import Foundation

/// Which signed update feed to read: GitHub (the Info.plist feed) by default, or the Hong Kong
/// mirror when GitHub cannot be reached or a check or download from it failed. Both feeds carry
/// the same signed items; only the download URLs differ, so Sparkle's signature checks are unchanged.
final class UpdateSource {
    static let mirrorFeed = "https://livecopilot-downloads-hk.oss-cn-hongkong.aliyuncs.com/updates/appcast.xml"
    static let mirrorDuration: TimeInterval = 24 * 3600
    private let defaults: UserDefaults
    private let key = "livecopilot.update-mirror-until"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func usesMirror(now: Date = Date()) -> Bool {
        guard let until = defaults.object(forKey: key) as? Date else { return false }
        return until > now && until.timeIntervalSince(now) <= Self.mirrorDuration
    }

    func preferMirror(now: Date = Date()) { defaults.set(now.addingTimeInterval(Self.mirrorDuration), forKey: key) }

    func reset() { defaults.removeObject(forKey: key) }

    /// Network-level failures worth retrying on the mirror; signature, archive and no-update
    /// results are not, because the mirror serves the same signed files.
    static func isNetworkFailure(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain { return true }
        if error.domain == "SUSparkleErrorDomain", [1002, 2001].contains(error.code) { return true }  // appcast, download
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.domain == NSURLErrorDomain }
        return false
    }

    /// True when the feed answers with a success status within `timeout` seconds.
    static func reachable(_ url: URL, timeout: TimeInterval = 5, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<400).contains(status)
    }
}
