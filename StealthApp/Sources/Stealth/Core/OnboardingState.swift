import Foundation

enum OnboardingStep: Int, Codable, CaseIterable, Identifiable {
    // Raw IDs are persisted by older guides; declaration order drives navigation.
    case language = 0, workflow = 6, introduction = 1, models = 2, analysis = 3, ready = 5
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(Int.self)
        // The retired permission step now lives on the input-mode page.
        guard let step = Self(rawValue: id == 4 ? Self.introduction.rawValue : id) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown onboarding step")
        }
        self = step
    }
    var position: Int { Self.allCases.firstIndex(of: self)! }
    var id: Int { rawValue }
}

/// Completion records the user's navigation choice, never capability readiness.
struct OnboardingState: Codable, Equatable {
    enum Disposition: String, Codable { case inProgress, deferred, completed, existingUser }
    static let defaultsKey = "livecopilot.onboarding.v1"
    var version = 1
    var step = OnboardingStep.language
    var disposition = Disposition.inProgress
    var prefersTyping = false
    var wantsKnowledge = false
    // Missing in older saved guides: preserve their existing selections.
    var localSetupReviewed: Bool? = false
    var speechScenario: OnboardingSpeechScenario?
    var speechManuallySelected: Bool?
    var jevChoiceReviewed: Bool?
    // Independent of spoken languages; nil preserves older guides' actual choice.
    var knowledgeRequested: Bool?

    var shouldPresent: Bool { disposition == .inProgress }
    mutating func advance() { step = OnboardingStep.allCases[min(step.position + 1, OnboardingStep.allCases.count - 1)] }
    mutating func back() { step = OnboardingStep.allCases[max(0, step.position - 1)] }
    mutating func reopen() {
        if disposition == .completed || disposition == .existingUser { step = .language }
        disposition = .inProgress
    }
    static func load(defaults: UserDefaults, hasExistingData: Bool) -> Self {
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 { return saved }
        // Saved settings (including a damaged file) and existing data belong to an
        // existing user. Never infer a first launch from an async credential check.
        let existing = defaults.object(forKey: "livecopilot.settings") != nil || hasExistingData
        return Self(disposition: existing ? .existingUser : .inProgress, localSetupReviewed: existing ? true : false)
    }
    func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A request deliberately containing no transcript, knowledge, or personal context.
enum AnalysisConnectionProbe {
    static var request: AnswerRequest {
        AnswerRequest(query: RetrievalQuery.formulate(question: "Reply with OK to this connection test.", context: "", previousQuestion: nil),
                      conversation: "", scenario: .meeting, sources: [], mode: .reply)
    }
    static func run(provider: any ReasoningProvider) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var receivedText = false
                for try await delta in provider.stream(request) {
                    try Task.checkCancellation()
                    if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { receivedText = true }
                }
                guard receivedText else { throw CopilotError.message("The service returned no text. Check the model and retry.") }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw CopilotError.message("Connection test timed out. Check the network and retry.")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
