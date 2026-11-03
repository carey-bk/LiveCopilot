# Agent handoff — high-value fixes (claude/high-value-fixes)

Base: `83a76dd`. Worktree: `/Users/careyzhang/Documents/Claude Code Project/Dev-LiveCopilot`. Nothing pushed, merged, versioned, signed or installed.

## 1. Silent app termination when a local worker exits (crash) — fixed, mechanism reproduced

**Problem.** `LocalInferenceWorker` (Paraformer/Zipformer ASR and BGE-M3 embedding) wrote requests to the child's stdin without `F_SETNOSIGPIPE`, and the app does not ignore `SIGPIPE`. If the worker has exited, or is terminated by `close()`/timeout, while the app writes, the kernel delivers `SIGPIPE` and the **whole app terminates with no `.ips` report** (SIGPIPE is not a crash-report signal). `LayaWorker` already set `F_SETNOSIGPIPE`; this worker did not.

**Reproduction.** `Tests/CoreChecks.swift` → "writing to an exited local worker…": a fake worker closes stdin, reports ready, and stays alive; the next `call` writes 32 KB. Before the fix `scripts/test-core.sh` exited with status **141 (128 + SIGPIPE)** and printed no FAIL line. A standalone probe of Foundation `Process` + `Pipe` (scratch only) showed the same 141 and confirmed Foundation closes the parent's copies of the child ends (EOF is observable; a dead reader means EPIPE/SIGPIPE).

**Fix.** `Providers/LocalInferenceWorker.swift`: set `F_SETNOSIGPIPE` on the stdin pipe after launch; a failed write is classified `process_ended`, recorded through the existing `workerFailure` diagnostic, and surfaces the existing "Local model stopped unexpectedly…" error. Listening then stops through the existing `LocalLiveProvider.fail()` path.

**Link to user reports.** Realistic triggers include `LocalLiveProvider` overflow/failure calling `worker.close()` while a 0.5 s audio request is being written, a worker dying between requests, and closing the embedding worker during indexing. That one of these caused the reported crashes is **not confirmed**: no user `.ips`/journal is available, and an absence of `.ips` is consistent with, but not proof of, SIGPIPE.

## 2. Microphone stops after a device reconfiguration ("no sound") — changed, not hardware-verified

**Problem.** `MicCaptureManager` handled `AVAudioEngineConfigurationChange` by stopping capture and asking the user to restart. AVAudioEngine stops itself whenever input/output hardware format changes, which includes Bluetooth headsets switching profile when their microphone opens and default-device changes. In-Person mode then ends listening; Remote mode silently loses the You side.

**Fix.** Start logic is factored into `startEngine()`. On a configuration change the tap is removed and the engine restarted with the newly read input format (bounded to 3 recoveries per 30 s). If recovery fails or the bound is exceeded, behavior is the previous stop + existing localized message. Journal: `micDeviceChanged` → `micReady` (recovered, now with sample rate/channels) or → `micStopped`.

**Evidence boundary.** Code reading and Apple's documented engine behavior only. No Bluetooth/device-switch test was run (no hardware session); this needs an interactive check: start In-Person with AirPods, confirm transcripts continue and the journal shows `micDeviceChanged` then `micReady`.

## 3. Diagnostics could not tell "no audio" from "silence" from "no recognition" — added

`Core/AudioFlowMonitor.swift` keeps content-free counters per source (updated on the capture thread under a lock; audio is never stored). The coordinator records them in the existing capture journal (`CaptureDiagnostics`), two events per source per session:

- `audioCheck` ~5 s after listening starts, `audioSummary` when the source stops. The full-session Stop path waits for final flush; capture-loss callbacks snapshot before asynchronous disconnect, so their summaries may omit flush-produced text.
- Fields: verdict (`noAudio`, `digitalSilence`, `audioWithoutText`, `recognized`), seconds of audio, ms to first audio, peak dBFS, audible share (> −60 dBFS), partial/final counts, mean/max provider-activity-event-to-next-text time (not acoustic onset or end-to-end latency), and the largest local ASR backlog (`LocalLiveProvider.maxBacklogMS`).
- The TXT summary prints these numbers via `CaptureDiagnostics.summaryLine`.
- When the **microphone** delivers no buffers or only exact zeros for 5 s, the overlay status shows a localized device/mute hint (en, zh-Hans; zh-Hant via the existing ICU transform). System audio is only recorded, since silence is normal when nothing plays.
- Journal decoding is now per-record tolerant, so a stage written by a newer build no longer empties (and later overwrites) the whole journal. Older builds still decode new journals all-or-nothing; a downgrade can lose that journal.

