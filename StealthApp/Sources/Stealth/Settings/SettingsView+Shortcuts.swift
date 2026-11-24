import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            LCSettingsCard(t("Floating window"),
                           subtitle: t("{shortcut} shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.")
                               .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display),
                           systemImage: "macwindow") {
                shortcutRow(t("Show / Hide Overlay"), systemImage: "macwindow") {
                    KeyRecorderView(combo: hotkeys.toggleOverlay, language: coordinator.settings.language,
                                    onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                        recordShortcut { coordinator.updateOverlayHotkey(combo) }
                    }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-toggle-overlay")
                    Button(t("Reset")) { recordShortcut { coordinator.resetOverlayHotkey() } }
                        .accessibilityIdentifier("reset-shortcut-toggle-overlay")
                }
            }
            LCSettingsCard(t("Conversation tools"),
                           subtitle: b("Click a shortcut and press a new key combination. Escape cancels; Reset restores its default.", "点击快捷键后按下新的组合键，按 Esc 取消；点击“重置”恢复默认。"),
                           systemImage: "keyboard") {
                ForEach(Array(SuggestionMode.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 { Divider() }
                    let enabled = coordinator.settings.isEnabled(mode)
                    VStack(alignment: .leading, spacing: 4) {
                        shortcutRow(t(mode.label), systemImage: mode.systemImage) {
                            KeyRecorderView(combo: hotkeys.combo(for: mode), language: coordinator.settings.language,
                                            onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                                recordShortcut { coordinator.updateHotkey(combo, for: mode) }
                            }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-" + mode.rawValue)
                            Button(t("Reset")) { recordShortcut { coordinator.resetHotkey(mode) } }
                        }
                        .disabled(!enabled)
                        if !enabled {
                            Button { page = .modesAndScenarios } label: {
                                HStack(spacing: 4) {
                                    Text(t("Enable this tool in Modes & Scenarios to use its shortcut."))
                                    Image(systemName: "arrow.right").font(.caption2.weight(.semibold))
                                }.font(.caption).foregroundStyle(LC.accent)
                            }
                            .buttonStyle(.plain).padding(.leading, 28)
                        }
                    }
                }
            }
            if shortcutConflict {
                Label(b("This shortcut is already assigned to another action. Choose a different combination.", "这个快捷键已用于其他操作，请选择其他组合。"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(LC.danger)
                    .lcCallout(.danger, padding: 12)
                    .accessibilityIdentifier("shortcut-conflict")
            }
        }.padding(.bottom, 24)
    }
    private func shortcutRow<Controls: View>(_ title: String, systemImage: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity, alignment: .leading)
            controls()
        }
    }
    @discardableResult private func recordShortcut(_ update: () -> Bool) -> Bool {
        let accepted = update()
        shortcutConflict = !accepted
        return accepted
    }
}
