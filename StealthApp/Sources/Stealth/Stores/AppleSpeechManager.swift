import Foundation
import Combine

@MainActor final class AppleSpeechManager: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checkedLanguage: AppleSpeechLanguage?
    @Published private(set) var busy = false
    @Published private(set) var failedLanguage: AppleSpeechLanguage?
    var downloadFailed: Bool { failedLanguage != nil }
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?
    private var revision = UUID()
    var available: Bool { AppleSpeechSupport.available }
    func refresh(_ language: AppleSpeechLanguage) async {
        let id = UUID(); revision = id
        let ready = await AppleSpeechSupport.installed(language)
        guard revision == id else { return }
        installed = ready
        checkedLanguage = language
        if !busy { message = available ? (ready ? "Installed · offline ready" : "Not downloaded") : "Apple speech requires macOS 26 and a supported Mac and language." }
    }
    func install(_ language: AppleSpeechLanguage) {
        guard !busy else { return }
        busy = true; failedLanguage = nil; message = "Downloading Apple speech language…"
        task = Task {
            var wasCancelled = false
            do {
                try await AppleSpeechSupport.install(language)
                message = "Installed · offline ready"
            } catch is CancellationError {
                wasCancelled = true
                message = "Apple speech download cancelled."
            }
            catch { failedLanguage = language; message = "Apple speech download failed. Check the network and retry." }
            busy = false
            if !wasCancelled, !Task.isCancelled {
                installed = await AppleSpeechSupport.installed(language)
                checkedLanguage = language
            }
            task = nil
        }
    }
    func cancel() { task?.cancel() }
    func shutdown() async { task?.cancel(); await task?.value }
}
