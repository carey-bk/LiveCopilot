import XCTest
import AVFoundation
import Combine
@testable import LiveCopilot

/// Opt-in, real installed ASR/Laya/BGE with synthetic public fixtures only.
/// The controlled SSE transport isolates orchestration latency from WAN/model variance.
private struct BenchmarkSSE: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, Int) { throw CancellationError() }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try await Task.sleep(nanoseconds: 120_000_000)
                for content in ["## Suggested answer\n", "Method B takes 42 milliseconds.", "\n## Evidence & notes\nMeasured latency: 42 ms [S1]."] {
                    let data = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": content]]]])
                    continuation.yield("data: " + String(decoding: data, as: UTF8.self)); continuation.yield("")
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                continuation.yield("data: [DONE]"); continuation.yield(""); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reproduces the previous lazy-load path without changing retrieval or inference.
private struct LazyBenchmarkEmbedding: EmbeddingProvider {
    let local: LocalEmbeddingProvider
    var model: String { local.model }
    func embed(_ texts: [String]) async throws -> [[Float]] { try await local.embed(texts) }
}

final class PipelineBenchmarks: XCTestCase {
    @MainActor func testRetrievalColdVersusPrepared() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_PIPELINE_BENCHMARK"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in real local retrieval benchmark") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCopilot")
        let model = LocalModelKind.embedding.location(in: dataRoot.appendingPathComponent("Models"))
        let corpus = root.appendingPathComponent("retrieval-fixture.txt")
        try "Synthetic benchmark: Method B has a measured latency of 42 milliseconds. The sample size is 128. 方法B的延迟是42毫秒，样本量128。".write(to: corpus, atomically: true, encoding: .utf8)
        let knowledge = root.appendingPathComponent("retrieval-knowledge-" + UUID().uuidString)
        let seed = LocalEmbeddingProvider(directory: model)
        let index = try KnowledgeIndex(directory: knowledge)
        _ = try await index.importDocument(corpus, provider: seed)
        seed.close()
        var rows: [[String: Any]] = []
        var expectedSources: [String]?
        for prepared in [false, true] {
            let suite = "LiveCopilot-Retrieval-Benchmark-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let local = LocalEmbeddingProvider(directory: model)
            let provider: any EmbeddingProvider = prepared ? local : LazyBenchmarkEmbedding(local: local)
            let reasoner = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: URL(string: "https://fixture.invalid/chat/completions")!, transport: BenchmarkSSE())
            let app = AppCoordinator(mock: true, layaPredictor: { _, _ in 0.95 }, mockReasoning: reasoner,
                                     emitMockConversation: false, mockDefaults: defaults, mockEmbedding: provider,
                                     mockKnowledgeDirectory: knowledge)
            app.settings.embeddingService = .local
            app.settings.listeningService = .apple; app.settings.automaticSuggestions = true
            let preparationStart = ProcessInfo.processInfo.systemUptime
            await app.refreshKnowledge()
            if prepared {
                let deadline = preparationStart + 60
                while !local.isPrepared && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertTrue(local.isPrepared)
            }
            let preparationMS = Int((ProcessInfo.processInfo.systemUptime - preparationStart) * 1000)
            await app.start()
            for run in 0..<3 {
                let question = "What is the latency of method B?"
                if run == 0 {
                    app.receiveMockEvent(.transcript(.init(id: suite, speaker: .them, text: question, startMS: 0, endMS: 1000, receivedAt: Date())), speaker: .them)
                } else { app.askText(question) }
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                while (app.suggestion.text.isEmpty || app.suggestion.isLoading) && app.suggestion.error == nil && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertNil(app.suggestion.error)
                XCTAssertFalse(app.suggestion.text.isEmpty)
                XCTAssertFalse(app.suggestion.sources.isEmpty)
                let ids = app.suggestion.sources.map(\.id)
                if let expectedSources { XCTAssertEqual(ids, expectedSources) } else { expectedSources = ids }
                let trace = try XCTUnwrap(app.suggestion.trace)
                let dispatched = try XCTUnwrap(trace.milliseconds(.analysisDispatched))
                let request = try XCTUnwrap(trace.milliseconds(.modelRequest))
                let first = try XCTUnwrap(trace.milliseconds(.firstToken))
                rows.append(["mode": prepared ? "background_prepared" : "previous_lazy_load", "run": run,
                             "origin": run == 0 ? "Jev (controlled classifier)" : "manual",
                             "preparation_before_question_ms": preparationMS,
                             "dispatch_to_first_text_ms": first - dispatched,
                             "rag_ms": app.suggestion.retrievalMS, "model_to_first_text_ms": first - request,
                             "trace_ms": Dictionary(uniqueKeysWithValues: trace.times.keys.map { ($0.rawValue, trace.milliseconds($0)!) }),
                             "sources_unchanged": ids == expectedSources])
            }
            await app.shutdown(); local.close(); defaults.removePersistentDomain(forName: suite)
        }
        let result: [String: Any] = ["transport": "controlled SSE 120ms + 3x40ms; no remote API", "embedding": "real installed local BGE-M3", "runs": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("retrieval-preparation.json"))
    }

    @MainActor func testInstalledAudioPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["LIVECOPILOT_PIPELINE_BENCHMARK"], !output.isEmpty, !output.hasPrefix("$(") else {
            throw XCTSkip("Opt-in real local audio benchmark")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("Apple ASR requires macOS 26") }
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCopilot")
        let runtime = LayaRuntimeManager(root: dataRoot.appendingPathComponent("Laya"))
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await runtime.prepareAndWait()
        let loadMS = Int((ProcessInfo.processInfo.systemUptime - loadStart) * 1000)
        let embedding = LocalEmbeddingProvider(directory: LocalModelKind.embedding.location(in: dataRoot.appendingPathComponent("Models")))
        let corpus = root.appendingPathComponent("synthetic-benchmark.txt")
        try "Synthetic benchmark: Method B has a measured latency of 42 milliseconds. The sample size is 128. 方法B的延迟是42毫秒，样本量128。".write(to: corpus, atomically: true, encoding: .utf8)
        let knowledge = root.appendingPathComponent("knowledge-" + UUID().uuidString)
        let index = try KnowledgeIndex(directory: knowledge)
        _ = try await index.importDocument(corpus, provider: embedding)
        var relevance: [[String: Any]] = []
        for (question, shouldHit) in [
            ("方法B的延迟和样本量是多少？", true),
            ("What latency and sample size were measured for method B?", true),
            ("请解释一下 quantum entanglement 是什么", false),
            ("How do I bake sourdough bread?", false),
            ("Can you explain 方法B的 latency?", true)
        ] {
            let query = RetrievalQuery.formulate(question: question, context: "之前我们讨论过方法B的实验结果。", previousQuestion: "方法B的样本量是多少？")
            let vector = try await embedding.embed([query.semantic])[0]
            let hits = try await index.retrieve(query: query, vector: vector, model: embedding.model, limit: 6)
            relevance.append(["question": question, "expected_hit": shouldHit, "hits": hits.map { ["cosine": $0.semanticSimilarity ?? -1, "coverage": $0.lexicalCoverage, "relevance": $0.relevance] }])
            XCTAssertEqual(!hits.isEmpty, shouldHit, question)
        }
        try JSONSerialization.data(withJSONObject: relevance, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("relevance.json"))
        var results: [[String: Any]] = []
        for (name, voice, language, question) in [
            ("zh", "Tingting", AppleSpeechLanguage.chinese, "请问方法B的延迟是多少毫秒？"),
            ("en", "Samantha", .english, "Could you explain the latency of method B?"),
        ] {
            guard await AppleSpeechSupport.installed(language) else { throw XCTSkip("Required Apple ASR language is not installed") }
            let audio = root.appendingPathComponent(name + ".aiff")
            let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", audio.path, question]
            try say.run(); say.waitUntilExit(); XCTAssertEqual(say.terminationStatus, 0)
            let file = try AVAudioFile(forReading: audio)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let converter = PCMConverter(); converter.configure(sampleRate: 16000)
            var pcm = Data(repeating: 0, count: 16000); pcm.append(converter.convert(buffer)!)
            // Exclude trailing TTS silence: audio-end clock is the last sample above -46 dBFS.
            var lastVoicedFrame = 0
            pcm.withUnsafeBytes { bytes in
                for i in 0..<(bytes.count / 2) {
                    if abs(Int(bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) > 164 { lastVoicedFrame = i }
                }
            }
            pcm.append(Data(repeating: 0, count: 32000 * 3))
            for run in 0..<3 {
                let suite = "LiveCopilot-Benchmark-" + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                let reasoner = ChatCompletionsProvider(key: "fixture-only", model: "fixture", endpoint: URL(string: "https://fixture.invalid/chat/completions")!, transport: BenchmarkSSE())
                var predictions: [[String: Any]] = [], events: [[String: Any]] = []
                var origin = ProcessInfo.processInfo.systemUptime
                func ms() -> Int { Int((ProcessInfo.processInfo.systemUptime - origin) * 1000) }
                let app = AppCoordinator(mock: true, layaPredictor: { text, context in
                    let start = ms()
                    let score = try await runtime.predict(text: text, context: context)
                    predictions.append(["start_ms": start, "end_ms": ms(), "score": score, "text": text])
                    return score
                }, mockReasoning: reasoner, emitMockConversation: false, mockDefaults: defaults,
                                         mockEmbedding: embedding, mockKnowledgeDirectory: knowledge)
                app.settings.listeningService = .apple; app.settings.automaticSuggestions = true
                app.settings.embeddingService = .local
                await app.start()
                var requested: Int?, first: Int?, completed: Int?, failure: String?
                var tokens = Set<AnyCancellable>()
                app.suggestion.$isLoading.dropFirst().sink { loading in
                    if loading { requested = ms() }
                    else if requested != nil { completed = ms() }
                }.store(in: &tokens)
                app.suggestion.$text.dropFirst().sink { if !$0.isEmpty && first == nil { first = ms() } }.store(in: &tokens)
                let speech = AppleLiveProvider(speaker: .them, language: language)
                try await speech.prepare()
                speech.onEvent = { event in
                    switch event {
                    case .speechActivity(let active): events.append(["stage": active ? "speech_start" : "speech_end", "ms": ms()])
                    case .transcript(let fragment): events.append(["stage": "asr_final", "ms": ms(), "text": fragment.text])
                    case .partialTranscript(let text): if !text.isEmpty { events.append(["stage": "asr_partial", "ms": ms(), "text": text]) }
                    case .failed(let error): failure = error
                    default: break
                    }
                    app.receiveMockEvent(event, speaker: .them)
                }
                origin = ProcessInfo.processInfo.systemUptime
                speech.connect(context: "")
                // Exactly real-time 100 ms PCM packets; no physical microphone or capture required.
                for offset in stride(from: 0, to: pcm.count, by: 3200) {
                    speech.sendAudio(pcm.subdata(in: offset..<min(pcm.count, offset + 3200)))
                    let remaining = origin + Double(offset + 3200) / 32000 - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 12
                while completed == nil && failure == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                let row: [String: Any] = ["case": name, "run": run, "speech_end_ms": lastVoicedFrame / 16,
                    "analysis_start_ms": requested ?? -1, "first_text_ms": first ?? -1, "complete_ms": completed ?? -1,
                    "rag_ms": app.suggestion.retrievalMS, "events": events, "predictions": predictions,
                    "trace_ms": app.suggestion.trace.map { trace in Dictionary(uniqueKeysWithValues: trace.times.keys.compactMap { stage in trace.milliseconds(stage).map { (stage.rawValue, $0) } }) } ?? [:],
                    "question": app.suggestion.question, "answer": app.suggestion.text, "error": failure ?? app.suggestion.error ?? ""]
                results.append(row)
                try JSONSerialization.data(withJSONObject: ["laya_load_ms": loadMS, "transport": "controlled SSE 120ms + 3x40ms", "runs": results], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
                XCTAssertNotNil(completed, "No completed answer for \(name): \(failure ?? app.suggestion.error ?? "no trigger")")
                XCTAssertFalse(app.suggestion.text.isEmpty)
                await speech.disconnect(); await app.shutdown(); defaults.removePersistentDomain(forName: suite)
            }
        }
        embedding.close(); await runtime.shutdown()
    }
    @MainActor func testParaformerRequestPipeline() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_PIPELINE_BENCHMARK"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in local Paraformer/Laya regression") }
        let root = URL(fileURLWithPath: output).appendingPathComponent("paraformer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCopilot")
        let runtime = LayaRuntimeManager(root: dataRoot.appendingPathComponent("Laya"))
        try await runtime.prepareAndWait()
        let suite = "LiveCopilot-Paraformer-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let reasoner = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: URL(string: "https://fixture.invalid/chat/completions")!, transport: BenchmarkSSE())
        var scores: [Double] = []
        let app = AppCoordinator(mock: true, layaPredictor: { text, context in
            let score = try await runtime.predict(text: text, context: context); scores.append(score); return score
        }, mockReasoning: reasoner, emitMockConversation: false, mockDefaults: defaults,
                                 mockKnowledgeDirectory: root.appendingPathComponent("empty-knowledge"))
        app.settings.listeningService = .paraformer; app.settings.automaticSuggestions = true
        await app.start()
        let speech = LocalLiveProvider(directory: LocalModelKind.streamingSpeech.location(in: dataRoot.appendingPathComponent("Models")), speaker: .them)
        try await speech.prepare()
        var finals: [String] = [], failure: String?, starts = 0
        var tokens = Set<AnyCancellable>()
        app.suggestion.$isLoading.dropFirst().sink { if $0 { starts += 1 } }.store(in: &tokens)
        speech.onEvent = { event in
            if case .transcript(let fragment) = event { finals.append(fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if case .failed(let error) = event { failure = error }
            app.receiveMockEvent(event, speaker: .them)
        }
        speech.connect(context: "")
        var results: [[String: Any]] = []
        for (index, item) in [
            ("日本的首都是哪里", true), ("日本的首都是哪里", false),
            ("告诉我你的经历", true), ("跟我说你的学历情况", true), ("讲讲冒泡排序", true),
            ("讲讲项目中的困难", true), ("你在项目中遇到的最大困难是什么", true),
            ("今天的会议到这里结束", false), ("我不知道日本的首都是哪里", false)
        ].enumerated() {
            let (question, shouldTrigger) = item
            let audio = root.appendingPathComponent("case-\(index).aiff")
            let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Tingting", "-r", "210", "-o", audio.path, question]
            try say.run(); say.waitUntilExit(); XCTAssertEqual(say.terminationStatus, 0)
            let file = try AVAudioFile(forReading: audio)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let converter = PCMConverter(); converter.configure(sampleRate: 16000)
            var pcm = Data(repeating: 0, count: 16000); pcm.append(converter.convert(buffer)!)
            pcm.append(Data(repeating: 0, count: 64000))
            let startCount = starts, finalCount = finals.count, scoreCount = scores.count
            let origin = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: pcm.count, by: 3200) {
                speech.sendAudio(pcm.subdata(in: offset..<min(pcm.count, offset + 3200)))
                let remaining = origin + Double(offset + 3200) / 32000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertNil(failure)
            XCTAssertEqual(starts - startCount, shouldTrigger ? 1 : 0, question)
            let recognized = Array(finals.dropFirst(finalCount)).joined()
            XCTAssertEqual(recognized, question, "Actual installed Paraformer must preserve the complete utterance")
            if shouldTrigger {
                XCTAssertEqual(app.suggestion.question, question)
                XCTAssertFalse(app.suggestion.text.isEmpty)
                XCTAssertEqual(app.settings.knowledgeMode, .hybrid); XCTAssertEqual(app.settings.answerLanguage, .auto)
            }
            results.append(["question": question, "recognized": recognized, "expected_trigger": shouldTrigger,
                            "analysis_requests": starts - startCount, "laya_scores": Array(scores.dropFirst(scoreCount)),
                            "trace_ms": shouldTrigger ? app.suggestion.trace.map { trace in Dictionary(uniqueKeysWithValues: trace.times.keys.map { ($0.rawValue, trace.milliseconds($0)!) }) } ?? [:] : [:]])
            try JSONSerialization.data(withJSONObject: ["transport": "controlled SSE; no paid API", "runs": results], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
        }
        await speech.disconnect(); await app.shutdown(); await runtime.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }

}
