import Foundation
import Combine

enum AnswerState: String { case queued, generating, completed, interrupted, failed }

@MainActor final class SuggestionStore: ObservableObject {
    @Published private(set) var state = AnswerState.queued
    private(set) var answeredAt: Date?
    private(set) var completedAt: Date?
    private var rawText = ""
    @Published private(set) var text = ""
    @Published private(set) var question = ""
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var mode: SuggestionMode = .reply
    @Published var sources: [RetrievedSource] = []
    @Published var warning: String?
    @Published var retrievalMS = 0
    @Published var firstTextMS: Int?
    @Published var trace: PipelineTrace?
    var waitingMessage: String {
        if trace?.milliseconds(.reasoningStarted) != nil { return "The model is thinking…" }
        return trace?.milliseconds(.modelRequest) == nil ? "Retrieving evidence…" : "Waiting for the model's answer…"
    }
    func mark(_ stage: PipelineTrace.Stage, at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        trace?.mark(stage, at: at)
        if let trace { DebugLog.log(trace.logLine(stage)) }
    }
    var citedSources: [(index: Int, source: RetrievedSource)] {
        SuggestionParser.citedIndices(text, sourceCount: sources.count).map { ($0, sources[$0 - 1]) }
    }
    func begin(mode: SuggestionMode = .reply, question: String = "") {
        answeredAt = nil; completedAt = nil
        state = .generating
        self.mode = mode; self.question = question; isLoading = true; error = nil; text = ""; rawText = ""
        sources = []; warning = nil; retrievalMS = 0; firstTextMS = nil; trace = nil
    }
    func appendDelta(_ delta: String) { if answeredAt == nil && !delta.isEmpty { answeredAt = Date() }; rawText += delta; text = AnswerCleanup.cleaned(CitationPolicy.sanitized(rawText, sourceCount: sources.count), streaming: true) }
    func finish() {
        completedAt = Date(); isLoading = false; if state == .generating { state = .completed }
        text = AnswerCleanup.cleaned(CitationPolicy.sanitized(rawText, sourceCount: sources.count), streaming: false)
    }
    func interrupt(_ message: String? = nil) { completedAt = Date(); isLoading = false; state = .interrupted; warning = message }
    func prepare(question: String) { self.question = question; state = .queued }
    func fail(_ message: String) { completedAt = Date(); isLoading = false; state = .failed; error = message }
    func copy(from other: SuggestionStore) {
        answeredAt = other.answeredAt; completedAt = other.completedAt
        state = other.state
        rawText = other.rawText; text = other.text; question = other.question
        isLoading = other.isLoading; error = other.error; mode = other.mode
        sources = other.sources; warning = other.warning; retrievalMS = other.retrievalMS
        firstTextMS = other.firstTextMS; trace = other.trace
    }
    func reset() { answeredAt = nil; completedAt = nil; state = .queued; rawText = ""; text = ""; question = ""; isLoading = false; error = nil; sources = []; warning = nil; mode = .reply; retrievalMS = 0; firstTextMS = nil; trace = nil }
}
