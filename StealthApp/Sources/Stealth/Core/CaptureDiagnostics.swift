import Foundation

/// Bounded structured journal. Never accepts free-form error messages, paths or captured content.
enum CaptureDiagnostics {
    enum Stage: String, Codable {
        case appLaunch, cleanExit, listeningStart, systemStart, systemReady, systemFailed, systemStopped
        case micPermission, micFormat, micTap, micEngine, micReady, micFailed, micStopped, micDeviceChanged
        case speechConnecting, speechReady, speechFailed, listeningStop, workerStart, workerExit, workerFailure
        /// Per-source audio flow, a few seconds after capture starts and when the source stops.
        case audioCheck, audioSummary
        /// Privacy-safe reliability telemetry: main-thread stalls and stop/shutdown phase boundaries.
        case mainThreadStall, stopStage, shutdownStage
    }
    enum WorkerTerminationInitiator: String, Codable {
        case selfCheck, shutdown, userCancel, answerTimeout, workerTimeout, discardOnError, modelRemoved, deinitCleanup, external
    }
    enum LifecyclePhase: String, Codable {
        case verificationWait, retrievalWait, systemStop, micStop, disconnectProviders, complete
    }
    enum Failure: String, Codable {
        case unknown, embedding_context, inference_failed, timeout, runtime_missing, runtime_start
        case embedding_load, model_load_failed, process_ended
        case queueTimeout = "queue_timeout"
        /// A started embedding worker rejected one input at this stage (never the input itself).
        case token_limit, text_size, embedding_decode, embedding_dimension, embedding_finite, embedding_zero
        /// Captured audio exceeded the bound while the speech model loaded, or after it was ready.
        case speech_load_slow, speech_behind
    }
    struct Details: Codable {
        var sampleRate: Double?; var channels: UInt32?; var echoCancellation: Bool?
        var permissionGranted: Bool?; var errorDomain: String?
        var listeningService: String?; var captureMode: String?; var automatic: Bool?
        var speaker: String?; var workerMode: String?; var workerPID: Int32?
        var terminationReason: Int?; var failure: Failure?
        var workerTerminationInitiator: WorkerTerminationInitiator?
        var lifecyclePhase: LifecyclePhase?; var timedOut: Bool?
        var stallMS: Int?; var isRunning: Bool?; var isTransitioning: Bool?
        var answerIsRunning: Bool?; var transcriptLineCount: Int?
        var audioVerdict: AudioFlowMonitor.Verdict?; var audioSeconds: Double?; var firstAudioMS: Int?
        var peakDBFS: Int?; var audibleFraction: Double?; var partials: Int?; var transcripts: Int?
        var textLatencyMeanMS: Int?; var textLatencyMaxMS: Int?; var backlogMaxMS: Int?
        var readyMS: Int?; var finalLagMeanMS: Int?; var finalLagMaxMS: Int?
        var echo: EchoMonitor.Counters?
    }
    static func audioDetails(_ flow: AudioFlowMonitor.Snapshot, speaker: String, recognition: RecognitionStats? = nil, echo: EchoMonitor.Counters? = nil) -> Details {
        Details(speaker: speaker, audioVerdict: flow.verdict, audioSeconds: flow.audioSeconds, firstAudioMS: flow.firstAudioMS,
                peakDBFS: flow.peakDBFS, audibleFraction: flow.audibleFraction, partials: flow.partials, transcripts: flow.transcripts,
                textLatencyMeanMS: flow.textLatencyMeanMS, textLatencyMaxMS: flow.textLatencyMaxMS, backlogMaxMS: recognition?.backlogMaxMS,
                readyMS: recognition?.readyMS, finalLagMeanMS: recognition?.finalLagMeanMS, finalLagMaxMS: recognition?.finalLagMaxMS, echo: echo)
    }
    struct Event: Codable {
        let time: Date; let stage: Stage; let code: Int?
        var schema: Int? = 2
        var launchID: UUID?; var captureID: UUID?; var build: String?; var pid: Int32?
        var uptime: Double?; var details: Details?
    }
    static let launchID = UUID()
    private static var captureID: UUID?
    private static let queue = DispatchQueue(label: "com.livecopilot.capture-diagnostics")
    private static var url: URL {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let suffix = bundle == "com.livecopilot.app" ? "" : "/Development"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveCopilot\(suffix)/capture-diagnostics.json")
    }
    static func errorDetails(_ error: Error) -> Details {
        let domain = (error as NSError).domain
        let known = ["NSOSStatusErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSURLErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain", "com.apple.coreaudio.avfaudio"]
        return Details(errorDomain: known.contains(domain) ? domain : "other")
    }
    static func record(_ stage: Stage, code: Int? = nil, details: Details? = nil) {
        // Do not record test hosts, mock runs or synthetic fixture workers. Development builds record
        // into their own journal (see `url`) so hardware checks of a local build leave evidence.
        let environment = ProcessInfo.processInfo.environment
        guard ["com.livecopilot.app", "com.livecopilot.development"].contains(Bundle.main.bundleIdentifier ?? ""),
              environment["XCTestConfigurationFilePath"] == nil, environment["LIVECOPILOT_MOCK"] != "1",
              !ProcessInfo.processInfo.arguments.contains("--mock") else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            if stage == .listeningStart { captureID = UUID() }
            let event = Event(time: now, stage: stage, code: code, launchID: launchID,
                              captureID: captureID, build: build,
                              pid: pid, uptime: uptime, details: details)
            try? append(event, to: url)
        }
    }
    @discardableResult
    static func flush(timeout: TimeInterval = 0.5) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }
    static func append(_ event: Event, to destination: URL) throws {
        var events = read(from: destination); events.append(event)
        let data = try JSONEncoder().encode(Array(events.suffix(256)))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    static func read(from source: URL) -> [Event] {
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
              let data = try? Data(contentsOf: source) else { return [] }
        // Skip individual records this build cannot decode (e.g. a stage added by a newer build)
        // instead of discarding, and later overwriting, the whole journal.
        guard let rows = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return rows.compactMap(\.event)
    }
    private struct Lossy: Decodable {
        let event: Event?
        init(from decoder: Decoder) throws { event = try? Event(from: decoder) }
    }
    /// Numbers only: never transcript text, device names or paths.
    static func summaryLine(_ event: Event) -> String {
        var line = "\(ISO8601DateFormatter().string(from: event.time)) \(event.stage.rawValue)\(event.code.map { " code=\($0)" } ?? "")"
        guard let d = event.details,
              d.audioVerdict != nil || d.failure != nil || d.readyMS != nil ||
              d.workerTerminationInitiator != nil || d.lifecyclePhase != nil || d.stallMS != nil else { return line }
        var fields: [String] = []
        if let v = d.speaker { fields.append("speaker=\(v)") }
        if let v = d.workerMode { fields.append("worker=\(v)") }
        if let v = d.workerTerminationInitiator { fields.append("initiator=\(v.rawValue)") }
        if let v = d.lifecyclePhase { fields.append("phase=\(v.rawValue)") }
        if let v = d.timedOut { fields.append("timed_out=\(v)") }
        if let v = d.stallMS { fields.append("stall_ms=\(v)") }
        if let v = d.isRunning { fields.append("running=\(v)") }
        if let v = d.isTransitioning { fields.append("transitioning=\(v)") }
        if let v = d.answerIsRunning { fields.append("answering=\(v)") }
        if let v = d.transcriptLineCount { fields.append("lines=\(v)") }
        if let v = d.failure { fields.append("failure=\(v.rawValue)") }
        if let v = d.readyMS { fields.append("ready_ms=\(v)") }
        if let v = d.audioVerdict { fields.append("verdict=\(v.rawValue)") }
        if let v = d.audioSeconds { fields.append("audio_s=\(v)") }
        if let v = d.firstAudioMS { fields.append("first_audio_ms=\(v)") }
        if let v = d.peakDBFS { fields.append("peak_dbfs=\(v)") }
        if let v = d.audibleFraction { fields.append("audible=\(v)") }
        if let v = d.partials { fields.append("partials=\(v)") }
        if let v = d.transcripts { fields.append("finals=\(v)") }
        if let v = d.textLatencyMeanMS { fields.append("activity_to_text_ms_mean=\(v)") }
        if let v = d.textLatencyMaxMS { fields.append("activity_to_text_ms_max=\(v)") }
        if let v = d.backlogMaxMS { fields.append("backlog_ms_max=\(v)") }
        if let v = d.finalLagMeanMS { fields.append("final_lag_ms_mean=\(v)") }
        if let v = d.finalLagMaxMS { fields.append("final_lag_ms_max=\(v)") }
        if let e = d.echo {
            fields.append("echo_held=\(e.heldTurns) echo_confirmed=\(e.confirmedTurns) echo_ignored=\(e.ignoredFinals) echo_unclear=\(e.unclearFinals) echo_confirm_ms_max=\(e.confirmMSMax) echo_text_finals=\(e.textEchoFinals) echo_text_confirms=\(e.textOwnConfirms) echo_confirmed_turn_echo=\(e.confirmedTurnEchoFinals)")
            if let lag = e.pathLagMS, let gain = e.pathGainDB { fields.append("echo_lag_ms=\(lag) echo_gain_db=\(gain)") }
            if let corr = e.bestCorrelationPercent, let lag = e.bestLagMS { fields.append("echo_best_corr=\(corr) echo_best_lag_ms=\(lag)") }
            fields.append("delivery_ms_max_system=\(e.systemDelayMSMax) delivery_ms_max_mic=\(e.micDelayMSMax)")
            fields.append("echo_frames_ms=\(e.echoFrameMS) unclear_frames_ms=\(e.unclearFrameMS) own_silent_far_end_ms=\(e.ownSilentFarEndMS) own_louder_ms=\(e.ownLouderMS) own_excess_4_8_ms=\(e.ownExcess4to8MS) own_excess_8_12_ms=\(e.ownExcess8to12MS) own_clear_ms=\(e.ownClearMS)")
        }
        line += " " + fields.joined(separator: " ")
        return line
    }
    static func journal() -> Data { queue.sync { (try? JSONEncoder().encode(read(from: url))) ?? Data("[]".utf8) } }
    static func snapshot() -> String {
        queue.sync { read(from: url).suffix(20).map(summaryLine).joined(separator: "\n") }
    }
    static func previousExitSummary(events: [Event]) -> String {
        guard let lastLaunch = events.last(where: { $0.stage == .appLaunch && $0.launchID != launchID }), let id = lastLaunch.launchID else {
            return "Previous launch unavailable (new journal or retention limit)."
        }
        return events.contains { $0.launchID == id && $0.stage == .cleanExit }
            ? "Previous recorded launch exited cleanly."
            : "Previous recorded launch has no clean-exit marker. This may be a crash, force quit, power loss, or incomplete record; it is not proof of a crash."
    }
    static func previousExitSummary() -> String { queue.sync { previousExitSummary(events: read(from: url)) } }
}

