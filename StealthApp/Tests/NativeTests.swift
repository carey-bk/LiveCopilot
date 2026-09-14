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
