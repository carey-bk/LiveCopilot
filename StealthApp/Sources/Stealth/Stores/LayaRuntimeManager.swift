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
    @Published private(set) var message = "Bundled Laya is unavailable."
    @Published private(set) var progress: Double?
    @Published private(set) var transferProgress: Double?
    @Published private(set) var transferStatus = ""
    @Published private(set) var downloadFileIndex: Int?
    @Published private(set) var downloadFileTotal: Int?
    private var task: Task<Void, Error>?
    private var worker: LayaWorker?
    private var installer: LayaWorker?
    private var epoch: UInt64 = 0
    private var preference: LayaBackend?
    private let defaults: UserDefaults
    private var readyBackend: LayaBackend?
    private var predictions = 0
    private let assetSource: URL?
    private var threshold: Double
    private var nativeCurrent: URL {
        return resources.deletingLastPathComponent().appendingPathComponent("OfflineModels/laya")
    }
    var backend: LayaBackend {
        return .w8
    }
    func updateThreshold(_ value: Double) {
        let old = backend
        threshold = value
        if old != backend { stop(); automaticPreparationAttempted = false }
    }
    var downloadByteCount: Int64? {
        return LayaNativeAssets.downloadSize(resources: resources, mode: backend)
    }
    var isReady: Bool { state == .ready }
    var isBusy: Bool { state == .installing || state == .loading }
    var isInstalled: Bool {
        return (try? LayaNativeAssets.pins(resources, backend).installed(at: nativeCurrent)) == true
    }

    init(root: URL, resources: URL? = nil, preference: LayaBackend? = nil, assetSource: URL? = nil, threshold: Double = 0.80, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preference = preference ?? defaults.string(forKey: "LayaBackend").flatMap(LayaBackend.init(rawValue:))
        self.assetSource = assetSource ?? defaults.string(forKey: "LayaNativeAssetDirectory").map { URL(fileURLWithPath: $0) }
        self.threshold = threshold
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
    func install() {
        prepare()
    }
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
        (try? LayaNativeAssets.pins(resources, backend))?.source_sha256
    }
    var engineTitle: String {
        return "Core ML · " + backend.rawValue.uppercased()
    }
    var technicalDetails: String {
        if let pins = try? LayaNativeAssets.pins(resources, backend) {
            return engineTitle + "\nCheckpoint: " + pins.source_sha256
        }
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("pins.json")),
              let pins = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let source = (pins["source"] as? [String: Any])?["revision"] as? String ?? "—"
        let model = pins["model_revision"] as? String ?? "—"
        let bytes = (pins["model"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
        return "\(engineTitle) · multilingual\nRuntime: \(source)\nModel: \(model)\nCheckpoint: \(checkpointID ?? "—")\nModel files: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))\n\(root.appendingPathComponent("current").path)"
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
        predictions += 1
        defer { predictions -= 1 }
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
    private let legacyNames = ["current", "bootstrap", "downloads"]
    private var legacyItems: [URL] {
        legacyNames.map { root.appendingPathComponent($0) }.filter {
            var info = stat()
            return lstat($0.path, &info) == 0
        }
    }
    var hasLegacyFiles: Bool { !legacyItems.isEmpty }
    var canCleanLegacy: Bool {
        guard isReady, !isBusy, task == nil, predictions == 0,
              let readyBackend, readyBackend.rawValue != "python",
              (try? LayaNativeAssets.pins(resources, readyBackend).installed(at: nativeCurrent)) == true,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              (try? nativeCurrent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        else { return false }
        return hasLegacyFiles
    }
    func cleanLegacyFiles() {
        guard canCleanLegacy else { return }
        do {
            // removeItem unlinks the historical current symlink itself. Its
            // installs/<uuid> target is outside the three authorised entries.
            for entry in legacyItems { try FileManager.default.removeItem(at: entry) }
            record("legacy_cleanup_complete")
            message = "Legacy Python runtime entries and download cache removed."
        } catch {
            record("legacy_cleanup_incomplete")
            message = "Some legacy files remain. Retry cleanup."
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
            message = isInstalled ? "Laya is stopped. Bundled files are retained." : "Bundled Laya is unavailable."
        }
    }
    func shutdown() async {
        let pending = task
        stop()
        _ = try? await pending?.value
    }
    private func begin(download: Bool, reload: Bool = false, target: LayaBackend? = nil) {
        guard Self.supported, task == nil, !isBusy else { return }
        if !download && isReady && !reload { return }
        guard download || isInstalled else {
            state = .notInstalled; message = "Bundled Laya is unavailable."; return
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
                let mode = target ?? self.backend
                let directory = self.nativeCurrent
                guard stamp == self.epoch, self.isInstalled else { throw LayaRuntimeError.unavailable }
                self.state = .loading; self.progress = nil; self.message = "Loading Laya locally…"
                self.downloadFileIndex = nil; self.downloadFileTotal = nil
                let onExit: @Sendable () -> Void = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.epoch == stamp, self.state == .ready else { return }
                        self.record("worker_exited")
                        self.state = .failed
                        self.message = "Laya stopped. Reload the model; manual generation remains available."
                    }
                }
                let worker: LayaWorker
                worker = LayaWorker(native: directory, resources: self.resources, precision: mode.rawValue, onExit: onExit)
                self.worker = worker
                try await worker.prepare()
                try Task.checkCancellation()
                guard stamp == self.epoch else { throw CancellationError() }
                self.readyBackend = mode
                if let target {
                    self.preference = target
                    self.defaults.set(target.rawValue, forKey: "LayaBackend")
                }
                self.record("worker_ready · " + (mode.rawValue == "python" ? "python" : "livecopilot-laya") + " · " + mode.rawValue)
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
}
