import Foundation
import OSLog

/// Drives the OpenAI Realtime API over a WebSocket.
///
/// Responsibilities:
///  - connect with the Keychain API key
///  - configure the session for input-audio transcription (live transcript)
///  - stream system audio up as base64 PCM16
///  - surface transcription deltas (the other people's speech → text)
///  - on demand, request a single text suggestion using recent transcript context
///
/// All published callbacks are invoked on the main actor.
@MainActor
final class RealtimeClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected

    /// Which side of the conversation this client transcribes.
    let speaker: Speaker

    /// Only the client that owns conversation context (the "them" side) generates
    /// reply suggestions. The mic client transcribes only.
    let handlesSuggestions: Bool

    init(speaker: Speaker, handlesSuggestions: Bool) {
        self.speaker = speaker
        self.handlesSuggestions = handlesSuggestions
        super.init()
    }

    // Callbacks wired up by the coordinator.
    var onTranscriptDelta: ((String, Speaker) -> Void)?
    var onTranscriptCompleted: ((String, Speaker) -> Void)?
    var onSuggestionDelta: ((String) -> Void)?
    var onSuggestionDone: (() -> Void)?
    var onError: ((String) -> Void)?

    private let log = Logger(subsystem: "com.stealth.app", category: "realtime")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var tone: ReplyTone = .professional

    // Tracks which response is a user-requested suggestion vs. background activity.
    private var pendingSuggestionResponseID: String?

    // Set during an intentional disconnect so the receive-loop failure is silent.
    private var isClosing = false

    func setTone(_ tone: ReplyTone) { self.tone = tone }

    // MARK: - Connection

    func connect() {
        guard state != .connected, state != .connecting else { return }
        guard let apiKey = KeychainStore.load() else {
            state = .failed("No API key. Open Settings and paste your OpenAI key.")
            onError?("No API key set.")
            return
        }
        state = .connecting

        var request = URLRequest(url: Config.realtimeURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GA interface: the `OpenAI-Beta: realtime=v1` header must NOT be sent.

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        // Do NOT start receiving yet — wait for `didOpenWithProtocol`.
        // Calling receive() before the socket is open throws POSIX 57
        // ("Socket is not connected") and tears the connection down.
        isClosing = false
        DebugLog.log("[\(speaker.rawValue)] connect(): resuming task")
        task.resume()
    }

    func disconnect() {
        // Mark intentional close so the in-flight receive failure is ignored
        // instead of surfacing "Socket is not connected" to the user.
        isClosing = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        state = .disconnected
    }

    /// Configure the session (GA schema): a realtime session with input-audio
    /// transcription enabled, but NO automatic responses — we drive the reply
    /// suggestion manually when the user presses the hotkey.
    private func configureSession() {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Config.realtimeSampleRate),
                        ],
                        "transcription": [
                            "model": "gpt-4o-transcribe",
                            "language": "en",
                        ],
                        // Server VAD detects speech boundaries and auto-commits the
                        // audio buffer, which is what triggers transcription. We keep
                        // `create_response: false` so it NEVER auto-replies — reply
                        // suggestions stay manual (⌥Space). Without VAD the buffer is
                        // never committed, no transcription fires, and the server
                        // eventually closes the idle socket (close code 1001).
                        "turn_detection": [
                            "type": "server_vad",
                            // Per-speaker: the mic side runs AEC so it needs a lower
                            // threshold or VAD never fires and "You" lines never commit.
                            // IMPORTANT: must be a binary-clean Double — JSONSerialization
                            // prints e.g. 0.3 as "0.29999999999999999" (17 dp), which the
                            // API rejects (decimal_max_decimal_places_exceeded). Config only
                            // returns exactly-representable values (0.25, 0.5).
                            "threshold": Config.vadThreshold(for: speaker),
                            // Lead-in audio kept before the detected speech start, so
                            // the first word isn't clipped.
                            "prefix_padding_ms": 500,
                            "silence_duration_ms": Config.vadSilenceMs,
                            "create_response": false,
                            "interrupt_response": false,
                        ],
                    ],
                ],
            ],
        ]
        send(event)
    }

    // MARK: - Audio in

    private var audioChunkCount = 0

    /// Append a chunk of PCM16 mono 24kHz audio to the input buffer.
    func sendAudio(_ pcm16: Data) {
        guard state == .connected else {
            audioChunkCount += 1
            if audioChunkCount % 50 == 1 {
                DebugLog.log("sendAudio DROPPED (state=\(state)) — \(pcm16.count) bytes")
            }
            return
        }
        audioChunkCount += 1
        if audioChunkCount % 50 == 1 {
            DebugLog.log("sendAudio OK #\(audioChunkCount) — \(pcm16.count) bytes")
        }
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ]
        send(event)
    }

    // MARK: - Suggestion request (hotkey)

    /// Ask the model for ONE on-demand suggestion (reply / recap / follow-up)
    /// based on the recent transcript.
    func requestSuggestion(context: String, mode: SuggestionMode) {
        guard state == .connected else {
            onError?("Not connected yet.")
            return
        }
        let task: String
        switch mode {
        case .reply: task = "Suggest my spoken reply now."
        case .recap: task = "Recap the conversation so far."
        case .followUp: task = "Suggest one follow-up question I could ask."
        }
        let prompt = """
        Recent transcript of the call (most recent line last):
        ---
        \(context.isEmpty ? "(no speech captured yet)" : context)
        ---
        \(task)
        """

        let event: [String: Any] = [
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
                "instructions": Config.suggestionInstructions(mode: mode, tone: tone),
                "input": [[
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": prompt]],
                ]],
            ],
        ]
        // Mark the next response as the suggestion we care about.
        pendingSuggestionResponseID = "pending"
        send(event)
    }

    // MARK: - Send / receive plumbing

    private func send(_ json: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(string)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log.error("WS send error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor in
                    if self.isClosing {
                        // Expected teardown after disconnect() — stay quiet.
                        DebugLog.log("[\(self.speaker.rawValue)] receive ended (intentional close)")
                        return
                    }
                    DebugLog.log("[\(self.speaker.rawValue)] receiveLoop FAILURE: \(error.localizedDescription)")
                    self.state = .failed(error.localizedDescription)
                    self.onError?(error.localizedDescription)
                }
            case .success(let message):
                if case let .string(text) = message {
                    Task { @MainActor in self.handleEvent(text) }
                }
                self.receiveLoop()
            }
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        // Log everything except the high-frequency transcription deltas.
        // Tag with the speaker so You/Them sessions are distinguishable in the log.
        if type != "conversation.item.input_audio_transcription.delta" {
            DebugLog.log("[\(speaker.rawValue)] EVENT: \(type)")
        }

        switch type {
        case "session.created":
            // Configure as soon as the session exists.
            configureSession()

        case "session.updated":
            state = .connected
            DebugLog.log("STATE = connected")

        // --- Live transcription of this client's audio source ---
        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String { onTranscriptDelta?(delta, speaker) }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = obj["transcript"] as? String {
                onTranscriptCompleted?(transcript, speaker)
            }

        // --- Suggestion text streaming back ---
        case "response.text.delta", "response.output_text.delta":
            if let delta = obj["delta"] as? String { onSuggestionDelta?(delta) }

        case "response.done", "response.completed":
            if pendingSuggestionResponseID != nil {
                pendingSuggestionResponseID = nil
                onSuggestionDone?()
            }

        case "error":
            let err = obj["error"] as? [String: Any]
            let message = err?["message"] as? String ?? "Unknown realtime error"
            let code = err?["code"] as? String ?? "?"
            let param = err?["param"] as? String ?? "?"
            DebugLog.log("[\(speaker.rawValue)] REALTIME ERROR code=\(code) param=\(param): \(message)")
            log.error("Realtime error: \(message, privacy: .public)")
            onError?(message)

        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RealtimeClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Socket is genuinely open now — safe to start receiving.
        Task { @MainActor in
            self.log.info("WebSocket opened")
            DebugLog.log("WebSocket OPENED — starting receive loop")
            self.receiveLoop()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor in
            self.state = .disconnected
            self.log.info("WebSocket closed: \(closeCode.rawValue)")
            DebugLog.log("WebSocket CLOSED code=\(closeCode.rawValue) reason=\(reasonText)")
        }
    }
}
