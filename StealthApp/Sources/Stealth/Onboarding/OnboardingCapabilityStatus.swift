import SwiftUI

/// Presentation only: installed files do not prove that a runtime has loaded successfully.
enum OnboardingCapabilityStatus: Equatable {
    case ready, download, installed, verify, downloading, queued, verifying, loadFailed, downloadFailed, configure, attention, unavailable, off, notNeeded

    @MainActor static func local(_ kind: LocalModelKind, models: LocalModelManager) -> Self {
        if models.downloading == kind { return .downloading }
        if models.queued.contains(kind) { return .queued }
        if models.installed.contains(kind) { return .installed }
        return models.failures[kind] == nil ? .download : .downloadFailed
    }
    static func apple(available: Bool, installed: Bool, busy: Bool, verified: Bool) -> Self {
        guard available else { return .unavailable }
        if busy { return .downloading }
        guard verified else { return .verify }
        return installed ? .ready : .download
    }
    static func laya(_ state: LayaRuntimeManager.State) -> Self {
        switch state {
        case .unsupported: return .unavailable
        case .notInstalled: return .download
        case .installed: return .installed
        case .installing: return .downloading
        case .loading: return .verifying
        case .ready: return .ready
        case .failed: return .loadFailed
        }
    }
    func title(_ language: AppLanguage) -> String {
        let pair: (String, String)
        switch self {
        case .ready: pair = ("Ready", "已就绪")
        case .download: pair = ("Not downloaded", "未下载")
        case .installed: pair = ("Installed · unverified", "已安装，待验证")
        case .loadFailed: pair = ("Load failed", "加载失败")
        case .downloadFailed: pair = ("Download failed", "下载失败")
        case .configure: pair = ("Setup needed", "待配置")
        case .verify: pair = ("Unverified", "待验证")
        case .downloading: pair = ("Downloading", "下载中")
        case .queued: pair = ("Queued", "等待下载")
        case .verifying: pair = ("Verifying", "验证中")
        case .attention: pair = ("Needs attention", "需处理")
        case .unavailable: pair = ("Unavailable", "不可用")
        case .notNeeded: pair = ("Optional for typing", "手动输入无需配置")
        case .off: pair = ("Not enabled", "未启用")
        }
        return ServiceGuide.text(pair.0, pair.1, language)
    }
    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .download: return "arrow.down.circle"
        case .installed: return "internaldrive"
        case .verify, .verifying: return "circle.dotted"
        case .downloading: return "arrow.down"
        case .queued: return "clock"
        case .attention, .loadFailed, .downloadFailed, .configure: return "exclamationmark.circle"
        case .unavailable, .off, .notNeeded: return "minus.circle"
        }
    }
}

struct OnboardingCapabilityBadge: View {
    let status: OnboardingCapabilityStatus
    let language: AppLanguage
    private var color: Color {
        switch status {
        case .ready: return LC.success
        default: return .secondary
        }
    }
    var body: some View {
        Label(status.title(language), systemImage: status.icon)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.08), in: Capsule()).fixedSize()
            .help(status == .verify ? ServiceGuide.text("Installed resources or saved settings still need runtime verification.", "已安装的资源或已保存的配置仍需运行验证。", language) : status.title(language))
    }
}