These metrics enable provider-event timing and backlog comparisons; **no latency improvement is claimed** by this change.

## 4. Unbounded debug log — bounded

`Support/DebugLog.swift` rotated never; it now rotates `livecopilot.log` to `livecopilot.1.log` at 2 MB (two bounded files under normal successful filesystem operations) and reuses one `DateFormatter`. Writes stay on the existing serial queue. The size is read with `FileManager.attributesOfItem`, not `URL.resourceValues`: the latter caches on the long-lived static URL, so the size never grows and rotation never fires. The first full XCTest run caught exactly this (log stayed at 2000 B against a 1000 B bound).

## Files

- `StealthApp/Sources/Stealth/Providers/LocalInferenceWorker.swift`, `LocalLiveProvider.swift`
- `StealthApp/Sources/Stealth/Audio/MicCaptureManager.swift`, `AudioCaptureManager.swift`
- `StealthApp/Sources/Stealth/Core/AudioFlowMonitor.swift` (new), `CaptureDiagnostics.swift`, `Localization.swift`
- `StealthApp/Sources/Stealth/Stores/AppCoordinator.swift`, `Support/DebugLog.swift`
- Tests: `StealthApp/Tests/CoreChecks.swift` (+3 checks), `StealthApp/Tests/NativeTests.swift` (+3 cases including the integration-review regression)
- Docs: `docs/BUG_REPORTING.md`, this file

## Commands

```bash
cd StealthApp
./scripts/test-core.sh
bash scripts/prepare-sparkle.sh && ./scripts/build-local-runtime.sh && ~/.local/bin/xcodegen generate
# DerivedData outside ~/Documents: see "Repeated Documents access prompts" below.
xcodebuild -project LiveCopilot.xcodeproj -scheme LiveCopilot -configuration Debug \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LiveCopilot-claude-high-value-fixes" \
  -resultBundlePath build/<name>.xcresult test
```

## Results

Run on this worktree (macOS, Debug, no real API calls, no real recordings):

- `scripts/test-core.sh`: baseline at `83a76dd` 73 passed; with the new SIGPIPE check but before the fix the binary died with exit 141 and no FAIL line; final **76 deterministic checks passed**.
- Full XCTest (`LiveCopilotTests`): first run 257 executed, 24 skipped, 3 failures, all in the new `testDebugLogRotatesAtItsBoundAndKeepsOnePreviousFile` (the `resourceValues` caching bug above; that run also reported 9537 s for the test, cause not established). After the fix: **257 executed, 24 skipped, 0 failures, `TEST SUCCEEDED`** (93.8 s). Skips are the existing opt-in real-model, page-rendering and benchmark tests; the skip count is unchanged.
- `git diff --check` clean; secret-pattern scan of the diff found nothing.
- Acceptance material (not in Git): result bundle `StealthApp/build/claude-test-results.xcresult`, DerivedData `StealthApp/build/DerivedData-claude`. Raw logs were kept in the Claude session scratchpad (`core-*.log`, `xctest*.log`) and are reproducible with the commands above.

## Not addressed / remaining

- Answer format and personalization (feedback 6): not changed. Lower priority than crash/no-audio; would need a precedence design across scenario, knowledge-mode and language prompts.
- Recognition speed (feedback 2): no tuning. The new `activity_to_text_ms_*` and `backlog_ms_max` fields are the before/after measurement for future work; audio still hops to the main actor per buffer (`AppCoordinator` `onPCM16`), a candidate if backlog proves significant.
- Knowledge model "downloaded but load fails" (feedback 4): prior work (`KNOWLEDGE_MODEL_LOAD_FIX.md`) already added self-check and CPU fallback; no new root-cause evidence found. The SIGPIPE fix also protects the embedding worker.
- Not verified: physical microphone/system audio, Bluetooth switching, signed/installed build, affected users' machines.

