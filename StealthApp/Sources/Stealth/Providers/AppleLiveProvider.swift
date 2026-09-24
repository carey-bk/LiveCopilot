import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

enum AppleSpeechSupport {
    static var available: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }
    static func installed(_ language: AppleSpeechLanguage) async -> Bool {
        guard #available(macOS 26, *), available,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else { return false }
        // Assets can already be on disk but appear "supported" to a new app
        // until it reserves the locale. Reservation registers use; it does not
        // download data or authorize cloud recognition.
        do { try await AssetInventory.reserve(locale: locale) } catch { return false }
        return await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)]) == .installed
    }
    static func install(_ language: AppleSpeechLanguage) async throws {
        guard #available(macOS 26, *), available,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw CopilotError.message("Apple speech requires macOS 26 and a supported Mac and language.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }
}

/// Apple owns inference and downloaded assets; this provider never falls back to
/// server recognition. Laya decides whether a final local transcript needs analysis.
@available(macOS 26, *)
@MainActor final class AppleLiveProvider: LiveProvider {
    var onEvent: ((LiveEvent) -> Void)?
    private let speaker: Speaker
    private let language: AppleSpeechLanguage
    private let sessionStart: Date
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var active = false, ready = false, closing = false, failed = false, speaking = false
    private var heardSpeech = false
    private var audioFrames: Int64 = 0, offsetMS = 0
    private var textState = SpeechPreviewState()

    init(speaker: Speaker, language: AppleSpeechLanguage, sessionStart: Date = Date()) {
        self.speaker = speaker; self.language = language; self.sessionStart = sessionStart
    }
    func prepare() async throws {
        if analyzer != nil { return }
        guard await AppleSpeechSupport.installed(language),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw CopilotError.message("Download the selected Apple speech language in Services first.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        try Task.checkCancellation()
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber, detector], considering: inputFormat) else {
            throw CopilotError.message("Apple speech has no compatible audio format.")
        }
        targetFormat = format
        if format != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            guard converter != nil else { throw CopilotError.message("Apple speech has no compatible audio format.") }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let input = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(64)) { self.continuation = $0 }
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    self.consume(result)
                }
            } catch { if let self, self.active || self.closing { self.fail() } }
        }
        detectorTask = Task { [weak self] in
            do {
                for try await result in detector.results {
                    guard let self, !Task.isCancelled else { return }
                    self.speaking = result.speechDetected
                    if self.speaking { self.heardSpeech = true }
                    self.onEvent?(.speechActivity(self.speaking))
                }
            } catch { if let self, self.active || self.closing { self.fail() } }
        }
        try await analyzer.start(inputSequence: input)
    }
    func connect(context: String) {
        guard !active else { return }
        active = true
        heardSpeech = false
        offsetMS = max(0, Int(Date().timeIntervalSince(sessionStart) * 1000))
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepare()
                guard self.active, !Task.isCancelled else { return }
                self.ready = true; self.onEvent?(.ready)
                let queued = self.pending; self.pending.removeAll(); self.sendAudio(queued)
            } catch {
                if self.active { self.fail(message: error is CopilotError ? error.localizedDescription : nil) }
            }
        }
    }
    func sendAudio(_ data: Data) {
        guard active, !closing, !data.isEmpty else { return }
        guard data.count % 2 == 0, data.count <= 16000 * 2 * 12 else { fail(); return }
        guard ready else {
            guard pending.count + data.count <= 16000 * 2 * 12 else { fail(); return }
            pending.append(data); return
        }
        // Bounded 250 ms input buffers; never silently drop queued speech.
        for offset in stride(from: 0, to: data.count, by: 8000) {
            let bytes = data.subdata(in: offset..<min(data.count, offset + 8000))
            guard let buffer = makeBuffer(bytes) else { fail(); return }
            let time = CMTime(value: audioFrames, timescale: 16000)
            audioFrames += Int64(bytes.count / 2)
            guard case .enqueued = continuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) else { fail(); return }
        }
    }
    private func makeBuffer(_ bytes: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(bytes.count / 2)
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames), let channel = source.int16ChannelData else { return nil }
        source.frameLength = frames
        bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel[0], count: bytes.count))
        guard let converter, let targetFormat else { return source }
        let capacity = AVAudioFrameCount(Double(frames) * targetFormat.sampleRate / 16000 + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var fed = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
    private func consume(_ result: SpeechTranscriber.Result) {
        guard active || closing else { return }
        let start = max(0, Int(result.range.start.seconds * 1000))
        let end = max(start, Int(CMTimeRangeGetEnd(result.range).seconds * 1000))
        let text = String(result.text.characters)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { heardSpeech = true }
        if let part = textState.accept(startMS: start, endMS: end, text: text, final: result.isFinal) {
            let id = "apple-\(speaker.rawValue)-\(part.startMS)-\(part.endMS)"
            let stable = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            onEvent?(.transcript(.init(id: id, speaker: speaker, text: " " + stable, startMS: offsetMS + part.startMS,
                                      endMS: offsetMS + part.endMS, receivedAt: Date())))
        }
        onEvent?(.partialTranscript(textState.preview))
    }
    private func fail(message: String? = nil) {
        guard !failed else { return }
        failed = true; active = false; pending.removeAll()
        continuation?.finish(); onEvent?(.partialTranscript(""))
        onEvent?(.failed(message ?? "Apple speech stopped unexpectedly. Stop/start listening to retry."))
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
    func appendContext(_ text: String, delegationID: String?) {}
    func disconnect() async {
        closing = true; active = false
        if !ready { loading?.cancel(); await loading?.value }
        continuation?.finish()
        var finalized = ready && !failed && pending.isEmpty
        if let analyzer {
            let deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.failed = true; await analyzer.cancelAndFinishNow()
            }
            if ready {
                do { try await analyzer.finalizeAndFinishThroughEndOfInput(); await resultTask?.value }
                catch {
                    let recognition = error as NSError
                    // Apple's recognizer rejects a genuinely silent stream when
                    // finalizing it. No speech and no transcript is a valid stop.
                    finalized = !heardSpeech && recognition.domain == "SFSpeechErrorDomain" && recognition.code == 1
                }
            } else { await analyzer.cancelAndFinishNow() }
            deadline.cancel()
        }
        detectorTask?.cancel(); resultTask?.cancel(); loading?.cancel()
        pending.removeAll(); continuation = nil; analyzer = nil; ready = false; closing = false
        onEvent?(.partialTranscript("")); onEvent?(.speechActivity(false))
        onEvent?(.closed(finalized: finalized && !failed))
    }
}
