import SwiftUI

/// A single native window. Downloads belong to the coordinator, not a page's lifetime.
struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var models: LocalModelManager
    @ObservedObject var apple: AppleSpeechManager
    @ObservedObject var laya: LayaRuntimeManager
    @ObservedObject var hotkeys: HotkeyStore
    @StateObject private var permissions: OnboardingPermissions
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var presentedStep: OnboardingStep
    @State private var movingForward = true
    let close: () -> Void
    let beginListening: () -> Void
    let beginTyping: () -> Void

    init(coordinator: AppCoordinator, close: @escaping () -> Void,
         beginListening: @escaping () -> Void, beginTyping: @escaping () -> Void) {
        self.coordinator = coordinator; store = coordinator.onboarding
        models = coordinator.localModels; apple = coordinator.appleSpeech; laya = coordinator.laya; hotkeys = coordinator.hotkeys
        _permissions = StateObject(wrappedValue: OnboardingPermissions(mock: coordinator.isMock))
        _presentedStep = State(initialValue: coordinator.onboarding.state.step)
        self.close = close; self.beginListening = beginListening; self.beginTyping = beginTyping
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var step: OnboardingStep { store.state.step }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning || coordinator.isIndexing }
    private var reduceMotion: Bool {
        systemReduceMotion || (AppPaths.isOnboardingPreview && ProcessInfo.processInfo.arguments.contains("--onboarding-reduce-motion"))
    }
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: movingForward ? 30 : -30)),
                           removal: .opacity.combined(with: .offset(x: movingForward ? -20 : 20)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AppBrandTitle(iconSize: 28, titleSize: 19)
                Spacer()
                if coordinator.isMock { Text(b("PREVIEW · no recording or API calls", "预览 · 不录音，不调用 API")).font(.caption).foregroundStyle(.secondary) }
                else if models.downloading != nil || apple.busy || laya.isBusy {
                    Button { store.state.step = .models } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(b("Preparing models · view progress", "正在准备模型 · 查看进度")).font(.caption)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("onboarding-download-status")
                }
            }.padding(.horizontal, 36).padding(.top, 28)
            ZStack {
                ForEach(OnboardingStep.allCases) { page in
                    if page == presentedStep {
                        pageContent(page)
                            .transition(pageTransition)
                            .allowsHitTesting(page == step)
                            .accessibilityHidden(page != step)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            footer.padding(.horizontal, 36).padding(.bottom, 26)
        }
        .frame(minWidth: 1040, idealWidth: 1040, minHeight: 660, idealHeight: 668)
        .background { OnboardingAtmosphere(step: step, reduceMotion: reduceMotion) }
        .toggleStyle(TrailingSwitchStyle())
        .environment(\.locale, coordinator.settings.language.locale)
        .onChange(of: step) { old, new in
            movingForward = new.position > old.position
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.38).speed(OnboardingMotion.speed)) { presentedStep = new }
        }
        .task(id: coordinator.settings.appleSpeechLanguage) { await apple.refresh(coordinator.settings.appleSpeechLanguage) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(); models.refresh()
            Task { await apple.refresh(coordinator.settings.appleSpeechLanguage) }
        }
    }
    private func pageContent(_ page: OnboardingStep) -> some View {
        GeometryReader { geometry in
          HStack(alignment: page == .introduction ? .top : .center, spacing: 36) {
            VStack(alignment: .leading, spacing: page == .workflow ? 10 : page == .analysis ? 14 : 18) {
                if page == .workflow { Spacer(minLength: 20).frame(maxHeight: 40) }
                Text(title(page)).font(.system(size: page == .workflow ? 28 : 32, weight: .semibold)).tracking(-0.7)
                    .lineLimit(page == .analysis ? 1 : nil).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboarding-title")
                Text(subtitle(page)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                leftContent(page)
            }.frame(width: 310, alignment: .leading)
                .frame(maxHeight: page == .workflow ? .infinity : nil, alignment: .top)
            rightContent(page)
                .frame(maxWidth: page == .workflow ? 500 : .infinity)
                .frame(width: max(0, geometry.size.width - 432), alignment: .top)
                .frame(maxHeight: page == .introduction ? nil : .infinity, alignment: .center)
                .padding(page == .workflow ? 0 : 3)
          }.padding(.bottom, page == .workflow ? 30 : 0).padding(.horizontal, 40).padding(.vertical, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func title(_ page: OnboardingStep) -> String {
        switch page {
        case .language: return b("A little preparation.\nA clearer conversation.", "准备一下，\n从容开口。")
        case .workflow: return b("From hearing a question\nto a ready reply.", "从听见问题，\n到准备好回答。")
        case .introduction: return b("Choose your input", "使用方式与权限")
        case .models: return b("Your local\ncapabilities.", "本地能力配置")
        case .analysis: return b("Connect your answer service", "连接你的回答服务")
        case .ready: return b("Your first\nconversation.", "开始你的\n第一次体验。")
        }
    }
    private func subtitle(_ page: OnboardingStep) -> String {
        switch page {
        case .language: return b("Choose your interface language. You can change it anytime in Settings.", "选择界面语言，之后随时可以在设置中更改。")
        case .workflow: return b("Follow the conversation in real time and use your materials to prepare a grounded answer in your own words.", "实时理解对话，结合你的资料，提供有依据、可以直接使用的回答建议。")
        case .introduction: return b("Choose where your questions will come from and the context for your answers.", "选择对话从哪里来，以及你希望在哪种场景下使用回答建议。")
        case .models: return b("Start with the recommended setup for this Mac. Customize only what you need; downloads continue in the background.", "从适合这台 Mac 的推荐方案开始，也可按需自定义。下载会在后台继续。")
        case .analysis: return b("Your chosen AI service generates answers.\nAdd an API key to get started.", "回答由你选择的 AI 服务生成。配置 API Key 即可开始，也可以稍后设置。")
        case .ready: return b("Review your setup, then try a question below. You can return to this guide from Settings.", "查看当前准备情况，在下方试问一句。以后也可以从设置重新打开引导。")
        }
    }
    @ViewBuilder private func leftContent(_ page: OnboardingStep) -> some View {
        switch page {
        case .language:
            VStack(spacing: 9) {
                languageOption(.system, b("Follow system", "跟随系统"))
                languageOption(.simplifiedChinese, "简体中文")
                languageOption(.traditionalChinese, "繁體中文")
                languageOption(.english, "English")
            }
        case .workflow:
            VStack(alignment: .leading, spacing: 18) {
                workflowItem("waveform", b("Live transcription", "实时转写"), b("Turn microphone or system audio into text.", "将麦克风或系统音频中的对话转为文字。"))
                workflowItem("bolt", "Jev Mode", b("Detect complete questions and trigger suggestions.", "自动识别完整提问，在合适时机触发回答建议。"))
                    .saturation(coordinator.settings.automaticSuggestions ? 1 : 0)
                    .opacity(coordinator.settings.automaticSuggestions ? 1 : 0.72)
                workflowItem("books.vertical", b("Personal knowledge base", "个人知识库"), b("Find evidence in your files, or answer without them.", "检索资料提供依据；没有资料也可以直接回答。"))
                workflowItem("text.bubble", b("Answer suggestions", "回答建议"), b("Prepare a clear, natural reply using context and sources.", "结合上下文和资料，生成自然、清晰的回答。"))
            }
            Spacer(minLength: 12)
            JevModeCard(isOn: $coordinator.settings.automaticSuggestions, language: coordinator.settings.language,
                        identifier: "onboarding-jev")
                .disabled(locked || (coordinator.settings.listeningService.isLocal && laya.state == .unsupported))
        case .introduction:
            VStack(spacing: 9) {
                modeOption(b("Remote meeting", "远程会议"), detail: b("System audio and optional microphone", "系统音频，可同时使用麦克风"), icon: "headphones", selected: !store.state.prefersTyping && coordinator.settings.mode == .remote) {
                    store.state.prefersTyping = false; coordinator.settings.mode = .remote
                }
                modeOption(b("In-person conversation", "现场交流"), detail: b("Room microphone", "主要使用麦克风"), icon: "person.2", selected: !store.state.prefersTyping && coordinator.settings.mode == .inPerson) {
                    store.state.prefersTyping = false; coordinator.settings.mode = .inPerson
                }
                modeOption(b("Manual input", "手动输入"), detail: b("Type a question directly", "直接输入问题"), icon: "keyboard", selected: store.state.prefersTyping) { store.state.prefersTyping = true }
            }.disabled(locked)
            VStack(alignment: .leading, spacing: 8) {
                Picker(b("Conversation scenario", "使用场景"), selection: $coordinator.settings.scenario) {
                    ForEach(ScenarioProfile.allCases) { scenario in
                        Text(L10n.text(scenario.rawValue, language: coordinator.settings.language)).tag(scenario)
                    }
                }.disabled(locked).accessibilityIdentifier("onboarding-scenario")
                Text(coordinator.settings.automaticSuggestions
                     ? b("Jev Mode is on. When listening, complete questions can trigger suggestions.", "已开启 Jev Mode，监听时检测到完整提问可自动生成建议。")
                     : b("Jev Mode is off. You can still ask manually.", "未开启 Jev Mode，你仍然可以手动提问。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .models:
            OnboardingDetectedModelsView(coordinator: coordinator)
        case .analysis:
            OnboardingAnswerRecommendations(language: coordinator.settings.language)
        case .ready:
            OnboardingNote(icon: "keyboard", title: b("Keep it within reach", "随时唤出助手"),
                           detail: hotkeys.toggleOverlay.display + b(" shows or hides the floating window. ", " 显示或隐藏悬浮窗。") + "\n" + hotkeys.combo(for: .reply).display + b(" generates a reply from the conversation.", " 根据当前对话生成回答。"))
        }
        if locked { Text(b("Stop the current session or indexing before changing setup.", "请先停止当前监听或索引，再更改配置。")).font(.caption).foregroundStyle(.secondary) }
    }
    private func workflowItem(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                if title == "Jev Mode" {
                    HStack(spacing: 7) {
                        Text(b("Question recognition", "自动识别提问")).font(.system(size: 13, weight: .semibold))
                        Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func rightContent(_ page: OnboardingStep) -> some View {
        switch page {
        case .language:
            VStack(alignment: .center, spacing: 18) {
                Text(coordinator.settings.language.usesChinese ? "你好" : "Hello").font(.system(size: 74, weight: .medium)).tracking(-3)
                Text(b("Welcome to LiveCopilot", "欢迎使用 LiveCopilot")).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 360)
        case .workflow:
            OnboardingWorkflowDemo(language: coordinator.settings.language, automatic: $coordinator.settings.automaticSuggestions,
                                   editable: OnboardingRecommendation.canEdit(coordinator) && !(coordinator.settings.listeningService.isLocal && laya.state == .unsupported),
                                   reduceMotion: reduceMotion)
                .onAppear { store.state.jevChoiceReviewed = true }
        case .introduction:
                VStack(alignment: .leading, spacing: 12) {
                    OnboardingModePreview(language: coordinator.settings.language, typing: store.state.prefersTyping,
                                          remote: coordinator.settings.mode == .remote, microphone: coordinator.micEnabled)
                    OnboardingPermissionsView(coordinator: coordinator, store: store, permissions: permissions)
                }.padding(3)
        case .models: OnboardingModelsView(coordinator: coordinator, store: store)
        case .analysis: OnboardingAnalysisView(coordinator: coordinator)
        case .ready: OnboardingReadyView(coordinator: coordinator, store: store, permissions: permissions,
                                        beginListening: beginListening, beginTyping: beginTyping)
        }
    }
    private var footer: some View {
        HStack(spacing: 14) {
            Button(b("Back", "返回")) { store.state.back() }
                .disabled(step == .language).accessibilityIdentifier("onboarding-back")
            OnboardingStepProgress(step: step, language: coordinator.settings.language, reduceMotion: reduceMotion)
                .padding(.leading, 6)
            Spacer(minLength: 16)
            if step == .models {
                Button(b("Use available capabilities", "先用现有能力")) { OnboardingDownloads.skip(coordinator) }
                    .buttonStyle(OnboardingQuietButtonStyle(reduceMotion: reduceMotion)).accessibilityIdentifier("onboarding-skip-download")
            } else {
                Button(step == .analysis ? b("Test later", "稍后测试") : b("Set up later", "稍后设置")) {
                    if step == .analysis { store.state.advance() }
                    else { store.deferSetup(); close() }
                }
                    .buttonStyle(OnboardingQuietButtonStyle(reduceMotion: reduceMotion)).accessibilityIdentifier("onboarding-defer")
            }
            Button(nextTitle) {
                if step == .analysis && !coordinator.isAnalysisConnectionVerified {
                    if coordinator.hasAnswerCredential && (try? coordinator.settings.analysisCredentialReference()) != nil {
                        Task { try? await coordinator.testAnalysisConnection() }
                    } else {
                        NotificationCenter.default.post(name: .onboardingFocusCredential, object: nil)
                    }
                } else if step == .ready { store.complete(); close() }
                else {
                    if step == .models { OnboardingDownloads.start(coordinator) }
                    store.state.advance()
                }
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled((step == .analysis && (coordinator.testingAnalysisConnection || locked)) || step == .models && !store.state.prefersTyping && coordinator.settings.listeningService == .apple && apple.checkedLanguage != coordinator.settings.appleSpeechLanguage)
                .accessibilityIdentifier("onboarding-next")
        }
    }
    private var nextTitle: String {
        if step == .analysis {
            if coordinator.testingAnalysisConnection { return b("Testing connection…", "正在测试连接…") }
            if (try? coordinator.settings.analysisCredentialReference()) == nil { return b("Configure service address", "配置服务地址") }
            if !coordinator.hasAnswerCredential { return b("Configure API Key", "配置 API Key") }
            if !coordinator.isAnalysisConnectionVerified {
                return coordinator.analysisConnectionFailure == nil ? b("Test connection", "测试连接") : b("Retry test", "重新测试")
            }
        }
        if step == .ready { return b("Enter LiveCopilot", "进入 LiveCopilot") }
        if step == .models && !locked && OnboardingDownloads.requiresDownload(coordinator) {
            return OnboardingRecommendation.current(coordinator).matches(coordinator)
                ? b("Download recommended setup & continue", "下载推荐配置并继续")
                : b("Download selected setup & continue", "下载所选配置并继续")
        }
        return b("Continue", "继续")
    }
    private func languageOption(_ language: AppLanguage, _ title: String) -> some View {
        modeOption(title, icon: "globe", selected: coordinator.settings.language == language) { coordinator.settings.language = language }
            .accessibilityIdentifier("onboarding-language-" + language.rawValue)
    }
    private func modeOption(_ title: String, detail: String? = nil, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }.padding(13).background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? b("Selected", "已选") : b("Not selected", "未选"))
    }
}

struct OnboardingNote: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}
