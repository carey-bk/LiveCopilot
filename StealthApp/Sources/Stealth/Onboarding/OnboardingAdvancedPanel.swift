import SwiftUI

/// All three capability editors use the same opaque, keyboard-accessible native shell.
struct OnboardingAdvancedPanel<Content: View>: View {
    let title: String
    let icon: String
    let language: AppLanguage
    var savesImmediately = true
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { JevBrand.text(title, size: 17) } icon: { Image(systemName: icon) }.font(.system(size: 16, weight: .semibold))
            Divider()
            LCScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(height: 340)
            Divider()
            HStack {
                Text(ServiceGuide.text(savesImmediately ? "Changes save immediately" : "Save edits before closing", savesImmediately ? "更改即时保存" : "编辑后请先保存连接", language)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ServiceGuide.text("Done", "完成", language), action: close)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).controlSize(.regular).buttonStyle(.bordered)
            .toggleStyle(TrailingSwitchStyle()).padding(20).frame(width: 480)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OnboardingDownloadSummary: View {
    let setup: OnboardingSetupSnapshot
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if setup.resources.isEmpty {
                Label(setup.needsLayaLoad ? b("No download needed · verify Laya next", "无需下载 · 继续后验证 Laya") : b("No downloads needed for this setup", "当前配置无需下载资源"), systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text(b("Resources for this setup", "当前配置所需资源")).font(.system(size: 12, weight: .medium))
                ForEach(setup.resources) { resource in
                    HStack(spacing: 6) {
                        Text(resource.name)
                        if !resource.needsStart { Text(resource.status.title(language)).foregroundStyle(LC.accent) }
                        Spacer(minLength: 4)
                        Text(resource.sizeLabel(language)).monospacedDigit()
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(resource.bytes.map { b("Full resource size: ", "完整资源大小：") + String($0) + b(" bytes (pinned manifest)", " 字节（固定版本清单）") } ?? b("The complete resource size is not available.", "目前无法获取完整资源大小。"))
                }
            }
            if !setup.backgroundOnly.isEmpty {
                Text(b("Also preparing in the background: ", "另有后台任务：") + setup.backgroundOnly.joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding-download-summary")
    }
}
