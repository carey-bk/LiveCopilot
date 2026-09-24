import Foundation
import AVFoundation

/// Opt-in, synthetic-data integration. Never prints credentials, authorization headers or request bodies.
@main struct IntegrationMain {
    @MainActor static func main() async {
        do {
            guard let key = try integrationCredential(), !key.isEmpty else {
                throw CopilotError.message("No credential available. Add LiveCopilot-OpenAI/current-user in Keychain or export OPENAI_API_KEY in this shell.")
            }
            print("PASS credential available (value never displayed)")
            if CommandLine.arguments.contains("--keychain-check") { return }
            var settings = AppSettings.load()
            if let index = CommandLine.arguments.firstIndex(of: "--live-language") {
                guard CommandLine.arguments.indices.contains(index + 1),
                      let language = LiveSpeechLanguage(rawValue: CommandLine.arguments[index + 1]) else {
                    throw CopilotError.message("Use --live-language chinese, english or mixed.")
                }
                settings.liveSpeechLanguage = language
            }
            if CommandLine.arguments.contains("--live-only") {
                try await verifyLive(key: key, settings: settings)
                return
            }
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
        // Allow time for the user's system authorization prompt, then terminate
        // the child too. Exiting only the parent leaves an orphaned prompt.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0, let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        if process.terminationReason == .uncaughtSignal {
            throw CopilotError.message("Keychain read was cancelled or timed out. Allow access locally and retry; no API request was sent.")
        }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }
    @MainActor static func verifyLive(key: String, settings: AppSettings) async throws {
        var audioURL: URL?
        if CommandLine.arguments.contains("--live-question") {
            guard let i = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.indices.contains(i + 1) else {
                throw CopilotError.message("Pass --audio with a synthetic test audio file.")
            }
            audioURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        try await LiveSmokeCheck.run(key: key, settings: settings, audioURL: audioURL) { print($0) }
    }
}
