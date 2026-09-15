import Foundation

/// Published list prices, checked 2026-09-15. Match exact official model IDs only;
/// a compatible endpoint can have a completely different billing policy.
enum ServiceGuide {
    static let checked = "2026-09-15"
    static func text(_ en: String, _ zh: String, _ language: AppLanguage) -> String { language.usesChinese ? zh : en }
    static func listening(_ service: ListeningService, language: AppLanguage) -> String {
        switch service {
        case .openAI: return text("OpenAI · cloud, semantic question detection", "OpenAI · 云端，语义判断提问", language)
        case .apple: return text("Apple · local/free, streaming, macOS 26+", "Apple · 本地/免费，流式，macOS 26+", language)
        case .local: return text("SenseVoiceSmall + VAD · local/free, sentence captions", "SenseVoiceSmall + VAD · 本地/免费，整句识别", language)
        case .paraformer: return text("Paraformer · local/free, Chinese/English streaming", "Paraformer · 本地/免费，中英文流式", language)
        }
    }
    static func livePrice(_ model: String, language: AppLanguage) -> String {
        guard model == "gpt-live-1" else { return unknown(language) }
        return text("GPT-Live-1: $0.05/min per session, billed per second. Remote Meeting with system audio + microphone opens two sessions: about $0.10/min. Connected silence also counts. Backend model/tool usage is extra.",
                    "GPT-Live-1：每路会话 $0.05/分钟，按秒计费。远程会议同时开启系统音频和麦克风时为两路，约 $0.10/分钟。连接期间的静音也计时；后端模型/工具另计费。", language)
    }
    static func embeddingPrice(_ model: String, language: AppLanguage) -> String {
        let price: String
        switch model { case "text-embedding-3-small": price = "0.02"; case "text-embedding-3-large": price = "0.13"; default: return unknown(language) }
        return text("\(model): $\(price) per 1M input tokens. Charged for document indexing and query embeddings; re-indexing sends the text again.",
                    "\(model)：每百万输入 token $\(price)。文档建库与检索问题的向量化均计费；重新建库会再次处理文本。", language)
    }
    static func analysisPrice(_ service: ReasoningService, model: String, language: AppLanguage) -> String {
        switch service {
        case .compatible: return unknown(language)
        case .sharedOpenAI, .separateOpenAI:
            guard model == "gpt-5.6-sol" else { return unknown(language) }
            return text("GPT-5.6 Sol: per 1M tokens, input $4 · cached input $0.40 · output $20. Current promotional price, guaranteed at least through Nov 21, 2026. Cost depends on context and answer length, not minutes.",
                        "GPT-5.6 Sol：每百万 token，输入 $4 · 缓存命中输入 $0.40 · 输出 $20。当前优惠价至少持续至 2026-11-21。按上下文和回答长度计费，不按分钟。", language)
        case .deepSeek:
            let rates: String
            switch model {
            case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": rates = "$0.15 / $0.30 · $0.003 / $0.006 · $0.60 / $1.20"
            case "deepseek-v4-pro": rates = "$0.66 / $1.32 · $0.022 / $0.044 · $1.98 / $3.96"
            default: return unknown(language)
            }
            return text("\(model): per 1M tokens, input miss · input cache hit · output (off-peak / peak):\n\(rates)\nPeak: Mon–Fri 01:00–04:00 and 06:00–10:00 UTC (Beijing 09–12, 14–18). All other hours off-peak. Thinking tokens count as output.",
                        "\(model)：每百万 token，依次为未命中输入 · 缓存命中输入 · 输出（低峰 / 高峰）：\n\(rates)\n高峰：周一至周五北京时间 09–12、14–18 点；其余时间低峰。思考 token 计入输出。", language)
        }
    }
    static func unknown(_ language: AppLanguage) -> String {
        text("Pricing is set by this model's provider; no verified price for this selection. Check its billing page before use.", "当前选择暂无已核对报价，价格由模型服务商决定，请以其计费页面为准。", language)
    }
}
