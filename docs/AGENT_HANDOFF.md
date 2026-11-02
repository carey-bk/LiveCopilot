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

- `audioCheck` ~5 s after listening starts, `audioSummary` when the source stops (after the final flush).
- Fields: verdict (`noAudio`, `digitalSilence`, `audioWithoutText`, `recognized`), seconds of audio, ms to first audio, peak dBFS, audible share (> −60 dBFS), partial/final counts, mean/max speech-onset-to-first-text latency, and the largest local ASR backlog (`LocalLiveProvider.maxBacklogMS`).
- The TXT summary prints these numbers via `CaptureDiagnostics.summaryLine`.
- When the **microphone** delivers no buffers or only exact zeros for 5 s, the overlay status shows a localized device/mute hint (en, zh-Hans; zh-Hant via the existing ICU transform). System audio is only recorded, since silence is normal when nothing plays.
- Journal decoding is now per-record tolerant, so a stage written by a newer build no longer empties (and later overwrites) the whole journal. Older builds still decode new journals all-or-nothing; a downgrade can lose that journal.

These metrics enable latency comparisons; **no latency improvement is claimed** by this change.

## 4. Unbounded debug log — bounded

`Support/DebugLog.swift` rotated never; it now rotates `livecopilot.log` to `livecopilot.1.log` at 2 MB (≤ 4 MB total) and reuses one `DateFormatter`. Writes stay on the existing serial queue. The size is read with `FileManager.attributesOfItem`, not `URL.resourceValues`: the latter caches on the long-lived static URL, so the size never grows and rotation never fires. The first full XCTest run caught exactly this (log stayed at 2000 B against a 1000 B bound).

## Files

- `StealthApp/Sources/Stealth/Providers/LocalInferenceWorker.swift`, `LocalLiveProvider.swift`
- `StealthApp/Sources/Stealth/Audio/MicCaptureManager.swift`, `AudioCaptureManager.swift`
- `StealthApp/Sources/Stealth/Core/AudioFlowMonitor.swift` (new), `CaptureDiagnostics.swift`, `Localization.swift`
- `StealthApp/Sources/Stealth/Stores/AppCoordinator.swift`, `Support/DebugLog.swift`
- Tests: `StealthApp/Tests/CoreChecks.swift` (+3 checks), `StealthApp/Tests/NativeTests.swift` (+2 cases)
- Docs: `docs/BUG_REPORTING.md`, this file

## Commands

```bash
cd StealthApp
./scripts/test-core.sh
bash scripts/prepare-sparkle.sh && ./scripts/build-local-runtime.sh && ~/.local/bin/xcodegen generate
xcodebuild -project LiveCopilot.xcodeproj -scheme LiveCopilot -configuration Debug \
  -derivedDataPath build/DerivedData-claude -resultBundlePath build/claude-test-results.xcresult test
```

## Results

Run on this worktree (macOS, Debug, no real API calls, no real recordings):

- `scripts/test-core.sh`: baseline at `83a76dd` 73 passed; with the new SIGPIPE check but before the fix the binary died with exit 141 and no FAIL line; final **76 deterministic checks passed**.
- Full XCTest (`LiveCopilotTests`): first run 257 executed, 24 skipped, 3 failures, all in the new `testDebugLogRotatesAtItsBoundAndKeepsOnePreviousFile` (the `resourceValues` caching bug above; that run also reported 9537 s for the test, cause not established). After the fix: **257 executed, 24 skipped, 0 failures, `TEST SUCCEEDED`** (93.8 s). Skips are the existing opt-in real-model, page-rendering and benchmark tests; the skip count is unchanged.
- `git diff --check` clean; secret-pattern scan of the diff found nothing.
- Acceptance material (not in Git): result bundle `StealthApp/build/claude-test-results.xcresult`, DerivedData `StealthApp/build/DerivedData-claude`. Raw logs were kept in the Claude session scratchpad (`core-*.log`, `xctest*.log`) and are reproducible with the commands above.

## Not addressed / remaining

- Answer format and personalization (feedback 6): not changed. Lower priority than crash/no-audio; would need a precedence design across scenario, knowledge-mode and language prompts.
- Recognition speed (feedback 2): no tuning. The new `text_ms_*` and `backlog_ms_max` fields are the before/after measurement for future work; audio still hops to the main actor per buffer (`AppCoordinator` `onPCM16`), a candidate if backlog proves significant.
- Knowledge model "downloaded but load fails" (feedback 4): prior work (`KNOWLEDGE_MODEL_LOAD_FIX.md`) already added self-check and CPU fallback; no new root-cause evidence found. The SIGPIPE fix also protects the embedding worker.
- Not verified: physical microphone/system audio, Bluetooth switching, signed/installed build, affected users' machines.
