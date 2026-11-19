import Foundation
import Darwin

/// Private stdio IPC, with one serial queue per resident native worker. Audio and text never
/// appear in command arguments, environment, diagnostics, temporary files or a listening socket.
final class LocalInferenceWorker: @unchecked Sendable {
    private final class PendingCall {
        let continuation: CheckedContinuation<[String: Any], Error>
        var deadline: DispatchWorkItem?
        init(continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }
    }
    private let queue = DispatchQueue(label: "com.livecopilot.local-inference", qos: .userInitiated)
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let sigkillGraceSeconds: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var activeID: UUID?
    private var pendingCalls: [UUID: PendingCall] = [:]
    private var terminationInitiators: [Int32: CaptureDiagnostics.WorkerTerminationInitiator] = [:]
    private var cancelled = Set<UUID>()
    private var timedOut = Set<UUID>()
    private var closed = false
    private var diagnosticCode = "unknown"
    /// Controllable test barrier invoked on the serial queue after `activeID` is set and before launching/checking the child process.
    var onBeforeStartProcess: (() -> Void)?
    var failureCode: String { lock.lock(); defer { lock.unlock() }; return diagnosticCode }
    private func recordFailure(_ code: String) {
        lock.lock(); diagnosticCode = code; lock.unlock()
        CaptureDiagnostics.record(.workerFailure, details: .init(workerMode: diagnosticMode, failure: CaptureDiagnostics.Failure(rawValue: code) ?? .unknown))
    }
    private var diagnosticMode: String { ["embedding", "embedding-cpu", "asr", "streaming", "zipformer", "paraformer"].contains(arguments.first ?? "") ? arguments[0] : "other" }

    init(mode: String, modelDirectory: URL, executable: URL? = nil, sigkillGraceSeconds: TimeInterval = 1.5) {
        self.executable = executable ?? Bundle.main.resourceURL!.appendingPathComponent("LocalRuntime/livecopilot-inference")
        self.sigkillGraceSeconds = max(0.05, sigkillGraceSeconds)
        arguments = [mode, modelDirectory.path]
    }
    deinit {
        lock.lock()
        terminateProcessLocked(initiator: .deinitCleanup)
        lock.unlock()
        try? input?.close(); try? output?.close()
    }

