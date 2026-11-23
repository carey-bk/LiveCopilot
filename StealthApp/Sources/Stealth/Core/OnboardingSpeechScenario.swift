import Foundation

/// Speech guidance is separate from the answer-style scenario and never starts downloads.
enum OnboardingSpeechScenario: String, Codable, CaseIterable, Identifiable {
    case mixedInterview, singleLanguage, multilingualMeeting
    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .mixedInterview: return ServiceGuide.text("Chinese + English", "中英混合", language)
        case .singleLanguage: return ServiceGuide.text("One language", "单语言", language)
        case .multilingualMeeting: return ServiceGuide.text("More languages", "更多语言", language)
        }
    }
    var engine: ListeningService {
        switch self {
        case .mixedInterview: return .zipformer
        case .singleLanguage: return .apple
        case .multilingualMeeting: return .openAI
        }
    }
}

