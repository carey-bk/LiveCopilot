<div align="center">

# Stealth — an open-source macOS meeting copilot (Cluely-style)

**Real-time meeting transcription + AI reply suggestions, in a screen-share-invisible overlay. Native Swift/SwiftUI, no Electron, no backend.**

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-5.0-orange)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI-brightgreen)](https://developer.apple.com/xcode/swiftui/)
[![AI](https://img.shields.io/badge/OpenAI-Realtime%20API-black)](https://platform.openai.com/docs/guides/realtime)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Status](https://img.shields.io/badge/status-MVP%20working-success)](#status)

</div>

---

Stealth is a **native macOS meeting assistant** ("AI meeting copilot") that listens to both sides of a live call, **live-transcribes** the conversation, and — on a hotkey — suggests a **natural-English reply** you can say out loud. The floating overlay is **invisible to screen recording and screen sharing** (that's the "stealth"), so it never shows up when you share your screen on Zoom, Google Meet, Microsoft Teams, or a native call.

It was built for a **non-native English speaker** taking calls with native Australian/US speakers — but it's useful for anyone who wants a **real-time transcript** and **AI-suggested responses** during meetings, interviews, or sales calls.

> **Comparable to:** Cluely, Otter.ai, Granola, Fireflies.ai — but **open source**, **native (no Electron)**, and **local-first** (audio is streamed straight to OpenAI, never stored on any server).

<!--
Keywords: macOS meeting copilot, Cluely clone, Cluely alternative, open source meeting assistant,
real-time meeting transcription, AI reply suggestions, live transcription macOS, ScreenCaptureKit,
OpenAI Realtime API, gpt-realtime, screen-share invisible overlay, undetectable overlay,
Swift SwiftUI menu bar app, Zoom Google Meet Teams transcription, interview copilot, sales call assistant.
-->

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [Security & privacy](#security--privacy)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [FAQ](#faq)
- [License](#license)

## Features

- 🎙️ **Two-sided live transcription** — your microphone ("You", blue) and the meeting's system audio ("Them", green), each timestamped, in one scrollable transcript.
- 💬 **AI reply suggestions on a hotkey** — press `⌥Space` and Stealth drafts a short, natural spoken reply to the last thing the other person said.
- 🧠 **Recap & follow-up modes** — beyond replies, get a quick catch-up summary or a smart follow-up question to ask.
- 🕶️ **Invisible to screen sharing** — the overlay is an `NSPanel` with `sharingType = .none`, so it's excluded from screen capture/recording. Share your screen freely.
- 🎧 **Acoustic echo cancellation** — speaker audio bleeding into your mic isn't mislabeled as "You".
- 📌 **Menu-bar agent** — no dock icon; a waveform icon lives in your menu bar. Floating overlay works across all Spaces, is draggable and resizable.
- ⌨️ **Global hotkeys** — `⌥Space` to suggest, `⌥H` to show/hide the overlay.
- 🔐 **Key stays in the Keychain** — your OpenAI API key is stored in the macOS Keychain, never on disk or in the repo.
- 🗂️ **Session history** — past meeting transcripts are kept locally so you can review them.
- ⚡ **Native performance** — Swift/SwiftUI + ScreenCaptureKit + AVAudioEngine. No browser, no Electron, no Node.

## How it works

Stealth runs **two independent audio pipelines**, each with its own OpenAI Realtime transcription session, feeding one speaker-labelled transcript:

```
System audio (ScreenCaptureKit)  → RealtimeClient(speaker: .them) ─┐
Microphone   (AVAudioEngine+AEC)  → RealtimeClient(speaker: .you)  ─┤
                                                                    ├→ TranscriptStore (speaker-labelled, timestamped)
[⌥Space hotkey] → systemRealtime.requestSuggestion(context) ───────┴→ SuggestionStore → OverlayView card
```

- Both audio sources are downsampled to **24 kHz mono PCM16** and streamed over WebSocket to the **OpenAI Realtime API** (model `gpt-realtime`, transcription `gpt-4o-transcribe`).
- Only the `.them` client generates **reply suggestions** — it gets a rolling transcript window as context when you press the hotkey.
- The overlay renders the live transcript plus the latest suggestion card.

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for the full technical reference, data flow, and the hard-won gotchas from live bring-up.

## Requirements

| Requirement | Details |
|---|---|
| **macOS** | 14.0 (Sonoma) or newer |
| **Xcode** | 15+ (Swift 5, command-line tools installed) |
| **xcodegen** | `brew install xcodegen` — generates the Xcode project from `project.yml` |
| **OpenAI API key** | With access to the **Realtime API** (`gpt-realtime`) — [platform.openai.com](https://platform.openai.com/api-keys) |
| **Permissions** | Screen & System Audio Recording + Microphone (granted once, on first launch) |

## Quick start

```bash
# 1. Clone
git clone https://github.com/vortechron/stealth.git
cd stealth/StealthApp

# 2. Install the project generator (once)
brew install xcodegen

# 3. (Recommended, once) create a stable local signing identity so macOS keeps
#    your Screen Recording / Microphone permission grants across rebuilds.
sudo ./setup-signing.sh

# 4. Build, sign, install to /Applications, and launch
./run.sh
```

Then:

1. Look for the **waveform icon** in your menu bar (top-right — there's **no dock icon** by design).
2. Open **Settings** from the menu and paste your **OpenAI API key** (it's saved to the Keychain).
3. Click **Start Listening**. macOS will prompt for **Screen Recording** and **Microphone** — grant both. (If a grant seems ignored, quit and relaunch — TCC sometimes needs an app restart.)
4. Join a call and start talking. See [Usage](#usage).

> **Why `setup-signing.sh`?** macOS ties permission grants to an app's code signature. Ad-hoc re-signing changes the signature every build, so grants get orphaned and macOS re-prompts forever. A stable self-signed cert fixes this — grant permissions **once** and they stick across rebuilds. Skip it and the app still runs; you'll just re-approve permissions after each code change.

## Usage

| Action | How |
|---|---|
| **Start / stop listening** | Menu bar → **Start Listening** (prompts for permissions the first time) |
| **Suggest a reply** | `⌥Space` (Option + Space) — drafts a reply to the last thing "Them" said |
| **Show / hide overlay** | `⌥H` (Option + H) |
| **Switch mode** | In the overlay card: **Reply**, **Recap**, or **Follow-up** |
| **Change tone** | Settings → **Professional** / **Casual** |
| **Move / resize overlay** | Drag anywhere; resize from the bottom-right handle |
| **Review past sessions** | Settings → **History** |

The transcript shows **You** (blue) and **Them** (green), each line timestamped `HH:mm`. Transcription is **sentence-chunked**, not word-by-word (that's `gpt-4o-transcribe` behavior).

## Configuration

All tuning knobs live in **[`StealthApp/Sources/Stealth/Support/Config.swift`](StealthApp/Sources/Stealth/Support/Config.swift)**:

| Setting | Default | What it does |
|---|---|---|
| `realtimeModel` | `gpt-realtime` | OpenAI Realtime model (GA — **not** `gpt-4o-realtime-preview`). |
| `realtimeSampleRate` | `24000` | Input audio sample rate (PCM16 mono). |
| `suggestionContextWindow` | `60` s | Rolling transcript window sent as context for a suggestion. |
| `transcriptLineLimit` | `200` | Max transcript lines kept in memory / shown. |
| `micEchoCancellation` | `false` | Apple AEC on the mic. On = less speaker bleed, but can over-suppress a quiet voice. |
| `vadSilenceMs` | `700` | Silence (ms) before a turn is committed → transcribed. Lower fragments speech and clips words. |
| `vadThreshold(for:)` | `.you 0.25` / `.them 0.5` | Voice-activity sensitivity per speaker. **Must be multiples of 0.25/0.5** — the Realtime API rejects floats with >16 decimal places (e.g. `0.3` serializes badly). |
| `suggestionInstructions(...)` | — | The system prompts for Reply / Recap / Follow-up modes. |

After editing, re-run `./run.sh` and confirm the **build number** (shown in the menu bar / overlay footer / settings) matches your latest build.

## Project layout

```
Stealth/
├── README.md                 ← you are here
├── CLAUDE.md                 ← agent/dev context for the codebase
├── docs/ARCHITECTURE.md      ← full technical reference
├── tasks/                    ← working notes (todo, lessons)
└── StealthApp/
    ├── project.yml           ← xcodegen spec (source of truth for the Xcode project)
    ├── run.sh                ← build + sign + install to /Applications + launch
    ├── setup-signing.sh      ← one-time stable signing identity
    ├── Resources/            ← Info.plist, entitlements
    └── Sources/Stealth/
        ├── StealthApp.swift        ← @main, MenuBarExtra + AppDelegate
        ├── Audio/                  ← ScreenCaptureKit + mic capture
        ├── Realtime/               ← OpenAI Realtime WebSocket client
        ├── Stores/                 ← AppCoordinator + transcript/suggestion/session state
        ├── Overlay/                ← the stealth NSPanel + SwiftUI overlay
        ├── Hotkeys/                ← global Carbon hotkeys
        ├── Settings/               ← API key entry, tone, history
        └── Support/                ← Config, Keychain, DebugLog, AppInfo
```

## Troubleshooting

- **Debug log:** `~/Library/Logs/Stealth/stealth.log` — the single most useful diagnostic. `DebugLog` writes here (OSLog wasn't surfacing reliably).
- **Permissions ignored / re-prompting every build:** run `sudo ./setup-signing.sh` once (see [Quick start](#quick-start)), then grant permissions again. After that they stick.
- **"You" side never appears in the transcript:** mic AEC/noise-suppression can over-suppress a quiet voice so VAD never fires. Lower `vadThreshold(.you)` or set `micEchoCancellation = false` in `Config.swift`.
- **Words clipped / dropped mid-sentence:** `vadSilenceMs` too low — raise it (700 ms is the tuned default).
- **Realtime API rejects the session:** don't use floats like `0.3` for VAD thresholds; stick to `0.25`/`0.5` (see the note in `Config.swift`).
- **Build number in the UI doesn't match your changes:** the running app is stale — re-run `./run.sh` and check the footer.

More detail and the full list of first-bring-up gotchas are in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Security & privacy

- 🔑 **Your OpenAI API key is stored in the macOS Keychain**, never written to disk or committed. The repo's `.gitignore` also blocks the local signing key material (`.signing/`, `*.p12`, `*.pem`).
- 📡 **No backend, no server storage.** Audio is streamed directly from your Mac to OpenAI's Realtime API for real-time transcription and is **not stored** by this app. Review [OpenAI's API data-usage policy](https://openai.com/policies/) for how they handle streamed data.
- 🚫 **This is a personal build — do not distribute the built app.** It calls OpenAI directly with your key, so a shared binary would leak it. Hiding the key behind a backend (ephemeral tokens) is [Phase 2](#roadmap).
- ⚖️ **Recording consent:** transcribing a call may require the other participants' consent depending on your jurisdiction. You are responsible for using Stealth lawfully.

## Roadmap

- [ ] **Phase 2 — Laravel backend**: ephemeral OpenAI tokens (hide the API key), auth, meeting history → enables safe distribution.
- [ ] **Auto question-detection** (currently a manual `⌥Space` hotkey).
- [ ] **Live word-by-word transcription** (needs a streaming model; current output is sentence-chunked).
- [ ] **Comprehension layer** — "what are they actually asking?" (currently reply-only).
- [ ] Multi-language support (currently English only, Phase 1).

## Contributing

Contributions welcome. This is currently a **personal MVP**, so please:

1. Open an issue describing the change before large PRs.
2. Read **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** and the **critical gotchas** — several settings look wrong but are deliberate (VAD timing, float precision, Release-only signing).
3. Keep the "locked design decisions" intact unless you're proposing to change one: native Swift (not Electron), direct OpenAI connection for the MVP, Keychain-stored key, manual suggestion hotkey.
4. Build and verify with `./run.sh`; confirm the build number in the UI reflects your change.

## FAQ

**Is Stealth really invisible during screen sharing?**
The overlay uses `NSWindow.sharingType = .none`, which excludes it from ScreenCaptureKit-based capture (Zoom, Meet, Teams, QuickTime, macOS screen recording). Your transcript and suggestions stay private on your screen.

**Does it work with Zoom / Google Meet / Microsoft Teams?**
Yes — it captures **system audio** via ScreenCaptureKit, so it transcribes whatever is playing through your speakers, regardless of the meeting app. Your side comes from the microphone.

**Do I need an OpenAI account?**
Yes. Stealth uses the OpenAI Realtime API and needs your own API key with Realtime access.

**Is there a Windows or web version?**
No. Stealth is macOS-native by design — ScreenCaptureKit and the screen-share-invisible overlay are hard to replicate in web/Electron stacks.

**Why isn't there a signed, downloadable release?**
Because the app talks to OpenAI directly with your key — a distributed binary would leak it. Distribution is gated on the Phase 2 backend.

## License

[MIT](LICENSE) © [vortechron](https://github.com/vortechron)

---

<div align="center">
<sub>Stealth — open-source, native macOS AI meeting copilot. If this helped, ⭐ the repo.</sub>
</div>
