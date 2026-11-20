import Foundation
import Combine
import CryptoKit
import Darwin

/// Owns only this app variant's Laya directory. Network access is explicit via install().
@MainActor
final class LayaRuntimeManager: ObservableObject {
    enum State: String { case unsupported, notInstalled, installed, installing, loading, ready, failed }
    let root: URL
    private let resources: URL
    @Published private(set) var state: State = .notInstalled
    @Published private(set) var message = "Download Laya to enable offline question detection."
    @Published private(set) var progress: Double?
    @Published private(set) var transferProgress: Double?
    @Published private(set) var transferStatus = ""
    @Published private(set) var downloadFileIndex: Int?
    @Published private(set) var downloadFileTotal: Int?
    private var task: Task<Void, Error>?
    private var worker: LayaWorker?
    private var installer: LayaWorker?
    private var epoch: UInt64 = 0
    var downloadByteCount: Int64? { LayaDownloadSize.load(resources: resources)?.totalBytes }
    var isReady: Bool { state == .ready }
    var isBusy: Bool { state == .installing || state == .loading }
    var isInstalled: Bool { Self.hasInstallation(root.appendingPathComponent("current"), resources: resources) }

    init(root: URL, resources: URL? = nil) {
        self.root = root
        self.resources = resources ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("LayaRuntime")
        if !Self.supported { state = .unsupported; message = "Laya requires Apple Silicon and macOS 14 or newer." }
        else if isInstalled { state = .installed; message = "Laya is installed. Load it to enable offline detection." }
        else if FileManager.default.fileExists(atPath: root.appendingPathComponent("current/receipt.json").path) {
            message = "A newer Laya model is required. Download it here; your previous files are retained until the update is verified."
        }
    }
    private static var supported: Bool {
        #if arch(arm64)
        if #available(macOS 14, *) { return true }
        #endif
        return false
    }
    func install() { begin(download: true) }
    func prepare() { begin(download: false) }
    private var automaticPreparationAttempted = false
    /// Called on entering local setup. Never retries failure/cancellation or downloads resources.
    func prepareInstalledOnce(enabled: Bool) {
        guard enabled, state == .installed, !automaticPreparationAttempted else { return }
        automaticPreparationAttempted = true
        prepare()
    }
    /// Re-hash the installed files and run a fresh local warmup; never downloads.
    func checkModel() { begin(download: false, reload: true) }
    /// The worker verifies the accepted downloaded checkpoint before publishing ready.
    var checkpointID: String? {
        if let data = try? Data(contentsOf: resources.appendingPathComponent("response-model.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return manifest["id"] as? String
        }
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("pins.json")),
              let pins = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return pins["id"] as? String
    }
    var technicalDetails: String {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("pins.json")),
              let pins = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let source = (pins["source"] as? [String: Any])?["revision"] as? String ?? "—"
        let model = pins["model_revision"] as? String ?? "—"
        let bytes = (pins["model"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
        return "Laya MLX · FP16 · multilingual\nRuntime: \(source)\nModel: \(model)\nCheckpoint: \(checkpointID ?? "—")\nModel files: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))\n\(root.appendingPathComponent("current").path)"
    }
    @Published private(set) var diagnosticEvents: [String] = []
    private func record(_ event: String) {
        diagnosticEvents.append(Date().formatted(date: .omitted, time: .standard) + " · " + event)
        if diagnosticEvents.count > 20 { diagnosticEvents.removeFirst(diagnosticEvents.count - 20) }
    }
    func prepareAndWait() async throws {
        try Task.checkCancellation()
        if isReady { return }
        if task == nil { prepare() }
        guard let pending = task else { throw LayaRuntimeError.unavailable }
        try await pending.value
        try Task.checkCancellation()
        guard isReady else { throw LayaRuntimeError.unavailable }
    }
    func predict(text: String, context: String) async throws -> Double {
        guard isReady, let worker else { throw LayaRuntimeError.unavailable }
        let stamp = epoch
        do {
            let result = try await worker.predict(text: text, context: context)
            try Task.checkCancellation()
            guard stamp == epoch, isReady else { throw CancellationError() }
            return result
        } catch {
            if stamp == epoch {
                worker.stop(); self.worker = nil
                record("prediction_failed"); state = .failed
                message = "Laya stopped. Reload the model; manual generation remains available."
            }
            throw error
        }
    }
    func removeDownloadedFiles() {
        guard !isBusy else { return }
        stop()
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            state = .notInstalled; progress = nil; transferProgress = nil; transferStatus = ""
            downloadFileIndex = nil; downloadFileTotal = nil
            message = "Laya model, runtime and download cache deleted."
        } catch { state = .failed; message = error.localizedDescription }
    }
    func cancel() { stop() }
    func stop() {
        record("stopped")
        epoch &+= 1
        task?.cancel(); task = nil
        worker?.stop(); worker = nil
        installer?.stop(); installer = nil
        progress = nil; downloadFileIndex = nil; downloadFileTotal = nil
        if !Self.supported { state = .unsupported }
        else {
            state = isInstalled ? .installed : .notInstalled
            message = isInstalled ? "Laya is stopped. Downloaded files are retained." : "Download Laya to enable offline question detection."
        }
    }
    func shutdown() async {
        let pending = task
        stop()
        _ = try? await pending?.value
    }
    private func begin(download: Bool, reload: Bool = false) {
        guard Self.supported, task == nil, !isBusy else { return }
        if !download && isReady && !reload { return }
        guard download || isInstalled else {
            state = .notInstalled; message = "Download Laya before loading it."; return
        }
        automaticPreparationAttempted = true
        epoch &+= 1
        let stamp = epoch
        worker?.stop(); worker = nil
        record(download ? "install_started" : "load_and_verify_started")
        state = download ? .installing : .loading
        transferStatus = ""; transferProgress = nil
        downloadFileIndex = nil; downloadFileTotal = nil
        progress = download ? 0 : nil
        message = download ? "Preparing the isolated Laya runtime…" : "Loading Laya locally…"
        task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                if download {
                    let transferUpdate: @Sendable (Double?, String) -> Void = { [weak self] value, detail in
                        Task { @MainActor in
                            guard let self, self.epoch == stamp, self.state == .installing else { return }
                            self.transferProgress = value; self.transferStatus = detail
                        }
                    }
                    let fileUpdate: @Sendable (Int, Int) -> Void = { [weak self] index, total in
                        Task { @MainActor in
                            guard let self, self.epoch == stamp, self.state == .installing else { return }
                            self.downloadFileIndex = index; self.downloadFileTotal = total
                        }
                    }
                    let python = try await LayaBootstrap.prepare(root: self.root, resources: self.resources,
                                                                  progress: transferUpdate, file: fileUpdate)
                    transferUpdate(nil, "")
                    try Task.checkCancellation()
                    guard stamp == self.epoch else { throw CancellationError() }
                    var arguments = ["-I", "-B", self.resources.appendingPathComponent("install.py").path, "--root", self.root.path, "--resources", self.resources.path]
                    if let base = ModelDistribution.baseURL {
                        arguments += ["--download-source", "distribution", "--distribution-base", base.absoluteString]
                    } else { arguments += ["--download-source", "mirror"] }
                    let installer = LayaWorker(executable: python, arguments: arguments, transfer: transferUpdate,
                                               file: fileUpdate) { [weak self] stage, value in
                        Task { @MainActor in
                            guard let self, self.epoch == stamp, self.state == .installing else { return }
                            self.transferStatus = ""; self.transferProgress = nil
                            self.progress = value
                            if stage == "python" || stage == "verifying" || stage == "complete" {
                                self.downloadFileIndex = nil; self.downloadFileTotal = nil
                            }
                            let labels = ["python": "Creating the isolated Python environment…", "dependencies": "Downloading pinned runtime dependencies…", "source": "Installing the verified Laya runtime…", "model": "Downloading the multilingual model…", "verifying": "Checking the local model…", "complete": "Local installation verified."]
                            self.message = labels[stage] ?? "Installing Laya…"
                        }
                    }
                    self.installer = installer
                    try await installer.prepare(timeout: 3600)
                    installer.stop(); self.installer = nil
                }
                try Task.checkCancellation()
                guard stamp == self.epoch, self.isInstalled else { throw LayaRuntimeError.unavailable }
                self.state = .loading; self.progress = nil; self.message = "Loading Laya locally…"
                self.downloadFileIndex = nil; self.downloadFileTotal = nil
                let worker = LayaWorker(installation: self.root.appendingPathComponent("current").resolvingSymlinksInPath(), resources: self.resources) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.epoch == stamp, self.state == .ready else { return }
                        self.record("worker_exited")
                        self.state = .failed
                        self.message = "Laya stopped. Reload the model; manual generation remains available."
                    }
                }
                self.worker = worker
                try await worker.prepare()
                try Task.checkCancellation()
                guard stamp == self.epoch else { throw CancellationError() }
                self.record("warmup_passed · \(self.checkpointID ?? "unknown")"); self.state = .ready; self.message = "Laya is ready. Detection runs offline."; self.task = nil
            } catch {
                if stamp == self.epoch {
                    self.worker?.stop(); self.worker = nil
                    self.installer?.stop(); self.installer = nil
                    self.record("load_or_install_failed · " + error.localizedDescription); self.task = nil; self.progress = nil; self.state = .failed
                    self.downloadFileIndex = nil; self.downloadFileTotal = nil
                    self.message = self.isInstalled
                        ? "Laya was downloaded but could not start. Retry loading it; manual generation remains available."
                        : "Laya installation failed. Check the connection and retry; manual generation remains available."
                }
                throw error
            }
        }
    }
    /// A completion receipt must match bundled pins. A successful warmup is still required for .ready.
    private static func hasInstallation(_ current: URL, resources: URL) -> Bool {
        guard let pinsData = try? Data(contentsOf: resources.appendingPathComponent("pins.json")),
              let pins = try? JSONSerialization.jsonObject(with: pinsData) as? [String: Any],
              let expected = pins["id"] as? String,
              let data = try? Data(contentsOf: current.appendingPathComponent("receipt.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["schema"] as? Int == 1, receipt["pin_id"] as? String == expected,
              let files = receipt["files"] as? [String: String], !files.isEmpty,
              FileManager.default.isExecutableFile(atPath: current.appendingPathComponent("venv/bin/python3").path)
        else { return false }
        let required = ["source/laya_mlx/agent.py", "model/model.safetensors", "model/rl_agent_config.json", "model/encoder/config.json", "model/tokenizer/tokenizer.json"]
        return required.allSatisfy { name in
            files[name]?.count == 64 && FileManager.default.fileExists(atPath: current.appendingPathComponent(name).path)
        }
    }
}

enum LayaBootstrap {
    static func pythonPin(from data: Data) throws -> (url: URL, digest: String) {
        guard let pins = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let python = pins["python"] as? [String: Any],
              let digest = python["sha256"] as? String, digest.count == 64,
              let address = python["url"] as? String, let url = URL(string: address), url.scheme == "https"
        else { throw LayaRuntimeError.installationFailed }
        return (url, digest)
    }
    static func downloadFileTotal(from data: Data) throws -> Int {
        guard let pins = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wheels = pins["wheels"] as? [[String: Any]],
              let model = pins["model"] as? [[String: Any]],
              !wheels.isEmpty, !model.isEmpty, wheels.count + model.count <= 998
        else { throw LayaRuntimeError.installationFailed }
        return 2 + wheels.count + model.count
    }
    static func prepare(root: URL, resources: URL, progress: @escaping @Sendable (Double?, String) -> Void,
                        file: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        let data = try Data(contentsOf: resources.appendingPathComponent("pins.json"))
        let (url, digest) = try pythonPin(from: data)
        let fileTotal = try downloadFileTotal(from: data)
        let fm = FileManager.default
        let directory = root.appendingPathComponent("bootstrap/" + digest)
        let executable = directory.appendingPathComponent("python/bin/python3")
        if fm.isExecutableFile(atPath: executable.path) { return executable }
        let cache = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = cache.appendingPathComponent(digest + ".tar.gz")
        if !(await matches(archive, digest: digest)) {
            if fm.fileExists(atPath: archive.path) { try fm.removeItem(at: archive) }
            file(1, fileTotal)
            try await LocalModelInstaller.download(ModelDownload(url: url, sha256: digest, name: "Python runtime", ossObjectKey: "laya/python/" + digest + ".tar.gz"), to: archive, progress: progress)
        }
        try Task.checkCancellation()
        let staging = root.appendingPathComponent("bootstrap/staging-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        // Only the exact hash-pinned Python archive is extracted. No shell or user input is executed.
        try await LayaBootstrapProcess().run(arguments: ["-xzf", archive.path, "-C", staging.path])
        try Task.checkCancellation()
        guard fm.isExecutableFile(atPath: staging.appendingPathComponent("python/bin/python3").path) else { throw LayaRuntimeError.installationFailed }
        if fm.isExecutableFile(atPath: executable.path) { return executable }
        try fm.moveItem(at: staging, to: directory)
        return executable
    }
    private static func matches(_ url: URL, digest: String) async -> Bool {
        let hashTask = Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                while let data = try handle.read(upToCount: 1048576), !data.isEmpty {
                    if Task.isCancelled { return false }
                    hash.update(data: data)
                }
            } catch { return false }
            if Task.isCancelled { return false }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
        }
        return await withTaskCancellationHandler {
            await hashTask.value
        } onCancel: {
            hashTask.cancel()
        }
    }
}

private final class LayaBootstrapProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func run(arguments: [String]) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock(); defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); child.arguments = arguments
                child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                child.terminationHandler = { process in
                    if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: LayaRuntimeError.installationFailed) }
                }
                process = child
                do { try child.run() }
                catch { process = nil; child.terminationHandler = nil; continuation.resume(throwing: LayaRuntimeError.installationFailed) }
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true
            if let child = self.process, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            self.lock.unlock()
        }
    }
}
