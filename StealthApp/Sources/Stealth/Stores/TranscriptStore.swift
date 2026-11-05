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

    private(set) var archivedLines: [TranscriptLine] = []
    private(set) var fragmentRevisions: [TranscriptFragment] = []
    func archiveSnapshot(since: Date) -> [SessionLine] {
        archivedLines.filter { $0.at >= since }.map { SessionLine(from: $0, fragmentIDs: fragmentsByLine[$0.id, default: []].map(\.id)) }
    }

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
        archivedLines.append(TranscriptLine(speaker: speaker, at: now, content: trimmed))
        lines = Array(archivedLines.suffix(Config.transcriptLineLimit))
    }

    private var protectedPreview: (id: UUID, text: String, at: Date)?

    func preserveOwnPreview(_ text: String, at now: Date = Date()) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let saved = protectedPreview, now.timeIntervalSince(saved.at) < 12,
           value.hasPrefix(saved.text), let index = archivedLines.firstIndex(where: { $0.id == saved.id }) {
            archivedLines[index] = TranscriptLine(id: saved.id, speaker: .you, at: saved.at, content: value)
            protectedPreview = (saved.id, value, now)
            lines = Array(archivedLines.suffix(Config.transcriptLineLimit))
            clearPartial(.you)
            return
        }
        commit(value, speaker: .you, now: now)
        protectedPreview = archivedLines.last.map { ($0.id, value, now) }
        clearPartial(.you)
    }

    /// Recent transcript (speaker-labelled) for suggestion requests.
    func recentContext(now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-Config.suggestionContextWindow)
        let recent = lines.filter { $0.at >= cutoff }
        let chosen = recent.isEmpty ? Array(lines.suffix(4)) : recent
        return chosen.map { "\($0.speaker.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    private var lastFragmentEnd: [Speaker: Int] = [:]
    private var fragmentsByLine: [UUID: [TranscriptFragment]] = [:]
    private var fragmentLine: [String: UUID] = [:]
    func ingest(_ fragment: TranscriptFragment) {
        if fragmentRevisions.last(where: { $0.id == fragment.id }) != fragment { fragmentRevisions.append(fragment) }
        defer { lines = Array(archivedLines.suffix(Config.transcriptLineLimit)) }
        if let lineID = fragmentLine[fragment.id], let index = archivedLines.firstIndex(where: { $0.id == lineID }),
           var parts = fragmentsByLine[lineID], let part = parts.firstIndex(where: { $0.id == fragment.id }) {
            parts[part] = fragment; fragmentsByLine[lineID] = parts
            let old = archivedLines[index]
            archivedLines[index] = TranscriptLine(id: old.id, speaker: old.speaker, at: old.at, content: parts.map(\.text).joined())
            return
        }
        if fragment.speaker == .you, let saved = protectedPreview {
            protectedPreview = nil
            let final = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if fragment.receivedAt.timeIntervalSince(saved.at) < 12, final.hasPrefix(saved.text),
               let index = archivedLines.firstIndex(where: { $0.id == saved.id }) {
                archivedLines[index] = TranscriptLine(id: saved.id, speaker: .you, at: saved.at, content: final)
                fragmentsByLine[saved.id] = [fragment]
                fragmentLine[fragment.id] = saved.id
                lastFragmentEnd[.you] = fragment.endMS
                return
            }
        }
        if let last = archivedLines.last, last.speaker == fragment.speaker,
           let end = lastFragmentEnd[fragment.speaker], fragment.startMS >= end,
           fragment.startMS - end < 1600, last.content.count < 1800 {
            archivedLines = Array(archivedLines.dropLast()) + [TranscriptLine(id: last.id, speaker: last.speaker, at: last.at, content: last.content + fragment.text)]
        } else {
            archivedLines = archivedLines + [TranscriptLine(speaker: fragment.speaker, at: fragment.receivedAt, content: fragment.text)]
        }
        if let id = archivedLines.last?.id {
            fragmentsByLine[id, default: []].append(fragment); fragmentLine[fragment.id] = id
        }
        lastFragmentEnd[fragment.speaker] = fragment.endMS
    }

    func clear() {
        protectedPreview = nil
        fragmentsByLine = [:]; fragmentLine = [:]
        lastFragmentEnd = [:]
        archivedLines = []; fragmentRevisions = []
        lines = []
        partialThem = ""
        partialYou = ""
    }
}
