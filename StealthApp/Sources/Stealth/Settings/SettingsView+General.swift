import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            LCSettingsCard(t("Language & appearance"), systemImage: "paintpalette") {
                LCSettingsRow(t("Interface language"), detail: t("Changes apply immediately. Set the answer language separately in the floating panel.")) {
                    Picker(t("Interface language"), selection: $coordinator.settings.language) {
                        Text(t("Follow system")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                        Text("繁體中文").tag(AppLanguage.traditionalChinese)
                    }.labelsHidden().fixedSize().accessibilityIdentifier("interface-language")
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Floating window background"))
                    Picker(t("Floating window background"), selection: $coordinator.settings.background) {
                        ForEach(AppBackground.available) { background in
                            Text(t(background.label)).tag(background)
                        }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("window-background")
                    Text(t(coordinator.settings.background.effective.detail)).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    fontSizeControl(b("Transcript text", "流式识别区字号"), value: $coordinator.settings.transcriptFontSize, identifier: "transcript-font-size",
                                    preview: b("What was your role in this project?", "你在这个项目中具体负责什么？"))
                    fontSizeControl(b("Answer text", "回答区字号"), value: $coordinator.settings.answerFontSize, identifier: "answer-font-size",
                                    preview: b("I would start with the goal, then explain the approach.", "我会先说明目标，再介绍具体的方法。"))
                }
                Text(b("Text sizes are independent and take effect immediately. The window reflows; longer content scrolls.", "两处字号独立保存、即时生效；窗口会重新排版，较长的内容可滚动阅读。")).font(.caption).foregroundStyle(.secondary)
                Divider()
                LCSettingsRow(b("Expanded transcript", "展开转写行数"), detail: b("Collapsed, the transcript shows the latest two lines.", "折叠时显示最新两行。")) {
                    Picker(b("Expanded transcript", "展开转写行数"), selection: $coordinator.settings.transcriptExpandedLines) {
                        ForEach(AppSettings.transcriptExpandedLineChoices, id: \.self) { Text(b("\($0) lines", "\($0) 行")).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("transcript-expanded-lines")
                }
            }
            LCSettingsCard(t("Floating window"), systemImage: "rectangle.righthalf.inset.filled") {
                LCSettingsRow(b("Automatically fit answer height", "回答区自动伸缩"),
                              detail: b("Fit the window to answer content; longer conversations scroll. The voice and input areas stay fixed. Drag vertically to use a manual height.", "窗口随回答内容伸缩，长会话独立滚动；语音区和输入区保持固定。手动拖动高度后改为手动尺寸。")) {
                    LCSwitch(title: b("Automatically fit answer height", "回答区自动伸缩"), isOn: $coordinator.settings.overlayAutoHeight)
                        .accessibilityIdentifier("overlay-auto-height")
                }
                Divider()
                LCSettingsRow(t("Hide the floating window from meeting screen sharing and recording"),
                              detail: t("Keep suggestions visible on your screen while excluding the floating window from capture. Settings and setup remain visible in shared content. Verify the result from another participant before use.")) {
                    LCSwitch(title: t("Hide the floating window from meeting screen sharing and recording"), isOn: $coordinator.settings.excludeOverlayFromCapture)
                        .accessibilityIdentifier("exclude-overlay-capture")
                }
                // Third-party input methods draw their candidate window in their own process, which
                // no app can exclude from capture; the built-in ones show it inside LiveCopilot.
                Label(b("To hide the input method's candidates too, type with a built-in macOS input method. Third-party ones (such as WeChat or Sogou) show their own candidate window, which LiveCopilot cannot hide.",
                        "如需输入法候选框也一并隐藏，请使用系统自带输入法。微信、搜狗等第三方输入法的候选框由输入法自己显示，LiveCopilot 无法隐藏。"),
                      systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("exclude-overlay-capture-input-method")
                if coordinator.settings.excludeOverlayFromCapture, case .failed = coordinator.overlayCaptureProtection {
                    Label(b("Capture protection is unavailable on this system. The floating window may be recorded.",
                            "当前系统未能启用录制保护，悬浮窗可能被录入。"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(LC.warning)
                }
                Divider()
                LCSettingsRow(b("Automatically dock to edge", "自动贴边"),
                              detail: b("When enabled, the window tucks into the right edge and appears on hover. Turn off to drag its header anywhere on your desktop.", "开启后，悬浮窗自动贴靠右侧边缘，悬停时展开。关闭后，可拖动窗口顶部到桌面任意位置。")) {
                    LCSwitch(title: b("Automatically dock to edge", "自动贴边"), isOn: $coordinator.settings.overlayEdgeHide)
                        .accessibilityIdentifier("overlay-edge-hide")
                }
            }
            LCSettingsCard(t("Menu bar"), systemImage: "menubar.rectangle") {
                LCSettingsRow(t("Show LiveCopilot in the menu bar"),
                              detail: t("When hidden, use the Dock icon or {shortcut} to open the floating window. You can turn the menu bar icon back on here.")
                                .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display)) {
                    LCSwitch(title: t("Show LiveCopilot in the menu bar"), isOn: $coordinator.settings.showMenuBarIcon)
                        .accessibilityIdentifier("show-menu-bar-icon")
                }
            }
            LCSettingsCard(b("Audio permissions", "音频权限"), subtitle: b("Granted in System Settings › Privacy & Security.", "在「系统设置 › 隐私与安全性」中授权。"),
                           systemImage: "lock.shield", tone: .warning, status: readiness[.permissions].badge(coordinator.settings.language)) {
                permissionRow(microphone: true)
                Divider()
                permissionRow(microphone: false)
            }
            .onAppear { permissions.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
        }.padding(.bottom, 24)
    }

    /// What each input is used for follows the capture code: remote mode records system audio as Them
    /// and the microphone as You; in-person mode records only the microphone.
    private func permissionRow(microphone: Bool) -> some View {
        let allowed = microphone ? permissions.microphone == .authorized : permissions.screenAudio
        return LCSettingsRow(microphone ? b("Microphone", "麦克风") : b("System audio", "系统音频"),
                             detail: microphone ? b("Your voice in remote meetings; the whole room in person.", "远程会议中录你的声音；现场模式录整个房间。")
                                                : b("The other side in remote meetings. Not used in person.", "远程会议中录对方的声音；现场模式不使用。")) {
            HStack(spacing: 8) {
                LCPill(text: allowed ? b("Allowed", "已允许") : b("Not allowed", "尚未允许"), tone: allowed ? .success : .warning).fixedSize()
                if microphone && permissions.microphone == .notDetermined {
                    Button(b("Request access", "申请权限")) { Task { await permissions.requestMicrophone() } }
                } else if !microphone && !allowed {
                    Button(b("Request access", "申请权限")) { permissions.requestScreenAudio() }
                }
                Button(b("Open settings", "打开系统设置")) { permissions.openSettings(microphone: microphone) }
            }.fixedSize()
        }
    }
}
