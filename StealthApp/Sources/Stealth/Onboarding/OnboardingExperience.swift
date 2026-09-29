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

/// A transparent, opt-in plan. Applying it never downloads, grants access, or changes credentials.
struct OnboardingRecommendation: Equatable {
    let scenario: ScenarioProfile
    let typing: Bool
    let speech: ListeningService
    let jevSupported: Bool
    var recommendsJev: Bool { !typing && jevSupported }
    var wantsKnowledge: Bool { scenario != .meeting }
    init(scenario: ScenarioProfile, typing: Bool, appleReady: Bool, jevSupported: Bool = true) {
        self.scenario = scenario; self.typing = typing; self.jevSupported = jevSupported
        speech = appleReady ? .apple : .paraformer
    }
    func applying(to settings: AppSettings) -> AppSettings {
        var result = settings
        if !typing { result.listeningService = speech; result.automaticSuggestions = recommendsJev }
        if wantsKnowledge { result.embeddingService = .local }
        return result
    }
    @MainActor static func current(_ coordinator: AppCoordinator) -> Self {
        Self(scenario: coordinator.settings.scenario, typing: coordinator.onboarding.state.prefersTyping,
             appleReady: coordinator.appleSpeech.available && coordinator.appleSpeech.installed && !coordinator.appleSpeech.busy,
             jevSupported: coordinator.laya.state != .unsupported)
    }
    @MainActor static func apply(_ coordinator: AppCoordinator) {
        guard !coordinator.isRunning, !coordinator.isTransitioning, !coordinator.isIndexing,
              coordinator.localModels.downloading == nil, !coordinator.appleSpeech.busy, !coordinator.laya.isBusy else { return }
        let plan = current(coordinator)
        coordinator.settings = plan.applying(to: coordinator.settings)
        coordinator.onboarding.state.wantsKnowledge = plan.wantsKnowledge
    }
}
