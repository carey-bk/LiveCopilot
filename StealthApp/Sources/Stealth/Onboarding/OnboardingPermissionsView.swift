import SwiftUI
import AVFoundation

struct OnboardingPermissionsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var permissions: OnboardingPermissions
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.state.prefersTyping {
                Image(systemName: "keyboard").font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
                Text(b("No audio permissions needed", "无需音频权限")).font(.title2.bold())
                Text(b("You can ask by typing. When you later start listening, configure the permissions for that mode.", "直接输入问题即可。以后需要监听时，再配置对应权限。")).foregroundStyle(.secondary)
            } else {
                if coordinator.settings.mode == .remote {
                    Toggle(b("Include my microphone", "同时收录我的麦克风"), isOn: $coordinator.micEnabled)
                        .disabled(coordinator.isRunning || coordinator.isTransitioning)
                }
                if coordinator.settings.mode == .inPerson || coordinator.micEnabled {
                permissionCard(title: b("Microphone", "麦克风"), icon: "mic", status: microphoneStatus,
                               detail: coordinator.settings.mode == .inPerson
                               ? b("Transcribe the room through your microphone. Speakers are not individually identified.", "通过麦克风转写现场对话，不区分具体说话人。")
                               : b("Include your voice in the conversation.", "将你自己的声音加入对话。"),
                               granted: permissions.microphone == .authorized) {
                    if permissions.microphone == .notDetermined {
                        Button(b("Allow microphone", "允许麦克风")) { Task { await permissions.requestMicrophone() } }
                            .disabled(permissions.mock || permissions.requestingMicrophone).accessibilityIdentifier("onboarding-request-microphone")
                    } else if permissions.microphone != .authorized {
                        Button(b("Open microphone settings", "打开麦克风设置")) { permissions.openSettings(microphone: true) }.disabled(permissions.mock)
                    }
                }
                }
                if coordinator.settings.mode == .remote {
                    permissionCard(title: b("Screen & system audio", "屏幕与系统音频"), icon: "speaker.wave.2", status: permissions.screenAudio ? b("Allowed", "已允许") : b("Not allowed", "尚未允许"),
                                   detail: b("Hear the other side of a remote call. macOS groups this access with screen recording; LiveCopilot processes audio only.", "听到远程会议中对方的声音。macOS 将这项访问归入屏幕录制相关权限，LiveCopilot 只处理音频。"),
                                   granted: permissions.screenAudio) {
                        if !permissions.screenAudio {
                            Button(b("Request system audio access", "申请系统音频权限")) { permissions.requestScreenAudio() }
                                .disabled(permissions.mock).accessibilityIdentifier("onboarding-request-screen-audio")
                            Button(b("Open privacy settings", "打开隐私设置")) { permissions.openSettings(microphone: false) }.disabled(permissions.mock)
                        }
                        if permissions.requestedScreenAudio {
                            Text(b("If macOS asks you to reopen the app, quit and reopen it. This guide keeps your place.", "如果 macOS 提示重新打开，请退出再启动应用，引导会保留当前进度。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(b("Check permissions again", "重新检查权限")) { permissions.refresh() }.accessibilityIdentifier("onboarding-refresh-permissions")
                Text(b("If you skip a permission, you can continue with typing and complete setup later.", "暂不授权也可以继续输入问题，之后再补充配置。")).font(.caption).foregroundStyle(.secondary)
                if coordinator.isMock { Text(b("Preview mode does not request system permissions.", "预览模式不会申请系统权限。")).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(4)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(title, systemImage: icon).font(.headline); Spacer(); if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(granted ? Color.green : Color.secondary)
            actions()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}
