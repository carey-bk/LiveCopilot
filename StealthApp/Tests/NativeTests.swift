import XCTest
import Combine
import SwiftUI
import Carbon.HIToolbox
@testable import LiveCopilot

final class NativeTests: XCTestCase {
    func testCoreAcceptanceChecks() async throws {
        let checks = try await CoreChecks.run()
        XCTAssertGreaterThanOrEqual(checks.count, 25)
    }
    @MainActor func testManualQueryWithoutListeningAndCancellation() async throws {
        let coordinator = AppCoordinator(mock: true)
        XCTAssertFalse(coordinator.isRunning)
        let finished = expectation(description: "manual stream completes")
        var didStart = false
        let subscription = coordinator.suggestion.$isLoading.sink { loading in
            if loading { didStart = true }
            if didStart && !loading { finished.fulfill() }
        }
        coordinator.askText("Explain the latency tradeoff.")
        await fulfillment(of: [finished], timeout: 8)
        subscription.cancel()
        XCTAssertNil(coordinator.suggestion.error)
        XCTAssertTrue(coordinator.suggestion.text.contains("Mock preview"))
        XCTAssertFalse(coordinator.isRunning)
        coordinator.askText("An obsolete request")
        coordinator.askText("The latest request")
        let latest = expectation(description: "latest request completes")
        let latestSubscription = coordinator.suggestion.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in latest.fulfill() }
        await fulfillment(of: [latest], timeout: 8)
        latestSubscription.cancel()
        XCTAssertTrue(coordinator.suggestion.text.contains("The latest request"))
        XCTAssertFalse(coordinator.suggestion.text.contains("An obsolete request"))
        coordinator.askText("Cancel this request")
        coordinator.cancelAnswer()
        XCTAssertFalse(coordinator.suggestion.isLoading)
    }
    @MainActor func testLiveMockDelegationKeepsListeningWhileReasoningRuns() async throws {
        let coordinator = AppCoordinator(mock: true)
        coordinator.settings.automaticSuggestions = true
        let completed = expectation(description: "automatic answer completes")
        var started = false
        let subscription = coordinator.suggestion.$isLoading.sink { loading in
            if loading { started = true }
            if started && !loading { completed.fulfill() }
        }
        await coordinator.start()
        XCTAssertTrue(coordinator.isRunning)
        await fulfillment(of: [completed], timeout: 10)
        subscription.cancel()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertTrue(coordinator.suggestion.question.contains("latency"))
        await coordinator.stop()
        XCTAssertFalse(coordinator.isRunning)
    }
    @MainActor func testTranscriptPreservesRawFragmentTextAndStableRows() {
        let store = TranscriptStore(), now = Date()
        store.ingest(.init(id: "a", speaker: .them, text: "What is", startMS: 0, endMS: 500, receivedAt: now))
        let row = store.lines.first!.id
        store.ingest(.init(id: "b", speaker: .them, text: " the latency?", startMS: 500, endMS: 1000, receivedAt: now))
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines[0].id, row)
        XCTAssertEqual(store.lines[0].content, "What is the latency?")
        store.ingest(.init(id: "c", speaker: .you, text: "42 ms", startMS: 600, endMS: 1100, receivedAt: now))
        XCTAssertEqual(store.lines[1].speaker, .you)
    }
    @MainActor func testStreamingPreviewsReplaceWithoutEnteringConversationContext() {
        let store = TranscriptStore()
        store.setPartial("Why did we", speaker: .them)
        store.setPartial("Why did we choose method B", speaker: .them)
        store.setPartial("我在听", speaker: .you)
        XCTAssertEqual(store.partialThem, "Why did we choose method B")
        XCTAssertEqual(store.partialYou, "我在听")
        XCTAssertTrue(store.hasContent) // Empty compact window must grow for previews too.
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertTrue(store.recentContext().isEmpty)
        store.clearPartial(.them)
        store.ingest(.init(id: "stable", speaker: .them, text: "Why did we choose method B?", startMS: 0, endMS: 3000, receivedAt: Date()))
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines[0].content, "Why did we choose method B?")
        XCTAssertTrue(store.partialThem.isEmpty)
        XCTAssertFalse(store.partialYou.isEmpty)
        store.clear()
        XCTAssertFalse(store.hasContent)
    }
    @MainActor func testShutdownCancelsAnswerAndPreventsSessionRestart() async {
        let coordinator = AppCoordinator(mock: true)
        await coordinator.start()
        coordinator.askText("Synthetic question during shutdown")
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertTrue(coordinator.suggestion.isLoading)
        await coordinator.shutdown()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(coordinator.suggestion.isLoading)
        await coordinator.start()
        XCTAssertFalse(coordinator.isRunning)
    }
    @MainActor func testFocusedOverlayShortcutsConsumeMatchesOnly() {
        let suite = "LiveCopilot-Hotkey-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(), store = HotkeyStore(defaults: defaults)
        var replies = 0, toggles = 0
        manager.register(store: store, onSuggest: { if $0 == .reply { replies += 1 } }, onToggleOverlay: { toggles += 1 })
        defer { manager.unregisterAll() }
        func key(_ code: Int, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: UInt16(code))!
        }
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_Space)))
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_Space, repeatKey: true)))
        XCTAssertEqual(replies, 1)
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_H)))
        XCTAssertEqual(toggles, 1)
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_X)))
    }
    @MainActor func testOverlayNativeProperties() {
        let panel = OverlayWindow(rootView: Text("Synthetic overlay check"))
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.close()
    }
    @MainActor func testResizeBorderLeavesContentInteractive() {
        let child = NSView(), border = OverlayResizeView(content: NSView())
        border.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        border.addSubview(child)
        child.frame = NSRect(x: 80, y: 200, width: 200, height: 200)
        XCTAssertTrue(border.hitTest(NSPoint(x: 9, y: 300)) === border)
        XCTAssertTrue(border.hitTest(NSPoint(x: 458, y: 22)) === border)
        XCTAssertTrue(border.hitTest(NSPoint(x: 180, y: 300)) === child)
        XCTAssertEqual(border.edges(at: NSPoint(x: 22, y: 22)), [.left, .bottom])
        XCTAssertEqual(border.edges(at: NSPoint(x: 22, y: 618)), [.left, .top])
        XCTAssertEqual(border.edges(at: NSPoint(x: 458, y: 618)), [.right, .top])
    }
    @MainActor func testHiddenOverlayCanGrowWithoutRevealingAndPinRestoresIt() async throws {
        let panel = OverlayWindow(rootView: Text("Synthetic overlay check"))
        defer { panel.close() }
        panel.configure(autoHeight: true, edgeHide: true)
        XCTAssertTrue(panel.edgeHidden)
        XCTAssertFalse(panel.isVisible)
        let top = panel.frame.maxY, width = panel.frame.width
        panel.contentHeightChanged(570)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(panel.frame.height, 570, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(panel.frame.width, width)
        panel.showForAnswer()
        XCTAssertFalse(panel.isVisible, "automatic answers must respect edge hiding")
        panel.showForAnswer(automatic: false)
        XCTAssertTrue(panel.isVisible, "explicit keyboard/menu requests must remain discoverable")
        panel.configure(autoHeight: true, edgeHide: false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.edgeHidden)
    }
    @MainActor func testManualVerticalResizeOverridesPendingAutomaticGrowth() async throws {
        let panel = OverlayWindow(rootView: Text("Synthetic overlay check"))
        defer { panel.close() }
        var notified = false
        panel.onManualHeight = { notified = true }
        panel.contentHeightChanged(700)
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: 510, height: 410), display: false)
        panel.userFinishedResize(vertical: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(notified)
        XCTAssertFalse(panel.autoHeight)
        XCTAssertEqual(panel.frame.height, 410)
        XCTAssertEqual(panel.frame.width, 510)
    }
    @MainActor func testEdgePointerRevealsActualPanelAndRespectsInteractions() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = OverlayWindow(rootView: Text("Synthetic edge check"))
        defer { panel.close() }
        panel.configure(autoHeight: true, edgeHide: true)
        let point = NSPoint(x: screen.frame.maxX - 1, y: screen.visibleFrame.midY)
        let now = ProcessInfo.processInfo.systemUptime
        panel.updatePointer(point, now: now, interacting: false)
        XCTAssertFalse(panel.isVisible)
        panel.updatePointer(point, now: now + 0.2, interacting: false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.edgeHidden)
        let outside = NSPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.midY)
        panel.updatePointer(outside, now: now + 3, interacting: true)
        panel.updatePointer(outside, now: now + 5, interacting: true)
        XCTAssertFalse(panel.edgeHidden, "window hid during editing or dragging")
        panel.updatePointer(outside, now: now + 6, interacting: false)
        panel.updatePointer(outside, now: now + 7, interacting: false)
        XCTAssertTrue(panel.edgeHidden)
        panel.configure(autoHeight: true, edgeHide: false)
        panel.updatePointer(outside, now: now + 20, interacting: false)
        XCTAssertTrue(panel.isVisible, "pinned panel still responded to edge hiding")
    }
    @MainActor func testResizeAllDirectionsPreserveOppositeEdgesAndClamp() {
        let original = NSRect(x: 100, y: 200, width: 480, height: 640)
        let minimum = NSSize(width: 400, height: 440), maximum = NSSize(width: 700, height: 1000)
        let combinations: [OverlayResizeView.Edge] = [.left, .right, .top, .bottom,
            [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]]
        for edges in combinations {
            for delta in [NSPoint(x: 80, y: -60), NSPoint(x: -2000, y: 2000), NSPoint(x: 2000, y: -2000)] {
                let result = OverlayResizeView.resized(original, by: delta, edges: edges, minimum: minimum, maximum: maximum)
                XCTAssertTrue((400...700).contains(result.width))
                XCTAssertTrue((440...1000).contains(result.height))
                if edges.contains(.left) { XCTAssertEqual(result.maxX, original.maxX) }
                else { XCTAssertEqual(result.minX, original.minX) }
                if edges.contains(.bottom) { XCTAssertEqual(result.maxY, original.maxY) }
                else { XCTAssertEqual(result.minY, original.minY) }
            }
        }
        let grown = OverlayResizeView.resized(original, by: NSPoint(x: 80, y: -60), edges: [.bottom, .right], minimum: minimum, maximum: maximum)
        XCTAssertEqual(grown.size, NSSize(width: 560, height: 700))
    }
    func testKeychainRoundTripInIsolatedItem() throws {
        let service = "LiveCopilot-Test-" + UUID().uuidString
        defer { try? KeychainStore.clear(service: service, account: "test") }
        try KeychainStore.save("non-secret-fixture", service: service, account: "test")
        XCTAssertEqual(try KeychainStore.read(service: service, account: "test"), "non-secret-fixture")
        try KeychainStore.save("updated-fixture", service: service, account: "test")
        XCTAssertEqual(try KeychainStore.read(service: service, account: "test"), "updated-fixture")
        try KeychainStore.clear(service: service, account: "test")
        XCTAssertNil(try KeychainStore.read(service: service, account: "test"))
    }
    func testChatCompletionsThroughURLSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = ChatCompletionsProvider(key: "test-only", model: "fixture", endpoint: URL(string: "https://fixture.example/chat/completions")!, transport: URLSessionTransport(session: session))
        let answer = AnswerRequest(query: .formulate(question: "Synthetic latency?", context: ""), conversation: "", scenario: .meeting, sources: [])
        var text = ""
        for try await delta in provider.stream(answer) { text += delta }
        XCTAssertEqual(text, "延迟 42 毫秒 [S1]")
    }
    func testChatCompletionCancellationClosesTransport() async throws {
        let first = expectation(description: "first useful text arrived")
        let closed = expectation(description: "underlying stream cancelled")
        let transport = GatedChatTransport(onClose: { closed.fulfill() })
        let provider = ChatCompletionsProvider(key: "test-only", model: "fixture", endpoint: URL(string: "https://fixture.example/chat/completions")!, transport: transport)
        let answer = AnswerRequest(query: .formulate(question: "Cancel this synthetic stream", context: ""), conversation: "", scenario: .meeting, sources: [])
        let task = Task {
            do { for try await delta in provider.stream(answer) { if delta == "partial" { first.fulfill() } } }
            catch { }
        }
        await fulfillment(of: [first], timeout: 3)
        task.cancel()
        await fulfillment(of: [closed], timeout: 3)
        await task.value
    }
    func testSeparateCredentialDeletionPreservesLiveCredential() throws {
        let service = "LiveCopilot-Test-Isolation-" + UUID().uuidString
        defer {
            try? KeychainStore.clear(service: service, account: "live")
            try? KeychainStore.clear(service: service, account: "analysis")
        }
        try KeychainStore.save("live-fixture", service: service, account: "live")
        try KeychainStore.save("analysis-fixture", service: service, account: "analysis")
        try KeychainStore.clear(service: service, account: "analysis")
        XCTAssertEqual(try KeychainStore.read(service: service, account: "live"), "live-fixture")
        XCTAssertNil(try KeychainStore.read(service: service, account: "analysis"))
    }
    func testResponsesThroughURLSessionPreservesSSEBoundaries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAIReasoningProvider(key: "test-only", model: "fixture", transport: URLSessionTransport(session: session))
        let answer = AnswerRequest(query: .formulate(question: "Synthetic latency?", context: ""), conversation: "", scenario: .meeting, sources: [])
        var text = ""
        for try await delta in provider.stream(answer) { text += delta }
        XCTAssertEqual(text, "延迟 42 毫秒 🧪")
    }

}

/// Exercise the actual URLSession AsyncBytes transport without sending a request
/// to the network. Deliberately split UTF-8 and CRLF across separate byte loads.
private final class SyntheticSSEProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let responses = "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"延迟 42 毫秒 🧪\"}\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n"
        let chat = "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"hidden\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"延迟 42 毫秒 [S1]\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        let wire = request.url!.path.hasSuffix("chat/completions") ? chat : responses
        for byte in wire.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class GatedChatTransport: HTTPTransport, @unchecked Sendable {
    let onClose: @Sendable () -> Void
    init(onClose: @escaping @Sendable () -> Void) { self.onClose = onClose }
    func data(for request: URLRequest) async throws -> (Data, Int) { throw CancellationError() }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            c.onTermination = { [onClose] _ in onClose() }
            c.yield(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
            c.yield("")
        }
    }
}
