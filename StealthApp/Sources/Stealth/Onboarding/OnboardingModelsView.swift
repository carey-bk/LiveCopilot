import SwiftUI

@MainActor enum OnboardingDownloads {
    static func localKinds(_ coordinator: AppCoordinator) -> [LocalModelKind] {
        var kinds: [LocalModelKind] = []
        if !coordinator.onboarding.state.prefersTyping, let kind = coordinator.settings.listeningService.localModel { kinds.append(kind) }
        if coordinator.onboarding.state.wantsKnowledge && coordinator.settings.embeddingService == .local { kinds.append(.embedding) }
        return kinds.filter { !coordinator.localModels.installed.contains($0) && coordinator.localModels.downloading != $0 && !coordinator.localModels.queued.contains($0) }
    }
    static func needsApple(_ coordinator: AppCoordinator) -> Bool {
        !coordinator.onboarding.state.prefersTyping && coordinator.settings.listeningService == .apple &&
        coordinator.appleSpeech.available && !coordinator.appleSpeech.installed && !coordinator.appleSpeech.busy
    }
    static func needsLaya(_ coordinator: AppCoordinator) -> Bool {
        !coordinator.onboarding.state.prefersTyping && coordinator.settings.listeningService.isLocal &&
        coordinator.settings.automaticSuggestions && coordinator.laya.state != .unsupported && !coordinator.laya.isReady && !coordinator.laya.isBusy
    }
    static func hasPending(_ coordinator: AppCoordinator) -> Bool {
        !localKinds(coordinator).isEmpty || needsApple(coordinator) || needsLaya(coordinator)
    }
    static func start(_ coordinator: AppCoordinator) {
        guard !coordinator.isMock, !coordinator.isRunning, !coordinator.isTransitioning, !coordinator.isIndexing else { return }
        coordinator.localModels.enqueue(localKinds(coordinator))
        if needsApple(coordinator) { coordinator.appleSpeech.install(coordinator.settings.appleSpeechLanguage) }
        if needsLaya(coordinator) {
            if coordinator.laya.isInstalled { coordinator.laya.prepare() } else { coordinator.laya.install() }
        }
    }
}

