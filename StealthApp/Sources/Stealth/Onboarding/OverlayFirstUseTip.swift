import SwiftUI

/// Inline guidance preserves access to the real controls and never triggers them.
struct OverlayFirstUseTip: View {
    let step: OverlayTourState.Step
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var hotkeys: HotkeyStore
    init(step: OverlayTourState.Step, coordinator: AppCoordinator) {
        self.step = step; self.coordinator = coordinator
        store = coordinator.onboarding; hotkeys = coordinator.hotkeys
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: "lightbulb").font(.system(size: 12, weight: .semibold))
                    .labelStyle(OverlayTipTitleStyle())
                Spacer(minLength: 4)
                Text("\(step.position + 1) / \(OverlayTourState.Step.order.count)").font(.caption2).foregroundStyle(.secondary)
                Button(b("Dismiss tips", "跳过提示")) { store.dismissTips() }
                    .font(.caption2).buttonStyle(.borderless).accessibilityIdentifier("overlay-tip-dismiss")
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(step == .captureExclusion ? b("Open Settings", "打开设置") : b("Open setup", "打开配置引导")) {
                    if step == .captureExclusion { coordinator.onOpenSettings?() }
                    else { coordinator.onOpenOnboarding?() }
                }
                    .font(.caption2).buttonStyle(.borderless)
                Spacer()
                Button(step == .captureExclusion ? b("Got it", "知道了") : b("Next tip", "下一条")) { store.advanceTip() }
                    .font(.caption).accessibilityIdentifier("overlay-tip-next")
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous).strokeBorder(LC.hairline))
            .onboardingSpotlightCard()
            .accessibilityElement(children: .contain).accessibilityIdentifier("overlay-first-use-tip")
    }
    private var title: String {
        switch step {
        case .start: return store.state.prefersTyping ? b("Start with a question", "先输入一个问题") : b("Start listening when you are ready", "准备好后，再开始监听")
        case .answer: return b("Choose when to ask for help", "按需生成回答")
        case .transcript: return b("Follow the conversation", "实时转写")
        case .tools: return b("Recap, follow-up and automatic answers", "总结、追问与自动建议")
        case .composer: return b("Type a question any time", "随时输入问题")
        case .window: return b("Buttons along the top", "顶部按钮")
        case .visibility: return b("Keep the window within reach", "随时唤出悬浮窗")
        case .captureExclusion: return L10n.text("Hide the floating window from meeting screen sharing and recording", language: coordinator.settings.language)
        }
    }
    private var detail: String {
        switch step {
        case .start:
            if coordinator.isMock {
                return store.state.prefersTyping
                    ? b("Type below and click Ask. This preview returns a sample response without recording or calling an API.", "在下方输入问题并点击“提问”。本预览只展示示例回答，不录音，也不调用 API。")
                    : b("The play button starts and stops listening. In this preview it shows sample captions without recording audio.", "播放按钮用于开始和停止监听。本预览只显示示例字幕，不采集音频。")
            }
            return store.state.prefersTyping
                ? b("Type below and click Ask. No audio access is needed. A real service request starts only when you submit.", "在输入框中填写问题，点击“提问”即可，无需音频权限。提交后才会请求回答服务。")
                : b("The play button starts capture; click it again to stop. Prepare your speech model and permissions in setup first. These tips never start recording.", "播放按钮开始采集，再点一次即可停止。请先在引导中准备识别服务和权限；查看提示不会开始录音。")
        case .answer:
            if coordinator.isMock {
                return hotkeys.combo(for: .reply).display + b(" or Generate answer shows a sample suggestion here. In normal use, this requests your configured answer service.", " 或“生成回答”会在这里展示示例建议。正式使用时会请求你配置的回答服务。")
            }
            return hotkeys.combo(for: .reply).display + b(" or Generate answer uses the current conversation. You can also type a question below. Requests use your configured answer service.", " 或“生成回答”会根据当前对话请求建议，也可在下方直接输入问题。请求使用你配置的回答服务。")
        case .transcript:
            return coordinator.settings.mode == .remote
                ? b("What is said appears here: You is your microphone, Them is the system audio. Collapse transcript keeps the latest two lines; Translate shows the other side in a language you pick; turn off Follow transcript to scroll back.",
                    "对话会实时显示在这里：「我」是你的麦克风，「对方」是系统音频。「折叠转写」只留最新两行；「翻译」把对方的话译成你选的语言；关闭「跟随最新转写」可往回翻看。")
                : b("What is said in the room appears here. Collapse transcript keeps the latest two lines; Translate shows it in a language you pick; turn off Follow transcript to scroll back.",
                    "现场说的话会实时显示在这里。「折叠转写」只留最新两行；「翻译」把内容译成你选的语言；关闭「跟随最新转写」可往回翻看。")
        case .tools:
            return b("Recap summarizes what has been said and decided; Follow-up suggests one question you can ask next. With Auto on, an answer is prepared when the other side finishes a question. The knowledge menu chooses whether answers draw on your documents.",
                     "「总结」概括目前聊了什么、定了什么；「追问」帮你想一个接下来可以问的问题。打开「自动建议」后，对方问完问题会自动准备回答。「混合知识」菜单决定回答是否引用你的资料。")
        case .composer:
            return b("Type and press Return to ask; a long question wraps onto more lines. The bubble button inside the field chooses whether recent conversation is sent with the question. While an answer is being written, Send becomes Stop. The globe menu sets the answer language.",
                     "在输入框打字，回车即可提问，长问题会自动换行显示。输入框里的气泡按钮选择是否附带近期对话；生成回答时发送键会变成停止键。右侧地球菜单设置回答语言。")
        case .window:
            return b("Play starts or stops listening. ↻ clears the conversation and answers (listening continues). The microphone turns your voice on or off in Remote Meeting. The gear opens Settings, the pin switches edge docking, the layout button switches to answers only, and − hides the window.",
                     "播放键开始/停止监听；↻ 清空对话和回答，监听不中断；麦克风在远程会议中开关你的声音；齿轮打开设置；图钉切换自动贴边；布局按钮切换为只看回答；“−”隐藏窗口。")
        case .captureExclusion:
            let status = coordinator.settings.excludeOverlayFromCapture
                ? b("Currently on. ", "当前已开启。") : b("Currently off. ", "当前未开启。")
            return L10n.text("Keep suggestions visible on your screen while excluding the floating window from capture. Settings and setup remain visible in shared content. Verify the result from another participant before use.", language: coordinator.settings.language)
                + "\n" + status + b("Change this in Settings → General.", "可在“设置 → 通用”中调整。")
        case .visibility:
            return hotkeys.toggleOverlay.display + b(" shows or hides this window. Pin it to keep it visible; when edge hiding is enabled, move to the right edge to reveal it. You can replay these tips from Settings.", " 显示或隐藏窗口。点击图钉可固定窗口；开启贴边隐藏时，将鼠标移到屏幕右侧即可唤出。设置中可以重看提示。")
        }
    }
}

