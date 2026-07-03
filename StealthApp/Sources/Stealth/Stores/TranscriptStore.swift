import Foundation
import Combine

/// Who said a given line.
enum Speaker: String {
    case them = "Them"
    case you = "You"
}

/// One finished transcript line, with speaker + timestamp.
struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
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

    func appendDelta(_ delta: String, speaker: Speaker) {
        switch speaker {
        case .them: partialThem += delta
        case .you: partialYou += delta
        }
    }

    /// Discard the in-progress partial for a speaker without committing it.
    func clearPartial(_ speaker: Speaker) {
        switch speaker {
        case .them: partialThem = ""
        case .you: partialYou = ""
        }
    }

    /// Commit the current partial for a speaker as a finished line.
    func commitPartial(_ speaker: Speaker, now: Date = Date()) {
        let text: String
        switch speaker {
        case .them: text = partialThem; partialThem = ""
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

    func clear() {
        lines = []
        partialThem = ""
        partialYou = ""
    }
}
