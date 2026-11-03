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
    private var engine = AVAudioEngine()
    private var engineRevision = UUID()
    private let pcmConverter = PCMConverter()
    private var configurationObserver: NSObjectProtocol?
    private var captureRevision = UUID()
    private var recoveries: [TimeInterval] = []
    /// AVAudioEngine raises an Objective-C exception, which Swift cannot catch, on a second tap.
    private var tapInstalled = false
    /// Optional content-free level/arrival accounting; observed on the audio thread.
    var flow: AudioFlowMonitor?
    func configure(sampleRate: Double) { if !isCapturing { pcmConverter.configure(sampleRate: sampleRate) } }

    init() { observeEngine() }

    private func observeEngine() {
        let revision = engineRevision
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing, self.engineRevision == revision else { return }
                self.recoverFromConfigurationChange()
            }
        }
    }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }

    func start() async {
        let revision = UUID(); captureRevision = revision
        CaptureDiagnostics.record(.micPermission)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard captureRevision == revision else { return }
        CaptureDiagnostics.record(.micPermission, details: .init(permissionGranted: granted))
        guard granted else {
            CaptureDiagnostics.record(.micFailed)
            lastError = "Microphone permission denied. Enable LiveCopilot in System Settings → Privacy & Security → Microphone."
            return
        }
        guard !isCapturing else { return }
        lastError = nil
        recoveries = []
        rebuildEngine()
        if startEngine() { isCapturing = true }
    }

    /// Reads the current input format, installs the tap and starts the engine.
    /// On failure, leaves no tap installed and sets `lastError`.
    private func startEngine() -> Bool {
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

        CaptureDiagnostics.record(.micFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        CaptureDiagnostics.record(.micFormat, details: .init(sampleRate: inputFormat.sampleRate.isFinite ? inputFormat.sampleRate : nil, channels: inputFormat.channelCount, echoCancellation: Config.micEchoCancellation))
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            CaptureDiagnostics.record(.micFailed)
            lastError = "No microphone input available."
            DebugLog.log("MIC no input format")
            return false
        }

        let worker = pcmConverter, emit = onPCM16, flow = self.flow
        CaptureDiagnostics.record(.micTap)
        removeTap()
        // `nil` taps the bus's current format. Passing the format read above raises an uncatchable
        // exception if the hardware format changes first (for example a Bluetooth headset switching
        // profile as its microphone opens). The converter follows each buffer's own format.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            if let data = worker.convert(buffer) { flow?.observe(data); emit?(data) }
        }
        tapInstalled = true

        do {
            CaptureDiagnostics.record(.micEngine)
            engine.prepare()
            try engine.start()
            CaptureDiagnostics.record(.micReady, details: .init(sampleRate: inputFormat.sampleRate, channels: inputFormat.channelCount))
            DebugLog.log("MIC capture started OK (input \(inputFormat.sampleRate)Hz)")
            return true
        } catch {
            CaptureDiagnostics.record(.micFailed, code: (error as NSError).code, details: CaptureDiagnostics.errorDetails(error))
            lastError = error.localizedDescription
            DebugLog.log("MIC capture FAILED: \(error.localizedDescription)")
            removeTap()
            return false
        }
    }

    /// AVAudioEngine stops itself when the input/output hardware format changes, e.g. when a
    /// Bluetooth headset switches profile as its microphone opens, or the default device changes.
    /// Rebuild the tap for the new format instead of leaving the session silently without audio.
    /// Bounded so a device that keeps reconfiguring cannot cause a restart loop.
    private func recoverFromConfigurationChange() {
        // A new route change supersedes retries waiting for the previous route to settle.
        captureRevision = UUID()
        CaptureDiagnostics.record(.micDeviceChanged)
        let now = ProcessInfo.processInfo.systemUptime
        recoveries = recoveries.filter { now - $0 < 30 } + [now]
        rebuildEngine()
        guard recoveries.count <= 3 else { stopAfterDeviceChange(); return }
        if startEngine() {
            lastError = nil
            DebugLog.log("MIC recovered after device configuration change")
            return
        }
        // The new route's format can be briefly unavailable while it settles; retry once.
        let revision = captureRevision
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isCapturing, self.captureRevision == revision, !self.tapInstalled else { return }
            self.rebuildEngine()
            if self.startEngine() {
                self.lastError = nil
                DebugLog.log("MIC recovered after device configuration change (retry)")
            } else { self.stopAfterDeviceChange() }
        }
    }

    private func stopAfterDeviceChange() {
        isCapturing = false
        CaptureDiagnostics.record(.micStopped)
        lastError = "Microphone device configuration changed. Stop/start listening to use the current device."
        DebugLog.log("MIC stopped after device configuration change")
    }

    func stop() {
        captureRevision = UUID()
        guard isCapturing else { return }
        removeTap()
        engine.stop()
        pcmConverter.reset()
        isCapturing = false
        CaptureDiagnostics.record(.micStopped)
        DebugLog.log("MIC capture stopped")
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// A stopped engine can retain the old input-bus format after a Bluetooth route change.
    /// Replacing the graph refreshes that format; reinstalling a nil-format tap on the old
    /// graph still inherited 48 kHz while the AirPods hardware had moved to 24 kHz (-10868).
    /// Called on MainActor after the notification callback returns, never from that callback.
    private func rebuildEngine() {
        engineRevision = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        removeTap()
        engine.stop()
        pcmConverter.reset()
        engine = AVAudioEngine()
        observeEngine()
    }
}
