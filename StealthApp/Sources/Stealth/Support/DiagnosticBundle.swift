import Foundation
import CryptoKit

/// Detailed reports are local-only, opt-in, and never passed to the GitHub URL builder.
enum DiagnosticBundle {
    struct Crash: Identifiable, Sendable {
        let id: String
        let data: Data
        let date: Date
        var preview: String { String(decoding: data.prefix(120_000), as: UTF8.self) }
    }
    struct Scan: Sendable { let crashes: [Crash]; let status: String }
    static func parse(_ data: Data) -> [String: Any]? {
        if let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["procName"] != nil { return value }
        guard let newline = data.firstIndex(of: 10) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data.suffix(from: data.index(after: newline)))) as? [String: Any]
    }
    static func belongsToApp(_ object: [String: Any]) -> Bool {
        guard let name = object["procName"] as? String else { return false }
        if ["LiveCopilot", "LiveCopilot Dev", "livecopilot-inference"].contains(name) { return true }
        // A Python crash is included only if its executable belongs to our private Laya runtime.
        if ["Python", "python", "python3"].contains(name), let path = object["procPath"] as? String {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCopilot/Laya").path + "/"
            return path.hasPrefix(root)
        }
        return false
    }
    static func scan(roots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
    ]) -> Scan {
        var candidates: [(URL, Date)] = []; var unavailable = 0; var skipped = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            for folder in [root, root.appendingPathComponent("Retired")] {
                guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { unavailable += 1; continue }
                for file in files where file.pathExtension == "ips" {
                    let name = file.lastPathComponent
                    guard ["LiveCopilot", "livecopilot-inference", "Python", "python"].contains(where: name.hasPrefix) else { continue }
                    guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                          values.isSymbolicLink != true, let size = values.fileSize, size <= 10_000_000 else { skipped += 1; continue }
                    candidates.append((file, values.contentModificationDate ?? .distantPast))
                }
            }
        }
        var crashes: [Crash] = []
        for (url, date) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(40) {
            guard let data = try? Data(contentsOf: url), data.count <= 10_000_000,
                  let object = parse(data), belongsToApp(object) else { skipped += 1; continue }
            crashes.append(Crash(id: "crash-\(crashes.count + 1).ips", data: data, date: date))
            if crashes.count == 5 { break }
        }
        return Scan(crashes: crashes, status: "Matched reports: \(crashes.count); unavailable folders (including optional Retired): \(unavailable); skipped/unreadable candidates: \(skipped). Most recent 5 matching reports only. Missing reports do not rule out a crash; macOS may generate them after a delay. Raw reports can belong to older builds.")
    }
    /// A macOS report about this app: crash (.ips), hang (.hang), spin (.spin) or resource (.diag).
    struct SystemReport: Identifiable, Sendable {
        let id: String
        let name: String
        let date: Date
        let data: Data
        var kind: String {
            switch (name as NSString).pathExtension {
            case "hang": return "hang"
            case "spin": return "spin"
            case "diag": return name.contains("cpu_resource") ? "cpu" : "resource"
            default: return "crash"
            }
        }
        var preview: String { String(decoding: data.prefix(120_000), as: UTF8.self) }
    }

    static let reportExtensions: Set<String> = ["ips", "hang", "spin", "diag"]

    /// Text reports (.hang/.spin/.diag) name the process in a "Process:" or "Command:" header line.
    static func textReportBelongsToApp(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(8192), as: UTF8.self)
        return head.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Process:") || trimmed.hasPrefix("Command:") else { return false }
            let value = trimmed.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            return ["LiveCopilot", "LiveCopilot Dev", "livecopilot-inference"].contains { value == $0 || value.hasPrefix($0 + " ") }
        }
    }

    /// Reports from this app modified within `window` of `date`, newest first, at most `limit`.
    static func systemReports(near date: Date, window: TimeInterval = 72 * 3600, limit: Int = 10, roots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
    ]) -> [SystemReport] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var candidates: [(URL, Date)] = []
        for root in roots {
            for folder in [root, root.appendingPathComponent("Retired")] {
                guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { continue }
                for file in files where reportExtensions.contains(file.pathExtension) {
                    guard ["LiveCopilot", "livecopilot-inference"].contains(where: file.lastPathComponent.hasPrefix),
                          let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                          values.isSymbolicLink != true, let size = values.fileSize, size <= 10_000_000,
                          let modified = values.contentModificationDate, abs(modified.timeIntervalSince(date)) <= window else { continue }
                    candidates.append((file, modified))
                }
            }
        }
        var reports: [SystemReport] = []
        var names = Set<String>()
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard !names.contains(url.lastPathComponent), let data = try? Data(contentsOf: url) else { continue }
            let belongs = url.pathExtension == "ips" ? (parse(data).map(belongsToApp) ?? false) : textReportBelongsToApp(data)
            guard belongs else { continue }
            names.insert(url.lastPathComponent)
            reports.append(SystemReport(id: url.lastPathComponent, name: url.lastPathComponent, date: modified, data: data))
            if reports.count == limit { break }
        }
        return reports
    }

    static let readme = """
    LiveCopilot feedback bundle, created on the user's Mac after they reviewed its contents.
    It contains no audio, transcript, answers, documents or credentials. system-reports/ holds
    macOS crash, hang and resource reports for LiveCopilot, which can include usernames and paths.
    stalls/ holds main-thread stacks sampled while the app was unresponsive. Match image UUIDs
    against the exact build before symbolicating offsets. Worker exits may be intentional
    cancellation; correlate PID, stage and time.

    """

    /// Writes `files` (relative path → bytes) plus README.txt and SHA256.json into a ZIP at `target`.
    static func write(to target: URL, files input: [String: Data]) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LiveCopilot-feedback-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent(target.deletingPathExtension().lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files = input
        files["README.txt"] = Data(readme.utf8)
        var hashes: [String: String] = [:]
        for (name, bytes) in files {
            // Relative names only; never write outside the bundle folder.
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { continue }
            let file = folder.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            hashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        try JSONSerialization.data(withJSONObject: hashes, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("SHA256.json"))
        let zip = work.appendingPathComponent("report.zip")
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Atomic destination replacement; no partial archive left after a failed export.
        try Data(contentsOf: zip).write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
