import Foundation

/// Native capture format and bounded UI context, retained from Stealth.
enum Config {
    static let realtimeSampleRate: Double = 24_000
    static let suggestionContextWindow: TimeInterval = 90
    static let transcriptLineLimit = 400
    // Upstream's current working default is off. Headphones reduce remote/mic bleed.
    static let micEchoCancellation = false
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