/// Lightweight, content-free main-thread stall detector.
/// Periodically pings the main queue from a background timer and records a single
/// rate-limited numeric diagnostic event when a ping stalls beyond `thresholdSeconds`.
final class MainThreadWatchdog: @unchecked Sendable {
    struct StateSnapshot: Sendable {
        var isRunning = false
        var isTransitioning = false
        var answerIsRunning = false
        var transcriptLineCount = 0
    }
    private let queue = DispatchQueue(label: "com.livecopilot.main-thread-watchdog", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pendingSince: TimeInterval?
    private var lastReportedAt: TimeInterval = 0
    private var latestState = StateSnapshot()
    private let intervalSeconds: TimeInterval
    private let thresholdSeconds: TimeInterval
    private let cooldownSeconds: TimeInterval
    private let onStall: @Sendable (Int, StateSnapshot) -> Void

    init(intervalSeconds: TimeInterval = 2.0,
         thresholdSeconds: TimeInterval = 1.5,
         cooldownSeconds: TimeInterval = 15.0,
         onStall: @escaping @Sendable (Int, StateSnapshot) -> Void = { stallMS, state in
             CaptureDiagnostics.record(.mainThreadStall, details: .init(
                 stallMS: stallMS, isRunning: state.isRunning, isTransitioning: state.isTransitioning,
                 answerIsRunning: state.answerIsRunning, transcriptLineCount: state.transcriptLineCount))
         }) {
        self.intervalSeconds = intervalSeconds
        self.thresholdSeconds = thresholdSeconds
        self.cooldownSeconds = cooldownSeconds
        self.onStall = onStall
    }

    deinit { stop() }

    func updateState(_ snapshot: StateSnapshot) {
        lock.withLock { latestState = snapshot }
    }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            pendingSince = nil
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var stallToReport: (Int, StateSnapshot)?
        var shouldPing = false
        lock.withLock {
            if let since = pendingSince {
                let elapsed = now - since
                if elapsed >= thresholdSeconds && now - lastReportedAt >= cooldownSeconds {
                    lastReportedAt = now
                    stallToReport = (Int((elapsed * 1000).rounded()), latestState)
                }
            } else {
                pendingSince = now
                shouldPing = true
            }
        }
        if let (ms, state) = stallToReport { onStall(ms, state) }
        if shouldPing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let doneAt = ProcessInfo.processInfo.systemUptime
                var lateStall: (Int, StateSnapshot)?
                self.lock.withLock {
                    if let since = self.pendingSince {
                        let elapsed = doneAt - since
                        if elapsed >= self.thresholdSeconds && doneAt - self.lastReportedAt >= self.cooldownSeconds {
                            self.lastReportedAt = doneAt
                            lateStall = (Int((elapsed * 1000).rounded()), self.latestState)
                        }
                    }
                    self.pendingSince = nil
                }
                if let (ms, state) = lateStall {
                    let callback = self.onStall
                    self.queue.async { callback(ms, state) }
                }
            }
        }
    }
}
