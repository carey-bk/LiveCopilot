import Foundation
import ScreenCaptureKit
import AVFoundation
import OSLog
import CoreGraphics

/// Captures SYSTEM audio (everyone else on the call — browser Meet, Zoom, Teams, anything)
/// via ScreenCaptureKit, with no microphone and no virtual audio device.
///
/// Output is delivered as 24 kHz mono PCM16 little-endian `Data`, ready for the Live API.
@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// Called on a background queue with PCM16 mono chunks tagged by capture session epoch.
    var onPCM16: ((Data, UUID) -> Void)?
    /// Optional content-free level/arrival accounting; observed on the capture queue.
    var flow: AudioFlowMonitor?
    /// Optional speaker-echo reference; observed on the capture queue with the buffer's capture time.
    var echo: EchoMonitor?

    /// Controllable backend handle for deterministic tests without Screen Recording permission.
    protocol StreamHandle: Sendable {
        func startCapture() async throws
        func stopCapture() async throws
    }
    var startTimeoutSeconds: TimeInterval = 10.0
    var stopTimeoutSeconds: TimeInterval = 5.0
    var testStreamFactory: ((_ deliver: @escaping @Sendable (Data, TimeInterval) -> Void) async throws -> any StreamHandle)?
    var diagnosticObserver: ((CaptureDiagnostics.Stage, CaptureDiagnostics.Details?) -> Void)?
    private var testHandle: (any StreamHandle)?
    private var activeGate: CaptureSessionGate?
    private var pendingGates: [UUID: CaptureSessionGate] = [:]

    private struct StartedSCStream {
        let stream: SCStream
        let output: AudioStreamOutput
    }

    private let log = Logger(subsystem: "com.livecopilot.app", category: "audio")
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var captureRevision = UUID()
    private var pcmBufferCount = 0
    private var outputSampleRate: Double = 24000
    func configure(sampleRate: Double) { if !isCapturing { outputSampleRate = sampleRate } }
    private let outputQueue = DispatchQueue(label: "com.livecopilot.audio.output")

    private func recordDiagnostic(_ stage: CaptureDiagnostics.Stage, code: Int? = nil, details: CaptureDiagnostics.Details? = nil) {
        CaptureDiagnostics.record(stage, code: code, details: details)
        diagnosticObserver?(stage, details)
    }

    /// Runs an async MainActor operation with a hard upper time bound so a wedged ScreenCaptureKit
    /// XPC call or hung stream handle cannot stall session startup or rollback indefinitely.
    /// If `operation` ignores task cancellation and resolves after the timeout, `onLateSuccess`
    /// runs in a fresh uncancelled MainActor task to tear down the leaked stream or handle.
    private static func runWithTimeout<T>(
        _ seconds: TimeInterval,
        onLateSuccess: (@MainActor (T) async -> Void)? = nil,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let timeoutNS = UInt64(max(0.05, seconds) * 1_000_000_000)
        return try await withCheckedThrowingContinuation { cont in
            let gate = TimeoutGate()
            let workTask = Task { @MainActor in
                do {
                    let value = try await operation()
                    if gate.claim() {
                        cont.resume(returning: value)
                    } else if let onLateSuccess {
                        Task { @MainActor in
                            await onLateSuccess(value)
                        }
                    }
                } catch {
                    guard gate.claim() else { return }
                    cont.resume(throwing: error)
                }
            }
            let timerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNS)
                guard gate.claim() else { return }
                workTask.cancel()
                cont.resume(throwing: CaptureError.timedOut)
            }
            gate.setTimer(timerTask)
        }
    }

    /// ScreenCaptureKit's first query in a process took about 2 s on a first Start. Asking for the
    /// shareable content ahead of time (no stream, no recording indicator) warms it. Only with an
    /// existing Screen Recording grant, so it never prompts.
    func prewarm() {
        guard testStreamFactory == nil, !isCapturing, CGPreflightScreenCaptureAccess() else { return }
        Task.detached(priority: .utility) {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            DebugLog.log(String(format: "AUDIO prewarm %.0f ms", (ProcessInfo.processInfo.systemUptime - started) * 1000))
        }
    }

    func start(sessionID: UUID = UUID()) async {
        guard !isCapturing else { return }
        let revision = UUID(); captureRevision = revision
        for staleGate in pendingGates.values { staleGate.invalidate() }
        pendingGates.removeAll()
        lastError = nil
        recordDiagnostic(.systemStart)
        let gate = CaptureSessionGate(sessionID: sessionID)
        pendingGates[revision] = gate
        defer { pendingGates.removeValue(forKey: revision) }
        let stopTimeout = stopTimeoutSeconds
        if let testStreamFactory {
            do {
                let emit = onPCM16, flow = self.flow, echo = self.echo
                let handle: any StreamHandle = try await Self.runWithTimeout(
                    startTimeoutSeconds,
                    onLateSuccess: { (lateHandle: any StreamHandle) in
                        gate.invalidate()
                        try? await Self.runWithTimeout(stopTimeout) {
                            try await lateHandle.stopCapture()
                        }
                    },
                    operation: {
                        let handle = try await testStreamFactory { data, captureTime in
                            gate.deliverIfActive {
                                flow?.observe(data)
                                echo?.observe(data, source: .system, at: captureTime)
                                emit?(data, gate.sessionID)
                            }
                        }
                        try await handle.startCapture()
                        return handle
                    }
                )
                guard captureRevision == revision else {
                    gate.invalidate()
                    try? await Self.runWithTimeout(stopTimeout) {
                        try await handle.stopCapture()
                    }
                    return
                }
                self.activeGate = gate
                self.testHandle = handle
                self.isCapturing = true
                recordDiagnostic(.systemReady, details: .init(sampleRate: outputSampleRate, channels: 1))
            } catch {
                gate.invalidate()
                guard captureRevision == revision else { return }
                recordDiagnostic(.systemFailed, code: (error as NSError).code, details: CaptureDiagnostics.errorDetails(error))
                lastError = humanReadable(error)
            }
            return
        }
        // Checking a denied/stale grant must not spawn a new macOS prompt on
        // every Start. The explicit Settings button owns the permission request.
        guard CGPreflightScreenCaptureAccess() else {
            gate.invalidate()
            recordDiagnostic(.systemFailed)
            lastError = "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen LiveCopilot."
            return
        }
        do {
            // Pick the main display as the capture surface. We discard video frames;
            // ScreenCaptureKit still requires a content filter built from shareable content.
            let content = try await Self.runWithTimeout(startTimeoutSeconds) {
                try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
            }
            guard captureRevision == revision else { gate.invalidate(); return }
            guard let display = content.displays.first else {
                throw CaptureError.noDisplay
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = Self.makeAudioOnlyStreamConfiguration(sampleRate: Config.realtimeSampleRate)

            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            let output = AudioStreamOutput(gate: gate, emit: onPCM16, flow: flow, echo: echo, sampleRate: outputSampleRate)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            let log = self.log
            let started = try await Self.runWithTimeout(
                startTimeoutSeconds,
                onLateSuccess: { (late: StartedSCStream) in
                    gate.invalidate()
                    log.warning("Stopping late ScreenCaptureKit stream after start timeout")
                    try? await Self.runWithTimeout(stopTimeout) {
                        try await late.stream.stopCapture()
                    }
                    withExtendedLifetime(late.output) {}
                },
                operation: {
                    try await stream.startCapture()
                    return StartedSCStream(stream: stream, output: output)
                }
            )
            guard captureRevision == revision else {
                gate.invalidate()
                try? await Self.runWithTimeout(stopTimeout) {
                    try await started.stream.stopCapture()
                }
                withExtendedLifetime(started.output) {}
                return
            }

            self.activeGate = gate
            self.output = started.output
            self.stream = started.stream
            self.isCapturing = true
            recordDiagnostic(.systemReady, details: .init(sampleRate: Double(cfg.sampleRate), channels: UInt32(cfg.channelCount)))
            log.info("System audio capture started")
            DebugLog.log("AUDIO capture started OK")
        } catch {
            gate.invalidate()
            guard captureRevision == revision else { return }
            recordDiagnostic(.systemFailed, code: (error as NSError).code, details: CaptureDiagnostics.errorDetails(error))
            lastError = humanReadable(error)
            log.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.log("AUDIO capture FAILED: \(error.localizedDescription)")
        }
    }

    func stop() async {
        captureRevision = UUID()
        // Immediately silence old stream callbacks before awaiting stopCapture so late frames
        // from a timed-out stream can never reach the next session's flow, echo, or provider.
        for gate in pendingGates.values { gate.invalidate() }
        pendingGates.removeAll()
        activeGate?.invalidate()
        activeGate = nil
        let activeStream = self.stream
        let activeTestHandle = self.testHandle
        guard activeStream != nil || activeTestHandle != nil else { return }
        self.stream = nil
        self.testHandle = nil
        self.output = nil
        self.isCapturing = false
        let timeoutNS = UInt64(max(0.05, stopTimeoutSeconds) * 1_000_000_000)
        let timedOut: Bool = await withCheckedContinuation { cont in
            var resumed = false
            Task { @MainActor [weak self] in
                do {
                    if let activeStream { try await activeStream.stopCapture() }
                    else if let activeTestHandle { try await activeTestHandle.stopCapture() }
                } catch {
                    self?.log.error("Stop failed: \(error.localizedDescription, privacy: .public)")
                }
                // Record .systemStopped only when the underlying stream actually confirms stop.
                self?.recordDiagnostic(.systemStopped)
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: false)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNS)
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: true)
            }
        }
        if timedOut {
            recordDiagnostic(.stopStage, details: .init(lifecyclePhase: .systemStop, timedOut: true))
            log.error("System audio stopCapture timed out after \(self.stopTimeoutSeconds)s")
        }
        log.info("System audio capture stopped")
    }

    private func humanReadable(_ error: Error) -> String {
        if let captureError = error as? CaptureError, captureError == .timedOut {
            return "System audio capture timed out while starting. Check Screen Recording permission or retry."
        }
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain && ns.code == SCStreamError.userDeclined.rawValue {
            return "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen LiveCopilot."
        }
        return error.localizedDescription
    }

    enum CaptureError: Error, Equatable { case noDisplay, timedOut }

    /// Minimize ScreenCaptureKit display-capture & GPU surface work when only system audio is needed.
    /// Audio callbacks arrive on CoreAudio cadence independent of the discarded video frame interval.
    nonisolated static func makeAudioOnlyStreamConfiguration(sampleRate: Double) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(sampleRate)
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        cfg.queueDepth = 1
        cfg.showsCursor = false
        cfg.scalesToFit = false
        return cfg
    }
}

