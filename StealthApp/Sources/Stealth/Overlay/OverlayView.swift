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
    @State private var fixedHeights: [String: CGFloat] = [:]
    var onContentHeight: (CGFloat) -> Void
    var onMinimumHeight: (CGFloat) -> Void
    init(coordinator: AppCoordinator, onContentHeight: @escaping (CGFloat) -> Void = { _ in }, onMinimumHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.coordinator = coordinator; transcript = coordinator.transcript; suggestion = coordinator.suggestion
        self.onContentHeight = onContentHeight; self.onMinimumHeight = onMinimumHeight
    }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    private var hasTranscript: Bool { showTranscript && transcript.hasContent }
    private var transcriptIdeal: CGFloat { hasTranscript ? min(145, max(44, transcriptHeight + 22)) : 0 }
    private var chromeHeight: CGFloat {
        // Padding, divider, and spacing between the fixed groups and content panes.
        (fixedHeights["top"] ?? 66) + (fixedHeights["actions"] ?? 24) + (fixedHeights["bottom"] ?? 84) + 29 + (hasTranscript ? 50 : 40)
    }
    private var desiredHeight: CGFloat { chromeHeight + transcriptIdeal + max(28, answerHeight) }
    private func reportSize() {
        onMinimumHeight(chromeHeight + 28 + (hasTranscript ? 44 : 0))
        onContentHeight(desiredHeight)
    }
    var body: some View {
        GeometryReader { geometry in
            let panes = OverlayLayout.panes(available: geometry.size.height - chromeHeight, transcriptIdeal: transcriptIdeal,
                                            answerIdeal: answerHeight, automatic: coordinator.settings.overlayAutoHeight)
            VStack(alignment: .leading, spacing: 10) {
                top.fixedSize(horizontal: false, vertical: true).background { measure("top") }
                if hasTranscript { transcriptView.frame(height: panes.transcript) }
                actions.fixedSize(horizontal: false, vertical: true).background { measure("actions") }
                Divider()
                answer.frame(height: panes.answer)
                bottom.fixedSize(horizontal: false, vertical: true).background { measure("bottom") }
            }
            .padding(14)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background { WindowBackgroundView(style: coordinator.settings.background, isOverlay: true) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .preferredColorScheme(coordinator.settings.background.usesLightAppearance ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .onPreferenceChange(OverlayContentHeights.self) { heights in
            if let height = heights["transcript"] { transcriptHeight = height }
            if let height = heights["answer"] { answerHeight = height }
            for key in ["top", "actions", "bottom"] { if let height = heights[key] { fixedHeights[key] = height } }
        }
        .onChange(of: desiredHeight) { _, _ in reportSize() }
        .onChange(of: coordinator.conversationGeneration) { _, _ in
            query = ""; showTranscript = true; followTranscript = true
            transcriptHeight = 22; answerHeight = 28
            reportSize()
        }
        .onAppear { reportSize() }
    }
    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.trailing, 16)
            Text(t(coordinator.statusMessage)).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if coordinator.isRunning {
                HStack {
                    Text(t(coordinator.questionState)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(t("Auto"), isOn: $coordinator.settings.automaticSuggestions)
                        .toggleStyle(OverlaySwitchStyle()).accessibilityIdentifier("automatic-suggestions")
                }
                if showTranscript && !transcript.hasContent {
                    Text(t("Listening — waiting for speech")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 6) {
            ForEach(SuggestionMode.allCases) { mode in
                Button { coordinator.requestSuggestion(mode: mode) } label: { Label(t(mode.label), systemImage: mode.systemImage).font(.caption) }
                    .help(coordinator.hotkeys.combo(for: mode).display)
            }
            Spacer()
            Button { showTranscript.toggle() } label: { Image(systemName: "text.bubble") }.help(t("Show/hide conversation"))
        }
    }
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        }
    }
    private func submit() { let value = query; query = ""; coordinator.askText(value) }
    private var header: some View {
        HStack {
            AppBrandTitle(iconSize: 22)
            if coordinator.isMock { Text(t("MOCK")).font(.caption2.bold()).foregroundStyle(.orange) }
            Spacer()
            Button { Task { await coordinator.toggle() } } label: {
                Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(coordinator.isRunning ? Color.red : .green)
            }.disabled(coordinator.isTransitioning).help(t(coordinator.isRunning ? "Stop listening" : "Start listening"))
            Button { Task { await coordinator.resetConversation() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(coordinator.isTransitioning)
                .help(t("Clear conversation and answers; keep listening if active"))
                .accessibilityLabel(t("Start fresh")).accessibilityIdentifier("reset-conversation")
            Button { coordinator.toggleMic() } label: { Image(systemName: coordinator.micEnabled ? "mic.fill" : "mic.slash") }
                .disabled(coordinator.isTransitioning).help(t("Toggle your microphone in Remote Meeting mode"))
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
                        if !transcript.hasContent { Text(t("Conversation appears here when listening.")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(transcript.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(t(line.speaker.rawValue)).font(.caption2.bold()).foregroundStyle(line.speaker == .you ? Color.blue : .green).frame(width: 35, alignment: .leading)
                                Text(line.content).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !transcript.partialThem.isEmpty {
                            partialRow(transcript.partialThem, speaker: coordinator.settings.mode == .inPerson ? .room : .them)
                        }
                        if !transcript.partialYou.isEmpty { partialRow(transcript.partialYou, speaker: .you) }
                        Color.clear.frame(height: 1).id("latest")
                    }.background { measure("transcript") }
                }.onChange(of: transcript.lines) { _, _ in if followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcript.partialThem) { _, _ in if followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcript.partialYou) { _, _ in if followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                Toggle(t("Follow transcript"), isOn: $followTranscript).font(.caption2).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    private func partialRow(_ text: String, speaker: Speaker) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(t(speaker.rawValue)).font(.caption2.bold()).foregroundStyle(speaker == .you ? Color.blue : .green).frame(width: 35, alignment: .leading)
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityLabel(t("Recognizing") + " · " + t(speaker.rawValue) + " · " + text)
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
