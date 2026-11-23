import Foundation

/// A read-only projection shared by the feature cards, inventory, download summary and footer.
/// It never starts verification, downloads, audio or remote requests.
struct OnboardingSetupInventory {
    var installed: Set<LocalModelKind> = []
    var downloading: LocalModelKind?
    var queued: [LocalModelKind] = []
    var failedDownloads: Set<LocalModelKind> = []
    var speechRuntime: CapabilityRuntimeState = .idle
    var knowledgeRuntime: CapabilityRuntimeState = .idle
    var appleAvailable = false
    var appleInstalled = false
    var appleChecked = false
    var appleBusy = false
    var appleFailed = false
    var layaState: LayaRuntimeManager.State = .notInstalled
    var layaInstalled = false
    var layaDownloadBytes: Int64? = LayaDownloadSize.load()?.totalBytes
    var cloudKeyConfigured = false

    @MainActor init(_ coordinator: AppCoordinator) {
        installed = coordinator.localModels.installed; downloading = coordinator.localModels.downloading
        queued = coordinator.localModels.queued; failedDownloads = Set(coordinator.localModels.failures.keys)
        speechRuntime = coordinator.currentSpeechRuntime
        knowledgeRuntime = coordinator.currentKnowledgeRuntime
        appleAvailable = coordinator.appleSpeech.available
        appleInstalled = coordinator.appleSpeech.installed
        appleChecked = coordinator.appleSpeech.checkedLanguage == coordinator.settings.appleSpeechLanguage
        appleBusy = coordinator.appleSpeech.busy
        appleFailed = coordinator.appleSpeech.failedLanguage == coordinator.settings.appleSpeechLanguage
        layaState = coordinator.laya.displayState; layaInstalled = coordinator.laya.isInstalled
        layaDownloadBytes = coordinator.laya.downloadByteCount
        cloudKeyConfigured = coordinator.hasAPIKey
    }
    init() {}
    func localStatus(_ kind: LocalModelKind, runtime: CapabilityRuntimeState = .idle) -> OnboardingCapabilityStatus {
        if downloading == kind { return runtime == .loading && installed.contains(kind) ? .verifying : .downloading }
        if queued.contains(kind) { return .queued }
        if failedDownloads.contains(kind) && !installed.contains(kind) { return .downloadFailed }
        guard installed.contains(kind) else { return .download }
        switch runtime {
        case .idle: return .installed
        case .loading: return .verifying
        case .ready: return .ready
        case .failed: return .loadFailed
        }
    }
}

enum CapabilityRuntimeState { case idle, loading, ready, failed }

struct OnboardingSetupSnapshot {
    enum Feature: String, Identifiable { case speech, knowledge, proactive; var id: String { rawValue } }
    struct Capability: Identifiable {
        let id: Feature
        let model: String
        let status: OnboardingCapabilityStatus
        let enabled: Bool
    }
    struct Resource: Identifiable {
        enum Kind: Equatable { case local(LocalModelKind), apple(AppleSpeechLanguage), laya }
        let kind: Kind
        let name: String
        let bytes: Int64?
        let status: OnboardingCapabilityStatus
        var id: String { name }
        var needsStart: Bool { status != .downloading && status != .queued && status != .verifying }
        func sizeLabel(_ language: AppLanguage) -> String {
            guard let bytes else { return ServiceGuide.text("Size unknown", "大小未知", language) }
            return String(format: "%.2f MB", Double(bytes) / 1_000_000)
        }
    }
    let capabilities: [Capability]
    let resources: [Resource]
    let backgroundOnly: [String]
    let needsLayaLoad: Bool
    var needsDownload: Bool { resources.contains(where: \.needsStart) }
    var hasActiveTransfers: Bool { resources.contains { !($0.needsStart) } || !backgroundOnly.isEmpty }
    var knownBytes: Int64 { resources.compactMap(\.bytes).reduce(0, +) }
    var unknownSizeCount: Int { resources.filter { $0.bytes == nil }.count }
    var unavailableFeatures: [Feature] {
        capabilities.filter { $0.enabled && ![.ready, .installed].contains($0.status) }.map(\.id)
    }
    subscript(_ feature: Feature) -> Capability { capabilities.first { $0.id == feature }! }