## Codex integration review

- Local providers emit speech activity only after the worker response arrives. Renamed printed timing fields to `activity_to_text_ms_*`: queue/inference time before that event is excluded, and events are not correlated by utterance ID. These values alone cannot establish recognition speed improvements.
- Bounded single oversized debug-log writes and added a regression for repeated oversized messages and both retained files.
- Hardware/device-switch acceptance remains outstanding. This review does not establish the cause of users' crashes or prove recovery on physical Bluetooth devices.

### Independent validation (2026-11-02)

- Standalone `scripts/test-core.sh`: **76 deterministic checks passed**, no real API calls.
- Independent original-source XCTest: **257 tests, 24 skipped, 0 failures** (94.456 s).
- Final reviewed-source XCTest, including the oversized-write regression and core acceptance checks: **258 tests, 24 skipped, 0 failures**, `TEST SUCCEEDED` (114.386 s).
- Both runs used `caffeinate -i xcodebuild -project LiveCopilot.xcodeproj -scheme LiveCopilot -configuration Debug -derivedDataPath build/DerivedData-codex-review -resultBundlePath <bundle> test` from `StealthApp`.
- Evidence retained locally in this Claude worktree: `StealthApp/build/codex-review-results.xcresult`, `StealthApp/build/codex-review-final-results.xcresult`, and `StealthApp/build/codex-review-logs/`. These are not committed.
- Xcode emitted local CoreDevice/CoreSimulator compatibility messages, existing Keychain deprecation warnings, and AppIntents metadata warnings. The macOS build and tests still completed successfully; simulator support was not validated or repaired.
- Integration scope: local `main`; no GitHub push, release, signing/notarization, or installed-app replacement.

## Round 2 (on top of `7540db3`)

Scope: capture failures, recognition latency, crashes and diagnostics. Default listening service is local Zipformer (`AppSettings.listeningService`), so the local path was measured first.

### Measurement before changing anything

`StealthApp/scripts/measure-local-asr.py` drives the bundled `livecopilot-inference` exactly like `LocalLiveProvider` (stdio JSON, base64 PCM16, real-time 100 ms chunks) with synthetic `say` speech, and prints timings only. On this Mac (Apple M4 Max, 14 cores, 36 GB) with the installed Zipformer model:

| Metric | zh (7.7 s speech) | en (3.7 s speech) |
| --- | --- | --- |
| Worker start to ready | 2837 ms first (cold), 362–456 ms later | 362 ms |
| Inference real-time factor | 0.07 | 0.07 |
| Request time p50 / p95 / max | 1.9–2.9 / 24 / 63 ms | 1.9 / 27 / 50 ms |
| Speech onset to first preview | ≈ 0.6 s (100 ms resolution) | ≈ 0.6 s |
| Speech end to final segment | ≈ 0.7 s (VAD `min_silence_duration` 0.65 s dominates) | ≈ 0.7 s |

Conclusion: on fast hardware the worker is not the latency source; the app-side per-partial main-thread work (transcript store, translation preview, Laya gate) is light. Paraformer was not installed here and was not measured. No behaviour change was made for latency; instead the app now records the same end-to-end numbers on users' machines (below), so slow machines can be identified from a diagnostics export.

### 5. Recognition timing and failure cause in diagnostics — added

