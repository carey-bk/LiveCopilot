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
    private var task: Task<Void, Error>?
    private var worker: LayaWorker?
    private var installer: LayaWorker?
    private var epoch: UInt64 = 0
    var isReady: Bool { state == .ready }
    var isBusy: Bool { state == .installing || state == .loading }
    var isInstalled: Bool { Self.hasInstallation(root.appendingPathComponent("current"), resources: resources) }

    init(root: URL, resources: URL? = nil) {
        self.root = root
        self.resources = resources ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("LayaRuntime")
        if !Self.supported { state = .unsupported; message = "Laya requires Apple Silicon and macOS 14 or newer." }
        else if isInstalled { state = .installed; message = "Laya is installed. Load it to enable offline detection." }
    }
    private static var supported: Bool {
        #if arch(arm64)
        if #available(macOS 14, *) { return true }
        #endif
        return false
    }
    func install() { begin(download: true) }
    func prepare() { begin(download: false) }
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
                state = .failed
                message = "Laya stopped. Reload the model; manual generation remains available."
            }
            throw error
        }
    }
    func cancel() { stop() }
    func stop() {
        epoch &+= 1
        task?.cancel(); task = nil
        worker?.stop(); worker = nil
        installer?.stop(); installer = nil
        progress = nil
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
    private func begin(download: Bool) {
        guard Self.supported, task == nil, !isBusy else { return }
        if !download && isReady { return }
        guard download || isInstalled else {
            state = .notInstalled; message = "Download Laya before loading it."; return
        }
        epoch &+= 1
        let stamp = epoch
        worker?.stop(); worker = nil
        state = download ? .installing : .loading
        transferStatus = ""; transferProgress = nil
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
                    let python = try await LayaBootstrap.prepare(root: self.root, resources: self.resources, progress: transferUpdate)
                    transferUpdate(nil, "")
                    try Task.checkCancellation()
                    guard stamp == self.epoch else { throw CancellationError() }
                    let installer = LayaWorker(executable: python, arguments: ["-I", "-B", self.resources.appendingPathComponent("install.py").path, "--root", self.root.path, "--resources", self.resources.path, "--download-source", "mirror"], transfer: transferUpdate) { [weak self] stage, value in
                        Task { @MainActor in
                            guard let self, self.epoch == stamp, self.state == .installing else { return }
                            self.transferStatus = ""; self.transferProgress = nil
                            self.progress = value
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
                let worker = LayaWorker(installation: self.root.appendingPathComponent("current").resolvingSymlinksInPath(), resources: self.resources)
                self.worker = worker
                try await worker.prepare()
                try Task.checkCancellation()
                guard stamp == self.epoch else { throw CancellationError() }
                self.state = .ready; self.message = "Laya is ready. Detection runs offline."; self.task = nil
            } catch {
                if stamp == self.epoch {
                    self.worker?.stop(); self.worker = nil
                    self.installer?.stop(); self.installer = nil
                    self.task = nil; self.progress = nil; self.state = .failed
                    self.message = "Laya could not start. Check the installation and retry; manual generation remains available."
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

private enum LayaBootstrap {
    static func prepare(root: URL, resources: URL, progress: @escaping @Sendable (Double?, String) -> Void) async throws -> URL {
        let data = try Data(contentsOf: resources.appendingPathComponent("pins.json"))
        guard let pins = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let python = pins["python"] as? [String: String], let digest = python["sha256"],
              digest.count == 64, let address = python["url"], let url = URL(string: address), url.scheme == "https"
        else { throw LayaRuntimeError.installationFailed }
        let fm = FileManager.default
        let directory = root.appendingPathComponent("bootstrap/" + digest)
        let executable = directory.appendingPathComponent("python/bin/python3")
        if fm.isExecutableFile(atPath: executable.path) { return executable }
        let cache = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = cache.appendingPathComponent(digest + ".tar.gz")
        if !(await matches(archive, digest: digest)) {
            if fm.fileExists(atPath: archive.path) { try fm.removeItem(at: archive) }
            try await LocalModelInstaller.download(ModelDownload(url: url, sha256: digest, name: "Python runtime"), to: archive, progress: progress)
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
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                while let data = try handle.read(upToCount: 1048576), !data.isEmpty { hash.update(data: data) }
            } catch { return false }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
        }.value
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
