import XCTest
import Combine
import SwiftUI
import Carbon.HIToolbox
import Security
import UniformTypeIdentifiers
@testable import LiveCopilot

/// Deterministic state for testing restoration despite the XCTest-host sharing
/// getter peculiarity documented in the compositor acceptance report.
private final class CaptureSharingPanel: NSPanel {
    private var storedSharing: NSWindow.SharingType = .readOnly
    var testKeyWindow: Bool?
    override var isKeyWindow: Bool { testKeyWindow ?? super.isKeyWindow }
    override var sharingType: NSWindow.SharingType {
        get { storedSharing }
        set { storedSharing = newValue }
    }
    override var canBecomeKey: Bool { true }
}

final class NativeTests: XCTestCase {
    @MainActor func testAutomaticDockingDefaultsOffAndCanBeEnabledPersistently() throws {
        let suite = "LiveCopilot-Docking-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings.load(defaults: defaults)
        XCTAssertFalse(settings.overlayEdgeHide)
        settings.overlayEdgeHide = true; settings.save(defaults: defaults)
        XCTAssertTrue(AppSettings.load(defaults: defaults).overlayEdgeHide)
        let window = OverlayWindow(rootView: Text("Drag test"))
        defer { window.close() }
        window.setCaptureExcluded(false)
        window.configure(autoHeight: false, edgeHide: true)
        XCTAssertFalse(window.isMovableByWindowBackground)
        window.configure(autoHeight: false, edgeHide: false)
        XCTAssertTrue(window.isMovableByWindowBackground)
        window.setFrameOrigin(NSPoint(x: 200, y: 250))
        window.configure(autoHeight: false, edgeHide: false)
        XCTAssertEqual(window.frame.origin, NSPoint(x: 200, y: 250), "An ordinary configuration refresh must preserve the freely positioned window")
    }

