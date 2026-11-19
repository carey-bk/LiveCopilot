import Foundation

struct SessionLine: Codable, Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let at: Date
    let content: String
    var fragmentIDs: [String]? = nil
    init(from line: TranscriptLine, fragmentIDs: [String] = []) {
        id = line.id; speaker = line.speaker; at = line.at; content = line.content
        self.fragmentIDs = fragmentIDs
    }
    var clock: String { at.formatted(date: .omitted, time: .shortened) }
}

/// A lightweight immutable snapshot of the same answer store used by the live flow.
/// No vectors or local file paths are archived with citations.
struct SessionCitation: Codable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    let documentID: String
    let documentName: String
    let page: Int?
    let ordinal: Int
    let excerpt: String
    var label: String { "[S\(index)] \(documentName)" + (page.map { " · p.\($0)" } ?? "") + " · \(ordinal + 1)" }
}
struct SessionAnswer: Codable, Equatable, Identifiable {
    let id: UUID
    let questionID: UUID
    let automatic: Bool
    let createdAt: Date
    let answeredAt: Date?
    let completedAt: Date?
    let question: String
    let text: String
    let state: String
    let warning: String?
    let error: String?
    let sources: [SessionCitation]
    let sourceFragmentID: String?
}

struct SessionEvent: Identifiable, Equatable {
    enum Kind: String { case room, nearby, own, question, answer }
    let id: String
    let at: Date
    let kind: Kind
    let content: String
    var answer: SessionAnswer? = nil
    var sourceIDs: [String] = []
    func role(english: Bool) -> String {
        switch kind {
        case .room: return english ? "Room speech" : "现场语音"
        case .nearby: return english ? "Remote speech" : "附近语音"
        case .own: return english ? "Your speech" : "我的语音"
        case .question: return answer?.automatic == true ? (english ? "Recognized question" : "识别的问题") : (english ? "Manual question" : "手动提问")
        case .answer: return english ? "AI answer" : "AI 回答"
        }
    }
    func exported(markdown: Bool, english: Bool = false) -> String {
        let heading = "[\(at.formatted(date: .omitted, time: .standard))] \(role(english: english))"
        var value = (markdown ? "### " : "") + heading + "\n\n" + (kind == .answer && !markdown ? AnswerEmphasis.plainText(content) : content)
        if kind == .answer, let answer {
            value += "\n\n" + (english ? "Status: " : "状态：") + answer.state
            if let warning = answer.warning { value += "\n" + warning }
            if let error = answer.error { value += "\n" + error }
            for source in answer.sources { value += "\n\n" + source.label + "\n" + source.excerpt }
        }
        return value
    }
}

/// Optional v2 fields decode old transcript-only JSON without rewriting it.
struct SessionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let lines: [SessionLine]
    var fragments: [TranscriptFragment]? = nil
    var schemaVersion: Int? = nil
    var answers: [SessionAnswer]? = nil
    var generatedTitle: String? = nil
    var namingState: String? = nil

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, lines: [SessionLine]) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.lines = lines
    }
    var title: String { generatedTitle ?? preview }
    var preview: String {
        let content = answers?.first(where: { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.question
            ?? lines.first(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.content
            ?? startedAt.formatted(date: .abbreviated, time: .shortened)
        return String(content.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(72))
    }
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var durationLabel: String { Int(duration) >= 60 ? "\(Int(duration) / 60) min" : "\(Int(duration)) sec" }
    var lineCount: Int { lines.count }
    var messageCount: Int { lines.count + (answers?.count ?? 0) * 2 }
    var isLegacy: Bool { answers == nil }
    var timeline: [SessionEvent] {
        var events = lines.map { line in
            SessionEvent(id: "speech-" + line.id.uuidString, at: line.at,
                         kind: line.speaker == .room ? .room : line.speaker == .them ? .nearby : .own,
                         content: line.content, sourceIDs: line.fragmentIDs ?? [])
        }
        for answer in answers ?? [] {
            // Retain the exact question sent to AI, linked to the ASR fragment when available.
            events.append(SessionEvent(id: "question-" + answer.id.uuidString, at: answer.createdAt, kind: .question, content: answer.question, answer: answer))
            events.append(SessionEvent(id: "answer-" + answer.id.uuidString, at: answer.answeredAt ?? answer.createdAt, kind: .answer, content: answer.text, answer: answer))
        }
        // Stable insertion order puts questions before their answers for equal timestamps.
        return events.enumerated().sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }.map(\.element)
    }
    func matches(_ search: String) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let content = ([title] + lines.map(\.content) + (answers ?? []).flatMap { [$0.question, $0.text] + $0.sources.map { $0.documentName + " " + $0.excerpt } }).joined(separator: "\n")
        return terms.allSatisfy { content.localizedStandardContains(String($0)) }
    }
    func export(markdown: Bool) -> String {
        let iso = ISO8601DateFormatter()
        return (markdown ? "# " : "") + title + "\n" + iso.string(from: startedAt) + " — " + iso.string(from: endedAt)
            + "\n\(durationLabel) · \(messageCount) messages\n\n" + timeline.map { $0.exported(markdown: markdown) }.joined(separator: "\n\n") + "\n"
    }
    var transcriptDocument: String { export(markdown: false) }
    var plainText: String { timeline.map { $0.exported(markdown: false) }.joined(separator: "\n\n") }
    var exportFilename: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "LiveCopilot-" + formatter.string(from: startedAt) + ".txt"
    }
    /// Preserve paired question/answer/evidence context; sample long sessions evenly.
    var namingInput: String {
        func sample<T>(_ values: [T], limit: Int) -> [T] {
            guard values.count > limit else { return values }
            return (0..<limit).map { values[$0 * (values.count - 1) / (limit - 1)] }
        }
        func clipped(_ value: String, _ limit: Int) -> String {
            value.count <= limit ? value : String(value.prefix(limit)) + " [truncated]"
        }
        let turns = (answers ?? []).sorted { $0.createdAt < $1.createdAt }
        let pairedFragments = Set(turns.compactMap(\.sourceFragmentID))
        let unpaired = lines.filter { Set($0.fragmentIDs ?? []).isDisjoint(with: pairedFragments) }
        let payload: [String: Any] = [
            "turns": sample(turns, limit: 8).map { answer -> [String: Any] in
                ["question": clipped(answer.question, 600),
                 "answer": clipped(answer.text, 2400),
                 "state": answer.state,
                 "citedEvidence": answer.sources.prefix(2).map { source in
                     ["reference": "S\(source.index)", "document": clipped(source.documentName, 160),
                      "excerpt": clipped(source.excerpt, 600)]
                 }]
            },
            "otherSpeech": sample(unpaired, limit: 8).map { clipped($0.content, 400) }
        ]
        guard !turns.isEmpty || !unpaired.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
