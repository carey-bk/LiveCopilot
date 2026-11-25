import Foundation
import NaturalLanguage

enum KnowledgeMode: String, Codable, CaseIterable, Identifiable {
    case general, hybrid, knowledgeBaseOnly
    var id: String { rawValue }
    var usesKnowledgeBase: Bool { self != .general }
    var label: String {
        switch self {
        case .general: return "General Knowledge"
        case .hybrid: return "Hybrid Knowledge"
        case .knowledgeBaseOnly: return "Knowledge Base Only"
        }
    }
    var compactLabel: String {
        switch self { case .general: return "General Knowledge"; case .hybrid: return "Hybrid"; case .knowledgeBaseOnly: return "KB Only" }
    }
    var instructions: String {
        switch self {
        case .general:
            return """
            Knowledge mode: GENERAL KNOWLEDGE. No knowledge base is consulted. Answer the current
            question using your general knowledge and reasoning. Recent conversation, when supplied,
            clarifies the question; never force a connection to the user's resume or past projects.
            For hypothetical problems, explain what you would do, without claiming you already did it.
            Never invent personal experience or facts about the user. Do not cite local documents.
            """
        case .hybrid:
            return """
            Knowledge mode: HYBRID. Decide what the current question needs before using any excerpts.
            For general concepts, technical explanations, unfamiliar job responsibilities, hypothetical
            scenarios or proposed solutions, answer directly using relevant general knowledge and reasoning.
            If the question does not require knowledge-base facts, use ONLY general knowledge for the answer,
            even when retrieved excerpts are supplied. Do not redirect the answer to the user's resume,
            past projects or achievements merely because they share words with the question.
            Use excerpts only when the question needs specific documented facts, such as the user's actual
            experience, project results, or the contents of a document. With partial relevance, combine
            only directly supported personal facts with relevant general knowledge. Retrieval candidates
            are NOT proof of relevance. A fully general answer with no document citations is valid.
            Distinguish what you would do from what the user has actually done. Never invent personal facts.
            Ignore unrelated excerpts completely. Do not mention the knowledge base or missing evidence
            when answering a general question; never refuse it merely because the library has no match.
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

/// Languages a translation line can follow each answer sentence in. Labels are each language's own name.
enum TranslationLanguage: String, Codable, CaseIterable, Identifiable {
    case english, simplifiedChinese, traditionalChinese, japanese, korean, french, german, spanish, portuguese, italian, russian, arabic
    var id: String { rawValue }
    /// Shown as is in every interface language, so speakers can find their own language.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        }
    }
    var promptName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .italian: return "Italian"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        }
    }
    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
    /// Up to this many translations follow each sentence, so an answer stays readable while speaking.
    static let maximum = 3
    /// English for a non-English interface; Simplified Chinese for an English one.
    static func defaults(for interface: AppLanguage) -> [Self] { interface.usesChinese ? [.english] : [.simplifiedChinese] }

    /// Prompt section for the answer model; empty when no translation is requested.
    static func instructions(_ languages: [Self]) -> String {
        guard !languages.isEmpty else { return "" }
        let names = languages.map(\.promptName)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return """
        Translation lines are enabled (\(list)). Follow explicit user style and format preferences above when they conflict; otherwise use this format.
        For each sentence in the spoken answer, write the sentence in the response language, then immediately below it one line per translation, in this order: \(names.joined(separator: ", ")).
        Skip a translation when the sentence is already in that language: never repeat the sentence as its own "translation" (a Chinese answer gets no Chinese line). Keep each sentence and its translations together; never split the answer into separate whole-language blocks.
        Translate faithfully and naturally, as something the user could say aloud. Keep names, numbers, units and technical terms; carry **bold** over to the matching phrase in each translation. Do not label translation lines with language names.
        Headings stay in the response language only. Evidence and notes remain a separate, untranslated section.
        """
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

/// Display cleanup for model output: horizontal rules are dropped (the notes section has its own
/// divider), and a line that repeats an earlier line of the same paragraph is dropped (a
/// "translation" into the answer's own language). While streaming, an unfinished last line that
/// so far only repeats an earlier line, or is the start of a rule, is held back.
enum AnswerCleanup {
    static func cleaned(_ text: String, streaming: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        let unfinished = streaming ? lines.popLast() : nil
        var kept: [String] = [], block: [String] = []
        for line in lines {
            let key = normalized(line)
            if key.isEmpty { block = []; kept.append(line); continue }
            if isRule(line) || block.contains(key) { continue }
            block.append(key); kept.append(line)
        }
        if let unfinished {
            let key = normalized(unfinished)
            let partialRule = !key.isEmpty && Set(key).count == 1 && "-*_".contains(key.first!)
            if !partialRule && !(key.count > 0 && block.contains { $0.hasPrefix(key) }) { kept.append(unfinished) }
            else { kept.append("") }
        }
        return kept.joined(separator: "\n")
    }
    private static func normalized(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "").filter { !$0.isWhitespace }
    }
    private static func isRule(_ line: String) -> Bool {
        line.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil
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