    @MainActor func testProtectedOverlayUsesArrowWithoutChangingOtherWindowsOrResizeCursors() {
        let window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.orderFrontRegardless()
        var point = NSPoint(x: 100, y: 80)
        var top = window.windowNumber
        let controller = OverlayCursorProtection(window: window, pointer: { point }, topWindow: { _ in top })
        defer { controller.stop(); window.close(); NSCursor.arrow.set() }
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSCursor.iBeamCursorForVerticalLayout.set()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSCursor.resizeLeftRight.set()
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "Resizing remains discoverable")
        NSCursor.pointingHand.set()
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)
        top = window.windowNumber + 1
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "A settings/other-app window above it keeps its cursor")
        top = window.windowNumber; point = NSPoint(x: 900, y: 900)
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "Do not change text editing outside the overlay")
        point = NSPoint(x: 100, y: 80)
        controller.setEnabled(false)
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
        controller.setEnabled(true)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSCursor.iBeam.push()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSCursor.pop()
        window.orderOut(nil)
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
        window.orderFrontRegardless()
        controller.stop()
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "Closed controllers leave the cursor alone")
    }

    @MainActor func testInputCandidateProtectionRestoresStateWithoutProtectingSettings() {
        func panel() -> CaptureSharingPanel {
            let panel = CaptureSharingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            return panel
        }
        let overlay = panel(), candidate = panel(), settings = panel()
        let controller = OverlayInputCaptureProtection(overlay: overlay, candidate: { $0 === candidate })
        defer { controller.stop(); overlay.close(); candidate.close(); settings.close() }
        controller.update(windows: [overlay, candidate, settings], protectInput: true)
        XCTAssertEqual(candidate.sharingType, .none)
        XCTAssertEqual(settings.sharingType, .readOnly)
        controller.update(windows: [overlay, candidate, settings], protectInput: true)
        controller.update(windows: [overlay, candidate, settings], protectInput: false)
        XCTAssertEqual(candidate.sharingType, .readOnly, "The same candidate panel is reused for settings input")
        candidate.sharingType = .none
        controller.update(windows: [candidate], protectInput: true)
        controller.stop()
        XCTAssertEqual(candidate.sharingType, .none, "Preserve pre-existing exclusions")
    }

    @MainActor func testOrdinaryPanelIsNotMistakenForAnInputCandidate() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(OverlayInputCaptureProtection.isInputPanel(panel))
    }

    @MainActor func testVisibleCandidateKeepsProtectionUntilItLeavesScreen() {
        let overlay = CaptureSharingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let candidate = CaptureSharingPanel(contentRect: NSRect(x: 60, y: 60, width: 120, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [overlay, candidate] { window.isReleasedWhenClosed = false }
        let controller = OverlayInputCaptureProtection(overlay: overlay, candidate: { $0 === candidate })
        defer { controller.stop(); candidate.close(); overlay.close() }
        candidate.orderFrontRegardless()
        controller.update(windows: [candidate], protectInput: true)
        XCTAssertTrue(candidate.isVisible)
        controller.update(windows: [candidate], protectInput: false)
        XCTAssertEqual(candidate.sharingType, .none, "Focus loss must not expose the outgoing candidate")
        candidate.orderOut(nil)
        XCTAssertFalse(candidate.isVisible)
        XCTAssertEqual(candidate.sharingType, .readOnly, "Restore after it has left the screen")
    }

    @MainActor func testCandidateOrderingHookHandlesFirstDisplayReuseAndShutdown() {
        let overlay = CaptureSharingPanel(contentRect: NSRect(x: 40, y: 40, width: 150, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let candidate = CaptureSharingPanel(contentRect: NSRect(x: 40, y: 40, width: 120, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [overlay, candidate] { window.isReleasedWhenClosed = false }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 50))
        overlay.contentView = editor
        overlay.makeKeyAndOrderFront(nil)
        XCTAssertTrue(overlay.makeFirstResponder(editor))
        // The non-active XCTest host cannot reliably acquire the system key
        // window. Supply that input; real IME ordering is checked by the probe.
        overlay.testKeyWindow = true
        XCTAssertTrue(overlay.isKeyWindow)
        let controller = OverlayInputCaptureProtection(overlay: overlay, candidate: { $0 === candidate })
        defer { controller.stop(); candidate.close(); overlay.close() }
        // No refresh/update call before the first ordering operation.
        candidate.order(.above, relativeTo: 0)
        XCTAssertEqual(candidate.sharingType, .none)
        candidate.orderOut(nil)
        candidate.sharingType = .readOnly
        candidate.orderFrontRegardless()
        XCTAssertEqual(candidate.sharingType, .none, "Both public presentation paths are guarded")
        overlay.testKeyWindow = false
        overlay.orderOut(nil)
        XCTAssertEqual(candidate.sharingType, .none, "Still-visible old content remains protected")
        candidate.orderOut(nil)
        XCTAssertEqual(candidate.sharingType, .readOnly)
        candidate.orderFrontRegardless()
        XCTAssertEqual(candidate.sharingType, .readOnly, "A normal input owner reuses an unprotected panel")
        controller.stop()
        overlay.testKeyWindow = true
        overlay.makeKeyAndOrderFront(nil)
        candidate.orderFrontRegardless()
        XCTAssertEqual(candidate.sharingType, .readOnly, "Stopped controllers cannot change later windows")
    }

    /// Manual capture acceptance fixture, deliberately skipped in unattended runs.
    @MainActor func testManualFullOverlayCaptureRendering() async throws {
        guard ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] == "capture-render" else {
            throw XCTSkip("Opt-in manual meeting capture fixture")
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let suite = "com.livecopilot.capture-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let coordinator = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        coordinator.settings.background = .glass
        coordinator.settings.language = .simplifiedChinese
        coordinator.settings.overlayEdgeHide = false
        coordinator.settings.overlayAutoHeight = false
        coordinator.statusMessage = "完整界面对照 / 玻璃"
        let panel = OverlayWindow(rootView: OverlayView(coordinator: coordinator))
        panel.isReleasedWhenClosed = false
        defer {
            panel.stopWatching()
            panel.close()
            defaults.removePersistentDomain(forName: suite)
        }
        // Keep one small panel at the lower left so the meeting toolbar and
        // screen-share picker remain operable during manual acceptance.
        panel.configure(autoHeight: false, edgeHide: false)
        panel.setFrame(CGRect(x: screen.visibleFrame.minX + 35,
                              y: screen.visibleFrame.minY + 110,
                              width: 420, height: 315), display: true)
        panel.orderFrontRegardless()
        print("FULL_CAPTURE_RENDER_READY")
        let stop=URL(fileURLWithPath:"/tmp/livecopilot-full-render-small-stop")
        for _ in 0..<2400 {
            if FileManager.default.fileExists(atPath:stop.path) { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        withExtendedLifetime(coordinator) {}
        throw XCTSkip("Manual fixture displayed; local/recorded observations must be logged separately")
    }

    @MainActor func testCaptureRegionUsesWindowPointsAndClearsWithoutHidingLocalWindow() {
        var calls: [(Int, CGRect?)] = []
        let protection = WindowCaptureProtection(backend: .init { id, rect in
            calls.append((id, rect)); return 0
        })
        let window = NSWindow(contentRect: NSRect(x: 30, y: 60, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let originalFrame = window.frame, originalAlpha = window.alphaValue
        XCTAssertEqual(protection.apply(to: window, enabled: true), .applied)
        XCTAssertEqual(calls.last?.0, window.windowNumber)
        XCTAssertEqual(calls.last?.1, CGRect(x: 0, y: 0, width: 420, height: 280))
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(window.alphaValue, originalAlpha)
        XCTAssertEqual(protection.apply(to: window, enabled: true, covering: CGSize(width: 600, height: 500)), .applied)
        XCTAssertEqual(calls.last?.1, CGRect(x: 0, y: 0, width: 600, height: 500))
        XCTAssertEqual(protection.apply(to: window, enabled: false), .disabled)
        XCTAssertNil(calls.last!.1)
        // On macOS 27.2 the XCTest host reads .none even after a direct
        // .readOnly assignment. Actual reappearance is checked by the separate
        // SCStream pixel probe, rather than accepting that getter as evidence.
        XCTAssertEqual(protection.status, .disabled)
        XCTAssertEqual(window.alphaValue, originalAlpha)
    }

    @MainActor func testProductionCaptureProtectionDoesNotUsePrivateRegionBackend() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let production = WindowCaptureProtection()
        XCTAssertEqual(production.apply(to: window, enabled: true), .legacyRequested)
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertEqual(production.apply(to: window, enabled: false), .disabled)
        let failed = WindowCaptureProtection(backend: .init { _, _ in 1000 })
        XCTAssertEqual(failed.apply(to: window, enabled: true), .failed(1000))
        XCTAssertEqual(failed.apply(to: window, enabled: false), .failed(1000))
    }

    @MainActor func testOverlayCaptureSwitchDoesNotProtectOrdinaryWindows() {
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let onboarding = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        let overlay = OverlayWindow(rootView: Text("Synthetic privacy fixture"))
        for window in [settings, onboarding, overlay] { window.isReleasedWhenClosed = false }
        defer { overlay.close(); settings.close(); onboarding.close() }
        overlay.orderFrontRegardless()
        overlay.setCaptureExcluded(false)
        XCTAssertEqual(overlay.captureProtectionStatus, .disabled)
        overlay.setCaptureExcluded(true)
        overlay.setFrame(NSRect(x: 20, y: 20, width: 600, height: 460), display: false)
        XCTAssertEqual(overlay.sharingType, .none)
        XCTAssertEqual(overlay.captureProtectionStatus, .legacyRequested)
        XCTAssertEqual(settings.sharingType, .readOnly)
        XCTAssertEqual(onboarding.sharingType, .readOnly)
        overlay.setCaptureExcluded(false)
        XCTAssertEqual(overlay.captureProtectionStatus, .disabled)
    }

    @MainActor func testDeletingModelsPreservesKnowledgeAndOtherModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models")
        let removable = LocalModelKind.streamingSpeech.location(in: models)
        try FileManager.default.createDirectory(at: removable, withIntermediateDirectories: true)
        let knowledge = root.appendingPathComponent("knowledge")
        try Data("retain".utf8).write(to: knowledge)
        let manager = LocalModelManager(root: models)
        manager.remove(.embedding)
        XCTAssertTrue(LocalModelKind.embedding.isInstalled(in: models))
        manager.remove(.streamingSpeech)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
        XCTAssertEqual(try Data(contentsOf: knowledge), Data("retain".utf8))
    }

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
        coordinator.settings.listeningService = .openAI
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
    func testCaptureAndBackgroundDefaultsPreserveExplicitPreferences() throws {
        XCTAssertFalse(AppSettings().excludeOverlayFromCapture)
        XCTAssertEqual(AppSettings().background, .glass)
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.excludeOverlayFromCapture)
        XCTAssertEqual(missing.background, .glass)
        var explicit = AppSettings()
        explicit.excludeOverlayFromCapture = true
        explicit.background = .white
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(explicit))
        XCTAssertTrue(restored.excludeOverlayFromCapture)
        XCTAssertEqual(restored.background, .white)
    }
    func testLiquidGlassBackgroundRoundTripsAndFallsBackBeforeMacOS26() throws {
        var settings = AppSettings()
        settings.background = .liquidGlass
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.background, .liquidGlass)
        if #available(macOS 26, *) {
            XCTAssertTrue(AppBackground.available.contains(.liquidGlass))
            XCTAssertEqual(restored.background.effective, .liquidGlass)
        } else {
            XCTAssertFalse(AppBackground.available.contains(.liquidGlass))
            XCTAssertEqual(restored.background.effective, .glass)
        }
        // Liquid Glass follows the system appearance like glass; the light backgrounds stay light.
        XCTAssertFalse(AppBackground.liquidGlass.usesLightAppearance)
        XCTAssertTrue(AppBackground.white.usesLightAppearance)
        XCTAssertEqual(AppBackground.white.effective, .white)
    }
    func testDebugLogRotatesAtItsBoundAndKeepsOnePreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCopilot-DebugLog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("livecopilot.log"), previous = directory.appendingPathComponent("livecopilot.1.log")
        for _ in 0..<5 { DebugLog.append(Data(repeating: 65, count: 400), to: log, maximumBytes: 1_000) }
        XCTAssertEqual(try Data(contentsOf: log).count, 400, "The current log must restart after crossing its bound")
        XCTAssertEqual(try Data(contentsOf: previous).count, 800, "Only the most recent full log is kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testDebugLogBoundsAnOversizedSingleWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCopilot-LargeLog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("livecopilot.log")
        for _ in 0..<3 { DebugLog.append(Data(repeating: 65, count: 4_000), to: log, maximumBytes: 1_000) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_000) }
    }

    /// A synthetic stdio worker: `onAudio` is shell code run for each audio request with `$id` set.
    private func speechWorker(startup: String = "", onAudio: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCopilot-SpeechStats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("worker")
        try """
        #!/bin/sh
        \(startup)
        printf '%s\\n' '{"ready":true}'
        audio=0
        while IFS= read -r row; do
          id=$(printf '%s' "$row" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
          case "$row" in
            *'"op":"audio"'*) audio=$((audio+1)); \(onAudio) ;;
            *) printf '{"id":"%s"}\\n' "$id" ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, script)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @MainActor func testLocalRecognitionReportsReadyTimeAndFinalLagOnTheAudioTimeline() async throws {
        // The first audio request returns a final segment ending 300 ms into the stream.
        let (directory, worker) = try speechWorker(onAudio: """
        if [ "$audio" = 1 ]; then printf '{"id":"%s","segments":[{"text":"x","start_ms":0,"end_ms":300}]}\\n' "$id"; else printf '{"id":"%s"}\\n' "$id"; fi
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = LocalLiveProvider(directory: directory, speaker: .them, executable: worker)
        var ready = false, finals = 0, failure: String?
        provider.onEvent = { event in
            switch event {
            case .ready: ready = true
            case .transcript: finals += 1
            case .failed(let message): failure = message
            default: break
            }
        }
        provider.connect(context: "")
        try await waitUntil { ready || failure != nil }
        XCTAssertTrue(ready, failure ?? "worker never became ready")
        provider.sendAudio(Data(count: 32_000)) // 1 s captured before the result arrives
        try await waitUntil { finals > 0 || failure != nil }
        let stats = provider.recognitionStats
        XCTAssertEqual(finals, 1)
        XCTAssertNotNil(stats.readyMS)
        XCTAssertEqual(stats.finalLagCount, 1)
        XCTAssertEqual(stats.finalLagMeanMS, 700, "1000 ms captured minus a segment ending at 300 ms")
        XCTAssertEqual(stats.backlogMaxMS, 1_000)
        XCTAssertNil(stats.failure)
        await provider.disconnect()
        XCTAssertEqual(provider.recognitionStats.finalLagCount, 1, "the stop-time flush must not count as live lag")
    }

    @MainActor func testLocalRecognitionNamesSlowModelLoadSeparatelyFromFallingBehind() async throws {
        for (slowLoad, expected, text) in [(true, CaptureDiagnostics.Failure.speech_load_slow, "took too long to load"),
                                           (false, .speech_behind, "fell behind")] {
            // Slow load: ready only after 30 s. Behind: ready at once, but audio is never answered.
            let (directory, worker) = try speechWorker(startup: slowLoad ? "sleep 30" : "", onAudio: "exec sleep 30")
            defer { try? FileManager.default.removeItem(at: directory) }
            let provider = LocalLiveProvider(directory: directory, speaker: .room, executable: worker)
            var ready = false, failure: String?
            provider.onEvent = { event in
                if case .ready = event { ready = true }
                if case .failed(let message) = event { failure = message }
            }
            provider.connect(context: "")
            if !slowLoad { try await waitUntil { ready } ; XCTAssertTrue(ready) }
            for _ in 0..<14 where failure == nil {
                provider.sendAudio(Data(count: 32_000))
                await Task.yield()
            }
            XCTAssertEqual(provider.recognitionStats.failure, expected)
            XCTAssertTrue(failure?.contains(text) == true, failure ?? "no failure for \(expected)")
            XCTAssertNotNil(L10n.text(failure ?? "", language: .simplifiedChinese).range(of: "监听"), "missing Simplified Chinese for \(expected)")
            await provider.disconnect()
        }
    }

    @MainActor func testMicrophoneHintsOnlyForMissingOrDigitallySilentInputInAllLanguages() {
        XCTAssertNil(AppCoordinator.microphoneHint(.audioWithoutText), "Quiet rooms or unrecognized speech are not device faults")
        XCTAssertNil(AppCoordinator.microphoneHint(.recognized))
        for verdict in [AudioFlowMonitor.Verdict.noAudio, .digitalSilence] {
            let hint = try! XCTUnwrap(AppCoordinator.microphoneHint(verdict))
            let simplified = L10n.text(hint, language: .simplifiedChinese), traditional = L10n.text(hint, language: .traditionalChinese)
            XCTAssertTrue(simplified.contains("麦克风"), "Missing Simplified Chinese for \(verdict)")
            XCTAssertTrue(traditional.contains("麥克風"), "Missing Traditional Chinese for \(verdict)")
            XCTAssertEqual(L10n.text(hint, language: .english), hint)
        }
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
        coordinator.settings.listeningService = .openAI
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
    @MainActor func testOverlayShortcutMigrationPersistenceAndConflicts() throws {
        let suite = "LiveCopilot-Overlay-Key-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let customReply = HotkeyCombo(keyCode: UInt32(kVK_F8), modifiers: UInt32(controlKey | shiftKey))
        // Older installations only saved suggestion shortcuts.
        defaults.set(try JSONEncoder().encode(["reply": customReply]), forKey: "hotkeyCombos.v1")
        let store = HotkeyStore(defaults: defaults)
        XCTAssertEqual(store.toggleOverlay, HotkeyStore.defaultToggleOverlay)
        XCTAssertEqual(store.combo(for: .reply), customReply)
        let overlay = HotkeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(store.setToggleOverlay(overlay))
        XCTAssertFalse(store.set(overlay, for: .reply))
        XCTAssertFalse(store.setToggleOverlay(customReply))
        let restarted = HotkeyStore(defaults: defaults)
        XCTAssertEqual(restarted.toggleOverlay, overlay)
        XCTAssertEqual(restarted.combo(for: .reply), customReply)
        XCTAssertTrue(restarted.resetToggleOverlay())
        XCTAssertEqual(HotkeyStore(defaults: defaults).toggleOverlay, HotkeyStore.defaultToggleOverlay)
        XCTAssertEqual(restarted.combo(for: .reply), customReply)
    }
    @MainActor func testOverlayShortcutReloadRecordingAndDisabledTools() {
        let suite = "LiveCopilot-Overlay-Dispatch-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(), store = HotkeyStore(defaults: defaults)
        var toggles = 0
        manager.register(store: store, onSuggest: { _ in XCTFail("No suggestion expected") }, onToggleOverlay: { toggles += 1 })
        defer { manager.unregisterAll() }
        func key(_ code: Int) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        manager.setRecording(true)
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_H)))
        XCTAssertTrue(store.setToggleOverlay(HotkeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))))
        manager.reload()
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_J)))
        manager.setRecording(false)
        manager.setEnabledModes([])
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_H)))
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_J)))
        XCTAssertEqual(toggles, 1)
        store.resetToggleOverlay(); manager.reload()
        XCTAssertTrue(manager.handleOverlayKey(key(kVK_ANSI_H)))
        XCTAssertFalse(manager.handleOverlayKey(key(kVK_ANSI_J)))
        XCTAssertEqual(toggles, 2)
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
        XCTAssertEqual(panel.sharingType, .readOnly)
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

