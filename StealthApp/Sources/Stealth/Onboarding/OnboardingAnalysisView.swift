import SwiftUI

struct OnboardingAnalysisView: View {
    @ObservedObject var coordinator: AppCoordinator
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning }
    private var shared: Bool { coordinator.settings.reasoningService == .sharedOpenAI }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingAnswerConfiguration(coordinator: coordinator).disabled(locked)
            credentials
        }.padding(4).frame(maxHeight: .infinity, alignment: .center)
    }
    private var credentials: some View {
        OnboardingServiceSection(number: 2, title: b("API Key & connection test", "API Key 与连接测试")) {
            if (try? coordinator.settings.analysisCredentialReference()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: !shared, onboarding: true, analysisLayout: true)
                    .id(coordinator.settings.reasoningService.rawValue + "|" + ((try? coordinator.settings.analysisCredentialReference().account) ?? "invalid"))
                    .disabled(locked)
            } else {
                Label(b("Save a valid service address in Connection address first.", "请先在连接地址中保存有效的服务地址。"), systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct OnboardingConnectionFeedback: View {
    let language: AppLanguage
    let testing: Bool
    let verified: Bool
    let saved: Bool
    var mock = false
    var failure: OnboardingConnectionFailure?
    var compact = false
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    private var success: Bool { verified && !testing && failure == nil }
    private var title: String {
        if testing { return b("Testing connection…", "正在测试连接…") }
        if let failure { return failure.title(language) }
        if verified {
            if compact { return mock ? b("Preview passed", "预览通过") : b("Connected", "连接成功") }
            return mock ? b("Preview test passed · no API call", "预览测试通过 · 未调用 API") : b("Connection verified · ready to continue", "连接测试成功 · 可以继续")
        }
        return saved ? b("Key saved · connection not yet verified", "密钥已保存 · 连接待测试") : b("Not configured · you can set up later", "尚未配置 · 可以稍后设置")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: success ? "checkmark.circle.fill" : failure != nil ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(success ? Color.green : failure != nil ? Color.orange : Color.secondary)
            if let failure, !compact { Text(failure.detail(language)).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboarding-connection-result")
    }
}

struct OnboardingServiceSection<Content: View>: View {
    let number: Int
    let title: String
    var showsBorder = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(String(number)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 21, height: 21).background(Color.accentColor.opacity(0.09), in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            content()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(showsBorder ? 0.045 : 0)))
            .accessibilityElement(children: .contain)
    }
}
