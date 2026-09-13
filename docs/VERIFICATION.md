# Verification and troubleshooting

## Evidence recorded during development

The latest exact results are maintained in `IMPLEMENTATION_PLAN.md`. Distinguish source implementation, deterministic mocks, native build/test, real API checks, and interactive hardware/UI checks. An API session starting is not proof of successful capture or question detection; setting capture exclusion is not proof of exclusion in a specific meeting app.

## Deterministic checks (no API calls)

`./StealthApp/scripts/test-core.sh` compiles and runs core checks against temporary synthetic files and mocked HTTP providers. Coverage includes Unicode chunking, page/source tracking, cosine edge cases, FTS5/BM25 and CJK search, query escaping, fusion, persistence, deletion, re-index failure/atomic replacement, embedding compatibility, question state, incomplete questions, duplicate/answered suppression, follow-ups, Live event contracts, SSE completion/error handling and structured source parsing.

Xcode `test` additionally verifies typed queries with listening disabled, superseding/cancelling answers, concurrent listening/assistance, stable transcript rows and native Keychain create/read/update/delete using an isolated dummy item. It never changes the user's real API key.

## Real APIs (opt-in, synthetic material)

The user has authorized real OpenAI integration after key-independent tests. `scripts/integration.sh` reads the specified Keychain item without printing its contents. It creates a temporary synthetic benchmark document, indexes it via OpenAI Embeddings, performs local hybrid retrieval, and verifies that streamed Responses output retains the fixture fact and a source reference.

```bash
./StealthApp/scripts/integration.sh --keychain-check
./StealthApp/scripts/integration.sh
./StealthApp/scripts/integration.sh --live
```

For a paced synthetic speech/delegation check, create test speech locally and pass it to the optional test:

```bash
say -o /tmp/livecopilot-synthetic-question.aiff \
  'In our synthetic benchmark, why did we choose method B, and what is its latency?'
./StealthApp/scripts/integration.sh --live-question --audio /tmp/livecopilot-synthetic-question.aiff
```

The tool sends PCM at real playback pace and waits for transcript/delegation events. Output audio is discarded. This checks protocol and model behavior, **not physical microphone or ScreenCaptureKit behavior**. These commands incur API charges; they are never run by the deterministic suite.

## Interactive macOS checklist

1. Launch the installed app, verify menu-bar icon and overlay. Open Settings and History, close/reopen each. Show/hide with `⌥H`. Resize the overlay and confirm the input/answer remain reachable.
2. With listening **off**, type a question and submit with Ask and Return. Verify progressive output, Cancel, Copy, recent-context toggle, and readable errors on invalid model names. Restore valid settings afterward.
3. Import a nonprivate test PDF/TXT/MD/DOCX. Wait for Ready. Ask a question about an exact number. Expand `[S1]`, check text/page/filename, re-index, restart app and verify persistence. Delete only the test document and verify it no longer appears in retrieval.
4. Test In-Person first: grant Microphone, speak a complete question, observe Room transcript and automatic suggestion. Try a fragmented sentence, pause, continue; check it does not flood the overlay. Test a follow-up and `⌥Space` fallback.
5. Test Remote Meeting using headphones: grant Screen & System Audio Recording, play nonprivate speech in another app and speak into the mic. Confirm Them/You labels; a question from Them should generate help while your own transcript remains available. Mute/unmute You.
6. While a longer answer streams, continue speaking and ask a follow-up. Transcripts should continue; only the latest pending automatic request is retained. Turn automatic suggestions off and confirm manual assistance still works.
7. Deny one permission and verify the remaining input or manual text continues. Disconnect/reconnect network, inspect the visible connection status, then stop/start after retries are exhausted. Stop/quit while a connection is starting and confirm no paid session remains intentionally active.
8. In the actual meeting application's shared-screen preview or a separate viewer, check whether the overlay is excluded. Repeat after macOS/meeting-app updates. If visible, hide the overlay or adjust the sharing workflow before relying on privacy.

## Troubleshooting

| Symptom | Action |
|---|---|
| `xcodebuild` says CLT or license missing | Install/open Xcode; complete its setup; use `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if needed. |
| XcodeGen not found | `brew install xcodegen`; or set `XCODEGEN_BIN` to a complete official XcodeGen installation. Keep its `share/xcodegen` presets next to `bin`. |
| No Dock icon | Expected: use the menu-bar waveform or `⌥H`. |
| Keychain read denied / interaction required | Unlock login Keychain and Mac. Launch the installed app and allow access to `LiveCopilot-OpenAI/current username`. Do not paste the Key into chat. CLI may have a different Keychain access identity from the app. |
| Shell environment Key not seen in GUI | Launch the binary from that same shell, or use Keychain. Finder/`open` do not necessarily inherit shell exports. |
| 401 / 403 | Check OpenAI project Key and model access. A valid text API Key does not prove access to GPT-Live-1. |
| 429 | Check API billing, credits and rate limits; retry after limits recover. |
| No transcript | Verify selected mode, input permissions/device, active Live readiness, actual source audio and network. |
| You contains remote speech | Use headphones or mute the optional You microphone. Room mode intentionally does not distinguish speakers. |
| No automatic answer | Check Auto, complete the substantive question, inspect question state; use `⌥Space`. Pauses alone never trigger work. |
| Embedding failure | Existing index stays usable for re-index failures; retry indexing later. Query embedding errors fall back to local keyword retrieval. |
| Scanned / locked PDF | OCR/unlock it outside the app before import. |
| Model changed, semantic retrieval sparse | Re-index documents with the selected embedding model. Older vectors remain excluded from incompatible comparisons. |
| Reasoning fails halfway | Partial text is retained; retry or choose compatible model/effort. |
| Permissions return after rebuild | Ad-hoc signatures may require reapproval. Use a stable signing identity for repeated builds. |
| Final Live usage unconfirmed | A disconnect prevented `session.closed`; check OpenAI usage if needed. The app released the local connection. |

Do not treat logs from macOS `com.apple.linkd.autoShortcut` or the build-time AppIntents metadata extractor as application test failures when the actual compiler/tests succeed; investigate application errors separately.

## Current real-API result (2026-09-14)

The configured Keychain item was successfully read through the system `security` CLI, with its value kept private. OpenAI returned HTTP 401 for the first real Embeddings request. Independent `/v1/models` authentication diagnostics confirmed `invalid_api_key`. The user has been asked to replace the value locally in the same Keychain item. No successful live or reasoning API result has been claimed.

The separately compiled Swift integration helper initially could not access the item through the Security framework while the desktop was locked; the CLI integration therefore captures the already-authorized system CLI's output in memory. The native app uses the Security framework in the background and may require its own standard Keychain access prompt once the desktop is unlocked.
