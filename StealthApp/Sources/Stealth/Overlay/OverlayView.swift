import SwiftUI

/// Reference box for window-sizing metrics that must NOT trigger SwiftUI body invalidation.
private final class OverlayLayoutMetrics {
    var chromeHeight: CGFloat = 368
    var answerContentHeight: CGFloat = 56
    private var transcriptScrollWork: DispatchWorkItem?
    private var lastTranscriptScrollAt: TimeInterval = 0

    func scheduleTranscriptScroll(proxy: ScrollViewProxy) {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0.016, 0.1 - (now - lastTranscriptScrollAt))
        guard transcriptScrollWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transcriptScrollWork = nil
            self.lastTranscriptScrollAt = ProcessInfo.processInfo.systemUptime
            proxy.scrollTo("latest", anchor: .bottom)
        }
        transcriptScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelTranscriptScroll() {
        transcriptScrollWork?.cancel()
        transcriptScrollWork = nil
    }
}

struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var translation: TranscriptTranslationStore
    @State private var showTranslation = false
    @State private var translationTarget: TranscriptTranslationStore.Language = .simplified
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var hotkeys: HotkeyStore
    @ObservedObject var onboarding: OnboardingStore
    @State private var query = ""
    @FocusState private var composerFocused: Bool
    /// Natural height of the typed text. Driven through state so the input box grows and shrinks with an animation.
    @State private var composerTextHeight: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followTranscript = true
    @AppStorage("overlayTranscriptCollapsed") private var transcriptCollapsed = false
    @AppStorage("overlayAnswerOnly") private var answerOnly = false
    @State private var layoutMetrics = OverlayLayoutMetrics()
    var demonstrationAnswer: AppCoordinator.AnswerRecord?
    var onContentHeight: (CGFloat) -> Void
    var onMinimumHeight: (CGFloat) -> Void
    init(coordinator: AppCoordinator, demonstrationAnswer: AppCoordinator.AnswerRecord? = nil, transcriptPreferences: UserDefaults = .standard, onContentHeight: @escaping (CGFloat) -> Void = { _ in }, onMinimumHeight: @escaping (CGFloat) -> Void = { _ in }) {
        _transcriptCollapsed = AppStorage(wrappedValue: false, "overlayTranscriptCollapsed", store: transcriptPreferences)
        _answerOnly = AppStorage(wrappedValue: false, "overlayAnswerOnly", store: transcriptPreferences)
        self.demonstrationAnswer = demonstrationAnswer
        self.coordinator = coordinator; translation = coordinator.translation; transcript = coordinator.transcript; hotkeys = coordinator.hotkeys
        onboarding = coordinator.onboarding
        self.onContentHeight = onContentHeight; self.onMinimumHeight = onMinimumHeight
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    private var transcriptSize: CGFloat { OverlayTypography.clamped(coordinator.settings.transcriptFontSize, fallback: 12) }
    private var answerSize: CGFloat { OverlayTypography.clamped(coordinator.settings.answerFontSize, fallback: 14) }
    private var speakerWidth: CGFloat { max(36, transcriptSize * 3.2) } // fits "Them" in its pill at every text size
    private func reportSize() {
        // Only the answer viewport grows. The voice area and composer keep
        // their position relative to the window's stable top edge.
        let fixedHeight = layoutMetrics.chromeHeight + 10 + 28 // inter-pane spacing and outer padding
        // Enough for the empty state or two lines of an answer, so live controls can never
        // squeeze the answers out of view.
        let minimumAnswer: CGFloat = 92
        onMinimumHeight(fixedHeight + minimumAnswer)
        onContentHeight(fixedHeight + max(minimumAnswer, layoutMetrics.answerContentHeight))
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if !answerOnly { voiceSection }
                    actions.frame(height: 28)
                    if demonstrationAnswer == nil { bottom }
                    Divider()
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { measured in
                    Color.clear.preference(key: OverlayChromeHeightKey.self, value: measured.size.height)
                })
                if let record = demonstrationAnswer {
                    AnswerMessageView(record: record, store: record.store, language: coordinator.settings.language, fontSize: answerSize)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                ConversationFlowView(coordinator: coordinator, fontSize: answerSize, onContentHeight: { height in
                    let clamped = min(height, 1200)
                    guard clamped.isFinite, clamped > 0, abs(clamped - layoutMetrics.answerContentHeight) > 0.5 else { return }
                    layoutMetrics.answerContentHeight = clamped
                    reportSize()
                })
                .frame(maxHeight: .infinity)
                }

            }
            .padding(14)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background { WindowBackgroundView(style: coordinator.settings.background, isOverlay: true) }
        .clipShape(RoundedRectangle(cornerRadius: LC.Radius.panel))
        .preferredColorScheme(coordinator.settings.background.usesLightAppearance ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .overlay(RoundedRectangle(cornerRadius: LC.Radius.panel).strokeBorder(.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .onChange(of: coordinator.conversationGeneration) { _, _ in
            query = ""; followTranscript = true
            reportSize()
        }
        .onPreferenceChange(OverlayChromeHeightKey.self) { height in
            guard height > 0, abs(height - layoutMetrics.chromeHeight) > 0.5 else { return }
            layoutMetrics.chromeHeight = height
            reportSize()
        }
        .onAppear {
            #if DEBUG
            if demonstrationAnswer == nil, let fixture = UIFixture.query { query = fixture }
            #endif
            reportSize()
        }
        .onDisappear { layoutMetrics.cancelTranscriptScroll() }
    }
    @ViewBuilder private var voiceSection: some View {
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
            Text(b("Translation failed. Reopen Translation to retry; original text is retained.", "翻译失败，请重新开启翻译重试；原文已保留。")).font(.caption2).foregroundStyle(LC.warning)
        }
        transcriptView
        Divider()
    }
    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.trailing, 16)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                LCStatusDot(tone: statusTone, pulsing: coordinator.isRunning && !speechFailed, size: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                // One line while listening so the row never wraps; the full text stays in the tooltip.
                JevBrand.text(statusLine, size: 11).font(.caption)
                    .foregroundStyle(speechFailed ? LC.danger : Color.secondary)
                    .lineLimit(coordinator.isRunning ? 1 : 2).truncationMode(.tail).textSelection(.enabled)
                    .help(statusLine)
                Spacer(minLength: 8)
                if coordinator.isRunning && coordinator.settings.listeningService == .apple {
                    // The single-language note lives behind an icon so listening adds no row.
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(t("Apple ASR uses one language. For mixed Chinese/English, select another speech recognition engine in Services."))
                        .accessibilityLabel(t("Apple ASR uses one language. For mixed Chinese/English, select another speech recognition engine in Services."))
                        .accessibilityIdentifier("apple-speech-note")
                        .transition(.opacity)
                }
                if coordinator.isRunning {
                    LiveLevelsView(levels: coordinator.levels, mode: coordinator.settings.mode,
                                   micEnabled: coordinator.micEnabled, language: coordinator.settings.language)
                        .transition(.opacity)
                }
                footer.fixedSize()
            }
            .lcAnimation(LC.Motion.quick, value: coordinator.isRunning)
            if coordinator.isRunning, let notice = coordinator.captureNotice {
                Label(t(notice), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(LC.warning).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .lcCallout(.warning, padding: 8)
                    .accessibilityIdentifier("capture-notice")
            }
        }
    }
    /// Status text, plus the automatic-answer trigger only when it says something the rest of the
    /// window does not: still loading, unavailable, or working on a question it heard.
    private var statusLine: String {
        let status = t(coordinator.statusMessage)
        guard coordinator.isRunning, coordinator.settings.automaticSuggestions, coordinator.settings.listeningService.isLocal,
              // Only lasting states: "understanding" and "preparing" switch on every partial transcript and flicker.
              [.loading, .unavailable].contains(coordinator.layaGateStatus)
        else { return status }
        return status + " · " + coordinator.layaGateStatus.label(coordinator.settings.language)
    }
    @ViewBuilder private var actions: some View {
        if answerOnly {
            ViewThatFits(in: .horizontal) {
                actionRow(.titleAndIcon)
                actionRow(.titleOnly)
                actionRow(.titleOnly, compactToggle: true)
                actionRow(.iconOnly, compactToggle: true)
            }
            // Outer padding supplies another 14 pt of clearance from the resize corner.
            .padding(.trailing, OverlayResizeView.corner / 2)
        } else {
            ViewThatFits(in: .horizontal) {
                actionRow(.titleAndIcon)
                actionRow(.titleOnly)
                actionRow(.iconOnly)
            }
        }
    }

    private func actionRow<Style: LabelStyle>(_ style: Style, compactToggle: Bool = false) -> some View {
        HStack(spacing: 6) {
            ForEach(coordinator.settings.enabledSuggestionModes) { mode in
                Button { coordinator.requestSuggestion(mode: mode) } label: {
                    Label(t(mode.label), systemImage: mode.systemImage).font(.caption.weight(.medium)).labelStyle(style)
                        .padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(mode == .reply ? LC.accent : Color.primary)
                        .background(mode == .reply ? LC.accent.opacity(0.12) : LC.fill, in: Capsule())
                        .overlay(Capsule().strokeBorder(mode == .reply ? LC.accent.opacity(0.22) : LC.hairline))
                        .contentShape(Capsule())
                        .lcHoverable(radius: 13)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(t(mode.label) + " · " + hotkeys.combo(for: mode).display)
                .accessibilityIdentifier("action-" + mode.rawValue)
                .onboardingHighlight(onboarding.visibleTip == .answer && mode == .reply)
            }
            if answerOnly {
                // Answers-only mode has no header or status row: listening and the live
                // meters ride along in this row.
                listenButton.padding(.leading, 2)
                if coordinator.isRunning {
                    LiveLevelsView(levels: coordinator.levels, mode: coordinator.settings.mode,
                                   micEnabled: coordinator.micEnabled, language: coordinator.settings.language)
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
                Spacer(minLength: 4).overlay { OverlayDragRegion() }
                layoutToggle(iconOnly: compactToggle).fixedSize()
                hideButton.buttonStyle(LCIconButtonStyle(size: 24)).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 4)
                // Always present so the row does not shift when listening starts or stops.
                Toggle(t("Auto"), isOn: $coordinator.settings.automaticSuggestions)
                    .font(.caption2).toggleStyle(OverlaySwitchStyle())
                    .help(b("Suggest answers automatically while listening", "监听时自动生成回答建议"))
                    .accessibilityIdentifier("automatic-suggestions")
                    .fixedSize().padding(.trailing, 4)
                knowledgeModeMenu
            }
        }
        .lcAnimation(LC.Motion.quick, value: coordinator.isRunning)
    }
    private var knowledgeModeMenu: some View {
        Menu {
            Picker(t("Knowledge mode"), selection: $coordinator.settings.knowledgeMode) {
                ForEach(KnowledgeMode.allCases) { mode in Text(t(mode.label)).tag(mode) }
            }.pickerStyle(.inline)
        } label: {
            Label(t(coordinator.settings.knowledgeMode.compactLabel), systemImage: "books.vertical")
                .font(.caption)
        }.fixedSize().help(t(coordinator.settings.knowledgeMode.label))
            .accessibilityIdentifier("knowledge-mode")
    }
    private var answerLanguageMenu: some View {
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
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Side controls stay level with the input's last line as it grows.
            HStack(alignment: .bottom, spacing: 8) {
                composer
                answerLanguageMenu.frame(height: 34)
            }
        }
    }
    private func submit() { let value = query; query = ""; coordinator.askText(value) }
    private var canAsk: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// AI input bar: sparkle, plain field and a round send button inside a soft brand-gradient outline.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(LC.accent)
                .frame(height: 22)
                .accessibilityHidden(true)
            // Grows to six lines, then scrolls. The field keeps its natural height and is measured;
            // the visible frame follows that measurement with a spring.
            TextField(t("Ask anything — listening can be off"), text: $query, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit { submit() }.accessibilityIdentifier("manual-query")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ComposerTextHeightKey.self, value: proxy.size.height)
                })
                .frame(height: composerTextHeight, alignment: .top)
                .clipped()
                .padding(.vertical, 3)
                .onPreferenceChange(ComposerTextHeightKey.self) { height in
                    guard height > 0, abs(height - composerTextHeight) > 0.5 else { return }
                    withAnimation(reduceMotion ? nil : LC.Motion.standard) { composerTextHeight = height }
                }
            if canAsk {
                Text("↩").font(LC.Typo.micro).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(LC.fillSubtle, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(height: 22)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            conversationContextMenu
            sendButton
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(LinearGradient(colors: [LC.accent.opacity(composerFocused ? 0.85 : 0.5), LC.accentPink.opacity(composerFocused ? 0.75 : 0.4)],
                                         startPoint: .leading, endPoint: .trailing), lineWidth: composerFocused ? 1.5 : 1))
        // Focus glow in the brand colors; nothing animates while the field is idle.
        .shadow(color: LC.accent.opacity(composerFocused ? 0.22 : 0), radius: 8, y: 1)
        .lcAnimation(LC.Motion.quick, value: composerFocused)
        .lcAnimation(LC.Motion.quick, value: canAsk)
        .lcAnimation(LC.Motion.quick, value: coordinator.answerIsRunning)
        .onboardingHighlight(onboarding.visibleTip == .start && onboarding.state.prefersTyping)
    }
    /// Send, or Stop while an answer is being written. Return still submits a new question.
    private var sendButton: some View {
        let stopping = coordinator.answerIsRunning
        let fill: AnyShapeStyle = stopping ? AnyShapeStyle(Color.secondary.opacity(0.6))
            : canAsk ? AnyShapeStyle(LC.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.35))
        return Button { stopping ? coordinator.cancelAnswer() : submit() } label: {
            Image(systemName: stopping ? "stop.fill" : "arrow.up")
                .font(.system(size: stopping ? 9 : 11, weight: .bold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain).disabled(!stopping && !canAsk)
        .help(stopping ? b("Stop generating", "停止生成") : t("Ask"))
        .accessibilityLabel(stopping ? b("Stop generating", "停止生成") : t("Ask"))
        .accessibilityIdentifier("manual-query-submit")
    }
    /// Whether a typed question carries the recent conversation. Text-filled bubbles mean the
    /// conversation is attached; empty bubbles mean the question goes on its own.
    private var conversationContextMenu: some View {
        let included = coordinator.settings.includeConversation
        return Menu {
            Picker(b("Typed questions", "手动提问"), selection: $coordinator.settings.includeConversation) {
                Label(t("Use recent conversation"), systemImage: "bubble.left.and.text.bubble.right").tag(true)
                Label(b("Question only", "仅发送问题"), systemImage: "bubble.left.and.bubble.right").tag(false)
            }.pickerStyle(.inline)
        } label: {
            Image(systemName: included ? "bubble.left.and.text.bubble.right" : "bubble.left.and.bubble.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(included ? LC.accent : Color.secondary)
                .frame(width: 26, height: 22)
                .background(included ? LC.accent.opacity(0.12) : LC.fillSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(included ? t("Use recent conversation") : b("Question only — the conversation is not sent", "仅发送问题，不附带对话"))
        .accessibilityLabel(b("Conversation context", "对话上下文"))
        .accessibilityValue(included ? t("Use recent conversation") : b("Question only", "仅发送问题"))
        .accessibilityIdentifier("conversation-context")
        .lcAnimation(LC.Motion.quick, value: included)
    }
    private var speechFailed: Bool { coordinator.speechRuntime == .failed && !coordinator.isRunning }
    private var statusTone: LC.Tone {
        if speechFailed { return .danger }
        if coordinator.isTransitioning { return .warning }
        return coordinator.isRunning ? .success : .neutral
    }
    private var layoutToggle: some View { layoutToggle(iconOnly: false) }
    private func layoutToggle(iconOnly: Bool) -> some View {
        let label = answerOnly ? b("Show full view", "恢复完整模式") : b("Show answers only", "切换到精简模式")
        return Button {
            showTranslation = false
            answerOnly.toggle()
        } label: {
            if answerOnly && iconOnly {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            } else if answerOnly {
                Label(b("Full view", "完整模式"), systemImage: "rectangle.topthird.inset.filled")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "rectangle.compress.vertical")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("overlay-layout-toggle")
    }

    private var listenButton: some View {
        Button { Task { await coordinator.toggle() } } label: {
            HStack(spacing: 4) {
                if coordinator.isTransitioning {
                    // Cold audio devices can take several seconds to start; keep the wait visible.
                    LCSpinner(size: 9, color: coordinator.isRunning ? LC.danger : .white)
                    Text(coordinator.isRunning ? b("Stopping", "停止中") : b("Starting", "启动中")).font(.caption.weight(.semibold))
                } else {
                    Image(systemName: coordinator.isRunning ? "stop.fill" : "play.fill").font(.system(size: 8, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(coordinator.isRunning ? b("Stop", "停止") : b("Listen", "监听")).font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(coordinator.isRunning ? LC.danger : Color.white)
            .background {
                if coordinator.isRunning { Capsule().fill(LC.danger.opacity(0.13)) }
                else { Capsule().fill(LC.brandGradient).shadow(color: LC.accent.opacity(0.3), radius: 4, y: 1) }
            }
            .contentShape(Capsule())
            .lcAnimation(LC.Motion.standard, value: coordinator.isRunning)
            .lcAnimation(LC.Motion.quick, value: coordinator.isTransitioning)
        }.buttonStyle(.plain).fixedSize()
            // Not .disabled: the dimmed style would hide the start-up spinner. Taps are ignored instead.
            .allowsHitTesting(!coordinator.isTransitioning)
            .accessibilityAddTraits(coordinator.isTransitioning ? .updatesFrequently : [])
            .help(t(coordinator.isRunning ? "Stop listening" : "Start listening"))
            .accessibilityIdentifier("overlay-toggle-listening")
            .onboardingHighlight(onboarding.visibleTip == .start && !onboarding.state.prefersTyping)
    }
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                AppBrandTitle(iconSize: 22)
                if coordinator.isMock && demonstrationAnswer == nil { LCPill(text: t("MOCK"), tone: .warning) }
                Spacer(minLength: 0)
            }.overlay { OverlayDragRegion() }
                .help(b("Turn off automatic docking to drag this header anywhere.", "关闭自动贴边后，可拖动这里自由移动窗口。"))
            listenButton
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
                    .foregroundStyle(coordinator.settings.overlayEdgeHide ? Color.secondary : LC.accent)
            }.help(coordinator.settings.overlayEdgeHide
                   ? b("Turn off automatic docking · drag freely", "关闭自动贴边 · 自由拖动")
                   : b("Turn on automatic docking", "开启自动贴边"))
                .accessibilityIdentifier("overlay-pin")
                .onboardingHighlight(onboarding.visibleTip == .visibility)
            layoutToggle
            hideButton
        }.buttonStyle(LCIconButtonStyle(size: 24)).foregroundStyle(.secondary)
    }
    private var hideButton: some View {
        Button { (NSApp.windows.first(where: { $0 is OverlayWindow }) as? OverlayWindow)?.tuckAway() } label: { Image(systemName: "minus") }
            .help(t("Hide ({shortcut})").replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display))
            .accessibilityIdentifier("overlay-hide")
    }
    private var transcriptViewportHeight: CGFloat {
        if demonstrationAnswer != nil { return 60 }
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: transcriptSize))
        // Collapsed shows the latest two rows; expanded shows the number chosen in Settings.
        let rows = CGFloat(transcriptCollapsed ? 2 : coordinator.settings.transcriptExpandedLines)
        return line * rows + (rows - 1) * 6 + 4
    }
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                LCScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !transcript.hasContent {
                            Text(coordinator.isRunning ? b("Listening — the conversation appears here.", "正在聆听，对话会显示在这里。")
                                                       : t("Conversation appears here when listening.")).font(.system(size: transcriptSize)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(transcript.lines) { line in
                            transcriptRow(line.content, speaker: line.speaker, translated: translation.text(for: line), partial: false)
                                .transition(.opacity)
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
                    .lcAnimation(.easeOut(duration: 0.2), value: transcript.lines.count)
                }.frame(height: transcriptViewportHeight)
                    .onAppear { if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: transcriptCollapsed) { _, _ in if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: followTranscript) { _, value in if transcriptCollapsed || value { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: translation.values) { _, _ in if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: transcript.lines) { _, _ in if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: transcript.partialThem) { _, _ in if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                    .onChange(of: transcript.partialYou) { _, _ in if transcriptCollapsed || followTranscript { layoutMetrics.scheduleTranscriptScroll(proxy: proxy) } }
                if !transcriptCollapsed && demonstrationAnswer == nil {
                    Toggle(t("Follow transcript"), isOn: $followTranscript).font(.caption2).toggleStyle(OverlaySwitchStyle()).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
    // Both states use the same rows and columns. Only the scroll viewport height changes.
    private func transcriptRow(_ source: String, speaker: Speaker, translated: String?, partial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            transcriptTextRow(source, label: t(speaker.rawValue), color: speaker == .you ? LC.accent : LC.accentPink,
                              textColor: partial ? .secondary : .primary, selectable: !partial)
            if let translated {
                transcriptTextRow(translated, label: b("Tr.", "译"), color: LC.accent, textColor: LC.accent, selectable: !partial)
            }
        }
    }
    private func transcriptTextRow(_ text: String, label: String, color: Color, textColor: Color, selectable: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: max(10, transcriptSize - 2), weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize()
                .frame(minWidth: speakerWidth, alignment: .leading)
            // ASR fragments retain separator spaces for merging; do not render them as indentation.
            if selectable {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: transcriptSize)).foregroundStyle(textColor)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Volatile partial rows mutate many times per second; skipping SelectionOverlay
                // avoids rebuilding NSAttributedString/NSParagraphStyle on every partial frame.
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: transcriptSize)).foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Label(t(coordinator.settings.scenario.rawValue), systemImage: "theatermasks").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(hotkeys.toggleOverlay.display).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(LC.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                    .fill(configuration.isOn ? LC.accent : Color.primary.opacity(0.18))
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

private struct ComposerTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct OverlayChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


/// Live input meters in the status row: You and Them in Remote Meeting, the room in person.
private struct LiveLevelsView: View {
    @ObservedObject var levels: AudioLevelStore
    let mode: OperatingMode
    let micEnabled: Bool
    let language: AppLanguage
    var body: some View {
        HStack(spacing: 10) {
            if mode == .remote {
                meter(ServiceGuide.text("You", "我", language), level: micEnabled ? levels.you : 0, tone: .accent)
                meter(ServiceGuide.text("Them", "对方", language), level: levels.them, tone: .pink)
            } else {
                meter(ServiceGuide.text("Room", "现场", language), level: levels.you, tone: .pink)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
    private func meter(_ title: String, level: Double, tone: LC.Tone) -> some View {
        HStack(spacing: 4) {
            Text(title).font(LC.Typo.micro).foregroundStyle(.secondary)
            LCLevelBars(level: level, tone: tone)
        }
    }
}
