#if DEBUG
import AppKit
import Foundation

/// Debug-only, mock-only launch arguments that put the UI into reproducible states for
/// before/after screenshot comparison. Content is synthetic; writes stay in the mock data directory.
///
///     --mock --ui-preview --ui-fixture listening|streaming|answered|merged|session|error|notice
///     --ui-background glass|frosted|white   --ui-language english|simplifiedChinese
///     --ui-text-size 28   --ui-dark   --ui-seed-knowledge   --ui-onboarding-step <OnboardingStep case>
///     --ui-tip <OverlayTourState.Step case>   --ui-settings-page <SettingsPage case name> [--ui-service-role 0-3]   --ui-laya-threshold 0.85   --ui-continuous update|separate   --ui-open-history   --ui-answer-only
///     --ui-query <typed question>   --ui-question-only   --ui-transcript-collapsed   --ui-transcript-lines n   --ui-translations japanese,english   --ui-scroll-end
///     --ui-snapshot <folder> [--ui-snapshot-name n] [--ui-snapshot-delay s] [--ui-snapshot-quit]
@MainActor
enum UIFixture {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static func value(_ flag: String) -> String? {
        guard AppPaths.isMock, let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    private static func flag(_ name: String) -> Bool { AppPaths.isMock && arguments.contains(name) }

    static var state: String? { value("--ui-fixture") }
    /// Text placed in the overlay's question field, for the multi-line input state.
    /// Services tab to open with `--ui-settings-page services`: 0 speech, 1 triggers, 2 indexing, 3 answers.
    static var serviceRole: Int { value("--ui-service-role").flatMap(Int.init) ?? 0 }
    static var query: String? { value("--ui-query")?.replacingOccurrences(of: "\\n", with: "\n") }

    /// Holds the mock answer half-way so the streaming state can be captured.
    static var reasoning: (any ReasoningProvider)? { state == "streaming" ? PausedReasoningProvider() : nil }

