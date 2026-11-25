import SwiftUI

/// Shared selection and request settings for onboarding and Services.
struct OnboardingAnswerConfiguration: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var settings: AppSettings { coordinator.settings }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    private var provider: Binding<ReasoningService> {
        Binding(get: { settings.reasoningService == .sharedOpenAI ? .separateOpenAI : settings.reasoningService }, set: {
            coordinator.settings.selectRecommendedAnalysisService($0)
        })
    }
    /// Settings shows this as a regular settings card; onboarding keeps its numbered step.
    var settingsStyle = false
    var body: some View {
        if settingsStyle {
            LCSettingsCard(b("Answer model", "回答模型"), subtitle: b("The provider and model that write answers.", "生成回答所用的服务商和模型。"),
                           systemImage: "sparkles", tone: .pink) { configuration }
                .accessibilityIdentifier("onboarding-answer-configuration")
        } else {
            OnboardingServiceSection(number: 1, title: b("Choose & configure your answer model", "选择与配置回答模型"), showsBorder: false) { configuration }
                .accessibilityIdentifier("onboarding-answer-configuration")
        }
    }
    @ViewBuilder private var configuration: some View {
            HStack(spacing: 10) {
                Picker(b("Provider", "AI 服务商"), selection: provider) {
                    Text("OpenAI").tag(ReasoningService.separateOpenAI)
                    Text("DeepSeek").tag(ReasoningService.deepSeek)
                    Text("Qwen").tag(ReasoningService.qwen)
                    Text("GLM").tag(ReasoningService.glm)
                    Text("Kimi").tag(ReasoningService.kimi)
                    Text(b("Custom compatible API", "自定义兼容接口")).tag(ReasoningService.compatible)
                }.frame(width: settings.language.usesChinese ? 245 : 260)
                    .accessibilityIdentifier("onboarding-analysis-provider")
                if settings.reasoningService != .compatible {
                Button {
                    if !settings.usesRecommendedAnalysis { coordinator.settings.applyAnalysisRecommendation() }
                } label: {
                    HStack(spacing: 4) {
                        if settings.usesRecommendedAnalysis { Image(systemName: "checkmark.circle.fill") }
                        Text(settings.usesRecommendedAnalysis ? b("Applied", "已应用推荐配置") : b("Apply recommendation", "应用推荐配置"))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.usesRecommendedAnalysis ? LC.success : LC.accent)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background((settings.usesRecommendedAnalysis ? LC.success : LC.accent).opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                    .buttonStyle(.plain).fixedSize()
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: settings.usesRecommendedAnalysis)
                    .disabled(AnalysisModelCatalog.recommended(for: settings.reasoningService) == nil)
                    .accessibilityIdentifier("apply-analysis-recommendation")
                }
                Spacer(minLength: 0)
            }
                if settings.isOpenAIAnalysis {
                    Toggle(b("Use speech OpenAI key", "与语音识别共用 OpenAI 密钥"), isOn: Binding(
                        get: { coordinator.hasAPIKey && settings.reasoningService == .sharedOpenAI },
                        set: { coordinator.settings.selectAnalysisService($0 && coordinator.hasAPIKey ? .sharedOpenAI : .separateOpenAI) }))
                        .disabled(!coordinator.hasAPIKey)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .fixedSize().accessibilityIdentifier("analysis-share-openai-key")
                }
            if settings.reasoningService == .compatible {
                OnboardingCompatibleConnection(coordinator: coordinator)
            } else {
                currentConfiguration
                AnalysisModelFields(settings: $coordinator.settings)
                Divider()
                AnalysisMetrics(settings: settings)
            }
    }
    private var currentConfiguration: some View {
        let name = OnboardingAnalysisChoice.displayName(settings) ??
            (settings.analysisModel.isEmpty ? b("No model selected", "未选择模型") : settings.analysisModel)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(b("Current configuration · ", "当前配置 · ") + name + " / " + settings.analysisThinking.menuName +
                  " · " + settings.analysisProcessing.name, systemImage: "slider.horizontal.3")
                .foregroundStyle(LC.accent)
                .accessibilityIdentifier("analysis-current-configuration")
            if settings.usesRecommendedAnalysis {
                Text(AnalysisModelCatalog.tags(for: settings.reasoningService, language: settings.language))
                    .foregroundStyle(.secondary).accessibilityIdentifier("analysis-recommendation-tags")
            }
            Spacer(minLength: 0)
        }.font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
    }
}

