import XCTest
@testable import LiveCopilot

private actor StreamTiming {
    var events: [(PipelineTrace.Stage, TimeInterval)] = []
    func record(_ stage: PipelineTrace.Stage, _ time: TimeInterval) { events.append((stage, time)) }
    func snapshot() -> [(PipelineTrace.Stage, TimeInterval)] { events }
}

final class AnswerLatencyTests: XCTestCase {
    func testRepeatedCaptionsDoNotDuplicateQuestionOrEraseDifferentFacts() {
        var state = ConversationState()
        let now = Date()
        let texts = ["日本的首都是哪里", " 日本的首都是哪里？", " 日本的首都是哪里"]
        for (i, text) in texts.enumerated() {
            _ = state.append(.init(id: "\(i)", speaker: .room, text: text, startMS: i * 1000, endMS: i * 1000 + 900, receivedAt: now))
        }
        XCTAssertEqual(state.candidate(speaker: .room, now: now, cooldown: 0, force: true), texts[0])
        XCTAssertEqual(state.fragments.count, 3, "Raw captions must remain intact")
        XCTAssertEqual(state.context(), "Room: " + texts[0])
        _ = state.append(.init(id: "different", speaker: .room, text: " 中国的首都是哪里", startMS: 3000, endMS: 3900, receivedAt: now))
        XCTAssertTrue(state.candidate(speaker: .room, now: now, cooldown: 0, force: true)!.contains("中国"))
        _ = state.append(.init(id: "speaker", speaker: .you, text: texts[0], startMS: 4000, endMS: 4900, receivedAt: now))
        XCTAssertTrue(state.context().contains("You: " + texts[0]))
    }

    func testStreamingProgressNeverBecomesAnswerText() async throws {
        let clock = StreamTiming()
        var request = AnswerRequest(query: .formulate(question: "Test", context: ""), conversation: "", scenario: .interview, sources: [])
        request.onStreamProgress = { stage, time in await clock.record(stage, time) }
        let events = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, "",
            #"data: {"choices":[{"delta":{"reasoning_content":"never-display-or-log"}}]}"#, "",
            #"data: {"choices":[{"delta":{"reasoning_content":"second-private-chunk"}}]}"#, "",
            #"data: {"choices":[{"delta":{"content":"Tokyo."}}]}"#, "",
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, ""
        ]
        let provider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: URL(string: "https://fixture.invalid")!, transport: FixtureTransport(body: Data(), status: 200, events: events))
        var output = ""
        for try await text in provider.stream(request) { output += text }
        XCTAssertEqual(output, "Tokyo.")
        let stages = await clock.snapshot()
        XCTAssertEqual(stages.map(\.0), [.firstServiceEvent, .reasoningStarted])
        XCTAssertLessThanOrEqual(stages[0].1, stages[1].1)
    }

    @MainActor func testThinkingStatusOnlyAppearsAfterActualReasoningEvent() {
        let store = SuggestionStore(); store.begin(); store.trace = PipelineTrace()
        store.mark(.modelRequest); store.mark(.firstServiceEvent)
        XCTAssertEqual(store.waitingMessage, "Waiting for the model's answer…")
        store.mark(.reasoningStarted)
        XCTAssertEqual(store.waitingMessage, "The model is thinking…")
        XCTAssertTrue(store.text.isEmpty)
        store.begin()
        XCTAssertEqual(store.waitingMessage, "Retrieving evidence…")
    }

    /// Six paid requests only when explicitly opted in. Never modifies saved settings.
    @MainActor func testOptInDeepSeekLowVersusNone() async throws {
        let path = ProcessInfo.processInfo.environment["LIVECOPILOT_LATENCY_COMPARISON"] ?? ""
        guard !path.isEmpty, !path.hasPrefix("$(") else { throw XCTSkip("Requires authorization for six paid synthetic requests") }
        let settings = AppSettings.load(defaults: UserDefaults(suiteName: "com.livecopilot.app")!)
        guard settings.reasoningService == .deepSeek else { throw XCTSkip("This bounded comparison requires configured DeepSeek") }
        let reference = try settings.analysisCredentialReference()
        let key = try XCTUnwrap(KeychainStore.read(service: CredentialVault.service, account: CredentialVault.account(for: reference), interactive: ProcessInfo.processInfo.environment["LIVECOPILOT_KEYCHAIN_INTERACTIVE"] == "1"))
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let evidence = RetrievedSource(chunk: .init(id: "synthetic", documentID: "synthetic", documentName: "Synthetic.txt", ordinal: 0, page: nil,
            text: "合成测试项目：缓存命中延迟42毫秒，样本量128。", vector: [], embeddingModel: "fixture"), score: 1)
        let cases: [(String, String, [RetrievedSource])] = [
            ("simple-fact", "日本的首都是哪里？", []),
            ("mixed-evidence", "Please explain the 缓存 experiment's measured latency and sample size in English.", [evidence]),
            ("personal-unknown", "你的 GitHub 账号是怎么样，平时怎么使用？", [])
        ]
        var results: [[String: Any]] = []
        for (i, item) in cases.enumerated() {
            // Alternate order to reduce connection warm-up/order bias. No automatic retries.
            for effort in i % 2 == 0 ? ["low", "none"] : ["none", "low"] {
                let attempt: [String: Any] = ["case": item.0, "effort": effort]
                // Persist the attempt before sending, so interrupted runs cannot be mistaken for zero cost.
                results.append(attempt)
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("comparison.json"))
                let clock = StreamTiming(), start = ProcessInfo.processInfo.systemUptime
                var answer = AnswerRequest(query: .formulate(question: item.1, context: ""), conversation: "", scenario: .interview, sources: item.2)
                answer.onStreamProgress = { stage, time in await clock.record(stage, time) }
                let provider = ChatCompletionsProvider(key: key, model: settings.deepSeekModel, endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, deepSeekEffort: effort)
                var output = "", firstMS: Int?
                for try await text in provider.stream(answer) {
                    if !text.isEmpty && firstMS == nil { firstMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                    output += text
                }
                let completeMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                let stages = await clock.snapshot()
                results[results.count - 1] = attempt.merging([
                    "model": settings.deepSeekModel, "question": item.1, "answer": output,
                    "first_text_ms": firstMS ?? -1, "complete_ms": completeMS,
                    "stages_ms": Dictionary(uniqueKeysWithValues: stages.map { ($0.0.rawValue, Int(($0.1 - start) * 1000)) })
                ]) { _, new in new }
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("comparison.json"))
                XCTAssertFalse(output.isEmpty)
                if item.0 == "simple-fact" { XCTAssertTrue(output.contains("东京")) }
                if item.0 == "mixed-evidence" {
                    XCTAssertTrue(output.contains("42") && output.contains("128"))
                    XCTAssertEqual(SuggestionParser.citedIndices(output, sourceCount: 1), [1])
                }
                if item.2.isEmpty { XCTAssertTrue(SuggestionParser.citedIndices(output, sourceCount: 999).isEmpty) }
            }
        }
    }
}
