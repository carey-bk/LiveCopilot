import Foundation

/// Native capture format and bounded UI context, retained from Stealth.
enum Config {
    static let realtimeSampleRate: Double = 24_000
    static let suggestionContextWindow: TimeInterval = 90
    static let transcriptLineLimit = 400
    // Upstream's current working default is off. Headphones reduce remote/mic bleed.
    static let micEchoCancellation = false
}

/// What kind of on-demand assistance the user is asking for.
enum SuggestionMode: String, CaseIterable, Identifiable {
    case reply
    case recap
    case followUp

    var id: String { rawValue }

    /// Short label for the overlay card header.
    var label: String {
        switch self {
        case .reply: return "Reply"
        case .recap: return "Recap"
        case .followUp: return "Follow-up"
        }
    }

    /// SF Symbol for the overlay button.
    var systemImage: String {
        switch self {
        case .reply: return "bubble.left.and.bubble.right"
        case .recap: return "list.bullet.rectangle"
        case .followUp: return "questionmark.bubble"
        }
    }
}

enum ReplyTone: String, CaseIterable, Identifiable {
    case professional
    case casual

    var id: String { rawValue }

    var descriptor: String {
        switch self {
        case .professional: return "polite, professional"
        case .casual: return "friendly, casual"
        }
    }

    var label: String {
        switch self {
        case .professional: return "Professional"
        case .casual: return "Casual"
        }
    }
}
