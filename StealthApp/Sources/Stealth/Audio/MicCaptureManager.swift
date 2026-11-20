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

    /// Called on the audio thread with PCM16 mono chunks and their capture session ID.
    var onPCM16: ((Data, UUID) -> Void)?
    /// Test-only hook to simulate microphone capture startup and frame delivery without hardware/TCC.
    var testStartHandler: ((@escaping @Sendable (Data, TimeInterval) -> Void) async -> Bool)?

    private let log = Logger(subsystem: "com.livecopilot.app", category: "mic")
    private var engine = AVAudioEngine()
    private var engineRevision = UUID()
    private let pcmConverter = PCMConverter()
    private var configurationObserver: NSObjectProtocol?
    private var captureRevision = UUID()
    private var activeGate: MicSessionGate?
    private var activeSessionID = UUID()
    private var recoveries: [TimeInterval] = []
    /// AVAudioEngine raises an Objective-C exception, which Swift cannot catch, on a second tap.
    private var tapInstalled = false
    /// Optional content-free level/arrival accounting; observed on the audio thread.
    var flow: AudioFlowMonitor?
    /// Optional speaker-echo evidence; observed on the audio thread with the buffer's capture time.
    var echo: EchoMonitor?
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

    func start(sessionID: UUID = UUID()) async {
        guard !isCapturing else { return }
        let revision = UUID(); captureRevision = revision
        let gate = MicSessionGate(sessionID: sessionID)
        if let testStartHandler {
            let emit = onPCM16, flow = self.flow, echo = self.echo
            let started = await testStartHandler { data, captureTime in
                gate.deliverIfActive {
                    flow?.observe(data)
                    echo?.observe(data, source: .mic, at: captureTime)
                    emit?(data, gate.sessionID)
                }
            }
            guard captureRevision == revision, !isCapturing, started else { gate.invalidate(); return }
            lastError = nil
            recoveries = []
            activeGate?.invalidate()
            activeGate = gate
            activeSessionID = sessionID
            isCapturing = true
            return
        }
        CaptureDiagnostics.record(.micPermission)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard captureRevision == revision else { gate.invalidate(); return }
        CaptureDiagnostics.record(.micPermission, details: .init(permissionGranted: granted))
        guard granted else {
            gate.invalidate()
            CaptureDiagnostics.record(.micFailed)
            lastError = "Microphone permission denied. Enable LiveCopilot in System Settings → Privacy & Security → Microphone."
            return
        }
        guard !isCapturing else { gate.invalidate(); return }
        lastError = nil
        recoveries = []
        rebuildEngine()
        if startEngine(gate: gate) {
            activeGate?.invalidate()
            activeGate = gate
            activeSessionID = sessionID
            isCapturing = true
        } else {
            gate.invalidate()
        }
    }

    /// Reads the current input format, installs the tap and starts the engine.
    /// On failure, leaves no tap installed and sets `lastError`.
    private func startEngine(gate: MicSessionGate) -> Bool {
        let input = engine.inputNode

        // Use the hardware microphone format. Voice processing can expose a
        // multichannel input which converts to digital silence on built-in Macs.
        CaptureDiagnostics.record(.micFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        CaptureDiagnostics.record(.micFormat, details: .init(sampleRate: inputFormat.sampleRate.isFinite ? inputFormat.sampleRate : nil, channels: inputFormat.channelCount, echoCancellation: input.isVoiceProcessingEnabled))
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            CaptureDiagnostics.record(.micFailed)
            lastError = "No microphone input available."
            DebugLog.log("MIC no input format")
            return false
        }

        let worker = pcmConverter, emit = onPCM16, flow = self.flow, echo = self.echo
        CaptureDiagnostics.record(.micTap)
        removeTap()
        // `nil` taps the bus's current format. Passing the format read above raises an uncatchable
        // exception if the hardware format changes first (for example a Bluetooth headset switching
        // profile as its microphone opens). The converter follows each buffer's own format.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, when in
            if let data = worker.convert(buffer) {
                let captureTime = EchoMonitor.captureEnd(
                    start: when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil,
                    duration: Double(buffer.frameLength) / buffer.format.sampleRate)
                gate.deliverIfActive {
                    flow?.observe(data)
                    echo?.observe(data, source: .mic, at: captureTime)
                    emit?(data, gate.sessionID)
                }
            }
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
        activeGate?.invalidate()
        activeGate = nil
        CaptureDiagnostics.record(.micDeviceChanged)
        let now = ProcessInfo.processInfo.systemUptime
        recoveries = recoveries.filter { now - $0 < 30 } + [now]
        rebuildEngine()
        guard recoveries.count <= 3 else { stopAfterDeviceChange(); return }
        let gate = MicSessionGate(sessionID: activeSessionID)
        if startEngine(gate: gate) {
            activeGate = gate
            lastError = nil
            DebugLog.log("MIC recovered after device configuration change")
            return
        }
        gate.invalidate()
        // The new route's format can be briefly unavailable while it settles; retry once.
        let revision = captureRevision
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isCapturing, self.captureRevision == revision, !self.tapInstalled else { return }
            self.rebuildEngine()
            let retryGate = MicSessionGate(sessionID: self.activeSessionID)
            if self.startEngine(gate: retryGate) {
                self.activeGate = retryGate
                self.lastError = nil
                DebugLog.log("MIC recovered after device configuration change (retry)")
            } else {
                retryGate.invalidate()
                self.stopAfterDeviceChange()
            }
        }
    }

    private func stopAfterDeviceChange() {
        activeGate?.invalidate()
        activeGate = nil
        isCapturing = false
        CaptureDiagnostics.record(.micStopped)
        lastError = "Microphone device configuration changed. Stop/start listening to use the current device."
        DebugLog.log("MIC stopped after device configuration change")
    }

    /// Stops capture only if it still belongs to `sessionID`, so a stale teardown
    /// from a previous session can never stop a newer session's microphone.
    func stop(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        stop()
    }

    func stop() {
        captureRevision = UUID()
        activeGate?.invalidate()
        activeGate = nil
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

/// Synchronizes microphone teardown with CoreAudio tap callbacks so late frames
/// from an old session never touch the next session's flow, echo monitor, or live provider.
private final class MicSessionGate: @unchecked Sendable {
    let sessionID: UUID
    private let lock = NSLock()
    private var active = true
    init(sessionID: UUID) { self.sessionID = sessionID }
    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
    func deliverIfActive(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        body()
    }
}
