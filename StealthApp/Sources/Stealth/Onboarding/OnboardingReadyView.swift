import SwiftUI
import AVFoundation

struct OnboardingReadyView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var permissions: OnboardingPermissions
    @ObservedObject private var models: LocalModelManager
    @ObservedObject private var apple: AppleSpeechManager
    @ObservedObject private var laya: LayaRuntimeManager
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
        if coordinator.currentSpeechRuntime == .failed || coordinator.currentSpeechRuntime == .loading { return false }
        switch coordinator.settings.listeningService {
        case .zipformer: return models.installed.contains(.terminologySpeech)
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
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(b("Readiness", "准备情况")).font(.headline)
                    readiness
                    Divider()
                    OnboardingPracticeView(coordinator: coordinator, question: $practiceQuestion,
                                           answer: $practiceAnswer, error: $practiceError)
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("onboarding-ready-content")
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
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                let typing = store.state.prefersTyping
                let setup = OnboardingSetupSnapshot(coordinator)
                let optional = b("Not needed for manual input", "手动输入无需配置")
                statusRow(b("Speech transcription", "语音转写"), detail: typing ? optional : speechDetail, ready: !typing && speechReady, step: .models)
                Divider()
                statusRow(b("Audio permissions", "音频权限"), detail: typing ? optional : audioDetail, ready: !typing && permissionsReady, step: .introduction)
                Divider()
                statusRow(b("Answer service", "回答服务"), detail: answerDetail, ready: coordinator.isAnalysisConnectionVerified, step: .analysis)
                Divider()
                let knowledge = setup[.knowledge]
                statusRow(b("Knowledge retrieval", "资料检索"), detail: knowledge.enabled ? knowledgeDetail : b("Not enabled", "未启用"),
                          ready: knowledge.status == .ready, step: .models)
                Divider()
                let jev = setup[.proactive]
                let jevDetail = coordinator.settings.automaticSuggestions
                    ? b("Enabled for voice", "语音模式已启用") + " · " + (typing ? optional : jev.status.title(coordinator.settings.language))
                    : b("Off · you can ask manually", "未启用 · 可手动提问")
                statusRow("Jev Mode", detail: jevDetail, ready: jev.status == .ready,
                          step: coordinator.settings.automaticSuggestions && !typing ? .models : .workflow)
            }.padding(.horizontal, 16).background(LC.surface, in: RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous).strokeBorder(LC.hairline))
            HStack(spacing: 12) {
                if OnboardingDownloads.hasPending(coordinator) {
                    Button(b("Download selected models", "下载所选模型")) { OnboardingDownloads.start(coordinator) }
                        .disabled(coordinator.isMock || coordinator.isRunning || coordinator.isTransitioning || coordinator.isIndexing)
                        .accessibilityIdentifier("onboarding-download-pending")
                        .help(b("Continue using the app while downloads finish.", "后台下载，进入悬浮窗后会继续。"))
                }
                if !store.state.prefersTyping {
                    Button(coordinator.isMock ? b("Try sample captions", "体验示例字幕") : b("Start listening", "开始监听")) { store.complete(); beginListening() }
                        .disabled((!coordinator.isMock && (!speechReady || !permissionsReady)) || coordinator.isRunning || coordinator.isTransitioning)
                        .accessibilityIdentifier("onboarding-start-listening")
                }
                Spacer(minLength: 0)
            }
            if !store.state.prefersTyping {
                Text(coordinator.isMock ? b("Shows sample captions without recording or connecting to a service.", "显示示例字幕，不录音，也不连接真实服务。") : coordinator.settings.listeningService.isLocal
                     ? b("Starts real audio capture. If Jev Mode is on, complete questions can trigger paid answer requests.", "点击后开始采集音频；开启 Jev Mode 时，完整问题可能触发付费回答请求。")
                     : b("Starts audio streaming to OpenAI and may incur audio and answer API fees.", "点击后开始将音频发送至 OpenAI，可能产生语音及回答 API 费用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audioDetail: String {
        let mic = coordinator.settings.mode == .remote && !coordinator.micEnabled ? b("Microphone off", "麦克风已关闭") :
            permissions.microphone == .authorized ? b("Microphone allowed", "麦克风已允许") : b("Microphone access needed", "麦克风待授权")
        guard coordinator.settings.mode == .remote else { return mic }
        return mic + " · " + (permissions.screenAudio ? b("System audio allowed", "系统音频已允许") : b("System audio access needed", "系统音频待授权"))
    }
    private var answerDetail: String {
        if coordinator.isMock { return coordinator.isAnalysisConnectionVerified ? b("Preview test passed · no API call", "预览测试通过 · 未调用 API") : b("Preview provider · no real key", "示例服务 · 未使用真实密钥") }
        if coordinator.isAnalysisConnectionVerified { return b("Connection tested successfully this session", "本次运行已通过连接测试") }
        return coordinator.hasAnswerCredential ? b("Key configured · connection not yet tested", "密钥已配置 · 连接尚未测试") : b("Configure a key to generate answers", "配置密钥后可生成回答")
    }
    private var speechDetail: String {
        switch coordinator.currentSpeechRuntime {
        case .ready: return b("Speech recognition verified · ready to use", "语音识别验证通过 · 可以使用")
        case .loading: return b("Verifying model…", "正在验证模型…")
        case .failed: return b("Model verification failed · retry in setup", "模型验证失败 · 可返回配置重试")
        case .idle: break
        }

        if let kind = coordinator.settings.listeningService.localModel, models.failures[kind] != nil {
            return b("Download failed · review and retry", "下载失败 · 可查看并重试")
        }
        if (models.downloading != nil && models.downloading == coordinator.settings.listeningService.localModel) || apple.busy { return b("Downloading · you can continue typing", "下载中 · 可先输入问题") }
        if let kind = coordinator.settings.listeningService.localModel, models.queued.contains(kind) { return b("Queued for download", "等待下载") }
        if speechReady { return coordinator.settings.listeningService.isLocal ? b("Resources installed · start to test", "资源已安装 · 开始使用后验证") : b("Cloud key configured · not yet tested", "云端密钥已配置 · 尚未验证语音") }
        return b("Open setup to prepare speech", "前往配置以准备语音识别")
    }
    private var knowledgeDetail: String {
        if coordinator.settings.embeddingService == .openAI { return b("OpenAI · extracted text goes to the cloud", "OpenAI · 提取文本会发送至云端") }
        if models.installed.contains(.embedding) {
            switch coordinator.currentKnowledgeRuntime {
            case .ready: return b("Self-check passed · import documents in Settings", "自检通过 · 可在设置中导入资料")
            case .loading: return b("Running local model self-check", "正在进行本地模型自检")
            case .failed: return b("Verification failed · retry in Local capabilities", "验证失败 · 可返回本地能力配置重新验证")
            case .idle: return b("Installed · awaiting verification", "已安装，待验证")
            }
        }
        if models.failures[.embedding] != nil { return b("Download failed · review and retry", "下载失败 · 可查看并重试") }
        return models.downloading == .embedding || models.queued.contains(.embedding) ? b("Downloading / queued", "正在下载或等待下载") : b("Local model not downloaded", "本地模型尚未下载")
    }
    private func statusRow(_ title: String, detail: String, ready: Bool, step: OnboardingStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? LC.success : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(b("Review", "查看")) { store.state.step = step }.buttonStyle(.borderless).font(.caption)
        }.padding(.vertical, 7)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(b("Try your first question", "立即试一个问题")).font(.headline)
                AnalysisProviderBrand(service: coordinator.settings.reasoningService, model: coordinator.settings.analysisModel, compact: true)
                Spacer()
            }
            HStack {
                TextField(b("How can I introduce an idea clearly?", "怎样清楚地介绍一个方案？"), text: $question)
                    .textFieldStyle(.roundedBorder).disabled(busy).accessibilityIdentifier("onboarding-practice-question")
                Button(b("Test answer", "测试回答")) { ask() }
                    .disabled(!coordinator.hasAnswerCredential || busy || coordinator.isTransitioning)
                    .accessibilityIdentifier("onboarding-practice-ask")
                if busy { ProgressView().controlSize(.small); Button(b("Cancel", "取消")) { cancel() } }
            }
            Text(coordinator.isMock ? b("Preview response only. No API call is made.", "仅展示示例回答，不调用 API。") : b("Sends only this question; no history or documents. Uses your service's API allowance.", "仅发送本次问题，不附带历史或资料，会产生所选服务的 API 用量。")).font(.caption).foregroundStyle(.secondary)
            if !answer.isEmpty {
                OnboardingResponsePager(text: answer, language: coordinator.settings.language)
                    .frame(height: 170)
                    .accessibilityIdentifier("onboarding-practice-answer")
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(LC.danger).lineLimit(3).help(error) }
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
