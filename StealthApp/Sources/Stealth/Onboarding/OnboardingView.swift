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
            movingForward = new.rawValue > old.rawValue
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
          HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: page == .analysis ? 14 : 18) {
                Text(title(page)).font(.system(size: 32, weight: .semibold)).tracking(-0.7)
                    .lineLimit(page == .analysis ? 1 : nil).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboarding-title")
                Text(subtitle(page)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                leftContent(page)
            }.frame(width: 310, alignment: .leading)
            rightContent(page)
                .frame(width: max(0, geometry.size.width - 432), height: max(0, geometry.size.height - 38), alignment: .center)
                .padding(3)
          }.padding(.horizontal, 40).padding(.vertical, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func title(_ page: OnboardingStep) -> String {
        switch page {
        case .language: return b("A little preparation.\nA clearer conversation.", "准备一下，\n从容开口。")
        case .introduction: return b("Stay in the\nconversation.", "专注对话，\n让思路跟上。")
        case .models: return b("Your local\ncapabilities.", "本地能力配置")
        case .analysis: return b("Connect your answer service", "连接你的回答服务")
        case .permissions: return b("Choose what\nLiveCopilot hears.", "选择让助手\n听到什么。")
        case .ready: return b("Your first\nconversation.", "开始你的\n第一次体验。")
        }
    }
    private func subtitle(_ page: OnboardingStep) -> String {
        switch page {
        case .language: return b("Choose your interface language. You can change it anytime in Settings.", "选择界面语言，之后随时可以在设置中更改。")
        case .introduction: return b("Live captions, relevant knowledge, and words you can say aloud. Choose how you want to begin.", "实时看懂对话，查找相关资料，获得可以说出口的回答建议。选择你的使用方式。")
        case .models: return b("Start with the recommended setup for this Mac. Customize only what you need; downloads continue in the background.", "从适合这台 Mac 的推荐方案开始，也可按需自定义。下载会在后台继续。")
        case .analysis: return b("Your chosen AI service generates answers.\nAdd an API key to get started.", "由你选择的AI服务生成回答\n配置API KEY后即可使用")
        case .permissions: return b("Permissions are requested only when you click. Typing a question needs no audio access.", "点击按钮后才会请求系统权限。仅输入问题，无需音频权限。")
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
        case .introduction:
            VStack(spacing: 9) {
                modeOption(b("Remote meeting", "远程会议"), icon: "headphones", selected: !store.state.prefersTyping && coordinator.settings.mode == .remote) {
                    store.state.prefersTyping = false; coordinator.settings.mode = .remote
                }
                modeOption(b("In-person conversation", "现场交流"), icon: "person.2", selected: !store.state.prefersTyping && coordinator.settings.mode == .inPerson) {
                    store.state.prefersTyping = false; coordinator.settings.mode = .inPerson
                }
                modeOption(b("Start by typing", "先输入问题"), icon: "keyboard", selected: store.state.prefersTyping) { store.state.prefersTyping = true }
            }.disabled(locked)
            VStack(alignment: .leading, spacing: 8) {
                Picker(b("Conversation scenario", "使用场景"), selection: $coordinator.settings.scenario) {
                    ForEach(ScenarioProfile.allCases) { scenario in
                        Text(L10n.text(scenario.rawValue, language: coordinator.settings.language)).tag(scenario)
                    }
                }.disabled(locked).accessibilityIdentifier("onboarding-scenario")
                Text(b("Sets the answer style. Choose languages and knowledge needs on the next page.", "决定回答风格，下一页可选择使用语言及知识库需求。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .models:
            OnboardingDetectedModelsView(coordinator: coordinator)
        case .analysis:
            VStack(alignment: .leading, spacing: 12) {
                Label(b("Prioritize response speed in live conversations", "实时场景优先关注响应速度"), systemImage: "bolt")
                Label(b("Low reasoning balances speed and quality", "建议采用Low推理深度取得速度和质量的平衡"), systemImage: "gauge.with.dots.needle.33percent")
                Label(b("Keys stay in this Mac's Keychain", "密钥仅保存在本机 macOS 钥匙串"), systemImage: "lock.shield")
                Label(b("Set up or change your service later", "可以稍后补充或更换配置"), systemImage: "slider.horizontal.3")
            }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            OnboardingAnswerRecommendations(language: coordinator.settings.language)
        case .permissions:
            OnboardingNote(icon: store.state.prefersTyping ? "keyboard" : coordinator.settings.mode == .remote ? "headphones" : "mic",
                           title: store.state.prefersTyping ? b("Typing first", "先输入问题") : L10n.text(coordinator.settings.mode.rawValue, language: coordinator.settings.language),
                           detail: b("Return to the introduction to change this choice. Granting access never starts recording.", "可以返回功能介绍页更改使用方式。授予权限不会开始录音。"))
        case .ready:
            OnboardingNote(icon: "keyboard", title: b("Keep it within reach", "随时唤出助手"),
                           detail: hotkeys.toggleOverlay.display + b(" shows or hides the floating window. ", " 显示或隐藏悬浮窗。") + "\n" + hotkeys.combo(for: .reply).display + b(" generates a reply from the conversation.", " 根据当前对话生成回答。"))
        }
        if locked { Text(b("Stop the current session or indexing before changing setup.", "请先停止当前监听或索引，再更改配置。")).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func rightContent(_ page: OnboardingStep) -> some View {
        switch page {
        case .language:
            VStack(alignment: .center, spacing: 18) {
                Text(coordinator.settings.language.usesChinese ? "你好" : "Hello").font(.system(size: 74, weight: .medium)).tracking(-3)
                Text(b("Welcome to LiveCopilot", "欢迎使用 LiveCopilot")).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 360)
        case .introduction:
            OnboardingConversationPreview(language: coordinator.settings.language, scenario: coordinator.settings.scenario)
                .id(coordinator.settings.scenario.rawValue + coordinator.settings.language.rawValue)
        case .models: OnboardingModelsView(coordinator: coordinator, store: store)
        case .analysis: OnboardingAnalysisView(coordinator: coordinator)
        case .permissions: OnboardingPermissionsView(coordinator: coordinator, store: store, permissions: permissions)
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
                Button(b("Set up later", "稍后设置")) {
                    if step == .analysis { store.state.advance() }
                    else { store.deferSetup(); close() }
                }
                    .buttonStyle(OnboardingQuietButtonStyle(reduceMotion: reduceMotion)).accessibilityIdentifier("onboarding-defer")
            }
            Button(nextTitle) {
                if step == .ready { store.complete(); close() }
                else {
                    if step == .models { OnboardingDownloads.start(coordinator) }
                    store.state.advance()
                }
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(step == .models && !store.state.prefersTyping && coordinator.settings.listeningService == .apple && apple.checkedLanguage != coordinator.settings.appleSpeechLanguage)
                .accessibilityIdentifier("onboarding-next")
        }
    }
    private var nextTitle: String {
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
    private func modeOption(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
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
