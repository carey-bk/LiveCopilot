import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let transcript = TranscriptStore()
    let suggestion = SuggestionStore()
    let sessions = SessionStore()
    let hotkeys: HotkeyStore
    let localModels: LocalModelManager
    let laya: LayaRuntimeManager
    private let layaPredictor: ((String, String) async throws -> Double)?
    private let mockReasoning: (any ReasoningProvider)?
    private let emitMockConversation: Bool
    private lazy var layaGate: LayaTriggerController = {
        let gate = LayaTriggerController(predict: { [weak self] text, context in
            guard let self else { throw CancellationError() }
            var highest = 0.0
            for variant in LayaPredictionText.variants(text) {
                try Task.checkCancellation()
                let score: Double
                if let predict = self.layaPredictor { score = try await predict(variant, context) }
                else { score = try await self.laya.predict(text: variant, context: context) }
                highest = max(highest, score)
            }
            return highest
        }, onTrigger: { [weak self] input in self?.dispatchLaya(input) ?? true }, ruleNearMissMargin: 0.1)
        gate.onError = { [weak self] _ in
            guard let self else { return }
            self.statusMessage = ServiceGuide.text("Laya unavailable — manual generation remains available. Check Live services settings.", "Laya 暂不可用，仍可手动生成回答。请检查“实时服务”设置。", self.settings.language)
        }
        gate.onDecision = { [weak self] score in self?.layaLastScore = score }
        return gate
    }()
    let appleSpeech = AppleSpeechManager()
    private var localEmbedding: LocalEmbeddingProvider?
    let systemAudio = AudioCaptureManager()
    let mic = MicCaptureManager()
    let isMock: Bool
    private let settingsDefaults: UserDefaults
    private(set) var knowledge: KnowledgeIndex?
    private var systemLive: (any LiveProvider)?
    private var micLive: (any LiveProvider)?
    private var conversation = ConversationState()
    private var answerTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var requestID = UUID()
    private var credentialRevision = UUID()
    private var cachedKey: String?
    private var cachedAnalysisKey: String?
    private var analysisCredentialRevision = UUID()
    private var analysisCredentialReference: CredentialReference?
    private var isShuttingDown = false
    private var startupCheckStarted = false
    private var startupCheckTask: Task<Void, Never>?
    private var sessionStartedAt: Date?
    private var liveEpoch = UUID()
    private var activeDelegations = Set<String>()
    private var speakingSources = Set<Speaker>()
    private var incompleteLocalStop = false
    private var pendingAutomatic: (speaker: Speaker, id: String, deadline: Date)?
    private var cancellables = Set<AnyCancellable>()
    private var mockTask: Task<Void, Never>?

    @Published var settings = AppSettings() {
        didSet {
            settings.save(defaults: settingsDefaults)
            if oldValue.automaticSuggestions != settings.automaticSuggestions ||
                oldValue.scenario != settings.scenario ||
                oldValue.mode != settings.mode || oldValue.listeningService != settings.listeningService {
                invalidateAutomaticTrigger()
                configureAutomaticTrigger()
            } else if oldValue.layaThreshold != settings.layaThreshold {
                configureAutomaticTrigger(prepare: false)
            }
            if suggestion.isLoading && !settings.isEnabled(suggestion.mode) { cancelAnswer() }
            if oldValue.requiresOpenAIKey != settings.requiresOpenAIKey {
                if settings.requiresOpenAIKey { refreshKeyState() }
                else {
                    credentialRevision = UUID(); isCheckingKey = false; cachedKey = nil; hasAPIKey = false; keyNeedsAuthorization = false
                    keyStatus = "OpenAI is not required by the selected local services."
                }
            }
            if oldValue.reasoningService != settings.reasoningService ||
                (try? oldValue.analysisCredentialReference()) != (try? settings.analysisCredentialReference()) {
                refreshAnalysisKeyState()
            }
        }
    }
    @Published var isRunning = false
    @Published var isTransitioning = false
    @Published var hasAPIKey = false
    @Published var isCheckingKey = false
    @Published var keyNeedsAuthorization = false
    @Published var hasAnalysisKey = false
    @Published var isCheckingAnalysisKey = false
    @Published var analysisKeyNeedsAuthorization = false
    @Published var analysisKeyStatus = "No credential available."
    @Published var keyStatus = "No credential available."
    @Published var statusMessage = "Ready — type a question or start listening"
    @Published var questionState = QuestionPhase.listening.rawValue
    @Published private(set) var layaLastScore: Double?
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var isIndexing = false
    @Published private(set) var indexingProgress = 0.0
    @Published private(set) var documentIndexingProgress = 0.0
    @Published private(set) var indexingDocumentID: String?
    @Published private(set) var indexingSucceeded = false
    @Published var knowledgeMessage = ""
    @Published var includeConversation = true
    @Published var micEnabled = true
    @Published private(set) var conversationGeneration = UUID()
    var onHotkeysChanged: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onShowOverlay: ((_ automatic: Bool) -> Void)?

    init(mock: Bool = ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LIVECOPILOT_MOCK"] == "1",
         layaRoot: URL? = nil, layaPredictor: ((String, String) async throws -> Double)? = nil,
         mockReasoning: (any ReasoningProvider)? = nil,
         emitMockConversation: Bool = true, mockDefaults: UserDefaults? = nil) {
        isMock = mock
        self.layaPredictor = mock ? layaPredictor : nil
        self.mockReasoning = mock ? mockReasoning : nil
        self.emitMockConversation = emitMockConversation
        localModels = LocalModelManager(root: AppPaths.modelsDirectory(mock: mock))
        laya = LayaRuntimeManager(root: layaRoot ?? AppPaths.dataDirectory(mock: mock).appendingPathComponent("Laya", isDirectory: true))
        settingsDefaults = mock ? (mockDefaults ?? UserDefaults(suiteName: "com.livecopilot.mock")!) : .standard
        hotkeys = HotkeyStore(defaults: settingsDefaults)
        settings = AppSettings.load(defaults: settingsDefaults)
        do { knowledge = try KnowledgeIndex(directory: AppPaths.dataDirectory(mock: mock).appendingPathComponent("knowledge")) }
        catch { knowledgeMessage = error.localizedDescription }
        if mock { hasAPIKey = true; keyStatus = "Mock providers — no credential needed."; statusMessage = "MOCK MODE — no API calls" }
        else if settings.requiresOpenAIKey { refreshKeyState() }
        else { keyStatus = "OpenAI is not required by the selected local services." }
        refreshAnalysisKeyState()
        systemAudio.onPCM16 = { [weak self] data in Task { @MainActor in self?.systemLive?.sendAudio(data) } }
        mic.onPCM16 = { [weak self] data in Task { @MainActor in self?.micLive?.sendAudio(data) } }
        systemAudio.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        mic.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        systemAudio.$isCapturing.dropFirst().sink { [weak self] capturing in
            guard let self, !capturing, self.isRunning, !self.isTransitioning else { return }
            let provider = self.systemLive; self.systemLive = nil
            Task { await provider?.disconnect() }
            self.speakingSources.remove(.them)
            self.layaGate.reset()
            self.configureAutomaticTrigger(prepare: false)
            if !self.mic.isCapturing { self.isRunning = false; self.invalidateAutomaticTrigger(); self.saveSession() }
        }.store(in: &cancellables)
        mic.$isCapturing.dropFirst().sink { [weak self] capturing in
            guard let self, !capturing, self.isRunning, !self.isTransitioning else { return }
            let provider = self.micLive; self.micLive = nil
            Task { await provider?.disconnect() }
            self.speakingSources.remove(self.settings.mode == .inPerson ? .room : .you)
            self.layaGate.reset()
            self.configureAutomaticTrigger(prepare: false)
            if !self.systemAudio.isCapturing { self.isRunning = false; self.invalidateAutomaticTrigger(); self.saveSession() }
        }.store(in: &cancellables)
        sessions.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        laya.$state.dropFirst().sink { [weak self] _ in
            // Published sends before mutation; read readiness on the next actor turn.
            Task { @MainActor [weak self] in self?.configureAutomaticTrigger(prepare: false) }
        }.store(in: &cancellables)
        Task { await refreshKnowledge() }
    }
    /// Local transcribers use Laya; GPT-Live-1 owns its client delegation decisions.
    private var usesLaya: Bool { settings.listeningService.isLocal }
    private func invalidateAutomaticTrigger(releaseRuntime: Bool = true) {
        questionTask?.cancel(); questionTask = nil; pendingAutomatic = nil
        layaLastScore = nil
        layaGate.reset()
        if releaseRuntime { laya.stop() }
    }
    private func configureAutomaticTrigger(prepare: Bool = true) {
        let selected = isRunning && settings.automaticSuggestions && usesLaya && !isShuttingDown
        layaGate.configure(enabled: selected && (laya.isReady || layaPredictor != nil),
                           threshold: settings.layaThreshold, cooldown: settings.scenario.cooldown)
        if selected {
            for speaker in speakingSources { layaGate.setSpeaking(true, speaker: speaker) }
            if prepare && layaPredictor == nil && !laya.isReady && !laya.isBusy { laya.prepare() }
        }
    }
    private func manualIntervention() {
        pendingAutomatic = nil; questionTask?.cancel(); questionTask = nil
        layaGate.manualIntervention()
    }
    func cancelLayaRuntime() {
        invalidateAutomaticTrigger(releaseRuntime: false)
        laya.cancel()
        configureAutomaticTrigger(prepare: false)
    }
    private func submitLaya(speaker: Speaker, partial: String? = nil) {
        guard isRunning, settings.automaticSuggestions, usesLaya else { return }
        guard isMock || (speaker == .them ? systemAudio.isCapturing : mic.isCapturing) else { return }
        if speaker == .you { layaGate.manualIntervention(); return }
        // Very short ASR previews are often noise or an unfinished syllable.
        // They must not retire a complete question while the pause timer runs.
        if let partial, partial.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { return }
        // Use the same caption grouping as dispatch, without mutating conversation state.
        var snapshot = conversation
        if let partial {
            let now = Date()
            let offset = Int(now.timeIntervalSince(sessionStartedAt ?? now) * 1000)
            _ = snapshot.append(.init(id: "laya-preview", speaker: speaker, text: partial,
                                      startMS: offset, endMS: offset, receivedAt: now))
        }
        guard let text = snapshot.candidate(speaker: speaker, now: Date(), cooldown: 0, force: partial != nil, semanticDetection: true) else { return }
        layaGate.submit(.init(text: text, context: snapshot.context(), speaker: speaker, isFinal: partial == nil))
    }
    private func dispatchLaya(_ input: LayaTriggerInput) -> Bool {
        guard isRunning, !isTransitioning, !isShuttingDown, usesLaya, settings.automaticSuggestions else { return true }
        guard !suggestion.isLoading else { return false }
        guard let candidate = conversation.candidate(speaker: input.speaker, now: Date(), cooldown: settings.scenario.cooldown, semanticDetection: true),
              candidate == input.text else { return true }
        // No fabricated OpenAI tool-call ID: Laya is an independent automatic origin.
        request(query: candidate, mode: .reply, speaker: input.speaker, automatic: true, contextOverride: input.context)
        return true
    }
    /// Deterministic audio-free input for the existing mock mode and native integration tests.
    func receiveMockEvent(_ event: LiveEvent, speaker: Speaker) {
        guard isMock else { return }
        receive(event, speaker: speaker, epoch: liveEpoch)
    }
    func updateHotkey(_ combo: HotkeyCombo, for mode: SuggestionMode) { hotkeys.set(combo, for: mode); onHotkeysChanged?() }
    func resetHotkey(_ mode: SuggestionMode) { hotkeys.reset(mode); onHotkeysChanged?() }
    func refreshKeyState(interactive: Bool = false) {
        if isMock { hasAPIKey = true; return }
        guard !isCheckingKey else { return }
        isCheckingKey = true
        cachedKey = nil; hasAPIKey = false
        keyNeedsAuthorization = false
        keyStatus = "Checking Keychain…"
        let revision = UUID(); credentialRevision = revision
        Task {
            defer { if credentialRevision == revision { isCheckingKey = false } }
            do {
                // A locked Keychain or its access prompt must never freeze the native UI.
                let result = try await CredentialVault.shared.read(.live, interactive: interactive)
                let key = result.key
                guard credentialRevision == revision else { return }
                cachedKey = key; hasAPIKey = key != nil
                DebugLog.log("credential.ready role=live available=\(hasAPIKey)")
                keyNeedsAuthorization = result.needsAuthorization
                keyStatus = result.message
                if key == nil { statusMessage = result.needsAuthorization ? result.message : "No key available — open Settings to configure Keychain." }
                if let key { runStartupCheckIfRequested(key: key) }
            } catch {
                guard credentialRevision == revision else { return }
                cachedKey = nil; hasAPIKey = false; statusMessage = error.localizedDescription
                keyStatus = error.localizedDescription
            }
        }
    }
    func refreshAnalysisKeyState(interactive: Bool = false) {
        let revision = UUID(); analysisCredentialRevision = revision
        cachedAnalysisKey = nil; hasAnalysisKey = false; isCheckingAnalysisKey = false; analysisKeyNeedsAuthorization = false
        guard settings.reasoningService != .sharedOpenAI else { analysisKeyStatus = "Using the Live service credential."; return }
        guard !isMock else { hasAnalysisKey = true; analysisKeyStatus = "Mock providers — no credential needed."; return }
        do {
            let reference = try settings.analysisCredentialReference()
            analysisCredentialReference = reference
            isCheckingAnalysisKey = true
            analysisKeyStatus = "Checking Keychain…"
            Task {
                defer { if analysisCredentialRevision == revision { isCheckingAnalysisKey = false } }
                do {
                    let result = try await CredentialVault.shared.read(reference, interactive: interactive)
                    let key = result.key
                    guard analysisCredentialRevision == revision else { return }
                    cachedAnalysisKey = key; hasAnalysisKey = key != nil
                    DebugLog.log("credential.ready role=analysis available=\(hasAnalysisKey)")
                    analysisKeyNeedsAuthorization = result.needsAuthorization
                    analysisKeyStatus = result.message
                } catch {
                    guard analysisCredentialRevision == revision else { return }
                    analysisKeyStatus = error.localizedDescription
                }
            }
        } catch { analysisKeyStatus = error.localizedDescription }
    }
    func saveCredential(_ value: String, analysis: Bool) async throws {
        guard !isMock else { return }
        let reference = analysis ? try settings.analysisCredentialReference() : .live
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try await CredentialVault.shared.save(value, for: reference)
        if reference == .live {
            credentialRevision = UUID(); isCheckingKey = false
            cachedKey = value; hasAPIKey = true; keyNeedsAuthorization = false; keyStatus = "Saved in macOS Keychain."
        } else if (try? settings.analysisCredentialReference()) == reference {
            analysisCredentialRevision = UUID(); isCheckingAnalysisKey = false
            cachedAnalysisKey = value; hasAnalysisKey = true; analysisKeyNeedsAuthorization = false; analysisKeyStatus = "Saved in macOS Keychain."
        }
    }
    func removeCredential(analysis: Bool) async throws {
        guard !isMock else { return }
        let reference = analysis ? try settings.analysisCredentialReference() : .live
        try await CredentialVault.shared.remove(reference)
        if reference == .live { credentialRevision = UUID(); isCheckingKey = false; refreshKeyState() }
        else if (try? settings.analysisCredentialReference()) == reference { refreshAnalysisKeyState() }
    }
    private func runStartupCheckIfRequested(key: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--verify-live"), !startupCheckStarted, !isShuttingDown else { return }
        startupCheckStarted = true
        var audioURL: URL?
        if let i = arguments.firstIndex(of: "--audio") {
            guard arguments.indices.contains(i + 1) else { statusMessage = "Live check needs a synthetic audio path after --audio."; return }
            audioURL = URL(fileURLWithPath: arguments[i + 1])
        }
        startupCheckTask = Task {
            isTransitioning = true
            defer { isTransitioning = false }
            statusMessage = "Running explicit Live API check — synthetic audio only"
            do {
                try await LiveSmokeCheck.run(key: key, settings: settings, audioURL: audioURL) { message in
                    self.statusMessage = message
                    DebugLog.log("api.check \(message)")
                }
            } catch {
                statusMessage = "Live API check: " + error.localizedDescription
                DebugLog.log("api.check \(statusMessage)")
            }
        }
    }
    private func credential() throws -> String {
        guard let key = cachedKey else {
            throw CopilotError.message("Credential not available yet. Unlock Keychain and use Check Keychain in Settings, or save an API key there.")
        }
        return key
    }
    func removeLocalModel(_ kind: LocalModelKind) {
        guard !isRunning, !isTransitioning, !isIndexing, !suggestion.isLoading else { return }
        if kind == .embedding { localEmbedding?.close(); localEmbedding = nil }
        localModels.remove(kind)
    }

    private func embeddingProvider(requireReady: Bool = false) throws -> any EmbeddingProvider {
        if isMock { return MockEmbeddingProvider() }
        if settings.embeddingService == .local {
            if requireReady, !LocalModelKind.embedding.isInstalled(in: localModels.root) { throw CopilotError.message("Download the local embedding model in Services first.") }
            if localEmbedding == nil { localEmbedding = LocalEmbeddingProvider(directory: LocalModelKind.embedding.location(in: localModels.root)) }
            return localEmbedding!
        }
        return OpenAIEmbeddingProvider(key: cachedKey ?? "", model: settings.embeddingModel)
    }
    func start() async {
        guard !isRunning, !isTransitioning, !isShuttingDown else { return }
        isTransitioning = true; defer { isTransitioning = false }
        invalidateAutomaticTrigger(releaseRuntime: false)
        let epoch = UUID(); liveEpoch = epoch
        conversation.reset(); transcript.clear(); activeDelegations = []; speakingSources = []
        sessionStartedAt = Date()
        if isMock {
            isRunning = true; statusMessage = "MOCK listening — sample conversation"
            configureAutomaticTrigger()
            guard emitMockConversation else { return }
            let speaker: Speaker = settings.mode == .inPerson ? .room : .them
            mockTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                self.receive(.transcript(.init(id: UUID().uuidString, speaker: speaker, text: "What is the latency of method B?", startMS: 0, endMS: 1800, receivedAt: Date())), speaker: speaker, epoch: epoch)
                self.receive(.delegation(id: "mock-delegation", offsetMS: 1800), speaker: speaker, epoch: epoch)
            }
            return
        }
        do {
            let key = settings.listeningService == .openAI ? try credential() : ""
            if let kind = settings.listeningService.localModel, !kind.isInstalled(in: localModels.root) {
                throw CopilotError.message("Download the selected speech model and VAD in Services first.")
            }
            if settings.listeningService == .apple {
                guard AppleSpeechSupport.available else { throw CopilotError.message("Apple speech requires macOS 26 and a supported Mac and language.") }
                guard await AppleSpeechSupport.installed(settings.appleSpeechLanguage) else { throw CopilotError.message("Download the selected Apple speech language in Services first.") }
            }
            systemAudio.configure(sampleRate: settings.listeningService.sampleRate)
            mic.configure(sampleRate: settings.listeningService.sampleRate)
            statusMessage = "Starting audio capture…"
            // Acquire permissions/capture first; never leave paid sockets open after a capture failure.
            if settings.mode == .remote { await systemAudio.start() }
            guard liveEpoch == epoch else { return }
            if micEnabled || settings.mode == .inPerson { await mic.start() }
            guard liveEpoch == epoch else { return }
            guard systemAudio.isCapturing || mic.isCapturing else {
                statusMessage = mic.lastError ?? systemAudio.lastError ?? "No audio capture source available."
                sessionStartedAt = nil; return
            }
            isRunning = true
            configureAutomaticTrigger()
            if systemAudio.isCapturing { systemLive = makeLive(key: key, speaker: .them, epoch: epoch); systemLive?.connect(context: "") }
            if mic.isCapturing {
                let speaker: Speaker = settings.mode == .inPerson ? .room : .you
                micLive = makeLive(key: key, speaker: speaker, epoch: epoch); micLive?.connect(context: "")
            }
            statusMessage = systemAudio.lastError ?? mic.lastError ?? (settings.listeningService.isLocal ? "Loading local speech model…" : "Connecting Live…")
        } catch { statusMessage = error.localizedDescription; sessionStartedAt = nil }
    }
    private func makeLive(key: String, speaker: Speaker, epoch: UUID) -> any LiveProvider {
        let provider: any LiveProvider
        if settings.listeningService == .apple, #available(macOS 26, *) {
            provider = AppleLiveProvider(speaker: speaker, language: settings.appleSpeechLanguage, sessionStart: sessionStartedAt ?? Date())
        } else if let kind = settings.listeningService.localModel {
            provider = LocalLiveProvider(directory: kind.location(in: localModels.root), speaker: speaker, sessionStart: sessionStartedAt ?? Date())
        } else { provider = OpenAILiveProvider(key: key, model: settings.liveModel, speaker: speaker, scenario: settings.scenario, language: settings.liveSpeechLanguage) }
        provider.onEvent = { [weak self] event in self?.receive(event, speaker: speaker, epoch: epoch) }
        return provider
    }
    private func receive(_ event: LiveEvent, speaker: Speaker, epoch: UUID) {
        guard epoch == liveEpoch else { return }
        switch event {
        case .speechActivity(let active):
            if active { speakingSources.insert(speaker); if pendingAutomatic?.speaker == speaker { questionTask?.cancel() } }
            else { speakingSources.remove(speaker); if pendingAutomatic != nil { scheduleAutomatic() } }
            if usesLaya, isRunning { layaGate.setSpeaking(active, speaker: speaker) }
        case .partialTranscript(let text):
            transcript.setPartial(text, speaker: speaker)
            if !text.isEmpty { questionState = QuestionPhase.forming.rawValue }
            if !text.isEmpty { submitLaya(speaker: speaker, partial: text) }
        case .transcript(let fragment):
            transcript.clearPartial(speaker)
            guard conversation.append(fragment) else { return }
            transcript.ingest(fragment)
            if speaker == .you { systemLive?.appendContext("You said: " + fragment.text, delegationID: nil) }
            questionState = conversation.phase.rawValue
            if usesLaya { submitLaya(speaker: speaker) }
            else if pendingAutomatic != nil { scheduleAutomatic() }
        case .delegation(let id, _):
            guard !usesLaya, isRunning, settings.automaticSuggestions, speaker != .you, activeDelegations.insert(id).inserted else { return }
            if activeDelegations.count > 400 { activeDelegations = [id] }
            pendingAutomatic = (speaker, id, Date().addingTimeInterval(25))
            scheduleAutomatic()
        case .ready: statusMessage = "Listening · \(settings.mode.rawValue) · \(speaker.rawValue) ready"
        case .status(let message): statusMessage = message
        case .failed(let message):
            layaGate.reset()
            transcript.clearPartial(speaker)
            statusMessage = message
            if settings.listeningService.isLocal, isRunning, !isTransitioning {
                Task { await stop(); statusMessage = message }
            }
        case .closed(let finalized):
            speakingSources.remove(speaker)
            layaGate.reset()
            configureAutomaticTrigger(prepare: false)
            transcript.clearPartial(speaker)
            if !finalized, settings.listeningService.isLocal { incompleteLocalStop = true; DebugLog.log("local.close incomplete_flush") }
            else if !finalized { DebugLog.log("live.close final_usage_unconfirmed speaker=\(speaker.rawValue)") }
        }
    }
    private func scheduleAutomatic() {
        questionTask?.cancel()
        guard !usesLaya else { pendingAutomatic = nil; return }
        let epoch = liveEpoch
        questionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.liveEpoch == epoch, self.isRunning,
                  !self.usesLaya, self.settings.automaticSuggestions, let pending = self.pendingAutomatic else { return }
            if Date() > pending.deadline { self.pendingAutomatic = nil; return }
            if self.speakingSources.contains(pending.speaker) { self.questionState = QuestionPhase.forming.rawValue; return }
            if self.suggestion.isLoading { return } // Latest follow-up remains queued until answer finishes.
            guard let question = self.conversation.candidate(speaker: pending.speaker, now: Date(), cooldown: self.settings.scenario.cooldown) else {
                self.questionState = self.conversation.phase.rawValue
                if self.conversation.phase == .duplicate || self.conversation.phase == .answered { self.pendingAutomatic = nil }
                else { self.scheduleAutomatic() }
                return
            }
            self.pendingAutomatic = nil
            self.request(query: question, mode: .reply, speaker: pending.speaker, delegationID: pending.id, automatic: true)
        }
    }
    func shutdown() async {
        isShuttingDown = true
        cancelAnswer()
        startupCheckTask?.cancel()
        await startupCheckTask?.value
        await stop(force: true)
        localEmbedding?.close(); localEmbedding = nil
        await localModels.shutdown()
        await appleSpeech.shutdown()
        await laya.shutdown()
    }
    func stop(force: Bool = false) async {
        guard force || !isTransitioning else { return }
        isTransitioning = true; defer { isTransitioning = false }
        incompleteLocalStop = false
        isRunning = false
        invalidateAutomaticTrigger()
        speakingSources = []
        questionTask?.cancel(); pendingAutomatic = nil; mockTask?.cancel()
        await systemAudio.stop(); mic.stop()
        let a = systemLive, b = micLive; systemLive = nil; micLive = nil
        async let closeA: Void = a?.disconnect() ?? ()
        async let closeB: Void = b?.disconnect() ?? ()
        _ = await (closeA, closeB)
        liveEpoch = UUID()
        saveSession()
        statusMessage = incompleteLocalStop ? "Listening stopped. The final local speech segment could not be completed." : "Listening stopped — manual questions remain available"
    }
    /// Discard this session, including provider-side speech context and late buffered finals.
    /// Listening continues with fresh providers if it was active before the reset.
    func resetConversation() async {
        guard !isTransitioning, !isShuttingDown else { return }
        let resume = isRunning
        isTransitioning = true
        liveEpoch = UUID() // Invalidate old callbacks BEFORE disconnect can flush a final segment.
        invalidateAutomaticTrigger()
        cancelAnswer(); answerTask = nil
        questionTask?.cancel(); questionTask = nil; pendingAutomatic = nil
        mockTask?.cancel(); mockTask = nil
        sessionStartedAt = nil // This session was explicitly discarded, not archived.
        isRunning = false
        conversation.reset(); transcript.clear(); suggestion.reset()
        activeDelegations = []; speakingSources = []
        questionState = QuestionPhase.listening.rawValue
        settings.overlayAutoHeight = true
        conversationGeneration = UUID()
        statusMessage = "Ready — type a question or start listening"
        let a = systemLive, b = micLive; systemLive = nil; micLive = nil
        await systemAudio.stop(); mic.stop()
        async let closeA: Void = a?.disconnect() ?? ()
        async let closeB: Void = b?.disconnect() ?? ()
        _ = await (closeA, closeB)
        isTransitioning = false
        if resume && !isShuttingDown { await start() }
    }
    func saveSession() {
        if let started = sessionStartedAt {
            _ = sessions.save(lines: transcript.lines, startedAt: started, fragments: conversation.fragments)
        }
        sessionStartedAt = nil
    }
    func toggle() async { if isRunning { await stop() } else { await start() } }
    func toggleMic() {
        guard !isShuttingDown, !isTransitioning else { return }
        guard settings.mode == .remote else { statusMessage = "Room mode uses the microphone. Stop listening to disable it."; return }
        micEnabled.toggle()
        guard isRunning, !isMock else { return }
        let epoch = liveEpoch
        Task {
            if micEnabled {
                do {
                    let key = settings.listeningService == .openAI ? try credential() : ""; await mic.start()
                    guard mic.isCapturing, liveEpoch == epoch, isRunning, !isShuttingDown, micEnabled else { return }
                    micLive = makeLive(key: key, speaker: .you, epoch: liveEpoch); micLive?.connect(context: conversation.context())
                } catch { statusMessage = error.localizedDescription }
            } else { mic.stop(); let previous = micLive; micLive = nil; await previous?.disconnect() }
        }
    }
    func requestSuggestion(mode: SuggestionMode = .reply) {
        manualIntervention()
        guard settings.isEnabled(mode) else { return }
        let context = conversation.context()
        guard !context.isEmpty else { statusMessage = "No conversation yet. Type a question below to ask directly."; onShowOverlay?(false); return }
        let query: String
        switch mode {
        case .reply: query = "Help me answer the latest substantive question in this conversation."
        case .recap: query = "Summarize the recent conversation, decisions and unresolved questions."
        case .followUp: query = "Suggest one useful follow-up question based on this conversation."
        }
        request(query: query, mode: mode, useContext: true)
    }
    func askText(_ query: String) { manualIntervention(); request(query: query, mode: .reply, useContext: includeConversation) }
    func cancelAnswer() {
        manualIntervention()
        requestID = UUID(); answerTask?.cancel(); suggestion.finish()
        conversation.finish(success: false, question: suggestion.question)
        questionState = conversation.phase.rawValue
    }
    private func request(query: String, mode: SuggestionMode, speaker: Speaker? = nil,
                         delegationID: String? = nil, useContext: Bool = true,
                         automatic: Bool = false, contextOverride: String? = nil) {
        if !automatic { manualIntervention() }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isTransitioning, !isShuttingDown else { return }
        guard query.count <= 8000 else { suggestion.fail("Keep a manual question under 8,000 characters."); return }
        let reasoning: any ReasoningProvider
        let embedding: any EmbeddingProvider
        do {
            reasoning = isMock ? (mockReasoning ?? MockReasoningProvider()) : try ReasoningProviderFactory.make(settings: settings, liveKey: cachedKey, analysisKey: cachedAnalysisKey)
            embedding = try embeddingProvider()
        } catch { suggestion.fail(error.localizedDescription); onShowOverlay?(automatic); return }
        answerTask?.cancel()
        let id = UUID(); requestID = id
        let context = useContext ? (contextOverride ?? conversation.context()) : ""
        let previous = useContext ? conversation.previousQuestion : nil
        let normalized = RetrievalQuery.formulate(question: query, context: context, previousQuestion: previous)
        conversation.begin(query, speaker: speaker, now: Date())
        questionState = conversation.phase.rawValue
        suggestion.begin(mode: mode, question: query)
        onShowOverlay?(automatic)
        let settings = settings, epoch = liveEpoch, started = Date()
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                var sources: [RetrievedSource] = []
                if let knowledge = self.knowledge {
                    let documents = try await knowledge.documents()
                    if documents.contains(where: { $0.chunkCount > 0 }) {
                        var vector: [Float]?
                        do { vector = try await embedding.embed([normalized.semantic]).first }
                        catch {
                            try Task.checkCancellation()
                            guard self.requestID == id else { return }
                            self.suggestion.warning = "Semantic retrieval unavailable; using local keyword search."
                        }
                        sources = try await knowledge.retrieve(query: normalized, vector: vector, model: embedding.model, limit: settings.retrievalCount)
                    }
                } else { self.suggestion.warning = "Knowledge database unavailable; answering from general context." }
                try Task.checkCancellation(); guard self.requestID == id else { return }
                self.suggestion.sources = sources
                self.suggestion.retrievalMS = Int(Date().timeIntervalSince(started) * 1000)
                DebugLog.log("rag.ready elapsed_ms=\(self.suggestion.retrievalMS) chunks=\(sources.count)")
                let answer = AnswerRequest(query: normalized, conversation: context, scenario: settings.scenario, sources: sources, mode: mode)
                var first = true
                for try await delta in reasoning.stream(answer) {
                    try Task.checkCancellation(); guard self.requestID == id else { return }
                    if first {
                        self.suggestion.firstTextMS = Int(Date().timeIntervalSince(started) * 1000); first = false
                        DebugLog.log("answer.first_text elapsed_ms=\(self.suggestion.firstTextMS ?? 0)")
                    }
                    self.suggestion.appendDelta(delta)
                }
                guard self.requestID == id else { return }
                self.suggestion.finish(); self.conversation.finish(success: true, question: query)
                if let delegationID, self.liveEpoch == epoch {
                    let summary = "Assistance completed in the text overlay for the question. Brief result: " + String(self.suggestion.text.prefix(900))
                    (speaker == .room ? self.micLive : self.systemLive)?.appendContext(summary, delegationID: delegationID)
                }
            } catch {
                guard self.requestID == id, !Task.isCancelled else { return }
                self.suggestion.fail(error.localizedDescription); self.conversation.finish(success: false, question: query)
            }
            self.questionState = self.conversation.phase.rawValue
            if self.pendingAutomatic != nil { self.scheduleAutomatic() }
            self.layaGate.retryPending()
        }
    }
    func refreshKnowledge() async {
        guard let knowledge else { return }
        do { knowledgeDocuments = try await knowledge.documents() }
        catch { knowledgeMessage = error.localizedDescription }
    }
    private func indexingCallback(offset: Int, count: Int) -> @Sendable (String, Double) async -> Void {
        { [weak self] id, value in
            guard let self else { return }
            await self.updateIndexing(id: id, value: value, offset: offset, count: count)
        }
    }
    private func updateIndexing(id: String, value: Double, offset: Int, count: Int) async {
        indexingDocumentID = id
        documentIndexingProgress = value
        indexingProgress = (Double(offset) + value) / Double(max(1, count))
        if value == 0 || value == 1 { await refreshKnowledge() }
    }
    func importDocuments(_ urls: [URL]) {
        guard !isIndexing, let knowledge else { return }
        let documents: [URL]
        do { documents = try DocumentImport.validate(urls) }
        catch { knowledgeMessage = error.localizedDescription; return }
        guard !documents.isEmpty else { return }
        isIndexing = true
        indexingProgress = 0; documentIndexingProgress = 0; indexingSucceeded = false; indexingDocumentID = nil
        Task {
            defer { isIndexing = false; indexingDocumentID = nil }
            do {
                if !isMock, settings.embeddingService == .openAI { _ = try credential() }
                let provider = try embeddingProvider(requireReady: true)
                for (offset, url) in documents.enumerated() {
                    knowledgeMessage = "Indexing \(url.lastPathComponent)…"
                    do { _ = try await knowledge.importDocument(url, provider: provider, progress: indexingCallback(offset: offset, count: documents.count)) }
                    catch { knowledgeMessage = error.localizedDescription; await refreshKnowledge(); return }
                    await refreshKnowledge()
                }
                indexingSucceeded = true
                knowledgeMessage = "Indexing complete. Retrieval is local."
            } catch { knowledgeMessage = error.localizedDescription }
        }
    }
    func reindex(_ document: KnowledgeDocument) {
        guard !isIndexing, let knowledge else { return }
        isIndexing = true
        indexingProgress = 0; documentIndexingProgress = 0; indexingSucceeded = false; indexingDocumentID = nil
        Task {
            defer { isIndexing = false; indexingDocumentID = nil }
            do {
                knowledgeMessage = "Re-indexing \(document.name)…"
                if !isMock, settings.embeddingService == .openAI { _ = try credential() }
                _ = try await knowledge.reindex(document, provider: embeddingProvider(requireReady: true), progress: indexingCallback(offset: 0, count: 1))
                indexingSucceeded = true
                knowledgeMessage = "Re-indexing complete."
            } catch { knowledgeMessage = error.localizedDescription }
            await refreshKnowledge()
        }
    }
    func deleteDocument(_ document: KnowledgeDocument) {
        guard !isIndexing, let knowledge else { return }
        Task {
            do { try await knowledge.delete(document.id); knowledgeMessage = "Deleted local document and index." }
            catch { knowledgeMessage = error.localizedDescription }
            await refreshKnowledge()
        }
    }
    func reindexAll() {
        guard !isIndexing, let knowledge else { return }
        let documents = knowledgeDocuments
        guard !documents.isEmpty else { return }
        isIndexing = true
        indexingProgress = 0; documentIndexingProgress = 0; indexingSucceeded = false; indexingDocumentID = nil
        Task {
            defer { isIndexing = false; indexingDocumentID = nil }
            do {
                if !isMock, settings.embeddingService == .openAI { _ = try credential() }
                let provider = try embeddingProvider(requireReady: true)
                for (offset, document) in documents.enumerated() {
                    knowledgeMessage = "Re-indexing \(document.name)…"
                    _ = try await knowledge.reindex(document, provider: provider, progress: indexingCallback(offset: offset, count: documents.count))
                    await refreshKnowledge()
                }
                indexingSucceeded = true
                knowledgeMessage = "Re-indexing complete."
            } catch { knowledgeMessage = error.localizedDescription }
            await refreshKnowledge()
        }
    }
}
