import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let transcript = TranscriptStore()
    let translation = TranscriptTranslationStore()
    func setTranscriptTranslation(_ target: TranscriptTranslationStore.Language?) {
        guard let target else { translation.stop(); return }
        do {
            var translationSettings = settings
            let modes = AnalysisModelCatalog.models(for: settings.reasoningService).first { $0.id == settings.analysisModel }?.modes ?? []
            translationSettings.analysisThinking = modes.contains(.disabled) ? .disabled : (modes.contains(.low) ? .low : .modelDefault)
            let provider: any ReasoningProvider = isMock ? (mockReasoning ?? MockReasoningProvider()) : try ReasoningProviderFactory.make(settings: translationSettings, liveKey: cachedKey, analysisKey: cachedAnalysisKey)
            translation.start(target: target, provider: provider, lines: transcript.lines)
            translation.updatePreview(transcript.partialYou, speaker: .you)
            translation.updatePreview(transcript.partialThem, speaker: settings.mode == .inPerson ? .room : .them)
        } catch { statusMessage = error.localizedDescription }
    }
    let suggestion = SuggestionStore() // Stable display projection; requests own separate stores.
    struct AnswerRecord: Identifiable {
        let id: UUID
        let questionID: UUID
        let automatic: Bool
        var sourceFragmentID: String? = nil
        let createdAt: Date
        let store: SuggestionStore
        var viewed: Bool
    }
    @Published private(set) var answerRevision = 0
    @Published private(set) var answers: [AnswerRecord] = []
    @Published private(set) var selectedAnswerID: UUID?
    @Published private(set) var answerIsRunning = false
    @Published private(set) var queuedQuestionCount = 0
    @Published private(set) var skippedQuestionCount = 0
    private var questions = QuestionCoordinator()
    private var queueWake: Task<Void, Never>?
    private var answerTimeout: Task<Void, Never>?
    private var activeStore: SuggestionStore?
    var answerTimeoutSeconds: Double = 90
    var unreadAnswerCount: Int { answers.filter { !$0.viewed }.count }
    var previousAnswerID: UUID? {
        guard let index = answers.firstIndex(where: { $0.id == selectedAnswerID }), index > 0 else { return nil }
        return answers[index - 1].id
    }
    func selectAnswer(_ id: UUID) {
        guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
        selectedAnswerID = id; answers[index].viewed = true
        suggestion.copy(from: answers[index].store)
    }
    func showNextAnswer() {
        if let next = answers.first(where: { !$0.viewed }) { selectAnswer(next.id) }
        else if let index = answers.firstIndex(where: { $0.id == selectedAnswerID }), index + 1 < answers.count { selectAnswer(answers[index + 1].id) }
    }
    private func publishAnswer(_ id: UUID, store: SuggestionStore) {
        if selectedAnswerID == id { suggestion.copy(from: store) }
        if !store.isLoading, let sessionID = archivedAnswerSessions[id], let record = answers.first(where: { $0.id == id }) {
            let snapshot = archiveAnswer(record)
            sessions.update(sessionID) { session in
                guard let index = session.answers?.firstIndex(where: { $0.id == id }) else { return }
                session.answers?[index] = snapshot
            }
        }
        answerRevision &+= 1
    }
    private func syncQueuedAnswers() {
        let ids = Set(questions.pending.map(\.answerID))
        for record in answers where record.store.state == .queued && !ids.contains(record.id) {
            record.store.interrupt(ServiceGuide.text("Merged or skipped before generation.", "已合并或跳过，未发起生成。", settings.language))
        }
        for item in questions.pending {
            if let existing = answers.first(where: { $0.id == item.answerID }) {
                existing.store.prepare(question: item.query)
            } else {
                let store = SuggestionStore(); store.prepare(question: item.query)
                sessionAnswerIDs.insert(item.answerID)
                answers.append(AnswerRecord(id: item.answerID, questionID: item.id, automatic: true, sourceFragmentID: item.sourceID,
                                            createdAt: item.receivedAt, store: store, viewed: false))
            }
        }
        answerRevision &+= 1
    }
    private func drainQuestions() {
        queueWake?.cancel(); queueWake = nil
        guard !answerIsRunning, isRunning, settings.automaticSuggestions, !isShuttingDown, speakingSources.isEmpty else { return }
        if let item = questions.take() {
            queuedQuestionCount = questions.pending.count; skippedQuestionCount = questions.droppedCount
            request(query: item.query, mode: .reply, speaker: item.speaker, delegationID: item.delegationID,
                    automatic: true, contextOverride: item.context, pipelineTrace: item.trace, scheduled: item)
            syncQueuedAnswers()
        } else {
            syncQueuedAnswers()
            queuedQuestionCount = questions.pending.count; skippedQuestionCount = questions.droppedCount
            if let next = questions.pending.first {
                let delay = max(0.01, next.readyAt.timeIntervalSinceNow)
                queueWake = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    self?.drainQuestions()
                }
            }
        }
    }
    let sessions: SessionStore
    let hotkeys: HotkeyStore
    let localModels: LocalModelManager
    let onboarding: OnboardingStore
    let updates: AppUpdateController
    let laya: LayaRuntimeManager
    private let layaPredictor: ((String, String) async throws -> Double)?
    private let mockReasoning: (any ReasoningProvider)?
    private let mockEmbedding: (any EmbeddingProvider)?
    private let credentialReader: (@Sendable (CredentialReference, Bool) async throws -> CredentialState)?
    private let emitMockConversation: Bool
    private lazy var layaGate: LayaTriggerController = {
        let gate = LayaTriggerController(predict: { [weak self] text, context in
            guard let self else { throw CancellationError() }
            return try await self.scoreLayaText(text, context: context)
        }, onTrigger: { [weak self] input in self?.dispatchLaya(input) ?? true })
        gate.onError = { [weak self] _ in
            guard let self else { return }
            self.statusMessage = ServiceGuide.text("Laya unavailable — manual generation remains available. Check Live services settings.", "Laya 暂不可用，仍可手动生成回答。请检查“实时服务”设置。", self.settings.language)
        }
        gate.onEvent = { [weak self] event in self?.recordLaya(event) }
        gate.onDecision = { [weak self] score in self?.layaLastScore = score }
        gate.onTrace = { trace, stage in DebugLog.log(trace.logLine(stage)) }
        return gate
    }()
    let appleSpeech = AppleSpeechManager()
    private var localEmbedding: LocalEmbeddingProvider?
    private var retrievalPreparationTask: Task<Void, Never>?
    @Published private(set) var isPreparingRetrieval = false
    @Published private(set) var retrievalLoadFailed = false
    @Published private(set) var speechRuntime: CapabilityRuntimeState = .idle
    private var speechRuntimeService: ListeningService?
    private var speechRuntimeLanguage: AppleSpeechLanguage?
    var currentSpeechRuntime: CapabilityRuntimeState {
        guard speechRuntimeService == settings.listeningService,
              settings.listeningService != .apple || speechRuntimeLanguage == settings.appleSpeechLanguage else { return .idle }
        return speechRuntime
    }
    var currentKnowledgeRuntime: CapabilityRuntimeState {
        if isPreparingRetrieval { return .loading }
        if localEmbedding?.isPrepared == true { return .ready }
        return retrievalLoadFailed ? .failed : .idle
    }
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
    private var sessionWasVoice = false
    private var sessionAnswerIDs = Set<UUID>()
    private var archivedAnswerSessions: [UUID: UUID] = [:]
    private var namingGenerations: [UUID: UUID] = [:]
    private var namingTasks: [UUID: Task<Void, Never>] = [:]
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
            if oldValue.reasoningService != settings.reasoningService || oldValue.analysisModel != settings.analysisModel ||
                (try? oldValue.analysisCredentialReference()) != (try? settings.analysisCredentialReference()) {
                translation.stop()
            }
            if oldValue.professionalTerms != settings.professionalTerms || oldValue.professionalTermsEnabled != settings.professionalTermsEnabled {
                let terms = activeProfessionalTerms
                (systemLive as? LocalLiveProvider)?.updateTerms(terms, displayTerms: settings.professionalTermsEnabled ? settings.professionalTerms : [])
                (micLive as? LocalLiveProvider)?.updateTerms(terms, displayTerms: settings.professionalTermsEnabled ? settings.professionalTerms : [])
            }
            if oldValue.automaticSuggestions != settings.automaticSuggestions ||
                oldValue.scenario != settings.scenario ||
                oldValue.mode != settings.mode || oldValue.listeningService != settings.listeningService {
                questions.clear(); queueWake?.cancel(); queuedQuestionCount = 0
                invalidateAutomaticTrigger()
                configureAutomaticTrigger()
            } else if oldValue.layaThreshold != settings.layaThreshold {
                configureAutomaticTrigger(prepare: false)
            }
            if answerIsRunning && !settings.isEnabled(activeStore?.mode ?? suggestion.mode) { cancelAnswer() }
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
            if oldValue.knowledgeMode != settings.knowledgeMode {
                if settings.knowledgeMode.usesKnowledgeBase { prepareLocalRetrieval() }
                else { retrievalPreparationTask?.cancel() }
            }
            if oldValue.embeddingService != settings.embeddingService || oldValue.embeddingModel != settings.embeddingModel {
                embeddingVerificationEpoch = UUID(); embeddingVerificationTask?.cancel(); embeddingVerificationTask = nil
                embeddingVerification = .idle
                prepareLocalRetrieval()
            }
        }
    }
    @Published var isRunning = false
    @Published var isTransitioning = false
    @Published private(set) var embeddingVerification: ServiceVerification = .idle
    private var embeddingVerificationTask: Task<Void, Never>?
    private var embeddingVerificationEpoch = UUID()
    @Published var hasAPIKey = false
    @Published var isCheckingKey = false
    @Published var keyNeedsAuthorization = false
    @Published var hasAnalysisKey = false
    @Published var isCheckingAnalysisKey = false
    @Published var analysisKeyNeedsAuthorization = false
    @Published var analysisKeyStatus = "No credential available."
    @Published private(set) var answerCredentialRevision = UUID()
    @Published private(set) var verifiedAnalysisSettings: AppSettings?
    private var verifiedCredentialRevision: UUID?
    @Published private(set) var liveKeyCheckFeedback: CredentialCheckFeedback?
    @Published private(set) var analysisKeyCheckFeedback: CredentialCheckFeedback?
    @Published var keyStatus = "No credential available."
    @Published var statusMessage = "Ready — type a question or start listening"
    @Published var questionState = QuestionPhase.listening.rawValue
    @Published private(set) var layaGateStatus: LayaGateEvent = .idle
    private func recordLaya(_ event: LayaGateEvent) {
        if ![.ownSpeechStarted, .ownSpeechEnded, .otherSpeechStarted, .otherSpeechEnded, .inputReceived, .received, .predictionStarted, .predictionCompleted, .discarded].contains(event) { layaGateStatus = event }
        if !isMock { LayaGateDiagnostics.record(event) }
    }
    @Published private(set) var layaLastScore: Double?
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var isIndexing = false
    @Published private(set) var indexingProgress = 0.0
    @Published private(set) var indexingDocumentCount = 0
    @Published private(set) var indexingCompletedDocumentCount = 0
    @Published private(set) var indexingDocumentID: String?
    @Published private(set) var indexingSucceeded = false
    @Published var knowledgeMessage = ""
    @Published var includeConversation = true
    @Published var micEnabled = true
    @Published private(set) var conversationGeneration = UUID()
    var onHotkeysChanged: (() -> Void)?
    var onHotkeyRecordingChanged: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    @Published var overlayCaptureProtection: WindowCaptureProtection.Status = .disabled
    var onOpenOnboarding: (() -> Void)?
    var onShowOverlayTips: (() -> Void)?
    var onShowOverlay: ((_ automatic: Bool) -> Void)?

    init(mock: Bool = AppPaths.isMock,
         layaRoot: URL? = nil, layaPredictor: ((String, String) async throws -> Double)? = nil,
         mockReasoning: (any ReasoningProvider)? = nil,
         emitMockConversation: Bool = true, mockDefaults: UserDefaults? = nil,
         mockEmbedding: (any EmbeddingProvider)? = nil, mockKnowledgeDirectory: URL? = nil,
         credentialReader: (@Sendable (CredentialReference, Bool) async throws -> CredentialState)? = nil) {
        isMock = mock
        sessions = SessionStore(root: AppPaths.dataDirectory(mock: mock).appendingPathComponent("sessions", isDirectory: true))
        self.credentialReader = mock ? credentialReader : nil
        updates = AppUpdateController(mock: mock)
        self.layaPredictor = mock ? layaPredictor : nil
        self.mockReasoning = mock ? mockReasoning : nil
        self.mockEmbedding = mock ? mockEmbedding : nil
        self.emitMockConversation = emitMockConversation
        localModels = LocalModelManager(root: AppPaths.modelsDirectory(mock: mock))
        laya = LayaRuntimeManager(root: layaRoot ?? AppPaths.dataDirectory(mock: mock).appendingPathComponent("Laya", isDirectory: true))
        let preview = AppPaths.isOnboardingPreview
        settingsDefaults = mock ? (mockDefaults ?? UserDefaults(suiteName: preview ? "com.livecopilot.onboarding-preview.preferences" : "com.livecopilot.mock")!) : .standard
        onboarding = OnboardingStore(defaults: settingsDefaults, dataDirectory: AppPaths.dataDirectory(mock: mock))
        hotkeys = HotkeyStore(defaults: settingsDefaults)
        settings = AppSettings.load(defaults: settingsDefaults)
        if onboarding.isNewInstall && (!mock || preview) {
            settings.listeningService = .zipformer
            settings.embeddingService = .local
            settings.reasoningService = .separateOpenAI
            settings.automaticSuggestions = laya.state != .unsupported
            settings.save(defaults: settingsDefaults)


        }
        do { knowledge = try KnowledgeIndex(directory: (mock ? mockKnowledgeDirectory : nil) ?? AppPaths.dataDirectory(mock: mock).appendingPathComponent("knowledge")) }
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
        localModels.$installed.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareLocalRetrieval() }
        }.store(in: &cancellables)
        Task { await refreshKnowledge() }
    }
    /// Local transcribers use Laya; GPT-Live-1 owns its client delegation decisions.
    private var usesLaya: Bool { settings.listeningService.isLocal }
    private func invalidateAutomaticTrigger(releaseRuntime: Bool = true) {
        questions.clear(); syncQueuedAnswers(); queueWake?.cancel(); queuedQuestionCount = 0; skippedQuestionCount = 0
        questionTask?.cancel(); questionTask = nil; pendingAutomatic = nil
        layaLastScore = nil
        layaGate.reset()
        if releaseRuntime { laya.stop() }
    }
    private func configureAutomaticTrigger(prepare: Bool = true) {
        let selected = isRunning && settings.automaticSuggestions && usesLaya && !isShuttingDown
        if !selected { recordLaya(.disabled) }
        else if layaPredictor == nil && !laya.isReady { recordLaya(laya.isBusy ? .loading : .unavailable) }
        else if [.loading, .unavailable, .disabled].contains(layaGateStatus) { recordLaya(.idle) }
        layaGate.configure(enabled: selected && (laya.isReady || layaPredictor != nil),
                           threshold: settings.layaThreshold, cooldown: 0.75)
        if selected {
            for speaker in speakingSources { layaGate.setSpeaking(true, speaker: speaker) }
            if prepare && layaPredictor == nil && !laya.isReady && !laya.isBusy { laya.prepare() }
        }
    }
    private func manualIntervention() {
        questions.clear(); syncQueuedAnswers(); queueWake?.cancel(); queuedQuestionCount = 0; skippedQuestionCount = 0
        pendingAutomatic = nil; questionTask?.cancel(); questionTask = nil
        layaGate.manualIntervention()
    }
    /// Shares live scoring, but never enters the live gate or calls a reasoning provider.
    func testLayaTrigger(text: String) async throws -> LayaDiagnosticResult {
        guard !isRunning, !isTransitioning, !isShuttingDown, !isTestingLaya else { throw LayaRuntimeError.unavailable }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 65536 else { throw LayaRuntimeError.invalidInput }
        isTestingLaya = true
        defer { isTestingLaya = false }
        let threshold = settings.layaThreshold
        let start = ProcessInfo.processInfo.systemUptime
        if layaPredictor == nil { try await laya.prepareAndWait() }
        let prepared = ProcessInfo.processInfo.systemUptime
        let score = try await scoreLayaText(text, context: "")
        try Task.checkCancellation()
        return LayaDiagnosticResult(score: score, threshold: threshold,
                                    decision: .evaluate(score: score, threshold: threshold),
                                    preparationMS: (prepared - start) * 1000,
                                    predictionMS: (ProcessInfo.processInfo.systemUptime - prepared) * 1000)
    }
    @Published private(set) var isTestingLaya = false
    private func scoreLayaText(_ text: String, context: String) async throws -> Double {
        try Task.checkCancellation()
        let score: Double
        if let predict = layaPredictor { score = try await predict(text, context) }
        else { score = try await laya.predict(text: text, context: context) }
        guard score.isFinite, (0...1).contains(score) else {
            throw CopilotError.message("Laya returned an invalid confidence.")
        }
        return score
    }
    func cancelLayaRuntime() {
        invalidateAutomaticTrigger(releaseRuntime: false)
        laya.cancel()
        configureAutomaticTrigger(prepare: false)
    }
    private func submitLaya(speaker: Speaker, partial: String? = nil) {
        guard isRunning, settings.automaticSuggestions, usesLaya else { return }
        recordLaya(.inputReceived)
        guard isMock || (speaker == .them ? systemAudio.isCapturing : mic.isCapturing) else { recordLaya(.captureInactive); return }
        if speaker == .you { layaGate.manualIntervention(); recordLaya(.ownTranscript); return }
        // Very short ASR previews are often noise or an unfinished syllable.
        // They must not retire a complete question while the pause timer runs.
        if let partial, partial.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { recordLaya(.shortPreview); return }
        guard layaPredictor != nil || laya.isReady else { recordLaya(laya.isBusy ? .loading : .unavailable); return }
        // Use the same caption grouping as dispatch, without mutating conversation state.
        var snapshot = conversation
        if let partial {
            let now = Date()
            let offset = Int(now.timeIntervalSince(sessionStartedAt ?? now) * 1000)
            _ = snapshot.append(.init(id: "laya-preview", speaker: speaker, text: " " + partial,
                                      startMS: offset, endMS: offset, receivedAt: now))
        }
        guard let text = snapshot.candidate(speaker: speaker, now: Date(), cooldown: 0, force: partial != nil, semanticDetection: true) else {
            recordLaya(snapshot.phase == .answered ? .ownTranscript : snapshot.phase == .duplicate ? .duplicate : .noCandidate)
            return
        }
        layaGate.submit(.init(text: text, context: snapshot.layaContext(speaker: speaker, now: Date(), force: partial != nil),
                              speaker: speaker, isFinal: partial == nil, answerContext: snapshot.context(),
                              sourceID: partial == nil ? snapshot.latestFragmentID(speaker: speaker) : nil))
    }
    private func dispatchLaya(_ input: LayaTriggerInput) -> Bool {
        guard isRunning, !isTransitioning, !isShuttingDown, usesLaya, settings.automaticSuggestions else { return true }
        guard let candidate = conversation.candidate(speaker: input.speaker, now: Date(), cooldown: 0, semanticDetection: true),
              candidate == input.text else { recordLaya(.staleCandidate); return true }
        recordLaya(.dispatched)
        // No fabricated OpenAI tool-call ID: Laya is an independent automatic origin.
        request(query: candidate, mode: .reply, speaker: input.speaker, automatic: true, contextOverride: input.answerContext ?? conversation.context(), pipelineTrace: input.trace)
        return true
    }
    /// Deterministic audio-free input for the existing mock mode and native integration tests.
    func receiveMockEvent(_ event: LiveEvent, speaker: Speaker) {
        guard isMock else { return }
        receive(event, speaker: speaker, epoch: liveEpoch)
    }
    @discardableResult func updateHotkey(_ combo: HotkeyCombo, for mode: SuggestionMode) -> Bool {
        guard hotkeys.set(combo, for: mode) else { return false }
        onHotkeysChanged?(); return true
    }
    @discardableResult func resetHotkey(_ mode: SuggestionMode) -> Bool {
        updateHotkey(HotkeyStore.defaultCombos[mode]!, for: mode)
    }
    @discardableResult func updateOverlayHotkey(_ combo: HotkeyCombo) -> Bool {
        guard hotkeys.setToggleOverlay(combo) else { return false }
        onHotkeysChanged?(); return true
    }
    @discardableResult func resetOverlayHotkey() -> Bool { updateOverlayHotkey(HotkeyStore.defaultToggleOverlay) }
    @discardableResult func refreshKeyState(interactive: Bool = false) -> Task<Void, Never>? {
        guard !isCheckingKey else { return nil }
        liveKeyCheckFeedback = interactive ? .checking : nil
        if isMock && credentialReader == nil {
            hasAPIKey = true
            if interactive { liveKeyCheckFeedback = .found }
            return nil
        }
        answerCredentialRevision = UUID()
        isCheckingKey = true
        if !interactive { cachedKey = nil; hasAPIKey = false; keyNeedsAuthorization = false }
        keyStatus = "Checking Keychain…"
        let revision = UUID(); credentialRevision = revision
        return Task {
            defer { if credentialRevision == revision { isCheckingKey = false } }
            do {
                // A locked Keychain or its access prompt must never freeze the native UI.
                let result = try await readCredential(.live, interactive: interactive)
                let key = result.key
                guard credentialRevision == revision else { return }
                if cachedKey != key {
                    embeddingVerificationEpoch = UUID(); embeddingVerificationTask?.cancel(); embeddingVerificationTask = nil; embeddingVerification = .idle
                }
                cachedKey = key; hasAPIKey = key != nil
                DebugLog.log("credential.ready role=live available=\(hasAPIKey)")
                keyNeedsAuthorization = result.needsAuthorization
                keyStatus = result.message
                if interactive { liveKeyCheckFeedback = .resolve(checking: false, available: hasAPIKey, authorization: keyNeedsAuthorization, status: keyStatus) }
                if key == nil { statusMessage = result.needsAuthorization ? result.message : "No key available — open Settings to configure Keychain." }
                if let key, !interactive { runStartupCheckIfRequested(key: key) }
            } catch {
                guard credentialRevision == revision else { return }
                cachedKey = nil; hasAPIKey = false; statusMessage = error.localizedDescription
                keyStatus = error.localizedDescription
                if interactive { liveKeyCheckFeedback = .failed }
            }
        }
    }
    @discardableResult func refreshAnalysisKeyState(interactive: Bool = false) -> Task<Void, Never>? {
        analysisKeyCheckFeedback = interactive ? .checking : nil
        answerCredentialRevision = UUID()
        let revision = UUID(); analysisCredentialRevision = revision
        if !interactive { cachedAnalysisKey = nil; hasAnalysisKey = false; analysisKeyNeedsAuthorization = false }
        isCheckingAnalysisKey = false
        guard settings.reasoningService != .sharedOpenAI else {
            analysisKeyStatus = "Using the Live service credential."
            analysisKeyCheckFeedback = nil
            return interactive ? refreshKeyState(interactive: true) : nil
        }
        guard !isMock || credentialReader != nil else {
            hasAnalysisKey = true; analysisKeyStatus = "Mock providers — no credential needed."
            if interactive { analysisKeyCheckFeedback = .found }
            return nil
        }
        do {
            let reference = try settings.analysisCredentialReference()
            analysisCredentialReference = reference
            isCheckingAnalysisKey = true
            analysisKeyStatus = "Checking Keychain…"
            return Task {
                defer { if analysisCredentialRevision == revision { isCheckingAnalysisKey = false } }
                do {
                    let result = try await readCredential(reference, interactive: interactive)
                    let key = result.key
                    guard analysisCredentialRevision == revision else { return }
                    cachedAnalysisKey = key; hasAnalysisKey = key != nil
                    DebugLog.log("credential.ready role=analysis available=\(hasAnalysisKey)")
                    analysisKeyNeedsAuthorization = result.needsAuthorization
                    analysisKeyStatus = result.message
                    if interactive { analysisKeyCheckFeedback = .resolve(checking: false, available: hasAnalysisKey, authorization: analysisKeyNeedsAuthorization, status: analysisKeyStatus) }
                } catch {
                    guard analysisCredentialRevision == revision else { return }
                    cachedAnalysisKey = nil; hasAnalysisKey = false
                    analysisKeyStatus = error.localizedDescription
                    if interactive { analysisKeyCheckFeedback = .failed }
                }
            }
        } catch {
            analysisKeyStatus = error.localizedDescription
            if interactive { analysisKeyCheckFeedback = .failed }
            return nil
        }
    }
    private func readCredential(_ reference: CredentialReference, interactive: Bool) async throws -> CredentialState {
        if let credentialReader { return try await credentialReader(reference, interactive) }
        return try await CredentialVault.shared.read(reference, interactive: interactive)
    }
    func clearCredentialCheckFeedback(analysis: Bool) {
        if analysis { analysisKeyCheckFeedback = nil } else { liveKeyCheckFeedback = nil }
    }
    func saveCredential(_ value: String, analysis: Bool) async throws {
        guard !isMock else { return }
        let reference = analysis ? try settings.analysisCredentialReference() : .live
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        clearCredentialCheckFeedback(analysis: analysis)
        try await CredentialVault.shared.save(value, for: reference)
        answerCredentialRevision = UUID()
        if reference == .live {
            credentialRevision = UUID(); isCheckingKey = false
            cachedKey = value; hasAPIKey = true; keyNeedsAuthorization = false; keyStatus = "Saved in macOS Keychain."
            embeddingVerificationEpoch = UUID(); embeddingVerificationTask?.cancel(); embeddingVerificationTask = nil; embeddingVerification = .idle
            if settings.embeddingService == .openAI { Task { await self.verifyEmbeddingIfNeeded() } }
        } else if (try? settings.analysisCredentialReference()) == reference {
            analysisCredentialRevision = UUID(); isCheckingAnalysisKey = false
            cachedAnalysisKey = value; hasAnalysisKey = true; analysisKeyNeedsAuthorization = false; analysisKeyStatus = "Saved in macOS Keychain."
        }
    }
    var hasAnswerCredential: Bool { settings.reasoningService == .sharedOpenAI ? hasAPIKey : hasAnalysisKey }
    var isAnalysisConnectionVerified: Bool {
        guard let verifiedAnalysisSettings, verifiedCredentialRevision == answerCredentialRevision else { return false }
        return settings.reasoningService == verifiedAnalysisSettings.reasoningService &&
            settings.analysisModel == verifiedAnalysisSettings.analysisModel &&
            (try? settings.analysisCredentialReference()) == (try? verifiedAnalysisSettings.analysisCredentialReference()) &&
            settings.reasoningEffort == verifiedAnalysisSettings.reasoningEffort &&
            settings.analysisProcessing == verifiedAnalysisSettings.analysisProcessing &&
            settings.deepSeekEffort == verifiedAnalysisSettings.deepSeekEffort &&
            settings.presetConnection == verifiedAnalysisSettings.presetConnection
    }

    var isKnowledgeServiceVerified: Bool {
        settings.embeddingService == .local ? localModels.embeddingVerification.isReady : hasAPIKey && embeddingVerification.isReady
    }
    var knowledgeNeedsReindex: Bool {
        knowledgeDocuments.contains { $0.embeddingModel != settings.selectedEmbeddingIdentity }
    }
    func verifyEmbeddingIfNeeded() async {
        if settings.embeddingService == .local { await localModels.verifyEmbeddingIfNeeded() }
        else if hasAPIKey && embeddingVerification == .idle { try? await testEmbeddingConnection() }
    }
    /// Uses fixed text only. Existing documents and indexes are not modified.
    func testEmbeddingConnection() async throws {
        if let embeddingVerificationTask {
            await embeddingVerificationTask.value
            try Task.checkCancellation()
            if case .failed(let message) = embeddingVerification { throw CopilotError.message(message) }
            guard embeddingVerification.isReady else { throw CancellationError() }
            return
        }
        let model = settings.embeddingModel, savedKey = cachedKey
        let key = isMock ? "mock" : try credential()
        let epoch = UUID(); embeddingVerificationEpoch = epoch
        embeddingVerification = .checking
        let operation = Task { @MainActor in
            do {
                let provider: any EmbeddingProvider = isMock ? (mockEmbedding ?? MockEmbeddingProvider()) : OpenAIEmbeddingProvider(key: key, model: model)
                try await EmbeddingConnectionProbe.run(provider: provider)
                try Task.checkCancellation()
                guard epoch == embeddingVerificationEpoch, cachedKey == savedKey, model == settings.embeddingModel, settings.embeddingService == .openAI else { return }
                embeddingVerification = .ready
            } catch {
                guard !Task.isCancelled, epoch == embeddingVerificationEpoch, cachedKey == savedKey, model == settings.embeddingModel, settings.embeddingService == .openAI else { return }
                embeddingVerification = .failed(error.localizedDescription)
            }
        }
        embeddingVerificationTask = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        // A cancelled/replaced test must not reset a newer task or publish success.
        guard epoch == embeddingVerificationEpoch, cachedKey == savedKey, model == settings.embeddingModel else { throw CancellationError() }
        embeddingVerificationTask = nil
        if Task.isCancelled { embeddingVerification = .idle; throw CancellationError() }
        if case .failed(let message) = embeddingVerification { throw CopilotError.message(message) }
    }

    /// Explicit connection check; never captures or transmits microphone/system audio.
    func testLiveConnection() async throws {
        guard !isRunning, !isMock else {
            throw CopilotError.message("Stop listening before testing the speech connection.")
        }
        let testedSettings = settings, revision = credentialRevision
        let provider = OpenAILiveProvider(key: try credential(), model: testedSettings.liveModel,
            speaker: .them, scenario: testedSettings.scenario, language: testedSettings.liveSpeechLanguage)
        try await LiveConnectionProbe.run(provider: provider)
        try Task.checkCancellation()
        guard revision == credentialRevision, settings.liveModel == testedSettings.liveModel else {
            throw CopilotError.message("Speech configuration changed. Test the connection again.")
        }
    }

    /// Only invoked by the explicit onboarding test button; never includes user data.
    func testAnalysisConnection() async throws {
        let testedSettings = settings, credentialRevision = answerCredentialRevision
        verifiedAnalysisSettings = nil
        let provider: any ReasoningProvider = isMock ? (mockReasoning ?? MockReasoningProvider()) :
            try ReasoningProviderFactory.make(settings: settings, liveKey: cachedKey, analysisKey: cachedAnalysisKey)
        try await AnalysisConnectionProbe.run(provider: provider)
        try Task.checkCancellation()
        guard credentialRevision == answerCredentialRevision else { return }
        verifiedCredentialRevision = credentialRevision
        verifiedAnalysisSettings = testedSettings
    }
    func onboardingAnswer(_ question: String) throws -> AsyncThrowingStream<String, Error> {
        guard question.count <= 8000 else { throw CopilotError.message("Keep a manual question under 8,000 characters.") }
        let provider: any ReasoningProvider = isMock ? (mockReasoning ?? MockReasoningProvider()) :
            try ReasoningProviderFactory.make(settings: settings, liveKey: cachedKey, analysisKey: cachedAnalysisKey)
        let request = AnswerRequest(query: RetrievalQuery.formulate(question: question, context: "", previousQuestion: nil),
                                    conversation: "", scenario: settings.scenario, sources: [], mode: .reply,
                                    knowledgeMode: settings.knowledgeMode, answerLanguage: settings.answerLanguage)
        return provider.stream(request)
    }
    func removeCredential(analysis: Bool) async throws {
        guard !isMock else { return }
        let reference = analysis ? try settings.analysisCredentialReference() : .live
        try await CredentialVault.shared.remove(reference)
        answerCredentialRevision = UUID()
        if reference == .live { embeddingVerificationEpoch = UUID(); embeddingVerificationTask?.cancel(); embeddingVerificationTask = nil; embeddingVerification = .idle; credentialRevision = UUID(); isCheckingKey = false; refreshKeyState() }
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
        guard !isRunning, !isTransitioning, !isIndexing, !answerIsRunning else { return }
        if kind == .embedding {
            retrievalPreparationTask?.cancel()
            localEmbedding?.close(); localEmbedding = nil
        }
        if kind == .embedding { retrievalLoadFailed = false }
        localModels.remove(kind)
    }

    private func embeddingProvider(requireReady: Bool = false) throws -> any EmbeddingProvider {
        if isMock { return mockEmbedding ?? MockEmbeddingProvider() }
        if settings.embeddingService == .local {
            if requireReady, !LocalModelKind.embedding.isInstalled(in: localModels.root) { throw CopilotError.message("Download the local embedding model in Services first.") }
            if localEmbedding == nil { localEmbedding = LocalEmbeddingProvider(directory: LocalModelKind.embedding.location(in: localModels.root)) }
            return localEmbedding!
        }
        return OpenAIEmbeddingProvider(key: cachedKey ?? "", model: settings.embeddingModel)
    }
    /// Pay the one-time local load before a question arrives, only for a usable library.
    /// No ASR fragment retrieval, document re-indexing, model download or cloud call.
    private func prepareLocalRetrieval() {
        guard !isShuttingDown, settings.knowledgeMode.usesKnowledgeBase, settings.embeddingService == .local, retrievalPreparationTask == nil,
              knowledgeDocuments.contains(where: { $0.chunkCount > 0 }),
              let provider = (try? embeddingProvider(requireReady: true)) as? any LocalEmbeddingPreparing,
              knowledgeDocuments.contains(where: { $0.chunkCount > 0 && $0.embeddingModel == provider.model }),
              !provider.isPrepared else { return }
        isPreparingRetrieval = true; retrievalLoadFailed = false
        retrievalPreparationTask = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            defer { self?.isPreparingRetrieval = false; self?.retrievalPreparationTask = nil }
            do {
                try await provider.prepare()
                DebugLog.log("retrieval.prepare ready elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            } catch {
                self?.retrievalLoadFailed = !Task.isCancelled
                // Retrieval retains its existing keyword fallback. Do not interrupt listening.
                DebugLog.log("retrieval.prepare \(Task.isCancelled ? "cancelled" : "failed")")
            }
        }
    }
    func start() async {
        guard !isRunning, !isTransitioning, !isShuttingDown, !updates.installationCommitted else { return }
        isTransitioning = true; defer { isTransitioning = false }
        if !isMock { LayaGateDiagnostics.begin() }
        recordLaya(.idle)
        if !isMock { CaptureDiagnostics.record(.listeningStart, details: .init(listeningService: settings.listeningService.rawValue, captureMode: settings.mode.rawValue, automatic: settings.automaticSuggestions)) }
        prepareLocalRetrieval()
        invalidateAutomaticTrigger(releaseRuntime: false)
        let epoch = UUID(); liveEpoch = epoch
        saveSession()
        guard sessionStartedAt == nil else { statusMessage = sessions.lastError ?? "Session history could not be saved."; return }
        translation.resetSession(); conversation.reset(); transcript.clear(); activeDelegations = []; speakingSources = []
        sessionStartedAt = Date(); sessionWasVoice = true; sessionAnswerIDs = []
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
            CaptureDiagnostics.record(.speechConnecting)
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
    var activeProfessionalTerms: [String] {
        guard settings.professionalTermsEnabled else { return [] }
        return ProfessionalTerms.recognitionTerms(settings.professionalTerms,
            tokensURL: LocalModelKind.terminologySpeech.location(in: localModels.root).appendingPathComponent("tokens.txt"))
    }
    private func makeLive(key: String, speaker: Speaker, epoch: UUID) -> any LiveProvider {
        let provider: any LiveProvider
        if settings.listeningService == .apple, #available(macOS 26, *) {
            provider = AppleLiveProvider(speaker: speaker, language: settings.appleSpeechLanguage, sessionStart: sessionStartedAt ?? Date())
        } else if let kind = settings.listeningService.localModel {
            provider = LocalLiveProvider(directory: kind.location(in: localModels.root), speaker: speaker, sessionStart: sessionStartedAt ?? Date(),
                                         contextual: kind == .terminologySpeech, terms: activeProfessionalTerms, displayTerms: settings.professionalTermsEnabled ? settings.professionalTerms : [])
        } else { provider = OpenAILiveProvider(key: key, model: settings.liveModel, speaker: speaker, scenario: settings.scenario, language: settings.liveSpeechLanguage) }
        speechRuntimeService = settings.listeningService
        speechRuntimeLanguage = settings.appleSpeechLanguage
        speechRuntime = .loading
        provider.onEvent = { [weak self] event in self?.receive(event, speaker: speaker, epoch: epoch) }
        return provider
    }
    private func receive(_ event: LiveEvent, speaker: Speaker, epoch: UUID) {
        guard epoch == liveEpoch else { return }
        switch event {
        case .speechActivity(let active):
            if usesLaya, isRunning { recordLaya(speaker == .you ? (active ? .ownSpeechStarted : .ownSpeechEnded) : (active ? .otherSpeechStarted : .otherSpeechEnded)) }
            if active { speakingSources.insert(speaker); if pendingAutomatic?.speaker == speaker { questionTask?.cancel() } }
            else { speakingSources.remove(speaker); if pendingAutomatic != nil { scheduleAutomatic() } }
            if usesLaya, isRunning { layaGate.setSpeaking(active, speaker: speaker) }
            if !active {
                if settings.continuousQuestionPolicy == .complete { questions.postponeUntilQuiet() }
                drainQuestions()
            }
        case .partialTranscript(let text):
            transcript.setPartial(text, speaker: speaker)
            translation.updatePreview(text, speaker: speaker)
            if !text.isEmpty { questionState = QuestionPhase.forming.rawValue }
            if !text.isEmpty { submitLaya(speaker: speaker, partial: text) }
        case .transcript(let fragment):
            transcript.clearPartial(speaker)
            translation.updatePreview("", speaker: speaker)
            guard conversation.append(fragment) else { return }
            transcript.ingest(fragment)
            translation.update(lines: transcript.lines)
            if speaker == .you { systemLive?.appendContext("You said: " + fragment.text, delegationID: nil) }
            questionState = conversation.phase.rawValue
            if usesLaya { submitLaya(speaker: speaker) }
            else if pendingAutomatic != nil { scheduleAutomatic() }
        case .delegation(let id, _):
            guard !usesLaya, isRunning, settings.automaticSuggestions, speaker != .you, activeDelegations.insert(id).inserted else { return }
            if activeDelegations.count > 400 { activeDelegations = [id] }
            pendingAutomatic = (speaker, id, Date().addingTimeInterval(25))
            scheduleAutomatic()
        case .ready: if !isMock { CaptureDiagnostics.record(.speechReady, details: .init(speaker: speaker.rawValue)) }; speechRuntime = .ready; statusMessage = "Listening · \(settings.mode.rawValue) · \(speaker.rawValue) ready"
        case .status(let message): statusMessage = message
        case .failed(let message):
            if !isMock { CaptureDiagnostics.record(.speechFailed, details: .init(speaker: speaker.rawValue)) }
            speechRuntime = .failed
            layaGate.reset()
            transcript.clearPartial(speaker)
            translation.updatePreview("", speaker: speaker)
            statusMessage = message
            if settings.listeningService.isLocal, isRunning, !isTransitioning {
                Task { await stop(); statusMessage = message }
            }
        case .closed(let finalized):
            if speechRuntime != .failed { speechRuntime = .idle }
            speakingSources.remove(speaker)
            layaGate.reset()
            configureAutomaticTrigger(prepare: false)
            transcript.clearPartial(speaker)
            translation.updatePreview("", speaker: speaker)
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
            guard let question = self.conversation.candidate(speaker: pending.speaker, now: Date(), cooldown: 0) else {
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
        translation.stop()
        embeddingVerificationTask?.cancel(); await embeddingVerificationTask?.value
        isShuttingDown = true
        retrievalPreparationTask?.cancel()
        await retrievalPreparationTask?.value
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
        if !isMock { CaptureDiagnostics.record(.listeningStop) }
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
        // Finish and archive stable/final ASR before clearing the visible conversation.
        if resume { await stop() } else { saveSession() }
        guard sessionStartedAt == nil else {
            statusMessage = sessions.lastError ?? "Session history could not be saved. Check available disk space and permissions."
            return
        }
        isTransitioning = true
        liveEpoch = UUID() // Invalidate old callbacks BEFORE disconnect can flush a final segment.
        invalidateAutomaticTrigger()
        cancelAnswer(); answerTask = nil
        questionTask?.cancel(); questionTask = nil; pendingAutomatic = nil
        mockTask?.cancel(); mockTask = nil
        sessionStartedAt = nil // The completed round was archived above.
        isRunning = false
        translation.resetSession(); conversation.reset(); transcript.clear(); suggestion.reset(); answers.removeAll(); selectedAnswerID = nil
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
    private func archiveAnswer(_ record: AnswerRecord) -> SessionAnswer {
        let store = record.store
        return SessionAnswer(id: record.id, questionID: record.questionID, automatic: record.automatic,
                             createdAt: record.createdAt, answeredAt: store.answeredAt, completedAt: store.completedAt,
                             question: store.question, text: store.text, state: store.state.rawValue,
                             warning: store.warning, error: store.error, sources: store.citedSources.map { citation in
            let chunk = citation.source.chunk
            return SessionCitation(index: citation.index, documentID: chunk.documentID, documentName: chunk.documentName,
                                   page: chunk.page, ordinal: chunk.ordinal, excerpt: chunk.text)
        }, sourceFragmentID: record.sourceFragmentID)
    }
    func saveSession() {
        guard let started = sessionStartedAt else { return }
        let savedAnswers = answers.filter { sessionAnswerIDs.contains($0.id) }.map(archiveAnswer)
        let lines = transcript.archiveSnapshot(since: started)
        if !lines.isEmpty || !savedAnswers.isEmpty {
            guard let record = sessions.saveSnapshot(lines: lines, startedAt: started,
                fragments: transcript.fragmentRevisions.filter { $0.receivedAt >= started }, answers: savedAnswers) else { return }
            for answer in savedAnswers { archivedAnswerSessions[answer.id] = record.id }
            if sessionWasVoice && !isMock && !record.namingInput.isEmpty { nameSession(record) }
        }
        sessionStartedAt = nil; sessionWasVoice = false; sessionAnswerIDs = []
    }
    func renameSession(_ id: UUID, title: String) {
        guard SessionNaming.clean(title) != nil else { return }
        namingGenerations[id] = nil
        namingTasks.removeValue(forKey: id)?.cancel()
        sessions.rename(id, title: title)
    }
    func regenerateSessionTitle(_ id: UUID) {
        guard let record = sessions.sessions.first(where: { $0.id == id }),
              !record.namingInput.isEmpty else { return }
        nameSession(record)
    }
    private func nameSession(_ record: SessionRecord) {
        guard namingTasks[record.id] == nil else { return }
        guard sessions.update(record.id, change: { $0.namingState = "pending" }) else { return }
        let generation = UUID()
        namingGenerations[record.id] = generation
        let settings = settings, liveKey = cachedKey, analysisKey = cachedAnalysisKey
        namingTasks[record.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.namingGenerations[record.id] == generation {
                    self.namingTasks[record.id] = nil; self.namingGenerations[record.id] = nil
                }
            }
            do {
                let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: liveKey, analysisKey: analysisKey)
                let title = try await SessionNaming.generate(for: record, provider: provider)
                try Task.checkCancellation()
                guard self.namingGenerations[record.id] == generation else { return }
                self.sessions.update(record.id) { $0.generatedTitle = title; $0.namingState = "named" }
            } catch {
                guard self.namingGenerations[record.id] == generation else { return }
                self.sessions.update(record.id) { $0.namingState = "failed" }
            }
        }
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
        var snapshot = conversation
        let latestSpeaker: Speaker = settings.mode == .inPerson ? .room : .them
        if !transcript.partialThem.isEmpty {
            let now = Date(), offset = Int(Date().timeIntervalSince(sessionStartedAt ?? Date()) * 1000)
            _ = snapshot.append(.init(id: "manual-preview", speaker: latestSpeaker, text: " " + transcript.partialThem,
                                      startMS: offset, endMS: offset, receivedAt: now))
        }
        let context = snapshot.context()
        let latest = snapshot.candidate(speaker: latestSpeaker, now: Date(), cooldown: 0, force: true, semanticDetection: true)
        guard !context.isEmpty else { statusMessage = "No conversation yet. Type a question below to ask directly."; onShowOverlay?(false); return }
        let query: String
        switch mode {
        case .reply: query = latest ?? "Help me answer the latest substantive question in this conversation."
        case .recap: query = "Summarize the recent conversation, decisions and unresolved questions."
        case .followUp: query = "Suggest one useful follow-up question based on this conversation."
        }
        request(query: query, mode: mode, speaker: mode == .reply ? latestSpeaker : nil, useContext: true,
                contextOverride: context, languageQuestion: latest)
    }
    func askText(_ query: String) { manualIntervention(); request(query: query, mode: .reply, useContext: includeConversation) }
    func cancelAnswer() {
        manualIntervention()
        activeStore?.mark(.cancelled); activeStore?.interrupt()
        if let store = activeStore { publishAnswer(requestID, store: store) }
        requestID = UUID(); answerTask?.cancel(); answerTimeout?.cancel(); answerIsRunning = false
        conversation.finish(success: false, question: activeStore?.question ?? suggestion.question)
        activeStore = nil
        questionState = conversation.phase.rawValue
    }
    private func request(query: String, mode: SuggestionMode, speaker: Speaker? = nil,
                         delegationID: String? = nil, useContext: Bool = true,
                         automatic: Bool = false, contextOverride: String? = nil, pipelineTrace: PipelineTrace? = nil, languageQuestion: String? = nil, scheduled: QuestionCoordinator.Candidate? = nil) {
        if automatic && scheduled == nil {
            questions.enqueue(query: query, context: contextOverride ?? conversation.context(), speaker: speaker,
                              delegationID: delegationID, trace: pipelineTrace, sourceID: conversation.latestFragmentID(speaker: speaker), policy: settings.continuousQuestionPolicy)
            conversation.begin(query, speaker: speaker, now: Date())
            queuedQuestionCount = questions.pending.count; skippedQuestionCount = questions.droppedCount
            syncQueuedAnswers()
            drainQuestions()
            return
        }
        if !automatic { cancelAnswer() }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isTransitioning, !isShuttingDown else { return }
        guard query.count <= 8000 else { suggestion.fail("Keep a manual question under 8,000 characters."); return }
        if sessionStartedAt == nil { sessionStartedAt = Date(); sessionWasVoice = false; sessionAnswerIDs = [] }
        let settings = settings, liveKey = cachedKey, analysisKey = cachedAnalysisKey
        let embedding = settings.knowledgeMode.usesKnowledgeBase ? try? embeddingProvider() : nil
        let id = scheduled?.answerID ?? UUID(); requestID = id
        sessionAnswerIDs.insert(id)
        let output = answers.first(where: { $0.id == id })?.store ?? SuggestionStore()
        activeStore = output; answerIsRunning = true
        let show = !automatic || selectedAnswerID == nil
        if !answers.contains(where: { $0.id == id }) {
            answers.append(AnswerRecord(id: id, questionID: scheduled?.id ?? UUID(), automatic: automatic, sourceFragmentID: scheduled?.sourceID,
                                        createdAt: Date(), store: output, viewed: show))
        }
        if show {
            selectedAnswerID = id
            if let index = answers.firstIndex(where: { $0.id == id }) { answers[index].viewed = true }
        }
        let context = useContext ? (contextOverride ?? conversation.context()) : ""
        let previous = useContext && conversation.previousQuestion != query ? conversation.previousQuestion : nil
        let normalized = RetrievalQuery.formulate(question: query, context: context, previousQuestion: previous)
        if scheduled == nil { conversation.begin(query, speaker: speaker, now: Date()) }
        questionState = conversation.phase.rawValue
        output.begin(mode: mode, question: query)
        output.trace = pipelineTrace ?? PipelineTrace(id: id)
        output.mark(.analysisDispatched)
        publishAnswer(id, store: output)
        onShowOverlay?(automatic)
        answerTimeout?.cancel()
        answerTimeout = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.answerTimeoutSeconds * 1_000_000_000)) } catch { return }
            guard self.requestID == id, self.answerIsRunning else { return }
            self.answerTask?.cancel(); self.requestID = UUID()
            output.fail(ServiceGuide.text("Answer timed out. Try again manually.", "回答超时，请手动重试。", self.settings.language))
            self.publishAnswer(id, store: output); self.answerIsRunning = false; self.activeStore = nil
            self.conversation.finish(success: false, question: query)
            self.drainQuestions()
        }
        let epoch = liveEpoch, started = ProcessInfo.processInfo.systemUptime
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                var sources: [RetrievedSource] = []
                do {
                    if !settings.knowledgeMode.usesKnowledgeBase {
                        // General mode must not read documents or start embeddings.
                    } else if let knowledge = self.knowledge {
                        let documents = try await knowledge.documents()
                        if documents.contains(where: { $0.chunkCount > 0 }) {
                            var vector: [Float]?
                            do {
                                guard let embedding else { throw CopilotError.message("Embedding unavailable") }
                                // An index built with another embedding model cannot use this vector.
                                if documents.contains(where: { $0.chunkCount > 0 && $0.embeddingModel == embedding.model }) {
                                    output.mark(.embeddingStart)
                                    vector = try await embedding.embed([normalized.semantic]).first
                                    try Task.checkCancellation(); guard self.requestID == id else { return }
                                    output.mark(.embeddingComplete)
                                }
                            } catch {
                                try Task.checkCancellation()
                                guard self.requestID == id else { return }
                                output.warning = "Semantic retrieval unavailable; using local keyword search."
                            }
                            sources = try await knowledge.retrieve(query: normalized, vector: vector, model: embedding?.model ?? settings.selectedEmbeddingIdentity, limit: settings.retrievalCount)
                        }
                    } else { throw CopilotError.message("Knowledge unavailable") }
                } catch {
                    try Task.checkCancellation()
                    guard self.requestID == id else { return }
                    output.warning = settings.knowledgeMode == .hybrid
                        ? "Knowledge database unavailable; answering from general context."
                        : "Knowledge database unavailable; strict mode cannot answer without evidence."
                }
                try Task.checkCancellation(); guard self.requestID == id else { return }
                output.sources = sources
                output.retrievalMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                output.mark(.ragComplete)
                if settings.knowledgeMode == .knowledgeBaseOnly && sources.isEmpty {
                    let missing = settings.bilingualAnswers
                        ? AnswerLanguage.chinese.missingEvidence(question: query) + "\n" + AnswerLanguage.english.missingEvidence(question: query)
                        : settings.answerLanguage.missingEvidence(question: languageQuestion ?? query)
                    output.appendDelta(missing)
                } else {
                    var answer = AnswerRequest(query: normalized, conversation: context, scenario: settings.scenario, sources: sources, mode: mode,
                                               knowledgeMode: settings.knowledgeMode, answerLanguage: settings.answerLanguage, bilingualAnswers: settings.bilingualAnswers, additionalAnswerInstructions: settings.additionalAnswerInstructions, languageQuestion: languageQuestion)
                    answer.onStreamProgress = { [weak self] stage, time in
                        guard let coordinator = self else { return }
                        await MainActor.run {
                            guard coordinator.requestID == id, output.isLoading else { return }
                            output.mark(stage, at: time)
                            coordinator.publishAnswer(id, store: output)
                        }
                    }
                    let reasoning: any ReasoningProvider = self.isMock ? (self.mockReasoning ?? MockReasoningProvider()) :
                        try ReasoningProviderFactory.make(settings: settings, liveKey: liveKey, analysisKey: analysisKey)
                    output.mark(.modelRequest)
                    var first = true
                    for try await delta in reasoning.stream(answer) {
                        try Task.checkCancellation(); guard self.requestID == id else { return }
                        guard !delta.isEmpty else { continue }
                        if first {
                            output.firstTextMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000); first = false
                            output.mark(.firstToken)
                        }
                        output.appendDelta(delta)
                        self.publishAnswer(id, store: output)
                    }
                }
                guard self.requestID == id else { return }
                output.mark(.answerComplete)
                output.finish(); self.conversation.finish(success: true, question: query)
                if let delegationID, self.liveEpoch == epoch {
                    let summary = "Assistance completed in the text overlay for the question. Brief result: " + String(output.text.prefix(900))
                    (speaker == .room ? self.micLive : self.systemLive)?.appendContext(summary, delegationID: delegationID)
                }
            } catch {
                guard self.requestID == id, !Task.isCancelled else { return }
                output.mark(.failed)
                output.fail(error.localizedDescription); self.conversation.finish(success: false, question: query)
            }
            guard self.requestID == id else { return }
            self.answerTimeout?.cancel(); self.answerIsRunning = false; self.activeStore = nil
            self.publishAnswer(id, store: output)
            self.drainQuestions()
            self.questionState = self.conversation.phase.rawValue
            if self.pendingAutomatic != nil { self.scheduleAutomatic() }
            self.layaGate.retryPending()
        }
    }
    func refreshKnowledge() async {
        guard let knowledge else { return }
        do { knowledgeDocuments = try await knowledge.documents(); prepareLocalRetrieval() }
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
        // Each document has equal weight, including the actual completed portion of the
        // active document. The denominator stays fixed for this batch, not the library.
        indexingCompletedDocumentCount = offset + (value == 1 ? 1 : 0)
        indexingProgress = (Double(offset) + value) / Double(max(1, count))
        if value == 0 || value == 1 { await refreshKnowledge() }
    }
    private func beginIndexing(count: Int) {
        indexingDocumentCount = count
        indexingCompletedDocumentCount = 0
        indexingProgress = 0
        indexingSucceeded = false
        indexingDocumentID = nil
        isIndexing = true
    }
    func importDocuments(_ urls: [URL]) {
        guard !isIndexing, let knowledge else { return }
        let documents: [URL]
        do { documents = try DocumentImport.validate(urls) }
        catch { knowledgeMessage = error.localizedDescription; return }
        guard !documents.isEmpty else { return }
        beginIndexing(count: documents.count)
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
        beginIndexing(count: 1)
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
        beginIndexing(count: documents.count)
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
