import Foundation

/// Public release identity. Build stamps are deliberately not accepted as release versions.
struct ReleaseVersion: Comparable, Codable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:-([0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*))?(?:\+[0-9A-Za-z.-]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: bare, range: NSRange(bare.startIndex..., in: bare)) else { return nil }
        func group(_ n: Int) -> String? { Range(match.range(at: n), in: bare).map { String(bare[$0]) } }
        guard let major = Int(group(1) ?? ""), let minor = Int(group(2) ?? ""),
              let patch = Int(group(3) ?? "0"), major < 10_000 else { return nil }
        self.major = major; self.minor = minor; self.patch = patch; prerelease = group(4)
    }
    /// Releases from 2.11 on are MAJOR.MINOR; older tags with a non-zero patch keep it.
    var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
    var display: String { "v" + description }
    var isStable: Bool { prerelease == nil }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        guard let l = lhs.prerelease else { return false }
        guard let r = rhs.prerelease else { return true }
        let a = l.split(separator: "."), b = r.split(separator: ".")
        for (x, y) in zip(a, b) where x != y {
            if let nx = Int(x), let ny = Int(y) { return nx < ny }
            if Int(x) != nil { return true }
            if Int(y) != nil { return false }
            return x < y
        }
        return a.count < b.count
    }
}

struct UpdateRelease: Codable, Equatable {
    let version: ReleaseVersion
    var notes: String
    let supportsInAppInstall: Bool
    var display: String { version.display }
    // Never execute or open an arbitrary URL from cached or remote notes.
    /// The website's download section: GitHub plus netdisk mirrors that work where GitHub does not.
    static let officialPage = URL(string: "https://carey-bk.github.io/LiveCopilot/#download")!
    static func plainNotes(_ html: String?) -> String {
        guard let html else { return "查看本次更新的功能改进与问题修复。" }
        let source = String(html.prefix(32_000))
        let text = source.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</(?:p|li|h[1-6])\s*>|<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(8_000))
    }
}
