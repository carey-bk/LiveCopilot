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
        guard fragment.endMS >= fragment.startMS else { return false }
        if seenEventIDs.contains(fragment.id),
           let index = fragments.lastIndex(where: { $0.id == fragment.id }) {
            guard fragments[index].speaker == fragment.speaker, fragments[index].startMS == fragment.startMS,
                  fragment.endMS >= fragments[index].endMS, fragments[index].text != fragment.text else { return false }
            fragments[index] = fragment
            return true
        }
        seenEventIDs.insert(fragment.id)
        fragments.append(fragment)
        if fragments.count > 2600 {
            let drop = fragments.count - 2400
            for index in 0..<drop {
                seenEventIDs.remove(fragments[index].id)
            }
            fragments.removeFirst(drop)
        }
        if fragment.speaker != .you { phase = .forming }
        return true
    }

    func latestFragmentID(speaker: Speaker?) -> String? {
        fragments.last(where: { $0.speaker == speaker })?.id
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

    /// Talking within this long after their question arrived (a filler while waiting, or the start
    /// of your answer) does not count as having answered it yourself.
    static let ownReplyGrace: TimeInterval = 3
    /// When your words began: arrival minus their duration (both from the same recognizer).
    private static func ownSpeechStart(_ fragment: TranscriptFragment) -> Date {
        fragment.receivedAt.addingTimeInterval(-Double(max(0, fragment.endMS - fragment.startMS)) / 1000)
    }
    mutating func candidate(speaker: Speaker, now: Date, cooldown: TimeInterval, force: Bool = false, semanticDetection: Bool = false) -> String? {
        guard let last = fragments.last(where: { $0.speaker == speaker }) else { phase = .waiting; return nil }
        if !force, speaker == .them,
           let you = fragments.last(where: { $0.speaker == .you }), you.receivedAt > last.receivedAt,
           Self.ownSpeechStart(you) > last.receivedAt + Self.ownReplyGrace {
            phase = .answered; return nil
        }
        let eligible = candidateFragments(speaker: speaker, now: now, force: force)
        let captions: [TranscriptFragment]
        if let firstEligible = eligible.first,
           let startIndex = fragments.lastIndex(where: { $0.id == firstEligible.id }) {
            let eligibleIDs = Set(eligible.map(\.id))
            // Include intervening speakers during deduplication so a repeated question
            // after someone else's answer remains a separate turn.
            let turns = fragments[startIndex...].filter { $0.speaker != speaker || eligibleIDs.contains($0.id) }
            captions = Self.withoutAdjacentRepeats(turns).filter { $0.speaker == speaker }
        } else {
            captions = []
        }
        let question = String(captions.map(\.text).joined().suffix(2200)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Even a one-character turn can invite a contextual response. Laya owns
        // that semantic decision; the input layer only rejects empty text.
        guard question.count >= (semanticDetection ? 1 : 5) else { phase = .waiting; return nil }
        let lower = question.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let incomplete = [" and", " or", " because", " if", " but", " the", " of", " with", "以及", "因为", "如果"]
        if !force && !semanticDetection && incomplete.contains(where: { lower.hasSuffix($0) }) { phase = .waiting; return nil }
        handled.removeAll { now.timeIntervalSince($0.at) > 180 }
        if !force && handled.contains(where: { Self.similar($0.text, question) }) { phase = .duplicate; return nil }
        if !force, let at = lastTriggerAt, now.timeIntervalSince(at) < cooldown { phase = .waiting; return nil }
        phase = previousQuestion == nil ? .complete : .followUp
        return question
    }

    private func candidateFragments(speaker: Speaker, now: Date, force: Bool) -> [TranscriptFragment] {
        var eligible = fragments.filter { $0.speaker == speaker }
        if let id = lastQuestionFragmentID, let index = eligible.lastIndex(where: { $0.id == id }), index + 1 < eligible.count {
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
        return eligible
    }

    /// History is separate from the current candidate, so old requests cannot be
    /// duplicated into both fields. The worker applies the real 1,024-token budget.
    func layaContext(speaker: Speaker, now: Date, force: Bool = false) -> String {
        let currentIDs = Set(candidateFragments(speaker: speaker, now: now, force: force).map(\.id))
        let boundary = lastQuestionFragmentID.flatMap { id in fragments.lastIndex { $0.id == id } }
        struct Turn: Codable { let speaker: String; let text: String; let handled: Bool }
        struct Context: Codable { let currentSpeaker: String; var recentTurns: [Turn] }
        var context = Context(currentSpeaker: speaker.rawValue, recentTurns: [])
        for (index, fragment) in fragments.enumerated().suffix(80) where !currentIDs.contains(fragment.id) {
            context.recentTurns.append(Turn(speaker: fragment.speaker.rawValue, text: fragment.text,
                                           handled: boundary.map { index <= $0 } ?? false))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        while let data = try? encoder.encode(context) {
            if data.count <= 60_000 { return String(decoding: data, as: UTF8.self) }
            guard !context.recentTurns.isEmpty else { break }
            context.recentTurns.removeFirst()
        }
        return ""
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
        var lastKey: String?
        for fragment in input {
            let key = captionKey(fragment.text)
            if key.count >= 5, let last = result.last, last.speaker == fragment.speaker,
               lastKey == key { continue }
            result.append(fragment)
            lastKey = key
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
