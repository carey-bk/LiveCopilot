import SwiftUI

/// Self-contained illustrative content. It never reaches a runtime provider or a user document.
struct OnboardingConversationPreview: View {
    let language: AppLanguage
    var scenario: ScenarioProfile = .interview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    @State private var playing = true
    @State private var replay = 0
    private var motionDisabled: Bool {
        reduceMotion || (AppPaths.isOnboardingPreview && ProcessInfo.processInfo.arguments.contains("--onboarding-reduce-motion"))
    }
    private var shownPhase: Int { motionDisabled ? 3 : phase }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(b("Example conversation", "示例对话"), systemImage: "play.rectangle").font(.headline)
                Spacer()
                Text("\(shownPhase + 1) / 4").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(0..<4) { index in Capsule().fill(index <= shownPhase ? Color.accentColor : Color.primary.opacity(0.1)).frame(height: 3) }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Label(b("Hear the question", "听到问题"), systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                Text(question).font(.system(size: 18, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            demoStage(1, title: b("Recognize a complete question", "判断问题是否完整"), icon: "sparkle",
                      text: b("With Jev Mode enabled, a complete question can trigger a suggestion. You can also trigger it manually.", "开启 Jev Mode 后，可在完整问题出现时请求建议，也可以手动触发。"))
            demoStage(2, title: scenario == .meeting ? b("Use the conversation", "结合当前对话") : b("Find supporting material", "查找相关资料"), icon: "text.magnifyingglass",
                      text: evidence)
            VStack(alignment: .leading, spacing: 8) {
                Label(b("A starting point for your answer", "给你一个表达起点"), systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                Text(shownPhase == 3 ? answer : b("The suggestion appears here.", "回答建议会出现在这里。"))
                    .font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if !motionDisabled && phase < 3 {
                    Button(playing ? b("Pause", "暂停演示") : b("Continue demo", "继续演示")) { playing.toggle() }
                        .accessibilityIdentifier("onboarding-demo-playback")
                }
                if !motionDisabled {
                    Button(b("Replay", "重新播放")) { phase = 0; playing = true; replay += 1 }
                        .accessibilityIdentifier("onboarding-demo-replay")
                }
                Spacer(minLength: 0)
            }.buttonStyle(.borderless).font(.caption)
            Text(motionDisabled
                 ? b("Full example shown with Reduce Motion. No recording, documents, or API calls.", "已按“减少动态效果”展示完整示例。不录音、不读取资料、不调用 API。")
                 : b("Illustrative content only. No recording, documents, or API calls.", "仅为演示内容。不录音、不读取资料、不调用 API。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("onboarding-conversation-demo")
            .task(id: "\(playing)-\(motionDisabled)-\(replay)") {
                guard playing, !motionDisabled else { return }
                do {
                    while phase < 3 {
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        try Task.checkCancellation()
                        withAnimation(.easeInOut(duration: 0.3)) { phase += 1 }
                    }
                    playing = false
                } catch { /* Leaving the page or pausing cancels this demonstration. */ }
            }
    }
    private func demoStage(_ index: Int, title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.opacity(shownPhase >= index ? 1 : 0.28)
            .accessibilityHidden(shownPhase < index)
    }
    private var question: String {
        switch scenario {
        case .interview: return b("How would you introduce a project you worked on?", "你会怎样介绍自己做过的一个项目？")
        case .meeting: return b("How should we choose the next step?", "我们应该如何确定下一步？")
        case .defense: return b("What are the limitations of this method?", "这个方法有哪些局限？")
        }
    }
    private var evidence: String {
        switch scenario {
        case .interview: return b("Example project notes: goal, your contribution, and evidence of the result.", "示例项目笔记：目标、个人职责、结果依据。")
        case .meeting: return b("Example meeting context: the open decision, constraints, and next action.", "示例会议上下文：待定事项、限制条件、下一步行动。")
        case .defense: return b("Example method notes: assumptions, sample coverage, and validation limits.", "示例方法笔记：前提假设、样本覆盖、验证范围。")
        }
    }
    private var answer: String {
        switch scenario {
        case .interview: return b("I would begin with the problem, explain my contribution, then describe the result supported by my project notes.", "我会先说明要解决的问题，再介绍自己承担的工作，最后结合项目资料说明结果。")
        case .meeting: return b("Let's confirm the decision criteria, compare the options, then agree on an owner and a time to review progress.", "我们可以先确认决策标准，再比较可选方案，最后明确负责人和复盘时间。")
        case .defense: return b("I would separate the method's assumptions from the limits of the data, then explain what further validation is needed.", "我会分别说明方法的前提假设和数据覆盖的限制，再解释还需要哪些进一步验证。")
        }
    }
}
