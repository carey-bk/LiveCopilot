import Foundation

/// Curated text-answer models for LiveCopilot. Unlike a generic model list, each
/// choice is checked against its first-party API and reasoning controls.
/// Keep custom Model ID text entry available for future or private deployments.
struct AnalysisModelChoice: Identifiable {
    let id: String             // Exact first-party API Model ID.
    let name: String           // UI label.
    let subtitle: String       // Short use-case distinction.
}

enum AnalysisModelCatalog {
    static func choices(for service: ReasoningService) -> [AnalysisModelChoice] {
        switch service {
        case .sharedOpenAI, .separateOpenAI:
            return [
                .init(id: "gpt-6-luna", name: "GPT-6 Luna", subtitle: "Speed / value"),
                .init(id: "gpt-6-sol", name: "GPT-6 Sol", subtitle: "Balanced, legacy"),
                .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", subtitle: "Quality / balanced"),
                .init(id: "gpt-6-astra", name: "GPT-6 Astra", subtitle: "Highest quality")
            ]
        case .deepSeek:
            return [
                .init(id: "deepseek-flash", name: "DeepSeek V4.1 Flash", subtitle: "Fast Chinese"),
                .init(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", subtitle: "Quality")
            ]
        case .qwen:
            return [
                .init(id: "qwen3.8-flash", name: "Qwen3.8 Flash", subtitle: "Fast Chinese"),
                .init(id: "qwen3.8-27b", name: "Qwen3.8 27B", subtitle: "Economical"),
                .init(id: "qwen3.8-max", name: "Qwen3.8 Max", subtitle: "Quality")
            ]
        case .glm:
            return [
                .init(id: "glm-5.3-flash", name: "GLM-5.3 Flash", subtitle: "Lower cost"),
                .init(id: "glm-5.3-flashx", name: "GLM-5.3 FlashX", subtitle: "Faster deployment"),
                .init(id: "glm-5.3", name: "GLM-5.3", subtitle: "Quality")
            ]
        case .kimi:
            return [
                .init(id: "kimi-k2.6", name: "Kimi K2.6", subtitle: "Thinking optional"),
                .init(id: "kimi-k3", name: "Kimi K3", subtitle: "Deep reasoning")
            ]
        case .compatible:
            return [] // Custom gateway: unknown model IDs and reasoning capabilities.
        }
    }

    static func supports(_ model: String, service: ReasoningService) -> Bool {
        choices(for: service).contains { $0.id == model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    /// OpenAI explicitly rejects "none" for 6.1 Sol and Astra.
    static func openAIEfforts(for model: String) -> [String] {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let common = ["low", "medium", "high", "xhigh", "max"]
        if ["gpt-6-luna", "gpt-6-sol"].contains(name) { return ["", "none"] + common }
        return [""] + common
    }

    static func openAIEffortLabel(_ effort: String) -> String {
        switch effort {
        case "": return "Model default"
        case "none": return "Off (fastest)"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Xhigh"
        case "max": return "Maximum"
        default: return effort
        }
    }
}
