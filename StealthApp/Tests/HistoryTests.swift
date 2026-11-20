import XCTest
import SwiftUI
@testable import LiveCopilot

private struct TitleProvider: ReasoningProvider {
    var value = "缓存优化讨论"
    var delay: UInt64 = 0
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await Task.sleep(nanoseconds: delay); try Task.checkCancellation(); continuation.yield(value); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
final class HistoryTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func answer(_ at: Date, text: String = "## Suggested answer\nUse **caching**.\n\n## Evidence & notes\n42 ms [S1]") -> SessionAnswer {
        SessionAnswer(id: UUID(), questionID: UUID(), automatic: false, createdAt: at, answeredAt: at.addingTimeInterval(1), completedAt: at.addingTimeInterval(2), question: "How can we reduce latency?", text: text, state: "completed", warning: nil, error: nil,
                      sources: [.init(index: 1, documentID: "fixture", documentName: "性能报告", page: 2, ordinal: 0, excerpt: "Synthetic cache hit: 42 ms")], sourceFragmentID: nil)
    }
    @MainActor func testLegacyLoadDoesNotRewriteOrInventAnswers() throws {
        let root = try directory(), id = UUID()
        let data = Data("""
        {"id":"\(id)","startedAt":"2026-10-16T10:00:00Z","endedAt":"2026-10-16T10:01:00Z","lines":[{"id":"\(UUID())","speaker":"Room","at":"2026-10-16T10:00:01Z","content":"旧版转写"}]}
        """.utf8)
        let path = root.appendingPathComponent(id.uuidString + ".json"); try data.write(to: path)
        let record = try XCTUnwrap(SessionStore(root: root).sessions.first)
        XCTAssertTrue(record.isLegacy); XCTAssertNil(record.answers); XCTAssertEqual(record.timeline.count, 1)
        XCTAssertEqual(record.timeline[0].kind, .room); XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertFalse(record.export(markdown: true).contains("AI 回答"))
    }
    @MainActor func testRoundTripTimelineSearchAndBothExports() throws {
        let root = try directory(), store = SessionStore(root: root), at = Date(timeIntervalSince1970: 1_790_000_000)
        let record = try XCTUnwrap(store.saveSnapshot(lines: [.init(from: .init(speaker: .them, at: at, content: "缓存的讨论"))], startedAt: at, endedAt: at.addingTimeInterval(62), answers: [answer(at.addingTimeInterval(2)), answer(at.addingTimeInterval(5), text: "Second independent answer")]))
        XCTAssertEqual(SessionStore(root: root).sessions.first, record)
        XCTAssertEqual(record.timeline.map(\.kind), [.nearby, .question, .answer, .question, .answer])
        XCTAssertTrue(record.matches("CACHING latency")); XCTAssertTrue(record.matches("性能报告")); XCTAssertTrue(record.matches("42 ms")); XCTAssertFalse(record.matches("absent term"))
        for ext in ["md", "txt"] {
            let url = root.appendingPathComponent("export." + ext); try store.export(record, to: url)
            let text = try String(contentsOf: url, encoding: .utf8)
            for value in ["附近语音", "手动提问", "AI 回答", "[S1]", "性能报告", "42 ms", "Second independent answer", "2026-"] { XCTAssertTrue(text.contains(value), value) }
        }
    }
    @MainActor func testStableASRRevisionsAndLongArchiveBeyondVisibleLimit() {
        let store = TranscriptStore(), at = Date()
        for index in 0..<1200 {
            store.ingest(.init(id: "f\(index)", speaker: index.isMultiple(of: 2) ? .room : .them, text: "Original \(index)", startMS: index * 2000, endMS: index * 2000 + 1000, receivedAt: at.addingTimeInterval(Double(index))))
        }
        store.ingest(.init(id: "f0", speaker: .room, text: "Corrected first line", startMS: 0, endMS: 1000, receivedAt: at))
        let saved = store.archiveSnapshot(since: at)
        XCTAssertEqual(store.lines.count, Config.transcriptLineLimit); XCTAssertEqual(saved.count, 1200)
        XCTAssertEqual(saved[0].content, "Corrected first line"); XCTAssertEqual(saved[0].fragmentIDs, ["f0"])
        XCTAssertEqual(store.fragmentRevisions.filter { $0.id == "f0" }.count, 2)
        store.clear(); XCTAssertTrue(store.archivedLines.isEmpty); XCTAssertTrue(store.fragmentRevisions.isEmpty)
    }
    @MainActor func testDeleteCannotBeUndoneByLateNamingOrAnswer() throws {
        let root = try directory(), store = SessionStore(root: root), at = Date()
        let record = try XCTUnwrap(store.saveSnapshot(lines: [], startedAt: at, answers: [answer(at)]))
        store.delete(record)
        XCTAssertFalse(store.update(record.id) { $0.generatedTitle = "late" })
        XCTAssertTrue(store.sessions.isEmpty); XCTAssertTrue(SessionStore(root: root).sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.id.uuidString + ".txt").path))
    }
    @MainActor func testManualRenamePersistsAndRejectsInvalidTitles() throws {
        let root = try directory(), store = SessionStore(root: root), at = Date(timeIntervalSince1970: 1_790_000_000)
        let record = try XCTUnwrap(store.saveSnapshot(lines: [], startedAt: at, answers: [answer(at)]))
        XCTAssertTrue(store.rename(record.id, title: "  手动修正标题  "))
        XCTAssertFalse(store.rename(record.id, title: " "))
        XCTAssertFalse(store.rename(record.id, title: String(repeating: "字", count: 81)))
        let restored = try XCTUnwrap(SessionStore(root: root).sessions.first)
        XCTAssertEqual(restored.title, "手动修正标题")
        XCTAssertEqual(restored.namingState, "manual")
        XCTAssertEqual(restored.answers, record.answers)
        store.delete(restored)
        XCTAssertFalse(store.rename(record.id, title: "不能恢复删除记录"))
    }
    @MainActor func testNamingBoundedRequestSuccessFailureAndTimeout() async throws {
        let at = Date()
        var record = SessionRecord(startedAt: at, endedAt: at.addingTimeInterval(500), lines: (0..<100).map { .init(from: .init(speaker: .room, at: at.addingTimeInterval(Double($0)), content: "合成缓存讨论 " + String(repeating: "样本", count: 1000))) })
        record.answers = [answer(at)]
        let request = SessionNaming.request(for: record)
        XCTAssertLessThanOrEqual(record.namingInput.count, 45000)
        XCTAssertTrue(request.input.contains("Synthetic cache hit")); XCTAssertTrue(request.sources.isEmpty)
        XCTAssertTrue(request.instructions.contains("untrusted")); XCTAssertFalse(request.instructions.contains("spoken interview"))
        let title = try await SessionNaming.generate(for: record, provider: TitleProvider())
        XCTAssertEqual(title, "缓存优化讨论")
        do { _ = try await SessionNaming.generate(for: record, provider: TitleProvider(value: "line one\nline two")); XCTFail("Invalid title accepted") } catch {}
        let start = Date()
        do { _ = try await SessionNaming.generate(for: record, provider: TitleProvider(delay: 10_000_000_000), timeout: 10_000_000); XCTFail("Timeout accepted") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertNil(SessionNaming.clean("  ")); XCTAssertNil(SessionNaming.clean(String(repeating: "a", count: 81)))
    }
    @MainActor func testNamingKeepsPairedAnswersAndEvidenceWithoutChangingHistory() throws {
        let at = Date()
        var record = SessionRecord(startedAt: at, endedAt: at, lines: [])
        record.answers = [answer(at, text: "青松缓存项目采用灰度发布，错误率超过百分之一回滚 [S1]")]
        let original = record
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.namingInput.utf8)) as? [String: Any])
        let turns = try XCTUnwrap(payload["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0]["answer"] as? String, record.answers?.first?.text)
        XCTAssertTrue(record.namingInput.contains("Synthetic cache hit"))
        XCTAssertEqual(record, original)
        XCTAssertTrue(SessionNaming.request(for: record).instructions.contains("TITLE ONLY"))
        XCTAssertTrue(SessionNaming.request(for: record).instructions.contains("ambiguous"))
    }
    @MainActor func testCoordinatorKeepsMultipleAnswersAndLateCompletion() async throws {
        let suite = "HistoryCoordinator-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, mockReasoning: TitleProvider(value: "Synthetic response", delay: 100_000_000), emitMockConversation: false, mockDefaults: defaults)
        app.settings.automaticSuggestions = false
        let initial = Set(app.sessions.sessions.map(\.id))
        defer { for record in app.sessions.sessions where !initial.contains(record.id) { app.sessions.delete(record) } }
        await app.start()
        app.transcript.commit("Synthetic voice question", speaker: .room)
        app.askText("First test question")
        try await Task.sleep(nanoseconds: 300_000_000)
        app.askText("Second test question")
        await app.stop() // Persist while the second answer is still streaming.
        try await Task.sleep(nanoseconds: 400_000_000)
        let record = try XCTUnwrap(app.sessions.sessions.first(where: { !initial.contains($0.id) }))
        XCTAssertEqual(record.answers?.count, 2)
        XCTAssertEqual(record.answers?.map(\.question), ["First test question", "Second test question"])
        XCTAssertEqual(record.answers?.last?.state, "completed")
        XCTAssertEqual(record.answers?.last?.text, "Synthetic response")
        XCTAssertNil(record.generatedTitle, "Mock sessions must never invoke the user's API")
        await app.shutdown()
    }
    @MainActor func testLongHistoryNativeLayout() async throws {
        let store = SessionStore(root: try directory()), at = Date()
        _ = store.saveSnapshot(lines: (0..<3000).map { .init(from: .init(speaker: $0.isMultiple(of: 2) ? .room : .them, at: at.addingTimeInterval(Double($0)), content: "Long conversation line \($0). This is a synthetic transcript for scrolling acceptance.")) }, startedAt: at, endedAt: at.addingTimeInterval(3000), answers: [answer(at)])
        let host = NSHostingView(rootView: HistoryBrowser(sessions: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        let views = scrolls(host); XCTAssertGreaterThanOrEqual(views.count, 2)
        let timeline = try XCTUnwrap(views.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }))
        let start = Date()
        for fraction in [0.25, 0.5, 0.9, 0.2, 0.0] {
            timeline.contentView.scroll(to: NSPoint(x: 0, y: max(0, (timeline.documentView?.frame.height ?? 0) - timeline.contentView.frame.height) * fraction))
            timeline.reflectScrolledClipView(timeline.contentView)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertGreaterThan(timeline.documentView?.frame.height ?? 0, 10000)
    }
    @MainActor func testConfiguredAnalysisSessionTitle() async throws {
        guard ProcessInfo.processInfo.environment["LIVECOPILOT_REAL_ANALYSIS"] == "history-title" else { throw XCTSkip("Opt-in one synthetic title request") }
        let settings = AppSettings.load(defaults: (Bundle.main.bundleIdentifier == "com.livecopilot.app" ? UserDefaults.standard : try XCTUnwrap(UserDefaults(suiteName: "com.livecopilot.app"))))
        let reference = try settings.analysisCredentialReference()
        let key: String
        do { key = try XCTUnwrap(KeychainStore.read(service: CredentialVault.service, account: CredentialVault.account(for: reference), interactive: false)) }
        catch { throw XCTSkip("The unsigned XCTest host cannot access the saved credential; use the signed acceptance runner.") }
        let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: settings.reasoningService == .sharedOpenAI ? key : nil, analysisKey: key)
        let at = Date(), record = SessionRecord(startedAt: at, endedAt: at, lines: [.init(from: .init(speaker: .room, at: at, content: "这是合成测试会话。我们讨论缓存优化，让页面加载更快，并计划下周测试。"))])
        let title = try await SessionNaming.generate(for: record, provider: provider)
        XCTAssertFalse(title.isEmpty); XCTAssertLessThanOrEqual(title.count, 80)
        print("Synthetic session title: \(title)")
    }
    @MainActor func testTranscriptStoreIngestParityAndScaling() {
        let store = TranscriptStore(), at = Date()
        let start = ProcessInfo.processInfo.systemUptime
        // 4,000 fragments arranged in 2,000 speaker turns, each merging two adjacent fragments (< 1600 ms gap).
        for turn in 0..<2_000 {
            let speaker: Speaker = turn.isMultiple(of: 2) ? .them : .you
            let baseMS = turn * 4_000
            store.ingest(.init(id: "t\(turn)-a", speaker: speaker, text: "Turn \(turn) part A",
                               startMS: baseMS, endMS: baseMS + 500, receivedAt: at.addingTimeInterval(Double(turn))))
            store.ingest(.init(id: "t\(turn)-b", speaker: speaker, text: " part B",
                               startMS: baseMS + 700, endMS: baseMS + 1_200, receivedAt: at.addingTimeInterval(Double(turn) + 0.5)))
        }
        // Identical re-ingest must not append a duplicate revision.
        store.ingest(.init(id: "t0-a", speaker: .them, text: "Turn 0 part A", startMS: 0, endMS: 500, receivedAt: at))
        // Revisions to both earliest and latest fragments must update their archived lines in place.
        store.ingest(.init(id: "t0-a", speaker: .them, text: "Revised 0 part A", startMS: 0, endMS: 500, receivedAt: at))
        store.ingest(.init(id: "t1999-b", speaker: .you, text: " revised B",
                           startMS: 1999 * 4_000 + 700, endMS: 1999 * 4_000 + 1_200, receivedAt: at.addingTimeInterval(1999.5)))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 2.0, "4,000-fragment ingestion regressed toward O(N^2): \(elapsed)s")
        XCTAssertEqual(store.archivedLines.count, 2_000)
        XCTAssertEqual(store.lines.count, Config.transcriptLineLimit)
        XCTAssertEqual(store.archivedLines.first?.content, "Revised 0 part A part B")
        XCTAssertEqual(store.archivedLines.last?.content, "Turn 1999 part A revised B")
        XCTAssertEqual(store.lines.last?.content, "Turn 1999 part A revised B")
        XCTAssertEqual(store.fragmentRevisions.count, 4_002)
        let saved = store.archiveSnapshot(since: at)
        XCTAssertEqual(saved.count, 2_000)
        XCTAssertEqual(saved.first?.fragmentIDs, ["t0-a", "t0-b"])
        XCTAssertEqual(saved.first?.content, "Revised 0 part A part B")
        // Verify clear() resets O(1) index and revision caches cleanly.
        store.clear()
        XCTAssertTrue(store.archivedLines.isEmpty)
        XCTAssertTrue(store.fragmentRevisions.isEmpty)
        store.ingest(.init(id: "t0-a", speaker: .them, text: "Turn 0 part A", startMS: 0, endMS: 500, receivedAt: at))
        XCTAssertEqual(store.archivedLines.count, 1)
        XCTAssertEqual(store.fragmentRevisions.count, 1)
    }
    func testConversationStateBoundedHistoryAndInterveningCandidateParity() {
        var state = ConversationState()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<2_601 {
            let speaker: Speaker = i.isMultiple(of: 2) ? .them : .you
            let accepted = state.append(.init(id: "h\(i)", speaker: speaker, text: "History turn \(i) with enough words.",
                                              startMS: i * 2_000, endMS: i * 2_000 + 800,
                                              receivedAt: base.addingTimeInterval(Double(i))))
            XCTAssertTrue(accepted)
        }
        XCTAssertEqual(state.fragments.count, 2_400)
        XCTAssertEqual(state.fragments.first?.id, "h201")
        // Retained ID rejects identical duplicate and accepts a valid text revision.
        XCTAssertFalse(state.append(.init(id: "h2600", speaker: .them, text: "History turn 2600 with enough words.",
                                          startMS: 2_600 * 2_000, endMS: 2_600 * 2_000 + 800,
                                          receivedAt: base.addingTimeInterval(2_600))))
        XCTAssertTrue(state.append(.init(id: "h2600", speaker: .them, text: "Revised history turn 2600.",
                                         startMS: 2_600 * 2_000, endMS: 2_600 * 2_000 + 900,
                                         receivedAt: base.addingTimeInterval(2_600))))
        XCTAssertEqual(state.fragments.last?.text, "Revised history turn 2600.")
        // Evicted ID was removed from seenEventIDs, so reusing it appends normally.
        XCTAssertTrue(state.append(.init(id: "h0", speaker: .you, text: "Reused evicted ID.",
                                         startMS: 2_601 * 2_000, endMS: 2_601 * 2_000 + 500,
                                         receivedAt: base.addingTimeInterval(2_601))))

        // Intervening opposite-speaker turn keeps a repeated question separate while adjacent repeat collapses.
        let tailBaseMS = 6_000_000
        let tailAt = base.addingTimeInterval(3_000)
        let tailFragments: [TranscriptFragment] = [
            .init(id: "q1", speaker: .them, text: "What is the cache hit rate?", startMS: tailBaseMS, endMS: tailBaseMS + 500, receivedAt: tailAt),
            .init(id: "a1", speaker: .you, text: "Let me check that metric.", startMS: tailBaseMS + 600, endMS: tailBaseMS + 900, receivedAt: tailAt.addingTimeInterval(0.5)),
            .init(id: "q2", speaker: .them, text: " What is the cache hit rate?", startMS: tailBaseMS + 1_000, endMS: tailBaseMS + 1_500, receivedAt: tailAt.addingTimeInterval(1.0)),
            .init(id: "q3", speaker: .them, text: " What is the cache hit rate?", startMS: tailBaseMS + 1_600, endMS: tailBaseMS + 2_100, receivedAt: tailAt.addingTimeInterval(1.5))
        ]
        var small = ConversationState()
        for fragment in tailFragments {
            XCTAssertTrue(state.append(fragment))
            XCTAssertTrue(small.append(fragment))
        }
        let expected = small.candidate(speaker: .them, now: tailAt.addingTimeInterval(2), cooldown: 0, force: true)
        XCTAssertEqual(expected, "What is the cache hit rate? What is the cache hit rate?")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<50 {
            let actual = state.candidate(speaker: .them, now: tailAt.addingTimeInterval(2), cooldown: 0, force: true)
            XCTAssertEqual(actual, expected)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0, "candidate() regressed to scanning full history")
    }
    func testCaptureDiagnosticsFlushAndWatchdogOffMainStallCallback() {
        XCTAssertTrue(CaptureDiagnostics.flush(timeout: 0.5))

        final class StallProbe: @unchecked Sendable {
            let lock = NSLock()
            var mainUnblocked = false
            var fulfilled = false
            var sawMainThreadCallback = false
            var sawLateOffMainCallback = false
            var lastStallMS = 0
            var lastLineCount = 0
            let lateReported: XCTestExpectation
            init(_ expectation: XCTestExpectation) { self.lateReported = expectation }
        }

        let probe = StallProbe(expectation(description: "Watchdog reports late stall off main thread"))
        let watchdog = MainThreadWatchdog(intervalSeconds: 0.04, thresholdSeconds: 0.06, cooldownSeconds: 0.0) { ms, state in
            let isMain = Thread.isMainThread
            var shouldFulfill = false
            probe.lock.withLock {
                if isMain { probe.sawMainThreadCallback = true }
                probe.lastStallMS = ms
                probe.lastLineCount = state.transcriptLineCount
                if probe.mainUnblocked && !probe.fulfilled {
                    probe.fulfilled = true
                    probe.sawLateOffMainCallback = !isMain
                    shouldFulfill = true
                }
            }
            if shouldFulfill { probe.lateReported.fulfill() }
        }
        watchdog.updateState(.init(isRunning: true, isTransitioning: false, answerIsRunning: false, transcriptLineCount: 7))
        watchdog.start()
        defer { watchdog.stop() }

        // Block the main thread long enough for the timer (up to 200ms leeway) to queue a main ping
        // and exceed thresholdSeconds before the main run loop drains it.
        Thread.sleep(forTimeInterval: 0.38)
        probe.lock.withLock { probe.mainUnblocked = true }

        wait(for: [probe.lateReported], timeout: 2.0)
        watchdog.stop()
        probe.lock.withLock {
            XCTAssertFalse(probe.sawMainThreadCallback, "MainThreadWatchdog must never invoke onStall on the main thread")
            XCTAssertTrue(probe.sawLateOffMainCallback, "Expected late stall callback off the main thread")
            XCTAssertGreaterThanOrEqual(probe.lastStallMS, 60)
            XCTAssertEqual(probe.lastLineCount, 7)
        }
    }

    @MainActor func testAsyncSessionSaveFailureRetainsSnapshotBlocksResetRetriesOnceAndSeparatesDraftFailure() async throws {
        let root = try directory()
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsDir.path) }

        let suite = "HistoryAsyncDurability-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let app = AppCoordinator(mock: true, mockReasoning: TitleProvider(value: "Durable response"),
                                 emitMockConversation: false, mockDefaults: defaults,
                                 sessionStoreRoot: sessionsDir, sessionAsyncIO: true)
        app.settings.automaticSuggestions = false

        // Part 1: Real JSON write failure on asyncIO queue retains snapshot, blocks reset/start,
        // and retrying after storage recovers creates exactly ONE history record.
        await app.start()
        app.transcript.commit("Critical interview question that must not be lost", speaker: .them)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessionsDir.path)

        await app.stop()
        XCTAssertTrue(app.hasPendingUnsavedSession, "Failed JSON write must retain unsaved session state")
        XCTAssertTrue(app.sessions.sessions.isEmpty, "Failed JSON write must not publish a fake saved record")
        XCTAssertTrue(app.transcript.lines.contains(where: { $0.content.contains("Critical interview question") }))

        // Reset and starting next session must remain blocked while storage still fails.
        await app.resetConversation()
        XCTAssertTrue(app.hasPendingUnsavedSession, "resetConversation() must not discard an unsaved session")
        XCTAssertTrue(app.transcript.lines.contains(where: { $0.content.contains("Critical interview question") }))

        await app.start()
        XCTAssertFalse(app.isRunning, "start() must not begin a new session before the failed snapshot is saved")
        XCTAssertTrue(app.hasPendingUnsavedSession)

        // Restore storage permissions and retry saving.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsDir.path)
        let savedFirst = await app.retrySaveSession()
        XCTAssertTrue(savedFirst, "Retry must persist the retained snapshot once storage recovers")
        XCTAssertFalse(app.hasPendingUnsavedSession)
        XCTAssertEqual(app.sessions.sessions.count, 1)

        // Repeated retry must be idempotent and never create a duplicate record.
        let savedSecond = await app.retrySaveSession()
        XCTAssertTrue(savedSecond)
        XCTAssertEqual(app.sessions.sessions.count, 1)

        await app.sessions.flush(timeout: 2.0)
        let reloadedAfterRetry = SessionStore(root: sessionsDir, asyncIO: false)
        XCTAssertEqual(reloadedAfterRetry.sessions.count, 1, "Disk must contain exactly one persisted history record")
        XCTAssertEqual(reloadedAfterRetry.sessions.first?.lines.first?.content, "Critical interview question that must not be lost")

        // Part 2: JSON saved OK but TXT draft export fails -> handled separately as warning;
        // session IS durably saved, reset succeeds, and no duplicate is created.
        app.sessions.testDraftWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        await app.start()
        XCTAssertTrue(app.isRunning)
        app.transcript.commit("JSON persisted while TXT draft failed", speaker: .them)
        await app.stop()

        XCTAssertFalse(app.hasPendingUnsavedSession, "TXT draft export failure must not treat a persisted JSON session as unsaved")
        XCTAssertEqual(app.sessions.sessions.count, 2)
        XCTAssertTrue(app.sessions.lastDraftWarning?.contains("transcript draft could not be written") == true)
        XCTAssertTrue(app.statusMessage.contains("transcript draft could not be written"))

        // Reset must succeed cleanly without duplicating the saved session.
        await app.resetConversation()
        XCTAssertTrue(app.transcript.lines.isEmpty)
        XCTAssertEqual(app.sessions.sessions.count, 2)

        await app.sessions.flush(timeout: 2.0)
        let reloadedFinal = SessionStore(root: sessionsDir, asyncIO: false)
        XCTAssertEqual(reloadedFinal.sessions.count, 2)
        XCTAssertTrue(reloadedFinal.sessions.contains(where: { $0.lines.first?.content == "JSON persisted while TXT draft failed" }))

        await app.shutdown()
    }
}

