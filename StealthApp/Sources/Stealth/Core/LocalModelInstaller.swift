import Foundation

enum LocalModelInstaller {
    typealias Downloader = @Sendable (ModelDownload, URL) async throws -> Void
    static func download(_ item: ModelDownload, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var resumeData: Data?
        var downloaded: (URL, URLResponse)?
        for attempt in 0..<3 {
            do {
                if let resumeData { downloaded = try await session.download(resumeFrom: resumeData) }
                else { downloaded = try await session.download(from: item.url) }
                break
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < 2 else { throw CopilotError.message("Model download failed. Check the network and retry.") }
                resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
            }
        }
        guard let (temporary, response) = downloaded else { throw CopilotError.message("Model download failed. Check the network and retry.") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CopilotError.message("Model download failed. Check the network and retry.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
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
        for item in kind == .speech ? [ModelDownload.senseVoice, .vad] : [.bge] {
            status("Downloading local model…")
            let destination = stage.appendingPathComponent(item.name)
            try await downloader(item, destination)
            status("Verifying local model…")
            try await Task.detached(priority: .utility) { try item.verify(destination) }.value
            try Task.checkCancellation()
            if item.name == ModelDownload.senseVoice.name {
                status("Installing local model…")
                try await Task.detached(priority: .utility) {
                    let extraction = Process()
                    extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    let folder = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
                    extraction.arguments = ["-xjf", destination.path, "-C", payload.path, "--strip-components", "1", folder + "/model.int8.onnx", folder + "/tokens.txt"]
                    extraction.standardOutput = FileHandle.nullDevice; extraction.standardError = FileHandle.nullDevice
                    try extraction.run(); extraction.waitUntilExit()
                    guard extraction.terminationStatus == 0 else { throw CopilotError.message("Local model installation failed. Retry the download.") }
                }.value
            } else { try fm.moveItem(at: destination, to: payload.appendingPathComponent(item.name)) }
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
