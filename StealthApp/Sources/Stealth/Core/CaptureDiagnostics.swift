import Foundation

/// Bounded structured journal. Never accepts free-form error messages, paths or captured content.
enum CaptureDiagnostics {
    enum Stage: String, Codable {
        case appLaunch, cleanExit, listeningStart, systemStart, systemReady, systemFailed, systemStopped
        case micPermission, micFormat, micTap, micEngine, micReady, micFailed, micStopped, micDeviceChanged
        case speechConnecting, speechReady, speechFailed, listeningStop, workerStart, workerExit, workerFailure
    }
    enum Failure: String, Codable {
        case unknown, embedding_context, inference_failed, timeout, runtime_missing, runtime_start
        case embedding_load, model_load_failed, process_ended
    }
    struct Details: Codable {
        var sampleRate: Double?; var channels: UInt32?; var echoCancellation: Bool?
        var permissionGranted: Bool?; var errorDomain: String?
        var listeningService: String?; var captureMode: String?; var automatic: Bool?
        var speaker: String?; var workerMode: String?; var workerPID: Int32?
        var terminationReason: Int?; var failure: Failure?
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
        // Do not record test hosts or synthetic fixture workers in production diagnostics.
        guard Bundle.main.bundleIdentifier == "com.livecopilot.app", ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
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
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }
    static func journal() -> Data { queue.sync { (try? JSONEncoder().encode(read(from: url))) ?? Data("[]".utf8) } }
    static func snapshot() -> String {
        queue.sync { read(from: url).suffix(20).map {
            "\(ISO8601DateFormatter().string(from: $0.time)) \($0.stage.rawValue)\($0.code.map { " code=\($0)" } ?? "")"
        }.joined(separator: "\n") }
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
