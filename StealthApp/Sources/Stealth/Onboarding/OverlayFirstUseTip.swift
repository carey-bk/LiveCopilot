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
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(step.rawValue + 1) / \(OverlayTourState.Step.allCases.count)").font(.caption2).foregroundStyle(.secondary)
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
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("overlay-first-use-tip")
    }
    private var title: String {
        switch step {
        case .start: return store.state.prefersTyping ? b("Start with a question", "先输入一个问题") : b("Start listening when you are ready", "准备好后，再开始监听")
        case .answer: return b("Choose when to ask for help", "按需生成回答")
        case .visibility: return b("Keep the window within reach", "随时唤出悬浮窗")
        case .captureExclusion: return L10n.text("Keep the floating window hidden during screen sharing and screenshots", language: coordinator.settings.language)
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
        case .captureExclusion:
            let status = coordinator.settings.excludeOverlayFromCapture
                ? b("Currently on. ", "当前已开启。") : b("Currently off. ", "当前未开启。")
            return L10n.text("When enabled, the LiveCopilot floating window stays out of meeting apps' screen sharing and recordings, keeping suggestions visible only to you.", language: coordinator.settings.language)
                + "\n" + status + b("Change this in Settings → General.", "可在“设置 → 通用”中调整。")
        case .visibility:
            return hotkeys.toggleOverlay.display + b(" shows or hides this window. Pin it to keep it visible; when edge hiding is enabled, move to the right edge to reveal it. You can replay these tips from Settings.", " 显示或隐藏窗口。点击图钉可固定窗口；开启贴边隐藏时，将鼠标移到屏幕右侧即可唤出。设置中可以重看提示。")
        }
    }
}

extension View {
    func onboardingHighlight(_ active: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2).padding(-3).allowsHitTesting(false))
    }
}
