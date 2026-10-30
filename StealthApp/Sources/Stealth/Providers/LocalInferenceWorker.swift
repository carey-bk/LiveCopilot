import Foundation
import Darwin

/// Private stdio IPC, with one serial queue per resident native worker. Audio and text never
/// appear in command arguments, environment, diagnostics, temporary files or a listening socket.
final class LocalInferenceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.livecopilot.local-inference", qos: .userInitiated)
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var activeID: UUID?
    private var cancelled = Set<UUID>()
    private var timedOut = Set<UUID>()
    private var closed = false
    private var diagnosticCode = "unknown"
    var failureCode: String { lock.lock(); defer { lock.unlock() }; return diagnosticCode }
    private func recordFailure(_ code: String) {
        lock.lock(); diagnosticCode = code; lock.unlock()
        CaptureDiagnostics.record(.workerFailure, details: .init(workerMode: diagnosticMode, failure: CaptureDiagnostics.Failure(rawValue: code) ?? .unknown))
    }
    private var diagnosticMode: String { ["embedding", "asr", "streaming", "zipformer", "paraformer"].contains(arguments.first ?? "") ? arguments[0] : "other" }

    init(mode: String, modelDirectory: URL, executable: URL? = nil) {
        self.executable = executable ?? Bundle.main.resourceURL!.appendingPathComponent("LocalRuntime/livecopilot-inference")
        arguments = [mode, modelDirectory.path]
    }
    deinit { if let process, process.isRunning { process.terminate() }; try? input?.close(); try? output?.close() }

    func call(_ payload: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    lock.lock()
                    let rejected = closed || cancelled.contains(id)
                    if !rejected { activeID = id }
                    lock.unlock()
                    defer { lock.lock(); activeID = nil; cancelled.remove(id); timedOut.remove(id); lock.unlock() }
                    guard !rejected else { continuation.resume(throwing: CancellationError()); return }
                    let deadline = DispatchWorkItem { [weak self] in self?.interrupt(id, timeout: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    defer { deadline.cancel() }
                    do {
                        try ensureStarted()
                        lock.lock(); let cancelledNow = closed || cancelled.contains(id); lock.unlock()
                        if cancelledNow { throw CancellationError() }
                        var message = payload; message["id"] = id.uuidString
                        var bytes = try JSONSerialization.data(withJSONObject: message)
                        guard bytes.count < 4 * 1024 * 1024 else { throw CopilotError.message("Local model input is too large.") }
                        bytes.append(10); try input!.write(contentsOf: bytes)
                        let response = try readMessage()
                        guard response["id"] as? String == id.uuidString else { throw CopilotError.message("Local model returned an invalid response.") }
                        if response["error"] as? String == "embedding_context" {
                            recordFailure("embedding_context")
                            throw CopilotError.message("Local model could not allocate inference memory, including on CPU. Close other apps and retry.")
                        }
                        if response["error"] != nil { recordFailure("inference_failed"); throw CopilotError.message("Local model could not process this input. Check model files and input length.") }
                        lock.lock(); let wasCancelled = cancelled.contains(id); lock.unlock()
                        if wasCancelled { throw CancellationError() }
                        continuation.resume(returning: response)
                    } catch {
                        discardProcess()
                        lock.lock(); let wasCancelled = cancelled.contains(id) || closed, expired = timedOut.contains(id); lock.unlock()
                        if expired { recordFailure("timeout") }
                        else if !wasCancelled && failureCode == "process_ended" { recordFailure("process_ended") }
                        continuation.resume(throwing: wasCancelled ? CancellationError() : expired ? CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.") : error)
                    }
                }
            }
        } onCancel: { self.interrupt(id) }
    }
    private func interrupt(_ id: UUID, timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if timeout { guard activeID == id else { return }; timedOut.insert(id); diagnosticCode = "timeout" }
        else { cancelled.insert(id) }
        if activeID == id, let process, process.isRunning { process.terminate() }
    }
    func close() {
        lock.lock(); closed = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    private func ensureStarted() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            recordFailure("runtime_missing")
            throw CopilotError.message("Local runtime is missing. Reinstall the complete LiveCopilot app.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        let mode = diagnosticMode
        child.terminationHandler = { process in
            CaptureDiagnostics.record(.workerExit, code: Int(process.terminationStatus), details: .init(workerMode: mode, workerPID: process.processIdentifier, terminationReason: process.terminationReason.rawValue))
        }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        lock.lock()
        guard !closed, activeID.map({ !cancelled.contains($0) }) ?? false else { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); CaptureDiagnostics.record(.workerStart, details: .init(workerMode: mode, workerPID: child.processIdentifier)) } catch { process = nil; diagnosticCode = "runtime_start"; lock.unlock(); recordFailure("runtime_start"); throw CopilotError.message("Local runtime could not start. Reinstall the complete LiveCopilot app.") }
        lock.unlock()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer.removeAll(keepingCapacity: true)
        let response = try readMessage()
        guard response["ready"] as? Bool == true else {
            let code = response["error"] as? String ?? "model_load_failed"
            recordFailure(["embedding_context", "embedding_load"].contains(code) ? code : "model_load_failed")
            if response["error"] as? String == "embedding_context" {
                throw CopilotError.message("Local model could not allocate inference memory, including on CPU. Close other apps and retry.")
            }
            throw CopilotError.message("Local model could not load. Model files, available memory or runtime compatibility may be responsible. Restart the app and retry; if it persists, contact support.")
        }
    }
    private func readMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CopilotError.message("Local model returned an invalid response.") }
                return object
            }
            guard let output else { throw CopilotError.message("Local model returned an invalid response.") }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                lock.lock(); if diagnosticCode != "timeout" { diagnosticCode = "process_ended" }; lock.unlock()
                throw CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.")
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4 * 1024 * 1024 else { throw CopilotError.message("Local model returned an invalid response.") }
        }
    }
    private func discardProcess() {
        lock.lock()
        if let process, process.isRunning { process.terminate() }
        process = nil; lock.unlock()
        try? input?.close(); try? output?.close(); input = nil; output = nil; buffer.removeAll()
    }
}

