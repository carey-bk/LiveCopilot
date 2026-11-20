import Foundation
import OSLog

/// Official Live protocol, verified 2026-09-13. This intentionally contains no Realtime
/// response.create/input_audio_buffer events. Live delegates; Responses synthesizes separately.
enum LiveProtocol {
    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static func start(model: String, speaker: Speaker, scenario: ScenarioProfile, language: LiveSpeechLanguage, context: String) -> [String: Any] {
        let role = speaker == .you
            ? "This input is the copilot user's own microphone (You). Listen and transcribe; do not delegate requests for assistance."
            : speaker == .room
            ? "This input is a shared room microphone. Speaker identity is uncertain. Detect substantive questions directed to the presenter."
            : "This input is remote participants (Them). Detect substantive questions directed to the copilot user."
        let languageGuidance = language.instruction.map {
            "Transcribe the words actually spoken, in their original language and script. \($0)\nDo not use Korean or Japanese script for Mandarin or English speech unless those languages are clearly spoken."
        } ?? ""
        let instructions = """
        You are the conversation understanding layer of a private text copilot. \(role)
        \(scenario.instructions)
        \(languageGuidance)
        Stay silent; the application has no voice output. Listen continuously, including interruptions and corrections.
        Delegate to the client only when a meaningful question or request is sufficiently complete. Do not delegate on
        each pause, fragments, rhetorical questions, backchannels, or a question already answered by You.
        Recognize follow-ups and delegate a new follow-up once. The client retrieves documents and generates the
        answer in a separate text overlay while you keep listening. Wait for completion and don't repeat delegations.
        """
        var session: [String: Any] = ["model": model, "instructions": instructions,
            "audio": ["format": ["type": "audio/pcm", "rate": 24000], "output": ["voice": "marin"]],
            "delegation": ["type": "client"], "store": false]
        if !context.isEmpty {
            session["input"] = [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Prior conversation (reference only):\n" + String(context.suffix(6000))]]]]
        }
        return ["type": "session.start", "event_id": UUID().uuidString, "session": session]
    }
    static func connectionFailure(status: Int?, error: Error?) -> (message: String, retry: Bool) {
        switch status {
        case 400, 401, 402, 403, 404, 422, 429:
            return (ServiceHTTPFailure(status: status!).localizedDescription, false)
        default:
            if let error = error as NSError?, error.domain == NSURLErrorDomain {
                if error.code == NSURLErrorTimedOut { return ("Live startup timed out. Check network and model access.", true) }
                if error.code == NSURLErrorNotConnectedToInternet { return ("No internet connection. Reconnect and try the speech service again.", true) }
            }
            return ("Live connection failed. Check your network.", true)
        }
    }
    static func parse(_ obj: [String: Any], speaker: Speaker, now: Date = Date()) -> LiveEvent? {
        switch obj["type"] as? String {
        case "session.started": return .ready
        case "session.input_transcript.delta":
            guard let text = obj["delta"] as? String, let start = obj["start_ms"] as? Int,
                  let end = obj["end_ms"] as? Int, let id = obj["event_id"] as? String else { return nil }
            return .transcript(.init(id: id, speaker: speaker, text: text, startMS: start, endMS: end, receivedAt: now))
        case "session.delegation.created":
            guard let d = obj["delegation"] as? [String: Any], d["target"] as? String == "client",
                  let id = d["id"] as? String else { return nil }
            return .delegation(id: id, offsetMS: obj["offset_ms"] as? Int ?? 0)
        case "session.closed": return .closed(finalized: true)
        case "error":
            return .failed(ServiceHTTPFailure(status: 0, data: try? JSONSerialization.data(withJSONObject: obj)).localizedDescription)
        default: return nil // Output audio is intentionally discarded. Nothing is played.
        }
    }
}

@MainActor
final class OpenAILiveProvider: NSObject, LiveProvider {
    var onEvent: ((LiveEvent) -> Void)?
    let speaker: Speaker
    let model: String
    let scenario: ScenarioProfile
    let language: LiveSpeechLanguage
    private let key: String
    private let log = Logger(subsystem: "com.livecopilot.app", category: "live")
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var closeTimeoutTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var queue: [String] = []
    private var queuedBytes = 0
    private var ready = false
    private var closing = false
    private var active = false
    private var retries = 0
    private var generation = UUID()
    private var context = ""
    private var closeContinuations: [CheckedContinuation<Void, Never>] = []

