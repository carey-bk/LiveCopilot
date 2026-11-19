import SwiftUI

struct OnboardingRecommendationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var apple: AppleSpeechManager
    @ObservedObject var models: LocalModelManager
    @ObservedObject var laya: LayaRuntimeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator; store = coordinator.onboarding
        apple = coordinator.appleSpeech; models = coordinator.localModels; laya = coordinator.laya
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var plan: OnboardingRecommendation { .current(coordinator) }
    private var matches: Bool { plan.matches(coordinator) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label(b("Smart recommended setup", "智能推荐配置"), systemImage: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button(b("Restore", "恢复推荐配置")) { update { OnboardingRecommendation.apply(coordinator) } }
                    .controlSize(.small).disabled((matches && store.state.speechManuallySelected != true) || !OnboardingRecommendation.canEdit(coordinator))
                    .accessibilityLabel(b("Restore recommended setup", "恢复推荐配置"))
                    .accessibilityIdentifier("onboarding-apply-recommendation")
            }
            HStack(spacing: 12) {
                choiceLabel(b("Recognition language", "语音识别语言"))
                HStack(spacing: 2) {
                    ForEach(OnboardingSpeechScenario.allCases) { scene in
                        recommendationButton(scene.title(coordinator.settings.language), selected: OnboardingRecommendation.selectedScenario(coordinator) == scene) {
                            coordinator.onboarding.state.speechScenario = scene
                            OnboardingRecommendation.apply(coordinator)
                        }
                    }
                }.padding(2).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("onboarding-speech-scenario")
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                choiceLabel(b("Local knowledge base", "本地知识库"))
                HStack(spacing: 2) {
                    ForEach([true, false], id: \.self) { enabled in
                        recommendationButton(enabled ? b("Needed", "需要") : b("Not needed", "不需要"), selected: store.state.wantsKnowledge == enabled) {
                            OnboardingRecommendation.selectKnowledge(enabled, coordinator: coordinator)
                        }
                    }
                }.padding(2).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("onboarding-recommended-knowledge")
                Spacer(minLength: 0)
            }.padding(.top, 8)
            ZStack(alignment: .leading) {
                Text(recommendationDetail)
                    .id(recommendationDetail).transition(.opacity)
                    .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    .lineLimit(1).minimumScaleFactor(0.85).help(recommendationDetail)
            }
            .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15, alignment: .leading)
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity).frame(height: 134, alignment: .topLeading)
            .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.15)))
    }
    private func recommendationButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { update { action() } } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 13).padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .disabled(!OnboardingRecommendation.canEdit(coordinator))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func choiceLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12))
            .frame(width: coordinator.settings.language.usesChinese ? 84 : 132, alignment: .leading)
    }
    private var recommendationDetail: String {
        if store.state.speechManuallySelected == true {
            return b("Manual: ", "手动选择：") + engineName(coordinator.settings.listeningService) + b(" · tap a recommendation to restore", " · 点击上方选项恢复推荐")
        }
        return b("Recommended: ", "推荐：") + engineName(plan.speech) + " · " +
            (plan.speech == .openAI ? b("Online · usage fees", "需联网及 API 费用") : b("Local · low latency · no ASR fee", "本地 · 低延迟 · 无语音 API 费用"))
    }
    private func update(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), action)
    }
    private func engineName(_ service: ListeningService) -> String {
        switch service { case .zipformer: return "Zipformer"; case .paraformer: return "Paraformer"; case .apple: return "Apple"; case .openAI: return "OpenAI · GPT-Live" }
    }
}

struct OnboardingDetectedModelsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var models: LocalModelManager
    @ObservedObject var apple: AppleSpeechManager
    @ObservedObject var laya: LayaRuntimeManager
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator; store = coordinator.onboarding; models = coordinator.localModels
        apple = coordinator.appleSpeech; laya = coordinator.laya
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var setup: OnboardingSetupSnapshot { .init(coordinator) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(b("Current capabilities", "当前能力"), systemImage: "internaldrive").font(.system(size: 13, weight: .semibold))
            ForEach(setup.capabilities) { capability in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(featureName(capability.id)).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 3)
                        OnboardingCapabilityBadge(status: capability.status, language: coordinator.settings.language)
                    }
                    Text(capability.id == .proactive ? b("Automatic question recognition", "自动识别提问") : capability.model)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(b("Start with what is available", "先用现有能力")).font(.system(size: 12, weight: .semibold))
                Text(quickStartDetail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboarding-quick-start-detail")
            }
        }.padding(.top, 3)
    }
    private var quickStartDetail: String {
        let missing = setup.unavailableFeatures.map(featureName).joined(separator: b(", ", "、"))
        if missing.isEmpty {
            return b("Continue with installed capabilities; models are verified when loaded. You can add optional models in Settings.", "可先使用已安装能力，加载时验证。可选模型可在设置中补装。")
        }
        return b("Not ready yet: ", "暂不可用：") + missing + b(". Continue with typed questions and available capabilities; finish setup in Settings later.", "。可先输入问题并使用其他已有能力，之后在设置中补装或验证。")
    }
    private func featureName(_ feature: OnboardingSetupSnapshot.Feature) -> String {
        switch feature {
        case .speech: return b("Speech recognition", "语音识别")
        case .knowledge: return b("Knowledge retrieval", "知识库检索")
        case .proactive: return "Jev Mode"
        }
    }
}
