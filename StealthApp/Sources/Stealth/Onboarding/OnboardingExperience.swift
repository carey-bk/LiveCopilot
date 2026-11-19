import Foundation

/// Guidance is independent of setup completion and never changes runtime readiness.
struct OverlayTourState: Codable, Equatable {
    enum Step: Int, Codable, CaseIterable { case start, answer, visibility, captureExclusion }
    enum Disposition: String, Codable { case pending, active, finished, dismissed }
    static let defaultsKey = "livecopilot.overlay-tour.v1"
    var step = Step.start
    var disposition = Disposition.pending

    mutating func enterOverlay() { if disposition == .pending { disposition = .active } }
    mutating func advance() {
        guard disposition == .active else { return }
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
        else { disposition = .finished }
    }
    mutating func replay() { step = .start; disposition = .active }
    static func load(defaults: UserDefaults, newInstall: Bool) -> Self {
        if let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        // Upgrades, including phase-one installations, keep the tour opt-in.
        return Self(disposition: newInstall ? .pending : .dismissed)
    }
    func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

struct OnboardingRecommendation: Equatable {
    let scenario: ScenarioProfile
    let typing: Bool
    let speech: ListeningService
    let jevSupported: Bool
    let speechScenario: OnboardingSpeechScenario?
    var recommendsJev: Bool { !typing && (speech == .openAI || jevSupported) }
    let wantsKnowledge: Bool
    init(scenario: ScenarioProfile, typing: Bool, appleReady: Bool, jevSupported: Bool = true,
         speechScenario: OnboardingSpeechScenario? = nil, wantsKnowledge: Bool? = nil) {
        self.scenario = scenario; self.typing = typing; self.jevSupported = jevSupported
        self.speechScenario = speechScenario
        self.wantsKnowledge = wantsKnowledge ?? (scenario != .meeting)
        // Keep the legacy initializer's behavior for callers outside the scenario picker.
        speech = speechScenario?.engine(appleAvailable: appleReady) ?? .zipformer
    }
    func applyingSpeech(to settings: AppSettings) -> AppSettings {
        var result = settings
        if !typing {
            result.listeningService = speech
            if speechScenario == .multilingualMeeting { result.liveSpeechLanguage = .unrestricted }
        }
        return result
    }
    func applying(to settings: AppSettings, preserveJev: Bool = false) -> AppSettings {
        var result = applyingSpeech(to: settings)
        if !typing && !preserveJev { result.automaticSuggestions = recommendsJev }
        if wantsKnowledge { result.embeddingService = .local }
        return result
    }
    @MainActor func matches(_ coordinator: AppCoordinator) -> Bool {
        applying(to: coordinator.settings, preserveJev: coordinator.onboarding.state.jevChoiceReviewed == true) == coordinator.settings && coordinator.onboarding.state.wantsKnowledge == wantsKnowledge
    }
    @MainActor static func selectedScenario(_ coordinator: AppCoordinator) -> OnboardingSpeechScenario {
        coordinator.onboarding.state.speechScenario ?? .mixedInterview
    }
    @MainActor static func canEdit(_ coordinator: AppCoordinator) -> Bool {
        !coordinator.isRunning && !coordinator.isTransitioning && !coordinator.isIndexing &&
        coordinator.localModels.downloading == nil && coordinator.localModels.queued.isEmpty &&
        !coordinator.appleSpeech.busy && !coordinator.laya.isBusy
    }
    @MainActor static func current(_ coordinator: AppCoordinator) -> Self {
        Self(scenario: coordinator.settings.scenario, typing: coordinator.onboarding.state.prefersTyping,
             appleReady: coordinator.appleSpeech.available, jevSupported: coordinator.laya.state != .unsupported,
             speechScenario: selectedScenario(coordinator),
             wantsKnowledge: coordinator.onboarding.state.knowledgeRequested ??
                (coordinator.onboarding.state.localSetupReviewed == false ? true : coordinator.onboarding.state.wantsKnowledge))
    }
    @MainActor static func selectScenario(_ scenario: OnboardingSpeechScenario, coordinator: AppCoordinator) {
        guard canEdit(coordinator) else { return }
        // A legacy guide's existing engine is also a user selection, unless it already follows the plan.
        let followsRecommendation = coordinator.onboarding.state.speechManuallySelected != true &&
            current(coordinator).applyingSpeech(to: coordinator.settings) == coordinator.settings
        coordinator.onboarding.state.speechScenario = scenario
        if followsRecommendation {
            coordinator.settings = current(coordinator).applyingSpeech(to: coordinator.settings)
            coordinator.onboarding.state.speechManuallySelected = false
        } else { coordinator.onboarding.state.speechManuallySelected = true }
    }
    @MainActor static func selectSpeech(_ service: ListeningService, coordinator: AppCoordinator) {
        guard canEdit(coordinator) else { return }
        coordinator.onboarding.state.speechManuallySelected = true
        coordinator.settings.listeningService = service
    }
    @MainActor static func selectKnowledge(_ enabled: Bool, coordinator: AppCoordinator) {
        guard canEdit(coordinator) else { return }
        coordinator.onboarding.state.knowledgeRequested = enabled
        coordinator.onboarding.state.wantsKnowledge = enabled
        if enabled { coordinator.settings.embeddingService = .local }
    }
    @MainActor static func applyInitialIfNeeded(_ coordinator: AppCoordinator) {
        guard coordinator.onboarding.state.localSetupReviewed == false, canEdit(coordinator) else { return }
        apply(coordinator)
        coordinator.onboarding.state.localSetupReviewed = true
    }
    @MainActor static func apply(_ coordinator: AppCoordinator) {
        guard canEdit(coordinator) else { return }
        let plan = current(coordinator)
        coordinator.settings = plan.applying(to: coordinator.settings, preserveJev: coordinator.onboarding.state.jevChoiceReviewed == true)
        coordinator.onboarding.state.wantsKnowledge = plan.wantsKnowledge
        coordinator.onboarding.state.knowledgeRequested = plan.wantsKnowledge
        coordinator.onboarding.state.speechScenario = plan.speechScenario
        coordinator.onboarding.state.speechManuallySelected = false
    }
}
