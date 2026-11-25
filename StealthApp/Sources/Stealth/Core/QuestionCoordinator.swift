import Foundation

/// What happens when the other side adds to a question before you have spoken.
enum ContinuousQuestionPolicy: String, Codable, CaseIterable, Identifiable {
    /// The addition and the question are answered together; the earlier answer is kept in history.
    case update
    /// Every question gets its own answer.
    case separate
    var id: String { rawValue }
    var label: String {
        switch self { case .update: return "Update the answer"; case .separate: return "Answer separately" }
    }
    /// Earlier versions saved fast, smart or complete. Fast answered each part on its own;
    /// the other two tried to merge, which is what Update now does reliably.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "separate" || raw == "fast" ? .separate : .update
    }
}

/// Local, bounded scheduling. Classification never calls a paid model.
struct QuestionCoordinator {
    struct Candidate: Identifiable {
        let id = UUID()
        let answerID = UUID()
        let sourceID: String?
        var utterance: String
        var baseQuery: String?
        var query: String
        var context: String
        let speaker: Speaker?
        let delegationID: String?
        let trace: PipelineTrace?
        let receivedAt: Date
        var readyAt: Date
    }
    private(set) var pending: [Candidate] = []
    private var recent: [Candidate] = []
    private(set) var droppedCount = 0
    mutating func clear() { pending.removeAll(); recent.removeAll(); droppedCount = 0 }
    enum Outcome: Equatable {
        /// The same words were already queued or answered.
        case duplicate
        /// A recognition revision updated unstarted work, or arrived too late to matter.
        case revised
        case queued(answerID: UUID, merged: Bool)
    }
    /// - Parameters:
    ///   - continuesTurn: the speaker is still adding to the same question (you have not spoken).
    ///     It merges into their unstarted question, or into `previousQuery` when that question is
    ///     already being answered or was just answered.
    @discardableResult
    mutating func enqueue(query: String, context: String, speaker: Speaker?, delegationID: String?,
                          trace: PipelineTrace?, sourceID: String? = nil, continuesTurn: Bool = false,
                          previousQuery: String? = nil, now: Date = Date()) -> Outcome {
        recent.removeAll { now.timeIntervalSince($0.receivedAt) > 25 }
        guard !recent.contains(where: { $0.speaker == speaker && Self.key($0.utterance) == Self.key(query) }) else { return .duplicate }
        if let sourceID, let prior = recent.last(where: { $0.sourceID == sourceID && $0.speaker == speaker }) {
            // A stable segment revision updates only unstarted work, without a second billable request.
            if let index = pending.firstIndex(where: { $0.id == prior.id }) {
                pending[index].query = prior.baseQuery.map { $0 + "\n" + query } ?? query
                pending[index].utterance = query; pending[index].context = context
                if let recentIndex = recent.firstIndex(where: { $0.id == prior.id }) { recent[recentIndex] = pending[index] }
            }
            return .revised
        }
        var item = Candidate(sourceID: sourceID, utterance: query, baseQuery: nil, query: query, context: context, speaker: speaker, delegationID: delegationID,
                             trace: trace, receivedAt: now, readyAt: now)
        if continuesTurn {
            if let index = pending.lastIndex(where: { $0.speaker == speaker }) {
                item.baseQuery = pending[index].query
                pending.remove(at: index)
            } else if let previousQuery, !previousQuery.isEmpty {
                item.baseQuery = previousQuery
            }
            if let base = item.baseQuery { item.query = String((base + "\n" + query).suffix(6000)) }
        }
        recent.append(item)
        if pending.count == 3 { pending.removeFirst(); droppedCount += 1 }
        pending.append(item)
        return .queued(answerID: item.answerID, merged: item.baseQuery != nil)
    }
    func hasPending(from speaker: Speaker?) -> Bool { pending.contains { $0.speaker == speaker } }
    mutating func take(now: Date = Date()) -> Candidate? {
        let before = pending.count
        pending.removeAll { now.timeIntervalSince($0.receivedAt) > 25 }
        droppedCount += before - pending.count
        guard let first = pending.first, first.readyAt <= now else { return nil }
        return pending.removeFirst()
    }
    static func key(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