extension AudioCaptureManager.StreamHandle {
    func startCapture() async throws {}
}

// MARK: - SCStream callbacks

extension AudioCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.activeGate?.invalidate()
            self.activeGate = nil
            self.stream = nil
            self.output = nil
            self.recordDiagnostic(.systemFailed, code: (error as NSError).code, details: CaptureDiagnostics.errorDetails(error))
            self.lastError = self.humanReadable(error)
            self.isCapturing = false
        }
    }
}

/// Ensures a timeout race resumes its CheckedThrowingContinuation at most once and cancels the timer on completion.
private final class TimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var timerTask: Task<Void, Never>?

    func setTimer(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyResumed = resumed
        if !alreadyResumed { timerTask = task }
        lock.unlock()
        if alreadyResumed { task.cancel() }
    }

    func claim() -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        let task = timerTask
        timerTask = nil
        lock.unlock()
        task?.cancel()
        return true
    }
}

/// Synchronizes capture session teardown with background sample callbacks so late frames
/// from a timed-out SCStream never touch the next session's flow, echo monitor, or live provider.
private final class CaptureSessionGate: @unchecked Sendable {
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

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let converter = PCMConverter()
    private let gate: CaptureSessionGate
    private let emit: ((Data, UUID) -> Void)?
    private let flow: AudioFlowMonitor?
    private let echo: EchoMonitor?
    init(gate: CaptureSessionGate, emit: ((Data, UUID) -> Void)?, flow: AudioFlowMonitor?, echo: EchoMonitor?, sampleRate: Double) {
        self.gate = gate; self.emit = emit; self.flow = flow; self.echo = echo; converter.configure(sampleRate: sampleRate)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = sampleBuffer.toPCMBuffer(),
              let data = converter.convert(buffer) else { return }
        // Presentation time is on the host clock. ScreenCaptureKit delivers later than the
        // microphone tap, so arrival time would misalign the echo reference.
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureTime = EchoMonitor.captureEnd(
            start: start.isValid ? start.seconds : nil, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
        gate.deliverIfActive {
            flow?.observe(data)
            echo?.observe(data, source: .system, at: captureTime)
            emit?(data, gate.sessionID)
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }
}
