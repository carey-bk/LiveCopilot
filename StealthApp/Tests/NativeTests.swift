import XCTest
import Combine
import SwiftUI
import Carbon.HIToolbox
import Security
import UniformTypeIdentifiers
@testable import LiveCopilot

final class NativeTests: XCTestCase {
    @MainActor func testResetDiscardsInFlightAnswerAndReturnsToEmptyState() async throws {
        let coordinator = AppCoordinator(mock: true)
        coordinator.settings.overlayAutoHeight = false
        coordinator.transcript.setPartial("Old preview", speaker: .them)
        let firstDelta = expectation(description: "answer is streaming")
        let subscription = coordinator.suggestion.$text.filter { !$0.isEmpty }.prefix(1).sink { _ in firstDelta.fulfill() }
        coordinator.askText("An obsolete synthetic request")
        await fulfillment(of: [firstDelta], timeout: 5)
        subscription.cancel()
        let generation = coordinator.conversationGeneration
        await coordinator.resetConversation()
        XCTAssertNotEqual(generation, coordinator.conversationGeneration)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(coordinator.transcript.hasContent)
        XCTAssertTrue(coordinator.suggestion.text.isEmpty)
        XCTAssertTrue(coordinator.suggestion.question.isEmpty)
        XCTAssertTrue(coordinator.suggestion.sources.isEmpty)
        XCTAssertNil(coordinator.suggestion.firstTextMS)
        XCTAssertFalse(coordinator.suggestion.isLoading)
        XCTAssertTrue(coordinator.settings.overlayAutoHeight)
        coordinator.requestSuggestion()
        XCTAssertEqual(coordinator.statusMessage, "No conversation yet. Type a question below to ask directly.")
        let noStaleAnswer = expectation(description: "no obsolete delta after reset")
        noStaleAnswer.isInverted = true
        let afterReset = coordinator.suggestion.$text.filter { !$0.isEmpty }.sink { _ in noStaleAnswer.fulfill() }
        await fulfillment(of: [noStaleAnswer], timeout: 0.8)
        afterReset.cancel()
        await coordinator.shutdown()
    }
    @MainActor func testResetWhileListeningRestartsFreshAndAllowsSameQuestion() async throws {
        let coordinator = AppCoordinator(mock: true)
        coordinator.settings.automaticSuggestions = true
        let first = expectation(description: "first conversation answer")
        let firstSub = coordinator.suggestion.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in first.fulfill() }
        await coordinator.start()
        await fulfillment(of: [first], timeout: 10)
        firstSub.cancel()
        let oldRow = try XCTUnwrap(coordinator.transcript.lines.first?.id)
        await coordinator.resetConversation()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(coordinator.transcript.hasContent)
        XCTAssertTrue(coordinator.suggestion.text.isEmpty)
        let second = expectation(description: "same question in a new conversation is not suppressed")
        let secondSub = coordinator.suggestion.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in second.fulfill() }
        await fulfillment(of: [second], timeout: 10)
        secondSub.cancel()
        XCTAssertEqual(coordinator.transcript.lines.count, 1)
        XCTAssertNotEqual(coordinator.transcript.lines.first?.id, oldRow)
        XCTAssertTrue(coordinator.suggestion.text.contains("Mock preview"))
        await coordinator.shutdown()
    }
    func testCredentialMigrationIsSilentUntilExplicitAuthorizationAndPersists() async throws {
        let suite = "LiveCopilot-Vault-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = FixtureCredentials()
        try storage.save("legacy-fixture", service: CredentialReference.live.service, account: CredentialReference.live.account, interactive: true)
        storage.requireLegacyAuthorization = true
        let vault = CredentialVault(storage: storage, defaults: defaults, environmentKey: nil)
        let initial = try await vault.read(.live)
        XCTAssertTrue(initial.needsAuthorization)
        XCTAssertNil(initial.key)
        XCTAssertEqual(storage.interactiveReads, 0)
        let authorized = try await vault.read(.live, interactive: true)
        XCTAssertEqual(authorized.key, "legacy-fixture")
        let reads = storage.legacyReads
        let restarted = CredentialVault(storage: storage, defaults: defaults, environmentKey: nil)
        let recovered = try await restarted.read(.live)
        XCTAssertEqual(recovered.key, "legacy-fixture")
        XCTAssertEqual(storage.legacyReads, reads, "restart must use the app-owned copy")
        try await restarted.save("replacement-fixture", for: .live)
        let replacement = try await vault.read(.live)
        XCTAssertEqual(replacement.key, "replacement-fixture")
        try await vault.remove(.live)
        let removed = try await restarted.read(.live)
        XCTAssertNil(removed.key, "legacy key must not reappear after removal")
        XCTAssertEqual(storage.legacyReads, reads)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("fixture") })
    }
    func testManagedCredentialsRemainProviderAndEndpointScoped() async throws {
        let suite = "LiveCopilot-Vault-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CredentialVault(storage: FixtureCredentials(), defaults: defaults, environmentKey: nil)
        let a = CredentialReference(service: "Compatible", accountSuffix: "|https://a.example/v1")
        let b = CredentialReference(service: "Compatible", accountSuffix: "|https://b.example/v1")
        try await vault.save("a-fixture", for: a)
        try await vault.save("deepseek-fixture", for: .deepSeek)
        let missing = try await vault.read(b), deepSeek = try await vault.read(.deepSeek)
        XCTAssertNil(missing.key)
        XCTAssertEqual(deepSeek.key, "deepseek-fixture")
        try await vault.remove(a)
        let retained = try await vault.read(.deepSeek)
        XCTAssertEqual(retained.key, "deepseek-fixture")
    }
    func testSilentNativeKeychainReadRestoresInteractionPolicy() throws {
        let service = "LiveCopilot-Silent-Test-" + UUID().uuidString
        defer { try? KeychainStore.clear(service: service, account: "fixture") }
        try KeychainStore.save("not-a-real-api-key", service: service, account: "fixture")
        var before: DarwinBoolean = false, after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
        XCTAssertEqual(try KeychainStore.read(service: service, account: "fixture", interactive: false), "not-a-real-api-key")
        XCTAssertNil(try KeychainStore.read(service: service, account: "missing", interactive: false))
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(before.boolValue, after.boolValue)
    }
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
        func key(_ code: Int, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = [.control, .option]) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: UInt16(code))!
        }
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_Space)))
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_Space, repeatKey: true)))
        XCTAssertEqual(replies, 1)
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_H, modifiers: .option)))
        XCTAssertEqual(toggles, 1)
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_X, modifiers: .option)))
    }
    @MainActor func testDisabledToolShortcutsPassThroughAndCanBeReenabled() {
        let suite = "LiveCopilot-Tools-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(), store = HotkeyStore(defaults: defaults)
        var received: [SuggestionMode] = []
        manager.register(store: store, onSuggest: { received.append($0) }, onToggleOverlay: {})
        defer { manager.unregisterAll() }
        func key(_ code: Int) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        manager.setEnabledModes([.reply])
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_S)))
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_X)))
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_Space)))
        manager.setEnabledModes([.reply, .followUp])
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_S)))
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_X)))
        manager.setEnabledModes(SuggestionMode.allCases)
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_S)))
        XCTAssertEqual(received, [.reply, .followUp, .recap])
    }
    @MainActor func testNewShortcutDefaultsPreserveCustomBindingsAndResetIndividually() {
        let suite = "LiveCopilot-Defaults-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HotkeyStore(defaults: defaults)
        XCTAssertEqual(store.combo(for: .reply).display, "⌃⌥Space")
        XCTAssertEqual(store.combo(for: .recap).keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(store.combo(for: .followUp).keyCode, UInt32(kVK_ANSI_X))
        let custom = HotkeyCombo(keyCode: UInt32(kVK_F8), modifiers: UInt32(controlKey | shiftKey))
        store.set(custom, for: .reply)
        let restarted = HotkeyStore(defaults: defaults)
        XCTAssertEqual(restarted.combo(for: .reply), custom)
        restarted.reset(.recap)
        XCTAssertEqual(restarted.combo(for: .reply), custom)
        restarted.reset(.reply)
        XCTAssertEqual(restarted.combo(for: .reply), HotkeyStore.defaultCombos[.reply])
    }
    @MainActor func testDisabledToolCannotStartOrContinueAnAnswer() async throws {
        let coordinator = AppCoordinator(mock: true)
        let original = coordinator.settings
        defer { coordinator.settings = original }
        coordinator.settings.automaticSuggestions = false
        coordinator.settings.recapEnabled = false
        let status = coordinator.statusMessage
        coordinator.requestSuggestion(mode: .recap)
        XCTAssertEqual(coordinator.statusMessage, status, "disabled tool must not enter the request pipeline")
        let transcribed = expectation(description: "mock conversation ready")
        let subscription = coordinator.transcript.$lines.filter { !$0.isEmpty }.prefix(1).sink { _ in transcribed.fulfill() }
        await coordinator.start()
        await fulfillment(of: [transcribed], timeout: 8)
        subscription.cancel()
        coordinator.settings.recapEnabled = true
        coordinator.requestSuggestion(mode: .recap)
        XCTAssertTrue(coordinator.suggestion.isLoading)
        coordinator.settings.recapEnabled = false
        XCTAssertFalse(coordinator.suggestion.isLoading)
        await coordinator.shutdown()
    }
    func testFinderDropDecodingValidationAndLocalIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("会议 说明.TXT"), b = root.appendingPathComponent("notes.md")
        try "Meeting decision: benchmark the local speech model before release.".write(to: a, atomically: true, encoding: .utf8)
        try "# Next steps\nCompare transcript latency and document supported languages.".write(to: b, atomically: true, encoding: .utf8)
        let urls = try await DocumentImport.load([
            NSItemProvider(item: a as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: b.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: a as NSURL, typeIdentifier: UTType.fileURL.identifier)
        ])
        XCTAssertEqual(urls, [a, b])
        XCTAssertThrowsError(try DocumentImport.validate([a, root]))
        XCTAssertThrowsError(try DocumentImport.validate([URL(string: "https://example.com/notes.txt")!]))
        let invalid = root.appendingPathComponent("image.png")
        try Data([0]).write(to: invalid)
        XCTAssertThrowsError(try DocumentImport.validate([invalid]))
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        for url in urls { _ = try await index.importDocument(url, provider: MockEmbeddingProvider()) }
        let documents = try await index.documents()
        XCTAssertEqual(Set(documents.map(\.name)), Set([a.lastPathComponent, b.lastPathComponent]))
        XCTAssertTrue(documents.allSatisfy { $0.status == "Ready" && $0.chunkCount > 0 })
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
    @MainActor func testOverlayHostingTracksRapidContentAndManualBounds() async throws {
        let coordinator = AppCoordinator(mock: true)
        coordinator.settings.overlayEdgeHide = false
        var panel: OverlayWindow?
        let view = OverlayView(coordinator: coordinator, onContentHeight: { height in
            DispatchQueue.main.async { panel?.contentHeightChanged(height) }
        }, onMinimumHeight: { height in
            DispatchQueue.main.async { panel?.minimumContentHeightChanged(height) }
        })
        panel = OverlayWindow(rootView: view)
        let window = try XCTUnwrap(panel)
        defer { window.close(); panel = nil }
        window.configure(autoHeight: true, edgeHide: false)
        coordinator.isRunning = true
        coordinator.transcript.setPartial(String(repeating: "Synthetic streaming captions. ", count: 50), speaker: .them)
        coordinator.suggestion.appendDelta(String(repeating: "A long synthetic answer for layout validation. ", count: 100))
        try await Task.sleep(for: .milliseconds(450))
        window.contentView?.layoutSubtreeIfNeeded()
        let border = try XCTUnwrap(window.contentView as? OverlayResizeView)
        let hosting = try XCTUnwrap(border.subviews.first)
        XCTAssertEqual(hosting.frame.size, border.bounds.size)
        XCTAssertEqual(border.layer?.cornerRadius, 16)
        XCTAssertTrue(border.layer?.masksToBounds == true)
        XCTAssertGreaterThan(window.minSize.height, 240, "live controls need a dynamic minimum")
        XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 410, height: window.minSize.height), display: true)
        window.userFinishedResize(vertical: true)
        coordinator.transcript.setPartial("short preview", speaker: .them)
        coordinator.isRunning = false
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.size, border.bounds.size)
        XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        await coordinator.shutdown()
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

/// Synthetic storage only. Never reads the user's actual credentials.
private final class FixtureCredentials: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    var requireLegacyAuthorization = false
    private(set) var interactiveReads = 0
    private(set) var legacyReads = 0
    func read(service: String, account: String, interactive: Bool) throws -> String? {
        try lock.withLock {
            if interactive { interactiveReads += 1 }
            if service != CredentialVault.service {
                legacyReads += 1
                if requireLegacyAuthorization && !interactive { throw KeychainAccessError(status: errSecInteractionNotAllowed) }
            }
            return keys[service + "|" + account]
        }
    }
    func save(_ key: String, service: String, account: String, interactive: Bool) throws {
        lock.withLock { keys[service + "|" + account] = key }
    }
    func clear(service: String, account: String) throws { _ = lock.withLock { keys.removeValue(forKey: service + "|" + account) } }
}
