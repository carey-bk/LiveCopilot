import Foundation

enum AnalysisThinking: String, Codable, CaseIterable, Identifiable {
    case modelDefault, disabled, enabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modelDefault: return "Model default"
        case .disabled: return "Off (faster)"
        case .enabled: return "On (more thinking)"
        }
    }
}

/// Connection settings only. Each provider and endpoint has its own credential identity.
struct AnalysisConnection: Codable, Equatable {
    var baseURL: String
    var model: String
    var thinking = AnalysisThinking.modelDefault
    func endpoint() throws -> URL { try ServiceEndpoint.make(baseURL: baseURL, path: "chat/completions") }
    static let qwen = Self(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", thinking: .disabled)
    static let glm = Self(baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.2")
    static let kimi = Self(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2.6", thinking: .disabled)
}

extension ReasoningService {
    var isPreset: Bool { self == .qwen || self == .glm || self == .kimi }
    var pricingURL: String? {
        switch self {
        case .sharedOpenAI, .separateOpenAI: return "https://developers.openai.com/api/docs/models/gpt-5.6-sol"
        case .deepSeek: return "https://api-docs.deepseek.com/quick_start/pricing/"
        case .qwen: return "https://help.aliyun.com/zh/model-studio/model-pricing"
        case .glm: return "https://bigmodel.cn/pricing"
        case .kimi: return "https://platform.kimi.com/docs/pricing/chat"
        case .compatible: return nil
        }
    }
    var configurationURL: String? {
        switch self {
        case .qwen: return "https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope"
        case .glm: return "https://docs.bigmodel.cn/cn/guide/develop/http/introduction"
        case .kimi: return "https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart"
        default: return nil
        }
    }
}

extension AppSettings {
    var presetConnection: AnalysisConnection? {
        get {
            switch reasoningService {
            case .qwen: return qwenConnection
            case .glm: return glmConnection
            case .kimi: return kimiConnection
            default: return nil
            }
        }
        set {
            guard let value = newValue else { return }
            switch reasoningService {
            case .qwen: qwenConnection = value
            case .glm: glmConnection = value
            case .kimi: kimiConnection = value
            default: break
            }
        }
    }
}

enum OverlayTypography {
    static let range = 11.0...28.0
    static func clamped(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