    static func apply(to coordinator: AppCoordinator, openSettings: (SettingsPage) -> Void, openHistory: () -> Void) async {
        guard AppPaths.isMock else { return }
        if flag("--ui-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        // The mock preferences suite persists between runs, so every run states the layout explicitly.
        coordinator.settingsDefaults.set(flag("--ui-answer-only"), forKey: "overlayAnswerOnly")
        coordinator.settings.includeConversation = !flag("--ui-question-only")
        coordinator.settingsDefaults.set(flag("--ui-transcript-collapsed"), forKey: "overlayTranscriptCollapsed")
        coordinator.settings.transcriptExpandedLines = value("--ui-transcript-lines").flatMap(Int.init) ?? 6
        // Mock settings persist between runs, so the translation state is set on every launch.
        let translations = value("--ui-translations")?.split(separator: ",").compactMap { TranslationLanguage(rawValue: String($0)) } ?? []
        coordinator.settings.answerTranslationEnabled = !translations.isEmpty
        coordinator.settings.answerTranslationLanguages = translations
        if let raw = value("--ui-listening-service"), let service = ListeningService(rawValue: raw) { coordinator.settings.listeningService = service }
        if let raw = value("--ui-laya-idle"), let seconds = TimeInterval(raw) { coordinator.layaIdleReleaseSeconds = seconds }
        if let raw = value("--ui-laya-threshold"), let threshold = Double(raw) { coordinator.settings.layaThreshold = JevThreshold.snapped(threshold) }
        if let raw = value("--ui-continuous"), let policy = ContinuousQuestionPolicy(rawValue: raw) { coordinator.settings.continuousQuestionPolicy = policy }
        if let raw = value("--ui-background"), let background = AppBackground(rawValue: raw) { coordinator.settings.background = background }
        if let raw = value("--ui-language"), let language = AppLanguage(rawValue: raw) { coordinator.settings.language = language }
        if let raw = value("--ui-text-size"), let size = Double(raw) {
            coordinator.settings.transcriptFontSize = size
            coordinator.settings.answerFontSize = size
        }
        if flag("--ui-seed-knowledge") { await seedKnowledge(coordinator) }
        if let raw = value("--ui-onboarding-step"),
           let step = OnboardingStep.allCases.first(where: { String(describing: $0) == raw }) {
            coordinator.onboarding.state.step = step
        }

        switch state {
        case "listening":
            await listen(coordinator, automatic: false)
            coordinator.levels.applyFixture(you: 0.55, them: 0.8)
        case "streaming", "answered":
            coordinator.settings.automaticSuggestions = true
            await listen(coordinator, automatic: true)
        case "merged":
            // The other side adds to its question before you speak: the answer is written again.
            await listen(coordinator, automatic: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            coordinator.receiveMockEvent(.transcript(.init(id: "fixture-addition", speaker: .them, text: "And how does it hold up under peak load?",
                                                         startMS: 4_000, endMS: 5_000, receivedAt: Date())), speaker: .them)
            coordinator.receiveMockEvent(.delegation(id: "fixture-addition", offsetMS: 5_000), speaker: .them)
        case "session":
            // Records one synthetic session into mock history, then stops listening.
            await listen(coordinator, automatic: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await coordinator.stop()
        case "error":
            coordinator.settings.automaticSuggestions = false
            await coordinator.start()
            try? await Task.sleep(nanoseconds: 400_000_000)
            coordinator.receiveMockEvent(.failed("Download the selected speech model and VAD in Services first."), speaker: .them)
        case "starting":
            // Holds the listen button in its start-up state, as during a cold audio-device start.
            coordinator.settings.mode = .remote
            coordinator.isTransitioning = true
            coordinator.statusMessage = "Starting audio capture…"
        case "notice":
            await listen(coordinator, automatic: false)
            coordinator.applyFixtureCaptureNotice(AppCoordinator.systemAudioMissingNotice)
        default:
            break
        }

        if let raw = value("--ui-tip"), let step = OverlayTourState.Step.order.first(where: { String(describing: $0) == raw }) {
            coordinator.onboarding.replayTips()
            for _ in 0..<step.position { coordinator.onboarding.advanceTip() }
        }
        if let raw = value("--ui-settings-page"),
           let page = SettingsPage.allCases.first(where: { String(describing: $0) == raw }) {
            openSettings(page)
        }
        if flag("--ui-open-history") { openHistory() }
        if flag("--ui-gallery") { DesignGallery.open() }
        if let folder = value("--ui-snapshot") {
            await snapshot(into: URL(fileURLWithPath: folder), coordinator: coordinator)
        }
    }

    /// Renders each visible window of this process to PNG without Screen Recording permission.
    /// Behind-window blur (materials) is not captured; the PNG shows those areas as transparent.
    private static func snapshot(into folder: URL, coordinator: AppCoordinator) async {
        let laya = coordinator.laya
        let delay = value("--ui-snapshot-delay").flatMap(Double.init) ?? 2.5
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = value("--ui-snapshot-name") ?? (state ?? "app")
        if flag("--ui-scroll-end") {
            // Show the end of long settings pages: scroll the tallest scroll view of each titled window to its bottom.
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            for window in NSApp.windows where window.isVisible && !window.title.isEmpty {
                guard let scroll = (window.contentView.map(scrollViews) ?? []).max(by: { $0.frame.height < $1.frame.height }),
                      let document = scroll.documentView else { continue }
                let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        for window in NSApp.windows where window.isVisible && window.frame.width > 40 {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let kind = window is OverlayWindow ? "overlay" : window.title.isEmpty ? String(describing: type(of: window)) : window.title
            let name = "\(prefix)--\(kind)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
        if flag("--ui-dump-laya") {
            let report = ["state=\(laya.state.rawValue) display=\(laya.displayState.rawValue) verified=\(laya.wasVerified)",
                          "running=\(coordinator.isRunning) auto=\(coordinator.settings.automaticSuggestions) service=\(coordinator.settings.listeningService.rawValue) gate=\(coordinator.layaGateStatus)",
                          "status=\(coordinator.statusMessage)"] + laya.diagnosticEvents
            try? report.joined(separator: "\n").write(to: folder.appendingPathComponent(prefix + "--laya.txt"), atomically: true, encoding: .utf8)
        }
        if flag("--ui-dump-scrollers") {
            // Scrollers are not rendered by cacheDisplay; record their style instead (0 legacy, 1 overlay).
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            let lines = NSApp.windows.filter(\.isVisible).flatMap { window in
                (window.contentView.map(scrollViews) ?? []).map { "\(window.title.isEmpty ? "overlay" : window.title)\t\(type(of: $0))\tstyle=\($0.scrollerStyle.rawValue)\tsystem=\(NSScroller.preferredScrollerStyle.rawValue)" }
            }
            try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent(prefix + "--scrollers.txt"), atomically: true, encoding: .utf8)
        }
        if flag("--ui-snapshot-quit") { exit(0) }
    }

    private static func listen(_ coordinator: AppCoordinator, automatic: Bool) async {
        coordinator.settings.mode = .remote
        coordinator.settings.automaticSuggestions = automatic
        await coordinator.start()
        // The mock session emits its own first question after 0.2 s.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let lines: [(Speaker, String)] = [
            (.you, "Method B keeps median latency around 120 milliseconds."),
            (.them, "How does that compare with the baseline under peak load?"),
            (.you, "Under peak load the baseline is roughly three times slower."),
        ]
        guard !automatic else { return }
        var offset = 2_000
        for (speaker, text) in lines {
            coordinator.receiveMockEvent(.speechActivity(true), speaker: speaker)
            coordinator.receiveMockEvent(.transcript(.init(id: UUID().uuidString, speaker: speaker, text: text,
                                                           startMS: offset, endMS: offset + 1_800, receivedAt: Date())), speaker: speaker)
            coordinator.receiveMockEvent(.speechActivity(false), speaker: speaker)
            offset += 2_200
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        coordinator.receiveMockEvent(.partialTranscript("那内存占用方面有什么取舍"), speaker: .them)
    }

    /// Synthetic Markdown documents in the mock data directory; imported once.
    private static func seedKnowledge(_ coordinator: AppCoordinator) async {
        guard coordinator.knowledgeDocuments.isEmpty else { return }
        let folder = AppPaths.dataDirectory(mock: true).appendingPathComponent("fixture-documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let documents = [
            ("Method-B-benchmark.md", "# Method B benchmark\n\nMethod B keeps median latency around 120 ms on the synthetic workload. Peak-load latency of the baseline is roughly three times higher. Memory use grows by about 18% because of the warm cache.\n"),
            ("项目答辩要点.md", "# 答辩要点\n\n方法 B 的核心改进是预热缓存与批量调度。局限：冷启动阶段延迟较高；内存占用增加约 18%。\n"),
            ("Interview-notes.txt", "Synthetic interview notes. Strengths: system design, latency optimisation, clear trade-off communication.\n"),
        ]
        let urls = documents.map { name, text -> URL in
            let url = folder.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        coordinator.importDocuments(urls)
        for _ in 0..<50 where coordinator.isIndexing { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
}

private struct PausedReasoningProvider: ReasoningProvider {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let text = "## Core answer\nMethod B keeps median latency around 120 ms, roughly three times faster than the baseline under peak load. The main"
            let task = Task {
                for part in text.components(separatedBy: " ") {
                    if Task.isCancelled { break }
                    continuation.yield(part + " ")
                    try? await Task.sleep(nanoseconds: 12_000_000)
                }
                // Stay mid-stream until the answer is cancelled.
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 500_000_000) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
