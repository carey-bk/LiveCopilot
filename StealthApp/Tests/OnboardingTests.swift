import XCTest
import Combine
import SwiftUI
@testable import LiveCopilot

final class OnboardingTests: XCTestCase {
    @MainActor func testProviderBrandAssetsAreBundledAndCustomEndpointHasNoVendorLogo() throws {
        for service in ReasoningService.allCases where service != .compatible {
            let resource = try XCTUnwrap(service.logoResource)
            let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent(resource))
            XCTAssertNotNil(NSImage(contentsOf: url), "Missing provider logo: \(resource)")
        }
        XCTAssertNil(ReasoningService.compatible.logoResource)
        XCTAssertEqual(ReasoningService.sharedOpenAI.logoResource, ReasoningService.separateOpenAI.logoResource)
    }

    @MainActor func testCaptureExclusionTipResumesWithoutChangingPrivacyChoice() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        store.complete(); store.enterOverlay()
        for _ in 0..<3 { store.advanceTip() }
        XCTAssertEqual(store.visibleTip, .captureExclusion)
        let restored = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertEqual(restored.visibleTip, .captureExclusion)
        restored.advanceTip()
        XCTAssertEqual(restored.tour.disposition, .finished)
        XCTAssertNil(defaults.data(forKey: "livecopilot.settings"), "Tips must not write privacy preferences")
    }
    @MainActor func testAnswerPaginationPreservesMultilingualTextAndFitsThePanel() {
        let text = String(repeating: "这一段说明项目的目标、个人职责与结果。👩🏽‍💻\nA longer explanation with supporting details and follow-up actions.\n\n", count: 40)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let size = CGSize(width: 560, height: 240)
        let pages = OnboardingTextPages.split(text, size: size)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text)
        for page in pages {
            XCTAssertFalse(page.isEmpty)
            let measured = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph])
            let bounds = measured.boundingRect(with: NSSize(width: size.width - 8, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
            XCTAssertLessThanOrEqual(ceil(bounds.height), size.height - 8)
        }
    }
    @MainActor func testAnswerPaginationReflowsAndHandlesUnbrokenText() {
        let text = String(repeating: "🧑‍🚀无空格长句", count: 100)
        let compact = OnboardingTextPages.split(text, size: CGSize(width: 400, height: 180))
        let expanded = OnboardingTextPages.split(text, size: CGSize(width: 640, height: 340))
        XCTAssertEqual(compact.joined(), text)
        XCTAssertEqual(expanded.joined(), text)
        XCTAssertGreaterThan(compact.count, expanded.count)
        XCTAssertEqual(OnboardingTextPages.split("", size: .zero), [""])
        XCTAssertEqual(OnboardingTextPages.split("短回答", size: CGSize(width: 560, height: 240)), ["短回答"])
    }
    private func defaults() -> (String, UserDefaults) {
        let suite = "LiveCopilot-Onboarding-Test-" + UUID().uuidString
        return (suite, UserDefaults(suiteName: suite)!)
    }
    @MainActor func testFirstLaunchWithEmptySessionFolderAndResume() throws {
        let (suite, defaults) = defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertTrue(store.isNewInstall)
        XCTAssertTrue(store.state.shouldPresent)
        store.state.step = .permissions; store.state.prefersTyping = true; store.state.wantsKnowledge = true
        let recovered = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(recovered.isNewInstall)
        XCTAssertEqual(recovered.state.step, .permissions)
        XCTAssertTrue(recovered.state.shouldPresent && recovered.state.prefersTyping && recovered.state.wantsKnowledge)
        recovered.deferSetup()
        let deferred = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(deferred.state.shouldPresent)
        deferred.reopen()
        XCTAssertEqual(deferred.state.step, .permissions)
        deferred.complete()
        let complete = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(complete.state.shouldPresent)
        complete.reopen()
        XCTAssertEqual(complete.state.step, .language)
    }
    @MainActor func testExistingSettingsAndDataArePreserved() throws {
        let (suite, defaults) = defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.reasoningService = .compatible; settings.compatibleModel = "my-custom-model"
        settings.compatibleBaseURL = "https://example.invalid/v1"
        settings.language = .english; settings.automaticSuggestions = true
        settings.save(defaults: defaults)
        let original = defaults.data(forKey: "livecopilot.settings")
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(store.isNewInstall || store.state.shouldPresent)
        store.reopen(); store.state.advance(); store.complete()
        XCTAssertEqual(defaults.data(forKey: "livecopilot.settings"), original)
        XCTAssertEqual(AppSettings.load(defaults: defaults), settings)
        defaults.removeObject(forKey: "livecopilot.settings"); defaults.removeObject(forKey: OnboardingState.defaultsKey)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let history = root.appendingPathComponent("sessions/keep.json")
        try Data("historical-session".utf8).write(to: history)
        let legacy = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(legacy.isNewInstall || legacy.state.shouldPresent)
        XCTAssertEqual(try String(contentsOf: history), "historical-session")
    }
    func testCorruptSettingsDoNotBecomeNewUserAndNavigationIsBounded() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid-json".utf8), forKey: "livecopilot.settings")
        var state = OnboardingState.load(defaults: defaults, hasExistingData: false)
        XCTAssertFalse(state.shouldPresent)
        state.reopen(); state.back()
        XCTAssertEqual(state.step, .language)
        for _ in 0..<20 { state.advance() }
        XCTAssertEqual(state.step, .ready)
    }
    @MainActor func testDownloadQueueSkipsInstalledAndContinuesAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [LocalModelKind] = []
        let completed = expectation(description: "second model installed")
        let manager = LocalModelManager(root: root) { kind, location in
            started.append(kind)
            if kind == .streamingSpeech { throw CopilotError.message("fixture transfer failed") }
            try Self.writeInstalled(kind, root: location)
        }
        let subscription = manager.$installed.filter { $0.contains(.embedding) }.prefix(1).sink { _ in completed.fulfill() }
        manager.enqueue([.streamingSpeech, .embedding, .embedding])
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(started, [.streamingSpeech, .embedding])
        XCTAssertEqual(manager.failures[.streamingSpeech], "fixture transfer failed")
        manager.enqueue([.embedding])
        XCTAssertNil(manager.downloading)
        XCTAssertTrue(manager.queued.isEmpty)
        subscription.cancel(); await manager.shutdown()
    }
    @MainActor func testCancelDropsQueuedDownloadsAndKeepsExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeInstalled(.embedding, root: root)
        let started = expectation(description: "download started")
        var attempts: [LocalModelKind] = []
        let manager = LocalModelManager(root: root) { kind, _ in
            attempts.append(kind); started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        manager.enqueue([.streamingSpeech, .embedding])
        await fulfillment(of: [started], timeout: 3)
        manager.cancel(); await manager.shutdown()
        XCTAssertTrue(manager.queued.isEmpty)
        XCTAssertNil(manager.downloading)
        XCTAssertEqual(attempts, [.streamingSpeech])
        XCTAssertTrue(LocalModelKind.embedding.isInstalled(in: root))
    }
    func testProbeUsesNoConversationOrDocumentsAndRequiresText() async throws {
        XCTAssertTrue(AnalysisConnectionProbe.request.conversation.isEmpty)
        XCTAssertTrue(AnalysisConnectionProbe.request.sources.isEmpty)
        try await AnalysisConnectionProbe.run(provider: MockReasoningProvider())
        do {
            try await AnalysisConnectionProbe.run(provider: EmptyOnboardingProvider())
            XCTFail("An empty successful HTTP response must not verify the service")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no text")) }
    }
    @MainActor func testPreviewNeverDownloadsModels() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        coordinator.settings.listeningService = .paraformer; coordinator.settings.embeddingService = .local
        coordinator.onboarding.state.wantsKnowledge = true
        OnboardingDownloads.start(coordinator)
        XCTAssertNil(coordinator.localModels.downloading)
        XCTAssertFalse(coordinator.appleSpeech.busy || coordinator.laya.isBusy)
        await coordinator.shutdown()
    }
    @MainActor func testConnectionVerificationExpiresWhenConfigurationOrCredentialChanges() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        coordinator.settings.reasoningService = .separateOpenAI
        XCTAssertFalse(coordinator.isAnalysisConnectionVerified)
        try await coordinator.testAnalysisConnection()
        XCTAssertTrue(coordinator.isAnalysisConnectionVerified)
        coordinator.settings.language = .english
        XCTAssertTrue(coordinator.isAnalysisConnectionVerified, "language must not invalidate the same connection")
        coordinator.settings.reasoningModel = "another-model"
        XCTAssertFalse(coordinator.isAnalysisConnectionVerified)
        try await coordinator.testAnalysisConnection()
        XCTAssertTrue(coordinator.isAnalysisConnectionVerified)
        coordinator.refreshAnalysisKeyState()
        XCTAssertFalse(coordinator.isAnalysisConnectionVerified)
        await coordinator.shutdown()
    }
    @MainActor func testTypingPathSkipsSpeechAndDetectionDownloads() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        coordinator.settings.listeningService = .paraformer
        coordinator.settings.automaticSuggestions = true
        coordinator.onboarding.state.prefersTyping = true
        coordinator.onboarding.state.wantsKnowledge = false
        XCTAssertTrue(OnboardingDownloads.localKinds(coordinator).isEmpty)
        XCTAssertFalse(OnboardingDownloads.needsLaya(coordinator))
        coordinator.settings.listeningService = .apple
        XCTAssertFalse(OnboardingDownloads.needsApple(coordinator))
        await coordinator.shutdown()
    }
    private static func writeInstalled(_ kind: LocalModelKind, root: URL) throws {
        let location = kind.location(in: root)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var sizes: [String: Int64] = [:]
        for name in kind.files { try Data([1, 2, 3]).write(to: location.appendingPathComponent(name)); sizes[name] = 3 }
        try JSONEncoder().encode(sizes).write(to: location.appendingPathComponent("installed.json"))
    }

    @MainActor func testFirstUseTipsPersistAndPauseInsideGuide() throws {
        let (suite, defaults) = defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertEqual(store.tour.disposition, .pending)
        XCTAssertNil(store.visibleTip)
        store.isPresentingGuide = true
        store.deferSetup(); store.enterOverlay()
        XCTAssertNil(store.visibleTip)
        store.isPresentingGuide = false
        XCTAssertEqual(store.visibleTip, .start)
        store.advanceTip()
        let restored = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertEqual(restored.visibleTip, .answer)
        restored.advanceTip(); restored.advanceTip()
        XCTAssertEqual(restored.visibleTip, .captureExclusion)
        restored.advanceTip()
        XCTAssertNil(restored.visibleTip)
        XCTAssertEqual(restored.tour.disposition, .finished)
        restored.reopen(); restored.complete(); restored.enterOverlay()
        XCTAssertNil(restored.visibleTip, "reopening onboarding must not replay a finished tour")
        restored.replayTips(); XCTAssertEqual(restored.visibleTip, .start)
        restored.dismissTips()
        XCTAssertNil(OnboardingStore(defaults: defaults, dataDirectory: root).visibleTip)
    }

    @MainActor func testUpgradeDoesNotStartTipsAndLegacyGuideStillDecodes() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(#"{"version":1,"step":3,"disposition":"deferred","prefersTyping":true,"wantsKnowledge":false}"#.utf8)
        defaults.set(data, forKey: OnboardingState.defaultsKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertEqual(store.state.step, .analysis)
        XCTAssertTrue(store.state.prefersTyping)
        XCTAssertEqual(store.tour.disposition, .dismissed)
        store.enterOverlay(); XCTAssertNil(store.visibleTip)
        store.replayTips(); XCTAssertEqual(store.visibleTip, .start)
    }

    func testRecommendationChangesOnlyAdvertisedSettings() {
        var current = AppSettings()
        current.reasoningService = .compatible; current.compatibleModel = "keep-model"
        current.compatibleBaseURL = "https://example.invalid/v1"
        current.mode = .inPerson; current.language = .english
        current.recapEnabled = false; current.overlayEdgeHide = false
        current.automaticSuggestions = false
        let plan = OnboardingRecommendation(scenario: .defense, typing: false, appleReady: true)
        let updated = plan.applying(to: current)
        XCTAssertTrue(plan.wantsKnowledge)
        XCTAssertEqual(updated.listeningService, .apple)
        XCTAssertEqual(updated.embeddingService, .local)
        XCTAssertTrue(updated.automaticSuggestions)
        var expected = current
        expected.listeningService = .apple; expected.embeddingService = .local; expected.automaticSuggestions = true
        XCTAssertEqual(updated, expected, "provider, model, language, mode, tools and window choices must be retained")
        let meeting = OnboardingRecommendation(scenario: .meeting, typing: true, appleReady: false)
        XCTAssertFalse(meeting.wantsKnowledge)
        XCTAssertEqual(meeting.applying(to: current), current, "typing meeting guidance must leave audio and services unchanged")
    }

    func testJevRecommendationRespectsHardwareAndTyping() {
        var settings = AppSettings()
        settings.automaticSuggestions = true
        let unsupported = OnboardingRecommendation(scenario: .interview, typing: false, appleReady: false, jevSupported: false)
        XCTAssertFalse(unsupported.recommendsJev)
        XCTAssertFalse(unsupported.applying(to: settings).automaticSuggestions)
        let typing = OnboardingRecommendation(scenario: .meeting, typing: true, appleReady: false)
        XCTAssertFalse(typing.recommendsJev)
        XCTAssertEqual(typing.applying(to: settings).automaticSuggestions, settings.automaticSuggestions)
    }

    @MainActor func testApplyingRecommendationNeverStartsDownloadOrSession() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        coordinator.settings.scenario = .interview
        coordinator.onboarding.state.prefersTyping = true
        let originalSpeech = coordinator.settings.listeningService
        OnboardingRecommendation.apply(coordinator)
        XCTAssertTrue(coordinator.onboarding.state.wantsKnowledge)
        XCTAssertEqual(coordinator.settings.listeningService, originalSpeech)
        XCTAssertEqual(coordinator.settings.embeddingService, .local)
        XCTAssertNil(coordinator.localModels.downloading)
        XCTAssertFalse(coordinator.appleSpeech.busy || coordinator.laya.isBusy || coordinator.isRunning)
        XCTAssertTrue(coordinator.transcript.lines.isEmpty)
        coordinator.onboarding.state.prefersTyping = false
        coordinator.settings.automaticSuggestions = false
        OnboardingRecommendation.apply(coordinator)
        XCTAssertEqual(coordinator.settings.automaticSuggestions, coordinator.laya.state != .unsupported)
        XCTAssertNil(coordinator.localModels.downloading)
        XCTAssertTrue(coordinator.localModels.queued.isEmpty)
        XCTAssertFalse(coordinator.appleSpeech.busy || coordinator.laya.isBusy || coordinator.isRunning)
        XCTAssertTrue(coordinator.transcript.lines.isEmpty)
        await coordinator.shutdown()
    }

    @MainActor func testGuidancePreventsEdgeRevealAndAutoHideWithoutChangingPreference() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No display") }
        let panel = OverlayWindow(rootView: Text("Tour fixture"))
        defer { panel.close() }
        panel.configure(autoHeight: true, edgeHide: true)
        panel.setupWindowVisible = true
        let now = ProcessInfo.processInfo.systemUptime
        let edge = NSPoint(x: screen.frame.maxX - 1, y: screen.visibleFrame.midY)
        panel.updatePointer(edge, now: now, interacting: false)
        panel.updatePointer(edge, now: now + 1, interacting: false)
        XCTAssertFalse(panel.isVisible, "onboarding must suppress edge-triggered reveals")
        panel.setupWindowVisible = false
        panel.guidanceActive = true
        panel.reveal()
        let outside = NSPoint(x: screen.frame.minX + 20, y: screen.visibleFrame.midY)
        panel.updatePointer(outside, now: now + 3, interacting: false)
        panel.updatePointer(outside, now: now + 5, interacting: false)
        XCTAssertTrue(panel.isVisible, "tips must stay visible while being read")
        XCTAssertTrue(panel.edgeHide, "guidance must not rewrite the user's pin preference")
        panel.tuckAway(animated: false)
        panel.updatePointer(edge, now: now + 5.2, interacting: false)
        panel.updatePointer(edge, now: now + 5.5, interacting: false)
        XCTAssertTrue(panel.isVisible, "manually hidden tips can still be recovered from the edge")
        panel.guidanceActive = false
        panel.updatePointer(outside, now: now + 6, interacting: false)
        panel.updatePointer(outside, now: now + 8, interacting: false)
        XCTAssertTrue(panel.edgeHidden, "ordinary edge hiding resumes after the tour")
    }
}

private struct EmptyOnboardingProvider: ReasoningProvider {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}
