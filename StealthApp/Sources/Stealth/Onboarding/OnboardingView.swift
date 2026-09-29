import SwiftUI

/// A single native window. Downloads belong to the coordinator, not a page's lifetime.
struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var models: LocalModelManager
    @ObservedObject var apple: AppleSpeechManager
    @ObservedObject var laya: LayaRuntimeManager
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
        models = coordinator.localModels; apple = coordinator.appleSpeech; laya = coordinator.laya
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
            VStack(alignment: .leading, spacing: 18) {
                Text(title(page)).font(.system(size: 32, weight: .semibold)).tracking(-0.7)
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
        case .models: return b("Make this Mac\nyour copilot.", "让这台 Mac\n成为你的助手。")
        case .analysis: return b("Connect your\nanswer service.", "连接你的\n回答服务。")
        case .permissions: return b("Choose what\nLiveCopilot hears.", "选择让助手\n听到什么。")
        case .ready: return b("Your first\nconversation.", "开始你的\n第一次体验。")
        }
    }
    private func subtitle(_ page: OnboardingStep) -> String {
        switch page {
        case .language: return b("Choose your interface language. You can change it anytime in Settings.", "选择界面语言，之后随时可以在设置中更改。")
        case .introduction: return b("Live captions, relevant knowledge, and words you can say aloud. Choose how you want to begin.", "实时看懂对话，查找相关资料，获得可以说出口的回答建议。选择你的使用方式。")
        case .models: return b("Enable the capabilities you need. Downloads can continue while you finish setting up.", "按需准备本地能力。开始下载后，可以继续完成后面的设置。")
        case .analysis: return b("Your chosen service generates answers. A saved key and a successful connection test are separate checks.", "由你选择的 AI 服务生成回答。保存密钥后，可以主动测试连接。")
        case .permissions: return b("Permissions are requested only when you click. Typing a question needs no audio access.", "点击按钮后才会请求系统权限。仅输入问题，无需音频权限。")
        case .ready: return b("See what is available, try a sample, or continue setting up. You can return to this guide from Settings.", "查看当前准备情况，体验示例或继续配置。以后也可以从设置重新打开引导。")
        }
    }
    @ViewBuilder private func leftContent(_ page: OnboardingStep) -> some View {
        switch page {
        case .language:
            VStack(spacing: 9) {
                languageOption(.system, b("Follow system", "跟随系统"))
                languageOption(.simplifiedChinese, "简体中文")
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
                Text(b("Sets the answer style and the next page's recommendation.", "决定回答风格，以及下一页的配置推荐。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .models:
            OnboardingRecommendationView(coordinator: coordinator)
            OnboardingNote(icon: "internaldrive", title: b("Already installed? Keep it.", "已有模型，继续使用。"),
                           detail: b("Existing downloads are detected and reused. Local processing has no API fee.", "自动识别已有模型，避免重复下载。本地处理不产生 API 调用费。"))
            if models.downloading != nil || apple.busy || laya.isBusy {
                OnboardingNote(icon: "arrow.down.circle", title: b("Downloads in progress", "正在后台准备"), detail: b("Keep this app open. Progress remains available in Settings.", "保持应用运行。设置中也可以查看下载状态。"))
            }
        case .analysis:
            OnboardingNote(icon: "lock.shield", title: b("Know what leaves this Mac", "清楚数据去向"), detail: privacyText)
            OnboardingNote(icon: "key.horizontal", title: b("Stored in macOS Keychain", "保存在 macOS 钥匙串"), detail: b("Keys stay on this Mac. Each provider keeps its own credential.", "密钥保留在本机，各服务的凭据独立管理。"))
        case .permissions:
            OnboardingNote(icon: store.state.prefersTyping ? "keyboard" : coordinator.settings.mode == .remote ? "headphones" : "mic",
                           title: store.state.prefersTyping ? b("Typing first", "先输入问题") : L10n.text(coordinator.settings.mode.rawValue, language: coordinator.settings.language),
                           detail: b("Return to the introduction to change this choice. Granting access never starts recording.", "可以返回功能介绍页更改使用方式。授予权限不会开始录音。"))
        case .ready:
            OnboardingNote(icon: "keyboard", title: b("Keep it within reach", "随时唤出助手"),
                           detail: coordinator.hotkeys.toggleOverlay.display + b(" shows or hides the floating window. ", " 显示或隐藏悬浮窗。") + "\n" + coordinator.hotkeys.combo(for: .reply).display + b(" generates a reply from the conversation.", " 根据当前对话生成回答。"))
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
    private var privacyText: String {
        let speech = coordinator.settings.listeningService.isLocal
            ? b("Speech is transcribed on this Mac. ", "语音在本机转写。")
            : b("Audio is sent to OpenAI for transcription. ", "音频发送至 OpenAI 进行识别。")
        let knowledge = coordinator.settings.embeddingService == .local
            ? b("Knowledge embeddings stay local. ", "资料向量在本机生成。")
            : b("Knowledge indexing sends extracted text to OpenAI. ", "资料索引会将提取文本发送至 OpenAI。")
        return speech + knowledge + b("Generating an answer sends relevant conversation and selected excerpts to your answer service.", "生成回答时，相关对话和资料片段会发送至回答服务。")
    }
    private var footer: some View {
        HStack(spacing: 14) {
            Button(b("Back", "返回")) { store.state.back() }
                .disabled(step == .language).accessibilityIdentifier("onboarding-back")
            OnboardingStepProgress(step: step, language: coordinator.settings.language, reduceMotion: reduceMotion)
                .padding(.leading, 6)
            Spacer(minLength: 16)
            if step == .models {
                Button(b("Download later", "稍后下载")) { store.state.advance() }
                    .buttonStyle(OnboardingQuietButtonStyle(reduceMotion: reduceMotion)).accessibilityIdentifier("onboarding-skip-download")
            }
            Button(b("Set up later", "稍后设置")) { store.deferSetup(); close() }
                .buttonStyle(OnboardingQuietButtonStyle(reduceMotion: reduceMotion)).accessibilityIdentifier("onboarding-defer")
            Button(nextTitle) {
                if step == .ready { store.complete(); close() }
                else {
                    if step == .models { OnboardingDownloads.start(coordinator) }
                    store.state.advance()
                }
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-next")
        }
    }
    private var nextTitle: String {
        if step == .ready { return b("Enter LiveCopilot", "进入 LiveCopilot") }
        if step == .models && !coordinator.isMock && !locked && OnboardingDownloads.hasPending(coordinator) { return b("Prepare & continue", "准备并继续") }
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
