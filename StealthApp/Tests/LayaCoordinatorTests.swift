import XCTest
import Foundation
import SwiftUI
@testable import LiveCopilot

/// Counts the real coordinator-to-provider boundary, without an API key or audio capture.
private final class CountingLayaReasoning: ReasoningProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AnswerRequest] = []
    var hold = false
    var answerText = "Synthetic answer"
    private var waiting: AsyncThrowingStream<String, Error>.Continuation?
    func finishHeld() { lock.lock(); let value = waiting; waiting = nil; lock.unlock(); value?.finish() }
    var requests: [AnswerRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(answerText)
            if hold { lock.lock(); waiting = continuation; lock.unlock() }
            else { continuation.finish() }
        }
    }
}

final class LayaCoordinatorTests: XCTestCase {
    @MainActor func testSuppressedQuestionCanBeDeliveredAgainAfterOwnSpeech() async {
        var predictions = 0, answers = 0
        var events: [LayaGateEvent] = []
        let gate = LayaTriggerController(predict: { _, _ in predictions += 1; return 0.99 }, onTrigger: { _ in answers += 1; return true })
        gate.onEvent = { events.append($0) }
        gate.configure(enabled: true, threshold: 0.5, cooldown: 0)
        let question = LayaTriggerInput(text: "Please introduce your project", context: "", speaker: .them, isFinal: true, sourceID: "old")
        gate.setSpeaking(true, speaker: .you)
        gate.submit(question)
        await pause(0.25)
        XCTAssertEqual(predictions, 0)
        XCTAssertTrue(events.contains(.ownSpeech))
        gate.setSpeaking(false, speaker: .you)
        await pause(0.25)
        XCTAssertEqual(answers, 0, "Do not replay suppressed questions on silence alone")
        gate.submit(question)
        await pause(0.2)
        XCTAssertEqual(predictions, 0, "Old ASR replay must stay suppressed")
        var fresh = question; fresh.sourceID = "new"
        gate.submit(fresh)
        await pause(0.4)
        XCTAssertEqual(predictions, 1)
        XCTAssertEqual(answers, 1)
        gate.submit(question)
        await pause(0.2)
        XCTAssertEqual(answers, 1, "Actually handled questions must remain deduplicated")
        XCTAssertTrue(events.contains(.duplicate))
    }

    @MainActor func testRenderGateStatus() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"], !path.isEmpty, !path.hasPrefix("$(") else { throw XCTSkip("Opt-in UI rendering") }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = make(CountingLayaReasoning())
        app.settings.language = .simplifiedChinese
        app.settings.background = .white
        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .you)
        final(app, text: "Please introduce your project", id: "blocked")
        let host = NSHostingView(rootView: OverlayView(coordinator: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        await pause(0.4)
        host.layoutSubtreeIfNeeded(); window.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("own-speech-block.png"))
        window.orderOut(nil)
        await app.shutdown()
    }

    func testDiagnosticCountersAreBoundedAndContainOnlyFixedEvents() {
        LayaGateDiagnostics.begin()
        for _ in 0..<50 { LayaGateDiagnostics.record(.inputReceived) }
        LayaGateDiagnostics.record(.ownSpeech)
        let report = LayaGateDiagnostics.snapshot()
        XCTAssertTrue(report.contains("inputReceived: 50"))
        XCTAssertTrue(report.contains("ownSpeech: 1"))
        let timeline = report.components(separatedBy: "Recent events (maximum 32):\n").last!
        XCTAssertEqual(timeline.components(separatedBy: "\n").filter { $0.contains("T") && $0.contains("Z ") }.count, 32)
        LayaGateDiagnostics.begin()
        XCTAssertTrue(LayaGateDiagnostics.snapshot().contains("inputReceived: 0"))
    }

    @MainActor func testPredictionFailureIsExplicit() async {
        var events: [LayaGateEvent] = []
        let gate = LayaTriggerController(predict: { _, _ in throw LayaRuntimeError.unavailable }, onTrigger: { _ in XCTFail("Must not dispatch"); return true })
        gate.onEvent = { events.append($0) }
        gate.configure(enabled: true)
        gate.submit(.init(text: "Synthetic private question", context: "", speaker: .them, isFinal: true))
        await pause(0.15)
        XCTAssertEqual(events.last, .failed)
        XCTAssertFalse(events.contains(.predictionCompleted))
    }

    @MainActor func testGateDiagnosticReasonsTrackRealBoundaries() async {
        var score = 0.95
        var events: [LayaGateEvent] = []
        let gate = LayaTriggerController(predict: { _, _ in score }, onTrigger: { _ in true })
        gate.onEvent = { events.append($0) }
        let question = LayaTriggerInput(text: "Explain caching", context: "", speaker: .them, isFinal: false)
        gate.submit(question)
        XCTAssertEqual(events.last, .disabled)
        gate.configure(enabled: true)
        gate.submit(question)
        await pause(0.15)
        XCTAssertTrue(events.contains(.predictionStarted))
        XCTAssertTrue(events.contains(.predictionCompleted))
        XCTAssertEqual(events.last, .waitingFinal)
        gate.setSpeaking(true, speaker: .them)
        gate.submit(.init(text: question.text, context: "", speaker: .them, isFinal: true))
        XCTAssertEqual(events.last, .waitingSilence)
        gate.reset(); score = 0.1
        gate.submit(.init(text: "A different question", context: "", speaker: .them, isFinal: true))
        await pause(0.15)
        XCTAssertEqual(events.last, .belowThreshold)
        gate.reset()
        XCTAssertEqual(events.filter { $0 == .predictionStarted }.count, 2)
        XCTAssertEqual(events.filter { $0 == .predictionCompleted }.count, 2)
    }

