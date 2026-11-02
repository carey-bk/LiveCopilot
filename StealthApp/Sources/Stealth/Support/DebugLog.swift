import Foundation

/// Dead-simple file logger so we can diagnose the running app from the terminal.
/// Writes to ~/Library/Logs/LiveCopilot/livecopilot.log. Cheap, append-only, serialized, size-bounded.
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LiveCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("livecopilot.log")
    }()

    private static let queue = DispatchQueue(label: "com.livecopilot.debuglog")
    /// Bounded: at this size the file becomes `livecopilot.1.log`, replacing the older copy.
    static let maximumBytes = 2_000_000
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ message: String) {
        queue.async {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            append(data, to: url)
        }
    }

    static func append(_ data: Data, to url: URL, maximumBytes: Int = maximumBytes) {
        // Not `URL.resourceValues`: it caches on the long-lived URL, so the size would never grow.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumBytes {
            let previous = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
