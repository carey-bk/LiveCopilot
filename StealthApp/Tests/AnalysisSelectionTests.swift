import XCTest
import SwiftUI
@testable import LiveCopilot

final class AnalysisSelectionTests: XCTestCase {
    func testCompatiblePresetsUseDistinctCredentialScopesAndValidEndpoints() throws {
        var accounts = Set<String>()
        XCTAssertEqual(CompatibleServicePreset.all.count, 7)
        for preset in CompatibleServicePreset.all {
            var settings = AppSettings()
            settings.reasoningService = .compatible
            settings.compatibleBaseURL = preset.baseURL
            settings.compatiblePath = preset.path
            settings.compatibleModel = "test-model"
            let endpoint = try settings.compatibleEndpoint()
            XCTAssertEqual(endpoint.absoluteString, preset.baseURL + "/chat/completions")
            XCTAssertEqual(endpoint.scheme, "https")
            XCTAssertEqual(CompatibleServicePreset.matching(baseURL: preset.baseURL + "/", path: preset.path)?.id, preset.id)
            accounts.insert(try settings.analysisCredentialReference().account)
        }
        XCTAssertEqual(accounts.count, CompatibleServicePreset.all.count)
        XCTAssertNil(CompatibleServicePreset.matching(baseURL: "https://example.org/v1", path: "chat/completions"))
        XCTAssertNil(CompatibleServicePreset.matching(baseURL: "https://openrouter.ai/api/v1", path: "responses"))
    }

