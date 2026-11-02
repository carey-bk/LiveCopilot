import XCTest
import Combine
import SwiftUI
@testable import LiveCopilot

final class OnboardingTests: XCTestCase {
    @MainActor func testVersion23SkippedGuideRetainsSavedParaformerOnUpgrade() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRun = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertTrue(firstRun.isNewInstall)
        // v2.3.0 saves this literal at first launch, before any model download.
        defaults.set(Data(#"{"listeningService":"paraformer","embeddingService":"local","reasoningService":"separateOpenAI"}"#.utf8), forKey: "livecopilot.settings")
        firstRun.deferSetup()
        let upgraded = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertFalse(upgraded.isNewInstall)
        XCTAssertEqual(upgraded.state.disposition, .deferred)
        XCTAssertEqual(AppSettings.load(defaults: defaults).listeningService, .paraformer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testSkippingFreshGuideKeepsZipformerWithoutDownloading() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertTrue(store.isNewInstall)
        let settings = AppSettings.load(defaults: defaults)
        XCTAssertEqual(settings.listeningService, .zipformer)
        store.deferSetup()
        settings.save(defaults: defaults)
        let reopened = OnboardingStore(defaults: defaults, dataDirectory: root)
        XCTAssertEqual(reopened.state.disposition, .deferred)
        XCTAssertEqual(AppSettings.load(defaults: defaults).listeningService, .zipformer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        var chosen = settings
        chosen.listeningService = .paraformer
        chosen.save(defaults: defaults)
        XCTAssertEqual(AppSettings.load(defaults: defaults).listeningService, .paraformer)
    }

    @MainActor func testNewGuideDefaultsToMixedLanguagesAndKnowledgeForEveryAnswerStyle() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        for scenario in ScenarioProfile.allCases {
            app.onboarding.state = OnboardingState()
            app.settings.scenario = scenario
            OnboardingRecommendation.applyInitialIfNeeded(app)
            XCTAssertEqual(app.onboarding.state.speechScenario, .mixedInterview)
            XCTAssertEqual(app.settings.listeningService, .zipformer)
            XCTAssertTrue(app.onboarding.state.wantsKnowledge)
            XCTAssertEqual(app.onboarding.state.knowledgeRequested, true)
        }
        OnboardingRecommendation.selectScenario(.singleLanguage, coordinator: app)
        OnboardingRecommendation.selectKnowledge(false, coordinator: app)
        OnboardingRecommendation.applyInitialIfNeeded(app)
        XCTAssertEqual(app.onboarding.state.speechScenario, .singleLanguage)
        XCTAssertFalse(app.onboarding.state.wantsKnowledge, "Defaults must not overwrite a saved choice on return")
        await app.shutdown()
    }
    @MainActor func testFirstVisitRecommendsOnceAndPreservesCustomSetupOnReturn() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.onboarding.state.localSetupReviewed = false
        OnboardingRecommendation.applyInitialIfNeeded(app)
        XCTAssertTrue(OnboardingRecommendation.current(app).matches(app))
        app.settings.listeningService = .openAI
        app.onboarding.state.wantsKnowledge = false
        OnboardingRecommendation.applyInitialIfNeeded(app)
        XCTAssertEqual(app.settings.listeningService, .openAI)
        XCTAssertFalse(app.onboarding.state.wantsKnowledge)
        XCTAssertEqual(OnboardingState.load(defaults: defaults, hasExistingData: false).localSetupReviewed, true)
        // Old serialized guides have no review marker and must retain their choices.
        let legacy = Data(#"{"version":1,"step":2,"disposition":"inProgress","prefersTyping":false,"wantsKnowledge":false}"#.utf8)
        app.onboarding.state = try JSONDecoder().decode(OnboardingState.self, from: legacy)
        OnboardingRecommendation.applyInitialIfNeeded(app)
        XCTAssertEqual(app.settings.listeningService, .openAI)
        XCTAssertFalse(app.onboarding.state.wantsKnowledge)
        await app.shutdown()
    }

    func testSpeechScenarioRecommendationsUseLanguageNeedsAndHardware() {
        XCTAssertEqual(OnboardingSpeechScenario.mixedInterview.engine(appleAvailable: true), .zipformer)
        XCTAssertEqual(OnboardingSpeechScenario.singleLanguage.engine(appleAvailable: true), .apple)
        XCTAssertEqual(OnboardingSpeechScenario.singleLanguage.engine(appleAvailable: false), .zipformer)
        XCTAssertEqual(OnboardingSpeechScenario.multilingualMeeting.engine(appleAvailable: false), .openAI)
        let multilingual = OnboardingRecommendation(scenario: .interview, typing: false, appleReady: false,
                                                    jevSupported: false, speechScenario: .multilingualMeeting)
        XCTAssertTrue(multilingual.recommendsJev, "Cloud question detection does not require local Laya hardware")
    }
    @MainActor func testLanguageAndKnowledgeChoicesDriveTheSameSavedDownloadPlan() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        OnboardingRecommendation.applyInitialIfNeeded(app)
        for needsKnowledge in [false, true] {
            OnboardingRecommendation.selectKnowledge(needsKnowledge, coordinator: app)
            for scene in OnboardingSpeechScenario.allCases {
                OnboardingRecommendation.selectScenario(scene, coordinator: app)
                OnboardingRecommendation.apply(app)
                XCTAssertEqual(app.settings.listeningService, scene.engine(appleAvailable: app.appleSpeech.available))
                XCTAssertEqual(app.onboarding.state.wantsKnowledge, needsKnowledge)
                XCTAssertEqual(OnboardingRecommendation.current(app).wantsKnowledge, needsKnowledge)
                let setup = OnboardingSetupSnapshot(app)
                XCTAssertEqual(setup[.knowledge].enabled, needsKnowledge)
                XCTAssertEqual(setup.resources.contains { $0.kind == .local(.embedding) }, needsKnowledge)
                let saved = OnboardingState.load(defaults: defaults, hasExistingData: false)
                XCTAssertEqual(saved.knowledgeRequested, needsKnowledge)
                XCTAssertEqual(saved.wantsKnowledge, needsKnowledge)
                XCTAssertEqual(AppSettings.load(defaults: defaults), app.settings)
            }
        }
        OnboardingRecommendation.selectSpeech(.paraformer, coordinator: app)
        app.settings.automaticSuggestions = false
        let original = app.settings
        OnboardingRecommendation.selectKnowledge(false, coordinator: app)
        XCTAssertEqual(app.settings, original, "Disabling knowledge must retain manual speech, Jev and provider settings")
        OnboardingRecommendation.selectScenario(.multilingualMeeting, coordinator: app)
        XCTAssertEqual(app.settings.listeningService, .paraformer)
        XCTAssertFalse(app.onboarding.state.wantsKnowledge)
        XCTAssertNil(app.localModels.downloading)
        XCTAssertTrue(app.localModels.queued.isEmpty)
        XCTAssertFalse(app.appleSpeech.busy || app.laya.isBusy || app.isRunning)
        await app.shutdown()
    }
    @MainActor func testOlderGuidesKeepKnowledgeChoiceWhenChangingLanguagesOrRestoring() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        for enabled in [false, true] {
            app.onboarding.state = try JSONDecoder().decode(OnboardingState.self, from: Data("{\"version\":1,\"step\":2,\"disposition\":\"inProgress\",\"prefersTyping\":false,\"wantsKnowledge\":\(enabled)}".utf8))
            OnboardingRecommendation.selectScenario(.multilingualMeeting, coordinator: app)
            OnboardingRecommendation.apply(app)
            XCTAssertEqual(app.onboarding.state.wantsKnowledge, enabled)
            XCTAssertEqual(app.onboarding.state.knowledgeRequested, enabled)
        }
        await app.shutdown()
    }
    @MainActor func testScenarioOverrideRestoreAndSavedConfigurationStayConsistent() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.reasoningService = .compatible; app.settings.compatibleModel = "keep-model"
        app.settings.language = .english; app.settings.overlayEdgeHide = false
        app.onboarding.state.knowledgeRequested = true
        app.onboarding.state.speechScenario = .mixedInterview
        OnboardingRecommendation.apply(app)
        XCTAssertEqual(app.settings.listeningService, .zipformer)
        OnboardingRecommendation.selectScenario(.multilingualMeeting, coordinator: app)
        XCTAssertEqual(app.settings.listeningService, .openAI)
        XCTAssertEqual(app.settings.liveSpeechLanguage, .unrestricted)
        OnboardingRecommendation.selectSpeech(.paraformer, coordinator: app)
        OnboardingRecommendation.selectScenario(.singleLanguage, coordinator: app)
        XCTAssertEqual(app.settings.listeningService, .paraformer, "Keep the explicit override")
        XCTAssertEqual(app.onboarding.state.speechManuallySelected, true)
        let before = app.settings
        OnboardingRecommendation.apply(app)
        XCTAssertEqual(app.settings.listeningService, app.appleSpeech.available ? .apple : .zipformer)
        var expected = before
        expected.listeningService = app.appleSpeech.available ? .apple : .zipformer
        expected.embeddingService = .local; expected.automaticSuggestions = app.laya.state != .unsupported
        XCTAssertEqual(app.settings, expected, "Restore must not touch the answer provider, language, window or unrelated settings")
        XCTAssertEqual(AppSettings.load(defaults: defaults), app.settings)
        let saved = OnboardingState.load(defaults: defaults, hasExistingData: false)
        XCTAssertEqual(saved.speechScenario, .singleLanguage)
        XCTAssertEqual(saved.speechManuallySelected, false)
        let snapshot = OnboardingSetupSnapshot(app)
        XCTAssertEqual(OnboardingDownloads.requiresDownload(app), snapshot.needsDownload)
        // A selection changed in Settings while the guide is open is also a manual override.
        app.settings.listeningService = .openAI
        OnboardingRecommendation.selectScenario(.mixedInterview, coordinator: app)
        XCTAssertEqual(app.settings.listeningService, .openAI)
        XCTAssertEqual(app.onboarding.state.speechManuallySelected, true)
        await app.shutdown()
    }
    func testDownloadInventoryTracksActualSelectionQueueCompletionAndUnknownSizes() {
        var settings = AppSettings(); settings.listeningService = .paraformer
        settings.embeddingService = .local; settings.automaticSuggestions = true
        var state = OnboardingState(); state.wantsKnowledge = true
        var inventory = OnboardingSetupInventory()
        var setup = OnboardingSetupSnapshot(settings: settings, state: state, inventory: inventory)
        XCTAssertEqual(setup.resources.map(\.kind), [.local(.streamingSpeech), .local(.embedding), .laya])
        XCTAssertEqual(setup.knownBytes, 1_639_207_344)
        XCTAssertEqual(setup.unknownSizeCount, 0)
        XCTAssertEqual(setup.resources.last?.bytes, 766_807_229, "Include Python, wheels, source and model assets from bundled pins")
        inventory.layaDownloadBytes = nil
        XCTAssertEqual(OnboardingSetupSnapshot(settings: settings, state: state, inventory: inventory).unknownSizeCount, 1, "Missing manifests must not invent a size")
        inventory.downloading = .streamingSpeech; inventory.queued = [.embedding]
        inventory.layaState = .installing
        setup = .init(settings: settings, state: state, inventory: inventory)
        XCTAssertFalse(setup.needsDownload, "Do not enqueue or download already active resources again")
        XCTAssertTrue(setup.hasActiveTransfers)
        inventory.installed = [.streamingSpeech, .embedding]; inventory.downloading = nil; inventory.queued = []
        inventory.layaInstalled = true; inventory.layaState = .installed
        setup = .init(settings: settings, state: state, inventory: inventory)
        XCTAssertTrue(setup.resources.isEmpty)
        XCTAssertTrue(setup.needsLayaLoad)
        XCTAssertEqual(setup[.speech].status, .installed)
        XCTAssertEqual(setup[.proactive].status, .installed)
        inventory.speechRuntime = .loading; inventory.knowledgeRuntime = .failed; inventory.layaState = .ready
        setup = .init(settings: settings, state: state, inventory: inventory)
        XCTAssertEqual(setup[.speech].status, .verifying)
        XCTAssertEqual(setup[.knowledge].status, .loadFailed)
        XCTAssertEqual(setup[.proactive].status, .ready)
        inventory.speechRuntime = .ready
        XCTAssertEqual(OnboardingSetupSnapshot(settings: settings, state: state, inventory: inventory)[.speech].status, .ready)
        state.prefersTyping = true; state.wantsKnowledge = false
        setup = .init(settings: settings, state: state, inventory: inventory)
        XCTAssertTrue(setup.resources.isEmpty)
        XCTAssertFalse(setup.needsLayaLoad)
        XCTAssertTrue(setup.capabilities.allSatisfy { !$0.enabled })
    }
    func testAppleLanguageChecksAndUnusedTransfersAreNotMisrepresented() {
        var settings = AppSettings(); settings.listeningService = .apple
        settings.automaticSuggestions = false
        var inventory = OnboardingSetupInventory(); inventory.appleAvailable = true
        inventory.appleInstalled = true; inventory.appleChecked = false
        var setup = OnboardingSetupSnapshot(settings: settings, state: OnboardingState(), inventory: inventory)
        XCTAssertEqual(setup[.speech].status, .verify)
        XCTAssertTrue(setup.resources.isEmpty, "Wait for the current language's actual status")
        inventory.appleChecked = true; inventory.appleInstalled = false
        setup = .init(settings: settings, state: OnboardingState(), inventory: inventory)
        XCTAssertEqual(setup.resources.count, 1); XCTAssertNil(setup.resources.first?.bytes)
        XCTAssertEqual(setup.resources.first?.kind, .apple(settings.appleSpeechLanguage))
        inventory.appleInstalled = true; inventory.downloading = .embedding
        setup = .init(settings: settings, state: OnboardingState(), inventory: inventory)
        XCTAssertEqual(setup[.speech].status, .ready)
        XCTAssertTrue(setup.resources.isEmpty)
        XCTAssertEqual(setup.backgroundOnly, [LocalModelKind.embedding.title])
    }
    func testKnownSizesMatchPinnedDistributionManifestAndUnknownDigestStaysUnknown() throws {
        // Bundled test resources, not `#filePath`: reading the checkout from the test host prompts for
        // Documents access whenever the worktree is under ~/Documents and the ad-hoc signature changes.
        let resources = Bundle(for: Self.self)
        let manifest = try XCTUnwrap(resources.url(forResource: "oss-model-manifest", withExtension: "json"))
        let zipManifest = try XCTUnwrap(resources.url(forResource: "zipformer-model-manifest", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let zip = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: zipManifest)) as? [String: Any])
        let entries = try XCTUnwrap(object["objects"] as? [[String: Any]]) + XCTUnwrap(zip["objects"] as? [[String: Any]])
        for kind in LocalModelKind.allCases {
            for download in kind.downloads {
                let entry = try XCTUnwrap(entries.first { $0["sha256"] as? String == download.sha256 })
                XCTAssertEqual(download.knownByteCount, (entry["size"] as? NSNumber)?.int64Value)
            }
        }
        let unknown = ModelDownload(url: URL(string: "https://example.invalid/model")!, sha256: "future-digest", name: "fixture")
        XCTAssertNil(unknown.knownByteCount)
    }
    @MainActor func testQuickStartKeepsSelectionsAndStartsNoNewDownloads() async throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.onboarding.state.step = .models; app.onboarding.state.speechScenario = .mixedInterview
        OnboardingRecommendation.apply(app)
        let settings = app.settings, wantsKnowledge = app.onboarding.state.wantsKnowledge
        OnboardingDownloads.skip(app)
        XCTAssertEqual(app.onboarding.state.step, .analysis)
        XCTAssertEqual(app.settings, settings)
        XCTAssertEqual(app.onboarding.state.wantsKnowledge, wantsKnowledge)
        XCTAssertNil(app.localModels.downloading); XCTAssertTrue(app.localModels.queued.isEmpty)
        XCTAssertFalse(app.appleSpeech.busy || app.laya.isBusy || app.isRunning)
        XCTAssertEqual(AppSettings.load(defaults: defaults), settings)
        XCTAssertEqual(OnboardingState.load(defaults: defaults, hasExistingData: false).step, .analysis)
        await app.shutdown()
    }

    func testCapabilityBadgesRequireVerifiedReadiness() {
        XCTAssertEqual(OnboardingCapabilityStatus.laya(.notInstalled), .download)
        XCTAssertEqual(OnboardingCapabilityStatus.laya(.installed), .installed)
        XCTAssertEqual(OnboardingCapabilityStatus.laya(.loading), .verifying)
        XCTAssertEqual(OnboardingCapabilityStatus.laya(.ready), .ready)
        XCTAssertEqual(OnboardingCapabilityStatus.laya(.failed), .attention)
        XCTAssertEqual(OnboardingCapabilityStatus.apple(available: true, installed: true, busy: false, verified: false), .verify,
                       "Cached readiness for a different language must not show Ready")
        XCTAssertEqual(OnboardingCapabilityStatus.apple(available: true, installed: true, busy: false, verified: true), .ready)
        XCTAssertEqual(OnboardingCapabilityStatus.apple(available: true, installed: false, busy: false, verified: true), .download)
    }
    @MainActor func testInstalledLocalFilesAreNotRuntimeVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root)
        XCTAssertEqual(OnboardingCapabilityStatus.local(.streamingSpeech, models: manager), .download)
        try Self.writeInstalled(.streamingSpeech, root: root)
        manager.refresh()
        XCTAssertEqual(OnboardingCapabilityStatus.local(.streamingSpeech, models: manager), .installed)
        await manager.shutdown()
    }
    @MainActor func testLocalCapabilitiesPageRendersAtOriginalSize() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in page rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            for scene in OnboardingSpeechScenario.allCases {
                for size in [NSSize(width: 1040, height: 660), NSSize(width: 1280, height: 800)] {
                    let (suite, defaults) = defaults()
                    let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                             mockKnowledgeDirectory: root.appendingPathComponent(suite))
                    app.settings.language = language
                    app.onboarding.state.step = .models; app.onboarding.state.localSetupReviewed = true
                    app.onboarding.state.knowledgeRequested = true
                    app.onboarding.state.speechScenario = scene
                    OnboardingRecommendation.apply(app)
                    let host = NSHostingView(rootView: OnboardingView(coordinator: app, close: {}, beginListening: {}, beginTyping: {}))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.bounds.size, size)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("scenario-\(scene.rawValue)-\(language.rawValue)-\(Int(size.width)).png"))
                    OnboardingRecommendation.selectKnowledge(false, coordinator: app)
                    host.layoutSubtreeIfNeeded()
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("no-knowledge-\(scene.rawValue)-\(language.rawValue)-\(Int(size.width)).png"))
                    window.orderOut(nil)
                    await app.shutdown()
                    defaults.removePersistentDomain(forName: suite)
                }
            }
        }
    }
    @MainActor func testCombinedReadyPageRendersAtSupportedSizes() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in page rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            for size in [NSSize(width: 1040, height: 660), NSSize(width: 1280, height: 800)] {
                let (suite, defaults) = defaults()
                let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                         mockKnowledgeDirectory: root.appendingPathComponent(suite))
                app.settings.language = language; app.settings.listeningService = .paraformer
                app.settings.embeddingService = .local
                app.settings.automaticSuggestions = true
                app.onboarding.state.wantsKnowledge = true; app.onboarding.state.step = .ready
                let host = NSHostingView(rootView: OnboardingView(coordinator: app, close: {}, beginListening: {}, beginTyping: {}))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("ready-\(language.rawValue)-\(Int(size.width)).png"))
                window.orderOut(nil); await app.shutdown(); defaults.removePersistentDomain(forName: suite)
            }
        }
    }

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
        let finished = expectation(description: "download and verification finished")
        let manager = LocalModelManager(root: root, embeddingVerifier: { _ in }) { kind, location in
            started.append(kind)
            if kind == .streamingSpeech { throw CopilotError.message("fixture transfer failed") }
            try Self.writeInstalled(kind, root: location)
        }
        let subscription = manager.$installed.filter { $0.contains(.embedding) }.prefix(1).sink { _ in completed.fulfill() }
        let done = manager.$downloading.dropFirst().filter { $0 == nil && manager.embeddingVerification.isReady }.prefix(1).sink { _ in finished.fulfill() }
        manager.enqueue([.streamingSpeech, .embedding, .embedding])
        await fulfillment(of: [completed, finished], timeout: 5)
        XCTAssertEqual(started, [.streamingSpeech, .embedding])
        XCTAssertEqual(manager.failures[.streamingSpeech], "fixture transfer failed")
        await manager.shutdown()
        manager.enqueue([.embedding])
        XCTAssertNil(manager.downloading)
        XCTAssertTrue(manager.queued.isEmpty)
        subscription.cancel(); done.cancel(); await manager.shutdown()
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
        XCTAssertEqual(updated.listeningService, .zipformer)
        XCTAssertEqual(updated.embeddingService, .local)
        XCTAssertTrue(updated.automaticSuggestions)
        var expected = current
        expected.listeningService = .zipformer; expected.embeddingService = .local; expected.automaticSuggestions = true
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
        coordinator.onboarding.state.knowledgeRequested = true
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

    @MainActor func testFinishingGuideKeepsOverlayVisibleUntilFirstPointerVisit() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No display") }
        let panel = OverlayWindow(rootView: Text("Onboarding handoff"))
        defer { panel.close() }
        panel.configure(autoHeight: true, edgeHide: true)
        panel.revealAfterOnboarding()
        let now = ProcessInfo.processInfo.systemUptime
        let outside = NSPoint(x: screen.frame.minX + 20, y: screen.visibleFrame.midY)
        panel.updatePointer(outside, now: now + 30, interacting: false)
        panel.updatePointer(outside, now: now + 60, interacting: false)
        XCTAssertTrue(panel.isVisible && !panel.edgeHidden, "completed or dismissed tours must still hand off to a visible window")
        XCTAssertTrue(panel.edgeHide, "handoff must preserve auto-hide preference")
        panel.updatePointer(NSPoint(x: panel.frame.midX, y: panel.frame.midY), now: now + 61, interacting: false)
        panel.updatePointer(outside, now: now + 62, interacting: false)
        panel.updatePointer(outside, now: now + 64, interacting: false)
        XCTAssertTrue(panel.edgeHidden, "after the first visit, ordinary auto-hide resumes")
        panel.revealAfterOnboarding()
        panel.tuckAway(animated: false)
        XCTAssertFalse(panel.isVisible, "explicit hide must always take precedence")
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