final class LocalEmbeddingProvider: LocalEmbeddingPreparing, @unchecked Sendable {
    let model = LocalModelKind.embeddingIdentity
    private let worker: LocalInferenceWorker
    private let readinessLock = NSLock()
    private var prepared = false
    var isPrepared: Bool { readinessLock.withLock { prepared } }
    init(directory: URL, executable: URL? = nil) { worker = .init(mode: "embedding", modelDirectory: directory, executable: executable) }
    func prepare() async throws {
        guard !isPrepared else { return }
        // Exercise both model loading and the first inference/Metal setup with fixed local text.
        // The resident worker and subsequent queries share the same serialized IPC queue.
        _ = try await embed(["warmup"])
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embed(texts, progress: { _ in })
    }
    func embed(_ texts: [String], progress: @Sendable (Int) async -> Void) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        // One text per IPC request lets a new interactive query run between import chunks.
        for text in texts {
            try Task.checkCancellation()
            let response: [String: Any]
            do { response = try await worker.call(["op": "embed", "text": text]) }
            catch { readinessLock.withLock { prepared = false }; throw error }
            guard let numbers = response["vector"] as? [NSNumber], numbers.count == 1024 else {
                throw CopilotError.message("Local model returned an invalid response.")
            }
            let vector = numbers.map(\.floatValue)
            guard vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw CopilotError.message("Local model returned an invalid response.") }
            vectors.append(vector)
            readinessLock.withLock { prepared = true }
            await progress(vectors.count)
        }
        return vectors
    }
    func close() { readinessLock.withLock { prepared = false }; worker.close() }
}
