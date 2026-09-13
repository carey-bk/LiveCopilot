import Foundation

struct TranscriptFragment: Codable, Equatable, Sendable {
    let id: String
    let speaker: Speaker
    let text: String
    let startMS: Int
    let endMS: Int
    let receivedAt: Date
}

enum QuestionPhase: String {
    case listening = "Listening", forming = "Possible question forming"
    case complete = "Question ready", working = "Assistance in progress"
    case followUp = "Follow-up question", duplicate = "Already handled"
    case answered = "User has already answered", waiting = "Waiting for complete context"
}

/// Only a Live semantic delegation can request automatic assistance. Caption gaps never do.
struct ConversationState {
    private(set) var fragments: [TranscriptFragment] = []
    private(set) var phase = QuestionPhase.listening
    private(set) var previousQuestion: String?
    private var seenEventIDs: Set<String> = []
    private var handled: [(text: String, at: Date)] = []
    private var lastQuestionFragmentID: String?
    private var lastTriggerAt: Date?

    mutating func append(_ fragment: TranscriptFragment) -> Bool {
        guard !seenEventIDs.contains(fragment.id), fragment.endMS >= fragment.startMS else { return false }
        seenEventIDs.insert(fragment.id)
        fragments.append(fragment)
        if fragments.count > 2400 {
            fragments.removeFirst(fragments.count - 2400)
            seenEventIDs = Set(fragments.map(\.id))
        }
        if fragment.speaker != .you { phase = .forming }
        return true
    }

    func context(limit: Int = 7000) -> String {
        var rows: [(Speaker, String)] = []
        for fragment in fragments.suffix(100) {
            if rows.last?.0 == fragment.speaker {
                rows[rows.count - 1].1 += fragment.text
            } else { rows.append((fragment.speaker, fragment.text)) }
        }
        return String(rows.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "\n").suffix(limit))
    }

    mutating func candidate(speaker: Speaker, now: Date, cooldown: TimeInterval, force: Bool = false) -> String? {
        guard let last = fragments.last(where: { $0.speaker == speaker }) else { phase = .waiting; return nil }
        if !force, speaker == .them,
           let you = fragments.last(where: { $0.speaker == .you }), you.receivedAt > last.receivedAt {
            phase = .answered; return nil
        }
        var eligible = fragments.filter { $0.speaker == speaker }
        if let id = lastQuestionFragmentID, let index = eligible.firstIndex(where: { $0.id == id }), index + 1 < eligible.count {
            eligible = Array(eligible.suffix(from: index + 1))
        } else {
            // Restrict to the latest caption group, a context choice, not a completion assertion.
            var start = max(0, eligible.count - 12)
            for i in stride(from: eligible.count - 1, through: max(1, start), by: -1) {
                if eligible[i].startMS - eligible[i - 1].endMS > 1600 { start = i; break }
            }
            eligible = Array(eligible.suffix(from: start))
        }
        let question = String(eligible.map(\.text).joined().suffix(2200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= 5 else { phase = .waiting; return nil }
        let lower = question.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let incomplete = [" and", " or", " because", " if", " but", " the", " of", " with", "以及", "因为", "如果"]
        if !force && incomplete.contains(where: { lower.hasSuffix($0) }) { phase = .waiting; return nil }
        handled.removeAll { now.timeIntervalSince($0.at) > 180 }
        if !force && handled.contains(where: { Self.similar($0.text, question) }) { phase = .duplicate; return nil }
        if !force, let at = lastTriggerAt, now.timeIntervalSince(at) < cooldown { phase = .waiting; return nil }
        phase = previousQuestion == nil ? .complete : .followUp
        return question
    }

    mutating func begin(_ question: String, speaker: Speaker?, now: Date) {
        handled.append((question, now))
        previousQuestion = question
        lastTriggerAt = now
        if let speaker { lastQuestionFragmentID = fragments.last(where: { $0.speaker == speaker })?.id }
        phase = .working
    }
    mutating func finish(success: Bool, question: String) {
        if !success { handled.removeAll { $0.text == question }; lastTriggerAt = nil }
        phase = .listening
    }
    mutating func reset() { self = Self() }
    static func similar(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let a = canonical(lhs), b = canonical(rhs)
        if a == b { return true }
        guard min(a.count, b.count) > 20 else { return false }
        let aa = Set(lhs.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let bb = Set(rhs.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return aa.count > 4 && Double(aa.intersection(bb).count) / Double(max(1, aa.union(bb).count)) > 0.88
    }
}
