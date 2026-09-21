import XCTest
import Foundation
@testable import LiveCopilot

/// Counts the real coordinator-to-provider boundary, without an API key or audio capture.
private final class CountingLayaReasoning: ReasoningProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AnswerRequest] = []
    var hold = false
    private var waiting: AsyncThrowingStream<String, Error>.Continuation?
    func finishHeld() { lock.lock(); let value = waiting; waiting = nil; lock.unlock(); value?.finish() }
    var requests: [AnswerRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield("Synthetic answer")
            if hold { lock.lock(); waiting = continuation; lock.unlock() }
            else { continuation.finish() }
        }
    }
}

final class LayaCoordinatorTests: XCTestCase {
    @MainActor private func make(_ reasoning: CountingLayaReasoning,
                                predictor: ((String, String) async throws -> Double)? = { _, _ in 0.95 }) -> AppCoordinator {
        let suiteName = "LiveCopilot-Laya-Tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("laya-missing-" + UUID().uuidString)
        let app = AppCoordinator(mock: true, layaRoot: root, layaPredictor: predictor,
                                 mockReasoning: reasoning, emitMockConversation: false, mockDefaults: defaults)
        app.settings.automaticSuggestions = true
        app.settings.automaticTriggerService = .laya
        app.settings.mode = .remote
        app.settings.layaThreshold = 0.8
        return app
    }
    @MainActor private func pause(_ seconds: Double = 1.05) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor private func final(_ app: AppCoordinator, text: String, id: String = UUID().uuidString,
                                  speaker: Speaker = .them, offset: Int = 0) {
        app.receiveMockEvent(.transcript(.init(id: id, speaker: speaker, text: text,
                                             startMS: offset, endMS: offset + 1000, receivedAt: Date())), speaker: speaker)
    }
    @MainActor func testGateRegressionSuite() async throws {
        let passed = try await LayaTriggerChecks.run()
        XCTAssertGreaterThan(passed.count, 10)
    }
    @MainActor func testScoresPartialButDispatchesExactFinalOnceAfterSilence() async {
        let reasoning = CountingLayaReasoning()
        var scored: [String] = []
        let app = make(reasoning) { text, _ in scored.append(text); return 0.95 }
        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .them)
        app.receiveMockEvent(.partialTranscript("Could you explain caching"), speaker: .them)
        await pause(0.5)
        XCTAssertFalse(scored.isEmpty)
        XCTAssertTrue(reasoning.requests.isEmpty, "Partial captions must never dispatch an answer")
        let text = "Could you explain caching and its invalidation strategy?"
        final(app, text: text, id: "exact-final")
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty, "Active speech must suppress dispatch")
        app.receiveMockEvent(.speechActivity(false), speaker: .them)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.suggestion.question, text)
        XCTAssertEqual(scored.last, text)
        XCTAssertTrue(reasoning.requests.first?.conversation.contains(text) == true)
        final(app, text: text, id: "exact-final")
        app.receiveMockEvent(.delegation(id: "must-not-double-trigger", offsetMS: 1000), speaker: .them)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        await app.shutdown()
    }
    @MainActor func testOwnSpeechAndManualQuestionInvalidatePendingAutomaticAnswer() async {
        let reasoning = CountingLayaReasoning(), app = make(reasoning)
        await app.start()
        final(app, text: "How does the deployment process work?")
        app.receiveMockEvent(.speechActivity(true), speaker: .you)
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty)
        app.receiveMockEvent(.speechActivity(false), speaker: .you)
        final(app, text: "Please explain the database backup policy.", offset: 4000)
        app.askText("Manual question has priority")
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.suggestion.question, "Manual question has priority")
        await app.shutdown()
    }
    @MainActor func testStopResetAndDisableDiscardPendingDecision() async {
        for operation in 0..<3 {
            let reasoning = CountingLayaReasoning(), app = make(reasoning)
            await app.start()
            final(app, text: "Which architecture would you choose for this project?")
            if operation == 0 { await app.stop() }
            else if operation == 1 { await app.resetConversation() }
            else { app.settings.automaticSuggestions = false }
            await pause()
            XCTAssertTrue(reasoning.requests.isEmpty, "Operation \(operation) left a stale automatic request")
            app.askText("Manual generation remains available")
            await pause(0.2)
            XCTAssertEqual(reasoning.requests.count, 1)
            await app.shutdown()
        }
    }
    @MainActor func testMissingRuntimeDoesNotFallBackToProviderButAllowsManual() async {
        let reasoning = CountingLayaReasoning(), app = make(reasoning, predictor: nil)
        await app.start()
        final(app, text: "What is the latency of method B?")
        app.receiveMockEvent(.delegation(id: "no-paid-fallback", offsetMS: 1000), speaker: .them)
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty)
        XCTAssertFalse(app.laya.isReady)
        app.requestSuggestion()
        await pause(0.2)
        XCTAssertEqual(reasoning.requests.count, 1)
        await app.shutdown()
    }
    @MainActor func testFailedPredictorDoesNotCallReasoning() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { _, _ in throw CancellationError() }
        await app.start()
        final(app, text: "Please explain why the service is unavailable.")
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty)
        await app.shutdown()
    }
    @MainActor func testQuestionWaitsForBusyAnswerAndReusesItsScore() async {
        let reasoning = CountingLayaReasoning()
        reasoning.hold = true
        var scores = 0
        let app = make(reasoning) { _, _ in scores += 1; return 0.95 }
        await app.start()
        app.askText("Manual answer still streaming")
        await pause(0.2)
        final(app, text: "What is your approach to deployment safety?")
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(scores, 1)
        // Coordinator cooldown also applies to manual answers.
        await pause(6.1)
        reasoning.hold = false
        reasoning.finishHeld()
        await pause(0.3)
        XCTAssertEqual(reasoning.requests.count, 2)
        XCTAssertEqual(scores, 1, "Pending question must reuse its local score")
        await app.shutdown()
    }
    @MainActor func testLatePredictionCannotDispatchAfterReset() async {
        let reasoning = CountingLayaReasoning()
        var continuation: CheckedContinuation<Double, Never>?
        let app = make(reasoning) { _, _ in await withCheckedContinuation { continuation = $0 } }
        await app.start()
        final(app, text: "Please explain the reasoning behind this design.")
        await pause(0.2)
        XCTAssertNotNil(continuation)
        await app.resetConversation()
        continuation?.resume(returning: 0.99)
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty)
        await app.shutdown()
    }
    @MainActor func testShortChineseQuestionUsesSemanticDecision() async {
        let reasoning = CountingLayaReasoning(), app = make(reasoning)
        await app.start()
        final(app, text: "为什么？")
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.suggestion.question, "为什么？")
        await app.shutdown()
    }
    @MainActor func testInstalledLayaEndToEndWithMockReasoning() async throws {
        guard ProcessInfo.processInfo.environment["LIVECOPILOT_TEST_REAL_LAYA"] == "1" else {
            throw XCTSkip("Opt-in real local model test; no paid provider is used")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveCopilot/Development/Laya")
        let runtime = LayaRuntimeManager(root: root)
        try await runtime.prepareAndWait()
        for text in ["Could you explain your approach to solving this problem?", "请介绍一下你在这个项目中具体负责哪些工作？"] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            await app.start()
            final(app, text: text)
            let deadline = Date().addingTimeInterval(15)
            while reasoning.requests.isEmpty && Date() < deadline { await pause(0.1) }
            XCTAssertEqual(reasoning.requests.count, 1)
            XCTAssertEqual(app.suggestion.question, text)
            await app.shutdown()
        }
        for text in ["The meeting starts tomorrow at nine.", "今天我们先讨论项目进度，明天再看预算。"] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            await app.start()
            final(app, text: text)
            await pause()
            XCTAssertTrue(reasoning.requests.isEmpty, "Statement must not trigger in the real-model smoke set")
            await app.shutdown()
        }
        await runtime.shutdown()
    }
    @MainActor func testProviderRouteStillHandlesDelegationWithoutLaya() async {
        let reasoning = CountingLayaReasoning()
        var predictions = 0
        let app = make(reasoning) { _, _ in predictions += 1; return 0.95 }
        app.settings.automaticTriggerService = .provider
        await app.start()
        final(app, text: "What is the latency of method B?")
        app.receiveMockEvent(.delegation(id: "provider-route", offsetMS: 1000), speaker: .them)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(predictions, 0)
        await app.shutdown()
    }
}