    func testBillingAuthenticationAndRateLimitRemainDistinctAndPrivate() throws {
        let cases: [(Int, String, OnboardingConnectionFailure)] = [
            (429, "insufficient_quota", .billing), (429, "credit_balance_exhausted", .billing),
            (400, "Arrearage", .billing), (403, "insufficient_balance", .billing),
            (402, "unknown_error", .billing), (429, "rate_limit_exceeded", .rateLimit),
            (401, "invalid_api_key", .authentication), (400, "expired_api_key", .authentication),
            (503, "server_error", .service)]
        for (status, code, expected) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "sk-private-secret"]])
            let error = ServiceHTTPFailure(status: status, data: body)
            XCTAssertEqual(OnboardingConnectionFailure.classify(error), expected)
            XCTAssertEqual(OnboardingConnectionFailure.classify(CopilotError.message(error.localizedDescription)), expected)
            XCTAssertFalse(error.localizedDescription.contains("sk-private"))
            XCTAssertFalse(L10n.text(error.localizedDescription, language: .simplifiedChinese).contains("sk-private"))
        }
        let typed = Data(#"{"error":{"type":"insufficient_quota","code":null}}"#.utf8)
        XCTAssertEqual(ServiceHTTPFailure(status: 429, data: typed).kind, .billing)
        // Never infer lack of funds from a permission denial or an untrusted message.
        let arbitrary = Data(#"{"error":{"message":"expired_api_key insufficient_quota sk-private"}}"#.utf8)
        XCTAssertEqual(ServiceHTTPFailure(status: 403, data: arbitrary).kind, .permission)
        XCTAssertTrue(OnboardingConnectionFailure.authentication.detail(.simplifiedChinese).contains("过期"))
        XCTAssertTrue(OnboardingConnectionFailure.billing.detail(.simplifiedChinese).contains("充值"))
        XCTAssertFalse(OnboardingConnectionFailure.network.detail(.simplifiedChinese).contains("充值"))
    }

    func testEmbeddingAndStreamingErrorsPreserveProviderCodes() async throws {
        let body = Data(#"{"error":{"code":"insufficient_quota","message":"private-content"}}"#.utf8)
        let transport = CredentialFailureTransport(body: body)
        let embedding = OpenAIEmbeddingProvider(key: "fixture", model: "fixture", transport: transport)
        do { _ = try await embedding.embed(["Connection test"]); XCTFail("Unexpected success") }
        catch { XCTAssertEqual(OnboardingConnectionFailure.classify(error), .billing) }
        let reasoning = OpenAIReasoningProvider(key: "fixture", model: "gpt-6-sol", transport: transport)
        do { try await AnalysisConnectionProbe.run(provider: reasoning); XCTFail("Unexpected success") }
        catch { XCTAssertEqual(OnboardingConnectionFailure.classify(error), .billing) }
        let event: [String: Any] = ["type": "error", "error": ["code": "insufficient_quota", "message": "private-content"]]
        guard case .failed(let message) = LiveProtocol.parse(event, speaker: .them) else { return XCTFail("Missing failure") }
        XCTAssertEqual(OnboardingConnectionFailure.classify(CopilotError.message(message)), .billing)
        XCTAssertFalse(message.contains("private"))
    }

    @MainActor func testCredentialRowVisualAcceptance() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in credential rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "LiveCopilot-Credential-Render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults, mockKnowledgeDirectory: root.appendingPathComponent(suite))
        app.settings.reasoningService = .separateOpenAI
        try await app.testAnalysisConnection()
        for language in [AppLanguage.simplifiedChinese, .english] {
            app.settings.language = language
            for width: CGFloat in [560, 740] {
                let view = VStack(alignment: .leading, spacing: 20) {
                    OnboardingServiceSection(number: 2, title: "API Key") {
                        CredentialEditor(coordinator: app, analysis: true, onboarding: true, analysisLayout: true)
                    }
                    OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true, failure: .billing)
                    OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true, failure: .authentication)
                }.padding(20).frame(width: width).background(Color.white).preferredColorScheme(.light)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("credentials-\(language.rawValue)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
        await app.shutdown()
    }

    func testMetricDisplayPrecision() {
        XCTAssertEqual(MetricDisplayFormat.value("1.15", latency: true), "1.2")
        XCTAssertEqual(MetricDisplayFormat.value("2", latency: true), "2.0")
        XCTAssertEqual(MetricDisplayFormat.value("222.9", latency: false), "222")
        XCTAssertEqual(MetricDisplayFormat.value("1.15–3.45", latency: true), "1.2–3.5")
        XCTAssertNil(MetricDisplayFormat.value(nil, latency: true))
    }
    func testBlurDigitsOnlyChangeEditedPlacesWithThirtyMillisecondStagger() {
        let initial = NumericBlurTransition.slots("3.07", integerPlaces: 3)
        var transition = NumericBlurTransition(initial)
        XCTAssertFalse(transition.isActive(at: 10))
        transition.update(NumericBlurTransition.slots("1.13", integerPlaces: 3), at: 10, reduceMotion: false)
        XCTAssertEqual(transition.cells[2].start, 10)
        XCTAssertEqual(transition.cells[4].start, 10.03, accuracy: 0.000001)
        XCTAssertEqual(transition.cells[5].start, 10.06, accuracy: 0.000001)
        XCTAssertEqual(transition.cells[3].glyphs(at: 10.1).map(\.character), ["."])
        XCTAssertEqual(transition.cells[3].glyphs(at: 10.1).first?.blur, 0)
        let halfway = transition.cells[2].glyphs(at: 10.125)
        XCTAssertEqual(halfway.map(\.character), ["3", "1"])
        XCTAssertEqual(halfway.reduce(0) { $0 + $1.opacity }, 1, accuracy: 0.000001)
        XCTAssertTrue(halfway.allSatisfy { $0.opacity > 0 && $0.opacity < 1 && $0.blur > 0 })
        XCTAssertEqual(transition.cells[4].glyphs(at: 10.02).map(\.character), ["0"], "Later characters remain untouched during their delay")
        XCTAssertTrue(transition.isActive(at: 10.30))
        XCTAssertFalse(transition.isActive(at: 10.32))
        let finished = transition.cells.flatMap { $0.glyphs(at: 10.32) }
        XCTAssertEqual(String(finished.map(\.character)), "1.13")
        XCTAssertTrue(finished.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
        let starts = transition.cells.map(\.start)
        transition.update(NumericBlurTransition.slots("1.13", integerPlaces: 3), at: 11, reduceMotion: false)
        XCTAssertEqual(transition.cells.map(\.start), starts, "Unchanged numbers never replay their animation")
    }

    func testBlurDigitsKeepDecimalPositionsAndSurviveRapidChangesAndReducedMotion() {
        let short = NumericBlurTransition.slots("9.99", integerPlaces: 3)
        let long = NumericBlurTransition.slots("100.00", integerPlaces: 3)
        XCTAssertEqual(short.count, long.count)
        XCTAssertEqual(short.firstIndex(of: "."), long.firstIndex(of: "."))
        var transition = NumericBlurTransition(short)
        transition.update(long, at: 20, reduceMotion: false)
        let before = transition.cells[2].glyphs(at: 20.12)
        transition.update(NumericBlurTransition.slots("111.11", integerPlaces: 3), at: 20.12, reduceMotion: false)
        let after = transition.cells[2].glyphs(at: 20.12)
        XCTAssertEqual(before.map(\.character), after.map(\.character))
        XCTAssertEqual(before.map(\.opacity), after.map(\.opacity), "An interrupted change starts at the visible composite")
        XCTAssertEqual(before.map(\.blur), after.map(\.blur))
        transition.update(NumericBlurTransition.slots("0.67", integerPlaces: 3), at: 20.13, reduceMotion: true)
        XCTAssertFalse(transition.isActive(at: 20.13))
        let settled = transition.cells.flatMap { $0.glyphs(at: 20.13) }
        XCTAssertEqual(String(settled.map(\.character)), "0.67")
        XCTAssertTrue(settled.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
    }

    @MainActor func testBlurAnimationAndCapabilityBadgesRender() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in animation rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Check the number itself, not just its fixed-size containing window.
        for size in [CGFloat(14), 21, 28] {
            let compact = NSHostingView(rootView: StaggeredBlurNumber("3.07", prefix: "≈ ", suffix: " s", size: size, leadingAligned: true))
            let expanded = NSHostingView(rootView: StaggeredBlurNumber("320.85", prefix: "≈ ", suffix: " s", size: size, leadingAligned: true))
            XCTAssertEqual(compact.fittingSize, expanded.fittingSize)
        }
        let values = BlurNumberPreviewValues()
        let host = NSHostingView(rootView: BlurNumberPreview(values: values))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 440, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(100))
        try capture("blur-initial")
        let initialSize = host.fittingSize
        values.number = "1.13"
        for (name, wait) in [("blur-030ms", 30), ("blur-100ms", 70), ("blur-200ms", 100), ("blur-complete", 220)] {
            try await Task.sleep(for: .milliseconds(wait))
            try capture(name)
            XCTAssertEqual(host.fittingSize, initialSize, "Character changes must not change the layout")
        }
        values.number = "320.85"
        try await Task.sleep(for: .milliseconds(40))
        values.number = "2.75"
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(host.fittingSize, initialSize, "Changing digit counts keeps the same width and baseline")
        try capture("blur-interrupted-complete")
    }

    func testExplicitProviderChoiceAppliesRecommendationWithoutChangingEndpoint() throws {
        var settings = AppSettings()
        settings.reasoningModel = "gpt-6.1-sol"; settings.reasoningEffort = "high"; settings.openAIProcessing = .fast
        settings.glmConnection.baseURL = "https://api.z.ai/api/paas/v4"
        settings.glmConnection.model = "glm-5.3-flash"; settings.glmConnection.thinking = .max
        settings.selectRecommendedAnalysisService(.glm)
        XCTAssertEqual(settings.analysisModel, "glm-5.3-flashx")
        XCTAssertEqual(settings.analysisThinking, .low)
        XCTAssertTrue(settings.usesRecommendedAnalysis)
        XCTAssertEqual(settings.glmConnection.baseURL, "https://api.z.ai/api/paas/v4")
        settings.selectRecommendedAnalysisService(.separateOpenAI)
        XCTAssertEqual(settings.analysisModel, "gpt-6-sol")
        XCTAssertEqual(settings.analysisThinking, .low)
        XCTAssertEqual(settings.openAIProcessing, .standard)
        settings.selectAnalysisModel("gpt-6-sol"); settings.analysisThinking = .high
        settings.openAIProcessing = .fast
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings, "Reopening keeps the manually chosen configuration")
        XCTAssertFalse(restored.usesRecommendedAnalysis)
    }

    func testFastSelectionControlsWireTierPricingAndReferenceData() throws {
        let answer = AnswerRequest(query: .formulate(question: "What is a cache?", context: ""), conversation: "", scenario: .interview, sources: [])
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.openAIProcessing, .standard)
        for model in ["gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol"] {
            settings.selectAnalysisService(.separateOpenAI); settings.selectAnalysisModel(model)
            for fast in [false, true] {
                settings.openAIProcessing = fast ? .fast : .standard
                let provider = try XCTUnwrap(ReasoningProviderFactory.make(settings: settings, liveKey: nil, analysisKey: "fixture") as? OpenAIReasoningProvider)
                let request = try provider.httpRequest(answer)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(body["service_tier"] as? String, fast ? "fast" : "default")
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
                let price = try XCTUnwrap(AnalysisPricing.display(settings))
                XCTAssertEqual(price.quote.input, model == "gpt-6-luna" ? (fast ? 0.2 : 0.1) : (fast ? 4 : 2))
                XCTAssertEqual(price.quote.output, model == "gpt-6-luna" ? (fast ? 1 : 0.5) : (fast ? 20 : 10))
                if fast { XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample) }
                else { XCTAssertNotNil(AnalysisPerformance.selection(settings).matchingSample) }
            }
        }
        settings.selectAnalysisModel("unknown-model")
        XCTAssertFalse(settings.usesOpenAIFast, "Unverified custom model IDs must not receive Fast")
        settings.selectAnalysisService(.deepSeek)
        let provider = try XCTUnwrap(ReasoningProviderFactory.make(settings: settings, liveKey: nil, analysisKey: "fixture") as? ChatCompletionsProvider)
        let request = try provider.httpRequest(answer)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertNil(body["service_tier"], "OpenAI's setting must not leak into other services")
        XCTAssertNotNil(AnalysisPerformance.selection(settings).matchingSample)
    }

    func testReasoningMenuGroupsKeepOnlyRealCapabilities() {
        for model in AnalysisModelCatalog.models {
            let simple = model.modes.filter { !$0.isAdvanced }
            let advanced = model.modes.filter(\.isAdvanced)
            XCTAssertTrue(simple.allSatisfy { [.disabled, .low, .enabled].contains($0) })
            XCTAssertTrue(advanced.allSatisfy { [.medium, .high, .xhigh, .max].contains($0) })
            XCTAssertEqual(Set(simple + advanced), Set(model.modes))
        }
        XCTAssertEqual(AnalysisThinking.disabled.menuName, "Off")
        XCTAssertEqual(AnalysisModelCatalog.model("kimi-k2.6", service: .kimi)?.modes.filter { !$0.isAdvanced }, [.disabled, .enabled])
        XCTAssertFalse(AnalysisModelCatalog.model("gpt-6.1-sol", service: .separateOpenAI)!.modes.contains(.disabled))
    }

    func testOnboardingRecommendationsAndCustomModelsSurviveProviderSwitches() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.reasoningModel, "gpt-6-sol")
        settings.selectAnalysisModel("my-deployment-2026")
        settings.selectAnalysisService(.deepSeek)
        settings.selectAnalysisModel("deepseek-user-selected")
        settings.selectAnalysisService(.qwen)
        settings.selectAnalysisService(.separateOpenAI)
        XCTAssertEqual(settings.reasoningModel, "my-deployment-2026")
        settings.selectAnalysisService(.deepSeek)
        XCTAssertEqual(settings.analysisModel, "deepseek-user-selected")
        let credential = try settings.analysisCredentialReference()
        settings.applyAnalysisRecommendation()
        XCTAssertEqual(settings.analysisModel, "deepseek-flash")
        XCTAssertEqual(try settings.analysisCredentialReference(), credential)
        settings.selectAnalysisService(.separateOpenAI); settings.applyAnalysisRecommendation()
        XCTAssertEqual(settings.reasoningModel, "gpt-6-sol")
        XCTAssertEqual(settings.reasoningEffort, "low")
        settings.selectAnalysisModel("gpt-6.1-sol")
        XCTAssertEqual(settings.reasoningModel, "gpt-6.1-sol")
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.reasoningModel, "gpt-6.1-sol", "Reopening must not replace the saved model with Luna")
        XCTAssertEqual(OnboardingAnalysisChoice.displayName(saved), "GPT-6.1 Sol")
    }

    func testOnboardingEffortOptionsRespectProviderCapabilities() {
        var settings = AppSettings()
        XCTAssertTrue(settings.reasoningService.availableThinkingModes(for: settings.analysisModel).contains(.disabled))
        settings.analysisThinking = .disabled
        XCTAssertEqual(settings.reasoningEffort, "none")
        settings.selectAnalysisModel("gpt-6.1-sol")
        XCTAssertFalse(settings.reasoningService.availableThinkingModes(for: settings.analysisModel).contains(.disabled))
        XCTAssertEqual(settings.reasoningEffort, "low")
        for model in AnalysisModelCatalog.models {
            settings.selectAnalysisService(model.service); settings.selectAnalysisModel(model.id)
            let oldKey = try? settings.analysisCredentialReference()
            for option in model.modes {
                settings.analysisThinking = option
                XCTAssertEqual(settings.analysisThinking, option)
                XCTAssertEqual(try? settings.analysisCredentialReference(), oldKey)
            }
        }
    }

    func testFirstWordsNeverBorrowReasoningTokenLatency() {
        var settings = AppSettings()
        settings.selectAnalysisModel("gpt-6-luna")
        let luna = AnalysisPerformance.selection(settings).matchingSample
        XCTAssertEqual(luna?.tokensPerSecond, 133)
        XCTAssertNil(luna?.firstAnswerSeconds, "Published TTFT is not verified TTFA")
        settings.selectAnalysisService(.deepSeek)
        settings.analysisThinking = .low
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample?.firstAnswerSeconds)
        settings.deepSeekEffort = "none"
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.firstAnswerSeconds, 1.15)
        settings.deepSeekEffort = "medium"
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.effort, "high", "A documented alias must match the actual request")
        settings.selectAnalysisService(.compatible)
        settings.compatibleModel = "deepseek-flash"
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
    }

    func testConnectionFeedbackUsesRealTransportErrorCategories() {
        for (status, expected) in [(401, OnboardingConnectionFailure.authentication), (403, .permission), (402, .billing),
                                   (404, .model), (422, .parameters), (429, .rateLimit), (503, .service)] {
            XCTAssertThrowsError(try OpenAIHTTP.check(status)) {
                XCTAssertEqual(OnboardingConnectionFailure.classify($0), expected)
            }
        }
        XCTAssertEqual(OnboardingConnectionFailure.classify(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(OnboardingConnectionFailure.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(OnboardingConnectionFailure.classify(CopilotError.message("arbitrary server failure")), .service)
    }

    @MainActor func testConnectionFailureCannotMarkCurrentConfigurationVerified() async throws {
        let suite = "LiveCopilot-Service-Failure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let app = AppCoordinator(mock: true, mockReasoning: FailedServiceProbe(), emitMockConversation: false,
                                 mockDefaults: defaults, mockKnowledgeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        do { try await app.testAnalysisConnection(); XCTFail("Expected network failure") }
        catch { XCTAssertEqual(OnboardingConnectionFailure.classify(error), .network) }
        XCTAssertFalse(app.isAnalysisConnectionVerified)
        XCTAssertFalse(app.testingAnalysisConnection)
        XCTAssertEqual(app.analysisConnectionFailure, .network)
        app.settings.reasoningModel = "changed-model"
        XCTAssertNil(app.analysisConnectionFailure)
        app.onboarding.state.step = .analysis
        app.onboarding.state.advance()
        XCTAssertEqual(app.onboarding.state.step, .ready, "A failed connection must not trap the user")
        await app.shutdown(); defaults.removePersistentDomain(forName: suite)
    }

    @MainActor func testAnswerServiceStatesRenderAtSupportedSizes() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in page rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            let suite = "LiveCopilot-Service-Render-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults, mockKnowledgeDirectory: root.appendingPathComponent(suite))
            app.settings.language = language; app.onboarding.state.step = .analysis
            app.hasAPIKey = false
            for size in [NSSize(width: 1040, height: 660), NSSize(width: 1280, height: 800), NSSize(width: 1280, height: 1120)] {
                let host = NSHostingView(rootView: OnboardingView(coordinator: app, close: {}, beginListening: {}, beginTyping: {}))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.size, size)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("service-\(language.rawValue)-\(Int(size.width))-\(Int(size.height)).png"))
                window.orderOut(nil)
            }
            for service in [ReasoningService.deepSeek, .qwen, .glm, .kimi, .compatible, .separateOpenAI] {
                app.settings.selectRecommendedAnalysisService(service)
                app.settings.openAIProcessing = service == .separateOpenAI ? .fast : .standard
                let host = NSHostingView(rootView: OnboardingView(coordinator: app, close: {}, beginListening: {}, beginTyping: {}))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("service-\(language.rawValue)-\(service.rawValue).png"))
                window.orderOut(nil)
            }
            let states = VStack(alignment: .leading, spacing: 18) {
                AnalysisPerformanceCard(settings: app.settings, onboarding: true)
                OnboardingServiceSection(number: 4, title: "API Key") {
                    CredentialEditor(coordinator: app, analysis: false, onboarding: true)
                    OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: false)
                }
                OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true)
                OnboardingConnectionFeedback(language: language, testing: true, verified: false, saved: true)
                OnboardingConnectionFeedback(language: language, testing: false, verified: true, saved: true)
                OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true, failure: .permission)
                OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true, failure: .model)
                OnboardingConnectionFeedback(language: language, testing: false, verified: false, saved: true, failure: .network)
            }.padding(18).frame(width: 600).background(Color.white).preferredColorScheme(.light)
            let host = NSHostingView(rootView: states)
            host.setFrameSize(NSSize(width: 600, height: host.fittingSize.height)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("service-states-\(language.rawValue).png"))
            await app.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
    }

    func testProviderSwitchRestoresEffortAndModelChangeResetsIt() throws {
        var settings = AppSettings()
        settings.reasoningEffort = "high"
        settings.selectAnalysisService(.sharedOpenAI)
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.selectAnalysisService(.deepSeek)
        settings.deepSeekEffort = "max"
        settings.selectAnalysisService(.qwen)
        XCTAssertEqual(settings.qwenConnection.thinking, .disabled)
        settings.qwenConnection.thinking = .xhigh
        settings.selectAnalysisService(.glm)
        XCTAssertEqual(settings.glmConnection.thinking, .low)
        settings.glmConnection.thinking = .max
        settings.selectAnalysisService(.kimi)
        XCTAssertEqual(settings.kimiConnection.thinking, .disabled)
        settings.selectAnalysisModel("kimi-k3")
        XCTAssertEqual(settings.kimiConnection.thinking, .low)
        settings.selectAnalysisService(.deepSeek)
        XCTAssertEqual(settings.deepSeekEffort, "max")
        settings.selectAnalysisService(.qwen)
        XCTAssertEqual(settings.qwenConnection.thinking, .xhigh)
        settings.selectAnalysisService(.glm)
        XCTAssertEqual(settings.glmConnection.thinking, .max)
        settings.selectAnalysisService(.separateOpenAI)
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.reasoningEffort = "high"
        settings.selectAnalysisModel(AppSettings.defaultReasoningModel)
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.selectAnalysisModel("gpt-6-luna")
        XCTAssertEqual(settings.reasoningEffort, "low")
        settings.reasoningEffort = "medium"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reasoningEffort":"high","qwenConnection":{"baseURL":"https://dashscope.aliyuncs.com/compatible-mode/v1","model":"qwen3.8-flash","thinking":"disabled"}}"#.utf8))
        XCTAssertEqual(legacy.reasoningEffort, "high")
        XCTAssertEqual(legacy.qwenConnection.thinking, .disabled)
    }

    func testLowEffortUsesEachVendorWireFormatAndKeepsCredentialIdentity() throws {
        let answer = AnswerRequest(query: .formulate(question: "What is a cache?", context: ""), conversation: "", scenario: .interview, sources: [])
        for service in [ReasoningService.deepSeek, .qwen, .glm, .kimi] {
            var settings = AppSettings()
            settings.selectAnalysisService(service)
            if service == .kimi { settings.selectAnalysisModel("kimi-k3") }
            settings.analysisThinking = .low
            let credential = try settings.analysisCredentialReference()
            let provider = try XCTUnwrap(ReasoningProviderFactory.make(settings: settings, liveKey: "never-use", analysisKey: "fixture") as? ChatCompletionsProvider)
            let request = try provider.httpRequest(answer)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["reasoning_effort"] as? String, "low")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["temperature"])
            XCTAssertNil(body["thinking_budget"])
            if service == .qwen {
                XCTAssertEqual(body["enable_thinking"] as? Bool, true)
                XCTAssertNil(body["thinking"])
            } else if service == .kimi {
                XCTAssertNil(body["thinking"], "K3 must not receive the K2 thinking toggle")
            } else {
                XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
            }
            settings.selectAnalysisModel(service == .kimi ? "kimi-k2.6" : settings.analysisModel)
            XCTAssertEqual(try settings.analysisCredentialReference(), credential)
        }
        XCTAssertEqual(ReasoningService.kimi.normalizedThinking(.low, model: "kimi-k2.6"), .enabled)
        XCTAssertEqual(ReasoningService.glm.normalizedThinking(.disabled, model: "glm-5.3-flash"), .low)
        XCTAssertEqual(ReasoningService.qwen.defaultThinking(for: "unknown-model"), .modelDefault)
    }

    func testMetricsCannotBorrowOtherModelEffortOrRoute() {
        var settings = AppSettings()
        settings.reasoningModel = "gpt-6.1-sol"
        let initial = AnalysisPerformance.selection(settings)
        XCTAssertTrue(initial.matchesConfiguration)
        XCTAssertEqual(initial.matchingSample?.firstTokenSeconds, 3.04)
        XCTAssertEqual(initial.matchingSample?.tokensPerSecond, 51.3)
        settings.reasoningEffort = "high"
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.effort, "high")
        settings.reasoningModel = "gpt-6.1-sol-pro"
        XCTAssertNil(AnalysisPerformance.selection(settings).sample)
        settings.selectAnalysisService(.deepSeek); settings.analysisThinking = .low
        let deepSeek = AnalysisPerformance.selection(settings)
        XCTAssertTrue(deepSeek.matchesConfiguration)
        XCTAssertEqual(deepSeek.matchingSample?.effort, "low")
        XCTAssertEqual(deepSeek.matchingSample?.source, "OpenRouter")
        XCTAssertEqual(deepSeek.matchingSample?.firstTokenSeconds, 1.13)
        XCTAssertEqual(deepSeek.matchingSample?.tokensPerSecond, 153)
        settings.deepSeekEffort = "max"
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.tokensPerSecond, 217)
        settings.selectAnalysisService(.qwen); settings.analysisThinking = .low
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchingSample?.productReference == true)
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.firstTokenSeconds, 2)
        settings.selectAnalysisService(.kimi)
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        settings.kimiConnection.baseURL = "https://custom.example/v1"
        XCTAssertFalse(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
        settings.selectAnalysisService(.compatible)
        settings.compatibleModel = "gpt-6.1-sol"
        XCTAssertNil(AnalysisPerformance.selection(settings).sample)
        XCTAssertTrue(AnalysisPerformance.samples.allSatisfy {
            $0.firstTokenSeconds > 0 && $0.tokensPerSecond > 0 && ($0.productReference || $0.url.hasPrefix("https://")) && !$0.capturedAt.isEmpty
        })
    }

    func testExpandedMetricsAreEffortSpecificAndRejectCustomRoutes() {
        var settings = AppSettings()
        for model in ["gpt-6.1-sol", "gpt-6-sol"] {
            settings.reasoningModel = model
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                settings.reasoningEffort = effort
                XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.effort, effort)
            }
        }
        for service in [ReasoningService.deepSeek, .glm, .kimi] {
            settings.selectAnalysisService(service)
            if service == .kimi { settings.selectAnalysisModel("kimi-k3") }
            if service == .glm { settings.selectAnalysisModel("glm-5.3-flash") }
            for effort in ["low", "high", "max"] {
                if service == .deepSeek { settings.deepSeekEffort = effort }
                else { settings.presetConnection?.thinking = AnalysisThinking(rawValue: effort)! }
                XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.effort, effort)
            }
        }
        settings.selectAnalysisService(.glm)
        settings.glmConnection.baseURL = "https://custom.example/v1"
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
        settings.selectAnalysisService(.qwen)
        for mode in [AnalysisThinking.medium, .xhigh] {
            settings.qwenConnection.thinking = mode
            XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample, "Unsegmented data must not masquerade as a specific effort")
        }
        let keys = AnalysisPerformance.samples.map { $0.model + "/" + $0.effort }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    @MainActor func testSelectionPersistsThroughCoordinatorRestart() async throws {
        let suite = "LiveCopilot-Analysis-Selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let first = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults, mockKnowledgeDirectory: directory)
        first.settings.selectAnalysisService(.glm)
        XCTAssertEqual(first.settings.glmConnection.thinking, .low)
        first.settings.glmConnection.thinking = .high
        await first.shutdown()
        let second = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults, mockKnowledgeDirectory: directory)
        XCTAssertEqual(second.settings.glmConnection.thinking, .high)
        second.settings.selectAnalysisService(.qwen)
        second.settings.selectAnalysisService(.glm)
        XCTAssertEqual(second.settings.glmConnection.thinking, .high)
        XCTAssertEqual(AppSettings.load(defaults: defaults).glmConnection.thinking, .high)
        await second.shutdown()
    }

    @MainActor func testRenderPerformanceCards() async throws {
        let output = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !output.isEmpty, !output.hasPrefix("$(") else { throw XCTSkip("Opt-in component rendering") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            for service in [ReasoningService.separateOpenAI, .deepSeek, .qwen, .glm, .kimi, .compatible] {
                var settings = AppSettings()
                settings.language = language; settings.selectAnalysisService(service)
                let host = NSHostingView(rootView: AnalysisPerformanceCard(settings: settings).padding(16).frame(width: 470)
                    .background(Color.white).preferredColorScheme(.light))
                host.setFrameSize(NSSize(width: 470, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("performance-\(language.rawValue)-\(service.rawValue).png"))
                XCTAssertLessThan(host.bounds.height, 420)
            }
            let suite = "LiveCopilot-Performance-Render-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                     mockKnowledgeDirectory: root.appendingPathComponent(suite))
            app.settings.language = language
            app.settings.selectAnalysisService(.deepSeek)
            app.onboarding.state.step = .analysis
            let host = NSHostingView(rootView: OnboardingView(coordinator: app, close: {}, beginListening: {}, beginTyping: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 668), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("analysis-onboarding-\(language.rawValue).png"))
            window.orderOut(nil)
            await app.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private struct FailedServiceProbe: ReasoningProvider {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}

extension AnalysisSelectionTests {
    func testMetricRatingBoundariesAndInvalidReferences() {
        XCTAssertEqual(AnalysisMetricTier.latency(1.5), .fast)
        XCTAssertEqual(AnalysisMetricTier.latency(1.5001), .steady)
        XCTAssertEqual(AnalysisMetricTier.latency(3.5), .steady)
        XCTAssertEqual(AnalysisMetricTier.latency(3.5001), .slow)
        XCTAssertEqual(AnalysisMetricTier.generation(100), .fast)
        XCTAssertEqual(AnalysisMetricTier.generation(99.99), .steady)
        XCTAssertEqual(AnalysisMetricTier.generation(50), .steady)
        XCTAssertEqual(AnalysisMetricTier.generation(49.99), .slow)
        XCTAssertNil(AnalysisMetricTier.latency(nil))
        XCTAssertNil(AnalysisMetricTier.latency(-1))
        XCTAssertNil(AnalysisMetricTier.generation(0))
        XCTAssertNil(AnalysisMetricTier.latency(.infinity))
        XCTAssertNil(AnalysisMetricTier.generation(.nan))
        for (currency, cheap, moderate) in [(AnalysisCurrency.cny, 10.0, 50.0), (.usd, 1.5, 7.5)] {
            XCTAssertEqual(AnalysisMetricTier.price(cheap, currency: currency), .inexpensive)
            XCTAssertEqual(AnalysisMetricTier.price(cheap + 0.01, currency: currency), .moderatePrice)
            XCTAssertEqual(AnalysisMetricTier.price(moderate, currency: currency), .moderatePrice)
            XCTAssertEqual(AnalysisMetricTier.price(moderate + 0.01, currency: currency), .expensive)
            XCTAssertNil(AnalysisMetricTier.price(.nan, currency: currency))
        }
    }

    func testEstimatedRatingsDoNotInventAPointValueOrHideUncertainty() {
        XCTAssertEqual(AnalysisMetricTier.range("0.9–2.5", classify: AnalysisMetricTier.latency), .uncertain)
        XCTAssertEqual(AnalysisMetricTier.range("100–184", classify: AnalysisMetricTier.generation), .fast)
        XCTAssertEqual(AnalysisMetricTier.range("55.8–152.3", classify: AnalysisMetricTier.latency), .slow)
        XCTAssertEqual(AnalysisMetricTier.range("1.52", classify: AnalysisMetricTier.latency), .steady,
                       "Classify the numeric value, not the model names in editorial examples")
        for invalid in ["", "N/A", "3–1", "NaN", "1–2–3", "-2–1"] {
            XCTAssertNil(AnalysisMetricTier.range(invalid, classify: AnalysisMetricTier.latency))
        }
        for row in AnalysisConfigurations.all {
            XCTAssertNotNil(AnalysisMetricTier.range(row.ttft, classify: AnalysisMetricTier.latency), row.label)
            XCTAssertNotNil(AnalysisMetricTier.range(row.speed, classify: AnalysisMetricTier.generation), row.label)
        }
    }

    func testNineModelsAndEveryReasoningModeUseCorrectWireParameters() throws {
        let expected: [(ReasoningService, String, [AnalysisThinking])] = [
            (.separateOpenAI, "gpt-6-luna", [.disabled, .low, .medium, .high, .xhigh, .max]),
            (.separateOpenAI, "gpt-6-sol", [.disabled, .low, .medium, .high, .xhigh, .max]),
            (.separateOpenAI, "gpt-6.1-sol", [.low, .medium, .high, .xhigh, .max]),
            (.deepSeek, "deepseek-flash", [.disabled, .low, .high, .max]),
            (.qwen, "qwen3.8-flash", [.disabled, .low, .medium, .xhigh]),
            (.glm, "glm-5.3-flash", [.low, .high, .max]),
            (.glm, "glm-5.3-flashx", [.low, .high, .max]),
            (.kimi, "kimi-k2.6", [.disabled, .enabled]),
            (.kimi, "kimi-k3", [.low, .high, .max])
        ]
        XCTAssertEqual(AnalysisModelCatalog.models.count, 9)
        let answer = AnswerRequest(query: .formulate(question: "A synthetic test?", context: ""), conversation: "", scenario: .interview, sources: [])
        for (service, model, modes) in expected {
            var settings = AppSettings(); settings.selectAnalysisService(service); settings.selectAnalysisModel(model)
            XCTAssertEqual(service.availableThinkingModes(for: model), modes)
            let credential = try settings.analysisCredentialReference()
            for mode in modes {
                settings.analysisThinking = mode
                let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: "must-not-use", analysisKey: "fixture")
                let http: URLRequest
                if let openai = provider as? OpenAIReasoningProvider { http = try openai.httpRequest(answer) }
                else { http = try XCTUnwrap(provider as? ChatCompletionsProvider).httpRequest(answer) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: http.httpBody!) as? [String: Any])
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                XCTAssertEqual(try settings.analysisCredentialReference(), credential)
                XCTAssertNil(body["thinking_budget"])
                XCTAssertEqual(body["service_tier"] as? String, service == .separateOpenAI ? "default" : nil)
                if service == .separateOpenAI {
                    XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], mode.referenceKey)
                    XCTAssertNil(body["thinking"]); XCTAssertNil(body["reasoning_effort"])
                    XCTAssertTrue((body["input"] as? String)?.contains("synthetic") == true)
                } else {
                    XCTAssertNil(body["reasoning"])
                    XCTAssertEqual(body["reasoning_effort"] as? String, mode.effort)
                    if service == .qwen {
                        XCTAssertEqual(body["enable_thinking"] as? Bool, mode != .disabled)
                        XCTAssertNil(body["thinking"])
                    } else if model == "kimi-k3" {
                        XCTAssertNil(body["thinking"]); XCTAssertNil(body["enable_thinking"])
                    } else {
                        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], mode == .disabled ? "disabled" : "enabled")
                        XCTAssertNil(body["enable_thinking"])
                    }
                }
            }
        }
    }

    func testUnknownModelAndLegacyIllegalEffortCannotLeakReasoningParameters() throws {
        let answer = AnswerRequest(query: .formulate(question: "fixture", context: ""), conversation: "", scenario: .interview, sources: [])
        for service in ReasoningService.allCases {
            var settings = AppSettings(); settings.selectAnalysisService(service); settings.selectAnalysisModel("new-user-deployment")
            settings.reasoningEffort = "max"; settings.deepSeekEffort = "max"
            settings.presetConnection?.thinking = .max
            if service == .compatible { settings.compatibleBaseURL = "https://fixture.example/v1" }
            XCTAssertEqual(settings.analysisThinking, .modelDefault)
            XCTAssertEqual(service.availableThinkingModes(for: settings.analysisModel), [.modelDefault])
            let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: "fixture", analysisKey: "fixture")
            let http: URLRequest
            if let p = provider as? OpenAIReasoningProvider { http = try p.httpRequest(answer) }
            else { http = try XCTUnwrap(provider as? ChatCompletionsProvider).httpRequest(answer) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: http.httpBody!) as? [String: Any])
            for field in ["reasoning", "reasoning_effort", "thinking", "enable_thinking"] { XCTAssertNil(body[field], "\(service) \(field)") }
        }
        XCTAssertEqual(AnalysisModelCatalog.normalized("none", model: "gpt-6.1-sol", service: .separateOpenAI), .low)
        XCTAssertEqual(AnalysisModelCatalog.normalized("low", model: "kimi-k2.6", service: .kimi), .enabled)
        XCTAssertEqual(AnalysisModelCatalog.normalized("high", model: "qwen3.8-flash", service: .qwen), .xhigh)
        XCTAssertEqual(AnalysisModelCatalog.normalized("medium", model: "deepseek-flash", service: .deepSeek), .high)
    }

    func testFiveRecommendationsRestoreSavedChoicesAndKeepEndpointKeys() throws {
        let expected: [(ReasoningService, String, AnalysisThinking)] = [
            (.separateOpenAI, "gpt-6-sol", .low), (.deepSeek, "deepseek-flash", .disabled),
            (.qwen, "qwen3.8-flash", .disabled), (.glm, "glm-5.3-flashx", .low), (.kimi, "kimi-k2.6", .disabled)
        ]
        var settings = AppSettings()
        for (service, model, mode) in expected {
            settings.selectAnalysisService(service)
            XCTAssertEqual(settings.analysisModel, model); XCTAssertEqual(settings.analysisThinking, mode)
            XCTAssertTrue(settings.usesRecommendedAnalysis)
            settings.analysisThinking = service == .kimi ? .disabled : service == .qwen ? .xhigh : .max
            let chosen = settings.analysisThinking
            let key = try settings.analysisCredentialReference()
            settings.selectAnalysisService(.compatible); settings.selectAnalysisService(service)
            XCTAssertEqual(settings.analysisThinking, chosen)
            let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(saved, settings)
            settings.selectAnalysisModel("manual-id")
            XCTAssertFalse(settings.usesRecommendedAnalysis)
            settings.applyAnalysisRecommendation()
            XCTAssertEqual(settings.analysisModel, model); XCTAssertEqual(settings.analysisThinking, mode)
            XCTAssertEqual(try settings.analysisCredentialReference(), key)
            if service.isPreset {
                settings.presetConnection?.baseURL = "https://test-region.example/v1"
                let scopedKey = try settings.analysisCredentialReference()
                settings.applyAnalysisRecommendation()
                XCTAssertEqual(try settings.analysisCredentialReference(), scopedKey)
            }
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"glmConnection":{"baseURL":"https://open.bigmodel.cn/api/paas/v4","model":"glm-5.3-flash","thinking":"max"},"kimiConnection":{"baseURL":"https://api.moonshot.cn/v1","model":"kimi-k2.6","thinking":"disabled"}}"#.utf8))
        XCTAssertEqual(legacy.glmConnection.model, "glm-5.3-flash"); XCTAssertEqual(legacy.glmConnection.thinking, .max)
        XCTAssertEqual(legacy.kimiConnection.thinking, .disabled, "New-install recommendations must not overwrite existing accounts")
    }

    func testOfficialPricesConvertAmountsAndStayScopedToRegions() throws {
        var settings = AppSettings(); settings.language = .english; settings.selectAnalysisModel("gpt-6-luna")
        let usd = try XCTUnwrap(AnalysisPricing.display(settings))
        XCTAssertEqual(usd.input, 0.10); XCTAssertEqual(usd.output, 0.50); XCTAssertNil(usd.exchangeRate)
        settings.language = .simplifiedChinese
        let cny = try XCTUnwrap(AnalysisPricing.display(settings))
        XCTAssertEqual(cny.input, 0.10 * 7.4992 / 1.1206, accuracy: 0.0000001)
        XCTAssertEqual(cny.output, 0.50 * 7.4992 / 1.1206, accuracy: 0.0000001)
        XCTAssertTrue(cny.summary(.simplifiedChinese).contains("¥0.67"))
        XCTAssertEqual(cny.exchangeRate?.date, "2026-10-09")
        settings.selectAnalysisService(.glm)
        let glm = try XCTUnwrap(AnalysisPricing.display(settings))
        XCTAssertEqual(glm.input, 2); XCTAssertEqual(glm.output, 7); XCTAssertNil(glm.exchangeRate)
        settings.language = .english
        XCTAssertEqual(try XCTUnwrap(AnalysisPricing.display(settings)).input, 2 / (7.4992 / 1.1206), accuracy: 0.000001)
        settings.glmConnection.baseURL = "https://api.z.ai/api/paas/v4"
        XCTAssertNil(AnalysisPricing.display(settings), "An international route cannot inherit a China quote")
        settings.selectAnalysisService(.qwen)
        settings.language = .simplifiedChinese
        XCTAssertEqual(AnalysisPricing.display(settings)?.input, 0.8)
        settings.qwenConnection.baseURL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        XCTAssertEqual(AnalysisPricing.display(settings)?.input, 1.094)
        settings.qwenConnection.baseURL = "https://proxy.example/v1"
        XCTAssertNil(AnalysisPricing.display(settings)); XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
        settings.selectAnalysisService(.compatible); settings.compatibleModel = "gpt-6-luna"
        XCTAssertNil(AnalysisPricing.display(settings))
        for quote in AnalysisPricing.quotes {
            XCTAssertEqual(quote.unit, 1_000_000); XCTAssertGreaterThan(quote.input, 0); XCTAssertGreaterThan(quote.output, 0)
            XCTAssertEqual(quote.checkedAt, "2026-10-11"); XCTAssertTrue(quote.sourceURL.hasPrefix("https://"))
        }
    }

    func testAllProductSpecifiedReferenceRowsAreExactAndMissingEffortsStayEmpty() {
        let rows: [(String, String, Double, Double)] = [
            ("gpt-6-luna", "none", 0.83, 117.5), ("gpt-6-luna", "low", 3.07, 133),
            ("gpt-6-sol", "none", 0.93, 97.2), ("gpt-6-sol", "low", 1.70, 104.4),
            ("gpt-6.1-sol", "low", 3.04, 51.3), ("deepseek-flash", "none", 1.15, 222.1),
            ("deepseek-flash", "low", 1.13, 153), ("qwen3.8-flash", "none", 1.50, 55),
            ("qwen3.8-flash", "low", 2, 55), ("glm-5.3-flash", "low", 2.35, 95),
            ("glm-5.3-flashx", "low", 1.52, 284), ("kimi-k2.6", "none", 2.74, 59),
            ("kimi-k2.6", "enabled", 2.75, 57), ("kimi-k3", "low", 3.95, 26)
        ]
        for (model, effort, ttft, speed) in rows {
            let sample = AnalysisPerformance.samples.first { $0.model == model && $0.effort == effort }
            XCTAssertEqual(sample?.firstTokenSeconds, ttft); XCTAssertEqual(sample?.tokensPerSecond, speed)
            if model.hasPrefix("qwen") || model.hasPrefix("glm") { XCTAssertTrue(sample?.productReference == true) }
        }
        var settings = AppSettings(); settings.selectAnalysisModel("gpt-6-luna"); settings.analysisThinking = .medium
        XCTAssertNil(AnalysisPerformance.selection(settings).sample)
        settings.selectAnalysisService(.glm); settings.analysisThinking = .high
        XCTAssertNil(AnalysisPerformance.selection(settings).sample, "FlashX must not borrow Flash high")
        settings.selectAnalysisService(.kimi); settings.analysisThinking = .enabled
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.firstAnswerSeconds, 80.95)
        XCTAssertNotEqual(AnalysisPerformance.selection(settings).matchingSample?.firstTokenSeconds, 80.95)
    }

    func testErrorBodiesOnlyExposeSafeCategories() throws {
        let privateBody = Data(#"{"error":{"code":"model_not_found","message":"private-key-and-meeting-content"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIHTTP.check(400, data: privateBody)) { error in
            XCTAssertEqual(OnboardingConnectionFailure.classify(error), .model)
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
        let unsupported = Data(#"{"error":{"code":"unsupported_parameter","message":"private"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIHTTP.check(400, data: unsupported)) { error in
            XCTAssertEqual(OnboardingConnectionFailure.classify(error), .parameters)
        }
    }
}

