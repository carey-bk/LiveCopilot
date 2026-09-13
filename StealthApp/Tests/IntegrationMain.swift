import Foundation
import AVFoundation

/// Opt-in, synthetic-data integration. Never prints credentials, authorization headers or request bodies.
@main struct IntegrationMain {
    @MainActor static func main() async {
        let keyTimeout = DispatchWorkItem {
            print("INTEGRATION FAILED: Keychain access did not complete within 15 seconds. Unlock the Mac/login Keychain and authorize the installed app; no API request was sent.")
            exit(75)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: keyTimeout)
        do {
            guard let key = try integrationCredential(), !key.isEmpty else {
                throw CopilotError.message("No credential available. Add LiveCopilot-OpenAI/current-user in Keychain or export OPENAI_API_KEY in this shell.")
            }
            keyTimeout.cancel()
            print("PASS credential available (value never displayed)")
            if CommandLine.arguments.contains("--keychain-check") { return }
            let settings = AppSettings.load()
            let embedding = OpenAIEmbeddingProvider(key: key, model: settings.embeddingModel)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-api-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("synthetic-test.txt")
            try "Synthetic benchmark: Method B latency is 42 ms. Experiment A uses 128 samples. These are test fixtures, not real research.".write(to: file, atomically: true, encoding: .utf8)
            let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
            _ = try await index.importDocument(file, provider: embedding)
            print("PASS real OpenAI embeddings and local index")
            let query = RetrievalQuery.formulate(question: "What is the latency of method B in the synthetic benchmark? Cite the provided source.", context: "")
            let vector = try await embedding.embed([query.semantic])[0]
            let sources = try await index.retrieve(query: query, vector: vector, model: embedding.model, limit: 6)
            guard !sources.isEmpty else { throw CopilotError.message("Integration retrieval returned no sources.") }
            let request = AnswerRequest(query: query, conversation: "", scenario: .meeting, sources: sources)
            var text = "", first = true
            let start = Date()
            for try await delta in OpenAIReasoningProvider(key: key, model: settings.reasoningModel, effort: settings.reasoningEffort).stream(request) {
                if first { print("PASS first reasoning text at \(Int(Date().timeIntervalSince(start) * 1000)) ms"); first = false }
                text += delta
            }
            guard text.contains("42"), !SuggestionParser.citedIndices(text, sourceCount: sources.count).isEmpty else {
                throw CopilotError.message("Reasoning completed but did not preserve the synthetic fact/source; inspect the model configuration.")
            }
            print("PASS real Responses answer with factual evidence and source citation")
            if CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--live-question") {
                try await verifyLive(key: key, settings: settings)
            }
        } catch {
            print("INTEGRATION FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    /// The system security CLI already has access to the user's item; the separately
    /// compiled integration helper may not. Capture stdout in memory, never inherit it.
    static func integrationCredential() throws -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", KeychainStore.service, "-a", KeychainStore.account, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0, let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }
    @MainActor static func verifyLive(key: String, settings: AppSettings) async throws {
        let live = OpenAILiveProvider(key: key, model: settings.liveModel, speaker: .them, scenario: .meeting)
        var ready = false, failure: String?, delegated = false, transcript = "", closed = false
        live.onEvent = { event in
            switch event {
            case .ready: ready = true
            case .failed(let message): failure = message
            case .transcript(let fragment): transcript += fragment.text
            case .delegation: delegated = true
            case .closed(let finalized): closed = finalized
            default: break
            }
        }
        live.connect(context: "This is an automated synthetic audio check. Delegate the benchmark question when complete.")
        let deadline = Date().addingTimeInterval(25)
        while !ready && failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard ready else { await live.disconnect(); throw CopilotError.message(failure ?? "Live did not start before timeout.") }
        print("PASS official GPT-Live session.started")
        if CommandLine.arguments.contains("--live-question") {
            guard let pathIndex = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.indices.contains(pathIndex + 1) else {
                await live.disconnect(); throw CopilotError.message("Pass --audio with a synthetic test audio file.")
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[pathIndex + 1]))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                await live.disconnect(); throw CopilotError.message("Cannot decode synthetic audio.")
            }
            try file.read(into: buffer)
            guard let data = PCMConverter().convert(buffer) else { await live.disconnect(); throw CopilotError.message("Cannot convert synthetic audio.") }
            for start in stride(from: 0, to: data.count, by: 4800) {
                live.sendAudio(data.subdata(in: start..<min(start + 4800, data.count)))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for _ in 0..<120 {
                live.sendAudio(Data(repeating: 0, count: 4800))
                try await Task.sleep(nanoseconds: 100_000_000)
                if delegated && !transcript.isEmpty { break }
            }
        } else {
            for _ in 0..<10 { live.sendAudio(Data(repeating: 0, count: 4800)); try await Task.sleep(nanoseconds: 100_000_000) }
        }
        await live.disconnect()
        guard closed else { throw CopilotError.message("Live disconnected without session.closed; final duration unconfirmed.") }
        print("PASS official Live graceful close with final usage event")
        if CommandLine.arguments.contains("--live-question") {
            guard delegated, !transcript.isEmpty else { throw CopilotError.message("Live connected but synthetic question transcription/delegation was not observed.") }
            print("PASS synthetic speech transcription and semantic client delegation")
        }
    }
}
