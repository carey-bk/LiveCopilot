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
    /// AVAudioEngine work runs on its own serial queue: creating the input node of a cold audio
    /// device took about 4 s on the main thread when listening started, freezing the app.
    private let core = MicEngine()
    private var engineRevision = UUID()
    private let pcmConverter = PCMConverter()
    private var configurationObserver: NSObjectProtocol?
    private var captureRevision = UUID()
    private var activeGate: MicSessionGate?
    private var activeSessionID = UUID()
    private var recoveries: [TimeInterval] = []
    /// Main-actor mirror of the engine queue's tap state, for retry guards.
    private var tapInstalled = false
    /// Optional content-free level/arrival accounting; observed on the audio thread.
    var flow: AudioFlowMonitor?
    /// Optional speaker-echo evidence; observed on the audio thread with the buffer's capture time.
    var echo: EchoMonitor?
    func configure(sampleRate: Double) { if !isCapturing { pcmConverter.configure(sampleRate: sampleRate) } }

    init() {}

    /// The first audio engine of a process spends seconds bringing up the input device (measured
    /// 4.7 s on a first Start, 0.1 s afterwards). Doing that ahead of time, without starting any
    /// input, makes the first Start as quick as later ones. Skipped without microphone permission
    /// (no prompt) and for a Bluetooth default input, where opening it could switch a headset into
    /// its lower-quality call profile.
    func prewarm() {
        guard testStartHandler == nil, !isCapturing else { return }
        let permission = AVCaptureDevice.authorizationStatus(for: .audio), bluetooth = AudioDevices.defaultInputIsBluetooth()
        guard permission == .authorized, !bluetooth else {
            DebugLog.log("MIC prewarm skipped permission=\(permission.rawValue) bluetooth=\(bluetooth)"); return
        }
        DebugLog.log("MIC prewarm queued")
        let core = self.core
        Task.detached(priority: .utility) { await core.run { $0.prewarm() } }
    }

    /// Follows configuration changes of the engine that is currently running.
    private func observe(_ engine: MicEngine.EngineRef) {
        engineRevision = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        let revision = engineRevision
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine.engine, queue: .main) { [weak self] _ in
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
        let started = await startEngine(gate: gate)
        // stop() during the await already queued the engine teardown behind this start.
        guard captureRevision == revision, !isCapturing else {
            gate.invalidate()
            if captureRevision != revision { tapInstalled = false }
            return
        }
        if started {
            activeGate?.invalidate()
            activeGate = gate
            activeSessionID = sessionID
            isCapturing = true
        } else {
            gate.invalidate()
        }
    }

    /// Replaces the engine, reads the current input format, installs the tap and starts it on the
    /// engine queue. On failure, leaves no tap installed and sets `lastError`.
    private func startEngine(gate: MicSessionGate) async -> Bool {
        pcmConverter.reset()
        let worker = pcmConverter, emit = onPCM16, flow = self.flow, echo = self.echo
        // `nil` taps the bus's current format. Passing a format read earlier raises an uncatchable
        // exception if the hardware format changes first (for example a Bluetooth headset switching
        // profile as its microphone opens). The converter follows each buffer's own format.
        let tap: AVAudioNodeTapBlock = { buffer, when in
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
        let result = await core.run { $0.rebuildAndStart(tap: tap) }
        switch result {
        case .success(let engine):
            tapInstalled = true
            observe(engine)
            return true
        case .failure(let message):
            tapInstalled = false
            lastError = message
            return false
        }
    }

    /// AVAudioEngine stops itself when the input/output hardware format changes, e.g. when a
    /// Bluetooth headset switches profile as its microphone opens, or the default device changes.
    /// Rebuild the tap for the new format instead of leaving the session silently without audio.
    /// Bounded so a device that keeps reconfiguring cannot cause a restart loop.
    private func recoverFromConfigurationChange() {
        // A new route change supersedes retries waiting for the previous route to settle.
        let revision = UUID(); captureRevision = revision
        activeGate?.invalidate()
        activeGate = nil
        CaptureDiagnostics.record(.micDeviceChanged)
        let now = ProcessInfo.processInfo.systemUptime
        recoveries = recoveries.filter { now - $0 < 30 } + [now]
        guard recoveries.count <= 3 else {
            tapInstalled = false
            core.queue.async { [core] in core.stop() }
            stopAfterDeviceChange(); return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gate = MicSessionGate(sessionID: self.activeSessionID)
            let started = await self.startEngine(gate: gate)
            guard self.isCapturing, self.captureRevision == revision else { gate.invalidate(); return }
            if started {
                self.activeGate = gate
                self.lastError = nil
                DebugLog.log("MIC recovered after device configuration change")
                return
            }
            gate.invalidate()
            // The new route's format can be briefly unavailable while it settles; retry once.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.isCapturing, self.captureRevision == revision, !self.tapInstalled else { return }
            let retryGate = MicSessionGate(sessionID: self.activeSessionID)
            let retried = await self.startEngine(gate: retryGate)
            guard self.isCapturing, self.captureRevision == revision else { retryGate.invalidate(); return }
            if retried {
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

    /// Frames stop at once through the gate; the engine teardown runs in order on its queue.
    func stop() {
        captureRevision = UUID()
        activeGate?.invalidate()
        activeGate = nil
        // Also tears down an engine whose start is still in flight.
        core.queue.async { [core] in core.stop() }
        tapInstalled = false
        guard isCapturing else { return }
        pcmConverter.reset()
        isCapturing = false
        CaptureDiagnostics.record(.micStopped)
        DebugLog.log("MIC capture stopped")
    }
}

/// Owns AVAudioEngine. Every member except `queue` and `run` is used only on `queue`.
private final class MicEngine: @unchecked Sendable {
    struct EngineRef: @unchecked Sendable { let engine: AVAudioEngine }
    enum StartResult: Sendable { case success(EngineRef), failure(String) }
    let queue = DispatchQueue(label: "com.livecopilot.mic-engine", qos: .userInitiated)
    private var engine: AVAudioEngine?
    /// AVAudioEngine raises an Objective-C exception, which Swift cannot catch, on a second tap.
    private var tapInstalled = false

    func run<T: Sendable>(_ body: @escaping @Sendable (MicEngine) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    func stop() {
        removeTap()
        engine?.stop()
    }

    /// Reads the input format of a throwaway engine; no tap is installed and nothing is started.
    func prewarm() {
        guard engine == nil else { return }
        let started = ProcessInfo.processInfo.systemUptime
        // The node belongs to the engine: keep the engine alive until the format has been read
        // (a temporary engine was released first and the read crashed).
        let engine = AVAudioEngine()
        let format = withExtendedLifetime(engine) { engine.inputNode.outputFormat(forBus: 0) }
        DebugLog.log(String(format: "MIC prewarm %.0f ms (input %.0f Hz)", (ProcessInfo.processInfo.systemUptime - started) * 1000, format.sampleRate))
    }

    private func removeTap() {
        guard tapInstalled, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// A stopped engine can retain the old input-bus format after a Bluetooth route change.
    /// Replacing the graph refreshes that format; reinstalling a nil-format tap on the old
    /// graph still inherited 48 kHz while the AirPods hardware had moved to 24 kHz (-10868).
    func rebuildAndStart(tap: @escaping AVAudioNodeTapBlock) -> StartResult {
        stop()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Use the hardware microphone format. Voice processing can expose a
        // multichannel input which converts to digital silence on built-in Macs.
        CaptureDiagnostics.record(.micFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        CaptureDiagnostics.record(.micFormat, details: .init(sampleRate: inputFormat.sampleRate.isFinite ? inputFormat.sampleRate : nil, channels: inputFormat.channelCount, echoCancellation: input.isVoiceProcessingEnabled))
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            CaptureDiagnostics.record(.micFailed)
            DebugLog.log("MIC no input format")
            return .failure("No microphone input available.")
        }
        CaptureDiagnostics.record(.micTap)
        input.installTap(onBus: 0, bufferSize: 2048, format: nil, block: tap)
        tapInstalled = true
        do {
            CaptureDiagnostics.record(.micEngine)
            engine.prepare()
            try engine.start()
            CaptureDiagnostics.record(.micReady, details: .init(sampleRate: inputFormat.sampleRate, channels: inputFormat.channelCount))
            DebugLog.log("MIC capture started OK (input \(inputFormat.sampleRate)Hz)")
            return .success(EngineRef(engine: engine))
        } catch {
            CaptureDiagnostics.record(.micFailed, code: (error as NSError).code, details: CaptureDiagnostics.errorDetails(error))
            DebugLog.log("MIC capture FAILED: \(error.localizedDescription)")
            removeTap()
            return .failure(error.localizedDescription)
        }
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

import CoreAudio

enum AudioDevices {
    /// Whether the system default input device is a Bluetooth (or Bluetooth LE) device.
    static func defaultInputIsBluetooth() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
