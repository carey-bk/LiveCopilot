# Stealth — Architecture & Developer Reference

This is the technical companion to the [README](../README.md). It covers the data flow, the module map, key design decisions, and the hard-won gotchas from the first live bring-up. **Read the [gotchas](#critical-gotchas) before changing audio, VAD, or signing** — several settings look wrong but are deliberate.

- [Overview](#overview)
- [Data flow](#data-flow)
- [Module map](#module-map)
- [Realtime session schema](#realtime-session-schema)
- [Suggestion pipeline](#suggestion-pipeline)
- [Build & signing](#build--signing)
- [State & concurrency](#state--concurrency)
- [Critical gotchas](#critical-gotchas)
- [Locked design decisions](#locked-design-decisions)

## Overview

Stealth is a **menu-bar macOS agent** (`LSUIElement` — no dock icon) that captures both sides of a call, transcribes them live via the **OpenAI Realtime API**, and suggests spoken replies on a hotkey. It's native **Swift/SwiftUI**, has **no backend**, and stores the API key in the **macOS Keychain**.

Two audio sources each run their own Realtime WebSocket session and feed a single speaker-labelled transcript:

- **System audio** (what the other people say) → `ScreenCaptureKit` → `RealtimeClient(speaker: .them)` — also owns reply suggestions.
- **Microphone** (what you say) → `AVAudioEngine` (+ optional AEC) → `RealtimeClient(speaker: .you)` — transcription only.

## Data flow

```
┌─────────────────────────┐        24kHz PCM16         ┌───────────────────────────────┐
│ AudioCaptureManager     │ ─── onPCM16(Data) ───────▶ │ RealtimeClient(.them)         │
│ (ScreenCaptureKit)      │                            │  • WebSocket → OpenAI Realtime│
└─────────────────────────┘                            │  • transcription + suggestions│
                                                        └───────────────┬───────────────┘
┌─────────────────────────┐        24kHz PCM16                          │ deltas / completed / suggestion
│ MicCaptureManager       │ ─── onPCM16(Data) ───────▶ ┌────────────────┴──────────────┐
│ (AVAudioEngine + AEC)   │                            │ RealtimeClient(.you)          │
└─────────────────────────┘                            │  • transcription only         │
                                                        └───────────────┬───────────────┘
                                                                        │
                              ┌─────────────────────────────────────────┴──────────┐
                              ▼                                                      ▼
                    ┌──────────────────┐   requestSuggestion(context)   ┌────────────────────┐
   ⌥Space  ───────▶ │ AppCoordinator   │ ─────────────────────────────▶ │ SuggestionStore    │
                    │ (wires pipeline) │                                └─────────┬──────────┘
                    └────────┬─────────┘                                          │
                             │ commit / partial                                   │
                             ▼                                                     ▼
                    ┌──────────────────┐                              ┌────────────────────┐
                    │ TranscriptStore  │ ───────────────────────────▶ │ OverlayView        │
                    │ (You/Them lines) │                              │ (NSPanel, stealth) │
                    └────────┬─────────┘                              └────────────────────┘
                             │ on stop
                             ▼
                    ┌──────────────────┐
                    │ SessionStore     │  (local history of past meetings)
                    └──────────────────┘
```

`AppCoordinator` is the **single source of truth** and the wiring hub — it owns the stores, both capture managers, and both Realtime clients, and connects their callbacks.

## Module map

All source lives under `StealthApp/Sources/Stealth/`.

| Path | Responsibility |
|---|---|
| `StealthApp.swift` | `@main`. `MenuBarExtra` + `AppDelegate` (owns the overlay panel, global hotkeys, settings window). |
| **Stores/** | |
| `AppCoordinator.swift` | Pipeline wiring + lifecycle. Owns everything; exposes app state to the UI (`@MainActor ObservableObject`). |
| `TranscriptStore.swift` | `[TranscriptLine{speaker, at, content}]` plus per-speaker streaming partials. Updated immutably. |
| `SuggestionStore.swift` | Latest suggested reply + loading / error state. |
| `SessionStore.swift` / `SessionRecord.swift` | Local history of past listening sessions. |
| **Audio/** | |
| `AudioCaptureManager.swift` | System audio via ScreenCaptureKit → 24 kHz PCM16, emitted via `onPCM16`. |
| `MicCaptureManager.swift` | Mic via AVAudioEngine (+ optional AEC / voice processing) → 24 kHz PCM16. |
| **Realtime/** | |
| `RealtimeClient.swift` | One WebSocket session: connect, configure transcription, stream audio up, surface transcript deltas/completions, and (for the `.them` client) request suggestions. |
| **Overlay/** | |
| `OverlayWindow.swift` | The stealth `NSPanel` — `sharingType = .none`, floating, all Spaces, draggable, resizable. |
| `OverlayView.swift` | SwiftUI: scrollable transcript + suggestion card + resize handle. |
| **Hotkeys/** | |
| `HotkeyManager.swift` | Global Carbon hotkeys. |
| `HotkeyStore.swift` | Persisted per-mode key combos. |
| **Settings/** | |
| `SettingsView.swift` | API key entry + tone toggle + mic toggle. |
| `HistoryView.swift` | Browse saved sessions. |
| `KeyRecorderView.swift` | Record a custom hotkey combo. |
| **Support/** | |
| `Config.swift` | All tuning knobs (model, sample rate, VAD, limits, prompts). Start here to tune behavior. |
| `KeychainStore.swift` | OpenAI key in the macOS Keychain (never on disk). |
| `AppInfo.swift` | Reads version/build from the bundle (the build number shown in the UI). |
| `DebugLog.swift` | File logger → `~/Library/Logs/Stealth/stealth.log`. |

## Realtime session schema

The OpenAI Realtime API is **GA** — this trips people up. The session config is **nested**, and the model/header names differ from the old preview:

```jsonc
// session.update  (GA schema — note the nesting)
{
  "session": {
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": { "model": "gpt-4o-transcribe" },
        "turn_detection": {
          "type": "server_vad",
          "silence_duration_ms": 700,
          "prefix_padding_ms": 500,
          "threshold": 0.25,          // per-speaker; see Config.vadThreshold
          "create_response": false     // auto-commit (→ transcription) but never auto-reply
        }
      }
    },
    "output_modalities": ["text"]      // GA name — NOT "modalities"
  }
}
```

- Model in the URL: `wss://api.openai.com/v1/realtime?model=gpt-realtime` — **not** `gpt-4o-realtime-preview`.
- **No** `OpenAI-Beta: realtime=v1` header (that was the beta).
- Text deltas arrive as `response.output_text.delta`.
- Transcription completions arrive as input-audio transcription events; on completion the coordinator `clearPartial(speaker)` then `commit(line, speaker)`.

## Suggestion pipeline

Only the `.them` client (`handlesSuggestions: true`) generates suggestions.

1. User presses a hotkey (`⌥Space` for Reply; other combos for Recap / Follow-up).
2. `AppCoordinator` calls `systemRealtime.requestSuggestion(context:)` with a rolling transcript window (`Config.suggestionContextWindow`, default 60 s).
3. The client sends a `response.create` with `instructions` from `Config.suggestionInstructions(mode:tone:)` and tracks the response id (`pendingSuggestionResponseID`) so suggestion output isn't confused with background activity.
4. Text deltas stream into `SuggestionStore`; the overlay card renders them live.

Modes (`SuggestionMode`): **reply**, **recap**, **followUp**. Tone (`ReplyTone`): **professional**, **casual**.

## Build & signing

- **`run.sh`** stamps a fresh build number (`YYYYMMDD.HHMM` in `CFBundleVersion`), runs `xcodegen generate`, builds **Release**, installs to `/Applications/Stealth.app` (a stable path), signs inside-out, and launches. The build number is visible in the menu bar / overlay footer / settings — use it to confirm the running app is your latest code.
- **`setup-signing.sh`** (run once, with `sudo`) creates a self-signed **"Stealth Local Signing"** identity in the login keychain, trusted for code signing. Why: macOS TCC keys permission grants to the code signature (cdhash). Ad-hoc signing changes the cdhash every build → grants orphaned → endless re-prompts. A stable cert fixes this.
- **Release, not Debug:** Debug produces a separate `Stealth.debug.dylib`, which breaks re-signing with the custom identity. Release links a single binary.
- **App Sandbox is OFF** for the MVP (`Resources/Stealth.entitlements`: network client + audio input only). Unsandboxed is the most reliable combo for ScreenCaptureKit system-audio + a raw WebSocket in a personal build. Re-enable the sandbox in Phase 2 for distribution.

The Xcode project (`Stealth.xcodeproj`) is **generated** from `project.yml` and is `.gitignore`d — always regenerate with `xcodegen generate` (or just run `./run.sh`).

## State & concurrency

- `AppCoordinator`, `TranscriptStore`, `SuggestionStore`, and `RealtimeClient` are all `@MainActor` `ObservableObject`s. UI state mutations happen on the main actor.
- Audio capture callbacks (`onPCM16`) fire off the main thread; the coordinator hops back to `@MainActor` before touching a Realtime client.
- Stores follow the repo's **immutability** rule — new arrays/values, no in-place mutation of published state.

## Critical gotchas

These were all hit during the first live bring-up. **Don't regress them.**

1. **Realtime API is GA, not beta.** Model `gpt-realtime`; no `OpenAI-Beta` header; nested `session.audio.input.*` schema; `output_modalities` (not `modalities`); text deltas as `response.output_text.delta`.
2. **"Socket is not connected" had two causes:** (a) calling `receive()` before the WS opened — start the receive loop only from `didOpenWithProtocol`; (b) with VAD disabled the audio buffer was never committed, so the server closed the idle socket (~30 s). Fix: `server_vad` with `create_response: false` — auto-commits (→ transcription fires) but never auto-replies. On intentional `disconnect()`, an `isClosing` flag suppresses the expected receive failure.
3. **VAD silence = 700 ms** (`Config.vadSilenceMs`). At 200 ms ("snappy") natural sub-second pauses between words triggered mid-sentence commits and **clipped/dropped boundary words**. 700 ms waits for a real sentence pause; `prefix_padding_ms = 500` keeps the lead-in so the first word isn't clipped. Transcription is **sentence-chunked, not word-by-word** — that's `gpt-4o-transcribe` behavior. True live word streaming needs a different model.
4. **VAD threshold floats must be exactly representable.** `JSONSerialization` prints `0.3` as `0.29999999999999999` (17 dp) and the Realtime API rejects >16 dp. Use multiples of `0.25`/`0.5` only. Mic side runs at `0.25` (AEC lowers your post-processed voice level, so a higher threshold never fires `speech_stopped` → "You side doesn't appear"); system side at `0.5` to avoid latching onto background noise.
5. **Echo:** speaker output bleeds into the mic and gets labeled "You". Mitigated by mic AEC (`micEchoCancellation`), but AEC can over-suppress a quiet voice → "You" captures silence and VAD never fires. Trade-off tuned via `micEchoCancellation` + `vadThreshold(.you)`; a mic-disable toggle also exists.
6. **Don't double-commit transcript lines.** On `transcription.completed`: `clearPartial(speaker)` **then** `commit(line)`. Committing the partial too duplicates the line.

## Locked design decisions

- **Native Swift/SwiftUI, not Electron** — ScreenCaptureKit + a screen-share-invisible overlay are hard in web stacks.
- **No backend for the MVP** — the app calls OpenAI directly. A Laravel backend (ephemeral tokens to hide the key) is Phase 2 and is the prerequisite for distribution.
- **OpenAI Realtime API (GA)** over WebSocket. Model `gpt-realtime`; transcription `gpt-4o-transcribe`.
- **API key in the Keychain**, direct connection. **Personal build — never distribute** (the key would leak).
- **Manual suggestion hotkey** (`⌥Space`), not auto question-detection. `⌥H` toggles the overlay.
- **Two-sided transcript**: mic (You, blue) + system (Them, green), each timestamped `HH:mm`.

---

See also: [README](../README.md) · [`Config.swift`](../StealthApp/Sources/Stealth/Support/Config.swift) · [`CLAUDE.md`](../CLAUDE.md)