    init(key: String, model: String, speaker: Speaker, scenario: ScenarioProfile, language: LiveSpeechLanguage) {
        self.key = key; self.model = model; self.speaker = speaker; self.scenario = scenario; self.language = language
        super.init()
    }
    func connect(context: String) {
        guard !active else { return }
        self.context = context; active = true; closing = false; retries = 0
        openConnection()
    }
    private func openConnection() {
        generation = UUID(); let generation = generation
        ready = false
        var request = URLRequest(url: LiveProtocol.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        onEvent?(.status("\(speaker.rawValue): connecting to Live…"))
        startupTimeoutTask?.cancel()
        startupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation, !self.ready, !self.closing else { return }
            self.failed("Live startup timed out. Check network and model access.")
        }
    }
    private func startPingLoop(socket: URLSessionWebSocketTask, epoch: UUID) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self, self.generation == epoch, self.ready, !self.closing else { return }
                let pongError: Error? = await withCheckedContinuation { cont in
                    let lock = NSLock()
                    var resumed = false
                    func complete(_ err: Error?) {
                        lock.lock()
                        let should = !resumed
                        resumed = true
                        lock.unlock()
                        if should { cont.resume(returning: err) }
                    }
                    let pingDeadline = Task {
                        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                        complete(URLError(.timedOut))
                    }
                    socket.sendPing { error in
                        pingDeadline.cancel()
                        complete(error)
                    }
                }
                guard !Task.isCancelled, self.generation == epoch, self.ready, !self.closing else { return }
                if let pongError {
                    self.log.error("live.ping_failed speaker=\(self.speaker.rawValue, privacy: .public) code=\((pongError as NSError).code)")
                    self.transportFailed(socket, error: pongError)
                    return
                }
            }
        }
    }
    private func opened(_ socket: URLSessionWebSocketTask) {
        guard socket === self.socket, active, !closing else { return }
        let epoch = generation
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, self.generation == epoch else { return }
                    let data: Data
                    switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
                    if !self.handleIncomingJSONData(data, socket: socket, epoch: epoch) { return }
                } catch {
                    guard let self, self.generation == epoch, !Task.isCancelled else { return }
                    if self.closing { self.onEvent?(.closed(finalized: false)); self.finishConnection() }
                    else { self.transportFailed(socket, error: error) }
                    return
                }
            }
        }
        enqueue(LiveProtocol.start(model: model, speaker: speaker, scenario: scenario, language: language, context: context))
    }

    @discardableResult
    internal func handleIncomingJSONData(_ data: Data, socket: URLSessionWebSocketTask? = nil, epoch: UUID? = nil) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = LiveProtocol.parse(obj, speaker: self.speaker) else { return true }
        switch event {
        case .ready:
            guard !self.closing else { return true }
            self.ready = true
            self.retries = 0
            self.startupTimeoutTask?.cancel()
            self.startupTimeoutTask = nil
            if let socket, let epoch {
                self.startPingLoop(socket: socket, epoch: epoch)
            }
        case .transcript(let fragment):
            self.context = String((self.context + fragment.text).suffix(6000))
        case .closed:
            self.onEvent?(event); self.finishConnection(); return false
        case .failed(let text):
            self.failed(text, retry: false); return false
        default: break
        }
        self.onEvent?(event)
        return true
    }

    /// Test-only hook to exercise `OpenAILiveProvider`'s real `session.started` / `session.closed`
    /// handling without opening a network WebSocket.
    internal var isActiveForTesting: Bool { active }
    internal var isClosingForTesting: Bool { closing }
    internal func activateWithoutSocketForTesting() {
        active = true; closing = false; ready = false; retries = 0
    }
    internal func injectServerJSONForTesting(_ json: String) {
        _ = handleIncomingJSONData(Data(json.utf8))
    }
    func sendAudio(_ data: Data) {
        guard ready, !closing, data.count % 2 == 0 else { return }
        if queuedBytes > 192_000 { failed("Live upload is too slow. Reconnecting; buffered audio was discarded."); return }
        enqueue(["type": "session.input_audio.append", "audio": data.base64EncodedString()])
    }
    func appendContext(_ text: String, delegationID: String?) {
        context = String((context + "\n" + text).suffix(6000))
        guard ready, !closing else { return }
        enqueue(["type": "session.thinking.append", "event_id": UUID().uuidString,
                 "delegation_id": delegationID as Any? ?? NSNull(), "content": Self.contextExcerpt(text)])
    }
    // Live append content has a 500-token limit. A conservative UTF-8 byte bound
    // stays below it without introducing a tokenizer/model dependency.
    nonisolated static func contextExcerpt(_ text: String) -> String {
        var result = "", count = 0
        for ch in text {
            let size = String(ch).utf8.count
            if count + size > 450 { break }
            result.append(ch); count += size
        }
        return result
    }
    private func enqueue(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
        queue.append(text); queuedBytes += text.utf8.count
        guard senderTask == nil, let socket else { return }
        let epoch = generation
        senderTask = Task { [weak self] in
            while let self, self.generation == epoch, !self.queue.isEmpty, !Task.isCancelled {
                let message = self.queue.removeFirst(); self.queuedBytes -= message.utf8.count
                do { try await socket.send(.string(message)) }
                catch { if self.generation == epoch { self.transportFailed(socket, error: error) }; return }
            }
            if let self, self.generation == epoch { self.senderTask = nil }
        }
    }
    private func transportFailed(_ task: URLSessionTask, error: Error?) {
        guard task === socket, active else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        log.error("live.transport_failed speaker=\(self.speaker.rawValue, privacy: .public) status=\(status ?? -1) err=\((error as NSError?)?.code ?? 0)")
        let failure = LiveProtocol.connectionFailure(status: status, error: error)
        failed(failure.message, retry: failure.retry)
    }
    private func failed(_ message: String, retry: Bool = true) {
        guard active else { return }
        if closing { onEvent?(.closed(finalized: false)); finishConnection(); return }
        cleanTransport()
        guard retry && retries < 3 else {
            log.error("live.terminal_failed speaker=\(self.speaker.rawValue, privacy: .public) retry=\(retry) retries=\(self.retries)")
            active = false
            onEvent?(.failed(message))
            return
        }
        retries += 1
        onEvent?(.status("\(message) Reconnecting (\(retries)/3)…"))
        let wait = UInt64(1 << (retries - 1)) * 1_000_000_000
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.active, !self.closing else { return }
            self.openConnection()
        }
    }
    func disconnect() async {
        guard active else { return }
        if closing {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard closing else { continuation.resume(); return }
                    closeContinuations.append(continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishConnection() }
            }
            return
        }
        closing = true; reconnectTask?.cancel(); startupTimeoutTask?.cancel(); pingTask?.cancel()
        guard ready else { finishConnection(); return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                closeContinuations.append(continuation)
                queue = []; queuedBytes = 0
                enqueue(["type": "session.close", "event_id": UUID().uuidString])
                closeTimeoutTask?.cancel()
                closeTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled, let self, self.closing else { return }
                    self.onEvent?(.closed(finalized: false)); self.finishConnection()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.closing else { return }
                self.onEvent?(.closed(finalized: false))
                self.finishConnection()
            }
        }
    }
    private func finishConnection() {
        active = false; closing = false
        cleanTransport()
        let waiters = closeContinuations
        closeContinuations = []
        for waiter in waiters { waiter.resume() }
    }
    private func cleanTransport() {
        generation = UUID(); ready = false
        receiveTask?.cancel(); receiveTask = nil
        senderTask?.cancel(); senderTask = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
        closeTimeoutTask?.cancel(); closeTimeoutTask = nil
        pingTask?.cancel(); pingTask = nil
        queue = []; queuedBytes = 0
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

extension OpenAILiveProvider: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in self?.opened(webSocketTask) }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.socket, self.active else { return }
            self.log.info("live.ws_closed speaker=\(self.speaker.rawValue, privacy: .public) code=\(closeCode.rawValue)")
            if self.closing { self.onEvent?(.closed(finalized: false)); self.finishConnection() }
            else { self.transportFailed(webSocketTask, error: nil) }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, task === self.socket, self.active else { return }
            self.transportFailed(task, error: error)
        }
    }
}

/// A real session handshake, without capturing or sending user audio.
enum LiveConnectionProbe {
    @MainActor static func run(provider: any LiveProvider, timeout: TimeInterval = 25) async throws {
        var ready = false, failure: String?
        provider.onEvent = { event in
            switch event {
            case .ready: ready = true
            case .failed(let message): failure = message
            case .closed: if !ready { failure = "Speech connection closed before the session was ready." }
            default: break
            }
        }
        do {
            provider.connect(context: "")
            let deadline = Date().addingTimeInterval(timeout)
            while !ready && failure == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation()
            guard ready, failure == nil else {
                throw CopilotError.message(failure ?? "Live startup timed out. Check network and model access.")
            }
            provider.onEvent = nil
            await provider.disconnect()
        } catch {
            provider.onEvent = nil
            await provider.disconnect()
            throw error
        }
    }
}