struct OnboardingModelsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject private var models: LocalModelManager
    @ObservedObject private var apple: AppleSpeechManager
    @ObservedObject private var laya: LayaRuntimeManager
    @State private var showingCloudKey = false
    init(coordinator: AppCoordinator, store: OnboardingStore) {
        self.coordinator = coordinator; self.store = store
        models = coordinator.localModels; apple = coordinator.appleSpeech; laya = coordinator.laya
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning || coordinator.isIndexing }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.state.prefersTyping { speechSection }
            HStack(alignment: .top, spacing: 22) {
                knowledgeSection.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                if !store.state.prefersTyping {
                    Divider()
                    jevSection.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
            }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                if let freeSpace {
                    Label(b("Available on this Mac: ", "本机可用空间：") + freeSpace, systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                }
                if !OnboardingDownloads.localKinds(coordinator).isEmpty {
                    Text(b("Additional model downloads: about ", "新增模型下载：约 ") + ByteCountFormatter.string(fromByteCount: additionalBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if OnboardingDownloads.needsApple(coordinator) || OnboardingDownloads.needsLaya(coordinator) {
                    Text(b("Apple language assets and the Laya runtime are additional; their total size is not available here.", "Apple 语言资源与 Laya 运行环境另计，此处无法确定它们的总大小。")).font(.caption).foregroundStyle(.secondary)
                }
                Text(b("Local models need download and installation space. You can skip downloads and return later.", "本地模型需要下载及安装空间，可以跳过下载，之后再配置。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(4)
        .popover(isPresented: $showingCloudKey) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(b("OpenAI key", "OpenAI 密钥")).font(.title3.bold())
                    Spacer()
                    Button(b("Done", "完成")) { showingCloudKey = false }
                }
                CredentialEditor(coordinator: coordinator, analysis: false)
            }.padding(24).frame(width: 480)
        }
    }
    private var cloudKeyButton: some View {
        Button(b("Configure OpenAI key", "配置 OpenAI 密钥")) { showingCloudKey = true }
            .disabled(locked).accessibilityIdentifier("onboarding-cloud-key")
    }
    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(b("Live transcription", "实时转写"), systemImage: "waveform").font(.headline)
            Picker(b("Speech service", "识别方式"), selection: $coordinator.settings.listeningService) {
                Text(b("Paraformer · Chinese + English", "Paraformer · 本地中英双语")).tag(ListeningService.paraformer)
                Text(b("Apple · one language, on-device", "Apple · 本机单语言")).tag(ListeningService.apple).disabled(!apple.available)
                Text(b("OpenAI · cloud audio", "OpenAI · 云端识别")).tag(ListeningService.openAI)
            }.disabled(locked || apple.busy || models.downloading != nil || laya.isBusy)
                .accessibilityIdentifier("onboarding-speech-provider")
            SpeechSelectionGuide(language: coordinator.settings.language)
            switch coordinator.settings.listeningService {
            case .paraformer:
                modelStatus(.streamingSpeech)
                Text(b("Recognition language: Chinese + English · automatic", "识别语言：中英混合 · 自动识别")).font(.callout)
                Text(b("Paraformer + VAD · about 238 MB. Speech stays on this Mac.", "Paraformer + VAD · 约 238 MB。语音在本机处理。")).font(.caption).foregroundStyle(.secondary)
                Text(b("For English-heavy speech or specialist terms, compare Apple English or OpenAI on your own audio.", "英文为主或专业术语较多时，建议用自己的音频对比 Apple 英语或 OpenAI 的转写效果。")).font(.caption).foregroundStyle(.secondary)
            case .apple:
                AppleSpeechCard(manager: apple, language: $coordinator.settings.appleSpeechLanguage,
                                interfaceLanguage: coordinator.settings.language, locked: locked, permitsDownload: !coordinator.isMock)
            case .openAI:
                LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage,
                                         interfaceLanguage: coordinator.settings.language).disabled(locked)
                Text(b("Audio is sent to OpenAI. Requires its API key and incurs audio usage fees.", "音频发送至 OpenAI，需要对应 API Key，并产生语音 API 用量费用。")).font(.caption).foregroundStyle(.secondary)
                cloudKeyButton
            }
            if !apple.available { Text(b("Apple speech is unavailable on this Mac; it requires macOS 26 and supported hardware.", "此 Mac 暂不支持 Apple 识别；需要 macOS 26 及受支持硬件。")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(b("Use my documents for answers", "用自己的资料辅助回答"), isOn: $store.state.wantsKnowledge)
                .font(.headline).disabled(locked).accessibilityIdentifier("onboarding-knowledge")
            Text(b("Optional. Import documents later from Settings → Knowledge.", "可选，之后从“设置 → 知识库”导入资料。")).font(.caption).foregroundStyle(.secondary)
            if store.state.wantsKnowledge {
                Picker(b("Knowledge service", "资料处理方式"), selection: $coordinator.settings.embeddingService) {
                    Text(b("Local · BGE-M3", "本地 · BGE-M3")).tag(EmbeddingService.local)
                    Text("OpenAI Embeddings").tag(EmbeddingService.openAI)
                }.disabled(locked || models.downloading != nil)
                if coordinator.settings.embeddingService == .local {
                    modelStatus(.embedding)
                    Text(b("About 635 MB. Embeddings and retrieval stay on this Mac.", "约 635 MB。向量生成与检索在本机完成。")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(b("Indexing sends extracted text to OpenAI and uses its API key.", "生成索引时会将提取文本发送至 OpenAI，并使用其 API Key。")).font(.caption).foregroundStyle(.secondary)
                    cloudKeyButton
                }
            }
        }
    }
    private var jevSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $coordinator.settings.automaticSuggestions) {
                HStack(spacing: 8) {
                    Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 18))
                    if laya.state != .unsupported {
                        Text(b("Recommended", "推荐")).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                    }
                }
            }.font(.headline).disabled(locked || laya.isBusy || (coordinator.settings.listeningService.isLocal && laya.state == .unsupported))
                .accessibilityLabel("Jev Mode")
                .accessibilityIdentifier("onboarding-jev")
            Text(b("Recognize complete questions and request suggestions automatically. This does not generate answers locally.", "判断问题是否完整，并自动请求建议。这项能力不在本地生成回答。")).font(.caption).foregroundStyle(.secondary)
            if coordinator.settings.listeningService.isLocal {
                Text(layaStatus).font(.callout).foregroundStyle(laya.isReady ? Color.green : Color.secondary)
                if coordinator.settings.automaticSuggestions {
                    Text(b("Laya includes its runtime. Download size varies; progress shows actual transferred bytes.", "Laya 包含运行环境，下载大小以实际传输为准。")).font(.caption).foregroundStyle(.secondary)
                }
                if laya.isBusy {
                    if let progress = laya.transferProgress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                    Text(laya.transferStatus.isEmpty ? L10n.text(laya.message, language: coordinator.settings.language) : laya.transferStatus)
                        .font(.caption).lineLimit(2).textSelection(.enabled)
                    Button(b("Cancel preparation", "取消准备")) { coordinator.cancelLayaRuntime() }
                } else if laya.state == .failed {
                    Text(L10n.text(laya.message, language: coordinator.settings.language)).font(.caption).foregroundStyle(.red).lineLimit(2).help(laya.message)
                    Button(b("Retry", "重试")) { if laya.isInstalled { laya.prepare() } else { laya.install() } }.disabled(locked || coordinator.isMock)
                }
            } else {
                Text(b("The cloud speech service handles question detection; no Laya download is needed.", "由云端语音服务判断完整问题，无需下载 Laya。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var additionalBytes: Int64 { OnboardingDownloads.localKinds(coordinator).reduce(0) { $0 + $1.estimatedDownloadBytes } }
    @ViewBuilder private func modelStatus(_ kind: LocalModelKind) -> some View {
        if models.installed.contains(kind) {
            Label(b("Installed · reused", "已安装 · 直接复用"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        } else if models.downloading == kind {
            if let progress = models.downloadProgress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
            Text(L10n.text(models.message, language: coordinator.settings.language)).font(.caption).lineLimit(2).help(models.message)
            if !models.transferStatus.isEmpty { Text(models.transferStatus).font(.caption).monospacedDigit() }
            Button(b("Cancel downloads", "取消下载")) { models.cancel() }
        } else if models.queued.contains(kind) {
            Label(b("Queued", "等待下载"), systemImage: "clock").font(.callout).foregroundStyle(.secondary)
        } else {
            Label(b("Not downloaded", "尚未下载"), systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
            if let failure = models.failures[kind] {
                Text(L10n.text(failure, language: coordinator.settings.language)).font(.caption).foregroundStyle(.red).lineLimit(2).help(failure)
                Button(b("Retry download", "重试下载")) { models.enqueue([kind]) }.disabled(locked || coordinator.isMock)
            }
        }
    }
    private var layaStatus: String {
        switch laya.state {
        case .unsupported: return b("Requires Apple Silicon and macOS 14+. Manual replies remain available.", "需要 Apple Silicon 与 macOS 14+，仍可手动生成回答。")
        case .notInstalled: return b("Laya not downloaded", "Laya 尚未下载")
        case .installed: return b("Laya installed · load to verify", "Laya 已安装 · 待加载验证")
        case .installing: return b("Downloading and installing Laya…", "正在下载并安装 Laya…")
        case .loading: return b("Loading Laya…", "正在加载 Laya…")
        case .ready: return b("Laya ready · local", "Laya 已就绪 · 本地")
        case .failed: return b("Laya needs attention", "Laya 需要处理")
        }
    }
    private var freeSpace: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