@MainActor private final class SpeechConnectionStub: LiveProvider {
    var onEvent: ((LiveEvent) -> Void)?
    var initial: LiveEvent?
    var disconnected = false
    var audioCount = 0
    init(_ initial: LiveEvent?) { self.initial = initial }
    func connect(context: String) { if let initial { onEvent?(initial) } }
    func sendAudio(_ data: Data) { audioCount += 1 }
    func appendContext(_ text: String, delegationID: String?) {}
    func disconnect() async { disconnected = true }
}

final class SpeechConnectionTests: XCTestCase {
    func testReconnectHistoryUsesTypedInputMessages() throws {
        let event = LiveProtocol.start(model: "gpt-live-1", speaker: .them, scenario: .meeting, language: .mixed, context: "Synthetic prior topic")
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let input = try XCTUnwrap(session["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
    }

    @MainActor func testReadySessionPassesWithoutSendingAudioAndCloses() async throws {
        let provider = SpeechConnectionStub(.ready)
        try await LiveConnectionProbe.run(provider: provider)
        XCTAssertTrue(provider.disconnected)
        XCTAssertEqual(provider.audioCount, 0)
        XCTAssertNil(provider.onEvent)
    }
    @MainActor func testAuthenticationFailureIsPreserved() async {
        let message = LiveProtocol.connectionFailure(status: 401, error: nil).message
        let provider = SpeechConnectionStub(.failed(message))
        do {
            try await LiveConnectionProbe.run(provider: provider)
            XCTFail("Authentication failure passed verification")
        } catch { XCTAssertEqual(error.localizedDescription, message) }
        XCTAssertTrue(provider.disconnected)
        XCTAssertNil(provider.onEvent)
    }
    @MainActor func testEarlyCloseCannotPassVerification() async {
        let provider = SpeechConnectionStub(.closed(finalized: true))
        do { try await LiveConnectionProbe.run(provider: provider); XCTFail("Early close passed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("before the session")) }
        XCTAssertTrue(provider.disconnected)
    }
    @MainActor func testTimeoutAndCancellationCleanUp() async {
        let provider = SpeechConnectionStub(nil)
        do { try await LiveConnectionProbe.run(provider: provider, timeout: 0.01); XCTFail("Timeout passed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertTrue(provider.disconnected)
        let cancelled = SpeechConnectionStub(nil)
        let task = Task { try await LiveConnectionProbe.run(provider: cancelled) }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation passed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(cancelled.disconnected)
        XCTAssertNil(cancelled.onEvent)
    }
    func testHTTPFailuresStopRetryingCredentialsAndPreserveActionableReason() {
        for code in [400, 401, 403, 404, 429] {
            let failure = LiveProtocol.connectionFailure(status: code, error: URLError(.badServerResponse))
            XCTAssertFalse(failure.retry)
            XCTAssertTrue(failure.message.contains("HTTP \(code)"))
        }
        XCTAssertTrue(LiveProtocol.connectionFailure(status: 503, error: nil).retry)
        XCTAssertTrue(LiveProtocol.connectionFailure(status: nil, error: URLError(.timedOut)).retry)
    }
}

private final class EmbeddingConnectionStub: EmbeddingProvider {
    let model = "test-embedding"
    var inputs: [String] = []
    let result: Result<[[Float]], Error>
    init(_ result: Result<[[Float]], Error>) { self.result = result }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        inputs = texts
        return try result.get()
    }
}
final class EmbeddingConnectionTests: XCTestCase {
    func testOnlySyntheticTextIsSent() async throws {
        let provider = EmbeddingConnectionStub(.success([[0.1, 0.2]]))
        try await EmbeddingConnectionProbe.run(provider: provider)
        XCTAssertEqual(provider.inputs, ["Connection test"])
    }
    func testEmptyOrInvalidResponseCannotPass() async {
        for vectors: [[Float]] in [[], [[]], [[.nan]], [[1], [2]]] {
            let provider = EmbeddingConnectionStub(.success(vectors))
            do { try await EmbeddingConnectionProbe.run(provider: provider); XCTFail("Invalid vectors passed") }
            catch { XCTAssertTrue(error.localizedDescription.contains("embedding vectors")) }
        }
    }
    func testFailureAndCancellationAreNotReportedAsSuccess() async {
        let provider = EmbeddingConnectionStub(.failure(CopilotError.message("HTTP 401")))
        do { try await EmbeddingConnectionProbe.run(provider: provider); XCTFail("Authentication failure passed") }
        catch { XCTAssertEqual(error.localizedDescription, "HTTP 401") }
        let task = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await EmbeddingConnectionProbe.run(provider: EmbeddingConnectionStub(.success([[1]])))
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation passed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class KnowledgeVerificationTests: XCTestCase {
    @MainActor func testDownloadDoesNotBecomeReadyUntilInferenceCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let manager = LocalModelManager(root: root, embeddingVerifier: { _ in
            calls += 1
            try await Task.sleep(nanoseconds: 100_000_000)
        })
        let verification = Task { await manager.verifyEmbedding() }
        for _ in 0..<100 where !manager.embeddingVerification.isChecking { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(manager.installed.contains(.embedding))
        XCTAssertEqual(manager.embeddingVerification, .checking)
        XCTAssertFalse(manager.embeddingVerification.isReady)
        await verification.value
        XCTAssertTrue(manager.embeddingVerification.isReady)
        XCTAssertEqual(calls, 1)
        await manager.shutdown()
    }
    @MainActor func testFailedValidationPreservesFilesAndRetriesWithoutDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let manager = LocalModelManager(root: root, embeddingVerifier: { _ in
            attempts += 1
            if attempts == 1 { throw CopilotError.message("Load failed") }
        })
        XCTAssertEqual(manager.embeddingVerification, .idle)
        await manager.verifyEmbedding()
        XCTAssertEqual(manager.embeddingVerification, .failed("Load failed"))
        XCTAssertTrue(manager.installed.contains(.embedding))
        await manager.verifyEmbedding()
        XCTAssertTrue(manager.embeddingVerification.isReady)
        XCTAssertEqual(attempts, 2)
        manager.remove(.embedding)
        XCTAssertTrue(manager.embeddingVerification.isReady)
        XCTAssertTrue(manager.installed.contains(.embedding))
    }
    @MainActor func testCancelVerificationNeverMarksReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, embeddingVerifier: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) })
        let task = Task { await manager.verifyEmbedding() }
        for _ in 0..<100 where !manager.embeddingVerification.isChecking { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel(); await task.value
        XCTAssertEqual(manager.embeddingVerification, .idle)
        XCTAssertTrue(manager.installed.contains(.embedding))
    }
    func testTermsPreservePhrasesAndCleanEmptyDuplicateAndUnicodeEntries() throws {
        let terms = ProfessionalTerms.clean(" Vue\r\nvue\n\n机器学习\nReact Native\nNext.js\nC++\nGPT-6 模型\nCafé\nCafe\u{301}\n")
        XCTAssertEqual(terms, ["Vue", "机器学习", "React Native", "Next.js", "C++", "GPT-6 模型", "Café"])
        var settings = AppSettings(); settings.professionalTerms = terms
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.professionalTerms, terms)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).professionalTerms, ProfessionalTerms.examples)
        settings.professionalTerms = []
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).professionalTerms, [])
        XCTAssertFalse(ProfessionalTerms.supportsNativeEnhancement(.paraformer), "Shipped Paraformer must never claim hotword support")
    }
}