    @MainActor func testCoordinatorExposesOwnSpeechBlockAndRecoversOnFreshQuestion() async {
        let reasoning = CountingLayaReasoning(), app = make(reasoning)
        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .you)
        final(app, text: "Explain how caches work", id: "suppressed")
        await pause(0.2)
        XCTAssertEqual(app.layaGateStatus, .ownSpeech)
        XCTAssertNil(app.layaLastScore)
        XCTAssertTrue(reasoning.requests.isEmpty)
        app.receiveMockEvent(.speechActivity(false), speaker: .you)
        final(app, text: "Explain how caches work", id: "fresh", offset: 6000)
        await pause(0.7)
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.layaGateStatus, .dispatched)
        await app.shutdown()
    }

    @MainActor func testRawRequestAndRollingHistoryReachModelButAnswerKeepsReadableContext() async throws {
        let reasoning = CountingLayaReasoning()
        var inputs: [(String, String)] = []
        let app = make(reasoning) { text, context in
            inputs.append((text, context))
            // This verifies transport and scheduling only, not real model accuracy.
            return text == "第一个项目仔细讲一下吧" ? 0.95 : 0.1
        }
        await app.start()
        final(app, text: "我有三个项目：检索、语音和数据分析。", id: "history", speaker: .you)
        final(app, text: "第一个项目仔细讲一下吧", id: "request", offset: 3000)
        await pause(0.8)
        XCTAssertEqual(inputs.count, 1, "One semantic inference, without punctuation or sentence variants")
        XCTAssertEqual(inputs.first?.0, "第一个项目仔细讲一下吧")
        let modelContext = try XCTUnwrap(inputs.first?.1)
        XCTAssertTrue(modelContext.contains("recentTurns"))
        XCTAssertTrue(modelContext.contains("我有三个项目"))
        XCTAssertFalse(modelContext.contains("第一个项目仔细讲一下吧"))
        let request = try XCTUnwrap(reasoning.requests.first)
        XCTAssertTrue(request.conversation.contains("我有三个项目"))
        XCTAssertFalse(request.conversation.contains("recentTurns"), "Model-only context schema must not leak into the answer prompt")
        final(app, text: "第一个项目仔细讲一下吧", id: "request", offset: 3000)
        await pause(0.1)
        XCTAssertEqual(reasoning.requests.count, 1)
        await app.shutdown()
    }

    func testContinuousQueuePoliciesAndRevision() throws {
        var queue = QuestionCoordinator()
        let now = Date()
        func add(_ text: String, _ seconds: Double, _ source: String, _ policy: ContinuousQuestionPolicy = .smart) {
            queue.enqueue(query: text, context: "", speaker: .them, delegationID: nil, trace: nil,
                          sourceID: source, policy: policy, now: now.addingTimeInterval(seconds))
        }
        add("Why use RAG?", 0, "a")
        XCTAssertEqual(queue.take(now: now)?.query, "Why use RAG?", "Default must not wait for merge window")
        add("Compared to vector search, what are its benefits?", 1, "b")
        XCTAssertTrue(queue.pending[0].query.contains("Why use RAG?"))
        add("Compared to vector search, what are its limitations?", 1.1, "b")
        XCTAssertEqual(queue.pending.count, 1, "ASR revision must not add a request")
        XCTAssertTrue(queue.pending[0].query.contains("limitations"))
        add("What is your salary expectation?", 2, "c")
        XCTAssertEqual(queue.pending.count, 2)
        XCTAssertEqual(queue.pending[1].query, "What is your salary expectation?")
        add("What is your salary expectation?", 2.1, "d")
        XCTAssertEqual(queue.pending.count, 2)
        add("Describe a conflict", 3, "e"); add("Explain TCP", 4, "f")
        XCTAssertEqual(queue.pending.count, 3); XCTAssertEqual(queue.droppedCount, 1)
        XCTAssertNil(queue.take(now: now.addingTimeInterval(35)))
        queue.clear(); add("Why use RAG?", 0, "a", .complete)
        XCTAssertNil(queue.take(now: now)); XCTAssertNotNil(queue.take(now: now.addingTimeInterval(1.3)))
        queue.clear(); add("Why use RAG?", 0, "a", .fast); _ = queue.take(now: now)
        add("Compared to vector search?", 1, "b", .fast)
        XCTAssertEqual(queue.pending[0].query, "Compared to vector search?")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.continuousQuestionPolicy, .smart)
        var saved = old; saved.continuousQuestionPolicy = .complete
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved)).continuousQuestionPolicy, .complete)
    }
    @MainActor func testContinuousQuestionsPreserveForegroundAndAllowNavigation() async {
        let reasoning = CountingLayaReasoning(); reasoning.hold = true
        let app = make(reasoning); await app.start()
        final(app, text: "Why use RAG?", id: "a")
        await pause(1)
        let firstID = app.selectedAnswerID
        XCTAssertEqual(app.suggestion.question, "Why use RAG?")
        XCTAssertFalse(app.suggestion.text.isEmpty)
        final(app, text: "Compared to vector search, what are its benefits?", id: "b", offset: 2000)
        await pause(1)
        XCTAssertEqual(reasoning.requests.count, 1, "Must not cancel the streaming first answer")
        XCTAssertEqual(app.queuedQuestionCount, 1)
        reasoning.hold = false; reasoning.finishHeld(); await pause(0.3)
        XCTAssertEqual(reasoning.requests.count, 2)
        XCTAssertEqual(app.selectedAnswerID, firstID)
        XCTAssertEqual(app.suggestion.question, "Why use RAG?")
        XCTAssertEqual(app.unreadAnswerCount, 1)
        app.showNextAnswer()
        XCTAssertTrue(app.suggestion.question.contains("benefits"))
        XCTAssertTrue(app.suggestion.question.contains("Why use RAG?"))
        if app.answers.count == 2 { XCTAssertNotEqual(app.answers[0].questionID, app.answers[1].questionID) }
        if let id = app.previousAnswerID { app.selectAnswer(id) }
        XCTAssertEqual(app.selectedAnswerID, firstID)
        await app.shutdown()
    }
    @MainActor func testManualPriorityAndTimeoutDoNotOverwriteSelectedHistory() async {
        let reasoning = CountingLayaReasoning(); reasoning.hold = true
        let app = make(reasoning); await app.start()
        app.askText("Manual first")
        await pause(0.1)
        let firstID = app.selectedAnswerID!
        app.answerTimeoutSeconds = 0.15
        app.askText("Manual priority")
        await pause(0.1)
        app.selectAnswer(firstID)
        await pause(0.2)
        XCTAssertEqual(app.suggestion.question, "Manual first")
        XCTAssertFalse(app.answerIsRunning)
        XCTAssertNotNil(app.answers.last?.store.error)
        reasoning.finishHeld(); await pause(0.1)
        XCTAssertEqual(app.suggestion.question, "Manual first")
        XCTAssertEqual(app.answers.count, 2)
        await app.shutdown()
    }
    @MainActor func testStableASRRevisionDoesNotCreateSecondPaidRequest() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning); await app.start()
        final(app, text: "Could you explain retrieval design?", id: "same")
        await pause(1)
        final(app, text: "Could you explain retrieval system design?", id: "same")
        await pause(1)
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.answers.count, 1)
        await app.shutdown()
    }
    @MainActor func testFirstAnswerLatencyAndIndependentQuestion() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning); await app.start()
        let start = Date()
        final(app, text: "Could you explain the caching policy?", id: "latency-a")
        while reasoning.requests.isEmpty && Date().timeIntervalSince(start) < 1 { await pause(0.01) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(reasoning.requests.isEmpty)
        XCTAssertLessThan(elapsed, 0.8, "Smart mode must not add the 3-second merge window to the first answer")
        print("JEV_FIRST_DISPATCH_MS=\(Int(elapsed * 1000))")
        await pause(1)
        final(app, text: "What is your salary expectation?", id: "latency-b", offset: 2500)
        await pause(0.8)
        XCTAssertEqual(app.answers.count, 2)
        XCTAssertEqual(app.answers.last?.store.question, "What is your salary expectation?")
        XCTAssertEqual(app.suggestion.question, "Could you explain the caching policy?")
        await app.shutdown()
    }
    @MainActor func testConversationWindowFitsEmptyShortAndStreamingAnswers() async throws {
        let reasoning = CountingLayaReasoning(); reasoning.answerText = "A short answer."; reasoning.hold = true
        let app = make(reasoning); app.settings.language = .simplifiedChinese
        app.settings.background = .white; app.settings.overlayEdgeHide = false
        var panel: OverlayWindow?
        let view = OverlayView(coordinator: app, onContentHeight: { height in
            DispatchQueue.main.async { panel?.contentHeightChanged(height) }
        }, onMinimumHeight: { height in
            DispatchQueue.main.async { panel?.minimumContentHeightChanged(height) }
        })
        panel = OverlayWindow(rootView: view)
        let window = try XCTUnwrap(panel)
        window.configure(autoHeight: true, edgeHide: false)
        window.setCaptureExcluded(false)
        window.orderFrontRegardless()
        defer { window.close(); panel = nil }
        let root = URL(fileURLWithPath: "/tmp/overlay-content-fit-qa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            let host = try XCTUnwrap(window.contentView)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        await pause(0.4)
        let emptyHeight = window.frame.height, top = window.frame.maxY
        XCTAssertLessThan(emptyHeight, 500, "Empty conversation must not reserve the former 680-point window")
        try snapshot("empty")
        app.askText("Explain caching")
        await pause(0.4)
        let shortHeight = window.frame.height
        XCTAssertGreaterThan(shortHeight, emptyHeight)
        XCTAssertLessThan(shortHeight, 620, "Short answers should use their measured height")
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1, "Composer stays anchored to the same top edge")
        try snapshot("short")
        let answer = try XCTUnwrap(app.answers.first)
        answer.store.appendDelta(String(repeating: "\nA longer streaming answer for layout verification.", count: 100))
        await pause(0.5)
        let longHeight = window.frame.height
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertLessThanOrEqual(longHeight, 900)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        try snapshot("long")
        await app.resetConversation(); await pause(0.4)
        XCTAssertEqual(window.frame.height, emptyHeight, accuracy: 2, "Reset must shrink to the empty content again")
        let manualHeight = emptyHeight + 80
        window.setFrame(NSRect(x: window.frame.minX, y: top - manualHeight, width: window.frame.width, height: manualHeight), display: true)
        window.userFinishedResize(vertical: true)
        app.askText("Explain a queue"); await pause(0.4)
        XCTAssertEqual(window.frame.height, manualHeight, accuracy: 1, "Explicit manual sizing remains respected")
        reasoning.finishHeld(); await app.shutdown()
    }
    @MainActor func testRenderProtectedAnswer() async throws {
        let output = ProcessInfo.processInfo.environment["JEV_QA_OUTPUT"] ?? "/tmp/jev-answer-qa"
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reasoning = CountingLayaReasoning()
        reasoning.answerText = "建议回答\n我会结合关键词匹配与语义检索，提高专业术语问题的召回效果。\nI combine keyword matching with semantic retrieval to improve recall for technical questions.\n\n证据与说明\n这是用于界面验证的合成回答，不代表实际模型输出。"
        let app = make(reasoning); await app.start()
        final(app, text: "为什么使用 RAG？", id: "visual-a")
        await pause(1)
        final(app, text: "相比传统向量检索，它有什么优势？", id: "visual-b", offset: 2000)
        await pause(1)
        for language in [AppLanguage.simplifiedChinese, .english] {
            app.settings.language = language
            for width in [460.0, 680.0] {
                let host = NSHostingView(rootView: OverlayView(coordinator: app))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("overlay-\(language.rawValue)-\(Int(width)).png"))
                window.contentView = nil
            }
        }
        await app.shutdown()
    }
    func testScrollFollowDoesNotJumpWhileReadingHistory() {
        var scroll = ConversationScrollState()
        scroll.observe(offset: 500, distanceToBottom: 0)
        XCTAssertTrue(scroll.followsLatest)
        scroll.observe(offset: 500, distanceToBottom: 400) // new text grows below
        XCTAssertTrue(scroll.followsLatest)
        scroll.observe(offset: 200, distanceToBottom: 700) // user scrolls up
        XCTAssertFalse(scroll.followsLatest)
        scroll.observe(offset: 200, distanceToBottom: 1000)
        XCTAssertFalse(scroll.followsLatest)
        scroll.observe(offset: 1200, distanceToBottom: 0)
        XCTAssertTrue(scroll.followsLatest)
        XCTAssertTrue(AnswerMessageView.isEvidence("Evidence & notes"))
        XCTAssertTrue(AnswerMessageView.isEvidence("证据与说明"))
        XCTAssertFalse(AnswerMessageView.isEvidence("Suggested answer"))
        var resizing = ConversationScrollState()
        resizing.observe(offset: 500, distanceToBottom: 0, viewportHeight: 200)
        resizing.observe(offset: 350, distanceToBottom: 150, viewportHeight: 350)
        XCTAssertTrue(resizing.followsLatest, "Growing the viewport is not a user scrolling upward")
        resizing.observe(offset: 200, distanceToBottom: 300, viewportHeight: 350)
        XCTAssertFalse(resizing.followsLatest)
        resizing.observe(offset: 100, distanceToBottom: 300, viewportHeight: 450)
        XCTAssertFalse(resizing.followsLatest, "Resizing must also preserve the user's history-reading position")
    }
    @MainActor func testTranscriptDraftSaveReloadExportAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let start = Date()
        let line = TranscriptLine(speaker: .them, at: start, content: "请解释 RAG。Please explain RAG.")
        XCTAssertNil(store.save(lines: [], startedAt: start))
        let record = try XCTUnwrap(store.save(lines: [line], startedAt: start))
        let draft = root.appendingPathComponent(record.id.uuidString + ".txt")
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), record.transcriptDocument)
        let reloaded = SessionStore(root: root)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let exported = root.appendingPathComponent("export.txt")
        try reloaded.export(record, to: exported)
        XCTAssertTrue(try String(contentsOf: exported, encoding: .utf8).contains(line.content))
        reloaded.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))
        XCTAssertTrue(SessionStore(root: root).sessions.isEmpty)
    }
    @MainActor func testStylePreferencesReachAutomaticAndManualRequests() async throws {
        var defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.bilingualAnswers); XCTAssertEqual(defaults.additionalAnswerInstructions, "")
        defaults.bilingualAnswers = true; defaults.additionalAnswerInstructions = "Use short sentences."
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(defaults))
        XCTAssertTrue(decoded.bilingualAnswers); XCTAssertEqual(decoded.additionalAnswerInstructions, defaults.additionalAnswerInstructions)
        let reasoning = CountingLayaReasoning(); let app = make(reasoning)
        app.settings.bilingualAnswers = true; app.settings.additionalAnswerInstructions = defaults.additionalAnswerInstructions
        await app.start()
        final(app, text: "Could you explain retrieval design?")
        await pause(0.7)
        app.askText("Explain a cache")
        await pause(0.2)
        XCTAssertEqual(reasoning.requests.count, 2)
        for request in reasoning.requests {
            XCTAssertTrue(request.instructions.contains("Chinese sentence immediately followed"))
            XCTAssertTrue(request.instructions.contains("Use short sentences."))
        }
        XCTAssertEqual(app.answers.count, 2)
        XCTAssertTrue(app.answers[0].automatic); XCTAssertFalse(app.answers[1].automatic)
        XCTAssertEqual(app.answers[0].store.state, .completed)
        await app.stop()
        XCTAssertTrue(app.sessions.sessions.contains { $0.plainText.contains("retrieval design") })
        await app.shutdown()
    }
    func testSensitivityPresetsKeepThresholdSemanticsAndPersistence() throws {
        let levels = JevSensitivity.allCases
        XCTAssertEqual(levels.count, 5)
        for (less, more) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(less.threshold, more.threshold, "Higher sensitivity must require a lower score")
        }
        XCTAssertEqual(JevSensitivity.medium.threshold, AppSettings().layaThreshold)
        XCTAssertEqual(JevSensitivity.nearest(to: 0.83), .medium)
        XCTAssertEqual(JevSensitivity.nearest(to: 0.99), .low)
        XCTAssertEqual(JevSensitivity.nearest(to: .nan), .medium)
        for level in levels {
            var settings = AppSettings(); settings.layaThreshold = level.threshold
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(JevSensitivity.nearest(to: restored.layaThreshold), level)
        }
        XCTAssertFalse(LayaTriggerDecision.evaluate(score: 0.7, threshold: JevSensitivity.low.threshold).shouldTrigger)
        XCTAssertTrue(LayaTriggerDecision.evaluate(score: 0.7, threshold: JevSensitivity.high.threshold).shouldTrigger)
    }
    @MainActor func testRenderCompactJevSettingsPreservesExistingThreshold() async throws {
        let root = URL(fileURLWithPath: "/tmp/jev-settings-qa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = make(CountingLayaReasoning())
        app.settings.layaThreshold = 0.83
        for language in [AppLanguage.simplifiedChinese, .english] {
            app.settings.language = language
            for (width, height) in [(860, 680), (820, 610)] {
                // Include the extra cloud-engine status at the smallest supported view size.
                app.settings.listeningService = width == 820 ? .openAI : .paraformer
                let host = NSHostingView(rootView: SettingsView(coordinator: app, initialPage: .services, initialServiceRole: 1))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("jev-\(language.rawValue)-\(width)x\(height).png"))
                XCTAssertEqual(app.settings.layaThreshold, 0.83, "Displaying a preset must not quantize an existing saved setting")
                window.contentView = nil
            }
        }
        await app.shutdown()
    }
    @MainActor func testRenderSettingsPages() async throws {
        let root = URL(fileURLWithPath: "/tmp/jev-answer-qa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = make(CountingLayaReasoning()); app.settings.language = .simplifiedChinese
        for (name, page, role) in [("general", SettingsPage.general, 0), ("history", .history, 0), ("analysis", .services, 3), ("jev", .services, 1)] {
            let host = NSHostingView(rootView: SettingsView(coordinator: app, initialPage: page, initialServiceRole: role))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("settings-" + name + ".png"))
            window.contentView = nil
        }
        await app.shutdown()
    }
    @MainActor func testFreshConversationArchivesTranscriptBeforeClearing() async {
        let app = make(CountingLayaReasoning()); await app.start()
        let text = "Unique round " + UUID().uuidString
        final(app, text: text)
        await app.resetConversation()
        XCTAssertTrue(app.sessions.sessions.contains { $0.plainText.contains(text) })
        XCTAssertTrue(app.transcript.lines.isEmpty)
        XCTAssertTrue(app.answers.isEmpty)
        XCTAssertTrue(app.isRunning)
        await app.shutdown()
    }
    @MainActor private func make(_ reasoning: CountingLayaReasoning,
                                predictor: ((String, String) async throws -> Double)? = { _, _ in 0.95 }) -> AppCoordinator {
        let suiteName = "LiveCopilot-Laya-Tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("laya-missing-" + UUID().uuidString)
        let app = AppCoordinator(mock: true, layaRoot: root, layaPredictor: predictor,
                                 mockReasoning: reasoning, emitMockConversation: false, mockDefaults: defaults)
        app.settings.automaticSuggestions = true
        app.settings.listeningService = .paraformer
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
    @MainActor func testSettingsDiagnosticNeverCallsAnswerService() async throws {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { text, _ in text.hasSuffix("about") ? 0.1 : 0.95 }
        let question = try await app.testLayaTrigger(text: "Could you explain the retry policy?")
        XCTAssertTrue(question.decision.shouldTrigger)
        XCTAssertEqual(question.score, 0.95)
        XCTAssertEqual(question.threshold, 0.8)
        XCTAssertGreaterThanOrEqual(question.predictionMS, 0)
        let unfinished = try await app.testLayaTrigger(text: "I would like to ask you about")
        XCTAssertEqual(unfinished.decision, .belowThreshold)
        XCTAssertTrue(reasoning.requests.isEmpty)
        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(app.isTestingLaya)
        await app.shutdown()
    }
    @MainActor func testSettingsDiagnosticRejectsInputAndLiveSession() async {
        let reasoning = CountingLayaReasoning()
        var calls = 0
        let app = make(reasoning) { _, _ in calls += 1; return 0.95 }
        for text in ["  ", String(repeating: "中", count: 22000)] {
            do { _ = try await app.testLayaTrigger(text: text); XCTFail("Invalid input accepted") } catch { }
        }
        XCTAssertEqual(calls, 0)
        await app.start()
        do { _ = try await app.testLayaTrigger(text: "Why?"); XCTFail("Test ran during listening") } catch { }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(reasoning.requests.isEmpty)
        await app.shutdown()
    }
    func testDiagnosticPolicyKeepsExistingThresholdSemantics() {
        XCTAssertEqual(LayaTriggerDecision.evaluate(score: 0.7, threshold: 0.8), .belowThreshold)
        XCTAssertEqual(LayaTriggerDecision.evaluate(score: 0.85, threshold: 0.8), .threshold)
        XCTAssertEqual(LayaTriggerDecision.evaluate(score: 0.2, threshold: 0.8), .belowThreshold)
        XCTAssertEqual(LayaTriggerDecision.evaluate(score: 0.99, threshold: 0.8), .threshold)
        XCTAssertFalse(LayaTriggerDecision.evaluate(score: .nan, threshold: 0.8).shouldTrigger)
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
    @MainActor func testSingleCharacterTurnStillUsesLayaDecision() async {
        for (text, score, expectedRequests) in [("说", 0.99, 1), ("嗯", 0.02, 0)] {
            let reasoning = CountingLayaReasoning()
            var inputs: [String] = []
            let app = make(reasoning) { input, _ in inputs.append(input); return score }
            await app.start()
            final(app, text: "你想让我接着讲下去吗？", id: "context", speaker: .you)
            final(app, text: text, id: "single-character", offset: 2000)
            await pause()
            XCTAssertEqual(inputs, [text], "Do not bypass Laya because the utterance has one character")
            XCTAssertEqual(reasoning.requests.count, expectedRequests, "Only the model score determines response eligibility")
            await app.shutdown()
        }
    }
    @MainActor private func realLayaRuntime() async throws -> LayaRuntimeManager {
        guard ProcessInfo.processInfo.environment["LIVECOPILOT_TEST_REAL_LAYA"] == "1" else {
            throw XCTSkip("Opt-in real local model test; no paid provider is used")
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["LIVECOPILOT_TEST_LAYA_ROOT"], path.hasPrefix("/") {
            guard let resources = environment["LIVECOPILOT_TEST_LAYA_RESOURCES"], resources.hasPrefix("/") else {
                throw LayaRuntimeError.unavailable
            }
            let runtime = LayaRuntimeManager(root: URL(fileURLWithPath: path),
                                            resources: URL(fileURLWithPath: resources))
            guard runtime.isInstalled else { throw LayaRuntimeError.unavailable }
            try await runtime.prepareAndWait()
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("current/receipt.json"))
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            print("JEV_REAL_MODEL_PIN_ID=\(receipt["pin_id"] ?? "unknown")")
            print("JEV_REAL_CHECKPOINT_ID=\(runtime.checkpointID ?? "unknown")")
            return runtime
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveCopilot")
        let development = support.appendingPathComponent("Development/Laya")
        // Opt-in smoke check may read the installed runtime when there is no
        // development copy. prepareAndWait only loads it; never install/download.
        let root = FileManager.default.fileExists(atPath: development.appendingPathComponent("current").path)
            ? development : support.appendingPathComponent("Laya")
        let runtime = LayaRuntimeManager(root: root)
        guard runtime.isInstalled else { throw XCTSkip("No verified local Laya installation") }
        try await runtime.prepareAndWait()
        return runtime
    }
    @MainActor func testInstalledLayaEndToEndWithMockReasoning() async throws {
        let runtime = try await realLayaRuntime()
        for (text, speaker) in [
            ("Could you explain your approach to solving this problem?", Speaker.them),
            ("请介绍一下你在这个项目中具体负责哪些工作？", .them),
            ("你好你讲一下这个机制的实现是怎么做的", .room),
            ("你这个早退机制是怎么确定时间的", .room),
            // Exact final captions produced by this Mac's synthetic Paraformer
            // and Apple speech probes, including their missing punctuation.
            ("请问这个实验为什么选择方法比它的延迟是多少毫秒", .room),
            ("why did we choose method be and what is its lenc", .them),
            ("第一个项目仔细讲一下吧", .room),
            ("啊第一个项目仔细讲一下吧", .room),
            // Clear response intent survives an elliptical or unfinished ending.
            ("请你介绍当资源不足时怎样", .room),
            ("请介绍这个项目，因为", .room),
        ] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            if speaker == .room { app.settings.mode = .inPerson }
            await app.start()
            final(app, text: text, speaker: speaker)
            let deadline = Date().addingTimeInterval(15)
            while reasoning.requests.isEmpty && Date() < deadline {
                // One final input has one semantic decision. A rejected score will
                // not improve by waiting for the deadline; report that failure now.
                if let score = app.layaLastScore, score < app.settings.layaThreshold { break }
                await pause(0.1)
            }
            XCTAssertEqual(reasoning.requests.count, 1, "Real model missed request: \(text); score: \(String(describing: app.layaLastScore))")
            XCTAssertEqual(app.suggestion.question, text)
            await app.shutdown()
        }
        for text in ["The meeting starts tomorrow at nine.", "今天我们先讨论项目进度，明天再看预算。",
                     "第一个项目我仔细讲一下吧", "他说第一个项目仔细讲一下吧", "第一个项目不用仔细讲了"] {
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
    @MainActor func testRealLayaContextFollowupQueueAndRevisionPreserveStreamingAnswer() async throws {
        let runtime = try await realLayaRuntime()
        let reasoning = CountingLayaReasoning(); reasoning.hold = true
        let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
        await app.start()
        final(app, text: "我做过检索系统、语音助手和数据处理三个项目。", id: "background", speaker: .you)
        let start = Date()
        final(app, text: "第一个项目仔细讲一下吧", id: "first", offset: 2000)
        while reasoning.requests.isEmpty && Date().timeIntervalSince(start) < 3 { await pause(0.01) }
        XCTAssertEqual(reasoning.requests.count, 1, "Real Laya must accept an imperative with history")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "No merge-window delay on the first response")
        if !reasoning.requests.isEmpty {
            print("JEV_REAL_FIRST_DISPATCH_MS=\(Int(Date().timeIntervalSince(start) * 1000))")
        } else {
            print("JEV_REAL_NO_DISPATCH score=\(String(describing: app.layaLastScore))")
        }
        await pause(1)
        let firstID = app.selectedAnswerID
        let firstText = app.suggestion.text
        XCTAssertFalse(firstText.isEmpty)
        final(app, text: "那延迟呢", id: "followup", offset: 4000)
        await pause(1)
        XCTAssertEqual(reasoning.requests.count, 1, "New semantic request must not cancel the current stream")
        XCTAssertEqual(app.queuedQuestionCount, 1, "Real model must accept the contextual follow-up")
        XCTAssertEqual(app.suggestion.text, firstText)
        final(app, text: "那它的延迟呢", id: "followup", offset: 4000)
        await pause(0.4)
        XCTAssertEqual(app.queuedQuestionCount, 1, "ASR revision remains one queued request")
        reasoning.hold = false; reasoning.finishHeld()
        await pause(0.5)
        XCTAssertEqual(reasoning.requests.count, 2)
        XCTAssertEqual(app.answers.count, 2)
        XCTAssertEqual(app.selectedAnswerID, firstID)
        XCTAssertEqual(app.suggestion.text, firstText)
        app.showNextAnswer()
        XCTAssertNotEqual(app.selectedAnswerID, firstID)
        if let firstID { app.selectAnswer(firstID) }
        XCTAssertEqual(app.suggestion.text, firstText)
        await app.shutdown(); await runtime.shutdown()
    }
    @MainActor func testRealLayaReportedWithdrawnAndIncompleteASR() async throws {
        let runtime = try await realLayaRuntime()
        // Exposed regression examples: never described as fresh model acceptance.
        for text in ["他说第一个项目仔细讲一下吧", "请先别回答", "请比较这个项目与",
                     "我换个问法，你在这个项目里到底", "第一个项目是一个知识库检索系统。"] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            await app.start()
            final(app, text: text, id: "negative")
            await pause(0.85)
            XCTAssertLessThan(try XCTUnwrap(app.layaLastScore), 0.8, "Real Laya must wait: \(text)")
            XCTAssertTrue(reasoning.requests.isEmpty, "Wait when intent is absent, withdrawn, or still missing an essential object")
            await app.shutdown()
        }
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
        await app.start()
        final(app, text: "我想了解这个系统在", id: "asr-revision")
        await pause(0.7)
        XCTAssertTrue(reasoning.requests.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(app.layaLastScore), 0.8)
        final(app, text: "我想了解这个系统在断网时如何工作", id: "asr-revision")
        await pause(0.85)
        XCTAssertEqual(reasoning.requests.count, 1, "Completion of the same ASR segment must become one request")
        final(app, text: "我想了解这个系统在断网时如何工作？", id: "asr-revision")
        await pause(0.2)
        XCTAssertEqual(reasoning.requests.count, 1, "Punctuation correction must not bill twice")
        await app.shutdown()

        let cancelled = CountingLayaReasoning()
        let withdrawing = make(cancelled) { text, context in try await runtime.predict(text: text, context: context) }
        await withdrawing.start()
        final(withdrawing, text: "请解释这个系统的实现", id: "withdraw")
        await pause(0.05) // Revision arrives before the existing quiet guard expires.
        final(withdrawing, text: "请解释这个系统的实现，等等，先别回答", id: "withdraw")
        await pause(0.85)
        XCTAssertLessThan(try XCTUnwrap(withdrawing.layaLastScore), 0.8)
        XCTAssertTrue(cancelled.requests.isEmpty, "Latest semantic intent retracts the pending request")
        await withdrawing.shutdown(); await runtime.shutdown()
    }
    @MainActor func testRealLayaImplicitRequestUsesConversationContext() async throws {
        let runtime = try await realLayaRuntime()
        // Known user regression, plus the same utterance in an explicitly quoted
        // context. Neither is a replacement for the independently frozen holdout.
        for (history, expected) in [
            ("我的经历分成需求访谈、实施和交付三个阶段。", true),
            ("下面你只是逐字朗读昨天的访谈记录，不是在向我提问。", false),
        ] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            await app.start()
            final(app, text: history, id: "implicit-background", speaker: .you)
            final(app, text: "第一段我还想听细一点", id: "implicit-request", offset: 2000)
            let deadline = Date().addingTimeInterval(3)
            while app.layaLastScore == nil && Date() < deadline { await pause(0.02) }
            let score = try XCTUnwrap(app.layaLastScore)
            XCTAssertEqual(score >= 0.8, expected, "The same utterance must be interpreted in its current conversation")
            await pause(0.7)
            XCTAssertEqual(reasoning.requests.count, expected ? 1 : 0)
            if expected {
                let answerID = app.selectedAnswerID
                final(app, text: "第一段我还想听细一点。", id: "implicit-request", offset: 2000)
                await pause(0.2)
                XCTAssertEqual(reasoning.requests.count, 1, "A punctuation-only ASR revision must not create another request")
                XCTAssertEqual(app.selectedAnswerID, answerID)
            }
            await app.shutdown()
        }
        await runtime.shutdown()
    }
    @MainActor func testRealLayaEnglishCaptionIntentAndRevision() async throws {
        let runtime = try await realLayaRuntime()
        // Known ASR regressions in their actual surface forms; no inference-side
        // lowercasing or phrase matching is allowed to make these pass.
        for (caption, expected) in [
            ("why did we choose method be and what is its lenc", true),
            ("WHY DID WE CHOOSE METHOD BE AND WHAT IS ITS LENC", true),
            ("WHAT DID YOU DO ONCE THAT WAS OVER", true),
            ("WAIT UNTIL I EXPLICITLY INVITE YOUR ANSWER BEFORE SPEAKING", false),
            ("HOW DID YOU VERIFY THE FIX AS THE TITLE OF AN OLD TRANSCRIPT ENTRY", false),
        ] {
            let reasoning = CountingLayaReasoning()
            let app = make(reasoning) { text, context in try await runtime.predict(text: text, context: context) }
            await app.start()
            final(app, text: caption, id: "caption-regression", speaker: .them)
            let deadline = Date().addingTimeInterval(3)
            while app.layaLastScore == nil && Date() < deadline { await pause(0.02) }
            XCTAssertEqual(try XCTUnwrap(app.layaLastScore) >= 0.8, expected, caption)
            await pause(0.7)
            XCTAssertEqual(reasoning.requests.count, expected ? 1 : 0, caption)
            if expected {
                let answerID = app.selectedAnswerID
                final(app, text: caption + "?", id: "caption-regression", speaker: .them)
                await pause(0.2)
                XCTAssertEqual(reasoning.requests.count, 1, "Caption punctuation must not generate a second paid request")
                XCTAssertEqual(app.selectedAnswerID, answerID)
            }
            await app.shutdown()
        }
        await runtime.shutdown()
    }
    @MainActor func testGPTLiveDelegationTriggersWithoutLaya() async {
        let reasoning = CountingLayaReasoning()
        var predictions = 0
        let app = make(reasoning) { _, _ in predictions += 1; return 0.95 }
        app.settings.listeningService = .openAI
        await app.start()
        final(app, text: "What is the latency of method B?")
        await pause(0.65)
        XCTAssertTrue(reasoning.requests.isEmpty, "GPT-Live-1 must decide when to delegate")
        app.receiveMockEvent(.delegation(id: "provider-route", offsetMS: 1000), speaker: .them)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(predictions, 0)
        await app.shutdown()
    }
    @MainActor func testLocalSpeechAlwaysUsesLayaAndIgnoresProviderDelegation() async {
        let reasoning = CountingLayaReasoning()
        var predictions = 0
        let app = make(reasoning) { _, _ in predictions += 1; return 0.57 }
        app.settings.mode = .inPerson
        app.settings.listeningService = .paraformer
        await app.start()
        let question = "你讲一下这个机制是怎么实现的"
        final(app, text: question, id: "room-question", speaker: .room)
        await pause()
        XCTAssertGreaterThan(predictions, 0)
        XCTAssertTrue(reasoning.requests.isEmpty)
        app.receiveMockEvent(.delegation(id: "question-room-question", offsetMS: 1000), speaker: .room)
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty, "local provider delegation must not bypass Laya")
        await app.shutdown()
    }
    @MainActor func testAppleSpeechRoutesFinalTranscriptThroughLaya() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning)
        app.settings.mode = .inPerson
        app.settings.listeningService = .apple
        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .room)
        app.receiveMockEvent(.partialTranscript("你这个机制是怎么确定时间的"), speaker: .room)
        final(app, text: "你这个机制是怎么确定时间的", id: "apple-final", speaker: .room)
        app.receiveMockEvent(.partialTranscript(""), speaker: .room)
        app.receiveMockEvent(.speechActivity(false), speaker: .room)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.suggestion.question, "你这个机制是怎么确定时间的")
        await app.shutdown()
    }
    @MainActor func testRoomLayaShowsScoreBelowThreshold() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { _, _ in 0.57 }
        app.settings.mode = .inPerson
        await app.start()
        final(app, text: "你讲一下这个机制是怎么实现的", speaker: .room)
        await pause()
        XCTAssertEqual(app.layaLastScore, 0.57)
        XCTAssertTrue(reasoning.requests.isEmpty)
        await app.shutdown()
    }
    @MainActor func testTopicFirstRequestReachesAnswerOnceAfterSemanticDecisionAndSilence() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { _, _ in 0.95 }
        app.settings.mode = .inPerson
        await app.start()
        let text = "啊第一个项目仔细讲一下吧"
        app.receiveMockEvent(.speechActivity(true), speaker: .room)
        app.receiveMockEvent(.partialTranscript(text), speaker: .room)
        await pause(0.4)
        XCTAssertTrue(reasoning.requests.isEmpty, "Partial ASR must not dispatch")
        final(app, text: text, id: "topic-first", speaker: .room)
        await pause(0.4)
        XCTAssertTrue(reasoning.requests.isEmpty, "Still-speaking final ASR must not dispatch")
        app.receiveMockEvent(.partialTranscript(""), speaker: .room)
        app.receiveMockEvent(.speechActivity(false), speaker: .room)
        await pause(0.6)
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.suggestion.question, text)
        XCTAssertEqual(app.layaLastScore, 0.95)
        XCTAssertEqual(app.settings.layaThreshold, 0.8)
        final(app, text: text + "。", id: "topic-first", speaker: .room)
        await pause(0.6)
        XCTAssertEqual(reasoning.requests.count, 1, "ASR punctuation revision must not bill again")
        await app.shutdown()
    }
    @MainActor func testRoomLayaSemanticQuestionTriggersAfterSpeechGap() async {
        let reasoning = CountingLayaReasoning()
        let app = make(reasoning) { _, _ in 0.85 }
        app.settings.mode = .inPerson
        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .room)
        final(app, text: "你这个机制是怎么确定时间的", speaker: .room)
        await pause()
        XCTAssertTrue(reasoning.requests.isEmpty)
        app.receiveMockEvent(.speechActivity(false), speaker: .room)
        app.receiveMockEvent(.partialTranscript("气"), speaker: .room)
        await pause()
        XCTAssertEqual(reasoning.requests.count, 1)
        XCTAssertEqual(app.layaLastScore, 0.85)
        await app.shutdown()
    }
}
