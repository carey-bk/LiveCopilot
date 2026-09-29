import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(b("Software updates", "软件更新")).font(.headline)
                Spacer()
                Button(b("Check for Updates…", "检查更新…")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck).accessibilityIdentifier("check-for-updates")
            }
            Toggle(b("Automatically check for updates", "自动检查更新"), isOn: Binding(
                get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.enabled).accessibilityIdentifier("automatic-update-checks")
            Text(b("Downloads and installation require your confirmation. Updates preserve your models, documents, history, and API keys.",
                   "下载与安装由你确认。更新会保留模型、资料、历史和 API Key。"))
                .font(.caption).foregroundStyle(.secondary)
            if !updates.enabled {
                Text(b("Updates are available in the installed release app. Previews and development builds do not check for updates.",
                       "请在正式安装版中检查更新，预览和开发版本不会联网检查。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let date = updates.lastCheck {
                Text(b("Last checked: ", "上次检查：") + date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    var body: some View {
        Button(ServiceGuide.text("Check for Updates…", "检查更新…", language)) { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}
