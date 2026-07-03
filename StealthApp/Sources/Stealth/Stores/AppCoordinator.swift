import Foundation
import Combine
import SwiftUI

/// Wires the pipeline together and exposes high-level app state to the UI.
///
/// Two audio sources, each with its own Realtime transcription session:
///   • system audio → `systemRealtime` (speaker = Them) — also owns reply suggestions
///   • microphone   → `micRealtime`    (speaker = You)  — transcription only
@MainActor
final class AppCoordinator: ObservableObject {
    let transcript = TranscriptStore()
    let suggestion = SuggestionStore()
    let sessions = SessionStore()
    let hotkeys = HotkeyStore()

    let systemAudio = AudioCaptureManager()
    let mic = MicCaptureManager()

    let systemRealtime = RealtimeClient(speaker: .them, handlesSuggestions: true)
    let micRealtime = RealtimeClient(speaker: .you, handlesSuggestions: false)

    @Published var isRunning = false
    @Published var hasAPIKey: Bool = KeychainStore.load() != nil
    @Published var statusMessage: String = "Idle"

    /// Whether the user's mic is captured. Off = "Them" only (no speaker bleed
    /// being double-transcribed as "You"; also useful on speakerphone). Persists
    /// across sessions and can be toggled live while listening.
    @Published var micEnabled: Bool = UserDefaults.standard.object(forKey: "micEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(micEnabled, forKey: "micEnabled") }
    }

    /// When the current listening session began (for the saved history record).
    private var sessionStartedAt: Date?

    /// Set by the AppDelegate so Settings can rebind global hotkeys live.
    var onHotkeysChanged: (() -> Void)?

    /// Persist a new shortcut for a mode and re-register the global hotkeys.
    func updateHotkey(_ combo: HotkeyCombo, for mode: SuggestionMode) {
        hotkeys.set(combo, for: mode)
        onHotkeysChanged?()
    }

    func resetHotkey(_ mode: SuggestionMode) {
        hotkeys.reset(mode)
        onHotkeysChanged?()
    }
    @Published var tone: ReplyTone = .professional {
        didSet { systemRealtime.setTone(tone) }
    }

    init() {
        wire()
    }

    private func wire() {
        // System audio → "them" transcription session.
        systemAudio.onPCM16 = { [weak self] data in
            Task { @MainActor in self?.systemRealtime.sendAudio(data) }
        }
        // Microphone → "you" transcription session.
        mic.onPCM16 = { [weak self] data in
            Task { @MainActor in self?.micRealtime.sendAudio(data) }
        }

        for client in [systemRealtime, micRealtime] {
            client.onTranscriptDelta = { [weak self] delta, speaker in
                self?.transcript.appendDelta(delta, speaker: speaker)
            }
            client.onTranscriptCompleted = { [weak self] line, speaker in
                // Commit the authoritative final line and DROP the streamed partial
                // (committing the partial too would duplicate the line).
                self?.transcript.clearPartial(speaker)
                self?.transcript.commit(line, speaker: speaker)
            }
            client.onError = { [weak self] message in
                self?.statusMessage = "Error: \(message)"
            }
        }

        // Only the system (them) client streams reply suggestions.
        systemRealtime.onSuggestionDelta = { [weak self] delta in
            self?.suggestion.appendDelta(delta)
        }
        systemRealtime.onSuggestionDone = { [weak self] in
            self?.suggestion.finish()
        }
        systemRealtime.onError = { [weak self] message in
            self?.statusMessage = "Error: \(message)"
            self?.suggestion.fail(message)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        hasAPIKey = KeychainStore.load() != nil
        guard hasAPIKey else {
            statusMessage = "No API key — open Settings."
            return
        }
        statusMessage = "Connecting…"
        sessionStartedAt = Date()
        systemRealtime.setTone(tone)
        systemRealtime.connect()
        if micEnabled { micRealtime.connect() }

        await systemAudio.start()
        if let err = systemAudio.lastError {
            statusMessage = err
            return
        }
        if micEnabled {
            mic.start()   // mic failure is non-fatal — system audio still works
        }

        isRunning = true
        statusMessage = mic.isCapturing ? "Listening (you + them)" : "Listening (them only)"
    }

    /// Turn the user's mic on/off, live if a session is running. Disconnecting the
    /// "You" realtime session when muted avoids an idle socket and stray state.
    func toggleMic() {
        micEnabled.toggle()
        guard isRunning else { return }
        if micEnabled {
            micRealtime.connect()
            mic.start()
        } else {
            mic.stop()
            micRealtime.disconnect()
            transcript.clearPartial(.you)
        }
        statusMessage = mic.isCapturing ? "Listening (you + them)" : "Listening (them only)"
    }

    func stop() async {
        await systemAudio.stop()
        mic.stop()
        systemRealtime.disconnect()
        micRealtime.disconnect()
        isRunning = false

        // Archive this session's transcript, then clear the live view.
        if let startedAt = sessionStartedAt {
            let saved = sessions.save(lines: transcript.lines, startedAt: startedAt)
            statusMessage = saved != nil ? "Saved to history" : "Stopped"
        } else {
            statusMessage = "Stopped"
        }
        sessionStartedAt = nil
        transcript.clear()
        suggestion.reset()
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    // MARK: - Hotkey actions

    /// Triggered by a global hotkey or an overlay button. `mode` selects reply,
    /// recap, or follow-up; all render into the same suggestion card.
    func requestSuggestion(mode: SuggestionMode = .reply) {
        guard isRunning else {
            statusMessage = "Start listening first (menu bar)."
            return
        }
        suggestion.begin(mode: mode)
        systemRealtime.requestSuggestion(context: transcript.recentContext(), mode: mode)
    }

    func refreshKeyState() {
        hasAPIKey = KeychainStore.load() != nil
    }
}
