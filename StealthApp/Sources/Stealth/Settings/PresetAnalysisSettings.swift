import SwiftUI

struct PresetAnalysisSettings: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var draft = AnalysisConnection.qwen
    @State private var message = ""
    private var service: ReasoningService { coordinator.settings.reasoningService }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent(t("Reasoning model")) {
                        TextField(t("Reasoning model"), text: Binding(get: { draft.model }, set: { value in
                            if draft.model != value {
                                draft.model = value
                                draft.thinking = service.defaultThinking(for: value)
                            }
                        })).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-model")
                    }
                    LabeledContent(t("API Base URL")) {
                        TextField(t("API Base URL"), text: $draft.baseURL).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-base-url")
                    }
                    Picker(b("Thinking mode", "思考模式"), selection: $draft.thinking) {
                        ForEach(availableThinkingModes) { Text(t($0.label)).tag($0) }
                    }.accessibilityIdentifier("preset-thinking")
                    Text(connectionNote).font(.caption).foregroundStyle(.secondary)
                    Text(b("Chat Completions streaming. Do not include /chat/completions in the base URL. Thinking can increase latency and cost; if your chosen model cannot switch it off, use Model default. Keys are saved separately for each provider and endpoint.",
                           "使用 Chat Completions 流式接口，Base URL 不包含 /chat/completions。思考会增加等待时间与费用；所选模型若不支持关闭，请选“模型默认”。密钥按服务商和端点分别保存。")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(t("Save connection")) { save() }.accessibilityIdentifier("save-preset-connection")
                        if let url = service.configurationURL { Link(b("Official setup guide", "官方接入指南"), destination: URL(string: url)!) }
                    }
                    if !message.isEmpty { Text(t(message)).font(.caption).foregroundStyle(.secondary) }
                }.padding(10)
            } label: { Text(t(service.label)) }
            AnalysisPerformanceCard(settings: draftSettings)
            if draft != coordinator.settings.presetConnection {
                Text(b("Save the connection before managing its key. The next answer still uses the saved connection.", "请先保存连接再管理密钥；下一次回答仍使用已保存的配置。")).font(.caption).foregroundStyle(.secondary)
            }
            CredentialEditor(coordinator: coordinator, analysis: true)
                .id(try? coordinator.settings.analysisCredentialReference().account)
                .disabled(draft != coordinator.settings.presetConnection)
        }.onAppear {
            draft = coordinator.settings.presetConnection ?? .qwen
            draft.thinking = service.normalizedThinking(draft.thinking, model: draft.model)
        }

    }
    private var draftSettings: AppSettings {
        var settings = coordinator.settings
        settings.presetConnection = draft
        return settings
    }
    private var availableThinkingModes: [AnalysisThinking] {
        service.availableThinkingModes(for: draft.model)
    }
    private var connectionNote: String {
        switch service {
        case .qwen:
            return b("Default: Qwen3.8 Flash with low reasoning effort, Beijing legacy endpoint. For a workspace endpoint, paste its full base URL from Model Studio, including /compatible-mode/v1. The API key must match its region.",
                     "默认 Qwen3.8 Flash、low 推理强度，使用北京旧域名。业务空间请从百炼控制台复制完整 Base URL（含 /compatible-mode/v1）；Key 必须与地域一致。")
        case .glm:
            return b("Default: GLM-5.3 Flash on Zhipu's general API. This model requires thinking and defaults to low effort here. For an international Z.AI account use https://api.z.ai/api/paas/v4 with its own key. Coding Plan endpoints are not general API endpoints.",
                     "默认 GLM-5.3 Flash、智谱通用 API。此模型必须开启思考，本软件默认使用 low 推理强度。国际 Z.AI 账户请使用 https://api.z.ai/api/paas/v4 和对应 Key；Coding Plan 端点不适用于通用 API。")
        case .kimi:
            return b("Default: Kimi K2.6 with thinking off (no low setting), China API. Kimi K3 supports low/high/max. For an international account use https://api.moonshot.ai/v1 with that platform's key. Model availability and billing follow your account.",
                     "默认 Kimi K2.6、关闭思考（无 low 档位），使用国内 API。Kimi K3 可选 low/high/max。国际账户请使用 https://api.moonshot.ai/v1 和该平台的 Key；模型可用性及计费以账户为准。")
        default: return ""
        }
    }
    private func save() {
        do {
            var value = draft
            value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
            value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.model.isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
            value.thinking = service.normalizedThinking(value.thinking, model: value.model)
            _ = try value.endpoint()
            coordinator.settings.presetConnection = value
            draft = value
            message = "Connection saved. Credentials are scoped to this endpoint."
        } catch { message = error.localizedDescription }
    }
}
