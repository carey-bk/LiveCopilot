# LiveCopilot V1 implementation plan

Source of truth: `livecopilot_goal.md`. Started 2026-09-13.

## Baseline audit

- Workspace initially contained only the two supplied requirements documents, no Git repository.
- Imported complete upstream history from `vortechron/stealth`, baseline commit `02b78cc82195a1711e3de11adfaed26011635dae`. Original checkout preserved outside the workspace at `/tmp/livecopilot-stealth-baseline-20260913`.
- Native Swift/SwiftUI, macOS 14+, no third-party runtime dependencies. XcodeGen generates the Xcode project. Upstream has no automated tests.
- Reuse ScreenCaptureKit PCM conversion, AVAudioEngine capture, NSPanel overlay, Carbon hotkeys, session history, and Keychain wrapper (with reliability fixes).
- Replace the old Realtime suggestion coupling with official Live client delegation plus independent Responses and Embeddings providers.
- Upstream documentation reports successful prior live use; that is not verification on this Mac. Current `micEchoCancellation` is false despite older prose describing AEC as enabled.
- Target Mac: arm64, macOS 26.6.2, Swift 6.4 Command Line Tools. `xcodebuild -version` fails because full Xcode is absent. Direct baseline `swiftc` also fails because the new SwiftUI SDK requires `SwiftUIMacros`, absent from CLT. User has been asked to install Xcode; continue core development/tests independently.
- Preserve `sharingType = .none`, but verify capture exclusion with actual sharing software; do not equate setting the property with proven invisibility.

## Milestones

1. [done] Baseline, official API contract, reproducible build scripts and acceptance ledger.
2. [done] Provider-independent domain: profiles, conversation fragments/state, duplicate/follow-up handling, retrieval query, structured suggestion parsing.
3. [done] Local SQLite/FTS5 store; PDF/Markdown/text import; chunk/source metadata; embeddings; atomic reindex/delete; hybrid retrieval.
4. [done; real API pending valid credential] OpenAI Embeddings + streamed Responses + official Live WebSocket/client delegation; bounded reconnects and clear failure states.
5. [done; basic native UI QA passed; hardware pending] Wire native capture, operating modes, auto/manual triggers, text input, settings, knowledge management, history and Keychain.
6. [in progress; deterministic/native tests passed] Deterministic test suite including provider failures, native builds, app UI smoke verification and opt-in real API path.
7. [docs done; final interactive/API audit remains open] README/setup/architecture/privacy/troubleshooting and criterion-by-criterion final audit.

## Implementation decisions

- Keep existing source directory to minimize unrelated moves; product, bundle identifier, runtime data and UI become LiveCopilot.
- All three triggers share one asynchronous retrieval/reasoning pipeline. Listening does not await that pipeline. Manual requests supersede stale answers; automatic requests are deduplicated and bounded.
- Live uses `wss://api.openai.com/v1/live/sessions`, `session.start`/`session.started`, PCM24k audio appends, timestamped transcript fragments, and `session.delegation.created`. Delegation contains an opaque ID, not query text. Display grouping does not imply a completed question.
- Remote mode preserves separate Them/You streams. Room mode labels the microphone Room without claiming diarization. Output audio is discarded; no playback engine.
- Local exact cosine + SQLite FTS5 with reciprocal rank fusion, default six chunks. Embedding model identity is persisted so incompatible vectors never silently mix.
- Original files stay local. Only indexing text, query embeddings, necessary conversation/audio, and retrieved reasoning evidence go to OpenAI. No cloud index.
- No real API requests until key-independent development and Mock testing are complete. No key in source, logs, process arguments or Git.

## Verification ledger

| Evidence | Status |
|---|---|
| Original `xcodebuild` | Passed after Xcode installation; initial CLT-only failure retained below as history |
| Original direct Swift compile | Initial CLT-only failure; superseded by successful native Xcode build |
| Core deterministic tests | 32 passed |
| LiveCopilot native build/test | Release passed; 8 XCTest cases passed |
| UI launch/hotkeys/Keychain | Basic Mock UI and focused shortcuts passed; actual Keychain read awaits local system authorization |
| Real API manual query/indexing | Old key failed authentication; updated key not yet readable in this run |
| Real audio/permissions/share exclusion | Pending interactive verification |

This plan remains open until every required acceptance criterion has evidence or an explicitly documented external prerequisite. Missing external prerequisites do not stop independent implementation.

## Progress update — 2026-09-14

