import XCTest
import AVFoundation
@testable import LiveCopilot

/// Explicit opt-in: bounded requests with synthetic questions/documents only.
/// Read-only, noninteractive Keychain lookup; never migrate, modify or print a key.
final class ConfiguredAnalysisChecks: XCTestCase {
    @MainActor func testConfiguredAnalysisLanguagesAndEvidence() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_REAL_ANALYSIS"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in billable provider acceptance") }
        let settings = AppSettings.load(defaults: UserDefaults(suiteName: "com.livecopilot.app")!)
        let reference = try settings.analysisCredentialReference()
        let key: String?
        do {
            key = try KeychainStore.read(service: CredentialVault.service, account: CredentialVault.account(for: reference), interactive: ProcessInfo.processInfo.environment["LIVECOPILOT_KEYCHAIN_INTERACTIVE"] == "1")
        } catch { throw XCTSkip("Configured key requires user authorization in macOS; no interactive prompt requested") }
        guard let key else { throw XCTSkip("No accessible saved analysis credential") }
        let provider = try ReasoningProviderFactory.make(settings: settings,
            liveKey: settings.reasoningService == .sharedOpenAI ? key : nil, analysisKey: key)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chinese = RetrievedSource(chunk: .init(id: "cn", documentID: "cn", documentName: "Synthetic-CN.txt", ordinal: 0, page: nil,
            text: "合成项目资料：系统采用缓存。实验记录命中延迟为42毫秒，样本量128。这是测试资料。", vector: [], embeddingModel: "fixture"), score: 1)
        let english = RetrievedSource(chunk: .init(id: "en", documentID: "en", documentName: "Synthetic-EN.txt", ordinal: 0, page: nil,
            text: "Synthetic experiment: cache-hit latency was 42 milliseconds across 128 samples.", vector: [], embeddingModel: "fixture"), score: 1)
        let cases: [(String, String, AnswerLanguage, [RetrievedSource], Bool)] = [
            ("zh-general", "请问什么是二分查找？", .auto, [], true),
            ("en-after-zh", "Could you explain binary search?", .auto, [], false),
            ("mixed-explicit", "请用英文回答：how does a cache work? Use two sentences.", .auto, [], false),
            ("cn-document-en-answer", "What latency and sample size were measured in the synthetic experiment?", .auto, [chinese], false),
            ("en-document-cn-override", "What latency and sample size were measured?", .chinese, [english], true),
            ("personal-no-evidence", "我上一家公司负责的项目营收提升了多少？请不要猜测，用两句话回答。", .auto, [], true)
        ]
        var results: [[String: Any]] = []
        for (name, question, language, sources, expectChinese) in cases {
            let answer = AnswerRequest(query: .formulate(question: question, context: ""),
                conversation: "Them: 请介绍你的背景。\nYou: 我先用中文解释之前的问题。", scenario: .interview,
                sources: sources, answerLanguage: language)
            let start = ProcessInfo.processInfo.systemUptime
            var text = "", firstMS: Int?
            var audioMetrics: [String: Int] = [:]
            if name == "zh-general" || name == "en-after-zh" {
                let result = try await audioAnswer(question: question, chinese: expectChinese, provider: provider, directory: directory)
                text = result.0; audioMetrics = result.1; firstMS = audioMetrics["first_token_ms"]
            } else {
                for try await delta in provider.stream(answer) {
                    if !delta.isEmpty && firstMS == nil { firstMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                    text += delta
                }
            }
            let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
            XCTAssertEqual(han > 15, expectChinese, "Language mismatch: \(name)")
            if sources.isEmpty { XCTAssertTrue(SuggestionParser.citedIndices(text, sourceCount: 9999).isEmpty, name) }
            else {
                XCTAssertTrue(text.contains("42"), name); XCTAssertTrue(text.contains("128"), name)
                XCTAssertEqual(SuggestionParser.citedIndices(text, sourceCount: sources.count), [1], name)
            }
            if name == "personal-no-evidence" {
                XCTAssertFalse(text.contains("%") || text.contains("％"), "Personal metrics must not be invented")
                XCTAssertTrue(["不清楚", "不知道", "没有", "无法", "不确定", "缺少"].contains(where: text.contains))
            }
            results.append(["case": name, "provider": settings.reasoningService.rawValue,
                "first_text_ms": firstMS ?? -1, "complete_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
                "question": question, "answer": text, "audio_metrics": audioMetrics])
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("analysis-results.json"))
        }
    }
    @MainActor private func audioAnswer(question: String, chinese: Bool, provider: any ReasoningProvider, directory: URL) async throws -> (String, [String: Int]) {
        guard #available(macOS 26, *) else { throw CopilotError.message("Apple ASR unavailable") }
        let dataRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCopilot")
        let runtime = LayaRuntimeManager(root: dataRoot.appendingPathComponent("Laya"))
        try await runtime.prepareAndWait()
        let suite = "LiveCopilot-Real-Audio-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let app = AppCoordinator(mock: true, layaPredictor: { text, context in try await runtime.predict(text: text, context: context) },
                                 mockReasoning: provider, emitMockConversation: false, mockDefaults: defaults,
                                 mockKnowledgeDirectory: directory.appendingPathComponent("empty-" + UUID().uuidString))
        app.settings.listeningService = .apple; app.settings.automaticSuggestions = true
        await app.start()
        let audio = directory.appendingPathComponent(chinese ? "real-zh.aiff" : "real-en.aiff")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", chinese ? "Tingting" : "Samantha", "-o", audio.path, question]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: audio)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let converter = PCMConverter(); converter.configure(sampleRate: 16000)
        var pcm = Data(repeating: 0, count: 16000); pcm.append(converter.convert(buffer)!); pcm.append(Data(repeating: 0, count: 32000 * 3))
        let speech = AppleLiveProvider(speaker: .them, language: chinese ? .chinese : .english)
        try await speech.prepare()
        speech.onEvent = { event in app.receiveMockEvent(event, speaker: .them) }
        speech.connect(context: "")
        for offset in stride(from: 0, to: pcm.count, by: 3200) {
            speech.sendAudio(pcm.subdata(in: offset..<min(pcm.count, offset + 3200)))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while (app.suggestion.isLoading || app.suggestion.text.isEmpty) && app.suggestion.error == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let text = app.suggestion.text
        let metrics = app.suggestion.trace.map { trace in Dictionary(uniqueKeysWithValues: trace.times.keys.compactMap { stage in trace.milliseconds(stage).map { (stage.rawValue + "_ms", $0) } }) } ?? [:]
        XCTAssertNil(app.suggestion.error); XCTAssertFalse(text.isEmpty, "Real audio did not produce an answer")
        await speech.disconnect(); await app.shutdown(); await runtime.shutdown()
        defaults.removePersistentDomain(forName: suite)
        return (text, metrics)
    }

}
