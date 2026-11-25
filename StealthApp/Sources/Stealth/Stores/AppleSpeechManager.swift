import Foundation
import Combine

@MainActor final class AppleSpeechManager: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checkedLanguage: AppleSpeechLanguage?
    @Published private(set) var busy = false
    @Published private(set) var failedLanguage: AppleSpeechLanguage?
    var downloadFailed: Bool { failedLanguage != nil }
    @Published private(set) var message = ""
    /// Languages offered by this Mac; nil until loaded, when pickers show every known language.
    @Published private(set) var supported: Set<AppleSpeechLanguage>?
    func loadSupported() async {
        guard supported == nil else { return }
        let languages = await AppleSpeechSupport.supportedLanguages()
        if !languages.isEmpty { supported = languages }
    }
    private var task: Task<Void, Never>?
    private var revision = UUID()
    var available: Bool { AppleSpeechSupport.available }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private static func key(_ language: AppleSpeechLanguage) -> String { "livecopilot.appleSpeech.installed." + language.rawValue }
    /// The last checked result for `language`, so a relaunch shows it before the system query returns.
    func lastKnownInstalled(_ language: AppleSpeechLanguage) -> Bool {
        checkedLanguage == language ? installed : defaults.bool(forKey: Self.key(language))
    }
    private func remember(_ ready: Bool, _ language: AppleSpeechLanguage) { defaults.set(ready, forKey: Self.key(language)) }
    func refresh(_ language: AppleSpeechLanguage) async {
        let id = UUID(); revision = id
        let ready = await AppleSpeechSupport.installed(language)
        guard revision == id else { return }
        installed = ready
        checkedLanguage = language
        remember(ready, language)
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
                remember(installed, language)
            }
            task = nil
        }
    }
    func cancel() { task?.cancel() }
    func shutdown() async { task?.cancel(); await task?.value }
}
