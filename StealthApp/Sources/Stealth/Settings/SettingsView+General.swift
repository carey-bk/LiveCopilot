import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(b("Getting started", "新用户引导")).font(.headline)
                    Text(b("Review language, models, services, and permissions. Your existing setup is kept.", "查看语言、模型、服务和权限，保留已有配置。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(b("Open guide", "打开引导")) { coordinator.onOpenOnboarding?() }
                        .accessibilityIdentifier("settings-open-onboarding")
                    Button(b("Show floating window tips", "悬浮窗操作提示")) { coordinator.onShowOverlayTips?() }
                        .accessibilityIdentifier("settings-overlay-tips")
                }.fixedSize(horizontal: true, vertical: false)
            }
            SettingsSection {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(t("Interface language"), selection: $coordinator.settings.language) {
                        Text(t("Follow system")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                        Text("繁體中文").tag(AppLanguage.traditionalChinese)
                    }.accessibilityIdentifier("interface-language")
                    Text(t("Changes apply immediately. Set the answer language separately in the floating panel.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker(t("Floating window background"), selection: $coordinator.settings.background) {
                        ForEach(AppBackground.allCases) { background in
                            Text(t(background.label)).tag(background)
                        }
                    }.pickerStyle(.segmented).accessibilityIdentifier("window-background")
                    Text(t(coordinator.settings.background.detail)).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        fontSizeControl(b("Transcript text", "流式识别区字号"), value: $coordinator.settings.transcriptFontSize, identifier: "transcript-font-size",
                                        preview: b("What was your role in this project?", "你在这个项目中具体负责什么？"))
                        fontSizeControl(b("Answer text", "回答区字号"), value: $coordinator.settings.answerFontSize, identifier: "answer-font-size",
                                        preview: b("I would start with the goal, then explain the approach.", "我会先说明目标，再介绍具体的方法。"))
                    }
                    Text(b("Text sizes are independent and take effect immediately. The window reflows; longer content scrolls.", "两处字号独立保存、即时生效；窗口会重新排版，较长的内容可滚动阅读。")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Language & appearance"), systemImage: "paintpalette") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(b("Automatically fit answer height", "回答区自动伸缩"), isOn: $coordinator.settings.overlayAutoHeight)
                        .accessibilityIdentifier("overlay-auto-height")
                    Text(b("Fit the window to answer content; longer conversations scroll. The voice and input areas stay fixed. Drag vertically to use a manual height.", "窗口随回答内容伸缩，长会话独立滚动；语音区和输入区保持固定。手动拖动高度后改为手动尺寸。")).font(.caption).foregroundStyle(.secondary)
                    Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(t("Hide the floating window from meeting screen sharing and recording"), isOn: $coordinator.settings.excludeOverlayFromCapture)
                    .accessibilityIdentifier("exclude-overlay-capture")
                Text(t("Keep suggestions visible on your screen while excluding the floating window from capture. Settings and setup remain visible in shared content. Verify the result from another participant before use."))
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.settings.excludeOverlayFromCapture {
                    switch coordinator.overlayCaptureProtection {
                    case .failed:
                        Label(b("Capture protection is unavailable on this system. The floating window may be recorded.",
                                "当前系统未能启用录制保护，悬浮窗可能被录入。"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(LC.warning)
                    default: EmptyView()
                    }
                }
            }
                    Divider()
                    Toggle(b("Automatically dock to edge", "自动贴边"), isOn: $coordinator.settings.overlayEdgeHide)
                        .accessibilityIdentifier("overlay-edge-hide")
                    Text(b("When enabled, the window tucks into the right edge and appears on hover. Turn off to drag its header anywhere on your desktop.", "开启后，悬浮窗自动贴靠右侧边缘，悬停时展开。关闭后，可拖动窗口顶部到桌面任意位置。")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Floating window"), systemImage: "rectangle.righthalf.inset.filled") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(t("Show LiveCopilot in the menu bar"), isOn: $coordinator.settings.showMenuBarIcon)
                        .accessibilityIdentifier("show-menu-bar-icon")
                    Text(t("When hidden, use the Dock icon or {shortcut} to open the floating window. You can turn the menu bar icon back on here.")
                        .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Menu bar"), systemImage: "menubar.rectangle") }
            liveSection(b("Audio permissions", "音频权限")) {
                ForEach([true, false], id: \.self) { microphone in
                    HStack {
                        Text(microphone ? b("Microphone", "麦克风") : b("System audio", "系统音频"))
                        let allowed = microphone ? permissions.microphone == .authorized : permissions.screenAudio
                        Text(allowed ? b("Allowed", "已允许") : b("Not allowed", "尚未允许")).foregroundStyle(.secondary)
                        Spacer()
                        if microphone && permissions.microphone == .notDetermined {
                            Button(b("Request access", "申请权限")) { Task { await permissions.requestMicrophone() } }
                        } else if !microphone && !allowed {
                            Button(b("Request access", "申请权限")) { permissions.requestScreenAudio() }
                        }
                        Button(b("Open settings", "打开系统设置")) { permissions.openSettings(microphone: microphone) }
                    }
                }
            }
            .onAppear { permissions.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }

        }.padding(.bottom, 4)
    }
}
