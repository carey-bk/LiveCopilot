import Foundation
import Combine

@MainActor final class SuggestionStore: ObservableObject {
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
        self.mode = mode; self.question = question; isLoading = true; error = nil; text = ""; rawText = ""
        sources = []; warning = nil; retrievalMS = 0; firstTextMS = nil; trace = nil
    }
    func appendDelta(_ delta: String) { rawText += delta; text = CitationPolicy.sanitized(rawText, sourceCount: sources.count) }
    func finish() { isLoading = false }
    func fail(_ message: String) { isLoading = false; error = message }
    func reset() { rawText = ""; text = ""; question = ""; isLoading = false; error = nil; sources = []; warning = nil; mode = .reply; retrievalMS = 0; firstTextMS = nil; trace = nil }
}
