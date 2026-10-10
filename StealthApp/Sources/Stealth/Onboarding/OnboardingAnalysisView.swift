import SwiftUI

struct OnboardingAnalysisView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()
    @State private var testing = false
    @State private var succeeded = false
    @State private var message = ""
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning }
    private var shared: Bool { coordinator.settings.reasoningService == .sharedOpenAI }
    private var connectionIdentity: String {
        [coordinator.settings.reasoningService.rawValue, coordinator.settings.analysisModel,
         (try? coordinator.settings.analysisCredentialReference().accountSuffix) ?? "invalid",
         coordinator.settings.reasoningEffort, coordinator.settings.deepSeekEffort,
         coordinator.settings.presetConnection?.thinking.rawValue ?? ""].joined(separator: "|")
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Picker(b("Answer service", "回答服务"), selection: Binding(get: { coordinator.settings.reasoningService }, set: { coordinator.settings.selectAnalysisService($0) })) {
                ForEach(ReasoningService.allCases) { service in
                    Text(L10n.text(service.label, language: coordinator.settings.language)).tag(service)
                }
            }.disabled(locked || testing).accessibilityIdentifier("onboarding-analysis-provider")
            Text(b("Model: ", "模型：") + coordinator.settings.analysisModel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            OnboardingConnectionFields(coordinator: coordinator).id(coordinator.settings.reasoningService)
                .disabled(locked || testing)
            if coordinator.settings.reasoningService == .sharedOpenAI || coordinator.settings.reasoningService == .separateOpenAI {
                OpenAIAnalysisModelHint(settings: $coordinator.settings).disabled(locked || testing)
            }
            AnalysisPerformanceCard(settings: coordinator.settings)
            if (try? coordinator.settings.analysisCredentialReference()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: !shared)
                    .id(connectionIdentity).disabled(locked || testing)
            } else {
                Text(b("Save a valid service address in Advanced settings before entering a key.", "请先在高级设置中保存有效的服务地址，再配置密钥。")).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(b("Test connection", "测试连接")) { test() }
                    .disabled(testing || !coordinator.hasAnswerCredential || locked)
                    .accessibilityIdentifier("onboarding-test-connection")
                if testing {
                    ProgressView().controlSize(.small)
                    Button(b("Cancel", "取消")) { cancelTest() }
                }
            }
            if !message.isEmpty {
                Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout).foregroundStyle(succeeded ? Color.green : Color.secondary).lineLimit(3).help(message)
                    .accessibilityIdentifier("onboarding-connection-result")
            }
            Text(b("Testing sends only a short synthetic question to this service and may incur API charges. No conversation or documents are included.", "测试只向该服务发送一条简短示例问题，可能产生 API 费用，不附带对话或个人资料。")).font(.caption).foregroundStyle(.secondary)
            Text(b("You can continue without a key. Local transcription and the example remain available.", "暂时没有密钥也可以继续。本地转写与示例体验不受影响。")).font(.caption).foregroundStyle(.secondary)
        }.padding(4)
        }
        .onChange(of: connectionIdentity) { _, _ in cancelTest() }
        .onChange(of: coordinator.answerCredentialRevision) { _, _ in cancelTest() }
        .onDisappear { cancelTest() }
    }
    private func cancelTest() {
        testID = UUID(); testTask?.cancel(); testTask = nil
        testing = false; succeeded = false; message = ""
    }
    private func test() {
        cancelTest(); testing = true
        let id = testID
        testTask = Task {
            do {
                try await coordinator.testAnalysisConnection()
                guard !Task.isCancelled, testID == id else { return }
                succeeded = true
                message = coordinator.isMock ? b("Preview test passed · no API call", "预览测试通过 · 未调用 API") : b("Connection verified · the service returned text", "连接测试通过 · 服务已返回文本")
            } catch {
                guard !Task.isCancelled, testID == id else { return }
                message = L10n.text(error.localizedDescription, language: coordinator.settings.language)
            }
            if testID == id { testing = false; testTask = nil }
        }
    }
}

private struct OnboardingConnectionFields: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var model = ""
    @State private var baseURL = ""
    @State private var path = "chat/completions"
    @State private var message = ""
    @State private var expanded = false
    private var service: ReasoningService { coordinator.settings.reasoningService }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        Button(b("Advanced settings…", "高级设置…")) { expanded = true }
            .accessibilityIdentifier("onboarding-advanced-settings")
            .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(b("Connection settings", "连接设置")).font(.title3.bold())
                    Spacer()
                    Button(b("Done", "完成")) { expanded = false }
                }
                TextField(b("Model name", "模型名称"), text: $model).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("onboarding-analysis-model")
                if service.isPreset || service == .compatible {
                    TextField("HTTPS Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("onboarding-analysis-url")
                    if service == .compatible { TextField(b("API path", "API 路径"), text: $path).textFieldStyle(.roundedBorder) }
                    Text(b("Use the address and key for the same provider region. Changing the endpoint does not reuse the previous endpoint's key.", "服务地址与 Key 必须属于同一地域。更换地址不会沿用旧地址的密钥。")).font(.caption).foregroundStyle(.secondary)
                }
                Button(b("Save connection", "保存连接")) { save() }
                    .accessibilityIdentifier("onboarding-save-connection")
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(width: 480)
        }.onAppear {
            model = coordinator.settings.analysisModel
            baseURL = coordinator.settings.presetConnection?.baseURL ?? coordinator.settings.compatibleBaseURL
            path = coordinator.settings.compatiblePath
        }.onChange(of: coordinator.settings.analysisModel) { _, value in
            model = value
        }
    }
    private func save() {
        do {
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
            var settings = coordinator.settings
            settings.selectAnalysisModel(model)
            switch service {
            case .sharedOpenAI, .separateOpenAI, .deepSeek: break
            case .qwen, .glm, .kimi:
                var connection = settings.presetConnection!
                connection.model = model; connection.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                connection.thinking = service.normalizedThinking(connection.thinking, model: model)
                _ = try connection.endpoint(); settings.presetConnection = connection
            case .compatible:
                _ = try ServiceEndpoint.make(baseURL: baseURL, path: path)
                settings.compatibleModel = model
                settings.compatibleBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.compatiblePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            coordinator.settings = settings
            message = b("Connection saved. Test it before your first conversation.", "连接已保存，首次使用前可进行测试。")
        } catch { message = L10n.text(error.localizedDescription, language: coordinator.settings.language) }
    }
}
