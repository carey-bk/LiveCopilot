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
    static func write(to target: URL, report: String, journal: Data, notes: String, crashes: [Crash]) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LiveCopilot-support-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent("LiveCopilot-support")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [String: Data] = ["summary.txt": Data(report.utf8), "events.json": journal,
            "reproduction.txt": Data(String(notes.prefix(12_000)).utf8),
            "README.txt": Data("Private diagnostic bundle. Raw .ips files can contain usernames, paths and process information. Review before sharing privately. No audio, transcript, documents, credentials or general debug log were deliberately collected. A missing clean-exit marker is not proof of a crash. Match crash image UUIDs against the exact build's dSYM before symbolication. Worker exits may be intentional cancellation; correlate PID, stage and time.\n".utf8)]
        for (index, crash) in crashes.prefix(5).enumerated() { files["crash-\(index + 1).ips"] = crash.data }
        var hashes: [String: String] = [:]
        for (name, bytes) in files {
            let file = folder.appendingPathComponent(name)
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
