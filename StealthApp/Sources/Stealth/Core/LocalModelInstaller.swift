import Foundation

enum LocalModelInstaller {
    typealias Downloader = @Sendable (ModelDownload, URL) async throws -> Void
    /// Ordered routes for one file: configured distribution → pinned mirrors → host mirrors → origin.
    /// Every route must pass the pinned SHA-256 before it is accepted, so a source that is
    /// unreachable, truncated or serving different bytes automatically falls through.
    static func candidateURLs(_ item: ModelDownload, distributionBase: URL? = ModelDistribution.baseURL) -> [URL] {
        var addresses: [URL] = []
        if let distributionBase {
            let address = item.ossKey.split(separator: "/").reduce(distributionBase) { $0.appendingPathComponent(String($1)) }
            addresses.append(address)
        }
        addresses.append(contentsOf: item.mirrors)
        addresses.append(contentsOf: hostMirrors(for: item.url))
        addresses.append(item.url)
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Mirrors reachable from a mainland connection without a proxy, measured on a direct
    /// home line. GitHub is the fragile one: `github.com` assets stalled at ~13 KB/s and a
    /// bare `codeload.github.com` fetch never delivered a byte, so both get accelerators.
    static func hostMirrors(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return [] }
        switch host {
        case "huggingface.co":
            guard var mirror = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
            mirror.host = "hf-mirror.com"
            return [mirror.url].compactMap { $0 }
        case "github.com" where url.path.contains("/releases/download/"):
            // Verified to serve this payload byte-for-byte: gh-proxy.com completed the 629 KB
            // Silero VAD in 0.9 s where the origin needed 45.5 s.
            var mirrors: [URL] = []
            if url.path.contains("/" + pythonReleaseRepository + "/releases/download/") {
                // The pinned CPython archive is ~5x faster from a university release mirror, and
                // the Laya bootstrap needs it before any mirror logic of its own exists.
                mirrors += universityMirrors(for: url)
            }
            return mirrors + prefixMirrors(releaseAccelerators, url)
        case "codeload.github.com":
            // Only this accelerator proxied a codeload source archive; the other two returned 403.
            return prefixMirrors(["hk.gh-proxy.com"], url)
        default:
            return []
        }
    }

    private static let releaseAccelerators = ["gh-proxy.com", "hk.gh-proxy.com", "ghproxy.net"]
    private static let universityReleaseMirrors = [
        "https://mirrors.ustc.edu.cn/github-release",
        "https://mirror.nju.edu.cn/github-release",
    ]
    private static let pythonReleaseRepository = "astral-sh/python-build-standalone"

    /// `github.com/<repo>/releases/download/<tail>` → `<mirror>/<repo>/<tail>`, which is the
    /// layout the university release mirrors use.
    private static func universityMirrors(for url: URL) -> [URL] {
        guard let marker = url.absoluteString.range(of: "/releases/download/") else { return [] }
        let tail = url.absoluteString[marker.upperBound...]
        let repository = pythonReleaseRepository
        return universityReleaseMirrors.compactMap { URL(string: $0 + "/" + repository + "/" + tail) }
    }

    private static func prefixMirrors(_ hosts: [String], _ url: URL) -> [URL] {
        hosts.compactMap { URL(string: "https://" + $0 + "/" + url.absoluteString) }
    }
    static func download(_ item: ModelDownload, to destination: URL,
                         progress: @escaping @Sendable (Double?, String) -> Void = { _, _ in }) async throws {
        let addresses = candidateURLs(item)
        for (index, address) in addresses.enumerated() {
            try Task.checkCancellation()
            let host = address.host ?? ""
            progress(0, item.name + " · " + host + " · 0.0 MB · 0.0 MB/s")
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
                        result = try await observer.run(session: session, address: address, resumeData: resumeData)
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
                progress(1, item.name + " · " + host + " · verified")
                return
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                progress(nil, item.name + " · " + host + " failed; trying next source")
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

final class ModelDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double?, String) -> Void
    private let lock = NSLock()
    private var pending: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var saved: (URL, URLResponse)?
    private var fileError: Error?
    private var previousTime = Date()
    private var previousBytes: Int64 = 0
    init(update: @escaping @Sendable (Double?, String) -> Void) { self.update = update }
    func run(session: URLSession, address: URL, resumeData: Data?) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                pending = continuation; saved = nil; fileError = nil
                previousTime = Date(); previousBytes = 0
                let download = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: address)
                task = download
                lock.unlock()
                download.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".download")
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: destination)
            saved = (destination, response)
        } catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = pending; pending = nil; self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        if let error = wasCancelled ? CancellationError() : (error ?? fileError) {
            if let saved { try? FileManager.default.removeItem(at: saved.0) }
            continuation?.resume(throwing: error)
        } else if let saved { continuation?.resume(returning: saved) }
        else { continuation?.resume(throwing: URLError(.unknown)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date(), elapsed = Date().timeIntervalSince(previousTime)
        guard elapsed >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        let speed = Double(max(0, totalBytesWritten - previousBytes)) / max(0.001, elapsed) / 1_000_000
        previousTime = now; previousBytes = totalBytesWritten
        let fraction = totalBytesExpectedToWrite > 0 ? min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) : nil
        let rate = speed >= 0.1 ? String(format: "%.2f MB/s", speed) : String(format: "%.0f KB/s", speed * 1_000)
        update(fraction, String(format: "%.1f MB · %@", Double(totalBytesWritten) / 1_000_000, rate))
    }
}
