import SwiftUI

@MainActor enum OnboardingDownloads {
    static func localKinds(_ coordinator: AppCoordinator) -> [LocalModelKind] {
        OnboardingSetupSnapshot(coordinator).resources.compactMap {
            if case .local(let kind) = $0.kind, $0.needsStart { return kind }; return nil
        }
    }
    static func needsApple(_ coordinator: AppCoordinator) -> Bool {
        OnboardingSetupSnapshot(coordinator).resources.contains { if case .apple = $0.kind { return $0.needsStart }; return false }
    }
    static func needsLaya(_ coordinator: AppCoordinator) -> Bool {
        let setup = OnboardingSetupSnapshot(coordinator)
        return setup.needsLayaLoad || setup.resources.contains { $0.kind == .laya && $0.needsStart }
    }
    static func hasPending(_ coordinator: AppCoordinator) -> Bool {
        let setup = OnboardingSetupSnapshot(coordinator)
        return setup.needsDownload || setup.needsLayaLoad
    }
    static func requiresDownload(_ coordinator: AppCoordinator) -> Bool { OnboardingSetupSnapshot(coordinator).needsDownload }
    static func start(_ coordinator: AppCoordinator) {
        guard !coordinator.isMock, !coordinator.isRunning, !coordinator.isTransitioning, !coordinator.isIndexing else { return }
        // Take one immutable plan for this click; downloads may synchronously publish new state.
        let setup = OnboardingSetupSnapshot(coordinator)
        coordinator.localModels.enqueue(setup.resources.compactMap {
            if case .local(let kind) = $0.kind, $0.needsStart { return kind }; return nil
        })
        for resource in setup.resources where resource.needsStart {
            switch resource.kind {
            case .local: break
            case .apple(let language): coordinator.appleSpeech.install(language)
            case .laya: coordinator.laya.install()
            }
        }
        if setup.needsLayaLoad { coordinator.laya.prepare() }
    }
    static func skip(_ coordinator: AppCoordinator) {
        // Keep explicit choices and existing background transfers. No hidden download or fallback.
        coordinator.onboarding.state.advance()
    }
}

