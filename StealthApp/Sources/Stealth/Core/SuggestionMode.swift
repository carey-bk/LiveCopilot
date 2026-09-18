import Foundation

/// What kind of on-demand assistance the user is asking for.
enum SuggestionMode: String, CaseIterable, Identifiable {
    case reply
    case recap
    case followUp

    var id: String { rawValue }

    /// Short label for the overlay card header.
    var label: String {
        switch self {
        case .reply: return "Generate answer"
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