private struct DelayedVerificationEmbedding: EmbeddingProvider {
    let model = "test-embedding"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await Task.sleep(nanoseconds: 100_000_000)
        return [[1, 2]]
    }
}
extension KnowledgeVerificationTests {
    @MainActor private func app(_ provider: any EmbeddingProvider) -> AppCoordinator {
        let suite = "LiveCopilot-Knowledge-Verification-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var settings = AppSettings(); settings.embeddingService = .openAI; settings.save(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                              mockEmbedding: provider, mockKnowledgeDirectory: root)
    }
    @MainActor func testCloudCredentialsAreNotEquivalentToVerifiedModel() async throws {
        let coordinator = app(EmbeddingConnectionStub(.success([[1, 2]])))
        XCTAssertTrue(coordinator.hasAPIKey)
        XCTAssertFalse(coordinator.isKnowledgeServiceVerified)
        try await coordinator.testEmbeddingConnection()
        XCTAssertTrue(coordinator.isKnowledgeServiceVerified)
        coordinator.settings.embeddingModel = "another-model"
        XCTAssertFalse(coordinator.isKnowledgeServiceVerified)
        await coordinator.shutdown()
    }
    @MainActor func testCloudFailureRemainsUnconfigured() async {
        let coordinator = app(EmbeddingConnectionStub(.failure(CopilotError.message("HTTP 401"))))
        do { try await coordinator.testEmbeddingConnection(); XCTFail("Invalid key passed") }
        catch { XCTAssertEqual(error.localizedDescription, "HTTP 401") }
        XCTAssertFalse(coordinator.isKnowledgeServiceVerified)
        XCTAssertEqual(coordinator.embeddingVerification, .failed("HTTP 401"))
        await coordinator.shutdown()
    }
    @MainActor func testModelSwitchDiscardsPendingSuccessAndRequiresReindex() async throws {
        let coordinator = app(DelayedVerificationEmbedding())
        let task = Task { try await coordinator.testEmbeddingConnection() }
        for _ in 0..<100 where !coordinator.embeddingVerification.isChecking { try await Task.sleep(nanoseconds: 1_000_000) }
        coordinator.settings.embeddingService = .local
        do { try await task.value; XCTFail("Stale configuration passed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(coordinator.embeddingVerification, .idle)
        coordinator.knowledgeDocuments = [.init(id: "test", name: "test.txt", importedAt: Date(), localPath: "test.txt", status: "Ready", chunkCount: 1, embeddingModel: "text-embedding-3-small")]
        XCTAssertTrue(coordinator.knowledgeNeedsReindex)
        coordinator.knowledgeDocuments[0].embeddingModel = LocalModelKind.embeddingIdentity
        XCTAssertFalse(coordinator.knowledgeNeedsReindex)
        await coordinator.shutdown()
    }
}

final class TerminologyTests: XCTestCase {
    func testCapabilityPersistenceAndLegacySettings() throws {
        XCTAssertTrue(ProfessionalTerms.supportsNativeEnhancement(.zipformer))
        XCTAssertFalse(ProfessionalTerms.supportsNativeEnhancement(.paraformer))
        XCTAssertFalse(ProfessionalTerms.supportsNativeEnhancement(.apple))
        var settings = AppSettings()
        settings.listeningService = .zipformer
        settings.professionalTermsEnabled = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.listeningService, .zipformer)
        XCTAssertFalse(restored.professionalTermsEnabled)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{\"listeningService\":\"paraformer\"}".utf8)).listeningService, .paraformer)
    }
    func testTermsNormalizePhrasesAndRejectUnsupportedCharacters() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let symbols = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ机器学习")
        try symbols.enumerated().map { "\($0.element) \($0.offset)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProfessionalTerms.recognitionTerms(["React Native", "Next.js", "机器学习", "Vue", "vue", "🦊", "𰻞", "TypeScript"], tokensURL: url), ["REACT NATIVE", "NEXT JS", "机器学习", "VUE", "TYPESCRIPT"])
        XCTAssertTrue(ProfessionalTerms.recognitionTerms([String(repeating: "A", count: 101)], tokensURL: url).isEmpty)
        let terms = (1...101).map { String(repeating: "A", count: $0) }
        XCTAssertEqual(ProfessionalTerms.recognitionTerms(terms, tokensURL: url).count, 100)
    }
    func testPinnedDownloadRoutesAndIndependentInstallation() {
        let kind = LocalModelKind.terminologySpeech
        XCTAssertNotEqual(kind.directory, LocalModelKind.streamingSpeech.directory)
        XCTAssertEqual(kind.downloads.compactMap(\.knownByteCount).reduce(0, +), kind.estimatedDownloadBytes)
        for item in [ModelDownload.zipEncoder, .zipDecoder, .zipJoiner, .zipTokens] {
            let routes = LocalModelInstaller.candidateURLs(item, distributionBase: URL(string: "https://unpublished.example/models"))
            XCTAssertEqual(routes.first?.host, "modelscope.cn")
            XCTAssertEqual(routes.dropFirst().first?.host, "huggingface.co")
            XCTAssertTrue(routes.contains { $0.host == "hf-mirror.com" })
            XCTAssertFalse(routes.contains { $0.host == "unpublished.example" })
            XCTAssertEqual(item.sha256.count, 64)
        }
        XCTAssertEqual(ModelDownload.zipDecoder.installedName, "decoder.onnx")
    }
}

// MARK: - Independent Audit Regression Tests (P1 Cold-Start Race, P1 Stale Audio Isolation, P2 Streaming Coalescer)

private final class ControllableStreamHandle: AudioCaptureManager.StreamHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private let shouldHangStop: Bool
    private var released = false
    private var _stopCount = 0
    var stopCount: Int { lock.withLock { _stopCount } }

    init(hangStop: Bool) { self.shouldHangStop = hangStop }

    func stopCapture() async throws {
        lock.withLock { _stopCount += 1 }
        guard shouldHangStop else { return }
        await withCheckedContinuation { cont in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                stopContinuation = cont
                lock.unlock()
            }
        }
    }

    func releaseStop() {
        lock.lock()
        released = true
        let cont = stopContinuation
        stopContinuation = nil
        lock.unlock()
        cont?.resume()
    }
}

@MainActor
private final class RecordingLiveProvider: LiveProvider {
    var onEvent: ((LiveEvent) -> Void)?
    let tag: String
    private(set) var receivedAudio: [Data] = []
    private(set) var disconnectCount = 0
    private let finalTextOnDisconnect: String?

    init(tag: String, finalTextOnDisconnect: String? = nil) {
        self.tag = tag
        self.finalTextOnDisconnect = finalTextOnDisconnect
    }
    func connect(context: String) { onEvent?(.ready) }
    func sendAudio(_ data: Data) { receivedAudio.append(data) }
    func appendContext(_ text: String, delegationID: String?) {}
    func disconnect() async {
        disconnectCount += 1
        if let finalTextOnDisconnect, !receivedAudio.isEmpty {
            onEvent?(.transcript(.init(id: "final-\(tag)", speaker: .them, text: finalTextOnDisconnect, startMS: 0, endMS: 500, receivedAt: Date())))
        }
        onEvent?(.closed(finalized: true))
    }
}

private struct ScriptedReasoning: ReasoningProvider {
    let handler: @Sendable (AnswerRequest, AsyncThrowingStream<String, Error>.Continuation) -> Void
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in handler(request, continuation) }
    }
}

