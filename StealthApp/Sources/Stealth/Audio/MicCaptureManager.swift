import Foundation
import AVFoundation
import OSLog

/// Captures YOUR microphone and delivers 24 kHz mono PCM16 chunks,
/// matching the format the Live API expects (same as system audio).
///
/// Uses AVAudioEngine's input node tap → AVAudioConverter to the target format.
@MainActor
final class MicCaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// Called on the audio thread with PCM16 mono 24kHz chunks.
    var onPCM16: ((Data) -> Void)?

    private let log = Logger(subsystem: "com.livecopilot.app", category: "mic")
    private let engine = AVAudioEngine()
    private let pcmConverter = PCMConverter()
    private var configurationObserver: NSObjectProtocol?
    private var captureRevision = UUID()

    init() {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                self.stop()
                self.lastError = "Microphone device configuration changed. Stop/start listening to use the current device."
            }
        }
    }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }

    func start() async {
        let revision = UUID(); captureRevision = revision
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard captureRevision == revision else { return }
        guard granted else {
            lastError = "Microphone permission denied. Enable LiveCopilot in System Settings → Privacy & Security → Microphone."
            return
        }
        guard !isCapturing else { return }
        lastError = nil

        let input = engine.inputNode

        // Apple's voice processing (acoustic echo cancellation + noise suppression)
        // subtracts speaker bleed so it isn't mislabeled "You" — but it can also
        // over-suppress the user's own voice, leaving the "You" side silent. Gated by
        // Config so we can isolate that. NOTE: enabling changes the input format, so
        // read the format AFTER.
        if Config.micEchoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                DebugLog.log("MIC voice processing (AEC) enabled")
            } catch {
                DebugLog.log("MIC AEC enable failed (continuing without): \(error.localizedDescription)")
            }
        } else {
            DebugLog.log("MIC voice processing (AEC) DISABLED (Config.micEchoCancellation=false)")
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            lastError = "No microphone input available."
            DebugLog.log("MIC no input format")
            return
        }

        let worker = pcmConverter, emit = onPCM16
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            if let data = worker.convert(buffer) { emit?(data) }
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            DebugLog.log("MIC capture started OK (input \(inputFormat.sampleRate)Hz)")
        } catch {
            lastError = error.localizedDescription
            DebugLog.log("MIC capture FAILED: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        captureRevision = UUID()
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pcmConverter.reset()
        isCapturing = false
        DebugLog.log("MIC capture stopped")
    }

}
