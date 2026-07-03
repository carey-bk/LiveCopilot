# Stealth

Native macOS **Cluely clone** — a meeting copilot. Captures meeting audio, live-transcribes both sides, and on a hotkey suggests a natural-English reply. Built for a non-native English speaker on calls with Australian/US speakers.

**Status:** MVP working end-to-end (confirmed live). English only, Phase 1.

## Run / build

```bash
cd StealthApp
sudo ./setup-signing.sh   # ONCE only — creates stable signing cert (see Signing below)
./run.sh                  # build + sign + install to /Applications + launch
```

`run.sh` stamps a fresh build number (`YYYYMMDD.HHMM` in `CFBundleVersion`), regenerates the Xcode project, builds **Release**, signs, installs to `/Applications/Stealth.app`, and launches. The build number shows in the UI (menu bar, overlay footer, settings) — use it to confirm the running app reflects your latest code.

- **App is a menu-bar agent** (`LSUIElement`) — no dock icon. Look for the waveform icon top-right.
- **Debug log:** `~/Library/Logs/Stealth/stealth.log` (OSLog wasn't surfacing reliably; `DebugLog` writes here — invaluable for diagnosis).

## Architecture

Two audio sources, each with its own OpenAI Realtime transcription session:

```
System audio (ScreenCaptureKit)  → RealtimeClient(speaker: .them) ─┐
Microphone   (AVAudioEngine+AEC)  → RealtimeClient(speaker: .you)  ─┤
                                                                    ├→ TranscriptStore (speaker-labelled, timestamped)
[⌥Space hotkey] → systemRealtime.requestSuggestion(context) ───────┴→ SuggestionStore → OverlayView card
```

- `AppCoordinator` (`Sources/Stealth/Stores/`) wires everything; the single source of truth for app state.
- `RealtimeClient` is **per-speaker**; only the `.them` client (`handlesSuggestions: true`) generates reply suggestions.
- Mic uses **acoustic echo cancellation** (`setVoiceProcessingEnabled(true)`) so speaker audio bleeding into the mic isn't mislabeled "You".
- Overlay is an `NSPanel` with `sharingType = .none` → **invisible to screen capture/sharing** (the "stealth"). Floating, all Spaces, draggable, resizable (bottom-right handle).

### File map
- `Support/Config.swift` — all tuning knobs (model, sample rate, VAD ms, limits, prompt).
- `Support/KeychainStore.swift` — OpenAI key in macOS Keychain (never on disk).
- `Support/AppInfo.swift` — reads version/build from bundle.
- `Support/DebugLog.swift` — file logger.
- `Audio/AudioCaptureManager.swift` — system audio via ScreenCaptureKit → 24kHz PCM16.
- `Audio/MicCaptureManager.swift` — mic via AVAudioEngine + AEC → 24kHz PCM16.
- `Realtime/RealtimeClient.swift` — one WebSocket session (transcription + optional suggestions).
- `Stores/TranscriptStore.swift` — `[TranscriptLine{speaker,at,content}]` + per-speaker partials.
- `Stores/SuggestionStore.swift` — latest suggested reply + loading/error.
- `Stores/AppCoordinator.swift` — pipeline wiring + lifecycle.
- `Overlay/OverlayWindow.swift` — the stealth NSPanel.
- `Overlay/OverlayView.swift` — SwiftUI: scrollable transcript + suggestion card + resize handle.
- `Hotkeys/HotkeyManager.swift` — global Carbon hotkeys.
- `Settings/SettingsView.swift` — API key entry + tone toggle.
- `StealthApp.swift` — `@main`, MenuBarExtra + AppDelegate (owns overlay, hotkeys, settings window).

## Locked design decisions

- **Native Swift/SwiftUI**, NOT Electron (ScreenCaptureKit + stealth overlay are hard in web stacks).
- **No backend** — app calls OpenAI directly. Laravel + Laravel Boost deferred to Phase 2 (needed for hiding the API key when distributing).
- **OpenAI Realtime API (GA)** over WebSocket. Model `gpt-realtime`. Transcription model `gpt-4o-transcribe`.
- **API key in Keychain**, direct connection. **This is a personal build — never distribute it** (the key would leak).
- **Manual hotkey** for suggestions (⌥Space), not auto question-detection. ⌥H = show/hide overlay.
- **Two-sided transcript**: mic (You, blue) + system (Them, green), each timestamped (HH:mm).

## Critical gotchas (all hit during first live bring-up — don't regress these)

1. **Realtime API is GA, not beta.** Model `gpt-realtime` (NOT `gpt-4o-realtime-preview`). NO `OpenAI-Beta` header. Session schema is nested: `session.audio.input.{format:{type:"audio/pcm",rate:24000}, transcription, turn_detection}`. Response uses `output_modalities` (not `modalities`). Text deltas arrive as `response.output_text.delta`.
2. **"Socket is not connected" had two causes:** (a) calling `receive()` before the WS opens → start the receive loop only from `didOpenWithProtocol`; (b) VAD disabled meant the audio buffer was never committed, so the server closed the idle socket (~30s). Fix: `server_vad` with `create_response: false` — auto-commits (→ transcription fires) but never auto-replies. On intentional `disconnect()`, an `isClosing` flag suppresses the expected receive failure.
3. **VAD silence = 700ms** (`Config.vadSilenceMs`). Was 200ms ("snappy"), but that fragmented continuous speech — natural sub-second pauses between words triggered mid-sentence commits and **clipped/dropped boundary words** (seen on YouTube/system audio). 700ms waits for a real sentence pause; `prefix_padding_ms = 500` keeps lead-in so the first word isn't clipped. Transcription is still **sentence-chunked, not word-by-word** — that's `gpt-4o-transcribe` behavior. True live word streaming needs a different model.
4. **Echo:** speaker output bleeds into the mic and gets labeled "You". Mitigated by mic AEC. Residual leakage may still occur with loud speakers — options: raise mic VAD threshold, or add a mic-mute toggle.
5. **Don't double-commit transcript lines.** On `transcription.completed`, `clearPartial(speaker)` then `commit(line)` — committing the partial too duplicates the line.

## Signing (why permissions used to keep resetting)

macOS ties Screen Recording / Microphone TCC grants to the app's **code signature (cdhash)**. Ad-hoc re-signing changes the cdhash every build → grant orphaned → re-prompts forever. Fixed with a **stable self-signed cert** "Stealth Local Signing" (login keychain, trusted for codeSign) created by `setup-signing.sh`, plus install to a fixed `/Applications` path and **Release** config (single binary — Debug's separate `Stealth.debug.dylib` broke re-signing). Grant Screen Recording + Microphone **once** and it sticks across rebuilds.

App Sandbox is **OFF** for the MVP (entitlements in `Resources/Stealth.entitlements`: network client, audio input). Re-enable sandbox in Phase 2 for distribution.

## Permissions required (granted once)

- **Screen & System Audio Recording** — ScreenCaptureKit needs it even for audio-only.
- **Microphone** — for the "You" transcript side.

Both prompt the first time you click **Start Listening**. If a grant seems ignored, quit + relaunch (TCC sometimes needs an app restart).

## Roadmap (next phases)

- Phase 2: Laravel backend (hide API key via ephemeral tokens, meeting history, auth) → enables distribution.
- Auto question-detection (currently manual hotkey only).
- Live word-by-word transcription (streaming model).
- Comprehension/"what they're asking" layer (currently reply-only).
