import Foundation

enum AppPaths {
    static var isMock: Bool { ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LIVECOPILOT_MOCK"] == "1" }
    static func dataDirectory(mock: Bool = isMock) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(mock ? "LiveCopilot/Mock" : "LiveCopilot", isDirectory: true)
    }
}