- `Core/RecognitionStats.swift` (new): per-provider `readyMS` (connect → model ready), `backlogMaxMS`, final lag (captured audio after an utterance's end when its final text arrived; includes endpoint silence, queueing and inference; excludes capture-callback buffering; stop-time flushes not counted) and a failure code.
- `LocalLiveProvider` and `AppleLiveProvider` implement `RecognitionStatsReporting`. The coordinator records `ready_ms` on `speechReady`, `failure=` on `speechFailed`, and all of them in `audioCheck`/`audioSummary` (`final_lag_ms_mean`, `final_lag_ms_max`). This replaces `LocalLiveProvider.maxBacklogMS`.
- These complement Codex's `activity_to_text_ms_*` (provider-event timing): the new final lag is on the audio timeline and does include queue and inference time. Preview (partial) latency is still not measured end-to-end because the worker does not report a preview's audio position.

### 6. Slow model load reported as "fell behind" — distinguished

Both providers hold at most 12 s of captured audio (`RecognitionStats.maximumBacklogMS`, unchanged value). Overflow before the model is ready now fails with `speech_load_slow` and "Local speech model took too long to load…" / "Apple speech took too long to start…"; overflow after ready keeps the existing message (`speech_behind`). zh-Hans strings added; zh-Hant via the existing transform. Behaviour (when listening stops) is unchanged.

### 7. Apple speech input bound by buffer count — now bound by duration

`AppleLiveProvider` fed `SpeechAnalyzer` through `AsyncStream(bufferingPolicy: .bufferingOldest(64))` and failed listening on the first dropped buffer. One buffer is created per capture callback, so the tolerated lag depended on the device's callback size (e.g. 64 × ~43 ms ≈ 2.7 s for a 2048-frame 48 kHz tap), and on startup the queued pre-ready audio (up to 48 × 250 ms) consumed most of the 64 slots at once. The stream is now unbounded and an `AudioBacklog` (FIFO of enqueued durations, released as the analyzer pulls each input) enforces the same 12 s bound as the local provider, with the cause recorded. **Evidence boundary:** code analysis only. Apple speech was not run here: `AppleSpeechSupport.installed` reserves a locale through `AssetInventory`, a shared system change that was not authorised for this session.

### 8. Possible uncatchable exception when starting or recovering the microphone — hardened

`MicCaptureManager` read `inputNode.outputFormat(forBus: 0)` and passed it to `installTap`. AVAudioEngine raises an Objective-C exception (not catchable from Swift, so the app terminates) when a tap format no longer matches the input hardware format, which can happen when a Bluetooth headset switches profile as its microphone opens, i.e. exactly at Start or during the device-change recovery added in round 1. A second `installTap` on the same bus raises as well. Changes:
- Tap with `format: nil` (the bus's current format); the existing `PCMConverter` already follows each buffer's own format. The format is still read and validated (0 Hz / 0 channels still refuses to start) and recorded.
- `tapInstalled` makes every install/remove paired; `startEngine` removes any previous tap first.
- If an immediate recovery fails, one retry runs after 0.5 s (same 3-per-30 s budget, cancelled by Stop or a newer change) before falling back to the existing stop message.

**Evidence boundary:** not reproduced (no hardware session; user crash reports were not read). This removes the known exception paths; whether they caused the reported crashes is unconfirmed.

### Hardware checks still needed (user)

1. In-Person mode with AirPods (or another Bluetooth headset): Start listening several times; then, while listening, switch input device in System Settings → Sound. Expect no crash, transcripts continue, and the journal shows `micDeviceChanged` → `micReady`.
2. Default Zipformer on the affected (slower) Mac: listen for ~1 minute, Stop, export diagnostics. `ready_ms`, `final_lag_ms_*` and `backlog_ms_max` show whether loading or inference is slow there.
3. Apple speech, if used: Start/stop a few times with system audio playing; expect no "Apple speech stopped unexpectedly".

### Round 2 files

- New: `StealthApp/Sources/Stealth/Core/RecognitionStats.swift`, `StealthApp/scripts/measure-local-asr.py`
- Changed: `Audio/MicCaptureManager.swift`, `Providers/LocalLiveProvider.swift`, `Providers/AppleLiveProvider.swift`, `Core/CaptureDiagnostics.swift`, `Core/Localization.swift`, `Stores/AppCoordinator.swift`, `docs/BUG_REPORTING.md`
- Tests: `Tests/CoreChecks.swift` (+1 check; the journal check now passes backlog via `RecognitionStats`), `Tests/NativeTests.swift` (+2 cases driving `LocalLiveProvider` with synthetic shell workers: final lag 700 ms for a 300 ms segment end after 1 s of audio; `speech_load_slow` vs `speech_behind` with localized messages)

### Round 2 results

Run on this worktree (macOS, Debug, synthetic fixtures, no real API calls, no microphone or system capture):

- `scripts/test-core.sh`: **77 deterministic checks passed** (76 + the new recognition-stats check).
- New XCTests alone: both passed (0.4 s each).
- Full XCTest with `caffeinate -i`, DerivedData `build/DerivedData-claude`, result bundle `StealthApp/build/claude-r2-results.xcresult`: **260 executed, 24 skipped, 0 failures, `TEST SUCCEEDED`**. Skips are the existing opt-in real-model, rendering and benchmark tests (count unchanged).
- That run took 1142.7 s, of which 1048.8 s was reported by `OnboardingTests.testKnownSizesMatchPinnedDistributionManifestAndUnknownDigestStaysUnknown`, which only parses two JSON manifests; rerun alone it passed in 0.013 s and `pmset -g log` shows no system sleep. Round 1 saw the same pattern (9537 s on a trivial test). Cause found in round 3: a Documents access prompt waiting for an answer (see below).
- No compiler warnings in changed files (an initial `AnalyzerInput.buffer` deprecation on OS 27 was removed by tracking FIFO durations instead).
- `measure-local-asr.py` rerun after moving it into the repo: zh load 456 ms (warm), RTF 0.069, final 714 ms after the segment end.
- Raw logs: Claude session scratchpad (`core-r2.log`, `xctest-r2*.log`, `asr/*.json`); reproducible with the commands above.


## Repeated Documents access prompts during tests (round 3)

**Symptom.** Test runs repeatedly showed a macOS prompt for LiveCopilot to access the Documents folder; unattended runs stalled until it was answered.

**Root cause (from the TCC log, `log show --predicate 'subsystem == "com.apple.TCC"'`).**
- The worktree is under `~/Documents`, a TCC-protected folder. `OnboardingTests.testKnownSizesMatchPinnedDistributionManifestAndUnknownDigestStaysUnknown` read `docs/*-model-manifest.json` through `#filePath`, i.e. from the checkout, inside the test host (`com.livecopilot.development`). That was the only XCTest reading the source tree.
- Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`, no Team ID). `codesign -d -r-` shows `designated => cdhash H"…"`, so every rebuild is a new code identity and an earlier grant no longer matches. Two DerivedData builds here had different cdhashes (`55c2079f…`, `3b3e35ea…`).
- Round 2 evidence: at 14:12:13 tccd logged `Failed to match existing code requirement for subject com.livecopilot.development and service kTCCServiceSystemPolicyDocumentsFolder`, then `AUTHREQ_PROMPTING`. The grant was created at 14:29:42 when the prompt was answered. That 17.5 min is the 1048.8 s attributed to that test. Earlier runs of the same test took 0.001–20.8 s, i.e. however long the prompt waited. The round-1 9537 s on `testDebugLogRotates…` (a failing run) was not traced; it fits the same pattern but is unconfirmed.

**Signing stability.** Not stable for TCC: ad-hoc, cdhash-based designated requirement. The only code-signing identity on this Mac is the release Developer ID, which was deliberately not used for development builds (release signing is out of scope for agents). A stable development identity (e.g. an Apple Development certificate set as `CODE_SIGN_IDENTITY` for Debug) is the owner's decision. Without it, microphone and screen-recording grants for Debug builds also do not survive a rebuild, so expect one microphone prompt per new Debug build during hardware checks.

**Fix (no permission reset, no Full Disk Access, worktree not moved).**
- The two manifests are now test-bundle resources (`project.yml`, copied by Xcode at build time); the test reads them with `Bundle(for:)`. Assertions unchanged.
- Build/test with DerivedData outside `~/Documents` (command above), so the test host, its bundle, dSYMs and symbolication never touch a protected folder. Result bundles are written by `xcodebuild` itself and can stay in `StealthApp/build/`.
- `scripts/test-core.sh` and other swiftc command-line checks run under the invoking terminal's permissions and are unaffected.

**Development diagnostics.** `CaptureDiagnostics.record` previously accepted only `com.livecopilot.app`, so a local Debug build recorded nothing and a hardware check could not leave a journal. It now also records for `com.livecopilot.development`, into the existing development path `~/Library/Application Support/LiveCopilot/Development/capture-diagnostics.json`; test hosts (`XCTestConfigurationFilePath`), `LIVECOPILOT_MOCK=1` and `--mock` stay excluded. Development app data was already isolated under `LiveCopilot/Development`; only the model cache is shared (read). `DebugLog` still writes `~/Library/Logs/LiveCopilot/livecopilot.log` for both builds (pre-existing, unchanged).

### Round 3 results

- `scripts/test-core.sh`: **77 deterministic checks passed**.
- Full XCTest with DerivedData at `~/Library/Developer/Xcode/DerivedData/LiveCopilot-claude-high-value-fixes`, result bundle `StealthApp/build/claude-r3-results.xcresult`: **260 executed, 24 skipped, 0 failures, `TEST SUCCEEDED`, 94.1 s**; the manifest test took 0.001 s.
- The new build is again a new identity (`designated => cdhash H"d56d2877…"`, not the `3b3e35ea…` granted at 14:29), yet the TCC log for the whole run window (14:34:13–14:36:16) contains **no** `com.livecopilot` request at all, so no prompt was possible.
- Both manifests are present in `LiveCopilotTests.xctest/Contents/Resources`.
- No TCC record was reset or changed by this work; the Documents grant created at 14:29:42 for the old cdhash is left as the user answered it.

## Round 4: non-hardware acceptance and Codex review hand-off

Owner decisions: keep the test-resource and out-of-Documents build changes; **do not change development signing** (Debug stays ad-hoc). The owner runs the hardware checks listed under round 2.

### Checks done without hardware

- Re-read the full source diff since `7540db3`. No defect found:
  - Providers are created per listening session (`AppCoordinator.makeLive`), so `RecognitionStats`, `capturedBytes` and `audioFrames` cannot carry over between sessions.
  - `PCMConverter` rebuilds its converter whenever a buffer's format differs, so the `format: nil` tap does not depend on the format read at start.
  - The 0.5 s mic retry cannot double-install a tap. It is skipped after Stop (`captureRevision`), after capture ended, or once a newer configuration change already restarted the engine (`tapInstalled`).
- Edge case, behaviour unchanged in kind: Apple speech now shares the local provider's 12 s bound. If the model takes almost 12 s to load, the queued audio is handed over at once and the next buffer can overflow as `speech_behind` before the analyzer drains it. The old 64-buffer bound had the same cliff at a device-dependent point.
- Searched XCTest sources for other reads of the checkout (`#filePath`, current directory, `~/Documents`). None remain. Remaining `homeDirectoryForCurrentUser` uses are opt-in benchmark/real-model tests reading `~/Library/Application Support/LiveCopilot`, which is not TCC-protected.
- `scripts/build.sh` and `scripts/preview-onboarding.sh` still use `-derivedDataPath build` with `CODE_SIGNING_ALLOWED=NO`. They only build and never start the test host, so they were left unchanged.
- `docs/BUG_REPORTING.md`: explains `micDeviceChanged → micFailed → micReady/micStopped` (immediate restart failed, then the retry decided).
- `git diff --check 83a76dd` is clean. Secret-pattern scan of the whole branch diff found nothing. No build output, logs or result bundles are tracked (`build/` and `DerivedData/` are ignored).

### Round 4 results (HEAD before this doc commit: `f430a71` + doc edit)

- `scripts/test-core.sh`: **77 deterministic checks passed**, no real API calls.
- Full XCTest (`caffeinate -i`, DerivedData `~/Library/Developer/Xcode/DerivedData/LiveCopilot-claude-high-value-fixes`, result bundle `StealthApp/build/claude-r4-results.xcresult`): **260 executed, 24 skipped, 0 failures, `TEST SUCCEEDED`, 94.4 s**. The manifest test took 0.001 s.
- The TCC log for the run window contains no `com.livecopilot` event.
- No compiler warnings in changed files.
- Raw logs are in the Claude session scratchpad (`core-r4.log`, `xctest-r4.log`). Reproduce them with the commands above.

### Not verified (needs the owner's hardware run)

- Bluetooth / device-switch recovery and the absence of tap exceptions on real devices.
- `ready_ms` / `final_lag_ms_*` / `backlog_ms_max` on the slower Mac.
- Apple speech on any machine. `AssetInventory` reservation was not authorised.
- Whether any of these changes caused or fixes the users' reported crashes. No user `.ips` or journal has been read.

### Suggested review focus for Codex

1. `MicCaptureManager`: the `tapInstalled` pairing and the retry `Task` guards against Stop/restart races.
2. `AppleLiveProvider`: the unbounded `AsyncStream` plus `AudioBacklog` accounting, specifically that `removeOldest` is called exactly once per consumed input via `stream.map`.
3. `CaptureDiagnostics.record`: development builds now write `LiveCopilot/Development/capture-diagnostics.json`, while tests and mock runs stay excluded.
4. `project.yml`: the manifests are test-target resources only, not app resources.

Branch state: local commits only. Nothing pushed, merged, versioned, signed, notarised or installed. The worktree and acceptance material (`StealthApp/build/claude-r*-results.xcresult`) are kept for integration.


## Codex integration review of rounds 2–4 (2026-11-02)

- Reviewed the microphone restart/tap lifecycle, Apple input accounting, local recognition timings, diagnostic isolation, and bundled test resources against `7540db3`.
- Fixed a stale retry edge case: every microphone configuration change now advances `captureRevision`, so a delayed retry from an older route cannot run during a newer route's settling period. Existing Stop/session guards remain. This is a code-review correction; physical device-switch validation remains outstanding.
- Independently ran `scripts/test-core.sh`: **77 deterministic checks passed**. Original-source full XCTest: **260 tests, 24 skipped, 0 failures** (94.964 s). Final reviewed-source full XCTest: **260 tests, 24 skipped, 0 failures** (93.932 s), including the core acceptance checks.
- Built Release for **arm64 + x86_64** successfully, using DerivedData outside Documents. Debug tests used `~/Library/Developer/Xcode/DerivedData/LiveCopilot-codex-integration`; Release used `~/Library/Developer/Xcode/DerivedData/LiveCopilot-codex-install`.
- Local evidence remains in this Claude worktree: `StealthApp/build/codex-round2-review.xcresult`, `StealthApp/build/codex-round2-final.xcresult`, and `StealthApp/build/codex-round2-review-logs/`. Existing Claude evidence is preserved.
- The owner authorized local integration and replacement of the existing installed app for manual hardware testing. GitHub publication is outside this integration. Public version remains 2.7.0; local signing assigns a new internal build.
- Final-lag statistics use captured audio duration, assume continuous capture, exclude capture-callback buffering, and cannot by themselves establish end-to-end wall-clock recognition latency. No hardware recovery or user-crash resolution is claimed by these automated checks.


## AirPods hardware feedback and recovery correction (2026-11-03)

- The owner reproduced an automatic listening stop when putting on AirPods in In-Person mode, build `20261102.151529`. The app process remained alive.
- Capture diagnostics at 22:04:28–22:04:29 (+08:00) show `micDeviceChanged`, two `micFailed` events with `com.apple.coreaudio.avfaudio` / `-10868`, then `micStopped`. Recognition before the switch was working; the provider loaded in 393 ms, with a maximum queued backlog of 255 ms.
- The OS audio log explicitly reports `Input HW format: 1 ch, 24000 Hz` versus `tap format: 1 ch, 48000 Hz` on both attempts. Reinstalling a nil-format tap on the stopped engine reused its stale bus format. This establishes the cause of this listening stop, not a general cause of reported crashes.
- The microphone manager now recreates AVAudioEngine on a new listening start, route recovery, and the delayed retry. It removes the old observer/tap, stops the old engine, resets the converter, and registers the new observer. An engine generation guard discards queued notifications from the old engine. Replacement runs in the deferred MainActor task, outside the notification callback, as required by Apple's AVAudioEngineConfigurationChange documentation.
- Existing capture-revision cancellation and the bounded recovery policy remain. The fix requires a repeat of the same physical AirPods switch to confirm recovery; automated tests cannot establish that result.
- Content-free evidence is preserved locally under `StealthApp/build/airpods-recovery-evidence-20261103/` (capture events and filtered audio-only logs); it is not committed. Claude's later system-audio commits are separate and have not been included in this microphone correction.
- Verification of this correction: **77 core checks passed; 260 XCTest cases, 24 skipped, 0 failures; universal Release build succeeded**. Signed application inventory: 10 verified Mach-O binaries. No microphone capture or device switching was performed by the automated tests.
