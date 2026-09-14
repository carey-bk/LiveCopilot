import SwiftUI

struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var suggestion: SuggestionStore
    @State private var query = ""
    @State private var showTranscript = true
    @State private var followTranscript = true
    @State private var transcriptHeight: CGFloat = 22
    @State private var answerHeight: CGFloat = 28
    @State private var chromeHeight: CGFloat = 260
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800
    var onContentHeight: (CGFloat) -> Void
    init(coordinator: AppCoordinator, onContentHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.coordinator = coordinator; transcript = coordinator.transcript; suggestion = coordinator.suggestion
        self.onContentHeight = onContentHeight
    }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        Group {
            if coordinator.settings.overlayAutoHeight {
                // Also scroll the whole card on unusually short displays, keeping every control reachable.
                ScrollView { content }
            } else { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            WindowBackgroundView(style: coordinator.settings.background, isOverlay: true)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .preferredColorScheme(coordinator.settings.background.usesLightAppearance ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .onPreferenceChange(OverlayContentHeights.self) { heights in
            if let height = heights["transcript"] { transcriptHeight = height }
            if let height = heights["answer"] { answerHeight = height }
            if let height = heights["window"] {
                if let viewport = heights["answerViewport"] { chromeHeight = max(0, height - viewport) }
                onContentHeight(height)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { event in
            if let window = event.object as? OverlayWindow, let screen = window.screen { screenHeight = screen.visibleFrame.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenHeight = (NSApp.windows.first(where: { $0 is OverlayWindow })?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.trailing, 16) // Keep header buttons outside the corner resize target.
            Text(t(coordinator.statusMessage)).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if coordinator.isRunning {
                HStack {
                    Text(t(coordinator.questionState)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(t("Auto"), isOn: $coordinator.settings.automaticSuggestions)
                        .toggleStyle(OverlaySwitchStyle())
                        .accessibilityIdentifier("automatic-suggestions")
                }
            }
            if showTranscript {
                if transcript.lines.isEmpty {
                    if coordinator.isRunning { Text(t("Listening — waiting for speech")).font(.caption).foregroundStyle(.secondary) }
                } else {
                    transcriptView.frame(height: min(145, max(44, transcriptHeight + 22)))
                }
            }
            HStack(spacing: 6) {
                ForEach(SuggestionMode.allCases) { mode in
                    Button { coordinator.requestSuggestion(mode: mode) } label: { Label(t(mode.label), systemImage: mode.systemImage).font(.caption) }
                        .help(coordinator.hotkeys.combo(for: mode).display)
                }
                Spacer()
                Button { showTranscript.toggle() } label: { Image(systemName: "text.bubble") }.help(t("Show/hide conversation"))
            }
            Divider()
            answer
            HStack(alignment: .center) {
                TextField(t("Ask anything — listening can be off"), text: $query, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit { submit() }.accessibilityIdentifier("manual-query")
                Button(t("Ask")) { submit() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Toggle(t("Use recent conversation"), isOn: $coordinator.includeConversation).font(.caption2).toggleStyle(.checkbox)
                Spacer()
                if suggestion.isLoading { Button(t("Cancel")) { coordinator.cancelAnswer() }.font(.caption) }
            }
            footer.padding(.trailing, 20)
        }.padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { measure("window") }
    }
    private func submit() { let value = query; query = ""; coordinator.askText(value) }
    private var header: some View {
        HStack {
            Text(t("LiveCopilot")).font(.headline)
            if coordinator.isMock { Text(t("MOCK")).font(.caption2.bold()).foregroundStyle(.orange) }
            Spacer()
            Button { Task { await coordinator.toggle() } } label: {
                Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(coordinator.isRunning ? Color.red : .green)
            }.disabled(coordinator.isTransitioning).help(t(coordinator.isRunning ? "Stop listening" : "Start listening"))
            Button { coordinator.toggleMic() } label: { Image(systemName: coordinator.micEnabled ? "mic.fill" : "mic.slash") }
                .help(t("Toggle your microphone in Remote Meeting mode"))
            Button { coordinator.onOpenSettings?() } label: { Image(systemName: "gearshape") }.help(t("Settings and knowledge base"))
            Button { coordinator.settings.overlayEdgeHide.toggle() } label: {
                Image(systemName: coordinator.settings.overlayEdgeHide ? "pin" : "pin.fill")
                    .foregroundStyle(coordinator.settings.overlayEdgeHide ? Color.secondary : .blue)
            }.help(t(coordinator.settings.overlayEdgeHide ? "Pin window" : "Unpin and hide at right edge"))
                .accessibilityIdentifier("overlay-pin")
            Button { (NSApp.windows.first(where: { $0 is OverlayWindow }) as? OverlayWindow)?.tuckAway() } label: { Image(systemName: "minus") }.help(t("Hide (⌥H)"))
        }.buttonStyle(.borderless)
    }
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if transcript.lines.isEmpty { Text(t("Conversation appears here when listening.")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(transcript.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(t(line.speaker.rawValue)).font(.caption2.bold()).foregroundStyle(line.speaker == .you ? Color.blue : .green).frame(width: 35, alignment: .leading)
                                Text(line.content).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.background { measure("transcript") }
                }.onChange(of: transcript.lines) { _, _ in if followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                Toggle(t("Follow transcript"), isOn: $followTranscript).font(.caption2).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if !suggestion.question.isEmpty { Text(suggestion.question).font(.subheadline.bold()).textSelection(.enabled) }
                if let warning = suggestion.warning { Text(t(warning)).font(.caption).foregroundStyle(.orange) }
                if suggestion.isLoading && suggestion.text.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(t("Retrieving evidence and thinking…")).font(.caption) }
                }
                if suggestion.text.isEmpty && !suggestion.isLoading && suggestion.error == nil {
                    Text(t("Ask a question below, or use ⌥Space for help with the conversation.")).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(SuggestionParser.sections(suggestion.text).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t(section.title)).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(.init(section.content)).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error = suggestion.error { Text(t(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !suggestion.sources.isEmpty {
                    Divider()
                    Text(t("Sources · retrieved local evidence")).font(.caption.bold())
                    ForEach(Array(suggestion.sources.enumerated()), id: \.element.id) { i, source in
                        DisclosureGroup("[S\(i + 1)] \(source.chunk.displayLabel(language: coordinator.settings.language))") {
                            Text(source.chunk.text).font(.caption).textSelection(.enabled)
                        }.font(.caption2)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background { measure("answer") }
        }.frame(maxWidth: .infinity)
            .frame(height: coordinator.settings.overlayAutoHeight ? min(max(80, min(900, screenHeight - 24) - chromeHeight), max(28, answerHeight)) : nil)
            .frame(minHeight: coordinator.settings.overlayAutoHeight ? 0 : 80, maxHeight: coordinator.settings.overlayAutoHeight ? nil : .infinity)
            .background { measure("answerViewport") }
    }
    private func measure(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: OverlayContentHeights.self, value: [key: ceil(proxy.size.height)])
        }
    }
    private var footer: some View {
        HStack {
            Text(t(coordinator.settings.scenario.rawValue)).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let ms = suggestion.firstTextMS { Text("\(t("First text")) \(Double(ms) / 1000, specifier: "%.1f")s").font(.caption2).foregroundStyle(.secondary) }
            if !suggestion.text.isEmpty {
                Button(t("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(suggestion.text, forType: .string) }.font(.caption2)
            }
            Text(t("⌥H")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .help(t("Drag any edge or corner to resize"))
            .allowsHitTesting(false) // The native border owns all eight resize directions.
    }
}

private struct OverlayContentHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Native switches lose their on-state color when this nonactivating panel is in the background.
/// Draw the state explicitly while retaining Toggle's accessibility and Button's keyboard behavior.
private struct OverlaySwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.blue : Color.primary.opacity(0.18))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .frame(width: 14, height: 14).padding(2)
                    }
                    .frame(width: 32, height: 18)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}
