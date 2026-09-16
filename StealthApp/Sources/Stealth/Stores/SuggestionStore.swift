import Foundation
import Combine

@MainActor final class SuggestionStore: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var question = ""
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var mode: SuggestionMode = .reply
    @Published var sources: [RetrievedSource] = []
    @Published var warning: String?
    @Published var retrievalMS = 0
    @Published var firstTextMS: Int?
    func begin(mode: SuggestionMode = .reply, question: String = "") {
        self.mode = mode; self.question = question; isLoading = true; error = nil; text = ""
        sources = []; warning = nil; retrievalMS = 0; firstTextMS = nil
    }
    func appendDelta(_ delta: String) { text += delta }
    func finish() { isLoading = false }
    func fail(_ message: String) { isLoading = false; error = message }
    func reset() { text = ""; question = ""; isLoading = false; error = nil; sources = []; warning = nil; mode = .reply; retrievalMS = 0; firstTextMS = nil }
}
