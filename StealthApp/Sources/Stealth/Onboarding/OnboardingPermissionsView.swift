import SwiftUI
import AVFoundation

struct OnboardingPermissionsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var permissions: OnboardingPermissions
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(b("Audio permissions", "权限准备")).font(.headline)
                Spacer()
                if !store.state.prefersTyping {
                    Button(b("Check again", "重新检查")) { permissions.refresh() }
                        .buttonStyle(.borderless).accessibilityIdentifier("onboarding-refresh-permissions")
                }
            }
            if store.state.prefersTyping {
                Text(b("Typing needs no audio access. You can grant access in Settings if you switch to voice later.", "手动输入无需音频权限。之后如切换到语音模式，可在设置中补充授权。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let remote = coordinator.settings.mode == .remote
                if remote {
                    Toggle(b("Include my microphone", "同时收录我的麦克风"), isOn: $coordinator.micEnabled)
                        .disabled(coordinator.isRunning || coordinator.isTransitioning).font(.callout)
                }
                let needsMic = !remote || coordinator.micEnabled
                permissionCard(title: b("Microphone", "麦克风"), icon: "mic",
                               status: needsMic ? microphoneStatus : b("Not needed with microphone off", "麦克风关闭时无需授权"),
                               detail: b("Capture your voice or the room.", "用于收录你的声音或现场对话。"),
                               granted: needsMic && permissions.microphone == .authorized) {
                    if needsMic && permissions.microphone == .notDetermined {
                        Button(b("Allow microphone", "允许麦克风")) { Task { await permissions.requestMicrophone() } }
                            .disabled(permissions.mock || permissions.requestingMicrophone).accessibilityIdentifier("onboarding-request-microphone")
                    } else if needsMic && permissions.microphone != .authorized {
                        Button(b("Open microphone settings", "打开麦克风设置")) { permissions.openSettings(microphone: true) }.disabled(permissions.mock)
                    }
                }
                if remote {
                    permissionCard(title: b("System audio", "系统音频"), icon: "speaker.wave.2",
                                   status: permissions.screenAudio ? b("Allowed", "已允许") : b("Not allowed", "尚未允许"),
                                   detail: b("Hear the other side of the call.", "用于听到远程会议中对方的声音。"), granted: permissions.screenAudio) {
                        if !permissions.screenAudio || permissions.requestedScreenAudio {
                            Text(b("When macOS prompts you to quit, LiveCopilot will close. Reopen LiveCopilot manually from Applications to continue setup.", "按 macOS 提示退出后，LiveCopilot 会关闭。请从「应用程序」手动重新打开 LiveCopilot，继续新手引导。"))
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        if !permissions.screenAudio {
                            HStack {
                                Button(b("Request access", "申请权限")) { permissions.requestScreenAudio() }
                                    .disabled(permissions.mock).accessibilityIdentifier("onboarding-request-screen-audio")
                                Button(b("Open privacy settings", "打开隐私设置")) { permissions.openSettings(microphone: false) }.disabled(permissions.mock)
                            }
                        }
                    }
                }
                Text(b("Granting access does not start recording.", "授权不会立即开始录音。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: LC.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.panel, style: .continuous).strokeBorder(LC.hairline))
    }
    private var microphoneStatus: String {
        switch permissions.microphone {
        case .authorized: return b("Allowed", "已允许")
        case .notDetermined: return b("Not requested", "尚未申请")
        case .denied: return b("Not allowed · open Settings to change", "未允许 · 可前往设置更改")
        case .restricted: return b("Restricted by this Mac's policy", "受此 Mac 的策略限制")
        @unknown default: return b("Unknown · check again", "状态未知 · 请重新检查")
        }
    }
    private func permissionCard<Actions: View>(title: String, icon: String, status: String, detail: String,
                                               granted: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon).font(.callout.weight(.semibold))
                Spacer()
                Text(status).font(.caption.weight(.medium)).foregroundStyle(granted ? LC.success : Color.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            actions().controlSize(.small)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(LC.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous).strokeBorder(LC.hairline))
    }
}
