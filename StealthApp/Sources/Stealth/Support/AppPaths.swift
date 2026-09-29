import Foundation

enum AppPaths {
    static var isDevelopment: Bool { Bundle.main.bundleIdentifier == "com.livecopilot.development" }
    private static var isPreviewBundle: Bool { Bundle.main.object(forInfoDictionaryKey: "LiveCopilotOnboardingPreview") as? Bool == true }
    static var isMock: Bool { isPreviewBundle || ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LIVECOPILOT_MOCK"] == "1" }
    static var isOnboardingPreview: Bool {
        isMock && (isPreviewBundle || ProcessInfo.processInfo.arguments.contains("--onboarding-preview") || ProcessInfo.processInfo.environment["LIVECOPILOT_ONBOARDING_PREVIEW"] == "1")
    }
    static func dataDirectory(mock: Bool = isMock) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if mock && isOnboardingPreview {
            return base.appendingPathComponent("LiveCopilot/OnboardingPreview", isDirectory: true)
        }
        return base.appendingPathComponent(mock ? "LiveCopilot/Mock" : isDevelopment ? "LiveCopilot/Development" : "LiveCopilot", isDirectory: true)
    }
    // Models are a shared download cache; development documents/history are isolated.
    static func modelsDirectory(mock: Bool = isMock) -> URL {
        if mock { return dataDirectory(mock: true).appendingPathComponent("Models") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LiveCopilot/Models", isDirectory: true)
    }
}
