import Foundation

/// Curated public snapshots, never fetched while selecting a model. See
/// docs/validation/2026-10-10-hybrid-jev/analysis-performance-sources.md.
/// TTFT may include reasoning tokens; TTFA is when an answer becomes visible.
struct AnalysisPerformanceSample: Equatable {
    let model: String
    let effort: String
    let firstTokenSeconds: Double
    let tokensPerSecond: Double
    let firstAnswerSeconds: Double?
    let source: String
    let url: String
    let route: String
    let capturedAt: String
    let method: String
}

struct AnalysisPerformanceSelection {
    let effort: String
    let sample: AnalysisPerformanceSample?
    let matchesConfiguration: Bool

    /// Only same-model, same-effort, verified provider measurements can populate the card.
    /// Routed measurements are labelled with the gateway and provider in the source line.
    var matchingSample: AnalysisPerformanceSample? { matchesConfiguration ? sample : nil }
}

enum AnalysisPerformance {
    static let samples: [AnalysisPerformanceSample] = [
        .init(model: "gpt-6.1-sol", effort: "low", firstTokenSeconds: 3.03, tokensPerSecond: 51.3,
              firstAnswerSeconds: nil, source: "Artificial Analysis",
              url: "https://artificialanalysis.ai/models/gpt-6-1-sol-low", route: "OpenAI",
              capturedAt: "2026-10-10", method: "AA"),
        .init(model: "gpt-6-sol", effort: "low", firstTokenSeconds: 1.71, tokensPerSecond: 89,
              firstAnswerSeconds: 1.71, source: "Artificial Analysis",
              url: "https://artificialanalysis.ai/models/comparisons/gpt-6-1-sol-xhigh-vs-gpt-6-sol-low", route: "OpenAI",
              capturedAt: "2026-10-10", method: "AA"),
        .init(model: "deepseek-flash", effort: "max", firstTokenSeconds: 1.07, tokensPerSecond: 217,
              firstAnswerSeconds: 10.26, source: "Artificial Analysis",
              url: "https://artificialanalysis.ai/models/comparisons/deepseek-v4-1-flash-vs-glm-5-3-flash", route: "DeepSeek · V4.1 Flash",
              capturedAt: "2026-10-10", method: "AA"),
        .init(model: "glm-5.3-flash", effort: "unspecified", firstTokenSeconds: 3.05, tokensPerSecond: 58,
              firstAnswerSeconds: 37.80, source: "Artificial Analysis",
              url: "https://artificialanalysis.ai/models/comparisons/deepseek-v4-1-flash-vs-glm-5-3-flash", route: "GLM-5.3 Flash",
              capturedAt: "2026-10-10", method: "AA"),
        .init(model: "kimi-k2.6", effort: "none", firstTokenSeconds: 2.74, tokensPerSecond: 59,
              firstAnswerSeconds: 2.74, source: "Artificial Analysis",
              url: "https://artificialanalysis.ai/models/comparisons/kimi-k2-6-non-reasoning-vs-kimi-k2-thinking", route: "Kimi K2.6",
              capturedAt: "2026-10-10", method: "AA"),
        .init(model: "qwen3.8-flash", effort: "unspecified", firstTokenSeconds: 1.47, tokensPerSecond: 63,
              firstAnswerSeconds: nil, source: "OpenRouter",
              url: "https://openrouter.ai/qwen/qwen3.8-flash", route: "OpenRouter → Alibaba Cloud Int.",
              capturedAt: "2026-10-10", method: "OpenRouter"),
        .init(model: "gpt-6.1-sol", effort: "medium", firstTokenSeconds: 5.59, tokensPerSecond: 50.8, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-1-sol-medium", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6.1-sol", effort: "high", firstTokenSeconds: 61.03, tokensPerSecond: 51.5, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-1-sol-high", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6.1-sol", effort: "xhigh", firstTokenSeconds: 172.38, tokensPerSecond: 53.5, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-1-sol-xhigh", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6.1-sol", effort: "max", firstTokenSeconds: 320.85, tokensPerSecond: 55.6, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-1-sol", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6-sol", effort: "high", firstTokenSeconds: 23.37, tokensPerSecond: 84.6, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-sol-high", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6-sol", effort: "xhigh", firstTokenSeconds: 57.46, tokensPerSecond: 85.7, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-sol-xhigh", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "gpt-6-sol", effort: "max", firstTokenSeconds: 130.45, tokensPerSecond: 89.4, firstAnswerSeconds: nil, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/gpt-6-sol", route: "OpenAI", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "deepseek-flash", effort: "none", firstTokenSeconds: 1.15, tokensPerSecond: 222.1, firstAnswerSeconds: 1.15, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/deepseek-v4-1-flash-non-reasoning", route: "DeepSeek", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "kimi-k2.6", effort: "enabled", firstTokenSeconds: 2.75, tokensPerSecond: 57, firstAnswerSeconds: 80.95, source: "Artificial Analysis", url: "https://artificialanalysis.ai/models/comparisons/kimi-k2-6-vs-kimi-k2-thinking", route: "Kimi K2.6", capturedAt: "2026-10-10", method: "AA first-party API, published workload"),
        .init(model: "deepseek-flash", effort: "low", firstTokenSeconds: 1.13, tokensPerSecond: 153, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/deepseek/deepseek-v4.1-flash?reasoningEffort=low#providers", route: "DeepSeek", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "deepseek-flash", effort: "high", firstTokenSeconds: 1.26, tokensPerSecond: 162, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/deepseek/deepseek-v4.1-flash?reasoningEffort=high#providers", route: "DeepSeek", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "glm-5.3-flash", effort: "low", firstTokenSeconds: 3.57, tokensPerSecond: 33, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=low#providers", route: "Z.ai", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "glm-5.3-flash", effort: "high", firstTokenSeconds: 3.85, tokensPerSecond: 32, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=high#providers", route: "Z.ai", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "glm-5.3-flash", effort: "max", firstTokenSeconds: 3.0, tokensPerSecond: 58, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=max#providers", route: "Z.ai", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "kimi-k3", effort: "low", firstTokenSeconds: 3.95, tokensPerSecond: 26, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=low#providers", route: "Moonshot AI", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "kimi-k3", effort: "high", firstTokenSeconds: 4.35, tokensPerSecond: 16, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=high#providers", route: "Moonshot AI", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "kimi-k3", effort: "max", firstTokenSeconds: 5.89, tokensPerSecond: 20, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=max#providers", route: "Moonshot AI", capturedAt: "2026-10-10", method: "OpenRouter P50, first-party provider, effort filtered; gateway/region differ from direct API"),
        .init(model: "gpt-6-sol", effort: "medium", firstTokenSeconds: 2.23, tokensPerSecond: 68, firstAnswerSeconds: nil, source: "OpenRouter", url: "https://openrouter.ai/openai/gpt-6-sol?reasoningEffort=medium#providers", route: "OpenAI", capturedAt: "2026-10-10", method: "OpenRouter P50; standard OpenAI route, excludes Flex/Fast")
    ]

    static func selection(_ settings: AppSettings) -> AnalysisPerformanceSelection {
        let effort: String
        switch settings.reasoningService {
        case .sharedOpenAI, .separateOpenAI: effort = settings.reasoningEffort.isEmpty ? "modelDefault" : settings.reasoningEffort
        case .deepSeek: effort = settings.deepSeekEffort.isEmpty ? "modelDefault" : settings.deepSeekEffort
        case .qwen, .glm, .kimi:
            let mode = settings.reasoningService.normalizedThinking(settings.presetConnection!.thinking, model: settings.analysisModel)
            effort = mode == .disabled ? "none" : mode.rawValue
        case .compatible: effort = "unspecified"
        }
        // A similarly named model behind a custom endpoint is not the measured route.
        guard settings.reasoningService != .compatible else {
            return .init(effort: effort, sample: nil, matchesConfiguration: false)
        }
        let model = settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownModels: [ReasoningService: Set<String>] = [
            .sharedOpenAI: ["gpt-6.1-sol", "gpt-6-sol"], .separateOpenAI: ["gpt-6.1-sol", "gpt-6-sol"],
            .deepSeek: ["deepseek-flash"], .qwen: ["qwen3.8-flash"], .glm: ["glm-5.3-flash"], .kimi: ["kimi-k2.6", "kimi-k3"]
        ]
        let candidates = knownModels[settings.reasoningService]?.contains(model) == true ? samples.filter { $0.model == model } : []
        let sample = candidates.first { $0.effort == effort } ?? candidates.first
        // A routed first-party benchmark is useful for the same model/effort, but
        // is explicitly labelled OpenRouter -> provider (not a direct API test).
        // Custom endpoints and unsegmented statistics cannot inherit these values.
        let knownKimiRoute = settings.reasoningService == .kimi && ["https://api.moonshot.cn/v1", "https://api.moonshot.ai/v1"].contains(settings.kimiConnection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let knownGLMRoute = settings.reasoningService == .glm && ["https://open.bigmodel.cn/api/paas/v4", "https://api.z.ai/api/paas/v4"].contains(settings.glmConnection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let directRoute = knownGLMRoute || knownKimiRoute || settings.reasoningService == .sharedOpenAI || settings.reasoningService == .separateOpenAI || settings.reasoningService == .deepSeek
        return .init(effort: effort, sample: sample,
                     matchesConfiguration: directRoute && sample?.effort == effort && effort != "unspecified")
    }
}
