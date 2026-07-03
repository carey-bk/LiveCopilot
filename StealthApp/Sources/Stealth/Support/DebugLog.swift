import Foundation

/// Dead-simple file logger so we can diagnose the running app from the terminal.
/// Writes to ~/Library/Logs/Stealth/stealth.log. Cheap, append-only, thread-safe enough.
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Stealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stealth.log")
    }()

    private static let queue = DispatchQueue(label: "com.stealth.debuglog")

    static func log(_ message: String) {
        queue.async {
            let line = "[\(timestamp())] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
