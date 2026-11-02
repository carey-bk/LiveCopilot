import Foundation

/// Bounded structured journal. Never accepts free-form error messages, paths or captured content.
enum CaptureDiagnostics {
    enum Stage: String, Codable {
        case appLaunch, cleanExit, listeningStart, systemStart, systemReady, systemFailed, systemStopped
        case micPermission, micFormat, micTap, micEngine, micReady, micFailed, micStopped, micDeviceChanged
        case speechConnecting, speechReady, speechFailed, listeningStop, workerStart, workerExit, workerFailure
        /// Per-source audio flow, a few seconds after capture starts and when the source stops.
        case audioCheck, audioSummary
    }
    enum Failure: String, Codable {
        case unknown, embedding_context, inference_failed, timeout, runtime_missing, runtime_start
        case embedding_load, model_load_failed, process_ended
        /// Captured audio exceeded the bound while the speech model loaded, or after it was ready.
        case speech_load_slow, speech_behind
    }
    struct Details: Codable {
        var sampleRate: Double?; var channels: UInt32?; var echoCancellation: Bool?
        var permissionGranted: Bool?; var errorDomain: String?
        var listeningService: String?; var captureMode: String?; var automatic: Bool?
        var speaker: String?; var workerMode: String?; var workerPID: Int32?
        var terminationReason: Int?; var failure: Failure?
        var audioVerdict: AudioFlowMonitor.Verdict?; var audioSeconds: Double?; var firstAudioMS: Int?
        var peakDBFS: Int?; var audibleFraction: Double?; var partials: Int?; var transcripts: Int?
        var textLatencyMeanMS: Int?; var textLatencyMaxMS: Int?; var backlogMaxMS: Int?
        var readyMS: Int?; var finalLagMeanMS: Int?; var finalLagMaxMS: Int?
    }
    static func audioDetails(_ flow: AudioFlowMonitor.Snapshot, speaker: String, recognition: RecognitionStats? = nil) -> Details {
        Details(speaker: speaker, audioVerdict: flow.verdict, audioSeconds: flow.audioSeconds, firstAudioMS: flow.firstAudioMS,
                peakDBFS: flow.peakDBFS, audibleFraction: flow.audibleFraction, partials: flow.partials, transcripts: flow.transcripts,
                textLatencyMeanMS: flow.textLatencyMeanMS, textLatencyMaxMS: flow.textLatencyMaxMS, backlogMaxMS: recognition?.backlogMaxMS,
                readyMS: recognition?.readyMS, finalLagMeanMS: recognition?.finalLagMeanMS, finalLagMaxMS: recognition?.finalLagMaxMS)
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
        queue.sync {
            if stage == .listeningStart { captureID = UUID() }
            let event = Event(time: Date(), stage: stage, code: code, launchID: launchID,
                              captureID: captureID, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                              pid: ProcessInfo.processInfo.processIdentifier, uptime: ProcessInfo.processInfo.systemUptime, details: details)
            try? append(event, to: url)
        }
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
        guard let d = event.details, d.audioVerdict != nil || d.failure != nil || d.readyMS != nil else { return line }
        var fields: [String] = []
        if let v = d.speaker { fields.append("speaker=\(v)") }
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
