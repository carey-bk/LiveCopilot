import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(language.interfaceText("软件更新"), systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Button(language.interfaceText("检查更新")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck || updates.isWorking || updates.blockingReason() != nil)
                    .accessibilityIdentifier("check-for-updates")
            }
            HStack(spacing: 18) {
                Text(language.interfaceText("当前版本：\(updates.currentDisplay)"))
                Text(language.interfaceText("最新版本：") + (updates.latestVersion?.display ?? (updates.phase == .upToDate ? updates.currentDisplay : language.interfaceText("待检查"))))
                    .foregroundStyle(.secondary)
            }.font(.callout)
            Text(language.interfaceText(updates.statusText)).font(.callout).foregroundStyle(updates.phase == .failed ? Color.red : Color.primary)
                .accessibilityIdentifier("update-status")
            if !updates.message.isEmpty && updates.phase != .failed { Text(language.interfaceText(updates.message)).font(.caption).foregroundStyle(.secondary) }
            if [.checking, .downloading, .extracting, .installing].contains(updates.phase) {
                if let progress = updates.progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                if updates.phase == .downloading { Button(language.interfaceText("取消下载")) { updates.cancelDownload() } }
            }
            if let release = updates.release {
                DisclosureGroup(language.interfaceText("更新内容")) {
                    Text(release.notes).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.accessibilityIdentifier("update-notes")
                HStack {
                    if updates.phase == .readyToInstall {
                        Button(language.interfaceText("重启并更新")) { updates.restartToInstall() }
                            .disabled(updates.blockingReason() != nil).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("install-update")
                    } else if release.supportsInAppInstall {
                        Button(language.interfaceText("下载更新")) { updates.downloadUpdate() }
                            .disabled(!updates.canInstall || !updates.canCheck).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("download-update")
                    }
                    Link(release.supportsInAppInstall ? language.interfaceText("官方发布页") : language.interfaceText("前往官方发布页下载"), destination: UpdateRelease.officialPage)
                }
            } else if updates.phase == .failed { Link(language.interfaceText("官方发布页"), destination: UpdateRelease.officialPage) }
            if updates.blockingReason() != nil { Text(language.interfaceText("当前任务进行中，结束后可检查和安装更新。")).font(.caption).foregroundStyle(.secondary) }
            Toggle(language.interfaceText("自动检查更新"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.enabled).accessibilityIdentifier("automatic-update-checks")
            Text(language.interfaceText("后台静默检查，下载与重启由你确认。")).font(.caption).foregroundStyle(.secondary)
            if let date = updates.lastCheck {
                Text(language.interfaceText("上次检查：") + date.formatted(.dateTime.locale(language.locale).year().month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("software-update-management")
    }
}

struct UpdateBanner: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    let isBusy: Bool
    var body: some View {
        if !isBusy && updates.showsBanner, let release = updates.release {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.interfaceText("发现新版本 \(release.display)")).font(.system(size: 14, weight: .semibold))
                    Text(release.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    Button(language.interfaceText("查看更新")) { updates.viewUpdate() }.buttonStyle(.borderedProminent)
                    Button(language.interfaceText("稍后提醒")) { updates.remindLater() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.18)))
                .accessibilityIdentifier("update-banner")
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    @State private var awaitingResult = false
    @State private var showsResult = false
    var body: some View {
        Button {
            if updates.hasUpdate {
                updates.viewUpdate()
                if updates.phase != .readyToInstall { updates.downloadUpdate() }
            } else { awaitingResult = true; updates.checkForUpdates() }
        } label: {
            if updates.hasUpdate {
                Label { Text(updates.phase == .readyToInstall ? language.interfaceText("重启并更新") : language.interfaceText("下载新版本")) } icon: {
                    Image(systemName: "arrow.down.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.blue)
                }
            } else { Text(language.interfaceText("检查更新…")) }
        }.disabled(!updates.enabled).accessibilityIdentifier("menu-update-entry")
        .onChange(of: updates.phase) { _, phase in
            guard awaitingResult else { return }
            if phase == .upToDate || phase == .failed { awaitingResult = false; showsResult = true }
            else if phase == .available { awaitingResult = false; updates.viewUpdate() }
        }
        .alert(language.interfaceText("软件更新"), isPresented: $showsResult) { Button(language.interfaceText("好"), role: .cancel) {} } message: { Text(language.interfaceText(updates.statusText)) }
    }
}