final class AnswerEmphasisTests: XCTestCase {
    func testCompleteEmphasisAndUnicode() {
        let text = AnswerEmphasis.parsed("延迟从 **820 毫秒降到 310 毫秒**，准确率 **97.8%**。")
        XCTAssertEqual(String(text.characters), "延迟从 820 毫秒降到 310 毫秒，准确率 97.8%。")
        XCTAssertEqual(text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.count, 2)
    }
    func testPartialStreamingDelimitersAndParagraphs() {
        XCTAssertEqual(AnswerEmphasis.plainText("采用 **early-exit", streaming: true), "采用 early-exit")
        XCTAssertEqual(AnswerEmphasis.plainText("采用 **early-exit*", streaming: true), "采用 early-exit")
        XCTAssertEqual(AnswerEmphasis.plainText("**方法**\n\n**结果**"), "方法\n\n结果")
        XCTAssertEqual(AnswerEmphasis.plainText("[S1] 97.8%"), "[S1] 97.8%")
    }
}

extension HistoryTests {
    @MainActor func testManualFollowUpAfterArchiveFailureSurvivesReset() async throws {
        let dir = try directory()
        let app = AppCoordinator(mock: true, mockReasoning: TitleProvider(value: "Recovered answer"), emitMockConversation: false, sessionStoreRoot: dir, sessionAsyncIO: true)
        app.settings.automaticSuggestions = false
        await app.start()
        app.transcript.commit("Existing transcript", speaker: .them)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        await app.stop()
        XCTAssertTrue(app.hasPendingUnsavedSession)
        app.askText("Follow-up after stop")
        for _ in 0..<200 where app.answerIsRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(app.answers.contains { $0.store.question == "Follow-up after stop" && $0.store.text.contains("Recovered answer") })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        await app.resetConversation()
        XCTAssertFalse(app.hasPendingUnsavedSession)
        let history = SessionStore(root: dir).sessions
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.flatMap { $0.answers ?? [] }.map(\.question), ["Follow-up after stop"])
    }

    @MainActor func testOverlappingIdleResetsArchiveOnce() async throws {
        let dir = try directory()
        let app = AppCoordinator(mock: true, mockReasoning: TitleProvider(value: "Answer"), emitMockConversation: false, sessionStoreRoot: dir, sessionAsyncIO: true)
        app.askText("One manual session")
        for _ in 0..<200 where app.answerIsRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        app.sessions.testDraftWriter = { _, _ in Thread.sleep(forTimeInterval: 0.2) }
        let first = Task { await app.resetConversation() }
        for _ in 0..<100 where !app.sessions.isSaving { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(app.sessions.isSaving)
        await app.resetConversation()
        await first.value
        XCTAssertEqual(SessionStore(root: dir).sessions.count, 1)
    }
}
