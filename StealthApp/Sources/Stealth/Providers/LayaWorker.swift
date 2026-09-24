import Foundation
import Darwin
import CoreFoundation

enum LayaRuntimeError: LocalizedError {
    case unavailable, invalidInput, invalidResponse, timedOut, stopped, installationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Laya runtime is unavailable. Download or reload it in Settings."
        case .invalidInput: return "The text is empty or too large for local detection."
        case .invalidResponse: return "Laya returned an invalid response. Reload the local model."
        case .timedOut: return "Laya timed out. The local process was stopped; manual generation remains available."
        case .stopped: return "Laya stopped. Reload the local model to resume automatic detection."
        case .installationFailed: return "Laya installation failed. Check your connection and retry."
        }
    }
}

/// Serial, bounded NDJSON transport. No transcript in arguments, files, diagnostics or sockets.
/// Cancellation invalidates queued requests and physically kills the owned process group.
final class LayaWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.livecopilot.laya-worker", qos: .userInitiated)
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let transfer: (@Sendable (Double?, String) -> Void)?
    private let file: (@Sendable (Int, Int) -> Void)?
    private let status: (@Sendable (String, Double?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation: UInt64 = 0
    private var pending = Set<UUID>()
    private var cancelled = Set<UUID>()
    private var active: UUID?
    private var ready = false
    private let maxLine = 131072

    init(executable: URL, arguments: [String], transfer: (@Sendable (Double?, String) -> Void)? = nil,
         file: (@Sendable (Int, Int) -> Void)? = nil, status: (@Sendable (String, Double?) -> Void)? = nil) {
        self.executable = executable; self.arguments = arguments; self.status = status; self.transfer = transfer; self.file = file
    }
    convenience init(installation: URL, resources: URL) {
        self.init(executable: installation.appendingPathComponent("venv/bin/python3"),
                  arguments: ["-I", "-B", resources.appendingPathComponent("worker.py").path,
                              "--installation", installation.path])
    }
    deinit { killOwnedProcess(); try? input?.close(); try? output?.close() }

    func prepare(timeout: TimeInterval = 120) async throws {
        _ = try await perform(nil, timeout: timeout)
    }
    func predict(text: String, context: String, timeout: TimeInterval = 15) async throws -> Double {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65536, context.utf8.count <= 65536 else { throw LayaRuntimeError.invalidInput }
        let response = try await perform(["op": "predict", "text": text, "context": context], timeout: timeout)
        guard let score = response["score"] as? NSNumber, CFGetTypeID(score) != CFBooleanGetTypeID(),
              score.doubleValue.isFinite, (0...1).contains(score.doubleValue),
              let count = response["input_tokens"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
              count.doubleValue.rounded() == count.doubleValue, (1...1024).contains(count.intValue) else {
            stop(); throw LayaRuntimeError.invalidResponse
        }
        return score.doubleValue
    }

    /// Reusable stop: new requests may start a new process, old requests can never revive it.
    func stop() {
        lock.lock(); generation &+= 1; killOwnedProcess(); lock.unlock()
    }
    private func interrupt(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard pending.contains(id) else { return }
        cancelled.insert(id)
        if active == id { killOwnedProcess() }
    }
    private func perform(_ payload: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw LayaRuntimeError.invalidInput }
        let id = UUID()
        let epoch: UInt64 = try register(id)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { finish(id) }
                    do {
                        try check(id, epoch: epoch, deadline: deadline)
                        setActive(id)
                        try ensureStarted(id, epoch: epoch, deadline: deadline)
                        if let payload {
                            var request = payload; request["id"] = id.uuidString
                            var bytes = try JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
                            bytes.append(10)
                            guard bytes.count <= maxLine else { throw LayaRuntimeError.invalidInput }
                            try write(bytes, id: id, epoch: epoch, deadline: deadline)
                            let response = try read(id, epoch: epoch, deadline: deadline)
                            guard response["id"] as? String == id.uuidString, response["error"] == nil else {
                                throw LayaRuntimeError.invalidResponse
                            }
                            try check(id, epoch: epoch, deadline: deadline)
                            continuation.resume(returning: response)
                        } else {
                            try check(id, epoch: epoch, deadline: deadline)
                            continuation.resume(returning: [:])
                        }
                    } catch {
                        discard()
                        continuation.resume(throwing: normalized(error, id: id, epoch: epoch))
                    }
                }
            }
        } onCancel: { self.interrupt(id) }
    }
    private func register(_ id: UUID) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard pending.count < 8 else { throw LayaRuntimeError.unavailable }
        pending.insert(id); return generation
    }
    private func finish(_ id: UUID) {
        lock.lock(); pending.remove(id); cancelled.remove(id)
        if active == id { active = nil }; lock.unlock()
    }
    private func setActive(_ id: UUID) { lock.lock(); active = id; lock.unlock() }
    private func check(_ id: UUID, epoch: UInt64, deadline: Double) throws {
        lock.lock(); let invalid = generation != epoch || cancelled.contains(id); lock.unlock()
        if invalid { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw LayaRuntimeError.timedOut }
    }
    private func normalized(_ error: Error, id: UUID, epoch: UInt64) -> Error {
        lock.lock(); let invalid = generation != epoch || cancelled.contains(id); lock.unlock()
        if invalid { return CancellationError() }
        return error is LayaRuntimeError ? error : LayaRuntimeError.stopped
    }
    private func ensureStarted(_ id: UUID, epoch: UInt64, deadline: Double) throws {
        if ready, let process, process.isRunning { return }
        discard()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LayaRuntimeError.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
                             "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                             "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        lock.lock()
        guard generation == epoch, !cancelled.contains(id) else { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw LayaRuntimeError.unavailable }
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        // Do not retain the parent's copies of the child's ends: EOF must be observable.
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        lock.unlock()
        for handle in [input!, output!] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw LayaRuntimeError.stopped }
        }
        let noSignal: Int32 = 1
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, noSignal)
        for _ in 0..<10000 {
            let response = try read(id, epoch: epoch, deadline: deadline)
            if response["file_index"] != nil || response["file_total"] != nil {
                guard let index = response["file_index"] as? NSNumber,
                      let total = response["file_total"] as? NSNumber,
                      CFGetTypeID(index) != CFBooleanGetTypeID(), CFGetTypeID(total) != CFBooleanGetTypeID(),
                      index.doubleValue.rounded() == index.doubleValue,
                      total.doubleValue.rounded() == total.doubleValue,
                      (1...1000).contains(total.intValue), (1...total.intValue).contains(index.intValue)
                else { throw LayaRuntimeError.invalidResponse }
                file?(index.intValue, total.intValue); continue
            }
            if let detail = response["transfer"] as? String {
                guard detail.utf8.count <= 1024 else { throw LayaRuntimeError.invalidResponse }
                let value = (response["fraction"] as? NSNumber)?.doubleValue
                guard value == nil || (value!.isFinite && (0...1).contains(value!)) else { throw LayaRuntimeError.invalidResponse }
                transfer?(value, detail); continue
            }
            if let stage = response["stage"] as? String {
                let known: Set<String> = ["python", "dependencies", "source", "model", "verifying", "complete"]
                guard known.contains(stage) else { throw LayaRuntimeError.invalidResponse }
                let value = (response["progress"] as? NSNumber)?.doubleValue
                guard value == nil || (value!.isFinite && (0...1).contains(value!)) else { throw LayaRuntimeError.invalidResponse }
                status?(stage, value); continue
            }
            guard let flag = response["ready"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  flag.boolValue, response["protocol"] as? Int == 1 else { throw LayaRuntimeError.unavailable }
            ready = true; return
        }
        throw LayaRuntimeError.invalidResponse
    }
    private func wait(_ fd: Int32, events: Int16, id: UUID, epoch: UInt64, deadline: Double) throws {
        while true {
            try check(id, epoch: epoch, deadline: deadline)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let count = poll(&descriptor, 1, 50)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LayaRuntimeError.stopped }
            if count > 0 { return }
        }
    }
    private func write(_ data: Data, id: UUID, epoch: UInt64, deadline: Double) throws {
        guard let input else { throw LayaRuntimeError.stopped }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                try wait(input.fileDescriptor, events: Int16(POLLOUT), id: id, epoch: epoch, deadline: deadline)
                let count = Darwin.write(input.fileDescriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw LayaRuntimeError.stopped }; offset += count
            }
        }
    }
    private func read(_ id: UUID, epoch: UInt64, deadline: Double) throws -> [String: Any] {
        while true {
            try check(id, epoch: epoch, deadline: deadline)
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 4096, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw LayaRuntimeError.invalidResponse
                }
                return object
            }
            guard let output else { throw LayaRuntimeError.stopped }
            try wait(output.fileDescriptor, events: Int16(POLLIN), id: id, epoch: epoch, deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw LayaRuntimeError.stopped }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 8192 else { throw LayaRuntimeError.invalidResponse }
        }
    }
    /// Caller holds lock, or is deinitializing. Python creates its own group before doing work.
    private func killOwnedProcess() {
        guard let child = process else { return }
        let pid = child.processIdentifier
        guard pid > 0 else { return }
        if getpgid(pid) == pid { _ = Darwin.kill(-pid, SIGKILL) }
        if child.isRunning { _ = Darwin.kill(pid, SIGKILL) }
    }
    private func discard() {
        lock.lock(); killOwnedProcess(); process = nil; lock.unlock()
        try? input?.close(); try? output?.close(); input = nil; output = nil
        buffer.removeAll(keepingCapacity: true); ready = false
    }
}