private struct OverlayTipTitleStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.foregroundStyle(LC.accent); configuration.title }
    }
}

/// One place an overlay tip points at, in the overlay's coordinate space.
struct SpotlightTarget: Equatable {
    var rect: CGRect
    /// The tip card itself: kept clear of the dimming, without a highlight ring.
    var card = false
}

enum SpotlightLayout {
    /// Merges targets that touch or sit within `gap` points of each other, so a row of buttons
    /// reads as one lit area instead of many small boxes. Cards are never merged.
    static func holes(_ targets: [SpotlightTarget], gap: CGFloat = 10) -> [SpotlightTarget] {
        var cards = targets.filter(\.card), merged = targets.filter { !$0.card && !$0.rect.isEmpty }.map(\.rect)
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    if merged[i].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(merged[j].insetBy(dx: -gap / 2, dy: -gap / 2)) {
                        merged[i] = merged[i].union(merged[j]); merged.remove(at: j); changed = true
                        break outer
                    }
                }
            }
        }
        cards.append(contentsOf: merged.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }.map { SpotlightTarget(rect: $0) })
        return cards
    }
}

struct OnboardingSpotlightKey: PreferenceKey {
    struct Item { let anchor: Anchor<CGRect>; let card: Bool }
    static var defaultValue: [Item] = []
    static func reduce(value: inout [Item], nextValue: () -> [Item]) { value.append(contentsOf: nextValue()) }
}

/// Dims the overlay around the current tip's targets. Purely visual: every control stays usable.
struct OverlaySpotlight: View {
    let items: [OnboardingSpotlightKey.Item]
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GeometryReader { proxy in
            let holes = SpotlightLayout.holes(items.map { item in
                let rect = proxy[item.anchor]
                return SpotlightTarget(rect: item.card ? rect : rect.insetBy(dx: -5, dy: -4), card: item.card)
            })
            // Only with the tip card on screen: in answers-only view the card is hidden, so nothing explains the lit areas.
            if holes.contains(where: \.card), holes.contains(where: { !$0.card }) {
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        for hole in holes { path.addRoundedRect(in: hole.rect, cornerSize: Self.corner(hole), style: .continuous) }
                    }
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.42 : 0.26), style: FillStyle(eoFill: true))
                    ForEach(Array(holes.enumerated()).filter { !$0.element.card }, id: \.offset) { _, hole in
                        RoundedRectangle(cornerRadius: Self.corner(hole).width, style: .continuous)
                            .strokeBorder(LC.accent.opacity(0.55), lineWidth: 1)
                            .shadow(color: LC.accent.opacity(0.45), radius: 6)
                            .frame(width: hole.rect.width, height: hole.rect.height)
                            .offset(x: hole.rect.minX, y: hole.rect.minY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private static func corner(_ hole: SpotlightTarget) -> CGSize {
        let radius = hole.card ? LC.Radius.control + 2 : min(hole.rect.height / 2, 10)
        return CGSize(width: radius, height: radius)
    }
}

extension View {
    /// Marks this view as a target of the current overlay tip; `OverlaySpotlight` lights it up.
    func onboardingHighlight(_ active: Bool) -> some View {
        transformAnchorPreference(key: OnboardingSpotlightKey.self, value: .bounds) { value, anchor in
            if active { value.append(.init(anchor: anchor, card: false)) }
        }
    }
    func onboardingSpotlightCard() -> some View {
        transformAnchorPreference(key: OnboardingSpotlightKey.self, value: .bounds) { value, anchor in
            value.append(.init(anchor: anchor, card: true))
        }
    }
}
