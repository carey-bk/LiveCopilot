import Foundation
import Combine

@MainActor
final class TranscriptTranslationStore: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case simplified = "简体中文", traditional = "繁體中文", english = "English", japanese = "日本語", korean = "한국어", french = "Français", german = "Deutsch", spanish = "Español"
        var id: String { rawValue }
        var prompt: String {
            switch self {
            case .simplified: return "Simplified Chinese"
            case .traditional: return "Traditional Chinese"
            case .english: return "English"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .french: return "French"
            case .german: return "German"
            case .spanish: return "Spanish"
            }
        }
    }
    struct Translation: Equatable { let source: String; let text: String }
    @Published private(set) var enabled = false
    @Published private(set) var target: Language = .simplified
    @Published private(set) var values: [UUID: Translation] = [:]
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    private var provider: (any ReasoningProvider)?
    private var lines: [TranscriptLine] = []
    private var confirmed: [TranscriptLine] = []
    private var previews: [Speaker: TranscriptLine] = [:]
    private var cache: [String: String] = [:]
    func previewText(_ source: String, speaker: Speaker) -> String? {
        guard let line = previews[speaker], line.content == source else { return nil }
        return text(for: line)
    }
    func updatePreview(_ source: String, speaker: Speaker) {
        guard enabled else { return }
        if source.isEmpty { previews[speaker] = nil }
        else if previews[speaker]?.content != source {
            previews[speaker] = TranscriptLine(id: previews[speaker]?.id ?? UUID(), speaker: speaker, at: Date(), content: source)
        }
        refresh()
    }
    private func refresh() {
        lines = Array(confirmed.suffix(20)) + previews.values.sorted { $0.at < $1.at }
        let ids = Set(lines.map(\.id))
        values = values.filter { ids.contains($0.key) }; completed = completed.filter { ids.contains($0.key) }
        for line in lines where completed[line.id] != line.content {
            if let text = cache[line.content] {
                values[line.id] = Translation(source: line.content, text: text)
                completed[line.id] = line.content
            }
        }
        if let activeLine, !lines.contains(where: { $0.id == activeLine.id && $0.content == activeLine.content }) {
            generation = UUID(); task?.cancel(); task = nil; timeoutTask?.cancel(); timeoutTask = nil
            self.activeLine = nil; busy = false
        }
        pump()
    }
    private var activeLine: TranscriptLine?
    private var timeoutTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var completed: [UUID: String] = [:]
    func text(for line: TranscriptLine) -> String? {
        guard let value = values[line.id], value.source == line.content else { return nil }
        return value.text
    }
    func start(target: Language, provider: any ReasoningProvider, lines: [TranscriptLine]) {
        stop(); self.target = target; self.provider = provider; enabled = true
        // Enabling starts with the latest confirmed utterance, never uploads the entire old meeting.
        completed = Dictionary(uniqueKeysWithValues: lines.dropLast().map { ($0.id, $0.content) })
        update(lines: lines)
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; timeoutTask?.cancel(); timeoutTask = nil; activeLine = nil; provider = nil
        enabled = false; busy = false; failed = false; values = [:]; completed = [:]; lines = []; confirmed = []; previews = [:]; cache = [:]
    }
    func resetSession() {
        let active = enabled, provider = provider, target = target
        stop()
        if active, let provider { start(target: target, provider: provider, lines: []) }
    }
    func update(lines: [TranscriptLine]) {
        guard enabled else { return }
        confirmed = lines
        refresh()
    }
    private func pump() {
        guard task == nil, enabled, let provider,
              let line = lines.last(where: { completed[$0.id] != $0.content }) else { return }
        let token = generation, language = target
        let isPreview = previews.values.contains { $0.id == line.id }
        busy = true; activeLine = line
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.generation = UUID(); self.task?.cancel(); self.task = nil; self.activeLine = nil
            self.values[line.id] = nil; self.completed[line.id] = line.content
            self.failed = true; self.busy = false; self.pump()
        }
        task = Task { [weak self] in
            do {
                // Coalesce nearby final ASR fragments that merge into the same visible line.
                try await Task.sleep(nanoseconds: isPreview ? 900_000_000 : 100_000_000)
                guard let self, token == self.generation else { return }
                guard self.lines.contains(where: { $0.id == line.id && $0.content == line.content }) else {
                    self.timeoutTask?.cancel(); self.activeLine = nil; self.task = nil; self.busy = false; self.pump(); return
                }
                var request = AnswerRequest(query: .init(question: "", semantic: "", lexical: ""), conversation: "", scenario: .interview, sources: [])
                request.translationText = line.content; request.translationTarget = language.prompt
                var output = ""
                for try await delta in provider.stream(request) {
                    try Task.checkCancellation()
                    output += delta
                    guard output.count <= 16_000 else { throw CopilotError.message("Translation too long") }
                    guard token == self.generation else { return }
                    if self.lines.contains(where: { $0.id == line.id && $0.content == line.content }) {
                        self.values[line.id] = Translation(source: line.content, text: output)
                    }
                }
                try Task.checkCancellation()
                guard token == self.generation else { return }
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Empty translation") }
                if self.lines.contains(where: { $0.id == line.id && $0.content == line.content }) {
                    self.values[line.id] = Translation(source: line.content, text: output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if self.cache.count >= 80 { self.cache.removeAll() }
                self.cache[line.content] = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.failed = false
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.values[line.id] = nil
                self.failed = true
            }
            guard let self, token == self.generation else { return }
            self.completed[line.id] = line.content
            self.timeoutTask?.cancel(); self.activeLine = nil; self.task = nil; self.busy = false; self.pump()
        }
    }
}
