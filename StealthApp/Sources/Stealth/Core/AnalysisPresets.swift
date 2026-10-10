import Foundation

enum AnalysisThinking: String, Codable, CaseIterable, Identifiable {
    case modelDefault, disabled, enabled, low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modelDefault: return "Model default"
        case .disabled: return "Off (faster)"
        case .enabled: return "On (more thinking)"
        case .low: return "Low (faster)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Xhigh"
        case .max: return "Maximum"
        }
    }
    var effort: String? {
        switch self {
        case .modelDefault, .disabled, .enabled: return nil
        default: return rawValue
        }
    }
}

/// Connection settings only. Each provider and endpoint has its own credential identity.
struct AnalysisConnection: Codable, Equatable {
    var baseURL: String
    var model: String
    var thinking = AnalysisThinking.modelDefault
    func endpoint() throws -> URL { try ServiceEndpoint.make(baseURL: baseURL, path: "chat/completions") }
    static let qwen = Self(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-flash", thinking: .low)
    static let glm = Self(baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flash", thinking: .low)
    static let kimi = Self(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2.6", thinking: .disabled)
}

extension ReasoningService {
    var isPreset: Bool { self == .qwen || self == .glm || self == .kimi }
    func availableThinkingModes(for model: String) -> [AnalysisThinking] {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self == .qwen && ["qwen3.8-flash", "qwen3.8-max", "qwen3.8-max-0902", "qwen3.8-27b", "qwen3.8-omni-flash"].contains(name) {
            return [.low, .medium, .xhigh, .disabled, .modelDefault, .enabled]
        }
        if self == .qwen && name == "qwen3.8-2.4t-a95b" { return [.low, .medium, .xhigh, .modelDefault, .enabled] }
        if self == .glm && ["glm-5.3", "glm-5.3-flash", "glm-5.3-flashx"].contains(name) {
            return [.low, .high, .max, .modelDefault, .enabled]
        }
        if self == .kimi && name == "kimi-k3" { return [.low, .high, .max, .modelDefault] }
        return [.modelDefault, .disabled, .enabled]
    }
    func defaultThinking(for model: String) -> AnalysisThinking {
        if availableThinkingModes(for: model).contains(.low) { return .low }
        if self == .kimi && ["kimi-k2.6"].contains(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return .disabled }
        return .modelDefault
    }
    func normalizedThinking(_ thinking: AnalysisThinking, model: String) -> AnalysisThinking {
        availableThinkingModes(for: model).contains(thinking) ? thinking : .modelDefault
    }
    var pricingURL: String? {
        switch self {
        case .sharedOpenAI, .separateOpenAI: return "https://developers.openai.com/api/docs/models/gpt-6.1-sol"
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
        case .glm: return "https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash"
        case .kimi: return "https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart"
        default: return nil
        }
    }
}

extension AppSettings {
    /// Explicit UI selection only: loading saved preferences must preserve the user's effort.
    mutating func selectAnalysisService(_ service: ReasoningService) {
        guard reasoningService != service else { return }
        reasoningService = service
        resetAnalysisEffort()
    }
    mutating func selectAnalysisModel(_ model: String) {
        guard analysisModel != model else { return }
        switch reasoningService {
        case .sharedOpenAI, .separateOpenAI: reasoningModel = model
        case .deepSeek: deepSeekModel = model
        case .qwen, .glm, .kimi: presetConnection?.model = model
        case .compatible: compatibleModel = model
        }
        resetAnalysisEffort()
    }
    private mutating func resetAnalysisEffort() {
        switch reasoningService {
        case .sharedOpenAI, .separateOpenAI: reasoningEffort = "low"
        case .deepSeek: deepSeekEffort = "low"
        case .qwen, .glm, .kimi:
            let thinking = reasoningService.defaultThinking(for: analysisModel)
            presetConnection?.thinking = thinking
        case .compatible: break // The custom endpoint's capabilities are unknown.
        }
    }
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
