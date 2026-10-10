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

/// Automatic assistance requires a provider delegation (Live semantics or the local text gate).
/// Caption gaps and VAD silence alone never request it.
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
        for fragment in Self.withoutAdjacentRepeats(Array(fragments.suffix(100))) {
            if rows.last?.0 == fragment.speaker {
                rows[rows.count - 1].1 += fragment.text
            } else { rows.append((fragment.speaker, fragment.text)) }
        }
        return String(rows.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "\n").suffix(limit))
    }

    mutating func candidate(speaker: Speaker, now: Date, cooldown: TimeInterval, force: Bool = false, semanticDetection: Bool = false) -> String? {
        guard let last = fragments.last(where: { $0.speaker == speaker }) else { phase = .waiting; return nil }
        if !force, speaker == .them,
           let you = fragments.last(where: { $0.speaker == .you }), you.receivedAt > last.receivedAt {
            phase = .answered; return nil
        }
        var eligible = fragments.filter { $0.speaker == speaker }
        if let id = lastQuestionFragmentID, let index = eligible.firstIndex(where: { $0.id == id }), index + 1 < eligible.count {
            eligible = Array(eligible.suffix(from: index + 1))
        }
        // A completed answer does not disable turn boundaries. Otherwise an
        // unanswered/duplicate caption can leak into every subsequent question.
        var start = max(0, eligible.count - 12)
        for i in stride(from: eligible.count - 1, through: max(1, start), by: -1) {
            if eligible[i].startMS - eligible[i - 1].endMS > 1600 { start = i; break }
        }
        eligible = Array(eligible.suffix(from: start))
        if !force {
            // Keep raw captions/context; only retire an exact answered prefix in
            // an automatic candidate. Never fuzzy-match a new follow-up here.
            let answered = Set(handled.filter { now.timeIntervalSince($0.at) <= 180 }.map { Self.captionKey($0.text) })
            while eligible.count > 1, let first = eligible.first,
                  answered.contains(Self.captionKey(first.text)) { eligible.removeFirst() }
        }
        let eligibleIDs = Set(eligible.map(\.id))
        // Include intervening speakers during deduplication so a repeated question
        // after someone else's answer remains a separate turn.
        let turns = fragments.filter { $0.speaker != speaker || eligibleIDs.contains($0.id) }
        let captions = Self.withoutAdjacentRepeats(turns).filter { $0.speaker == speaker }
        let question = String(captions.map(\.text).joined().suffix(2200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= (semanticDetection ? 2 : 5) else { phase = .waiting; return nil }
        let lower = question.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let incomplete = [" and", " or", " because", " if", " but", " the", " of", " with", "以及", "因为", "如果"]
        if !force && !semanticDetection && incomplete.contains(where: { lower.hasSuffix($0) }) { phase = .waiting; return nil }
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
    /// Keep the raw transcript intact. Only collapse adjacent repeated full captions
    /// in analysis input, never fuzzy matches, short acknowledgements or speaker turns.
    private static func withoutAdjacentRepeats(_ input: [TranscriptFragment]) -> [TranscriptFragment] {
        var result: [TranscriptFragment] = []
        for fragment in input {
            let key = captionKey(fragment.text)
            if key.count >= 5, let last = result.last, last.speaker == fragment.speaker,
               captionKey(last.text) == key { continue }
            result.append(fragment)
        }
        return result
    }
    private static func captionKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？… "))
    }
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