private final class BlurNumberPreviewValues: ObservableObject {
    @Published var number = "3.07"
}
private struct BlurNumberPreview: View {
    @ObservedObject var values: BlurNumberPreviewValues
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("参考首 Token 延迟").font(.system(size: 12)).foregroundStyle(.secondary)
            StaggeredBlurNumber(values.number, prefix: "≈ ", suffix: " s", size: 28)
            HStack(spacing: 12) {
                ForEach([OnboardingCapabilityStatus.ready, .installed, .download, .verifying].indices, id: \.self) { index in
                    OnboardingCapabilityBadge(status: [OnboardingCapabilityStatus.ready, .installed, .download, .verifying][index], language: .simplifiedChinese)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white).preferredColorScheme(.light)
    }
}

extension AnalysisSelectionTests {
    func testAll58ConfigurationsRoundTripAndBuildMatchingRequests() throws {
        let rows = AnalysisConfigurations.all
        XCTAssertEqual(rows.count, 58)
        XCTAssertEqual(Set(rows.map { "\($0.model)|\($0.thinking)|\($0.processing)" }).count, 58)
        XCTAssertEqual(rows.filter { $0.kind == .estimate }.count, 27)
        XCTAssertEqual(rows.filter { $0.kind == .community }.count, 4)
        XCTAssertEqual(rows.filter { $0.kind == .publicSnapshot }.count, 27)
        let answer = AnswerRequest(query: .formulate(question: "Synthetic fixture", context: ""), conversation: "", scenario: .interview, sources: [])
        for row in rows {
            var settings = AppSettings()
            settings.selectAnalysisService(row.service); settings.selectAnalysisModel(row.model)
            settings.analysisThinking = row.thinking; settings.analysisProcessing = row.processing
            settings.language = row.currency == "USD" ? .english : .simplifiedChinese
            XCTAssertEqual(AnalysisConfigurations.selection(settings)?.id, row.id, row.label)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
            let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: nil, analysisKey: "test-only")
            let request: URLRequest
            if let p = provider as? OpenAIReasoningProvider { request = try p.httpRequest(answer) }
            else { request = try XCTUnwrap(provider as? ChatCompletionsProvider).httpRequest(answer) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, row.model)
            XCTAssertEqual(body["service_tier"] as? String, settings.isOpenAIAnalysis ? row.processing.wireValue : nil)
            if settings.isOpenAIAnalysis { XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], row.thinking.referenceKey) }
            else { XCTAssertEqual(body["reasoning_effort"] as? String, row.thinking.effort) }
            let price = try XCTUnwrap(AnalysisPricing.display(settings), row.label)
            XCTAssertEqual(price.input, row.input, row.label); XCTAssertEqual(price.output, row.output, row.label)
            if row.kind == .estimate {
                XCTAssertNil(row.firstTokenSeconds); XCTAssertNil(row.tokensPerSecond)
                XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample, "An estimate is not a measurement")
                XCTAssertFalse(row.ttft.isEmpty); XCTAssertFalse(row.speed.isEmpty)
            } else {
                XCTAssertNotNil(row.firstTokenSeconds); XCTAssertNotNil(row.tokensPerSecond)
            }
        }
    }

    func testRecommendedMenuPartitionsAndTopFiveFollowSourceTable() {
        XCTAssertEqual(AnalysisConfigurations.topFive.map(\.rank), [1, 2, 3, 4, 5])
        XCTAssertEqual(AnalysisConfigurations.topFive.map(\.model), ["gpt-6-sol", "deepseek-flash", "gpt-6-luna", "gpt-6-sol", "glm-5.3-flashx"])
        XCTAssertEqual(AnalysisConfigurations.all.filter(\.providerDefault).count, 5)
        for row in AnalysisConfigurations.all {
            XCTAssertEqual(AnalysisConfigurations.recommended(model: row.model, thinking: row.thinking, processing: row.processing), row.recommended || (row.model == "gpt-6-luna" && row.thinking == .low && row.processing == .fast))
            XCTAssertTrue(AnalysisConfigurations.processingModes(model: row.model).contains(row.processing))
            if row.providerDefault {
                var settings = AppSettings(); settings.selectRecommendedAnalysisService(row.service)
                XCTAssertEqual(AnalysisConfigurations.selection(settings)?.id, row.id)
            }
        }
        XCTAssertFalse(AnalysisConfigurations.modelIsRecommended("kimi-k3"))
        XCTAssertTrue(AnalysisConfigurations.recommended(model: "gpt-6-sol", thinking: .medium, processing: .standard))
        XCTAssertTrue(AnalysisConfigurations.recommended(model: "gpt-6-luna", thinking: .low, processing: .fast), "The October 12 sidebar recommendation supersedes the old CSV flag")
        XCTAssertTrue(AnalysisConfigurations.all.filter { $0.processing == .ultrafast }.allSatisfy { !$0.recommended })
    }

    func testExplicitCredentialCheckHasUsefulFeedbackForEveryReadOutcome() {
        let missing = CredentialState()
        let found = CredentialState(key: "private-fixture-must-not-appear")
        let authorization = CredentialState(needsAuthorization: true)
        for (state, result) in [(missing, CredentialCheckFeedback.missing), (found, .found), (authorization, .authorization)] {
            let feedback = CredentialCheckFeedback.resolve(checking: false, available: state.key != nil, authorization: state.needsAuthorization, status: state.message)
            XCTAssertEqual(feedback, result)
            for language in [AppLanguage.english, .simplifiedChinese] {
                XCTAssertFalse(feedback.message(language).isEmpty)
                XCTAssertFalse(feedback.message(language).contains("private-fixture"))
            }
        }
        XCTAssertEqual(CredentialCheckFeedback.resolve(checking: true, available: false, authorization: false, status: missing.message), .checking)
        XCTAssertEqual(CredentialCheckFeedback.resolve(checking: false, available: false, authorization: false, status: "Keychain read failed (-50)"), .failed)
        XCTAssertTrue(CredentialCheckFeedback.found.message(.simplifiedChinese).contains("未发送 API 请求"))
        XCTAssertTrue(CredentialCheckFeedback.missing.message(.simplifiedChinese).contains("上方输入并保存"))
    }
}

