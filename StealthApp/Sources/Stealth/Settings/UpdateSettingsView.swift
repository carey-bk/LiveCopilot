import SwiftUI

/// Update texts come from the controller in Chinese; English interfaces get them translated here.
enum UpdateCopy {
    private static let english: [String: String] = [
        "软件更新": "Software update", "检查更新": "Check now", "检查更新…": "Check for Updates…",
        "尚未检查更新": "Not checked yet", "开发与预览版本不检查正式更新": "Development and preview builds don't check for releases",
        "正在检查更新…": "Checking for updates…", "正在下载更新…": "Downloading update…",
        "正在验证并准备更新…": "Verifying and preparing the update…", "更新已就绪，可以重启并安装": "Update ready. Restart to install.",
        "更新已就绪，结束当前任务后可安装": "Update ready. Install after the current task finishes.", "正在安装更新…": "Installing update…",
        "更新失败，请稍后重试": "Update failed. Try again later.", "请先结束监听、索引或模型准备，再检查更新。": "Finish listening, indexing or model setup before checking for updates.",
        "更新服务暂不可用，请前往官网下载页。": "The update service is unavailable. Visit the download page.",
        "检查或更新失败，请检查网络后重试。": "Checking or updating failed. Check your network and try again.",
        "暂时无法确认最新正式版本，请稍后重试。": "Couldn't confirm the latest release. Try again later.",
        "更新失败，请检查网络或稍后重试。": "Update failed. Check your network or try again later.",
        "更新由 Mac App Store 提供": "Updates are provided by the Mac App Store",
        "取消下载": "Cancel download", "更新内容": "What's new", "重启并更新": "Restart and update", "下载更新": "Download update",
        "官网下载页": "Download page", "前往官网下载": "Download from the website",
        "当前任务进行中，结束后可检查和安装更新。": "A task is running. Check and install updates after it finishes.",
        "自动检查更新": "Check for updates automatically", "后台静默检查，下载与重启由你确认。": "Checks quietly in the background. You confirm downloads and restarts.",
        "上次检查：": "Last checked: ", "查看更新": "View update", "稍后提醒": "Remind me later", "下载新版本": "Download new version", "好": "OK",
        "已是最新": "Up to date", "有新版本": "Update available", "失败": "Failed", "待检查": "Not checked", "当前版本": "Current", "最新版本": "Latest"
    ]
    static func text(_ zh: String, _ language: AppLanguage) -> String {
        guard !language.usesChinese else { return language.interfaceText(zh) }
        if let value = english[zh] { return value }
        if zh.hasPrefix("当前已是最新版本 · ") { return "You're up to date · " + zh.dropFirst("当前已是最新版本 · ".count) }
        if zh.hasPrefix("发现新版本 ") { return "New version available: " + zh.dropFirst("发现新版本 ".count) }
        return zh
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    private func u(_ zh: String) -> String { UpdateCopy.text(zh, language) }
    /// A cached "latest" that is older than this build (a local or pre-release install) is not news.
    private var latestDisplay: String {
        if let latest = updates.latestVersion, let current = updates.currentVersion, latest > current { return latest.display }
        if updates.latestVersion != nil || updates.phase == .upToDate { return updates.currentDisplay }
        return u("待检查")
    }
    private var statusPill: (String, LC.Tone)? {
        switch updates.phase {
        case .upToDate: return (u("已是最新"), .success)
        case .available, .readyToInstall: return (u("有新版本"), .accent)
        case .failed: return (u("失败"), .danger)
        default: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LCIconTile(systemImage: "arrow.down.circle", tone: .accent, size: 26)
                Text(u("软件更新")).font(LC.Typo.headline)
                if let statusPill { LCPill(text: statusPill.0, tone: statusPill.1) }
                Spacer()
                if [.checking].contains(updates.phase) { LCSpinner(size: 12, color: LC.accent) }
                Button(u("检查更新")) { updates.checkForUpdates() }
                    .buttonStyle(LCButtonStyle(kind: .secondary, compact: true))
                    .disabled(!updates.canCheck || updates.isWorking || updates.blockingReason() != nil)
                    .accessibilityIdentifier("check-for-updates")
            }
            HStack(spacing: 0) {
                versionCell(u("当前版本"), updates.currentDisplay)
                Divider().frame(height: 30).padding(.horizontal, 16)
                versionCell(u("最新版本"), latestDisplay)
                Spacer()
            }
            Text(u(updates.statusText)).font(LC.Typo.callout).foregroundStyle(updates.phase == .failed ? LC.danger : Color.secondary)
                .accessibilityIdentifier("update-status")
            if !updates.message.isEmpty && updates.phase != .failed { Text(u(updates.message)).font(LC.Typo.caption).foregroundStyle(.secondary) }
            if [.downloading, .extracting, .installing].contains(updates.phase) {
                if let progress = updates.progress { LCDotMeter(fraction: progress, segments: 32, height: 6) } else { LCProgressLine() }
                if updates.phase == .downloading { Button(u("取消下载")) { updates.cancelDownload() }.buttonStyle(LCButtonStyle(kind: .ghost, compact: true)) }
            }
            if let release = updates.release {
                DisclosureGroup(u("更新内容")) {
                    Text(release.notes).font(LC.Typo.callout).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.accessibilityIdentifier("update-notes")
                HStack(spacing: 10) {
                    if updates.phase == .readyToInstall {
                        Button(u("重启并更新")) { updates.restartToInstall() }
                            .disabled(updates.blockingReason() != nil).buttonStyle(LCButtonStyle(kind: .primary))
                            .accessibilityIdentifier("install-update")
                    } else if release.supportsInAppInstall {
                        Button(u("下载更新")) { updates.downloadUpdate() }
                            .disabled(!updates.canInstall || !updates.canCheck).buttonStyle(LCButtonStyle(kind: .primary))
                            .accessibilityIdentifier("download-update")
                    }
                    Link(release.supportsInAppInstall ? u("官网下载页") : u("前往官网下载"), destination: UpdateRelease.officialPage)
                }
            } else if updates.phase == .failed { Link(u("官网下载页"), destination: UpdateRelease.officialPage) }
            if updates.blockingReason() != nil { Text(u("当前任务进行中，结束后可检查和安装更新。")).font(LC.Typo.caption).foregroundStyle(.secondary) }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(u("自动检查更新")).font(LC.Typo.body)
                    Text(u("后台静默检查，下载与重启由你确认。")).font(LC.Typo.caption).foregroundStyle(.secondary)
                    if let date = updates.lastCheck {
                        Text(u("上次检查：") + date.formatted(.dateTime.locale(language.locale).year().month().day().hour().minute()))
                            .font(LC.Typo.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Toggle(u("自动检查更新"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!updates.enabled).accessibilityIdentifier("automatic-update-checks")
            }
        }.lcCard()
            .accessibilityIdentifier("software-update-management")
    }
    private func versionCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(LC.Typo.caption).foregroundStyle(.secondary)
            Text(value).font(LC.Typo.headline.monospacedDigit())
        }
    }
}

struct UpdateBanner: View {
    @ObservedObject var updates: AppUpdateController
    let language: AppLanguage
    let isBusy: Bool
    var body: some View {
        if !isBusy && updates.showsBanner, let release = updates.release {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(LC.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UpdateCopy.text("发现新版本 \(release.display)", language)).font(.system(size: 14, weight: .semibold))
                    Text(release.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    Button(UpdateCopy.text("查看更新", language)) { updates.viewUpdate() }.buttonStyle(.borderedProminent)
                    Button(UpdateCopy.text("稍后提醒", language)) { updates.remindLater() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }.lcCallout(.accent)
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
                Label { Text(updates.phase == .readyToInstall ? UpdateCopy.text("重启并更新", language) : UpdateCopy.text("下载新版本", language)) } icon: {
                    Image(systemName: "arrow.down.circle.fill").symbolRenderingMode(.palette).foregroundStyle(LC.accent)
                }
            } else { Text(UpdateCopy.text("检查更新…", language)) }
        }.disabled(!updates.enabled).accessibilityIdentifier("menu-update-entry")
        .onChange(of: updates.phase) { _, phase in
            guard awaitingResult else { return }
            if phase == .upToDate || phase == .failed { awaitingResult = false; showsResult = true }
            else if phase == .available { awaitingResult = false; updates.viewUpdate() }
        }
        .alert(UpdateCopy.text("软件更新", language), isPresented: $showsResult) { Button(UpdateCopy.text("好", language), role: .cancel) {} } message: { Text(UpdateCopy.text(updates.statusText, language)) }
    }
}
