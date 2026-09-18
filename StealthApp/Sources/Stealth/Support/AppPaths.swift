import Foundation

enum AppPaths {
    static var isDevelopment: Bool { Bundle.main.bundleIdentifier == "com.livecopilot.development" }
    static var isMock: Bool { ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LIVECOPILOT_MOCK"] == "1" }
    static func dataDirectory(mock: Bool = isMock) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(mock ? "LiveCopilot/Mock" : isDevelopment ? "LiveCopilot/Development" : "LiveCopilot", isDirectory: true)
    }
    // Models are a shared download cache; development documents/history are isolated.
    static func modelsDirectory(mock: Bool = isMock) -> URL {
        if mock { return dataDirectory(mock: true).appendingPathComponent("Models") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LiveCopilot/Models", isDirectory: true)
    }
}
