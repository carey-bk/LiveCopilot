import XCTest
import Combine
import SwiftUI
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
}
