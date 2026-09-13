import Foundation

/// A single archived line in a saved session. Mirrors `TranscriptLine` but is
/// `Codable` (the live `TranscriptLine.id` is a runtime UUID; here it's persisted).
struct SessionLine: Codable, Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let at: Date
    let content: String

    init(from line: TranscriptLine) {
        self.id = line.id
        self.speaker = line.speaker
        self.at = line.at
        self.content = line.content
    }

    var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}

// `Speaker` is a raw-value enum → free `Codable` conformance.


/// One saved listening session: its time bounds and full transcript.
struct SessionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let lines: [SessionLine]
    var fragments: [TranscriptFragment]? = nil

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, lines: [SessionLine]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lines = lines
    }

    var lineCount: Int { lines.count }

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// "Mon 30 Jun, 21:57"
    var title: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: startedAt)
    }

    /// "12 min" / "45 sec"
    var durationLabel: String {
        let secs = Int(duration)
        if secs >= 60 { return "\(secs / 60) min" }
        return "\(secs) sec"
    }

    /// Full speaker-labelled transcript as plain text (for copy / preview).
    var plainText: String {
        lines.map { "[\($0.clock)] \($0.speaker.rawValue): \($0.content)" }
            .joined(separator: "\n")
    }
}
