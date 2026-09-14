import Foundation
import Combine

/// One finished transcript line, with speaker + timestamp.
struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    init(id: UUID = UUID(), speaker: Speaker, at: Date, content: String) {
        self.id = id; self.speaker = speaker; self.at = at; self.content = content
    }
    let speaker: Speaker
    let at: Date
    let content: String

    var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}

/// Observable two-sided transcript (You / Them), updated immutably.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []

    /// In-progress (not-yet-final) text per speaker, shown dimmer while streaming.
    @Published private(set) var partialThem: String = ""
    @Published private(set) var partialYou: String = ""
    var hasContent: Bool { !lines.isEmpty || !partialThem.isEmpty || !partialYou.isEmpty }

    func setPartial(_ text: String, speaker: Speaker) {
        switch speaker {
        case .them, .room: partialThem = text
        case .you: partialYou = text
        }
    }

    func appendDelta(_ delta: String, speaker: Speaker) {
        switch speaker {
        case .them, .room: partialThem += delta
        case .you: partialYou += delta
        }
    }

    /// Discard the in-progress partial for a speaker without committing it.
    func clearPartial(_ speaker: Speaker) {
        switch speaker {
        case .them, .room: partialThem = ""
        case .you: partialYou = ""
        }
    }

    /// Commit the current partial for a speaker as a finished line.
    func commitPartial(_ speaker: Speaker, now: Date = Date()) {
        let text: String
        switch speaker {
        case .them, .room: text = partialThem; partialThem = ""
        case .you: text = partialYou; partialYou = ""
        }
        commit(text, speaker: speaker, now: now)
    }

    /// Commit a complete transcribed line.
    func commit(_ line: String, speaker: Speaker, now: Date = Date()) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = lines + [TranscriptLine(speaker: speaker, at: now, content: trimmed)]
        if next.count > Config.transcriptLineLimit {
            next = Array(next.suffix(Config.transcriptLineLimit))
        }
        lines = next
    }

    /// Recent transcript (speaker-labelled) for suggestion requests.
    func recentContext(now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-Config.suggestionContextWindow)
        let recent = lines.filter { $0.at >= cutoff }
        let chosen = recent.isEmpty ? Array(lines.suffix(4)) : recent
        return chosen.map { "\($0.speaker.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    private var lastFragmentEnd: [Speaker: Int] = [:]
    func ingest(_ fragment: TranscriptFragment) {
        if let last = lines.last, last.speaker == fragment.speaker,
           let end = lastFragmentEnd[fragment.speaker], fragment.startMS >= end,
           fragment.startMS - end < 1600, last.content.count < 1800 {
            lines = Array(lines.dropLast()) + [TranscriptLine(id: last.id, speaker: last.speaker, at: last.at, content: last.content + fragment.text)]
        } else {
            lines = Array((lines + [TranscriptLine(speaker: fragment.speaker, at: fragment.receivedAt, content: fragment.text)]).suffix(Config.transcriptLineLimit))
        }
        lastFragmentEnd[fragment.speaker] = fragment.endMS
    }

    func clear() {
        lastFragmentEnd = [:]
        lines = []
        partialThem = ""
        partialYou = ""
    }
}