    func call(_ payload: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let pending = PendingCall(continuation: continuation)
                let deadline = DispatchWorkItem { [weak self] in self?.interrupt(id, timeout: true) }
                pending.deadline = deadline
                lock.lock()
                if closed || cancelled.contains(id) {
                    cancelled.remove(id)
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingCalls[id] = pending
                lock.unlock()
                // Start the timeout before queueing so backlog wait cannot bypass the deadline.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                queue.async { [self] in
                    lock.lock()
                    guard pendingCalls[id] != nil else {
                        cancelled.remove(id); timedOut.remove(id)
                        lock.unlock()
                        return
                    }
                    let rejected = closed || cancelled.contains(id) || timedOut.contains(id)
                    let rejectedByTimeout = timedOut.contains(id)
                    if !rejected { activeID = id }
                    lock.unlock()
                    defer {
                        lock.lock()
                        activeID = nil; cancelled.remove(id); timedOut.remove(id)
                        let leftover = pendingCalls.removeValue(forKey: id)
                        leftover?.deadline?.cancel()
                        lock.unlock()
                    }
                    if rejected {
                        if rejectedByTimeout {
                            resumeCall(id, with: .failure(CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.")), failureCodeOnResume: "timeout")
                        } else {
                            resumeCall(id, with: .failure(CancellationError()))
                        }
                        return
                    }
                    do {
                        onBeforeStartProcess?()
                        try checkActiveCallState(id)
                        try ensureStarted(for: id)
                        try checkActiveCallState(id)
                        var message = payload; message["id"] = id.uuidString
                        var bytes = try JSONSerialization.data(withJSONObject: message)
                        guard bytes.count < 4 * 1024 * 1024 else { throw CopilotError.message("Local model input is too large.") }
                        bytes.append(10)
                        do { try input!.write(contentsOf: bytes) } catch {
                            lock.lock(); if diagnosticCode != "timeout" { diagnosticCode = "process_ended" }; lock.unlock()
                            throw CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.")
                        }
                        let response = try readMessage()
                        guard response["id"] as? String == id.uuidString else { throw CopilotError.message("Local model returned an invalid response.") }
                        if response["error"] as? String == "embedding_context" {
                            recordFailure("embedding_context")
                            throw CopilotError.message("Local model could not allocate inference memory, including on CPU. Close other apps and retry.")
                        }
                        if response["error"] != nil { recordFailure("inference_failed"); throw CopilotError.message("Local model could not process this input. Check model files and input length.") }
                        try checkActiveCallState(id)
                        resumeCall(id, with: .success(response))
                    } catch {
                        discardProcess()
                        lock.lock(); let wasCancelled = cancelled.contains(id) || closed, expired = timedOut.contains(id); lock.unlock()
                        let reportedFailure = expired ? "timeout" : (!wasCancelled && failureCode == "process_ended" ? "process_ended" : nil)
                        let resolvedError: Error = wasCancelled
                            ? CancellationError()
                            : (expired ? CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.") : error)
                        resumeCall(id, with: .failure(resolvedError), failureCodeOnResume: reportedFailure)
                    }
                }
            }
        } onCancel: { self.interrupt(id) }
    }
    private func checkActiveCallState(_ id: UUID) throws {
        lock.lock()
        let isCancelled = closed || cancelled.contains(id)
        let isTimedOut = timedOut.contains(id)
        lock.unlock()
        if isCancelled { throw CancellationError() }
        if isTimedOut { throw CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.") }
    }
    private func resumeCall(_ id: UUID, with result: Result<[String: Any], Error>, failureCodeOnResume: String? = nil) {
        lock.lock()
        let pending = pendingCalls.removeValue(forKey: id)
        pending?.deadline?.cancel()
        lock.unlock()
        guard let pending else { return }
        if let failureCodeOnResume { recordFailure(failureCodeOnResume) }
        switch result {
        case .success(let value): pending.continuation.resume(returning: value)
        case .failure(let error): pending.continuation.resume(throwing: error)
        }
    }
    private func terminateProcessLocked(initiator: CaptureDiagnostics.WorkerTerminationInitiator) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        if terminationInitiators[pid] == nil { terminationInitiators[pid] = initiator }
        let grace = sigkillGraceSeconds
        process.terminate()
        // Escalate to SIGKILL if the child ignores SIGTERM or is stuck so Darwin.read gets EOF.
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
    private func takeTerminationInitiator(for pid: Int32) -> CaptureDiagnostics.WorkerTerminationInitiator {
        lock.lock(); defer { lock.unlock() }
        return terminationInitiators.removeValue(forKey: pid) ?? .external
    }
    private func interrupt(_ id: UUID, timeout: Bool = false) {
        var immediatePending: PendingCall?
        lock.lock()
        if timeout {
            guard activeID == id || pendingCalls[id] != nil else { lock.unlock(); return }
            timedOut.insert(id); diagnosticCode = "timeout"
            if activeID == id, let process, process.isRunning {
                terminateProcessLocked(initiator: .workerTimeout)
            } else {
                // Either queued, or active during cold start before any child process exists:
                // fail the caller immediately so cold-start races can never outlive the deadline.
                immediatePending = pendingCalls.removeValue(forKey: id)
                immediatePending?.deadline?.cancel()
            }
        } else {
            cancelled.insert(id)
            if activeID == id, let process, process.isRunning {
                terminateProcessLocked(initiator: .userCancel)
            } else {
                immediatePending = pendingCalls.removeValue(forKey: id)
                immediatePending?.deadline?.cancel()
            }
        }
        lock.unlock()
        if let immediatePending {
            if timeout {
                recordFailure("timeout")
                immediatePending.continuation.resume(throwing: CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files."))
            } else {
                immediatePending.continuation.resume(throwing: CancellationError())
            }
        }
    }
    func close(initiator: CaptureDiagnostics.WorkerTerminationInitiator = .shutdown) {
        var queuedToCancel: [PendingCall] = []
        lock.lock()
        closed = true
        terminateProcessLocked(initiator: initiator)
        for (id, pending) in pendingCalls where id != activeID {
            pending.deadline?.cancel()
            queuedToCancel.append(pending)
            pendingCalls.removeValue(forKey: id)
        }
        lock.unlock()
        for pending in queuedToCancel { pending.continuation.resume(throwing: CancellationError()) }
    }
    private func ensureStarted(for id: UUID) throws {
        try checkActiveCallState(id)
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            recordFailure("runtime_missing")
            throw CopilotError.message("Local runtime is missing. Reinstall the complete LiveCopilot app.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        let mode = diagnosticMode
        child.terminationHandler = { [weak self] process in
            let initiator = self?.takeTerminationInitiator(for: process.processIdentifier) ?? .external
            CaptureDiagnostics.record(.workerExit, code: Int(process.terminationStatus), details: .init(workerMode: mode, workerPID: process.processIdentifier, terminationReason: process.terminationReason.rawValue, workerTerminationInitiator: initiator))
        }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        lock.lock()
        let isCancelled = closed || activeID != id || cancelled.contains(id)
        let isTimedOut = timedOut.contains(id)
        guard !isCancelled, !isTimedOut else {
            lock.unlock()
            throw isCancelled
                ? CancellationError()
                : CopilotError.message("Local model stopped unexpectedly or timed out. Retry after checking model files.")
        }
        process = child
        do { try child.run(); CaptureDiagnostics.record(.workerStart, details: .init(workerMode: mode, workerPID: child.processIdentifier)) } catch { process = nil; diagnosticCode = "runtime_start"; lock.unlock(); recordFailure("runtime_start"); throw CopilotError.message("Local runtime could not start. Reinstall the complete LiveCopilot app.") }
        lock.unlock()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer.removeAll(keepingCapacity: true)
        // A worker that exits or is terminated while we write must surface EPIPE, not SIGPIPE:
        // the default signal action terminates the whole app without a crash report.
        let noSignal: Int32 = 1
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, noSignal)
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
        terminateProcessLocked(initiator: .discardOnError)
        process = nil; lock.unlock()
        try? input?.close(); try? output?.close(); input = nil; output = nil; buffer.removeAll()
    }
}

final class LocalEmbeddingProvider: LocalEmbeddingPreparing, @unchecked Sendable {
    let model = LocalModelKind.embeddingIdentity
    private let directory: URL
    private let executable: URL?
    private let workerLock = NSLock()
    private var worker: LocalInferenceWorker
    private var cpuFallbackActive: Bool
    private var closed = false
    private let readinessLock = NSLock()
    private var prepared = false
    var isPrepared: Bool { readinessLock.withLock { prepared } }
    init(directory: URL, executable: URL? = nil) {
        self.directory = directory
        self.executable = executable
        #if arch(x86_64)
        self.cpuFallbackActive = true
        self.worker = .init(mode: "embedding-cpu", modelDirectory: directory, executable: executable)
        #else
        self.cpuFallbackActive = false
        self.worker = .init(mode: "embedding", modelDirectory: directory, executable: executable)
        #endif
    }
    private func currentWorker() -> LocalInferenceWorker {
        workerLock.withLock { worker }
    }
    private func switchToCPUIfNeeded(failingWorker: LocalInferenceWorker) -> LocalInferenceWorker? {
        var previous: LocalInferenceWorker?
        let replacement: LocalInferenceWorker? = workerLock.withLock {
            guard !closed else { return nil }
            if cpuFallbackActive {
                return worker !== failingWorker ? worker : nil
            }
            cpuFallbackActive = true
            previous = worker
            let next = LocalInferenceWorker(mode: "embedding-cpu", modelDirectory: directory, executable: executable)
            worker = next
            return next
        }
        previous?.close(initiator: .discardOnError)
        return replacement
    }
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
            let activeWorker = currentWorker()
            let response: [String: Any]
            do {
                response = try await activeWorker.call(["op": "embed", "text": text])
            } catch is CancellationError {
                readinessLock.withLock { prepared = false }
                throw CancellationError()
            } catch {
                // If the GPU worker crashed out-of-process before in-process fallback could run,
                // transparently switch to a CPU worker and retry this chunk once.
                if activeWorker.failureCode == "process_ended",
                   let fallbackWorker = switchToCPUIfNeeded(failingWorker: activeWorker) {
                    do { response = try await fallbackWorker.call(["op": "embed", "text": text]) }
                    catch { readinessLock.withLock { prepared = false }; throw error }
                } else {
                    readinessLock.withLock { prepared = false }
                    throw error
                }
            }
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
    func close(initiator: CaptureDiagnostics.WorkerTerminationInitiator = .shutdown) {
        readinessLock.withLock { prepared = false }
        let current = workerLock.withLock { () -> LocalInferenceWorker in
            closed = true
            return worker
        }
        current.close(initiator: initiator)
    }
}
