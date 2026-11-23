import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            LCSectionHeader(t("Global shortcuts"), systemImage: "keyboard")
            HStack {
                Label(t("Show / Hide Overlay"), systemImage: "macwindow").frame(width: 160, alignment: .leading)
                KeyRecorderView(combo: hotkeys.toggleOverlay, language: coordinator.settings.language,
                                onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                    recordShortcut { coordinator.updateOverlayHotkey(combo) }
                }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-toggle-overlay")
                Button(t("Reset")) { recordShortcut { coordinator.resetOverlayHotkey() } }
                    .accessibilityIdentifier("reset-shortcut-toggle-overlay")
            }
            Divider()
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(t(mode.label), systemImage: mode.systemImage).frame(width: 160, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode), language: coordinator.settings.language,
                                    onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                        recordShortcut { coordinator.updateHotkey(combo, for: mode) }
                    }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-" + mode.rawValue)
                    Button(t("Reset")) { recordShortcut { coordinator.resetHotkey(mode) } }
                }.disabled(!coordinator.settings.isEnabled(mode))
                if !coordinator.settings.isEnabled(mode) {
                    Text(t("Enable this tool in Modes & Scenarios to use its shortcut.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if shortcutConflict {
                Text(b("This shortcut is already assigned to another action. Choose a different combination.", "这个快捷键已用于其他操作，请选择其他组合。"))
                    .font(.caption).foregroundStyle(LC.danger).accessibilityIdentifier("shortcut-conflict")
            }
            Text(b("Click a shortcut and press a new key combination. Escape cancels; Reset restores its default.", "点击快捷键后按下新的组合键，按 Esc 取消；点击“重置”恢复默认。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("{shortcut} shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.")
                .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display)).font(.caption).foregroundStyle(.secondary)
        }.lcCard().padding(.bottom, 24)
    }
    @discardableResult private func recordShortcut(_ update: () -> Bool) -> Bool {
        let accepted = update()
        shortcutConflict = !accepted
        return accepted
    }
}
