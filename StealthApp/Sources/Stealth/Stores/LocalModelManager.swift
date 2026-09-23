import Foundation
import Combine

@MainActor
final class LocalModelManager: ObservableObject {
    let root: URL
    @Published private(set) var installed: Set<LocalModelKind> = []
    @Published private(set) var downloading: LocalModelKind?
    @Published private(set) var message = ""
    @Published private(set) var messageKind: LocalModelKind?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var transferStatus = ""
    private var task: Task<Void, Never>?
    init(root: URL) { self.root = root; refresh() }
    func refresh() { installed = Set(LocalModelKind.allCases.filter { $0.isInstalled(in: root) }) }
    func install(_ kind: LocalModelKind) {
        guard task == nil else { return }
        downloadProgress = nil; transferStatus = ""
        downloading = kind; messageKind = kind; message = "Downloading local model…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = nil; self.task = nil; self.refresh() }
            do {
                try await LocalModelInstaller.install(kind, root: self.root, downloader: { [weak self] item, destination in
                    try await LocalModelInstaller.download(item, to: destination) { fraction, detail in
                        Task { @MainActor in self?.downloadProgress = fraction; self?.transferStatus = detail }
                    }
                }, status: { [weak self] value in
                    Task { @MainActor in self?.message = value }
                })
                self.message = "Local model installed. It can run offline."
            } catch is CancellationError { self.message = "Model download cancelled. The previous model was preserved." }
            catch let error as URLError where error.code == .cancelled { self.message = "Model download cancelled. The previous model was preserved." }
            catch { self.message = error is CopilotError ? error.localizedDescription : "Model download failed. Check the network and retry." }
        }
    }
    func cancel() { task?.cancel() }
    func shutdown() async { task?.cancel(); await task?.value }
}
