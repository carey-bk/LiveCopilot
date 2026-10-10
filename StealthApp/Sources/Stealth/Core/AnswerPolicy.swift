import Foundation
import NaturalLanguage

enum KnowledgeMode: String, Codable, CaseIterable, Identifiable {
    case hybrid, knowledgeBaseOnly
    var id: String { rawValue }
    var label: String { self == .hybrid ? "Hybrid Knowledge" : "Knowledge Base Only" }
    var instructions: String {
        switch self {
        case .hybrid:
            return """
            Knowledge mode: HYBRID. Answer general questions even when there are NO relevant documents.
            Highly relevant excerpts take priority for the user's documented facts. With partial relevance,
            combine only the supported details with relevant general knowledge. Ignore unrelated excerpts
            completely and answer from your own knowledge. Retrieval candidates are NOT proof of relevance.
            Never say you cannot answer a general question merely because the knowledge base has no match.
            """
        case .knowledgeBaseOnly:
            return """
            Knowledge mode: KNOWLEDGE BASE ONLY. Factual answers must be supported by relevant supplied
            document excerpts. Do not fill evidence gaps with general knowledge. If documents are unrelated
            or insufficient, explain the specific gap briefly in the requested response language.
            Conversation may clarify the question but is not a substitute for document evidence.
            """
        }
    }
}