final class ReliabilityAuditRegressionTests: XCTestCase {
    private func makeCountingWorkerScript(in dir: URL, name: String, spawnLog: URL, hangBeforeReady: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let body: String
        if hangBeforeReady {
            body = """
            #!/bin/sh
            echo spawn >> \(String(reflecting: spawnLog.path))
            while :; do sleep 1; done
            """
        } else {
            body = """
            #!/usr/bin/env python3
            import json, sys
            with open(\(String(reflecting: spawnLog.path)), "a") as f: f.write("spawn\\n")
            sys.stdout.write(json.dumps({"ready": True}) + "\\n"); sys.stdout.flush()
            for line in sys.stdin:
                req = json.loads(line)
                sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n"); sys.stdout.flush()
            """
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func spawnCount(_ spawnLog: URL) -> Int {
        guard let text = try? String(contentsOf: spawnLog, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    func testColdStartTimeoutPreventsLaunchAndRecoversNextRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-cold-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spawnLog = dir.appendingPathComponent("spawns.log")
        let script = try makeCountingWorkerScript(in: dir, name: "worker.py", spawnLog: spawnLog)

        let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: dir, executable: script, sigkillGraceSeconds: 0.2)
        defer { worker.close(initiator: .selfCheck) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var armed = true
        let hookLock = NSLock()
        worker.onBeforeStartProcess = {
            hookLock.lock()
            let shouldPause = armed
            armed = false
            hookLock.unlock()
            if shouldPause {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }

        let timedCall = Task {
            try await worker.call(["op": "ping"], timeout: 0.05)
        }
        // Deterministically wait until request 1 is active and paused right before ensureStarted().
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "Request never reached cold-start barrier")
        // Wait past the 50ms deadline while still paused before child launch.
        try await Task.sleep(nanoseconds: 140_000_000)
        release.signal()

        do {
            _ = try await timedCall.value
            XCTFail("Expired cold-start request must not launch worker or succeed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), "Expected timeout error, got: \(error)")
        }
        XCTAssertEqual(spawnCount(spawnLog), 0, "Expired request must not spawn a child process")

        // Next normal request on the same worker must start cleanly and succeed.
        let recovered = try await worker.call(["op": "ping"], timeout: 3.0)
        XCTAssertEqual(recovered["ok"] as? Bool, true)
        XCTAssertEqual(spawnCount(spawnLog), 1, "Only the subsequent valid request should spawn the worker")
    }

    func testColdStartCancelPreventsLaunchAndStuckReadyTimesOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-cold-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spawnLog = dir.appendingPathComponent("spawns.log")
        let script = try makeCountingWorkerScript(in: dir, name: "worker.py", spawnLog: spawnLog)

        let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: dir, executable: script, sigkillGraceSeconds: 0.2)
        defer { worker.close(initiator: .selfCheck) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var armed = true
        let hookLock = NSLock()
        worker.onBeforeStartProcess = {
            hookLock.lock()
            let shouldPause = armed
            armed = false
            hookLock.unlock()
            if shouldPause {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }

        let cancelledCall = Task { try await worker.call(["op": "ping"], timeout: 5.0) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        cancelledCall.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        release.signal()

        do {
            _ = try await cancelledCall.value
            XCTFail("Cancelled cold-start request must throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got: \(error)")
        }
        XCTAssertEqual(spawnCount(spawnLog), 0, "Cancelled request must not spawn a child process")

        let recovered = try await worker.call(["op": "ping"], timeout: 3.0)
        XCTAssertEqual(recovered["ok"] as? Bool, true)
        XCTAssertEqual(spawnCount(spawnLog), 1)

        // Process launched, never sends {"ready":true} -> timeout kills it cleanly and recovers on fresh worker.
        let stuckLog = dir.appendingPathComponent("stuck-spawns.log")
        let stuckScript = try makeCountingWorkerScript(in: dir, name: "stuck-ready.sh", spawnLog: stuckLog, hangBeforeReady: true)
        let stuckWorker = LocalInferenceWorker(mode: "embedding", modelDirectory: dir, executable: stuckScript, sigkillGraceSeconds: 0.2)
        defer { stuckWorker.close(initiator: .selfCheck) }
        do {
            _ = try await stuckWorker.call(["op": "ping"], timeout: 0.35)
            XCTFail("Stuck ready handshake should time out")
        } catch is CopilotError {
            XCTAssertEqual(stuckWorker.failureCode, "timeout")
        }
        XCTAssertEqual(spawnCount(stuckLog), 1)
    }

    @MainActor
    func testSystemAudioStopTimeoutIsolatesStaleFramesAndNormalStopFlushes() async throws {
        let defaults = UserDefaults(suiteName: "com.livecopilot.test.audio-isolation.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .apple
        app.settings.automaticSuggestions = false
        app.micEnabled = false
        app.systemAudio.stopTimeoutSeconds = 0.15

        var diagEvents: [(CaptureDiagnostics.Stage, CaptureDiagnostics.Details?)] = []
        app.systemAudio.diagnosticObserver = { stage, details in
            diagEvents.append((stage, details))
        }

        // Helper: 100ms (1600 samples @ 16kHz) PCM16 tagged buffer
        func makeTaggedPCM(sampleValue: Int16, durationSamples: Int = 1600) -> Data {
            var data = Data(count: durationSamples * 2)
            data.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Int16.self)
                for i in 0..<durationSamples { ptr[i] = sampleValue.littleEndian }
            }
            return data
        }

        // --- Part 1: Normal stop flushes final transcript and confirms .systemStopped without timeout ---
        var deliverNormal: (@Sendable (Data, TimeInterval) -> Void)?
        var normalProvider: RecordingLiveProvider?
        app.systemAudio.testStreamFactory = { deliver in
            deliverNormal = deliver
            return ControllableStreamHandle(hangStop: false)
        }
        app.testLiveProviderFactory = { _ in
            let p = RecordingLiveProvider(tag: "normal", finalTextOnDisconnect: " final tail segment")
            normalProvider = p
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        let normalFrame = makeTaggedPCM(sampleValue: 4000)
        deliverNormal?(normalFrame, ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(nanoseconds: 50_000_000)
        await app.stop()
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(normalProvider?.receivedAudio.count, 1)
        XCTAssertTrue(app.transcript.lines.contains(where: { $0.content.contains("final tail segment") }),
                      "Normal stop must still flush the last transcript segment")
        XCTAssertTrue(diagEvents.contains(where: { $0.0 == .systemStopped }), "Normal stop must confirm .systemStopped")
        XCTAssertFalse(diagEvents.contains(where: { $0.0 == .stopStage && $0.1?.lifecyclePhase == .systemStop && $0.1?.timedOut == true }))

        // --- Part 2: Session A stop times out -> Session B starts -> stale A frames must NOT enter B ---
        diagEvents.removeAll()
        var deliverA: (@Sendable (Data, TimeInterval) -> Void)?
        var deliverB: (@Sendable (Data, TimeInterval) -> Void)?
        var handleA: ControllableStreamHandle?
        var providerA: RecordingLiveProvider?
        var providerB: RecordingLiveProvider?
        var sessionIndex = 0

        app.systemAudio.testStreamFactory = { deliver in
            sessionIndex += 1
            if sessionIndex == 1 {
                deliverA = deliver
                let h = ControllableStreamHandle(hangStop: true)
                handleA = h
                return h
            } else {
                deliverB = deliver
                return ControllableStreamHandle(hangStop: false)
            }
        }
        app.testLiveProviderFactory = { _ in
            if sessionIndex == 1 {
                let p = RecordingLiveProvider(tag: "A")
                providerA = p
                return p
            } else {
                let p = RecordingLiveProvider(tag: "B")
                providerB = p
                return p
            }
        }

        // Capture Session A's onPCM16 sessionID via a spy so we can also simulate a pre-stop
        // main-queue callback arriving AFTER Session B starts.
        var sessionAID: UUID?
        let originalOnPCM = app.systemAudio.onPCM16
        app.systemAudio.onPCM16 = { data, id in
            if sessionAID == nil { sessionAID = id }
            originalOnPCM?(data, id)
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        let frameA_loud = makeTaggedPCM(sampleValue: 20000) // ~ -4 dBFS, clearly loud
        let frameB_silent = makeTaggedPCM(sampleValue: 0)   // digital silence, -96 dBFS

        // Deliver one legitimate frame during Session A to capture Session A's epoch ID.
        deliverA?(frameA_loud, ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(sessionAID, "Should capture Session A's sessionID")

        await app.stop()
        XCTAssertFalse(app.isRunning)
        // Diagnostics must distinguish stop-wait timeout from confirmed underlying stop!
        XCTAssertTrue(diagEvents.contains(where: { $0.0 == .stopStage && $0.1?.lifecyclePhase == .systemStop && $0.1?.timedOut == true }),
                      "Timed-out stop must record stopStage(systemStop, timedOut: true)")
        XCTAssertFalse(diagEvents.contains(where: { $0.0 == .systemStopped }),
                       "Timed-out stop must NOT claim .systemStopped before underlying stream actually stops")

        // Start Session B while Session A's stopCapture() is still hung.
        await app.start()
        XCTAssertTrue(app.isRunning)
        let nowB = ProcessInfo.processInfo.systemUptime
        // 1. Deliver a late loud frame from Session A's old stream callback AFTER Session B started.
        deliverA?(frameA_loud, nowB)
        // 2. Simulate an already-enqueued MainActor callback from Session A executing during Session B.
        if let staleID = sessionAID { originalOnPCM?(frameA_loud, staleID) }
        // 3. Deliver Session B's own silent frame.
        deliverB?(frameB_silent, nowB)
        try await Task.sleep(nanoseconds: 80_000_000)

        // Assert Session B's LiveProvider ONLY received Session B's frame!
        XCTAssertEqual(providerB?.receivedAudio, [frameB_silent],
                       "Session B must only receive its own frames, never stale Session A frames")
        // Assert Session B's AudioFlowMonitor was NOT polluted by Session A's loud frame!
        let flowB = app.systemFlowSnapshot
        XCTAssertEqual(flowB.verdict, .digitalSilence, "Stale loud Session A frame polluted Session B's audio flow verdict")
        XCTAssertEqual(flowB.peakDBFS, -96, "Stale loud Session A frame polluted Session B's peak dBFS")
        // Assert Session B's EchoMonitor reference was NOT polluted by Session A's loud frame!
        let assessment = app.echo.assess(from: nowB - 0.5, to: nowB + 0.1, now: nowB + 0.05)
        XCTAssertFalse(assessment.systemActive, "Stale loud Session A frame polluted Session B's echo reference")

        // Release Session A's hung stopCapture() and verify confirmed .systemStopped arrives now.
        handleA?.releaseStop()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(diagEvents.contains(where: { $0.0 == .systemStopped }),
                      "Underlying stream confirmation should record .systemStopped once stopCapture completes")

        _ = providerA
        await app.shutdown()
    }

    @MainActor
    func testStreamingCoalescerIdleFlushAndTerminalSnapshots() async throws {
        // 1. Burst followed by idle pause: first token immediate, buffered second token flushed within batch interval.
        do {
            let reasoning = ScriptedReasoning { _, cont in
                cont.yield("alpha")
                cont.yield(" beta")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    cont.finish()
                }
            }
            let app = AppCoordinator(mock: true, mockReasoning: reasoning, emitMockConversation: false)
            app.askText("idle flush check")
            for _ in 0..<50 where app.suggestion.text.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(app.suggestion.text.hasPrefix("alpha"))
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(app.suggestion.text, "alpha beta", "Buffered delta must flush on timer even with no further tokens")
            await app.shutdown()
        }

        // 2. Cancel right after burst: terminal snapshot includes buffered text immediately and never mutates afterward.
        do {
            let reasoning = ScriptedReasoning { _, cont in
                cont.yield("alpha")
                cont.yield(" beta")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    cont.finish()
                }
            }
            let app = AppCoordinator(mock: true, mockReasoning: reasoning, emitMockConversation: false)
            app.askText("cancel snapshot check")
            for _ in 0..<50 where app.suggestion.text.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            app.cancelAnswer()
            let snapshotAtCancel = app.suggestion.text
            XCTAssertEqual(snapshotAtCancel, "alpha beta", "Cancelled snapshot must flush consumed buffer before terminal publish")
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(app.suggestion.text, snapshotAtCancel, "Cancelled terminal snapshot must remain stable")
            await app.shutdown()
        }

        // 3. Stream failure right after burst: preserves full text once and stays stable.
        do {
            let reasoning = ScriptedReasoning { _, cont in
                cont.yield("alpha")
                cont.yield(" beta")
                Task {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    cont.finish(throwing: CopilotError.message("boom"))
                }
            }
            let app = AppCoordinator(mock: true, mockReasoning: reasoning, emitMockConversation: false)
            app.askText("failure snapshot check")
            for _ in 0..<100 where app.answerIsRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(app.suggestion.text, "alpha beta", "Failed snapshot must include buffered delta once")
            XCTAssertEqual(app.suggestion.state, .failed)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(app.suggestion.text, "alpha beta")
            await app.shutdown()
        }

        // 4. Answer timeout right after burst: flushes buffered text before publishing timeout terminal state.
        do {
            let reasoning = ScriptedReasoning { _, cont in
                cont.yield("alpha")
                cont.yield(" beta")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    cont.finish()
                }
            }
            let app = AppCoordinator(mock: true, mockReasoning: reasoning, emitMockConversation: false)
            app.answerTimeoutSeconds = 0.04
            app.askText("timeout snapshot check")
            for _ in 0..<100 where app.answerIsRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(app.suggestion.text, "alpha beta", "Timed-out snapshot must flush buffered delta before terminal fail")
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(app.suggestion.text, "alpha beta")
            await app.shutdown()
        }

        // 5. Replacement by next question: old answer keeps its buffered text, old timer never mutates new answer.
        do {
            let reasoning = ScriptedReasoning { req, cont in
                if req.query.question.contains("first") {
                    cont.yield("alpha")
                    cont.yield(" beta")
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        cont.finish()
                    }
                } else {
                    cont.yield("gamma")
                    cont.finish()
                }
            }
            let app = AppCoordinator(mock: true, mockReasoning: reasoning, emitMockConversation: false)
            app.askText("first question")
            for _ in 0..<50 where app.suggestion.text.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            let firstID = app.selectedAnswerID
            app.askText("second question")
            for _ in 0..<100 where app.answerIsRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 180_000_000)
            let firstRecord = app.answers.first(where: { $0.id == firstID })
            XCTAssertEqual(firstRecord?.store.text, "alpha beta", "Replaced answer must retain its full consumed text")
            XCTAssertEqual(app.suggestion.text, "gamma", "Old flush timer must never pollute the replacement answer")
            await app.shutdown()
        }
    }

    @MainActor func testKnowledgeDiagnosticsButtonTargetsKnowledgeIndexingTab() async {
        let target = SettingsView.knowledgeModelDiagnosticsTarget
        XCTAssertEqual(target.page, .services)
        XCTAssertEqual(target.serviceRole, .knowledgeIndexing)
        XCTAssertEqual(target.serviceRole.rawValue, 2)

        let app = AppCoordinator(mock: true, emitMockConversation: false)
        app.settings.language = .simplifiedChinese
        app.settings.embeddingService = .local
        let host = NSHostingView(rootView: SettingsView(coordinator: app, initialPage: target.page, initialServiceRole: target.serviceRole.rawValue))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.contentView = nil
        await app.shutdown()
    }

    @MainActor func testToggleMicMuteRaceCleanupAndCrossSessionIsolation() async throws {
        let defaults = UserDefaults(suiteName: "com.livecopilot.test.toggle-mic.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .apple
        app.settings.automaticSuggestions = false
        app.micEnabled = true

        // Part 1: Degraded Remote mode (system audio fails to start, only mic captures).
        // Intentional mute must NOT misfire mic.$isCapturing failure sink to terminate isRunning.
        var createdMicProviders: [RecordingLiveProvider] = []
        var deliverMicA: (@Sendable (Data, TimeInterval) -> Void)?
        var deliverMicB: (@Sendable (Data, TimeInterval) -> Void)?
        var micStartCount = 0
        app.systemAudio.testStreamFactory = { _ in throw AudioCaptureManager.CaptureError.noDisplay }
        app.mic.testStartHandler = { deliver in
            micStartCount += 1
            if micStartCount == 1 { deliverMicA = deliver }
            else { deliverMicB = deliver }
            return true
        }
        app.testLiveProviderFactory = { speaker in
            let p = RecordingLiveProvider(tag: "\(speaker.rawValue)-\(createdMicProviders.count)")
            if speaker == .you { createdMicProviders.append(p) }
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertFalse(app.systemAudio.isCapturing)
        XCTAssertTrue(app.mic.isCapturing)
        XCTAssertEqual(createdMicProviders.count, 1)

        // Intentional mute in mic-only Remote mode must keep the listening session alive.
        app.toggleMic()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(app.micEnabled)
        XCTAssertFalse(app.mic.isCapturing)
        XCTAssertTrue(app.isRunning, "Intentional mic mute must not kill a degraded Remote session")

        // Part 2: Rapid Unmute -> Mute -> Unmute must serialize and leave no leaked micLive provider.
        app.toggleMic() // unmute
        app.toggleMic() // mute
        app.toggleMic() // unmute
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(app.micEnabled)
        XCTAssertTrue(app.mic.isCapturing)
        XCTAssertTrue(app.isRunning)

        // Part 3: Unmute racing with stop() must never leave hardware mic capturing after stop().
        app.toggleMic() // mute first
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(app.mic.isCapturing)
        var releaseDelayedStart: CheckedContinuation<Bool, Never>?
        app.mic.testStartHandler = { deliver in
            deliverMicB = deliver
            return await withCheckedContinuation { cont in releaseDelayedStart = cont }
        }
        app.toggleMic() // unmute starts and suspends inside mic.start
        for _ in 0..<40 where releaseDelayedStart == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(releaseDelayedStart)
        let stopTask = Task { await app.stop() }
        try await Task.sleep(nanoseconds: 30_000_000)
        releaseDelayedStart?.resume(returning: true)
        await stopTask.value
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(app.mic.isCapturing, "Mic capture must not remain active after stop() raced with toggleMic()")

        // Part 4: Cross-session mic frame isolation (stale Session A tap frame must not enter Session B).
        func makePCM(_ value: Int16, samples: Int = 1600) -> Data {
            var data = Data(count: samples * 2)
            data.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Int16.self)
                for i in 0..<samples { ptr[i] = value.littleEndian }
            }
            return data
        }
        var providerB: RecordingLiveProvider?
        app.micEnabled = true
        app.mic.testStartHandler = { deliver in
            deliverMicB = deliver
            return true
        }
        app.testLiveProviderFactory = { speaker in
            let p = RecordingLiveProvider(tag: "sessionB-\(speaker.rawValue)")
            if speaker == .you { providerB = p }
            return p
        }
        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.mic.isCapturing)
        let nowB = ProcessInfo.processInfo.systemUptime
        let loudA = makePCM(20000)
        let silentB = makePCM(0)
        deliverMicA?(loudA, nowB)
        deliverMicB?(silentB, nowB)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(providerB?.receivedAudio, [silentB], "Stale Session A mic frame must never reach Session B provider")
        XCTAssertEqual(app.micFlowSnapshot.verdict, .digitalSilence, "Stale Session A mic frame must not pollute Session B micFlow")

        await app.shutdown()
    }

    @MainActor func testShutdownBoundsStalledIndexingAndPreventsRestart() async throws {
        struct HangingEmbedding: EmbeddingProvider {
            let model = "hang-test"
            func embed(_ texts: [String]) async throws -> [[Float]] {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return texts.map { _ in [1, 0, 0, 0] }
            }
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-shutdown-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sampleDoc = tempDir.appendingPathComponent("note.txt")
        try "LiveCopilot bounded shutdown verification sample.".write(to: sampleDoc, atomically: true, encoding: .utf8)

        let defaults = UserDefaults(suiteName: "com.livecopilot.test.shutdown-bound.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                 mockEmbedding: HangingEmbedding(), mockKnowledgeDirectory: tempDir.appendingPathComponent("kb", isDirectory: true))
        app.shutdownSubsystemTimeoutSeconds = 0.25
        app.importDocuments([sampleDoc])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(app.isIndexing)

        let started = ProcessInfo.processInfo.systemUptime
        await app.shutdown()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 2.0, "shutdown() must complete within bounded timeout even with a stalled indexing task")

        await app.start()
        XCTAssertFalse(app.isRunning, "start() must remain blocked after shutdown()")
    }

    @MainActor func testSessionStoreAsyncIOAndFlushDurability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-async-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seedStore = SessionStore(root: root, asyncIO: false)
        let older = try XCTUnwrap(seedStore.save(lines: [TranscriptLine(speaker: .them, at: Date(timeIntervalSince1970: 1_790_000_000), content: "Earlier meeting")],
                                                 startedAt: Date(timeIntervalSince1970: 1_790_000_000)))

        let asyncStore = SessionStore(root: root, asyncIO: true)
        let newer = try XCTUnwrap(asyncStore.save(lines: [TranscriptLine(speaker: .them, at: Date(timeIntervalSince1970: 1_790_001_000), content: "Current meeting")],
                                                  startedAt: Date(timeIntervalSince1970: 1_790_001_000)))
        await asyncStore.flush(timeout: 2.0)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(asyncStore.sessions.count, 2, "Async load must merge existing disk sessions with newly saved in-memory sessions")
        XCTAssertEqual(asyncStore.sessions.first?.id, newer.id)
        XCTAssertEqual(asyncStore.sessions.last?.id, older.id)

        asyncStore.delete(older)
        await asyncStore.flush(timeout: 2.0)

        let reloaded = SessionStore(root: root, asyncIO: false)
        XCTAssertEqual(reloaded.sessions.map(\.id), [newer.id], "Flushed async save + delete must match disk state on reload")
    }

    @MainActor func testSubmitLayaCoalescesRapidPartialsAndDeliversTrailingUpdate() async throws {
        final class PredictionCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var inputs: [String] = []
            func record(_ text: String) { lock.withLock { inputs.append(text) } }
            var values: [String] { lock.withLock { inputs } }
        }
        let counter = PredictionCounter()
        let defaults = UserDefaults(suiteName: "com.livecopilot.test.laya-throttle.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, layaPredictor: { text, _ in
            counter.record(text)
            return 0.2
        }, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .inPerson
        app.settings.listeningService = .apple
        app.settings.automaticSuggestions = true
        app.layaPartialThrottleInterval = 0.15

        await app.start()
        app.receiveMockEvent(.speechActivity(true), speaker: .room)
        for i in 1...10 {
            app.receiveMockEvent(.partialTranscript("How does caching step \(i) work in detail"), speaker: .room)
        }
        // Wait for trailing partial flush + Laya debounce window to settle.
        try await Task.sleep(nanoseconds: 650_000_000)
        let recorded = counter.values
        XCTAssertFalse(recorded.isEmpty, "At least one partial must reach Laya")
        XCTAssertLessThanOrEqual(recorded.count, 3, "Rapid 10-partial burst should coalesce rather than evaluating every frame")
        XCTAssertTrue(recorded.last?.contains("step 10") == true, "Trailing partial flush must deliver the latest partial text")
        await app.shutdown()
    }

    @MainActor func testCloudLiveTerminalFailureStopsListeningInsteadOfZombieCapture() async throws {
        // HTTP 422 must also be classified as non-retryable.
        XCTAssertFalse(LiveProtocol.connectionFailure(status: 422, error: nil).retry)

        let defaults = UserDefaults(suiteName: "com.livecopilot.test.cloud-live-fail.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .openAI
        app.settings.automaticSuggestions = false
        app.micEnabled = false

        var activeProvider: RecordingLiveProvider?
        app.systemAudio.testStreamFactory = { _ in ControllableStreamHandle(hangStop: false) }
        app.testLiveProviderFactory = { _ in
            let p = RecordingLiveProvider(tag: "cloud")
            activeProvider = p
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.systemAudio.isCapturing)

        activeProvider?.onEvent?(.failed("API key rejected. (HTTP 401)"))
        for _ in 0..<40 where app.isRunning || app.systemAudio.isCapturing {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.isRunning, "Terminal cloud Live failure must stop listening instead of leaving zombie capture")
        XCTAssertFalse(app.systemAudio.isCapturing, "Hardware audio capture must stop after terminal cloud Live failure")
        XCTAssertEqual(app.statusMessage, "API key rejected. (HTTP 401)")
        await app.shutdown()
    }

    @MainActor func testUncheckingSharedOpenAIKeyPreservesHasAPIKeyForReenabling() async {
        let defaults = UserDefaults(suiteName: "com.livecopilot.test.shared-key-toggle.\(UUID().uuidString)")!
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.listeningService = .zipformer
        app.settings.embeddingService = .local
        app.settings.reasoningService = .sharedOpenAI
        app.hasAPIKey = true

        // Switching from .sharedOpenAI to .separateOpenAI makes requiresOpenAIKey == false,
        // but must NOT wipe hasAPIKey so the "Use speech OpenAI key" toggle remains reversible.
        app.settings.selectAnalysisService(.separateOpenAI)
        XCTAssertFalse(app.settings.requiresOpenAIKey)
        XCTAssertTrue(app.hasAPIKey, "Unchecking Use speech OpenAI key must not clear hasAPIKey and permanently lock the toggle")

        // Switching back to .sharedOpenAI works cleanly.
        app.settings.selectAnalysisService(.sharedOpenAI)
        XCTAssertTrue(app.settings.requiresOpenAIKey)
        XCTAssertTrue(app.hasAPIKey)
        await app.shutdown()
    }

    @MainActor func testLowPowerVideoConferenceOptimizationsForIntelAndSCStream() async throws {
        // 1. Lightweight non-blur surface activates on Intel hosts or when Reduce Transparency is enabled.
        XCTAssertTrue(WindowBackgroundView.usesLightweightSurface(reduceTransparency: false, isIntel: true))
        XCTAssertTrue(WindowBackgroundView.usesLightweightSurface(reduceTransparency: true, isIntel: false))
        XCTAssertFalse(WindowBackgroundView.usesLightweightSurface(reduceTransparency: false, isIntel: false))

        // 2. Audio-only ScreenCaptureKit config minimizes display-capture rate & VRAM surface pool.
        let cfg = AudioCaptureManager.makeAudioOnlyStreamConfiguration(sampleRate: 16000)
        XCTAssertTrue(cfg.capturesAudio)
        XCTAssertTrue(cfg.excludesCurrentProcessAudio)
        XCTAssertEqual(cfg.sampleRate, 16000)
        XCTAssertEqual(cfg.channelCount, 1)
        XCTAssertEqual(cfg.width, 2)
        XCTAssertEqual(cfg.height, 2)
        XCTAssertEqual(cfg.queueDepth, 1)
        XCTAssertFalse(cfg.showsCursor)
        XCTAssertFalse(cfg.scalesToFit)
        XCTAssertGreaterThanOrEqual(cfg.minimumFrameInterval.seconds, 10.0)

        // 3. LocalLiveProvider coalesces 20ms (640B) audio bursts to cut IPC wakeups ~5x and flushes tail cleanly.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("batch-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let countLog = dir.appendingPathComponent("calls.log")
        let script = dir.appendingPathComponent("batch-worker.py")
        try """
        #!/usr/bin/env python3
        import base64, json, sys
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            if req.get("op") == "audio":
                nbytes = len(base64.b64decode(req.get("pcm", "")))
                with open(\(String(reflecting: countLog.path)), "a") as f: f.write(f"{nbytes}\\n")
                sys.stdout.write(json.dumps({"id": req["id"], "segments": [], "partial": "", "speaking": False}) + "\\n")
            elif req.get("op") == "flush":
                sys.stdout.write(json.dumps({"id": req["id"], "segments": [], "partial": "", "speaking": False}) + "\\n")
            else:
                sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n")
            sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = LocalLiveProvider(directory: dir, speaker: .them, executable: script)
        var ready = false
        provider.onEvent = { if case .ready = $0 { ready = true } }
        provider.connect(context: "")
        for _ in 0..<100 where !ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(ready)

        // Send 10 consecutive 20ms (640B) chunks = 6400B -> should coalesce into far fewer than 10 IPC calls.
        let chunk20ms = Data(count: 640)
        for _ in 0..<10 { provider.sendAudio(chunk20ms) }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Send one sub-threshold 20ms tail chunk (640B < 3072B) -> 120ms max-wait timer must flush it.
        provider.sendAudio(chunk20ms)
        try await Task.sleep(nanoseconds: 250_000_000)
        await provider.disconnect()

        let sizes = (try? String(contentsOf: countLog, encoding: .utf8))?.split(separator: "\n").compactMap { Int($0) } ?? []
        XCTAssertEqual(sizes.reduce(0, +), 7040, "All 11x 640B audio chunks including sub-threshold tail must be delivered")
        XCTAssertGreaterThanOrEqual(sizes.count, 2, "Initial burst and delayed tail should both flush")
        XCTAssertLessThanOrEqual(sizes.count, 4, "11x 20ms audio frames should coalesce into far fewer IPC round-trips")
    }

    @MainActor func testStopDuringToggleMicClearsFlagAndPreventsStaleStopOfNextSession() async throws {
        let suite = "com.livecopilot.test.mic-toggle-cross-session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .apple
        app.settings.automaticSuggestions = false
        app.micEnabled = true
        // Mic-only degraded remote session so unexpected mic disconnect in Session B must also stop isRunning.
        app.systemAudio.testStreamFactory = { _ in throw AudioCaptureManager.CaptureError.noDisplay }

        var micProviders: [RecordingLiveProvider] = []
        app.testLiveProviderFactory = { speaker in
            let p = RecordingLiveProvider(tag: "\(speaker.rawValue)-\(micProviders.count)")
            if speaker == .you { micProviders.append(p) }
            return p
        }
        app.mic.testStartHandler = { _ in true }

        // Session A: start, then mute mic cleanly.
        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.mic.isCapturing)
        app.toggleMic()
        for _ in 0..<40 where app.mic.isCapturing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(app.mic.isCapturing)

        // Start unmute in Session A, suspending inside mic.start after isTogglingMic is set.
        var releaseToggleA: CheckedContinuation<Bool, Never>?
        app.mic.testStartHandler = { _ in
            await withCheckedContinuation { cont in releaseToggleA = cont }
        }
        app.toggleMic()
        for _ in 0..<40 where releaseToggleA == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(releaseToggleA)

        // Stop Session A while toggleMic() is still suspended.
        await app.stop()
        XCTAssertFalse(app.isRunning)

        // Start Session B with healthy mic.
        app.micEnabled = true
        app.mic.testStartHandler = { _ in true }
        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.mic.isCapturing)
        let providerB = try XCTUnwrap(micProviders.last)
        XCTAssertEqual(providerB.disconnectCount, 0)

        // Now let Session A's stale toggleMic() resume late: it must NOT stop Session B's mic.
        releaseToggleA?.resume(returning: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(app.isRunning, "Stale Session A toggleMic completion must not disrupt Session B")
        XCTAssertTrue(app.mic.isCapturing, "Stale Session A toggleMic completion must not stop Session B's mic")
        XCTAssertEqual(providerB.disconnectCount, 0)

        // Now simulate an unexpected microphone disconnect in Session B:
        // Session B's mic.$isCapturing failure sink MUST fire (isTogglingMic must not have leaked from A).
        app.mic.stop()
        for _ in 0..<40 where app.isRunning || providerB.disconnectCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(app.isRunning, "Unexpected mic disconnect in Session B must trigger failure handling")
        XCTAssertEqual(providerB.disconnectCount, 1, "Session B's mic LiveProvider must be disconnected on unexpected mic loss")
        await app.shutdown()
    }

    @MainActor func testCloudSessionClosedStopsCaptureWhileNormalUserStopRemainsClean() async throws {
        let suite = "com.livecopilot.test.cloud-session-closed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .openAI
        app.settings.automaticSuggestions = false
        app.micEnabled = false

        // --- Path 1: Unexpected server-initiated session.closed stops listening and hardware capture ---
        var handle1: ControllableStreamHandle?
        var provider1: OpenAILiveProvider?
        app.systemAudio.testStreamFactory = { _ in
            let h = ControllableStreamHandle(hangStop: false)
            handle1 = h
            return h
        }
        app.testLiveProviderFactory = { speaker in
            let p = OpenAILiveProvider(key: "test-key", model: "gpt-live-1", speaker: speaker, scenario: .interview, language: app.settings.liveSpeechLanguage)
            p.activateWithoutSocketForTesting()
            provider1 = p
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.systemAudio.isCapturing)
        let active1 = try XCTUnwrap(provider1)
        active1.injectServerJSONForTesting(#"{"type":"session.started"}"#)
        XCTAssertTrue(active1.isActiveForTesting)

        // Inject server-initiated session.closed while listening is active.
        active1.injectServerJSONForTesting(#"{"type":"session.closed"}"#)
        for _ in 0..<60 where app.isRunning || app.systemAudio.isCapturing {
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertFalse(active1.isActiveForTesting, "OpenAILiveProvider must close connection on session.closed")
        XCTAssertFalse(app.isRunning, "Server-initiated session.closed must stop listening")
        XCTAssertFalse(app.systemAudio.isCapturing, "Server-initiated session.closed must stop system audio capture")
        XCTAssertEqual(handle1?.stopCount, 1)
        XCTAssertTrue(app.statusMessage.contains("closed by the service"), "Unexpected status: \(app.statusMessage)")

        // --- Path 2: Normal user stop() receiving session.closed during disconnect stays clean ---
        var handle2: ControllableStreamHandle?
        var provider2: OpenAILiveProvider?
        app.systemAudio.testStreamFactory = { _ in
            let h = ControllableStreamHandle(hangStop: false)
            handle2 = h
            return h
        }
        app.testLiveProviderFactory = { speaker in
            let p = OpenAILiveProvider(key: "test-key", model: "gpt-live-1", speaker: speaker, scenario: .interview, language: app.settings.liveSpeechLanguage)
            p.activateWithoutSocketForTesting()
            provider2 = p
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.systemAudio.isCapturing)
        let active2 = try XCTUnwrap(provider2)
        active2.injectServerJSONForTesting(#"{"type":"session.started"}"#)

        let stopTask = Task { await app.stop() }
        for _ in 0..<40 where !active2.isClosingForTesting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(active2.isClosingForTesting, "User stop() should send session.close and await session.closed")
        active2.injectServerJSONForTesting(#"{"type":"session.closed"}"#)
        await stopTask.value

        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(app.systemAudio.isCapturing)
        XCTAssertEqual(handle2?.stopCount, 1)
        XCTAssertEqual(app.statusMessage, "Listening stopped — manual questions remain available")
        await app.shutdown()
    }

    @MainActor func testIntentionalMicMuteWithClosedEventPreservesPendingRemoteQuestion() async throws {
        let suite = "com.livecopilot.test.mute-preserves-laya.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        final class CapturedQuestions: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ q: String) { lock.withLock { values.append(q) } }
            var all: [String] { lock.withLock { values } }
        }
        let captured = CapturedQuestions()
        let reasoner = ScriptedReasoning { req, cont in
            captured.append(req.query.question)
            cont.yield("## Suggested answer\nCache invalidation answer.")
            cont.finish()
        }

        let app = AppCoordinator(mock: true, layaPredictor: { _, _ in 0.96 }, mockReasoning: reasoner,
                                 emitMockConversation: false, mockDefaults: defaults)
        app.settings.mode = .remote
        app.settings.listeningService = .paraformer
        app.settings.automaticSuggestions = true
        app.micEnabled = true

        var systemProvider: RecordingLiveProvider?
        var micProvider: RecordingLiveProvider?
        app.systemAudio.testStreamFactory = { _ in ControllableStreamHandle(hangStop: false) }
        app.mic.testStartHandler = { _ in true }
        app.testLiveProviderFactory = { speaker in
            let p = RecordingLiveProvider(tag: speaker.rawValue)
            if speaker == .them { systemProvider = p } else { micProvider = p }
            return p
        }

        await app.start()
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.systemAudio.isCapturing)
        XCTAssertTrue(app.mic.isCapturing)

        // Remote speaker asks a substantive question, entering Laya's pending quiet window.
        let questionText = "Can you explain how the cache invalidation strategy works?"
        systemProvider?.onEvent?(.speechActivity(true))
        systemProvider?.onEvent?(.transcript(.init(id: "remote-q1", speaker: .them, text: questionText,
                                                   startMS: 0, endMS: 1800, receivedAt: Date())))
        systemProvider?.onEvent?(.speechActivity(false))

        // Immediately mute mic while the remote question is pending; RecordingLiveProvider.disconnect()
        // emits .closed(finalized: true) just like production LocalLiveProvider / AppleLiveProvider.
        app.toggleMic()
        for _ in 0..<40 where app.mic.isCapturing || (micProvider?.disconnectCount ?? 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(app.micEnabled)
        XCTAssertFalse(app.mic.isCapturing)
        XCTAssertEqual(micProvider?.disconnectCount, 1)
        XCTAssertTrue(app.isRunning)
        XCTAssertTrue(app.systemAudio.isCapturing)

        // Wait for Laya's quiet window and automatic answer generation to fire.
        for _ in 0..<120 where captured.all.isEmpty {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(captured.all.count, 1, "Intentional mic mute emitting .closed must NOT reset Laya and drop Them's pending question")
        XCTAssertTrue(captured.all.first?.contains("cache invalidation") == true)
        await app.shutdown()
    }
}
