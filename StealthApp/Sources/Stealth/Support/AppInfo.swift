import Foundation

/// Reads the app's version + build stamp from the bundle's Info.plist.
/// Build commands supply CURRENT_PROJECT_VERSION; distribution signing stamps it again.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// e.g. "v0.1.0 (20260630.2231)"
    static var display: String {
        "v\(version)\(AppPaths.isDevelopment ? " Dev" : "") (\(build))"
    }
}
