import Foundation
import Combine

@MainActor
final class LocalModelManager: ObservableObject {
    let root: URL
    @Published private(set) var installed: Set<LocalModelKind> = []
    @Published private(set) var downloading: LocalModelKind?
    @Published private(set) var queued: [LocalModelKind] = []
    @Published private(set) var failures: [LocalModelKind: String] = [:]
    @Published private(set) var message = ""
    @Published private(set) var messageKind: LocalModelKind?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var transferStatus = ""
    @Published private(set) var embeddingVerification: ServiceVerification = .idle
    private var verificationTask: Task<Void, Never>?
    private let embeddingVerifier: (@MainActor (URL) async throws -> Void)?
    @Published private(set) var checking: LocalModelKind?
    @Published private(set) var health: [LocalModelKind: LocalModelHealth] = [:]
    private let checker: @Sendable (LocalModelKind, URL) async throws -> LocalModelHealth
    private var task: Task<Void, Never>?
    private let installation: (@MainActor (LocalModelKind, URL) async throws -> Void)?
    init(root: URL, checker: @escaping @Sendable (LocalModelKind, URL) async throws -> LocalModelHealth = { try await LocalModelSelfCheck.run($0, root: $1) }, embeddingVerifier: (@MainActor (URL) async throws -> Void)? = nil, installation: (@MainActor (LocalModelKind, URL) async throws -> Void)? = nil) {
        self.root = root; self.checker = checker; self.installation = installation; self.embeddingVerifier = embeddingVerifier; refresh()
    }
    func refresh() {
        installed = Set(LocalModelKind.allCases.filter { $0.isInstalled(in: root) })
        if !installed.contains(.embedding) { embeddingVerification = .idle }
    }
    func verifyEmbeddingIfNeeded() async {
        guard embeddingVerification == .idle else { return }
        await verifyEmbedding()
    }
    func verifyEmbedding() async {
        guard verificationTask == nil, installed.contains(.embedding) else { return }
        embeddingVerification = .checking
        checking = .embedding; health[.embedding] = nil
        let operation = Task { @MainActor in
            do {
                if let embeddingVerifier { try await embeddingVerifier(LocalModelKind.embedding.location(in: root)) }
                else {
                    try await check(.embedding)
                    return
                }
                try Task.checkCancellation()
                embeddingVerification = .ready
            } catch is CancellationError { embeddingVerification = .idle }
            catch { embeddingVerification = .failed(error.localizedDescription) }
        }
        verificationTask = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        verificationTask = nil; checking = nil; installNext()
    }
    func enqueue(_ kinds: [LocalModelKind]) {
        refresh()
        for kind in kinds where !installed.contains(kind) && downloading != kind && !queued.contains(kind) { queued.append(kind) }
        installNext()
    }
    private func installNext() {
        guard task == nil, verificationTask == nil, !queued.isEmpty else { return }
        let kind = queued.removeFirst()
        if installed.contains(kind) { installNext() } else { install(kind) }
    }
    func install(_ kind: LocalModelKind) {
        guard task == nil, verificationTask == nil else { return }
        if kind == .embedding { embeddingVerification = .idle }
        failures[kind] = nil; health[kind] = nil
        downloadProgress = nil; transferStatus = ""
        downloading = kind; messageKind = kind; message = "Downloading local model…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = nil; self.checking = nil; self.task = nil; self.refresh(); self.installNext() }
            do {
                if let installation = self.installation { try await installation(kind, self.root) }
                else { try await LocalModelInstaller.install(kind, root: self.root, downloader: { [weak self] item, destination in
                    try await LocalModelInstaller.download(item, to: destination) { [weak self] fraction, detail in
                        Task { @MainActor in guard self?.checking == nil else { return }; self?.downloadProgress = fraction; self?.transferStatus = detail }
                    }
                }, status: { [weak self] value in
                    Task { @MainActor in guard self?.checking == nil else { return }; self?.message = value }
                }) }
                self.refresh()
                if kind == .embedding {
                    await self.verifyEmbedding()
                    self.message = self.embeddingVerification.message
                } else { try await self.check(kind) }
            } catch is CancellationError { self.message = "Model download cancelled. The previous model was preserved."; self.failures[kind] = self.message }
            catch let error as URLError where error.code == .cancelled { self.message = "Model download cancelled. The previous model was preserved."; self.failures[kind] = self.message }
            catch { self.message = error is CopilotError ? error.localizedDescription : "Model download failed. Check the network and retry."; self.failures[kind] = self.message }
        }
    }
    private func check(_ kind: LocalModelKind) async throws {
        checking = kind; health[kind] = nil
        downloadProgress = nil; transferStatus = ""
        messageKind = kind; message = "Checking the local model…"
        if kind == .embedding { embeddingVerification = .checking }
        let report = try await checker(kind, root)
        try Task.checkCancellation()
        health[kind] = report
        failures[kind] = report.ready ? nil : report.stage.rawValue
        if kind == .embedding { embeddingVerification = report.ready ? .ready : .failed(report.advice(english: true)) }
        message = ""
    }
    func runSelfCheck(_ kind: LocalModelKind) {
        guard task == nil, verificationTask == nil else { return }
        downloading = kind
        task = Task {
            defer { checking = nil; downloading = nil; task = nil; refresh(); installNext() }
            do { try await check(kind) }
            catch {
                if kind == .embedding { embeddingVerification = .idle }
                message = "Self-check cancelled. Downloaded files are kept."
            }
        }
    }
    func remove(_ kind: LocalModelKind) {
        guard task == nil, verificationTask == nil else { return }
        messageKind = kind
        do {
            let directory = kind.location(in: root)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            downloadProgress = nil; transferStatus = ""
            health[kind] = nil; failures[kind] = nil
            message = "Local model deleted. Download it again to use it."
        } catch { message = error.localizedDescription }
        refresh()
    }
    func cancel() { queued.removeAll(); task?.cancel(); verificationTask?.cancel() }
    func shutdown() async { cancel(); await task?.value; await verificationTask?.value }
}