    @MainActor init(_ coordinator: AppCoordinator) {
        self.init(settings: coordinator.settings, state: coordinator.onboarding.state, inventory: OnboardingSetupInventory(coordinator))
    }
    init(settings: AppSettings, state: OnboardingState, inventory: OnboardingSetupInventory) {
        let i = inventory
        var entries: [Capability] = [], downloads: [Resource] = []
        func addLocal(_ kind: LocalModelKind, name: String) {
            guard !kind.isBundled else { return }
            guard !i.installed.contains(kind) else { return }
            let sizes = kind.downloads.compactMap(\.knownByteCount)
            downloads.append(.init(kind: .local(kind), name: name,
                                   bytes: sizes.count == kind.downloads.count ? sizes.reduce(0, +) : nil,
                                   status: i.localStatus(kind)))
        }
        var speechStatus: OnboardingCapabilityStatus
        var speechName: String
        switch settings.listeningService {
        case .zipformer:
            speechName = "Zipformer + VAD"
            speechStatus = i.localStatus(.terminologySpeech, runtime: i.speechRuntime)
            if !state.prefersTyping { addLocal(.terminologySpeech, name: speechName) }
        case .paraformer:
            speechName = "Paraformer + VAD"
            speechStatus = i.localStatus(.streamingSpeech, runtime: i.speechRuntime)
            if !state.prefersTyping { addLocal(.streamingSpeech, name: speechName) }
        case .apple:
            speechName = "Apple · " + ServiceGuide.text(settings.appleSpeechLanguage == .chinese ? "Mandarin" : "English", settings.appleSpeechLanguage == .chinese ? "普通话" : "英语", settings.language)
            speechStatus = .apple(available: i.appleAvailable, installed: i.appleInstalled, busy: i.appleBusy, verified: i.appleChecked)
            if i.appleFailed && !i.appleInstalled { speechStatus = .downloadFailed }
            if i.appleChecked && i.appleInstalled && !i.appleBusy {
                switch i.speechRuntime {
                case .loading: speechStatus = .verifying
                case .failed: speechStatus = .loadFailed
                default: break
                }
            }
            if !state.prefersTyping && i.appleAvailable && ((i.appleChecked && !i.appleInstalled) || i.appleBusy) {
                downloads.append(.init(kind: .apple(settings.appleSpeechLanguage), name: speechName, bytes: nil, status: speechStatus))
            }
        case .openAI:
            speechName = "OpenAI · GPT-Live"
            speechStatus = i.cloudKeyConfigured ? .verify : .configure
            if i.speechRuntime == .loading { speechStatus = .verifying }
            if i.speechRuntime == .ready { speechStatus = .ready }
            if i.speechRuntime == .failed { speechStatus = .attention }
        }
        entries.append(.init(id: .speech, model: speechName, status: state.prefersTyping ? .notNeeded : speechStatus, enabled: !state.prefersTyping))
        let knowledgeStatus = settings.embeddingService == .local
            ? i.localStatus(.embedding, runtime: i.knowledgeRuntime) : (i.cloudKeyConfigured ? .verify : .configure)
        entries.append(.init(id: .knowledge, model: settings.embeddingService == .local ? "\(LocalModelKind.embeddingName)" : "OpenAI Embeddings",
                             status: state.wantsKnowledge ? knowledgeStatus : .off, enabled: state.wantsKnowledge))
        if state.wantsKnowledge && settings.embeddingService == .local { addLocal(.embedding, name: "\(LocalModelKind.embeddingName)") }
        let usesLocalJev = settings.listeningService.isLocal
        let jevEnabled = !state.prefersTyping && settings.automaticSuggestions
        var jevStatus: OnboardingCapabilityStatus = usesLocalJev ? .laya(i.layaState) : speechStatus
        if usesLocalJev && i.layaState == .failed { jevStatus = i.layaInstalled ? .loadFailed : .downloadFailed }
        entries.append(.init(id: .proactive, model: usesLocalJev ? "Laya · Jev Mode" : "GPT-Live · Jev Mode", status: jevEnabled ? jevStatus : (settings.automaticSuggestions ? .notNeeded : .off), enabled: jevEnabled))

        let selectedLocalKinds = downloads.compactMap { resource -> LocalModelKind? in
            if case .local(let kind) = resource.kind { return kind }; return nil
        }
        var extra = ([i.downloading].compactMap { $0 } + i.queued).filter { !selectedLocalKinds.contains($0) }.map(\.title)
        if i.appleBusy && (state.prefersTyping || settings.listeningService != .apple) { extra.append("Apple Speech") }
        if [.installing, .loading].contains(i.layaState) && (!jevEnabled || !usesLocalJev) { extra.append("Laya") }
        capabilities = entries; resources = downloads; backgroundOnly = extra
        needsLayaLoad = jevEnabled && usesLocalJev && i.layaInstalled && [.installed, .failed].contains(i.layaState)
    }
}
