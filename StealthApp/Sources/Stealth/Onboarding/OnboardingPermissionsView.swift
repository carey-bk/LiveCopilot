import SwiftUI
import AVFoundation

struct OnboardingPermissionsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: OnboardingStore
    @ObservedObject var permissions: OnboardingPermissions
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var needsSystemAudio: Bool { !store.state.prefersTyping && coordinator.settings.mode == .remote }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.state.prefersTyping {
                Label(b("Typing needs no audio access", "输入问题无需音频权限"), systemImage: "keyboard").font(.headline)
                Text(b("You can prepare system audio now for remote calls, or skip it until you start listening.", "可以提前准备远程会议所需的系统音频权限，也可以等需要监听时再设置。"))
                    .font(.callout).foregroundStyle(.secondary)
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
            }
            permissionCard(title: b("System audio permission", "系统音频权限"), icon: "speaker.wave.2",
                           status: permissions.screenAudio ? b("Allowed", "已允许") : b("Not allowed", "尚未允许"),
                           detail: b("Hear the other side of a remote call. In macOS, allow LiveCopilot under Screen & System Audio Recording; only audio is processed.", "用于听到远程会议中对方的声音。请在 macOS“屏幕与系统音频录制”中允许 LiveCopilot；应用只处理音频。"),
                           granted: permissions.screenAudio) {
                Text(needsSystemAudio
                     ? b("Required for your remote meeting mode", "当前远程会议模式需要此权限")
                     : b("Optional now · needed only for remote meeting audio", "当前可跳过 · 仅远程会议音频需要"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if !permissions.screenAudio {
                    HStack {
                        Button(b("Request system audio access", "申请系统音频权限")) { permissions.requestScreenAudio() }
                            .disabled(permissions.mock).accessibilityIdentifier("onboarding-request-screen-audio")
                        Button(b("Open privacy settings", "打开隐私设置")) { permissions.openSettings(microphone: false) }.disabled(permissions.mock)
                    }
                }
                if permissions.requestedScreenAudio {
                    Text(b("If macOS asks you to reopen the app, quit and reopen it. This guide keeps your place.", "如果 macOS 提示重新打开，请退出再启动应用，引导会保留当前进度。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(b("Check permissions again", "重新检查权限")) { permissions.refresh() }.accessibilityIdentifier("onboarding-refresh-permissions")
            Text(b("If you skip a permission, you can continue with typing and complete setup later.", "暂不授权也可以继续输入问题，之后再补充配置。"))
                .font(.caption).foregroundStyle(.secondary)
            if coordinator.isMock { Text(b("Preview mode does not request system permissions.", "预览模式不会申请系统权限。"))
                    .font(.caption).foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack { Label(title, systemImage: icon).font(.headline); Spacer(); if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(granted ? Color.green : Color.secondary)
            actions()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}
