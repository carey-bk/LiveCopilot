import SwiftUI
import AVFoundation

struct OnboardingReadyView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var permissions: OnboardingPermissions
    @ObservedObject private var models: LocalModelManager
    @ObservedObject private var apple: AppleSpeechManager
    @ObservedObject private var laya: LayaRuntimeManager
    private enum Panel { case readiness, example, practice }
    @State private var panel = Panel.readiness
    @State private var practiceQuestion = ""
    @State private var practiceAnswer = ""
    @State private var practiceError = ""
    let beginListening: () -> Void
    let beginTyping: () -> Void
    init(coordinator: AppCoordinator, store: OnboardingStore, permissions: OnboardingPermissions,
         beginListening: @escaping () -> Void, beginTyping: @escaping () -> Void) {
        self.coordinator = coordinator; self.store = store; self.permissions = permissions
        models = coordinator.localModels; apple = coordinator.appleSpeech; laya = coordinator.laya
        self.beginListening = beginListening; self.beginTyping = beginTyping
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var speechReady: Bool {
        switch coordinator.settings.listeningService {
        case .paraformer: return models.installed.contains(.streamingSpeech)
        case .apple: return apple.available && apple.installed && !apple.busy
        case .openAI: return coordinator.hasAPIKey && !coordinator.isCheckingKey
        }
    }
    private var permissionsReady: Bool {
        (coordinator.settings.mode == .remote && !coordinator.micEnabled || permissions.microphone == .authorized) &&
        (coordinator.settings.mode == .inPerson || permissions.screenAudio)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(b("First conversation", "首次体验"), selection: $panel) {
                Text(b("Readiness", "准备情况")).tag(Panel.readiness)
                Text(b("Example", "体验示例")).tag(Panel.example)
                Text(b("Try a question", "试问一句")).tag(Panel.practice)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("onboarding-ready-panel")
            Group {
                switch panel {
                case .readiness: readiness
                case .example:
                    OnboardingConversationPreview(language: coordinator.settings.language, scenario: coordinator.settings.scenario)
                case .practice:
                    OnboardingPracticeView(coordinator: coordinator, question: $practiceQuestion,
                                           answer: $practiceAnswer, error: $practiceError)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button(b("Go to the floating window", "前往悬浮窗")) { store.complete(); beginTyping() }
                Spacer()
                Button(b("Show the controls", "认识悬浮窗操作")) {
                    store.replayTips(); store.complete(); beginTyping()
                }.buttonStyle(.borderless).accessibilityIdentifier("onboarding-show-overlay-tips")
            }
        }.padding(4)
    }
    private var readiness: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                if !store.state.prefersTyping {
                    statusRow(b("Speech transcription", "语音转写"), detail: speechDetail, ready: speechReady, step: .models)
                    Divider()
                    statusRow(b("Audio permissions", "音频权限"), detail: permissionsReady ? b("Allowed · start to test audio", "已允许 · 开始使用后验证音频") : b("More access needed for this mode", "当前模式仍需授权"), ready: permissionsReady, step: .permissions)
                    Divider()
                }
                statusRow(b("Answer service", "回答服务"), detail: answerDetail, ready: coordinator.isAnalysisConnectionVerified, step: .analysis)
                if store.state.wantsKnowledge {
                    Divider()
                    statusRow(b("Knowledge retrieval", "资料检索"), detail: knowledgeDetail,
                              ready: coordinator.settings.embeddingService == .local ? models.installed.contains(.embedding) : coordinator.hasAPIKey, step: .models)
                }
                if !store.state.prefersTyping && coordinator.settings.automaticSuggestions && coordinator.settings.listeningService.isLocal {
                    Divider()
                    statusRow("Jev Mode", detail: laya.isReady ? b("Local detection ready", "本地判断已就绪") : laya.isBusy ? b("Preparing · manual replies remain available", "准备中 · 仍可手动触发") : laya.isInstalled ? b("Installed · loads when listening starts", "已安装 · 开始监听时加载") : b("Laya needs setup · use manual replies", "Laya 待配置 · 可手动触发"), ready: laya.isReady, step: .models)
                }
            }.padding(.horizontal, 16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            if !store.state.prefersTyping {
                Button(coordinator.isMock ? b("Try sample captions", "体验示例字幕") : b("Start listening", "开始监听")) { store.complete(); beginListening() }
                    .disabled((!coordinator.isMock && (!speechReady || !permissionsReady)) || coordinator.isRunning || coordinator.isTransitioning)
                    .accessibilityIdentifier("onboarding-start-listening")
                Text(coordinator.isMock ? b("Shows sample captions without recording or connecting to a service.", "显示示例字幕，不录音，也不连接真实服务。") : coordinator.settings.listeningService.isLocal
                     ? b("Starts real audio capture. If Jev Mode is on, complete questions can trigger paid answer requests.", "点击后开始采集音频；开启 Jev Mode 时，完整问题可能触发付费回答请求。")
                     : b("Starts audio streaming to OpenAI and may incur audio and answer API fees.", "点击后开始将音频发送至 OpenAI，可能产生语音及回答 API 费用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var answerDetail: String {
        if coordinator.isMock { return coordinator.isAnalysisConnectionVerified ? b("Preview test passed · no API call", "预览测试通过 · 未调用 API") : b("Preview provider · no real key", "示例服务 · 未使用真实密钥") }
        if coordinator.isAnalysisConnectionVerified { return b("Connection tested successfully this session", "本次运行已通过连接测试") }
        return coordinator.hasAnswerCredential ? b("Key configured · connection not yet tested", "密钥已配置 · 连接尚未测试") : b("Configure a key to generate answers", "配置密钥后可生成回答")
    }
    private var speechDetail: String {
        if models.downloading == .streamingSpeech || apple.busy { return b("Downloading · you can continue typing", "下载中 · 可先输入问题") }
        if models.queued.contains(.streamingSpeech) { return b("Queued for download", "等待下载") }
        if speechReady { return coordinator.settings.listeningService.isLocal ? b("Resources installed · start to test", "资源已安装 · 开始使用后验证") : b("Cloud key configured · not yet tested", "云端密钥已配置 · 尚未验证语音") }
        return b("Open setup to prepare speech", "前往配置以准备语音识别")
    }
    private var knowledgeDetail: String {
        if coordinator.settings.embeddingService == .openAI { return b("OpenAI · extracted text goes to the cloud", "OpenAI · 提取文本会发送至云端") }
        if models.installed.contains(.embedding) { return b("Local model installed · import documents in Settings", "本地模型已安装 · 可在设置中导入资料") }
        return models.downloading == .embedding || models.queued.contains(.embedding) ? b("Downloading / queued", "正在下载或等待下载") : b("Local model not downloaded", "本地模型尚未下载")
    }
    private func statusRow(_ title: String, detail: String, ready: Bool, step: OnboardingStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(b("Review", "查看")) { store.state.step = step }.buttonStyle(.borderless).font(.caption)
        }.padding(.vertical, 12)
    }
}

private struct OnboardingPracticeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var question: String
    @Binding var answer: String
    @Binding var error: String
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var revision = UUID()
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AnalysisProviderBrand(service: coordinator.settings.reasoningService, model: coordinator.settings.analysisModel)
                .padding(.bottom, 8)
            Text(b("Try a question", "试问一句")).font(.headline)
            TextField(b("How can I introduce an idea clearly?", "怎样清楚地介绍一个方案？"), text: $question)
                .textFieldStyle(.roundedBorder).disabled(busy).accessibilityIdentifier("onboarding-practice-question")
            HStack {
                Button(b("Ask this service", "向此服务提问")) { ask() }
                    .disabled(!coordinator.hasAnswerCredential || busy || coordinator.isTransitioning)
                    .accessibilityIdentifier("onboarding-practice-ask")
                if busy { ProgressView().controlSize(.small); Button(b("Cancel", "取消")) { cancel() } }
            }
            Text(coordinator.isMock ? b("Preview response only. No API call is made.", "仅展示示例回答，不调用 API。") : b("Sends only this question; no history or documents. Uses your service's API allowance.", "仅发送本次问题，不附带历史或资料，会产生所选服务的 API 用量。")).font(.caption).foregroundStyle(.secondary)
            if !answer.isEmpty {
                OnboardingResponsePager(text: answer, language: coordinator.settings.language)
                    .accessibilityIdentifier("onboarding-practice-answer")
            } else {
                Text(error.isEmpty ? b("Your answer will appear here.", "回答会出现在这里。") : error)
                    .font(.callout).foregroundStyle(error.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(6).help(error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !answer.isEmpty && !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error) }
        }.onDisappear { cancel() }
    }
    private func cancel() { revision = UUID(); task?.cancel(); task = nil; busy = false }
    private func ask() {
        cancel(); answer = ""; error = ""; busy = true
        let id = revision
        let input = question.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            do {
                let stream = try coordinator.onboardingAnswer(input.isEmpty ? b("How can I introduce an idea clearly?", "怎样清楚地介绍一个方案？") : input)
                for try await delta in stream {
                    guard !Task.isCancelled, id == revision else { return }
                    answer += delta
                }
            } catch {
                guard !Task.isCancelled, id == revision else { return }
                self.error = L10n.text(error.localizedDescription, language: coordinator.settings.language)
            }
            if id == revision { busy = false; task = nil }
        }
    }
}
