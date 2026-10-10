import XCTest
import SwiftUI
@testable import LiveCopilot

final class AnalysisSelectionTests: XCTestCase {
    func testSwitchResetsEffortButSameSelectionAndDecodingPreserveIt() throws {
        var settings = AppSettings()
        settings.reasoningEffort = "high"
        settings.selectAnalysisService(.sharedOpenAI)
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.selectAnalysisService(.deepSeek)
        settings.deepSeekEffort = "max"
        settings.selectAnalysisService(.qwen)
        XCTAssertEqual(settings.qwenConnection.thinking, .low)
        settings.qwenConnection.thinking = .xhigh
        settings.selectAnalysisService(.glm)
        XCTAssertEqual(settings.glmConnection.thinking, .low)
        settings.glmConnection.thinking = .max
        settings.selectAnalysisService(.kimi)
        XCTAssertEqual(settings.kimiConnection.thinking, .disabled)
        settings.selectAnalysisModel("kimi-k3")
        XCTAssertEqual(settings.kimiConnection.thinking, .low)
        settings.selectAnalysisService(.deepSeek)
        XCTAssertEqual(settings.deepSeekEffort, "low")
        settings.selectAnalysisService(.qwen)
        XCTAssertEqual(settings.qwenConnection.thinking, .low)
        settings.selectAnalysisService(.glm)
        XCTAssertEqual(settings.glmConnection.thinking, .low)
        settings.selectAnalysisService(.separateOpenAI)
        XCTAssertEqual(settings.reasoningEffort, "low")
        settings.reasoningEffort = "high"
        settings.selectAnalysisModel("gpt-6.1-sol")
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.selectAnalysisModel("gpt-6-sol")
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
        XCTAssertEqual(ReasoningService.kimi.normalizedThinking(.low, model: "kimi-k2.6"), .modelDefault)
        XCTAssertEqual(ReasoningService.glm.normalizedThinking(.disabled, model: "glm-5.3-flash"), .modelDefault)
        XCTAssertEqual(ReasoningService.qwen.defaultThinking(for: "unknown-model"), .modelDefault)
    }

    func testMetricsCannotBorrowOtherModelEffortOrRoute() {
        var settings = AppSettings()
        let initial = AnalysisPerformance.selection(settings)
        XCTAssertTrue(initial.matchesConfiguration)
        XCTAssertEqual(initial.matchingSample?.firstTokenSeconds, 3.03)
        XCTAssertEqual(initial.matchingSample?.tokensPerSecond, 51.3)
        settings.reasoningEffort = "high"
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.effort, "high")
        settings.reasoningModel = "gpt-6.1-sol-pro"
        XCTAssertNil(AnalysisPerformance.selection(settings).sample)
        settings.selectAnalysisService(.deepSeek)
        let deepSeek = AnalysisPerformance.selection(settings)
        XCTAssertTrue(deepSeek.matchesConfiguration)
        XCTAssertEqual(deepSeek.matchingSample?.effort, "low")
        XCTAssertEqual(deepSeek.matchingSample?.source, "OpenRouter")
        XCTAssertEqual(deepSeek.matchingSample?.firstTokenSeconds, 1.13)
        XCTAssertEqual(deepSeek.matchingSample?.tokensPerSecond, 153)
        settings.deepSeekEffort = "max"
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertEqual(AnalysisPerformance.selection(settings).matchingSample?.tokensPerSecond, 217)
        settings.selectAnalysisService(.qwen)
        XCTAssertFalse(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertEqual(AnalysisPerformance.selection(settings).sample?.source, "OpenRouter")
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
        settings.selectAnalysisService(.kimi)
        XCTAssertTrue(AnalysisPerformance.selection(settings).matchesConfiguration)
        settings.kimiConnection.baseURL = "https://custom.example/v1"
        XCTAssertFalse(AnalysisPerformance.selection(settings).matchesConfiguration)
        XCTAssertNil(AnalysisPerformance.selection(settings).matchingSample)
        settings.selectAnalysisService(.compatible)
        settings.compatibleModel = "gpt-6.1-sol"
        XCTAssertNil(AnalysisPerformance.selection(settings).sample)
        XCTAssertTrue(AnalysisPerformance.samples.allSatisfy {
            $0.firstTokenSeconds > 0 && $0.tokensPerSecond > 0 && $0.url.hasPrefix("https://") && !$0.capturedAt.isEmpty
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
        for mode in [AnalysisThinking.low, .medium, .xhigh, .disabled, .enabled, .modelDefault] {
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
        XCTAssertEqual(second.settings.glmConnection.thinking, .low)
        XCTAssertEqual(AppSettings.load(defaults: defaults).glmConnection.thinking, .low)
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
