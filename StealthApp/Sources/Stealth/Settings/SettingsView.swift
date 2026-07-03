import SwiftUI

/// Minimal settings: paste the OpenAI API key (→ Keychain) and pick the reply tone.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @State private var apiKeyField: String = ""
    @State private var savedFlash = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.hotkeys = coordinator.hotkeys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stealth Settings")
                    .font(.title3.bold())
                Spacer()
                Text(AppInfo.display)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI API Key")
                    .font(.subheadline.weight(.semibold))
                SecureField("sk-…", text: $apiKeyField)
                    .textFieldStyle(.roundedBorder)
                Text(coordinator.hasAPIKey
                     ? "A key is stored in your macOS Keychain."
                     : "No key stored yet. Required to connect.")
                    .font(.caption)
                    .foregroundStyle(coordinator.hasAPIKey ? .green : .secondary)
                HStack {
                    Button("Save Key") {
                        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.save(trimmed)
                        apiKeyField = ""
                        coordinator.refreshKeyState()
                        savedFlash = true
                    }
                    .keyboardShortcut(.defaultAction)

                    if coordinator.hasAPIKey {
                        Button("Clear") {
                            KeychainStore.clear()
                            coordinator.refreshKeyState()
                        }
                    }
                    if savedFlash {
                        Text("Saved ✓").font(.caption).foregroundStyle(.green)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Reply Tone").font(.subheadline.weight(.semibold))
                Picker("", selection: $coordinator.tone) {
                    ForEach(ReplyTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts").font(.subheadline.weight(.semibold))
                ForEach(SuggestionMode.allCases) { mode in
                    HStack {
                        Label(mode.label, systemImage: mode.systemImage)
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                        KeyRecorderView(combo: hotkeys.combo(for: mode)) { combo in
                            coordinator.updateHotkey(combo, for: mode)
                        }
                        .frame(width: 110, height: 22)
                        Button {
                            coordinator.resetHotkey(mode)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to default")
                    }
                }
                Label("⌥H — show / hide overlay (fixed)", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.tertiary)
                Text("Click a field, then press a modifier + key (e.g. ⌥R). Esc cancels.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Text("Stealth captures system audio via Screen Recording. Grant the permission when prompted, then start listening from the menu bar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
