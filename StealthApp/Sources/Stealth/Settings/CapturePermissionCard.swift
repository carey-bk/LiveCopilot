import SwiftUI
import CoreGraphics

struct CapturePermissionCard: View {
    let language: AppLanguage
    @State private var granted = CGPreflightScreenCaptureAccess()
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LiveCopilot" }
    private var appPath: String { (Bundle.main.bundleURL.path as NSString).abbreviatingWithTildeInPath }
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
            Text(b("In Privacy & Security, allow \(appName) at \(appPath). Quit and reopen if macOS asks. Permission must be granted by you; your saved API keys are retained.", "请在隐私与安全性中允许 \(appName)，对应位置为 \(appPath)。系统提示时退出并重新打开。权限需由你本人授予，已保存的 API Key 会保留。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in granted = CGPreflightScreenCaptureAccess() }
    }
}
