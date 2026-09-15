import SwiftUI
import CoreGraphics

struct CapturePermissionCard: View {
    let language: AppLanguage
    @State private var granted = CGPreflightScreenCaptureAccess()
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(b("System audio permission", "系统音频权限"), systemImage: "lock.shield").font(.headline)
            Text(granted ? b("Current app has screen/system-audio access.", "当前应用已有录屏与系统录音权限。") : b("The current app needs screen/system-audio access for Remote Meeting. In-Person mode only needs the microphone.", "远程会议需要为当前应用授予录屏与系统录音权限；现场模式仅需麦克风。"))
                .font(.callout).foregroundStyle(granted ? .green : .secondary)
            if !granted {
                Button(b("Request permission for this app", "为当前应用请求权限")) { granted = CGRequestScreenCaptureAccess() }
            }
            Button(b("Open Privacy Settings", "打开隐私设置")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            Text(b("Enable LiveCopilot at ~/Applications/LiveCopilot.app, then quit and reopen if macOS asks. The local installer archives old apps outside Applications and repairs stale screen-capture registrations when the signature changes. macOS still requires your Allow action; API keys stay in Keychain.", "请允许 ~/Applications/LiveCopilot.app 对应的 LiveCopilot；系统提示时退出重开。本地安装脚本会把旧版本归档到应用目录外，并在签名变化时重建录屏权限记录。macOS 的允许操作仍需本人完成，API Key 保留在钥匙串中。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in granted = CGPreflightScreenCaptureAccess() }
    }
}