enum AnswerLanguage: String, Codable, CaseIterable, Identifiable {
    case auto, chinese, english
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: return "Auto"; case .chinese: return "中文"; case .english: return "English" }
    }
    var instructions: String {
        switch self {
        case .chinese: return "Response language override: Simplified Chinese. Write the entire answer and headings in Chinese, regardless of the question, documents or history. Keep technical names as needed."
        case .english: return "Response language override: English. Write the entire answer and headings in English, regardless of the question, documents or history. Translate any useful Chinese evidence into English."
        case .auto:
            return """
            Response language: AUTO, evaluated afresh for THIS question. First obey an explicit request
            for a response language in the current substantive question. Otherwise use the language of
            its main semantic clause. Chinese sentences containing English technical terms are Chinese;
            English questions containing Chinese names or quotations are English. For genuinely mixed
            questions, infer the main requested explanation's language, not a raw character majority.
            Do not carry over the previous answer's language. Document language and interface language
            NEVER choose the response language. Translate evidence as needed. For recap/follow-up, use
            the latest substantive participant utterance, never the app's English command.
            """
        }
    }
    func localFallbackIsChinese(question: String) -> Bool {
        switch self {
        case .chinese: return true
        case .english: return false
        case .auto:
            let lower = question.lowercased()
            if lower.range(of: #"(?:answer|respond|reply|explain)\s+(?:only\s+)?in\s+english|(?:用|以)英语(?:回答|解释)|(?:用|以)英文(?:回答|解释)"#, options: .regularExpression) != nil { return false }
            if lower.range(of: #"(?:answer|respond|reply|explain)\s+(?:only\s+)?in\s+(?:chinese|mandarin)|(?:用|以)中文(?:回答|解释)"#, options: .regularExpression) != nil { return true }
            return NLLanguageRecognizer.dominantLanguage(for: question) == .simplifiedChinese || NLLanguageRecognizer.dominantLanguage(for: question) == .traditionalChinese
        }
    }
    func missingEvidence(question: String) -> String {
        localFallbackIsChinese(question: question)
            ? "## 回答建议\n当前为仅知识库模式，未找到足以回答这个问题的相关资料。请补充资料，或切换到混合知识模式。"
            : "## Suggested answer\nKnowledge Base Only is enabled. No relevant document evidence was found for this question. Add supporting material or switch to Hybrid Knowledge."
    }
}

enum QuestionScope {
    /// Resolve short anaphoric follow-ups locally; independent topics must not inherit old retrieval terms.
    static func needsContext(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("what about ") || q.hasPrefix("how about ") || q.hasPrefix("那") { return true }
        if q.count < 18 && ["why", "why not", "how so", "为什么", "为什么呢", "然后呢", "怎么做"].contains(q.trimmingCharacters(in: .punctuationCharacters)) { return true }
        return q.range(of: #"\b(it|its|that|those|these|they|their|this approach|this method|the previous|above)\b|它|这个|那个|上述|刚才|刚刚|其中|呢[？?]?$"#, options: .regularExpression) != nil
    }
}

enum CitationPolicy {
    /// Retain streaming output while withholding an unfinished citation token and removing unknown IDs.
    static func sanitized(_ raw: String, sourceCount: Int) -> String {
        var text = raw
        if let regex = try? NSRegularExpression(pattern: #"\[S(\d+)\]"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let ns = text as NSString
                if let value = Int(ns.substring(with: match.range(at: 1))), value > 0, value <= sourceCount { continue }
                text = ns.replacingCharacters(in: match.range, with: "")
            }
        }
        if let range = text.range(of: #"\[S\d*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text
    }
}


// Laya owns intent confidence; these guards prevent a high score on an obviously
// unfinished final ASR fragment from taking the reduced quiet/cooldown path.
enum QuestionCompleteness {
    static func mustWait(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let tails = [" and", " or", " because", " if", " but", " the", " of", " with", " to", " about", " for", "以及", "因为", "如果", "但是", "然后", "比如", "关于", "对于", "和", "跟", "是多"]
        if tails.contains(where: q.hasSuffix) { return true }
        if q.hasSuffix("的") && !["怎么", "如何", "为什么", "什么", "多少"].contains(where: q.contains) { return true }
        if ["he asked", "she asked", "they asked", "i asked", "i don't know", "i do not know", "他问", "她问", "他昨天问", "她昨天问", "我不知道", "我刚才问"].contains(where: q.hasPrefix) { return true }
        return ["不用回答", "不需要回答", "忽略刚才", "never mind", "ignore that", "no need to answer"].contains(where: q.contains)
    }
    /// A second local signal for complete, directly addressed questions/requests.
    /// ASR punctuation is optional. The controller still requires a valid model
    /// result, final ASR, silence, and its normal lifecycle/deduplication guards.
    static func explicitDirectQuestion(_ text: String) -> Bool {
        guard !mustWait(text) else { return false }
        var q = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !["\"", "“", "「"].contains(where: q.contains) else { return false }
        q = q.replacingOccurrences(of: #"^(?:嗯|呃|那么|那)[，,\s]*"#, with: "", options: .regularExpression)
        guard q.count >= 5, !mustWait(q), !q.hasSuffix("是"), !q.hasSuffix(" is"), !q.hasSuffix(" are") else { return false }
        guard !["请介绍一下", "介绍一下", "请解释一下", "解释一下", "请说明一下", "说明一下", "告诉我们", "告诉我", "跟我说说", "讲一讲"].contains(q) else { return false }
        // Do not promote reported speech, indirect statements or hypothetical clauses.
        let indirect = #"^(?:我知道|我们知道|大家知道|我记得|他知道|她知道|他说|她说|他说过|她说过|刚才|昨天|如果|假如|比如|今天讨论|we know|i know|i remember|he said|she said|if |for example)"#
        guard q.range(of: indirect, options: .regularExpression) == nil else { return false }
        let commands = #"^(?:请(?:你|您)?|麻烦(?:你|您)?)?(?:讲讲|讲一讲|说说|说一说|谈谈|谈一谈|介绍(?:一下)?|解释(?:一下)?|说明(?:一下)?|描述(?:一下)?|分析(?:一下)?|告诉我(?:们)?|跟我说(?:说)?|给我(?:们)?讲(?:讲)?)(.{2,})$"#
        if q.range(of: commands, options: .regularExpression) != nil { return true }
        // Match a question's main clause, not a question word buried in a statement.
        let chineseQuestion = #"^(?:请问[，,\s]*)?(?:(?:为什么|为何|怎么|怎样|如何|能否|可否|能不能|有没有).{2,}|.{2,}(?:是什么|是多少|在哪里|是哪里|是哪个|有哪些|有多少|是谁|多久|怎么样)(?:.{0,30})|你(?:们)?(?:认为|觉得).{2,})$"#
        if q.range(of: chineseQuestion, options: .regularExpression) != nil,
           q.range(of: #"[，,。.!;；]"#, options: .regularExpression) == nil { return true }
        let englishQuestion = #"^(?:what|why|how|when|where|which|who|whose|can you|could you|would you|will you|do you|did you|have you|are you|is there|are there)\b"#
        if q.split(whereSeparator: \.isWhitespace).count >= 4,
           q.range(of: englishQuestion, options: .regularExpression) != nil { return true }
        let englishRequest = #"^(?:please )?(?:explain|describe|compare|summarize|tell (?:me|us)(?: about)?|walk (?:me|us) through)\s+\S.{2,}$"#
        return q.range(of: englishRequest, options: .regularExpression) != nil
    }
    static func permitsFastDispatch(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard q.count >= 5, !mustWait(text) else { return false }
        let tails = [" and", " or", " because", " if", " but", " the", " of", " with", " to", " about", " for", "以及", "因为", "如果", "但是", "然后", "比如", "关于", "对于", "和", "跟", "是多", "是"]
        guard !tails.contains(where: q.hasSuffix) else { return false }
        return LocalQuestionDetector.isQuestion(q)
    }
}
