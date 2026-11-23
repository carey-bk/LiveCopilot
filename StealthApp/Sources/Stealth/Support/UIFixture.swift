#if DEBUG
import AppKit
import Foundation

/// Debug-only, mock-only launch arguments that put the UI into reproducible states for
/// before/after screenshot comparison. Content is synthetic; writes stay in the mock data directory.
///
///     --mock --ui-preview --ui-fixture listening|streaming|answered|session|error|notice
///     --ui-background glass|frosted|white   --ui-language english|simplifiedChinese
///     --ui-text-size 28   --ui-dark   --ui-seed-knowledge
///     --ui-settings-page <SettingsPage case name>   --ui-open-history
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

    /// Holds the mock answer half-way so the streaming state can be captured.
    static var reasoning: (any ReasoningProvider)? { state == "streaming" ? PausedReasoningProvider() : nil }

    static func apply(to coordinator: AppCoordinator, openSettings: (SettingsPage) -> Void, openHistory: () -> Void) async {
        guard AppPaths.isMock else { return }
        if flag("--ui-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let raw = value("--ui-background"), let background = AppBackground(rawValue: raw) { coordinator.settings.background = background }
        if let raw = value("--ui-language"), let language = AppLanguage(rawValue: raw) { coordinator.settings.language = language }
        if let raw = value("--ui-text-size"), let size = Double(raw) {
            coordinator.settings.transcriptFontSize = size
            coordinator.settings.answerFontSize = size
        }
        if flag("--ui-seed-knowledge") { await seedKnowledge(coordinator) }

        switch state {
        case "listening":
            await listen(coordinator, automatic: false)
        case "streaming", "answered":
            coordinator.settings.automaticSuggestions = true
            await listen(coordinator, automatic: true)
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
        case "notice":
            await listen(coordinator, automatic: false)
            coordinator.applyFixtureCaptureNotice(AppCoordinator.systemAudioMissingNotice)
        default:
            break
        }

        if let raw = value("--ui-settings-page"),
           let page = SettingsPage.allCases.first(where: { String(describing: $0) == raw }) {
            openSettings(page)
        }
        if flag("--ui-open-history") { openHistory() }
        if let folder = value("--ui-snapshot") { await snapshot(into: URL(fileURLWithPath: folder)) }
    }

    /// Renders each visible window of this process to PNG without Screen Recording permission.
    /// Behind-window blur (materials) is not captured; the PNG shows those areas as transparent.
    private static func snapshot(into folder: URL) async {
        let delay = value("--ui-snapshot-delay").flatMap(Double.init) ?? 2.5
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = value("--ui-snapshot-name") ?? (state ?? "app")
        for window in NSApp.windows where window.isVisible && window.frame.width > 40 {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let kind = window is OverlayWindow ? "overlay" : window.title.isEmpty ? String(describing: type(of: window)) : window.title
            let name = "\(prefix)--\(kind)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
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
