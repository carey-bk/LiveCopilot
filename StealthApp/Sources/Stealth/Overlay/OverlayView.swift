import SwiftUI

struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var translation: TranscriptTranslationStore
    @State private var showTranslation = false
    @State private var translationTarget: TranscriptTranslationStore.Language = .simplified
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var hotkeys: HotkeyStore
    @ObservedObject var onboarding: OnboardingStore
    @State private var query = ""
    @State private var followTranscript = true
    @AppStorage("overlayTranscriptCollapsed") private var transcriptCollapsed = false
    @State private var chromeHeight: CGFloat = 368
    @State private var answerContentHeight: CGFloat = 56
    var onContentHeight: (CGFloat) -> Void
    var onMinimumHeight: (CGFloat) -> Void
    init(coordinator: AppCoordinator, transcriptPreferences: UserDefaults = .standard, onContentHeight: @escaping (CGFloat) -> Void = { _ in }, onMinimumHeight: @escaping (CGFloat) -> Void = { _ in }) {
        _transcriptCollapsed = AppStorage(wrappedValue: false, "overlayTranscriptCollapsed", store: transcriptPreferences)
        self.coordinator = coordinator; translation = coordinator.translation; transcript = coordinator.transcript; hotkeys = coordinator.hotkeys
        onboarding = coordinator.onboarding
        self.onContentHeight = onContentHeight; self.onMinimumHeight = onMinimumHeight
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    private var transcriptSize: CGFloat { OverlayTypography.clamped(coordinator.settings.transcriptFontSize, fallback: 12) }
    private var answerSize: CGFloat { OverlayTypography.clamped(coordinator.settings.answerFontSize, fallback: 14) }
    private var speakerWidth: CGFloat { max(35, transcriptSize * 2.8) }
    private func reportSize() {
        // Only the answer viewport grows. The voice area and composer keep
        // their position relative to the window's stable top edge.
        let fixedHeight = chromeHeight + 10 + 28 // inter-pane spacing and outer padding
        onMinimumHeight(fixedHeight + 56)
        onContentHeight(fixedHeight + max(56, answerContentHeight))
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    top.fixedSize(horizontal: false, vertical: true)
                    if let step = onboarding.visibleTip {
                        OverlayFirstUseTip(step: step, coordinator: coordinator)
                    }
                    HStack {
                        Button { transcriptCollapsed.toggle() } label: {
                            Label(b(transcriptCollapsed ? "Expand transcript" : "Collapse transcript", transcriptCollapsed ? "展开转写" : "折叠转写"),
                                  systemImage: transcriptCollapsed ? "chevron.down" : "chevron.up")
                        }.buttonStyle(.borderless).font(.caption)
                            .accessibilityIdentifier("transcript-collapse")
                        Spacer()
                        Button { showTranslation.toggle() } label: {
                            Label(translation.enabled ? (translation.busy ? "… " : "") + translation.target.rawValue : b("Translate", "翻译"), systemImage: "character.bubble")
                        }.buttonStyle(.borderless).font(.caption)
                            .accessibilityIdentifier("transcript-translation")
                            .popover(isPresented: $showTranslation) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(b("Transcript translation", "转写翻译")).font(.headline)
                                    Picker(b("Target language", "目标语言"), selection: $translationTarget) {
                                        ForEach(TranscriptTranslationStore.Language.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    Text(b("Uses your configured answer model. Enabling sends the latest utterance and subsequent stable transcript previews to that service and uses its API quota. Original text is retained. A slow service only processes the latest 20 lines.", "使用已配置的回答模型。开启后会向该服务发送最近一句及后续稳定的临时转写文字，并消耗 API 用量。保留原文；服务较慢时仅处理最近 20 条转写。")).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Button(translation.enabled ? b("Apply language / retry", "应用语言 / 重试") : b("Enable translation", "开启翻译")) {
                                        coordinator.setTranscriptTranslation(translationTarget); showTranslation = false
                                    }
                                    if translation.enabled {
                                        Button(b("Stop translation", "关闭翻译")) { coordinator.setTranscriptTranslation(nil); showTranslation = false }
                                    }
                                }.padding(16).frame(width: 310)
                            }
                    }
                    if translation.enabled && translation.failed {
                        Text(b("Translation failed. Reopen Translation to retry; original text is retained.", "翻译失败，请重新开启翻译重试；原文已保留。")).font(.caption2).foregroundStyle(.orange)
                    }
                    transcriptView
                    Divider()
                    actions.frame(height: 28)
                    bottom.frame(height: 78, alignment: .top)
                    Divider()
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { measured in
                    Color.clear.preference(key: OverlayChromeHeightKey.self, value: measured.size.height)
                })
                ConversationFlowView(coordinator: coordinator, fontSize: answerSize, onContentHeight: { height in
                    guard height.isFinite, height > 0, abs(height - answerContentHeight) > 0.5 else { return }
                    answerContentHeight = height
                    reportSize()
                })
                .frame(maxHeight: .infinity)
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
        .onChange(of: coordinator.conversationGeneration) { _, _ in
            query = ""; followTranscript = true
            reportSize()
        }
        .onPreferenceChange(OverlayChromeHeightKey.self) { height in
            guard height > 0, abs(height - chromeHeight) > 0.5 else { return }
            chromeHeight = height
            reportSize()
        }
        .onAppear { reportSize() }
    }
    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.trailing, 16)
            Text(t(coordinator.statusMessage)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if coordinator.isRunning {
                HStack {
                    Text(t(coordinator.questionState)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(t("Auto"), isOn: $coordinator.settings.automaticSuggestions)
                        .toggleStyle(OverlaySwitchStyle()).accessibilityIdentifier("automatic-suggestions")
                }
                if coordinator.settings.automaticSuggestions,
                   coordinator.settings.listeningService.isLocal {
                    Text("Laya " + coordinator.layaGateStatus.label(coordinator.settings.language) +
                         (coordinator.layaLastScore.map { String(format: " · %@ %.2f / %.2f", t("Latest score"), $0, coordinator.settings.layaThreshold) } ?? ""))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("laya-gate-status")
                }
                if coordinator.settings.listeningService == .apple {
                    Text(t("Apple ASR uses one language. For mixed Chinese/English, select another speech recognition engine in Services."))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help(t("Apple ASR uses one language. For mixed Chinese/English, select another speech recognition engine in Services."))
                }
            }
        }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(coordinator.settings.enabledSuggestionModes) { mode in
                    Button { coordinator.requestSuggestion(mode: mode) } label: { Label(t(mode.label), systemImage: mode.systemImage).font(.caption) }
                        .help(hotkeys.combo(for: mode).display).accessibilityIdentifier("action-" + mode.rawValue)
                        .onboardingHighlight(onboarding.visibleTip == .answer && mode == .reply)
                }
                Spacer(minLength: 4)
                Menu {
                    Picker(t("Answer language"), selection: $coordinator.settings.answerLanguage) {
                        ForEach(AnswerLanguage.allCases) { language in Text(language.label).tag(language) }
                    }.pickerStyle(.inline)
                } label: {
                    Label(coordinator.settings.answerLanguage.label, systemImage: "globe")
                        .font(.caption)
                }.fixedSize().help(t("Answer language"))
                    .accessibilityIdentifier("answer-language")
            }
        }
    }
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                TextField(t("Ask anything — listening can be off"), text: $query, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1).frame(height: 28)
                    .onSubmit { submit() }.accessibilityIdentifier("manual-query")
                    .onboardingHighlight(onboarding.visibleTip == .start && onboarding.state.prefersTyping)
                Button(t("Ask")) { submit() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Toggle(t("Use recent conversation"), isOn: $coordinator.includeConversation).font(.caption2).toggleStyle(OverlaySwitchStyle())
                Spacer(minLength: 4)
                Menu {
                    Picker(t("Knowledge mode"), selection: $coordinator.settings.knowledgeMode) {
                        ForEach(KnowledgeMode.allCases) { mode in Text(t(mode.label)).tag(mode) }
                    }.pickerStyle(.inline)
                } label: {
                    Text(t(coordinator.settings.knowledgeMode.compactLabel)).font(.caption2)
                }.fixedSize().help(t(coordinator.settings.knowledgeMode.label))
                    .accessibilityIdentifier("knowledge-mode")
                if coordinator.answerIsRunning { Button(t("Cancel")) { coordinator.cancelAnswer() }.font(.caption) }
            }
            footer.padding(.trailing, 20)
        }
    }
    private func submit() { let value = query; query = ""; coordinator.askText(value) }
    private var header: some View {
        HStack {
            HStack {
                AppBrandTitle(iconSize: 22)
                if coordinator.isMock { Text(t("MOCK")).font(.caption2.bold()).foregroundStyle(.orange) }
                Spacer(minLength: 0)
            }.overlay { OverlayDragRegion() }
                .help(b("Turn off automatic docking to drag this header anywhere.", "关闭自动贴边后，可拖动这里自由移动窗口。"))
            Button { Task { await coordinator.toggle() } } label: {
                Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(coordinator.isRunning ? Color.red : .green)
            }.disabled(coordinator.isTransitioning).help(t(coordinator.isRunning ? "Stop listening" : "Start listening"))
                .accessibilityIdentifier("overlay-toggle-listening")
                .onboardingHighlight(onboarding.visibleTip == .start && !onboarding.state.prefersTyping)
            Button { Task { await coordinator.resetConversation() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(coordinator.isTransitioning)
                .help(t("Clear conversation and answers; keep listening if active"))
                .accessibilityLabel(t("Start fresh")).accessibilityIdentifier("reset-conversation")
            Button { coordinator.toggleMic() } label: { Image(systemName: coordinator.micEnabled ? "mic.fill" : "mic.slash") }
                .disabled(coordinator.isTransitioning).help(t("Toggle your microphone in Remote Meeting mode"))
            Button { coordinator.onOpenSettings?() } label: { Image(systemName: "gearshape") }.help(t("Settings and knowledge base"))
                .onboardingHighlight(onboarding.visibleTip == .captureExclusion)
            Button { coordinator.settings.overlayEdgeHide.toggle() } label: {
                Image(systemName: coordinator.settings.overlayEdgeHide ? "pin" : "pin.fill")
                    .foregroundStyle(coordinator.settings.overlayEdgeHide ? Color.secondary : .blue)
            }.help(coordinator.settings.overlayEdgeHide
                   ? b("Turn off automatic docking · drag freely", "关闭自动贴边 · 自由拖动")
                   : b("Turn on automatic docking", "开启自动贴边"))
                .accessibilityIdentifier("overlay-pin")
                .onboardingHighlight(onboarding.visibleTip == .visibility)
            Button { (NSApp.windows.first(where: { $0 is OverlayWindow }) as? OverlayWindow)?.tuckAway() } label: { Image(systemName: "minus") }
                .help(t("Hide ({shortcut})").replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display))
        }.buttonStyle(.borderless)
    }
    private var transcriptViewportHeight: CGFloat {
        transcriptCollapsed ? NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: transcriptSize)) * 3 + 6 : 90
    }
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !transcript.hasContent {
                            Text(t("Conversation appears here when listening.")).font(.system(size: transcriptSize)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(transcript.lines) { line in
                            transcriptRow(line.content, speaker: line.speaker, translated: translation.text(for: line), partial: false)
                        }
                        if !transcript.partialThem.isEmpty {
                            let speaker: Speaker = coordinator.settings.mode == .inPerson ? .room : .them
                            transcriptRow(transcript.partialThem, speaker: speaker,
                                          translated: translation.previewText(transcript.partialThem, speaker: speaker), partial: true)
                        }
                        if !transcript.partialYou.isEmpty {
                            transcriptRow(transcript.partialYou, speaker: .you,
                                          translated: translation.previewText(transcript.partialYou, speaker: .you), partial: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).id("latest")
                }.frame(height: transcriptViewportHeight)
                    .onAppear { if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcriptCollapsed) { _, _ in if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: followTranscript) { _, value in if transcriptCollapsed || value { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: translation.values) { _, _ in if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcript.lines) { _, _ in if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcript.partialThem) { _, _ in if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: transcript.partialYou) { _, _ in if transcriptCollapsed || followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                if !transcriptCollapsed {
                    Toggle(t("Follow transcript"), isOn: $followTranscript).font(.caption2).toggleStyle(OverlaySwitchStyle()).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
    // Both states use the same rows and columns. Only the scroll viewport height changes.
    private func transcriptRow(_ source: String, speaker: Speaker, translated: String?, partial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            transcriptTextRow(source, label: t(speaker.rawValue), color: speaker == .you ? .blue : .green,
                              textColor: partial ? .secondary : .primary)
            if let translated {
                transcriptTextRow(translated, label: b("Tr.", "译"), color: .blue, textColor: .blue)
            }
        }
    }
    private func transcriptTextRow(_ text: String, label: String, color: Color, textColor: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: max(11, transcriptSize - 1), weight: .bold))
                .foregroundStyle(color).frame(width: speakerWidth, alignment: .leading)
            // ASR fragments retain separator spaces for merging; do not render them as indentation.
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: transcriptSize)).foregroundStyle(textColor)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack {
            Text(t(coordinator.settings.scenario.rawValue)).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(hotkeys.toggleOverlay.display).font(.caption2).foregroundStyle(.tertiary)
                .onboardingHighlight(onboarding.visibleTip == .visibility)
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

private struct OverlayChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
