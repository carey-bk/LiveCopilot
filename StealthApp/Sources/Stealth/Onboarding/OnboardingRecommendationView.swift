import SwiftUI

struct OnboardingRecommendationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var apple: AppleSpeechManager
    @ObservedObject var models: LocalModelManager
    @ObservedObject var laya: LayaRuntimeManager
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator; store = coordinator.onboarding
        apple = coordinator.appleSpeech; models = coordinator.localModels; laya = coordinator.laya
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var plan: OnboardingRecommendation { .current(coordinator) }
    private var matches: Bool { plan.applying(to: coordinator.settings) == coordinator.settings && store.state.wantsKnowledge == plan.wantsKnowledge }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(b("Suggested for ", "适合") + L10n.text(plan.scenario.rawValue, language: coordinator.settings.language), systemImage: "slider.horizontal.3")
                .font(.headline)
            Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(configuration).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(matches ? b("Recommendation applied", "已采用推荐") : b("Use recommended setup", "应用推荐配置")) { OnboardingRecommendation.apply(coordinator) }
                .disabled(matches || coordinator.isRunning || coordinator.isTransitioning || coordinator.isIndexing ||
                          models.downloading != nil || apple.busy || laya.isBusy)
                .accessibilityIdentifier("onboarding-apply-recommendation")
            Text(b("Applying this setup does not download anything. Review the choices on the right before preparing them.", "应用推荐不会开始下载。可在右侧逐项调整，确认后再准备模型。")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    private var reason: String {
        switch plan.scenario {
        case .interview: return b("Use your résumé and project notes to ground concise answers.", "结合简历和项目资料，组织简洁、有依据的回答。")
        case .meeting: return b("Start with the conversation. Use Recap to review decisions and next actions.", "先围绕当前对话使用，随时通过“总结”整理结论与待办。")
        case .defense: return b("Bring your paper and method notes to explain assumptions and limitations.", "结合论文和方法笔记，说明假设、依据与局限。")
        }
    }
    private var configuration: String {
        let speech = plan.typing ? b("Type questions; no speech setup. ", "输入提问，无需配置语音。") : plan.speech == .apple
            ? b("Reuse installed Apple speech. ", "复用已安装的 Apple 识别。")
            : b("Local Chinese/English speech. ", "本地中英转写。")
        let trigger = plan.typing ? "" : plan.recommendsJev
            ? b("Enable Jev Mode for automatic suggestions. ", "开启 Jev Mode 自动建议。")
            : b("Generate replies manually on this Mac. ", "此 Mac 使用手动触发回答。")
        return speech + trigger + (plan.wantsKnowledge ? b("Enable local document retrieval; import documents later in Settings.", "开启本地资料检索，之后在设置中导入资料。") : b("Leave document retrieval optional; add it when needed.", "暂不准备资料检索，需要时再启用。"))
    }
}