- User installed Xcode 26.6 (17F113); selected developer directory verified. Both original Stealth and LiveCopilot now pass native Release `xcodebuild` on this Mac.
- Created GitHub fork `carey-bk/stealth`; configured `origin` and retained `upstream`. No development changes pushed.
- XcodeGen 2.46.0 installed from its official release with complete presets at `~/.local/share/livecopilot-tools/XcodeGen-2.46.0`, wrapper at `~/.local/bin/xcodegen`. The stalled Homebrew install was cancelled. Initial missing-preset generation was diagnosed and regenerated correctly before successful builds.
- Milestones 1–5 implemented. Mock text query, independent retrieval/reasoning, latest-request cancellation, automatic delegation, queued follow-ups, Room/Remote modes, profiles, source sections and knowledge-management controls exist.
- `test-core.sh`: **32 deterministic checks passed**.
- `xcodebuild test`: **6 XCTest cases, zero failures**, covering the 32 core checks, independent manual query/cancellation, live/answer concurrency, transcript grouping, isolated Keychain round trip, and NSPanel properties.
- Native Release app installed and process launched at `~/Applications/LiveCopilot.app`. Process launch/signature are verified; interactive visibility/keyboard actions still require UI verification.
- CUA reported the Mac locked; asked the user to unlock. Do not claim overlay/hotkey/permission/audio UI checks passed.
- User specified API key identity: Keychain Service `LiveCopilot-OpenAI`, Account current macOS user. API key content has not been displayed, logged or committed.
- Direct Security framework read from the new CLI helper timed out without making API calls. The trusted system `/usr/bin/security` CLI can access the exact specified item. Opt-in integration now captures that command's output privately in memory. Native app retains the Keychain access flow and performs lookup in the background so access prompts cannot freeze its UI.
- Real API integration is in progress with synthetic material only. Final outcome to be recorded below.

### Acceptance audit (implementation versus verification)

