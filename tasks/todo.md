> Historical Stealth checklist retained for reference. Current LiveCopilot scope/progress is in [IMPLEMENTATION_PLAN](../docs/IMPLEMENTATION_PLAN.md); this list is not the V1 acceptance authority.

# Stealth — 4 features

## 1. Fix: "You" (mic) transcript not appearing
Symptom: mic audio reaches OpenAI (`sendAudio OK` on You session) but no `transcription.completed` for You.
Root-cause hypotheses (diagnose first, log is not speaker-tagged):
- [ ] Tag every `EVENT:` log with `[speaker]` (RealtimeClient.handleEvent) so You vs Them is visible.
- [ ] Verify mic session reaches `session.updated` → `.connected`. If mic never connects, audio drops silently (guard at top of `sendAudio`). Log shows `MIC ... sendAudio OK` though → state IS connected. So session configured but no completion.
- [ ] Likely cause: server VAD never fires `speech_stopped` on mic side because **AEC over-suppresses** your own voice OR mic gain too low. Fix path: lower mic VAD `threshold` (0.5→~0.3) on the You session only, OR raise mic level. Make threshold per-speaker via Config.
- [ ] Fallback safety net: if VAD silent, the buffer never commits. Add nothing auto — but confirm with new logs after threshold drop.
- [ ] Verify live: speak, confirm `[You] EVENT: input_audio_buffer.speech_stopped` + `...transcription.completed` appear in log and line shows blue in overlay.

## 2. In-overlay button row + adjustable shortcut (record-a-keystroke)
- [ ] `Config`: add 3 suggestion *modes*: `.reply`, `.recap`, `.followUp`, each with own instructions.
- [ ] `RealtimeClient.requestSuggestion(context:mode:)` — pick instructions by mode.
- [ ] `AppCoordinator.requestSuggestion(mode:)` — default `.reply`.
- [ ] OverlayView: add compact 3-button row (Reply / Recap / Follow-up) above/below suggestion card. Disabled when not running.
- [ ] New `HotkeyStore` (persisted in UserDefaults): keyCode+modifiers for the suggest action. Defaults ⌥Space.
- [ ] `HotkeyManager.register` reads from HotkeyStore; add `reregisterSuggest()` to rebind live.
- [ ] SettingsView: "Suggest Reply Shortcut" record field — `KeyRecorderView` (NSView via NSViewRepresentable) capturing next keyDown (keyCode+modifierFlags), saves to HotkeyStore, calls reregister. Show current combo as glyphs.
- [ ] ⌥H (toggle overlay) stays fixed (not adjustable per scope).

## 3. Recap + Follow-up buttons (covered by #2 modes)
- [ ] Recap prompt: 2–3 line summary of what's been said so far (both speakers).
- [ ] Follow-up prompt: ONE smart follow-up question the user could ask next.
- [ ] Both render into the same suggestion card (reuse SuggestionStore). Card header label reflects last mode.

## 4. Session history on Stop
- [ ] `SessionRecord` model: id, startedAt, endedAt, [TranscriptLine]. Codable.
- [ ] `SessionStore`: save to `~/Library/Application Support/Stealth/sessions/<id>.json`; list/load/delete. Loads index on launch.
- [ ] `AppCoordinator.stop()`: snapshot transcript.lines → SessionStore.save (skip if empty). Then transcript.clear().
- [ ] History window: list past sessions (date, line count, duration) → detail = full speaker-labelled transcript, copyable. Delete button.
- [ ] Menu bar: "History…" item opens window (like Settings).

## Build / verify
- [ ] New files land under `Sources/` → picked up by XcodeGen on `./run.sh`. No project.yml edits.
- [ ] `./run.sh` builds Release, signs, installs, launches. Confirm build number bump in UI.
- [ ] Manual: start → speak (You appears) → others talk (Them) → Reply/Recap/Follow-up each produce text → custom shortcut works → Stop → open History → session present with transcript.

## Notes / immutability
- Keep stores immutable-update style (already do `lines = next`).
- Many small files: SessionRecord, SessionStore, HistoryView, HotkeyStore, KeyRecorderView, SuggestionMode separate.

## Decisions (answered)
1. All 3 actions (Reply/Recap/Follow-up) get adjustable global hotkeys.
2. History kept forever, manual delete.

## Review (done — build 20260630.2316, BUILD SUCCEEDED, running)
- Mic fix: per-speaker VAD threshold (You=0.3, Them=0.5) so AEC-attenuated voice still trips VAD; event logs now `[You]`/`[Them]` tagged for diagnosis. **Needs live confirm.**
- Modes: Config.SuggestionMode (reply/recap/followUp) + per-mode prompts; RealtimeClient.requestSuggestion(context:mode:); Coordinator.requestSuggestion(mode:).
- Overlay: 3-button action row; suggestion card shows mode header; placeholder updated.
- Hotkeys: HotkeyStore (UserDefaults) + HotkeyManager store-driven w/ live reload; KeyRecorderView (NSViewRepresentable) record field in Settings; ⌥H fixed.
- History: SessionRecord/SessionLine (Codable), SessionStore (JSON in App Support), HistoryView (master-detail, copy/delete), "History…" menu item; saved on stop() then transcript cleared.

## Still to verify live (user)
- Speak → blue "You" line appears (the original bug).
- Reply/Recap/Follow-up buttons each produce text.
- Settings → record a new shortcut → it fires globally.
- Stop → History window shows the session w/ full transcript.
