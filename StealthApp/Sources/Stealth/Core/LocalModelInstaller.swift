import Foundation

enum LocalModelInstaller {
    typealias Downloader = @Sendable (ModelDownload, URL) async throws -> Void
    static func download(_ item: ModelDownload, to destination: URL,
                         progress: @escaping @Sendable (Double?, String) -> Void = { _, _ in }) async throws {
        var addresses = [item.url]
        if item.url.host == "huggingface.co",
           var mirror = URLComponents(url: item.url, resolvingAgainstBaseURL: false) {
            mirror.host = "hf-mirror.com"
            if let url = mirror.url { addresses.insert(url, at: 0) }
        }
        for (index, address) in addresses.enumerated() {
            try Task.checkCancellation()
            let host = address.host ?? ""
            progress(nil, host)
            let observer = ModelDownloadObserver { value, rate in progress(value, item.name + " · " + host + " · " + rate) }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: config, delegate: observer, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                var resumeData: Data?
                var result: (URL, URLResponse)?
                for attempt in 0..<2 {
                    do {
                        if let data = resumeData { result = try await session.download(resumeFrom: data) }
                        else { result = try await session.download(from: address) }
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard attempt == 0, (error as? URLError)?.code != .cancelled else { throw error }
                        resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
                    }
                }
                guard let (temporary, response) = result else { throw URLError(.cannotLoadFromNetwork) }
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw CopilotError.message("HTTP download failed: " + host)
                }
                // Validate each source before accepting it, including mirror responses.
                try await Task.detached { try item.verify(temporary) }.value
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: destination)
                return
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if index == addresses.count - 1 {
                    throw CopilotError.message("Download failed: " + item.name + " (" + host + "). " + error.localizedDescription)
                }
            }
        }
    }
    static func install(_ kind: LocalModelKind, root: URL,
                        downloader: @escaping Downloader = { item, destination in try await download(item, to: destination) },
                        status: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".install-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        for item in kind.downloads {
            status("Downloading local model…")
            let destination = stage.appendingPathComponent(item.name)
            try await downloader(item, destination)
            status("Verifying local model…")
            try await Task.detached(priority: .utility) { try item.verify(destination) }.value
            try Task.checkCancellation()
            try fm.moveItem(at: destination, to: payload.appendingPathComponent(item.installedName ?? item.name))
        }
        try Task.checkCancellation()
        var sizes: [String: Int64] = [:]
        for name in kind.files {
            let attributes = try fm.attributesOfItem(atPath: payload.appendingPathComponent(name).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw CopilotError.message("Local model installation failed. Retry the download.")
            }
            sizes[name] = size.int64Value
        }
        try JSONEncoder().encode(sizes).write(to: payload.appendingPathComponent("installed.json"), options: .atomic)
        try commit(payload, to: kind.location(in: root))
    }
    static func commit(_ payload: URL, to destination: URL) throws {
        let fm = FileManager.default, previous = destination.deletingLastPathComponent().appendingPathComponent(".previous-" + UUID().uuidString)
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: previous) }
        do { try fm.moveItem(at: payload, to: destination) }
        catch { if exists { try? fm.moveItem(at: previous, to: destination) }; throw error }
        if exists { try? fm.removeItem(at: previous) }
    }
}

private final class ModelDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double?, String) -> Void
    private var previousTime = Date()
    private var previousBytes: Int64 = 0
    init(update: @escaping @Sendable (Double?, String) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let elapsed = Date().timeIntervalSince(previousTime)
        guard elapsed >= 0.3 else { return }
        let speed = Double(totalBytesWritten - previousBytes) / elapsed / 1_000_000
        previousTime = Date(); previousBytes = totalBytesWritten
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        update(fraction, String(format: "%.1f MB · %.1f MB/s", Double(totalBytesWritten) / 1_000_000, speed))
    }
}