extension AnalysisSelectionTests {
    @MainActor func testManualCredentialReadsKeepFormStableAndPublishDurableResults() async throws {
        for expected in [CredentialCheckFeedback.found, .missing, .authorization, .failed] {
            let suite = "LiveCopilot-KeyCheck-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                     mockKnowledgeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
                                     credentialReader: { _, interactive in
                guard interactive else { return CredentialState() }
                try await Task.sleep(for: .milliseconds(30))
                switch expected {
                case .found: return CredentialState(key: "fixture-never-displayed")
                case .missing: return CredentialState()
                case .authorization: return CredentialState(needsAuthorization: true)
                default: throw CopilotError.message("Synthetic keychain read failure")
                }
            })
            app.settings.selectAnalysisService(.separateOpenAI)
            await app.refreshAnalysisKeyState()?.value
            for analysis in [true, false] {
                if analysis { app.hasAnalysisKey = true } else { app.hasAPIKey = true }
                let read = analysis ? app.refreshAnalysisKeyState(interactive: true) : app.refreshKeyState(interactive: true)
                XCTAssertEqual(analysis ? app.analysisKeyCheckFeedback : app.liveKeyCheckFeedback, .checking)
                XCTAssertTrue(analysis ? app.hasAnalysisKey : app.hasAPIKey, "Starting a read must not remove and reinsert the form")
                await read?.value
                XCTAssertEqual(analysis ? app.analysisKeyCheckFeedback : app.liveKeyCheckFeedback, expected)
                XCTAssertFalse(analysis ? app.isCheckingAnalysisKey : app.isCheckingKey)
                XCTAssertEqual(analysis ? app.hasAnalysisKey : app.hasAPIKey, expected == .found)
                app.settings.language = .english
                XCTAssertEqual(analysis ? app.analysisKeyCheckFeedback : app.liveKeyCheckFeedback, expected, "Ordinary view updates must not discard a completed check")
                XCTAssertFalse(expected.message(.english).contains("fixture-never-displayed"))
            }
            await app.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor func testCredentialCheckCannotPublishOldProviderResultAfterSwitching() async throws {
        let suite = "LiveCopilot-KeyCheck-Switch-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                 mockKnowledgeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
                                 credentialReader: { _, interactive in
            if interactive { try await Task.sleep(for: .milliseconds(40)); return CredentialState(key: "old-provider") }
            return CredentialState()
        })
        await app.refreshAnalysisKeyState()?.value
        let old = app.refreshAnalysisKeyState(interactive: true)
        app.settings.selectAnalysisService(.deepSeek)
        await old?.value
        XCTAssertNil(app.analysisKeyCheckFeedback)
        XCTAssertFalse(app.hasAnalysisKey)
        XCTAssertEqual(app.settings.reasoningService, .deepSeek)
        await app.shutdown(); defaults.removePersistentDomain(forName: suite)
    }
}

private struct CredentialFailureTransport: HTTPTransport {
    let body: Data
    func data(for request: URLRequest) async throws -> (Data, Int) { (body, 429) }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(#"data: {"type":"response.failed","response":{"error":{"code":"insufficient_quota","message":"private-content"}}}"#)
            continuation.yield("")
            continuation.finish()
        }
    }
}
