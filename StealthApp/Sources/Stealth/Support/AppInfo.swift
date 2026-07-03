import Foundation

/// Reads the app's version + build stamp from the bundle's Info.plist.
/// `run.sh` rewrites CFBundleVersion to a fresh `YYYYMMDD.HHMM` value on every build,
/// so this is a reliable "is the running app my latest code?" indicator.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// e.g. "v0.1.0 (20260630.2231)"
    static var display: String {
        "v\(version) (\(build))"
    }
}