struct OnboardingModelsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject private var models: LocalModelManager
    @ObservedObject private var apple: AppleSpeechManager
    @ObservedObject private var laya: LayaRuntimeManager
    @State private var preparingRecommendation = false
    @State private var detail: Capability?
    @State private var showingCloudKey = false
    private enum Capability: String, Identifiable { case speech, knowledge, jev; var id: String { rawValue } }
    init(coordinator: AppCoordinator, store: OnboardingStore) {
        self.coordinator = coordinator; self.store = store
        models = coordinator.localModels; apple = coordinator.appleSpeech; laya = coordinator.laya
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var setup: OnboardingSetupSnapshot { .init(coordinator) }
    private var editable: Bool { OnboardingRecommendation.canEdit(coordinator) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning || coordinator.isIndexing }
    var body: some View {
        VStack(spacing: 8) {
            OnboardingRecommendationView(coordinator: coordinator)
            capabilityCard(.speech, title: b("Live transcription", "实时转写"), icon: "waveform", status: setup[.speech].status) {
                if store.state.prefersTyping {
                    HStack { Text(speechName); Spacer(); speechLanguage.disabled(true) }
                } else {
                    HStack(spacing: 8) {
                        Text(speechName).fontWeight(.medium)
                        Spacer(minLength: 4)
                        if coordinator.settings.listeningService == .openAI { cloudKeyButton }
                        speechLanguage
                    }.id(coordinator.settings.listeningService).transition(.opacity)
                }
                if let kind = coordinator.settings.listeningService.localModel, models.installed.contains(kind) {
                    HStack(spacing: 8) {
                        if coordinator.currentSpeechRuntime == .loading {
                            ProgressView().controlSize(.small)
                            Text(b("Verifying model…", "正在验证模型…"))
                        } else {
                            Button(coordinator.currentSpeechRuntime == .failed ? b("Retry verification", "重新验证") : b("Verify model", "验证模型")) {
                                coordinator.verifyOnboardingSpeech()
                            }.disabled(locked).accessibilityIdentifier("onboarding-verify-speech")
                            Text(b("Loads locally; no recording.", "仅加载本地模型，不录音。"))
                                .foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                    if coordinator.currentSpeechRuntime == .failed, let error = coordinator.speechVerificationError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                    }
                }
            }
            capabilityCard(.knowledge, title: b("Knowledge retrieval", "知识库检索"), icon: "books.vertical", status: setup[.knowledge].status) {
                Text(setup[.knowledge].model + " · " + (store.state.wantsKnowledge ? b("Enabled", "已启用") : b("Not enabled", "未启用")))
                if store.state.wantsKnowledge && coordinator.settings.embeddingService == .local {
                    Text(b("Recommended · indexes documents locally, free of API charges and keys.", "推荐本地 \(LocalModelKind.embeddingName)：为文档建索引、检索相关片段，免费且无需 API Key。")).font(.caption)
                }
            }
            capabilityCard(.jev, title: "Jev Mode", icon: "bolt", status: setup[.proactive].status) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(b("Automatic question recognition", "自动识别提问") + " · " + (coordinator.settings.listeningService.isLocal ? "Laya" : "GPT-Live") + (coordinator.settings.automaticSuggestions ? b(" · Enabled", " · 已启用") : ""))
                    Text(store.state.prefersTyping ? (coordinator.settings.automaticSuggestions
                         ? b("Enabled for voice. Typed questions are submitted manually.", "语音模式已启用；手动输入时直接提交问题。")
                         : b("Off. Typed questions are submitted manually.", "未启用；手动输入时直接提交问题。"))
                         : b("Detects complete questions and can trigger answer suggestions.", "用于判断提问是否完整，并在合适时机触发回答建议。"))
                    if coordinator.settings.automaticSuggestions && coordinator.settings.listeningService.isLocal {
                        if laya.state == .loading {
                            HStack { ProgressView().controlSize(.small); Text(b("Verifying Jev Mode…", "正在验证 Jev Mode…")) }.font(.caption)
                        } else if laya.state == .failed {
                            HStack {
                                Button(b("Retry verification", "重新验证")) { laya.prepare() }
                                    .disabled(!laya.isInstalled || locked).accessibilityIdentifier("onboarding-retry-jev")
                                Button(b("Error details", "查看错误")) { detail = .jev }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            OnboardingDownloadSummary(setup: setup, language: coordinator.settings.language)
                .frame(height: 84, alignment: .topLeading)
        }.frame(maxHeight: .infinity, alignment: .top)
        .contentTransition(.opacity)
        .disabled(preparingRecommendation)
        .task {
            if store.state.localSetupReviewed == false {
                preparingRecommendation = true
                defer { preparingRecommendation = false }
                await apple.refresh(coordinator.settings.appleSpeechLanguage)
                guard !Task.isCancelled else { return }
                OnboardingRecommendation.applyInitialIfNeeded(coordinator)
            }
            coordinator.prepareOnboardingLayaIfNeeded()
            verifyInstalledSpeechIfNeeded()
        }
        .task(id: store.state.wantsKnowledge && coordinator.settings.embeddingService == .local && models.downloading == nil) {
            if store.state.wantsKnowledge && coordinator.settings.embeddingService == .local && models.downloading == nil {
                await models.verifyEmbeddingIfNeeded()
            }
        }
        .onChange(of: models.installed) { _, _ in verifyInstalledSpeechIfNeeded() }
        .onChange(of: models.downloading) { _, _ in verifyInstalledSpeechIfNeeded() }
        .onChange(of: coordinator.settings.listeningService) { _, _ in verifyInstalledSpeechIfNeeded() }
        .popover(item: $detail) { selected in
            OnboardingAdvancedPanel(title: detailTitle(selected), icon: detailIcon(selected), language: coordinator.settings.language, close: { detail = nil }) {
                switch selected {
                case .speech: speechDetails
                case .knowledge: knowledgeDetails
                case .jev: jevDetails
                }
            }
        }
        .popover(isPresented: $showingCloudKey) {
            OnboardingAdvancedPanel(title: b("OpenAI key", "OpenAI 密钥"), icon: "key.horizontal", language: coordinator.settings.language, close: { showingCloudKey = false }) {
                CredentialEditor(coordinator: coordinator, analysis: false, liveLayout: true)
            }
        }
    }
    private func verifyInstalledSpeechIfNeeded() {
        guard !preparingRecommendation, !store.state.prefersTyping,
              let kind = coordinator.settings.listeningService.localModel,
              models.downloading != kind, models.installed.contains(kind),
              coordinator.currentSpeechRuntime == .idle else { return }
        coordinator.verifyOnboardingSpeech()
    }
    private func detailTitle(_ detail: Capability) -> String {
        switch detail { case .speech: return b("Live transcription", "实时转写"); case .knowledge: return b("Knowledge retrieval", "知识库检索"); case .jev: return "Jev Mode" }
    }
    private func detailIcon(_ detail: Capability) -> String {
        switch detail { case .speech: return "waveform"; case .knowledge: return "books.vertical"; case .jev: return "bolt" }
    }
    private func capabilityCard<Content: View>(_ capability: Capability, title: String, icon: String,
                                                status: OnboardingCapabilityStatus, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
                OnboardingCapabilityBadge(status: status, language: coordinator.settings.language)
                Spacer(minLength: 4)
                Button(b("Advanced", "高级设置")) { detail = capability }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    .disabled(store.state.prefersTyping && capability != .knowledge)
                    .accessibilityLabel(title + b(" advanced settings", "高级设置"))
                    .accessibilityIdentifier("onboarding-advanced-" + capability.rawValue)
            }
            content().font(.system(size: 12)).foregroundStyle(.secondary).controlSize(.small)
        }.padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity).frame(minHeight: capability == .speech ? 72 : 86, alignment: .topLeading)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055)))
    }
    private var speechName: String {
        switch coordinator.settings.listeningService {
        case .zipformer: return b("Zipformer · local", "Zipformer · 本地")
        case .paraformer: return b("Paraformer · local", "Paraformer · 本地")
        case .apple: return b("Apple · on-device", "Apple · 本机")
        case .openAI: return b("OpenAI · cloud", "OpenAI · 云端（按用量计费）")
        }
    }
    @ViewBuilder private var speechLanguage: some View {
        switch coordinator.settings.listeningService {
        case .paraformer, .zipformer:
            Text(b("Chinese + English · Auto", "中英混合 · 自动识别"))
                .help(b("Recognition language", "识别语言"))
        case .apple:
            Picker(b("Language", "识别语言"), selection: $coordinator.settings.appleSpeechLanguage) {
                Text(b("Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                Text(b("English", "英语")).tag(AppleSpeechLanguage.english)
            }.fixedSize().disabled(!editable).accessibilityIdentifier("onboarding-recognition-language")
        case .openAI:
            LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage,
                                     interfaceLanguage: coordinator.settings.language, compact: true).fixedSize().disabled(!editable)
        }
    }
    private var cloudKeyButton: some View {
        Button(b("Configure OpenAI key", "配置 OpenAI 密钥")) { detail = nil; showingCloudKey = true }
            .disabled(locked).accessibilityIdentifier("onboarding-cloud-key")
    }
    private var speechDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(b("Speech service", "识别方式"), selection: Binding(get: { coordinator.settings.listeningService }, set: {
                OnboardingRecommendation.selectSpeech($0, coordinator: coordinator)
            })) {
                Text(b("Zipformer · Local Chinese + English · Terminology", "Zipformer · 本地中英双语 · 术语增强")).tag(ListeningService.zipformer)
                Text(b("Paraformer · Local Chinese + English", "Paraformer · 本地中英双语")).tag(ListeningService.paraformer)
                Text(b("Apple · one language, on-device", "Apple · 本机单语言")).tag(ListeningService.apple).disabled(!apple.available)
                Text(b("OpenAI · cloud audio", "OpenAI · 云端识别")).tag(ListeningService.openAI)
            }.disabled(!editable).accessibilityIdentifier("onboarding-speech-provider")
            switch coordinator.settings.listeningService {
            case .zipformer:
                note(b("Local Chinese/English recognition with terminology enhancement.", "本地中英双语识别，支持术语增强。"))
                modelStatus(.terminologySpeech)
            case .paraformer:
                note(b("Chinese and English are recognized automatically on this Mac.", "在本机自动识别中文、英文及中英混合语音。"))
                modelStatus(.streamingSpeech)
            case .apple:
                speechLanguage
                note(b("Uses one recognition language. For mixed Chinese/English, choose Zipformer.", "使用单一识别语言；中英混合请选 Zipformer。"))
                OnboardingCapabilityBadge(status: setup[.speech].status, language: coordinator.settings.language)
                if apple.busy {
                    ProgressView().controlSize(.small)
                    Button(b("Cancel download", "取消下载")) { apple.cancel() }
                } else {
                    HStack {
                        if apple.checkedLanguage == coordinator.settings.appleSpeechLanguage && !apple.installed {
                            Button(b("Download language", "下载语言资源")) { apple.install(coordinator.settings.appleSpeechLanguage) }
                                .disabled(!editable || !apple.available || coordinator.isMock)
                        }
                        Button(b("Refresh status", "刷新状态")) { Task { await apple.refresh(coordinator.settings.appleSpeechLanguage) } }
                    }
                }
                if apple.failedLanguage == coordinator.settings.appleSpeechLanguage {
                    note(b("Language download failed. Retry when the network is available.", "语言资源下载失败，请检查网络后重试。"))
                }
            case .openAI:
                LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage, interfaceLanguage: coordinator.settings.language).disabled(!editable)
                note(b("Audio is sent to OpenAI. An API key and audio usage fees are required.", "音频发送至 OpenAI，需要对应 API Key，并产生语音 API 费用。"))
                cloudKeyButton
            }
            DisclosureGroup(b("Choosing an engine", "如何选择引擎")) {
                SpeechSelectionGuide(language: coordinator.settings.language).padding(.top, 8)
            }
            if !editable { note(b("Finish or cancel preparation before changing services.", "准备期间暂不可切换服务，请等待完成或取消任务。")) }
        }
    }
    private var knowledgeDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            note(b("The index finds relevant passages in your documents. Configure the answer model in Analysis & answers.", "索引模型用来从文档中找到相关片段。生成回答的模型请在「分析与回答」中配置。"))
            if store.state.wantsKnowledge {
                Picker(b("Knowledge index model", "知识库索引模型"), selection: $coordinator.settings.embeddingService) {
                    Text(b("\(LocalModelKind.embeddingName) (local, recommended)", "\(LocalModelKind.embeddingName)（本地，推荐）")).tag(EmbeddingService.local)
                    Text(b("OpenAI index model (remote)", "OpenAI 索引模型（远程）")).tag(EmbeddingService.openAI)
                }.disabled(!editable)
                if coordinator.settings.embeddingService == .local {
                    modelStatus(.embedding)
                    if case .failed = models.embeddingVerification {
                        Button(b("Retry verification", "重新验证")) { Task { await models.verifyEmbedding() } }
                    }
                    note(b("Embeddings and retrieval run on this Mac.", "向量生成与检索在本机完成。"))
                } else {
                    note(b("Indexing sends extracted document text to OpenAI and incurs API fees.", "生成索引时会将资料文本发送至 OpenAI，并产生 API 费用。"))
                    cloudKeyButton
                }
            }
        }
    }
    private var jevDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            note(b("Detects complete questions and requests your answer service. Manual replies remain available; answer generation may incur API fees.", "识别完整问题后请求回答服务，仍可随时手动触发。生成回答可能产生 API 费用。"))
            if coordinator.settings.listeningService.isLocal {
                OnboardingCapabilityBadge(status: setup[.proactive].status, language: coordinator.settings.language)
                if laya.isBusy {
                    if let progress = laya.transferProgress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                    note(laya.transferStatus.isEmpty ? L10n.text(laya.message, language: coordinator.settings.language) : laya.transferStatus)
                    Button(b("Cancel preparation", "取消准备")) { coordinator.cancelLayaRuntime() }
                } else if laya.state == .failed || laya.state == .installed {
                    note(L10n.text(laya.message, language: coordinator.settings.language))
                    Button(laya.isInstalled ? b("Load and verify", "加载并验证") : b("Retry download", "重试下载")) {
                        if laya.isInstalled { laya.prepare() } else { laya.install() }
                    }.disabled(!editable || coordinator.isMock)
                } else if laya.state == .unsupported {
                    note(b("Requires Apple Silicon and macOS 14+. Use manual replies on this Mac.", "需要 Apple Silicon 和 macOS 14+，此 Mac 可使用手动回答。"))
                } else {
                    if let bytes = laya.downloadByteCount {
                        let size = String(format: "%.2f MB", Double(bytes) / 1_000_000)
                        note(b("Initial download: \(size), including the model and runtime. Cached files reduce repeat downloads.", "首次下载 \(size)，包含模型与运行环境；已有缓存会减少实际下载量。"))
                    } else {
                        note(b("Laya includes the model and an isolated runtime.", "Laya 包含模型与独立运行环境。"))
                    }
                }
                if laya.state == .failed {
                    DisclosureGroup(b("Technical details", "技术详情")) {
                        Text(laya.diagnosticEvents.suffix(5).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                note(b("The cloud speech service detects questions. No local Laya download is needed.", "由云端语音服务判断问题，无需下载本地 Laya。"))
            }
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func modelStatus(_ kind: LocalModelKind) -> some View {
        OnboardingCapabilityBadge(status: setup[kind == .embedding ? .knowledge : .speech].status, language: coordinator.settings.language)
        if models.downloading == kind {
            if let progress = models.downloadProgress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
            note(L10n.text(models.message, language: coordinator.settings.language))
            if !models.transferStatus.isEmpty { note(models.transferStatus) }
            Button(b("Cancel downloads", "取消下载")) { models.cancel() }
        } else if let report = models.health[kind] {
            Label(report.ready ? b("Self-check passed", "自检通过") : b("Self-check failed", "自检未通过"), systemImage: report.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(report.ready ? Color.green : Color.orange)
            Text(coordinator.settings.language.interfaceText(report.advice(english: !coordinator.settings.language.usesChinese))).font(.caption)
            if !report.ready { Text(b("Open Settings → Services for self-check and diagnostics.", "请到设置 → 服务运行自检或复制诊断信息。")).font(.caption) }
        } else if models.installed.contains(kind) && kind != .embedding {
            Label(b("Downloaded · run self-check in Services", "已下载 · 可到服务页运行自检"), systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
        } else if models.queued.contains(kind) {
            Button(b("Cancel queued downloads", "取消排队下载")) { models.cancel() }
        } else if let failure = models.failures[kind] {
            note(L10n.text(failure, language: coordinator.settings.language))
            Button(b("Retry download", "重试下载")) { models.enqueue([kind]) }.disabled(!editable || coordinator.isMock)

        }
    }
}
