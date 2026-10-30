import Foundation

/// Published list prices, checked 2026-09-25. Match exact official model IDs only;
/// a compatible endpoint can have a completely different billing policy.
enum ServiceGuide {
    static let checked = "2026-09-25"
    static func text(_ en: String, _ zh: String, _ language: AppLanguage) -> String { language.usesChinese ? language.interfaceText(zh) : en }
    static func listening(_ service: ListeningService, language: AppLanguage) -> String {
        switch service {
        case .openAI: return text("OpenAI · cloud, semantic question detection", "OpenAI · 云端，语义判断提问", language)
        case .apple: return text("Apple · local/free, one language, macOS 26+", "Apple · 本地/免费，单语言，macOS 26+", language)
        case .zipformer: return text("Zipformer · local/free, terminology enhancement", "Zipformer · 本地/免费，术语增强", language)
        case .paraformer: return text("Paraformer · local/free, Chinese/English streaming", "Paraformer · 本地/免费，中英文流式", language)
        }
    }
    static func livePrice(_ model: String, language: AppLanguage) -> String {
        guard model == "gpt-live-1" else { return unknown(language) }
        return text("GPT-Live-1: $0.05/min per session, billed per second. Remote Meeting with system audio + microphone opens two sessions: about $0.10/min. Connected silence also counts. Backend model/tool usage is extra.",
                    "GPT-Live-1：每路会话 $0.05/分钟，按秒计费。远程会议同时开启系统音频和麦克风时为两路，约 $0.10/分钟。连接期间的静音也计时；后端模型/工具另计费。", language)
    }
    static func embeddingPrice(_ model: String, language: AppLanguage, compact: Bool = false) -> String {
        let price: String
        switch model { case "text-embedding-3-small": price = "0.02"; case "text-embedding-3-large": price = "0.13"; default: return unknown(language) }
        if compact { return text("$\(price) / 1M input tokens", "每百万输入 token $\(price)", language) }
        return text("\(model): $\(price) per 1M input tokens. Charged for document indexing and query embeddings; re-indexing sends the text again.",
                    "\(model)：每百万输入 token $\(price)。文档建库与检索问题的向量化均计费；重新建库会再次处理文本。", language)
    }
    static func analysisPrice(_ service: ReasoningService, model: String, language: AppLanguage) -> String {
        var settings = AppSettings()
        settings.language = language
        settings.selectAnalysisService(service)
        settings.selectAnalysisModel(model)
        guard let price = AnalysisPricing.display(settings) else { return unknown(language) }
        return price.summary(language) + text(" per 1M tokens. ", " / 每 100 万 Token。", language) + price.quote.conditions(language)
    }
    static func unknown(_ language: AppLanguage) -> String {
        text("Pricing is set by this model's provider; no verified price for this selection. Check its billing page before use.", "当前选择暂无已核对报价，价格由模型服务商决定，请以其计费页面为准。", language)
    }
}