struct AnalysisModelFields: View {
    @Binding var settings: AppSettings
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    private var knownModels: [AnalysisModel] { AnalysisModelCatalog.models(for: settings.reasoningService) }
    private var model: Binding<String> {
        Binding(get: { settings.analysisModel }, set: { settings.selectAnalysisModel($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !knownModels.isEmpty {
                    HStack(spacing: 6) {
                        Text(b("Model", "模型"))
                        Menu {
                            ForEach(knownModels.filter { AnalysisConfigurations.modelIsRecommended($0.id) }) { modelOption($0) }
                            let others = knownModels.filter { !AnalysisConfigurations.modelIsRecommended($0.id) }
                            if !others.isEmpty {
                                Menu(b("Other (not recommended)", "其他（不推荐）")) { ForEach(others) { modelOption($0) } }
                            }
                        } label: { Text(OnboardingAnalysisChoice.displayName(settings) ?? b("Custom", "自定义")) }
                            .fixedSize().accessibilityLabel(b("Model", "模型")).accessibilityIdentifier("analysis-model-picker")
                    }
                }
                HStack(spacing: 6) {
                    Text(b("Reasoning", "推理深度"))
                    Menu {
                        let modes = settings.reasoningService.availableThinkingModes(for: settings.analysisModel)
                        ForEach(modes.filter { recommended($0) }) { option($0) }
                        let others = modes.filter { !recommended($0) }
                        if !others.isEmpty {
                            Menu(b("Other (not recommended)", "其他（不推荐）")) { ForEach(others) { option($0) } }
                        }
                    } label: { Text(settings.analysisThinking == .modelDefault ? b("Default", "模型默认") : settings.analysisThinking.menuName) }
                        .fixedSize().disabled(settings.analysisThinking == .modelDefault)
                        .accessibilityLabel(b("Reasoning", "推理深度")).accessibilityIdentifier("onboarding-analysis-effort")
                }
                if settings.isOpenAIAnalysis {
                    HStack(spacing: 6) {
                        Text(b("Speed", "速度"))
                        Menu {
                            let modes = AnalysisConfigurations.processingModes(model: settings.analysisModel)
                            ForEach(modes.filter { recommended(settings.analysisThinking, processing: $0) }) { processingOption($0) }
                            let others = modes.filter { !recommended(settings.analysisThinking, processing: $0) }
                            if !others.isEmpty {
                                Menu(b("Other (not recommended)", "其他（不推荐）")) { ForEach(others) { processingOption($0) } }
                            }
                        } label: { Text(settings.analysisProcessing.name) }
                            .fixedSize().disabled(!settings.supportsOpenAIFast)
                            .accessibilityLabel(b("Processing mode", "处理模式"))
                            .accessibilityIdentifier("onboarding-openai-processing")
                    }
                }
            }.font(.system(size: 12))
            HStack(spacing: 10) {
                Text("API Model ID").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("API Model ID", text: model).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).frame(width: 205)
                    .accessibilityIdentifier("onboarding-analysis-model")
                Text(b("Enter a custom ID to route requests to that model.", "可自定义输入，路由至指定模型"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if settings.analysisThinking == .modelDefault {
                Text(b("Unknown model: optional reasoning parameters are omitted.", "未收录的模型使用模型默认，不发送额外推理参数。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

        }
    }
    private func recommended(_ thinking: AnalysisThinking, processing: AnalysisProcessing? = nil) -> Bool {
        AnalysisConfigurations.recommended(model: settings.analysisModel, thinking: thinking, processing: processing ?? settings.analysisProcessing)
    }
    private func modelOption(_ item: AnalysisModel) -> some View {
        Button {
            settings.selectAnalysisModel(item.id)
            settings.analysisProcessing = .standard
        } label: {
            if settings.analysisModel == item.id { Label(item.name, systemImage: "checkmark") }
            else { Text(item.name) }
        }
    }
    private func processingOption(_ mode: AnalysisProcessing) -> some View {
        Button { settings.analysisProcessing = mode } label: {
            if settings.analysisProcessing == mode { Label(mode.name, systemImage: "checkmark") }
            else { Text(mode.name) }
        }
    }
    private func option(_ mode: AnalysisThinking) -> some View {
        Button { settings.analysisThinking = mode } label: {
            if settings.analysisThinking == mode { Label(mode.menuName, systemImage: "checkmark") }
            else { Text(mode == .modelDefault ? b("Model default", "模型默认") : mode.menuName) }
        }
    }
}

struct OnboardingAnswerRecommendations: View {
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text(b("Recommended starting points", "推荐你优先这样开始"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            recommendation(.separateOpenAI, "GPT-6 Sol · Low · Fast", b("Strong reasoning with responsive answers for technical interviews.", "推理能力强，兼顾响应速度，适合专业技术面试。"))
            recommendation(.separateOpenAI, "GPT-6 Luna · Low · Fast", b("Fast, low-cost generation for frequent real-time Q&A.", "高速生成、成本极低，适合高频实时问答。"))
            recommendation(.deepSeek, "DeepSeek Flash · Low · Standard", b("Strong Chinese understanding with balanced speed and cost.", "中文理解出色，速度与性价比兼顾。"))
            recommendation(.glm, "GLM-5.3 FlashX · Low · Standard", b("Very fast generation for quickly composing longer answers.", "生成速度极快，适合需要快速组织长回答的场景。"))
        }.accessibilityElement(children: .combine).accessibilityIdentifier("onboarding-answer-recommendations")
    }
    private func recommendation(_ service: ReasoningService, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AnalysisProviderLogo(service: service, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Save the endpoint and model atomically before looking up endpoint-scoped credentials.
/// Connection templates only; credentials remain scoped to the saved endpoint.
/// Official source URLs were checked on 2026-11-18. No popularity or availability ranking.
struct CompatibleServicePreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let guide: String
    var path: String { "chat/completions" }
    var initialModel: String { id == "openrouter" ? "openrouter/free" : "" }
    static let all: [Self] = [
        .init(id: "siliconflow", name: "SiliconFlow / 硅基流动", baseURL: "https://api.siliconflow.cn/v1", guide: "https://api-docs.siliconflow.cn/docs/userguide/quickstart"),
        .init(id: "aihubmix", name: "AIHubMix", baseURL: "https://aihubmix.com/v1", guide: "https://aihubmix.com/playground"),
        .init(id: "302", name: "302.AI", baseURL: "https://api.302.ai/v1", guide: "https://doc-en.302.ai/5030894m0"),
        .init(id: "dmx", name: "DMXAPI (.cn)", baseURL: "https://www.dmxapi.cn/v1", guide: "https://doc.dmxapi.com/baseurl.html"),
        .init(id: "apiyi", name: "APIYI / API易", baseURL: "https://api.apiyi.com/v1", guide: "https://index.apiyi.com/quick-start"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", guide: "https://openrouter.ai/docs/quickstart"),
        .init(id: "together", name: "Together AI", baseURL: "https://api.together.ai/v1", guide: "https://docs.together.ai/docs/openai-api-compatibility")
    ]
    static func matching(baseURL: String, path: String) -> Self? {
        all.first { $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) && $0.path == path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    }
}

struct OnboardingCompatibleConnection: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var baseURL = ""
    @State private var path = ""
    @State private var model = ""
    @State private var error = ""
    @State private var presetID = "custom"
    @FocusState private var addressFocused: Bool
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var changed: Bool {
        baseURL != coordinator.settings.compatibleBaseURL || path != coordinator.settings.compatiblePath || model != coordinator.settings.compatibleModel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(b("Connection preset", "平台预设"), selection: $presetID) {
                    Text(b("Custom", "手动填写")).tag("custom")
                    ForEach(CompatibleServicePreset.all) { preset in Text(preset.name).tag(preset.id) }
                }.frame(maxWidth: 320).accessibilityIdentifier("compatible-service-preset")
                if let preset = CompatibleServicePreset.all.first(where: { $0.id == presetID }), let url = URL(string: preset.guide) {
                    Link(b("Setup & model IDs", "接入指南与模型 ID"), destination: url).font(.caption)
                }
            }
            .onChange(of: presetID) { _, id in
                guard let preset = CompatibleServicePreset.all.first(where: { $0.id == id }),
                      CompatibleServicePreset.matching(baseURL: baseURL, path: path)?.id != id else { return }
                baseURL = preset.baseURL
                path = preset.path
                model = preset.initialModel
                error = ""
            }
            Text(b("Choose a preset, enter a model ID from that platform, then save and add its API key.", "选择预设，填写该平台的模型 ID，保存后配置该平台的 API Key。"))
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(b("API Base URL", "API 基础地址"))
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .focused($addressFocused).accessibilityIdentifier("onboarding-compatible-base")
                }
                GridRow {
                    Text(b("API path", "接口路径"))
                    TextField("chat/completions", text: $path).accessibilityIdentifier("onboarding-compatible-path")
                }
                GridRow {
                    Text("API Model ID")
                    TextField(b("Exact model ID from your provider", "服务商提供的完整模型 ID"), text: $model)
                        .accessibilityIdentifier("onboarding-analysis-model")
                }
            }.font(.system(size: 12)).textFieldStyle(.roundedBorder)
            Text(b("Base URL and path are joined. Include /v1 once. Streaming responses and Bearer API keys are required.", "基础地址与接口路径会拼接，请只填写一次 /v1。接口需支持流式回答与 Bearer API Key。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(b("Save connection", "保存连接")) { save() }
                    .disabled(!changed && !coordinator.settings.compatibleModel.isEmpty)
                    .accessibilityIdentifier("onboarding-save-compatible")
                Text(changed ? b("Save changes before testing", "保存修改后再测试") :
                    coordinator.settings.compatibleBaseURL.isEmpty ? b("Enter your service address first", "请先填写服务地址") :
                    b("Saved · configure the API key below", "已保存 · 可在下方配置 API Key"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(LC.danger).fixedSize(horizontal: false, vertical: true) }
        }.onAppear {
            baseURL = coordinator.settings.compatibleBaseURL
            path = coordinator.settings.compatiblePath
            model = coordinator.settings.compatibleModel
            presetID = CompatibleServicePreset.matching(baseURL: baseURL, path: path)?.id ?? "custom"
        }.onReceive(NotificationCenter.default.publisher(for: .onboardingFocusCredential)) { _ in
            if (try? coordinator.settings.compatibleEndpoint()) == nil { addressFocused = true }
        }
    }
    private func save() {
        do {
            _ = try ServiceEndpoint.make(baseURL: baseURL, path: path)
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CopilotError.message("Enter an analysis model name in Services.")
            }
            var settings = coordinator.settings
            baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.compatibleBaseURL = baseURL
            settings.compatiblePath = path
            settings.compatibleModel = model
            coordinator.settings = settings
            error = ""
        } catch { self.error = L10n.text(error.localizedDescription, language: coordinator.settings.language) }
    }
}
