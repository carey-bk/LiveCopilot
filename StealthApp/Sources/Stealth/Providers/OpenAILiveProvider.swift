import Foundation

/// Official Live protocol, verified 2026-09-13. This intentionally contains no Realtime
/// response.create/input_audio_buffer events. Live delegates; Responses synthesizes separately.
enum LiveProtocol {
    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static func start(model: String, speaker: Speaker, scenario: ScenarioProfile, context: String) -> [String: Any] {
        let role = speaker == .you
            ? "This input is the copilot user's own microphone (You). Listen and transcribe; do not delegate requests for assistance."
            : speaker == .room
            ? "This input is a shared room microphone. Speaker identity is uncertain. Detect substantive questions directed to the presenter."
            : "This input is remote participants (Them). Detect substantive questions directed to the copilot user."
        let instructions = """
        You are the conversation understanding layer of a private text copilot. \(role)
        \(scenario.instructions)
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
            session["input"] = [["role": "user", "content": [["type": "input_text", "text": "Prior conversation (reference only):\n" + String(context.suffix(6000))]]]]
        }
        return ["type": "session.start", "event_id": UUID().uuidString, "session": session]
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
            let error = obj["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "unknown"
            // Do not surface raw error text: it can contain request/credential content.
            let auth = code.contains("auth") || code.contains("api_key") || code.contains("permission")
            return .failed(auth ? "Live authentication/access failed. Check your API key and model access." : "Live command/session failed. Check model configuration, API access and network.")
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
    private let key: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var queue: [String] = []
    private var queuedBytes = 0
    private var ready = false
    private var closing = false
    private var active = false
    private var retries = 0
    private var generation = UUID()
    private var context = ""
    private var closeContinuation: CheckedContinuation<Void, Never>?

    init(key: String, model: String, speaker: Speaker, scenario: ScenarioProfile) {
        self.key = key; self.model = model; self.speaker = speaker; self.scenario = scenario
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
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation, !self.ready else { return }
            self.failed("Live startup timed out. Check network and model access.")
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
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let event = LiveProtocol.parse(obj, speaker: self.speaker) else { continue }
                    switch event {
                    case .ready: self.ready = true; self.timeoutTask?.cancel()
                    case .transcript(let fragment):
                        self.context = String((self.context + fragment.text).suffix(6000))
                    case .closed:
                        self.onEvent?(event); self.finishConnection(); return
                    case .failed(let text): self.failed(text, retry: false); return
                    default: break
                    }
                    self.onEvent?(event)
                } catch {
                    guard let self, self.generation == epoch, !Task.isCancelled else { return }
                    if self.closing { self.onEvent?(.closed(finalized: false)); self.finishConnection() }
                    else { self.failed("Live disconnected. Reconnecting if possible; manual text queries remain available.") }
                    return
                }
            }
        }
        enqueue(LiveProtocol.start(model: model, speaker: speaker, scenario: scenario, context: context))
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
                catch { if self.generation == epoch { self.failed("Live upload failed. Check network connection.") }; return }
            }
            if let self, self.generation == epoch { self.senderTask = nil }
        }
    }
    private func failed(_ message: String, retry: Bool = true) {
        guard active else { return }
        if closing { onEvent?(.closed(finalized: false)); finishConnection(); return }
        cleanTransport()
        onEvent?(.failed(message))
        guard retry && retries < 3 else { active = false; onEvent?(.status("\(speaker.rawValue): disconnected — stop/start listening to retry.")); return }
        retries += 1
        let wait = UInt64(1 << (retries - 1)) * 1_000_000_000
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.active, !self.closing else { return }
            self.openConnection()
        }
    }
    func disconnect() async {
        guard active, !closing else { return }
        closing = true; reconnectTask?.cancel(); timeoutTask?.cancel()
        guard ready else { finishConnection(); return }
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
            queue = []; queuedBytes = 0
            enqueue(["type": "session.close", "event_id": UUID().uuidString])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.onEvent?(.closed(finalized: false)); self.finishConnection()
            }
        }
    }
    private func finishConnection() {
        active = false; closing = false
        cleanTransport()
        closeContinuation?.resume(); closeContinuation = nil
    }
    private func cleanTransport() {
        generation = UUID(); ready = false
        receiveTask?.cancel(); receiveTask = nil; senderTask?.cancel(); senderTask = nil; timeoutTask?.cancel()
        queue = []; queuedBytes = 0
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

extension OpenAILiveProvider: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in self?.opened(webSocketTask) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, task === self.socket, self.active else { return }
            let code = (task.response as? HTTPURLResponse)?.statusCode
            self.failed(code == 401 || code == 403 ? "Live authentication/access failed. Check the key and model access." : "Live connection failed. Check your network.", retry: code != 401 && code != 403)
        }
    }
}
