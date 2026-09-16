import Foundation

/// Local streaming transcription. Paraformer
/// emits replaceable previews while its streaming decoder is still listening.
@MainActor
final class LocalLiveProvider: LiveProvider {
    var onEvent: ((LiveEvent) -> Void)?
    private let speaker: Speaker
    private let worker: LocalInferenceWorker
    private let sessionStart: Date
    private var offsetMS = 0
    private var active = false
    private var ready = false
    private var closing = false
    private var pending = Data()
    private var pump: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var trigger: Task<Void, Never>?
    private var question = ""
    private var lastEndMS = -10000
    private var speaking = false
    private var lastSegmentID = ""
    private var inferenceFailed = false
    private var partial = ""

    init(directory: URL, speaker: Speaker, sessionStart: Date = Date(), executable: URL? = nil) {
        self.speaker = speaker; self.sessionStart = sessionStart
        worker = .init(mode: "paraformer", modelDirectory: directory, executable: executable)
    }
    func prepare() async throws { _ = try await worker.call(["op": "ping"]) }
    func connect(context: String) {
        guard !active else { return }
        active = true; closing = false
        offsetMS = max(0, Int(Date().timeIntervalSince(sessionStart) * 1000))
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepare()
                guard self.active, !Task.isCancelled else { return }
                self.ready = true; self.onEvent?(.ready); self.drain()
            } catch { if self.active { self.fail() } }
        }
    }
    func sendAudio(_ data: Data) {
        guard active, !closing else { return }
        // At most 12 seconds. Never silently drop audio then pretend the transcript is complete.
        guard pending.count + data.count <= 16000 * 2 * 12 else {
            active = false; inferenceFailed = true; trigger?.cancel(); pending.removeAll(); worker.close()
            partial = ""; onEvent?(.partialTranscript(""))
            onEvent?(.failed("Local recognition fell behind. Stop/start listening and reduce other heavy workloads.")); return
        }
        pending.append(data); drain()
    }
    private func drain() {
        guard ready, pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            defer { self.pump = nil }
            while !self.pending.isEmpty && !Task.isCancelled {
                let count = min(self.pending.count, 16000) // Up to 0.5 s per IPC command.
                let data = Data(self.pending.prefix(count)); self.pending.removeFirst(count)
                do {
                    let result = try await self.worker.call(["op": "audio", "pcm": data.base64EncodedString()])
                    if self.active || self.closing { self.consume(result) }
                } catch { self.inferenceFailed = true; if self.active { self.fail() }; return }
            }
        }
    }
    private func consume(_ response: [String: Any]) {
        let wasSpeaking = speaking
        speaking = response["speaking"] as? Bool ?? false
        if wasSpeaking != speaking { onEvent?(.speechActivity(speaking)) }
        if speaking { trigger?.cancel(); trigger = nil }
        for row in response["segments"] as? [[String: Any]] ?? [] {
            guard let raw = row["text"] as? String, let start = row["start_ms"] as? Int, let end = row["end_ms"] as? Int else { continue }
            let text = raw.replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = "local-" + UUID().uuidString
            if start - lastEndMS > 1800 { question = text } else { question = String((question + " " + text).suffix(2200)) }
            lastEndMS = end; lastSegmentID = id
            onEvent?(.transcript(.init(id: id, speaker: speaker, text: " " + text, startMS: offsetMS + start,
                                      endMS: offsetMS + end, receivedAt: Date())))
        }
        if let preview = response["partial"] as? String, preview != partial {
            partial = preview; onEvent?(.partialTranscript(preview))
        }
        if !speaking, active, !closing, speaker != .you, trigger == nil, LocalQuestionDetector.isQuestion(question) {
            let id = lastSegmentID
            trigger = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, let self, self.active, !self.closing, !self.speaking, self.lastSegmentID == id else { return }
                self.onEvent?(.delegation(id: "question-" + id, offsetMS: self.offsetMS + self.lastEndMS))
                // Keep this completed task until speech resumes so silence cannot redelegate.
            }
        }
    }
    private func fail() {
        active = false; trigger?.cancel(); pending.removeAll(); worker.close()
        partial = ""; onEvent?(.partialTranscript(""))
        onEvent?(.failed("Local model stopped unexpectedly or timed out. Retry after checking model files."))
    }
    func appendContext(_ text: String, delegationID: String?) { /* The app owns local conversation context. */ }
    func disconnect() async {
        closing = true; active = false; trigger?.cancel(); loading?.cancel()
        let worker = self.worker
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { worker.close() }
        }
        defer { deadline.cancel() }
        var finalized = pending.isEmpty && !inferenceFailed
        if ready {
            await pump?.value
            if !inferenceFailed, let result = try? await worker.call(["op": "flush"], timeout: 15) {
                consume(result); finalized = pending.isEmpty
            } else { finalized = false }
        }
        worker.close(); pump?.cancel(); pending.removeAll(); ready = false
        partial = ""; onEvent?(.partialTranscript(""))
        onEvent?(.closed(finalized: finalized))
    }
}
