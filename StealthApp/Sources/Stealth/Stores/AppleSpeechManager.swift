import Foundation
import Combine

@MainActor final class AppleSpeechManager: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?
    private var revision = UUID()
    var available: Bool { AppleSpeechSupport.available }
    func refresh(_ language: AppleSpeechLanguage) async {
        let id = UUID(); revision = id
        let ready = await AppleSpeechSupport.installed(language)
        guard revision == id else { return }
        installed = ready
        if !busy { message = available ? (ready ? "Installed · offline ready" : "Not downloaded") : "Apple speech requires macOS 26 and a supported Mac and language." }
    }
    func install(_ language: AppleSpeechLanguage) {
        guard !busy else { return }
        busy = true; message = "Downloading Apple speech language…"
        task = Task {
            do {
                try await AppleSpeechSupport.install(language)
                message = "Installed · offline ready"
            } catch is CancellationError { message = "Apple speech download cancelled." }
            catch { message = "Apple speech download failed. Check the network and retry." }
            busy = false; installed = await AppleSpeechSupport.installed(language)
            task = nil
        }
    }
    func cancel() { task?.cancel() }
    func shutdown() async { task?.cancel(); await task?.value }
}