| Requirement | Implementation/evidence | Remaining verification |
|---|---|---|
| Native macOS build | Original + V1 Release xcodebuild succeeded | Latest final package recheck |
| Preserve capture/overlay behavior | Reused native managers/panel/hotkeys; converter thread safety improved; NSPanel property test passes | Hardware, permissions and actual share exclusion |
| LiveCopilot identity | UI, product/bundle, app storage, installed app renamed | Visual UI check |
| Official GPT-Live-1 API | New Live endpoint/startup/transcript/delegation/close implementation; protocol tests | Real Live acceptance |
| Automatic meaningful questions | Live delegation plus state/cooldown/dedup; incomplete and answered suppression tests | Synthetic/interactive speech check |
| Manual conversation hotkey | Existing Carbon actions route into independent pipeline | Actual keypress |
| Manual input without Live | Native orchestration test passes | UI Ask/Return interaction |
| Remote / In-Person | Separate Them/You or one Room input | Hardware mode checks |
| Three scenario profiles | Interview/Meeting/Defense settings and prompts; unit check | UI selection |
| Supported document import | PDFKit, native DOCX, Markdown/TXT; metadata and chunking | Interactive PDF/DOCX chooser |
| OpenAI embeddings | Batched provider with strict response validation and mocks | Real embeddings |
| Persisted local index | SQLite WAL + source/chunk/vector metadata; reopen test passes | Real API fixture reopen covered by integration path |
| Hybrid retrieval | FTS5/BM25 + exact cosine + fusion, CJK, model compatibility; tests pass | Real query fixture |
| Separate strong reasoning | Configurable Responses provider, bounded context/effort and stream | Real Responses model access |
| Source references | [S#] mapped to local excerpts/page metadata; source/parser tests | Real model factual/citation check |
| Concise streamed overlay | Progressive section parser and observable stream, cancel, sources | Visual scan/readability |
| Secure API key | Specified Keychain convention, isolated create/read/update/delete test, environment fallback | App access to user's existing item may need native authorization |
| Graceful failure | HTTP/auth/rate mappings, lexical fallback, re-index rollback, bounded reconnects, request supersession | Real network disconnect and hardware permission denial |
| Meaningful automated tests | 32 core checks + 6 native XCTest cases | Passed |
| Native build/tests pass | xcodebuild build/test successful | Final source/package check |
| Real/manual verification docs | Integration script + concise interactive checklist | User participation required for hardware |
| Current docs | README, architecture, privacy, verification and plan updated | Final results update |

The goal remains active. Implemented and Mock-tested features are not represented as real hardware/API verification.

### Real API outcome — 2026-09-14

- The system `security` CLI successfully read the exact specified Keychain item; value withheld throughout.
- Actual OpenAI Embeddings request failed with **HTTP 401** before index generation.
- An independent, read-only request to `/v1/models` confirmed **HTTP 401, `error.code = invalid_api_key`**. Only the standardized code/status was surfaced; server text that might echo credentials was not printed.
- Asked the user to update the existing Keychain item locally. Real Embeddings/Responses/Live success is **not verified**, and Live audio integration was not started because authentication failed first.
- GUI/physical audio checks remain pending Mac unlock. User has been asked once to unlock; no attempt to bypass the lock or its permission prompts.
- An invalid credential and a locked desktop are external verification prerequisites, not successful acceptance results. Continue final code/package checks; keep the goal open.

### Final local checkpoint — 2026-09-14 00:59 (Asia/Shanghai)

- Latest source passed **32 deterministic checks and 6 native XCTest cases (0 failures)**, including interrupted/batched indexing and in-flight deletion safeguards.
- Latest Release build passed and was installed at `/Users/careyzhang/Applications/LiveCopilot.app`, build **20260914.005926**. `codesign --verify --deep --strict` passed. Installed and built executable SHA-256 match: `f28e73ea2a20627d1cade9314500ac2866f72bd87b946882ab4c1081d8f83921`.
- The installed universal arm64/x86_64 app process launched. A prior development instance did not finish closing while waiting on Keychain/locked-desktop interaction; it contained no listening session or user-entered work and was terminated before replacement. Interactive quit/keychain behavior remains on the macOS QA list.
- Added automatic closure of the corresponding Live connection when a capture device stops, microphone configuration-change handling, recovery of interrupted initial indexing, and explicit hotkey-registration failures. Full hardware behavior still needs interactive verification.
- Source secret-literal scan and `git diff --check` passed. No private documents, transcripts, runtime databases or credentials are staged. The supplied DOCX remains local/ignored; the source requirements Markdown was not modified.
- **External prerequisites now block further meaningful acceptance verification:** update the invalid OpenAI key in the specified Keychain item and unlock the Mac for UI/hardware checks. No further API retries should be made until the credential is updated. Keep the Goal active/incomplete; do not claim final delivery acceptance.

### Resumed acceptance — 2026-09-14 03:53 (Asia/Shanghai)

- User confirmed unlock and Keychain update. Native UI is now accessible. The earlier `invalid_api_key` result belongs to the previous credential; **do not describe the new key as invalid** without an API result.
- The initial resumed helper read timed out after 15 seconds, before sending any API request. Fixed its orphaned child-process behavior: allow 60 seconds for authorization and terminate the child on timeout. The old orphan was cancelled. The installed production app now clearly displays `Checking Keychain…`; local system authorization is still pending. The computer-use tool refuses access to SecurityAgent, so the user must handle that system prompt locally.
- Diagnosed an actual quit hang: `terminateLater` changes AppKit's run-loop mode, while cleanup awaits MainActor work. Return `terminateCancel`, finish asynchronous cleanup on the normal loop, then terminate. Added capture generation guards and shutdown gating so late permission/capture completions cannot start a Live session after quitting. Graceful SIGTERM quit and repeated installation/relaunch now passed; no force kill was needed after the fix.
- Added focused-overlay shortcut handling alongside Carbon registration. CUA's app-targeted Option+Space originally inserted a nonbreaking space; after the fix it triggered manual conversation assistance and left the query field unchanged. Physical system-wide keypresses with another foreground app remain on the hardware checklist.
- Changed file import to asynchronous `NSOpenPanel.begin`, preserving the running application event loop. Improved per-document button styling/accessibility. Mock shortcut preferences now use the same isolated suite as other Mock settings.
- Actual Mock UI checks passed: native overlay/settings, manual Return and Ask with listening off, simulated automatic assistance, focused Option+Space, Remote/In-Person and all three scenario choices, separate Mock preference persistence, four-format document import, source disclosure with PDF page number and exact excerpt, and knowledge persistence after restarting.
- Synthetic local fixtures: `benchmark.txt` (1 chunk), `experiment.md` (1), `method-notes.docx` (1), `study.pdf` (2 pages/chunks). All reached Ready using `mock-embedding-v1`; the query returned sources across the files and exposed `study.pdf · p.2` with the test latency of 42 ms. Fixtures were imported only into `LiveCopilot/Mock`, and no private user documents were accessed or sent.
- Latest native XCTest run: **8 cases, zero failures**, including the **32 core checks**, plus new shortcut consumption/repeat suppression and shutdown/restart prevention checks. Release build succeeded; final UI-only styling change also compiled successfully.
- Installed build **20260914.035208**, executable SHA-256 **95c0a79528130c101db9a6952243a163f90f215d6b90b6210a860b9a026c656c**; built/installed hashes match and strict codesign verification passes. App has been switched back to production mode and is open at Settings for local Keychain authorization.
- Still unverified: updated-key authentication, real Embeddings/Responses/Live, physical microphone/system-audio flow, background global shortcuts, actual sharing exclusion, and complete visual/resize checks. Core re-index/delete tests pass; those controls were not exercised through UI automation. The blank private-window capture from the UI tool is not evidence for Zoom/Teams/Meet exclusion.
- Task remains incomplete pending the local credential access step, followed by real API acceptance and the documented hardware checklist.
