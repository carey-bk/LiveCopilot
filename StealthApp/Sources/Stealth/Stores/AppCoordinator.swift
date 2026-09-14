import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let transcript = TranscriptStore()
    let suggestion = SuggestionStore()
    let sessions = SessionStore()
    let hotkeys: HotkeyStore
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
    private var pendingAutomatic: (speaker: Speaker, id: String, deadline: Date)?
    private var cancellables = Set<AnyCancellable>()
    private var mockTask: Task<Void, Never>?

    @Published var settings = AppSettings() {
        didSet {
            settings.save(defaults: settingsDefaults)
            if oldValue.reasoningService != settings.reasoningService ||
                oldValue.compatibleBaseURL != settings.compatibleBaseURL || oldValue.compatiblePath != settings.compatiblePath {
                refreshAnalysisKeyState()
            }
        }
    }
    @Published var isRunning = false
    @Published var isTransitioning = false
    @Published var hasAPIKey = false
    @Published var isCheckingKey = false
    @Published var hasAnalysisKey = false
    @Published var isCheckingAnalysisKey = false
    @Published var analysisKeyStatus = "No credential available."
    @Published var keyStatus = "No credential available."
    @Published var statusMessage = "Ready — type a question or start listening"
    @Published var questionState = QuestionPhase.listening.rawValue
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var isIndexing = false
    @Published var knowledgeMessage = ""
    @Published var includeConversation = true
    @Published var micEnabled = true
    @Published var tone = ReplyTone.professional
    var onHotkeysChanged: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onShowOverlay: (() -> Void)?

    init(mock: Bool = ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LIVECOPILOT_MOCK"] == "1") {
        isMock = mock
        settingsDefaults = mock ? UserDefaults(suiteName: "com.livecopilot.mock")! : .standard
        hotkeys = HotkeyStore(defaults: settingsDefaults)
        settings = AppSettings.load(defaults: settingsDefaults)
        do { knowledge = try KnowledgeIndex(directory: AppPaths.dataDirectory(mock: mock).appendingPathComponent("knowledge")) }
        catch { knowledgeMessage = error.localizedDescription }
        if mock { hasAPIKey = true; keyStatus = "Mock providers — no credential needed."; statusMessage = "MOCK MODE — no API calls" }
        else { refreshKeyState() }
        refreshAnalysisKeyState()
        systemAudio.onPCM16 = { [weak self] data in Task { @MainActor in self?.systemLive?.sendAudio(data) } }
        mic.onPCM16 = { [weak self] data in Task { @MainActor in self?.micLive?.sendAudio(data) } }
        systemAudio.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        mic.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        systemAudio.$isCapturing.dropFirst().sink { [weak self] capturing in
            guard let self, !capturing, self.isRunning, !self.isTransitioning else { return }
            let provider = self.systemLive; self.systemLive = nil
            Task { await provider?.disconnect() }
            if !self.mic.isCapturing { self.isRunning = false; self.saveSession() }
        }.store(in: &cancellables)
        mic.$isCapturing.dropFirst().sink { [weak self] capturing in
            guard let self, !capturing, self.isRunning, !self.isTransitioning else { return }
            let provider = self.micLive; self.micLive = nil
            Task { await provider?.disconnect() }
            if !self.systemAudio.isCapturing { self.isRunning = false; self.saveSession() }
        }.store(in: &cancellables)
        sessions.$lastError.compactMap { $0 }.sink { [weak self] message in self?.statusMessage = message }.store(in: &cancellables)
        Task { await refreshKnowledge() }
    }
    func updateHotkey(_ combo: HotkeyCombo, for mode: SuggestionMode) { hotkeys.set(combo, for: mode); onHotkeysChanged?() }
    func resetHotkey(_ mode: SuggestionMode) { hotkeys.reset(mode); onHotkeysChanged?() }
    func refreshKeyState() {
        if isMock { hasAPIKey = true; return }
        guard !isCheckingKey else { return }
        isCheckingKey = true
        cachedKey = nil; hasAPIKey = false
        keyStatus = "Checking Keychain… Complete any macOS access prompt locally."
        let revision = UUID(); credentialRevision = revision
        Task {
            defer { if credentialRevision == revision { isCheckingKey = false } }
            do {
                // A locked Keychain or its access prompt must never freeze the native UI.
                let key = try await Task.detached(priority: .userInitiated) { try KeychainStore.resolve() }.value
                guard credentialRevision == revision else { return }
                cachedKey = key; hasAPIKey = key != nil
                DebugLog.log("credential.ready role=live available=\(hasAPIKey)")
                keyStatus = key == nil ? "No credential available." : "Credential available. No API request made."
                if key == nil { statusMessage = "No key available — open Settings to configure Keychain." }
                if let key { runStartupCheckIfRequested(key: key) }
            } catch {
                guard credentialRevision == revision else { return }
                cachedKey = nil; hasAPIKey = false; statusMessage = error.localizedDescription
                keyStatus = error.localizedDescription
            }
        }
    }
    func refreshAnalysisKeyState() {
        let revision = UUID(); analysisCredentialRevision = revision
        cachedAnalysisKey = nil; hasAnalysisKey = false; isCheckingAnalysisKey = false
        guard settings.reasoningService != .sharedOpenAI else { analysisKeyStatus = "Using the Live service credential."; return }
        guard !isMock else { hasAnalysisKey = true; analysisKeyStatus = "Mock providers — no credential needed."; return }
        do {
            let reference = try settings.analysisCredentialReference()
            analysisCredentialReference = reference
            isCheckingAnalysisKey = true
            analysisKeyStatus = "Checking Keychain… Complete any macOS access prompt locally."
            Task {
                defer { if analysisCredentialRevision == revision { isCheckingAnalysisKey = false } }
                do {
                    let key = try await Task.detached(priority: .userInitiated) {
                        try KeychainStore.read(service: reference.service, account: reference.account)
                    }.value
                    guard analysisCredentialRevision == revision else { return }
                    cachedAnalysisKey = key; hasAnalysisKey = key != nil
                    DebugLog.log("credential.ready role=analysis available=\(hasAnalysisKey)")
                    analysisKeyStatus = key == nil ? "No credential available." : "Credential available. No API request made."
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
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.save(value, service: reference.service, account: reference.account)
        }.value
        if reference == .live {
            credentialRevision = UUID(); isCheckingKey = false
            cachedKey = value; hasAPIKey = true; keyStatus = "Saved in macOS Keychain."
        } else if (try? settings.analysisCredentialReference()) == reference {
            analysisCredentialRevision = UUID(); isCheckingAnalysisKey = false
            cachedAnalysisKey = value; hasAnalysisKey = true; analysisKeyStatus = "Saved in macOS Keychain."
        }
    }
    func removeCredential(analysis: Bool) async throws {
        guard !isMock else { return }
        let reference = analysis ? try settings.analysisCredentialReference() : .live
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.clear(service: reference.service, account: reference.account)
        }.value
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
    private func embeddingProvider(key: String) -> any EmbeddingProvider {
        isMock ? MockEmbeddingProvider() : OpenAIEmbeddingProvider(key: key, model: settings.embeddingModel)
    }
    func start() async {
        guard !isRunning, !isTransitioning, !isShuttingDown else { return }
        isTransitioning = true; defer { isTransitioning = false }
        let epoch = UUID(); liveEpoch = epoch
        conversation.reset(); transcript.clear(); activeDelegations = []
        sessionStartedAt = Date()
        if isMock {
            isRunning = true; statusMessage = "MOCK listening — sample conversation"
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
            let key = try credential()
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
            if systemAudio.isCapturing { systemLive = makeLive(key: key, speaker: .them, epoch: epoch); systemLive?.connect(context: "") }
            if mic.isCapturing {
                let speaker: Speaker = settings.mode == .inPerson ? .room : .you
                micLive = makeLive(key: key, speaker: speaker, epoch: epoch); micLive?.connect(context: "")
            }
            statusMessage = systemAudio.lastError ?? mic.lastError ?? "Connecting Live…"
        } catch { statusMessage = error.localizedDescription; sessionStartedAt = nil }
    }
    private func makeLive(key: String, speaker: Speaker, epoch: UUID) -> any LiveProvider {
        let provider = OpenAILiveProvider(key: key, model: settings.liveModel, speaker: speaker, scenario: settings.scenario)
        provider.onEvent = { [weak self] event in self?.receive(event, speaker: speaker, epoch: epoch) }
        return provider
    }
    private func receive(_ event: LiveEvent, speaker: Speaker, epoch: UUID) {
        guard epoch == liveEpoch else { return }
        switch event {
        case .transcript(let fragment):
            guard conversation.append(fragment) else { return }
            transcript.ingest(fragment)
            if speaker == .you { systemLive?.appendContext("You said: " + fragment.text, delegationID: nil) }
            questionState = conversation.phase.rawValue
            if pendingAutomatic != nil { scheduleAutomatic() }
        case .delegation(let id, _):
            guard settings.automaticSuggestions, speaker != .you, activeDelegations.insert(id).inserted else { return }
            if activeDelegations.count > 400 { activeDelegations = [id] }
            pendingAutomatic = (speaker, id, Date().addingTimeInterval(25))
            scheduleAutomatic()
        case .ready: statusMessage = "Listening · \(settings.mode.rawValue) · \(speaker.rawValue) ready"
        case .status(let message), .failed(let message): statusMessage = message
        case .closed(let finalized):
            if !finalized { DebugLog.log("live.close final_usage_unconfirmed speaker=\(speaker.rawValue)") }
        }
    }
    private func scheduleAutomatic() {
        questionTask?.cancel()
        let epoch = liveEpoch
        questionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self, self.liveEpoch == epoch, self.isRunning,
                  self.settings.automaticSuggestions, let pending = self.pendingAutomatic else { return }
            if Date() > pending.deadline { self.pendingAutomatic = nil; return }
            if self.suggestion.isLoading { return } // Latest follow-up remains queued until answer finishes.
            guard let question = self.conversation.candidate(speaker: pending.speaker, now: Date(), cooldown: self.settings.scenario.cooldown) else {
                self.questionState = self.conversation.phase.rawValue
                if self.conversation.phase == .duplicate || self.conversation.phase == .answered { self.pendingAutomatic = nil }
                else { self.scheduleAutomatic() }
                return
            }
            self.pendingAutomatic = nil
            self.request(query: question, mode: .reply, speaker: pending.speaker, delegationID: pending.id)
        }
    }
    func shutdown() async {
        isShuttingDown = true
        cancelAnswer()
        startupCheckTask?.cancel()
        await startupCheckTask?.value
        await stop(force: true)
    }
    func stop(force: Bool = false) async {
        guard force || !isTransitioning else { return }
        isTransitioning = true; defer { isTransitioning = false }
        liveEpoch = UUID(); isRunning = false
        questionTask?.cancel(); pendingAutomatic = nil; mockTask?.cancel()
        await systemAudio.stop(); mic.stop()
        let a = systemLive, b = micLive; systemLive = nil; micLive = nil
        async let closeA: Void = a?.disconnect() ?? ()
        async let closeB: Void = b?.disconnect() ?? ()
        _ = await (closeA, closeB)
        saveSession()
        statusMessage = "Listening stopped — manual questions remain available"
    }
    func saveSession() {
        if let started = sessionStartedAt {
            _ = sessions.save(lines: transcript.lines, startedAt: started, fragments: conversation.fragments)
        }
        sessionStartedAt = nil
    }
    func toggle() async { if isRunning { await stop() } else { await start() } }
    func toggleMic() {
        guard !isShuttingDown else { return }
        guard settings.mode == .remote else { statusMessage = "Room mode uses the microphone. Stop listening to disable it."; return }
        micEnabled.toggle()
        guard isRunning, !isMock else { return }
        let epoch = liveEpoch
        Task {
            if micEnabled {
                do {
                    let key = try credential(); await mic.start()
                    guard mic.isCapturing, liveEpoch == epoch, isRunning, !isShuttingDown, micEnabled else { return }
                    micLive = makeLive(key: key, speaker: .you, epoch: liveEpoch); micLive?.connect(context: conversation.context())
                } catch { statusMessage = error.localizedDescription }
            } else { mic.stop(); await micLive?.disconnect(); micLive = nil }
        }
    }
    func requestSuggestion(mode: SuggestionMode = .reply) {
        let context = conversation.context()
        guard !context.isEmpty else { statusMessage = "No conversation yet. Type a question below to ask directly."; onShowOverlay?(); return }
        let query: String
        switch mode {
        case .reply: query = "Help me answer the latest substantive question in this conversation."
        case .recap: query = "Summarize the recent conversation, decisions and unresolved questions."
        case .followUp: query = "Suggest one useful follow-up question based on this conversation."
        }
        request(query: query, mode: mode, useContext: true)
    }
    func askText(_ query: String) { request(query: query, mode: .reply, useContext: includeConversation) }
    func cancelAnswer() {
        requestID = UUID(); answerTask?.cancel(); suggestion.finish()
        conversation.finish(success: false, question: suggestion.question)
        questionState = conversation.phase.rawValue
    }
    private func request(query: String, mode: SuggestionMode, speaker: Speaker? = nil,
                         delegationID: String? = nil, useContext: Bool = true) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard query.count <= 8000 else { suggestion.fail("Keep a manual question under 8,000 characters."); return }
        let reasoning: any ReasoningProvider
        do {
            reasoning = isMock ? MockReasoningProvider() : try ReasoningProviderFactory.make(settings: settings, liveKey: cachedKey, analysisKey: cachedAnalysisKey)
        } catch { suggestion.fail(error.localizedDescription); onShowOverlay?(); return }
        let embedding = embeddingProvider(key: cachedKey ?? "")
        if delegationID == nil { pendingAutomatic = nil; questionTask?.cancel() }
        answerTask?.cancel()
        let id = UUID(); requestID = id
        let context = useContext ? conversation.context() : ""
        let previous = useContext ? conversation.previousQuestion : nil
        let normalized = RetrievalQuery.formulate(question: query, context: context, previousQuestion: previous)
        conversation.begin(query, speaker: speaker, now: Date())
        questionState = conversation.phase.rawValue
        suggestion.begin(mode: mode, question: query)
        onShowOverlay?()
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
                let answer = AnswerRequest(query: normalized, conversation: context, scenario: settings.scenario, sources: sources)
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
        }
    }
    func refreshKnowledge() async {
        guard let knowledge else { return }
        do { knowledgeDocuments = try await knowledge.documents() }
        catch { knowledgeMessage = error.localizedDescription }
    }
    func importDocuments(_ urls: [URL]) {
        guard !isIndexing, let knowledge else { return }
        isIndexing = true
        Task {
            defer { isIndexing = false }
            do {
                let provider = embeddingProvider(key: isMock ? "" : try credential())
                for url in urls {
                    knowledgeMessage = "Indexing \(url.lastPathComponent)…"
                    do { _ = try await knowledge.importDocument(url, provider: provider) }
                    catch { knowledgeMessage = error.localizedDescription; await refreshKnowledge(); return }
                    await refreshKnowledge()
                }
                knowledgeMessage = "Indexing complete. Retrieval is local."
            } catch { knowledgeMessage = error.localizedDescription }
        }
    }
    func reindex(_ document: KnowledgeDocument) {
        guard !isIndexing, let knowledge else { return }
        isIndexing = true
        Task {
            defer { isIndexing = false }
            do {
                knowledgeMessage = "Re-indexing \(document.name)…"
                _ = try await knowledge.reindex(document, provider: embeddingProvider(key: isMock ? "" : try credential()))
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
}
