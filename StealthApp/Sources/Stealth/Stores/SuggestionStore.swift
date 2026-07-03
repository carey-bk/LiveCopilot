import Foundation
import Combine

/// Holds the latest suggested reply plus loading / error state for the overlay card.
@MainActor
final class SuggestionStore: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?
    /// Which kind of suggestion is currently shown (for the card header).
    @Published private(set) var mode: SuggestionMode = .reply

    func begin(mode: SuggestionMode = .reply) {
        self.mode = mode
        isLoading = true
        error = nil
        text = ""
    }

    /// Streaming token from the model response.
    func appendDelta(_ delta: String) {
        text += delta
    }

    func finish() {
        isLoading = false
    }

    func fail(_ message: String) {
        isLoading = false
        error = message
    }

    func reset() {
        text = ""
        isLoading = false
        error = nil
    }
}
