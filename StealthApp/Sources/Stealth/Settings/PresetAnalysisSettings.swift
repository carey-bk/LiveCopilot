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
                        TextField(t("Reasoning model"), text: $draft.model).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-model")
                    }
                    LabeledContent(t("API Base URL")) {
                        TextField(t("API Base URL"), text: $draft.baseURL).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-base-url")
                    }
                    Picker(b("Thinking mode", "思考模式"), selection: $draft.thinking) {
                        ForEach(AnalysisThinking.allCases) { Text(t($0.label)).tag($0) }
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
            if draft != coordinator.settings.presetConnection {
                Text(b("Save the connection before managing its key. The next answer still uses the saved connection.", "请先保存连接再管理密钥；下一次回答仍使用已保存的配置。")).font(.caption).foregroundStyle(.secondary)
            }
            CredentialEditor(coordinator: coordinator, analysis: true)
                .id(try? coordinator.settings.analysisCredentialReference().account)
                .disabled(draft != coordinator.settings.presetConnection)
        }.onAppear { draft = coordinator.settings.presetConnection ?? .qwen }
    }
    private var connectionNote: String {
        switch service {
        case .qwen:
            return b("Default: Qwen Plus, Beijing legacy endpoint. For a workspace endpoint, paste its full base URL from Model Studio, including /compatible-mode/v1. The API key must match its region. Singapore uses a different endpoint and key.",
                     "默认 Qwen Plus、北京旧域名。使用业务空间新域名时，请从百炼控制台复制完整 Base URL，包含 /compatible-mode/v1。Key 必须与地域一致，新加坡等地域的端点和 Key 不通用。")
        case .glm:
            return b("Default: GLM-5.2 on Zhipu's general API. For an international Z.AI account use https://api.z.ai/api/paas/v4 with its own key and an available model. Coding Plan endpoints are not general API endpoints.",
                     "默认 GLM-5.2、智谱通用 API。国际 Z.AI 账户请使用 https://api.z.ai/api/paas/v4、对应 Key 和可用模型。Coding Plan 专用端点不适用于通用 API。")
        case .kimi:
            return b("Default: Kimi K2.6, China API. For an international account use https://api.moonshot.ai/v1 with that platform's key. Model availability and billing follow your account.",
                     "默认 Kimi K2.6、国内 API。国际账户请使用 https://api.moonshot.ai/v1 和该平台的 Key，模型可用性及计费以账户为准。")
        default: return ""
        }
    }
    private func save() {
        do {
            var value = draft
            value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
            value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.model.isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
            _ = try value.endpoint()
            coordinator.settings.presetConnection = value
            draft = value
            message = "Connection saved. Credentials are scoped to this endpoint."
        } catch { message = error.localizedDescription }
    }
}
