# LiveCopilot V1 implementation and acceptance

Source of truth: `livecopilot_goal.md`. Development: 2026-09-13–14. Final local delivery: 2026-09-14 (Asia/Shanghai).

## Delivery status

V1 implementation is complete and installed at `/Users/careyzhang/Applications/LiveCopilot.app`, version **1.0.0**, build **20260914.075740**. The installed application has passed real OpenAI Embeddings, Responses and official Live checks. It has been restarted normally, reads the existing Keychain credential, and is left ready with listening off. The synthetic acceptance document has been removed from the production knowledge base; only the exact disposable fixture was deleted.

Physical microphone/system-audio behavior, background global keypresses, complete visual/resize inspection, permission denial/network interruption, and actual meeting-app screen-share exclusion have an explicit interactive checklist in `VERIFICATION.md`. These are **not represented as passed hardware tests**. The supplied requirements explicitly allow a manual checklist for audio behavior requiring user participation. No further development or API-credential prerequisite is outstanding.

## Baseline audit and scope

- The workspace initially contained the supplied requirements documents, without a Git repository. Imported upstream history from `vortechron/stealth`, baseline `02b78cc82195a1711e3de11adfaed26011635dae`. The original checkout is preserved at `/tmp/livecopilot-stealth-baseline-20260913`.
- Created personal fork `carey-bk/stealth`, configured `origin` and retained `upstream`. Work is on local branch `livecopilot-v1`; development changes have not been pushed.
- Original Stealth and V1 both passed native Release builds after the user installed full Xcode. Initial CLT-only failure was an environment prerequisite, resolved with Xcode 26.6 (17F113), selected at `/Applications/Xcode.app/Contents/Developer`.
- Target Mac: arm64, macOS 26.6.2. Installed application: universal arm64/x86_64. XcodeGen 2.46.0 is installed with official presets at `~/.local/share/livecopilot-tools/XcodeGen-2.46.0`, wrapper `~/.local/bin/xcodegen`.
- Reused Swift/SwiftUI, ScreenCaptureKit, AVAudioEngine, PCM conversion, NSPanel, menu bar, Carbon shortcuts, local history and Keychain. Kept native build/signing, original MIT license and the source directory layout.
- OpenAI-only V1: official Live client delegation, Embeddings and independent streamed Responses. No alternate providers, cloud index, Docker, account system or unrelated product expansion.

## Completed milestones

1. Baseline audit, official API contract and reproducible native build scripts.
2. Provider-independent conversation/question state, normalized retrieval intent, incomplete/duplicate/answered suppression and follow-up handling.
3. Local SQLite/FTS5 knowledge store, PDF/MD/TXT/DOCX extraction, chunk/source metadata, persisted vectors, atomic re-index/delete and hybrid retrieval.
4. OpenAI Embeddings, official Live WebSocket protocol/client delegation and independent streamed Responses, with bounded reconnects and readable failure states.
5. Native capture orchestration, Room/Remote modes, three profiles, automatic/manual/text triggers, settings, knowledge management, history and secure credential access.
6. Deterministic mocks, native XCTest, native UI smoke checks, real API validation and fixes for failures found during acceptance.
7. Final package verification, criterion audit and current setup/architecture/privacy/troubleshooting documentation.

## Implementation decisions

- Three assistance triggers share one asynchronous retrieval/reasoning pipeline. Listening continues independently. Manual requests supersede stale answers; automatic requests are deduplicated and bounded.
- Live uses `wss://api.openai.com/v1/live/sessions`, `session.start`/`session.started`, PCM24k audio, timestamped transcript fragments, `session.delegation.created` and explicit close. Delegation IDs are opaque; the app derives retrieval intent from conversation state. No model audio is played.
- Remote mode retains Them/You streams. In-Person mode labels the shared microphone Room and makes no diarization claim.
- Retrieval combines local exact cosine with SQLite FTS5/BM25 using reciprocal rank fusion, default six chunks. Embedding model identity prevents incompatible vectors from mixing.
- Originals, chunks, vectors and history remain local. OpenAI receives indexing text, query embeddings, necessary audio/context and retrieved answer evidence. There is no cloud knowledge index.
- All key-independent development and Mock testing preceded real API requests. The Keychain convention is Service `LiveCopilot-OpenAI`, Account current macOS username; environment fallback is `OPENAI_API_KEY`. Credentials are never printed, logged, supplied as process arguments or committed.

## Acceptance audit

| Requirement | Final implementation and evidence | Explicit verification boundary |
|---|---|---|
| Native macOS build | Original + final V1 Release builds pass; native Debug XCTest passes | Installed local ad-hoc package, not a notarized distribution |
| Preserve useful capture/overlay behavior | Native managers/panel/menu/hotkeys/history retained; converter, capture-generation and shutdown reliability improved; NSPanel property test passes | Physical capture and actual sharing exclusion require interactive checks |
| LiveCopilot identity | UI/product/bundle/storage renamed; installed native Settings and overlay inspected | Full visual/resize inspection remains manual |
| Official GPT-Live-1 API | Real `session.started`, synthetic speech transcript, client delegation and `session.closed` observed | Synthetic audio bypasses physical devices |
| Automatic meaningful questions | Live delegation plus conservative state/cooldown/dedup; incomplete/answered/follow-up tests; Mock automatic UI assistance | Real Live delegation and orchestration tested separately; real hardware end-to-end remains manual |
| Manual conversation hotkey | Carbon registration retained; focused Option+Space invokes the shared pipeline without inserting characters | Physical keypress while another app is foreground remains manual |
| Text query with listening off | Native tests and UI Ask/Return; real grounded answer completed without a Live session | Passed |
| Remote / In-Person | Them/You and Room paths; UI mode switching and Mock behavior checked | Hardware mode checks remain manual |
| Three scenario profiles | Interview/Meeting/Academic Defense prompts/settings; UI selection checked | Passed implementation/UI selection |
| Import supported local documents | Native PDFKit/DOCX and MD/TXT; all four formats reached Ready in isolated Mock UI | Scanned PDFs need external OCR |
| OpenAI Embeddings | Production UI indexed disposable `benchmark.txt` with real `text-embedding-3-small` | Real fixture: one chunk, 1536 dimensions |
| Persisted local knowledge | SQLite WAL metadata/chunks/vectors/source copies; reopen tests and Mock app restart; real vector verified in SQLite | Personal-scale exact vector search |
| Hybrid retrieval | FTS5/BM25 + cosine + fusion, CJK and model compatibility tests; real query retrieved exact fixture | Retrieval relevance on the user's own corpus is not benchmarked |
| Separate configurable reasoning | Real `gpt-5.6-sol` low-effort Responses request after local retrieval | Other model/effort combinations depend on API access |
| Source references | Real answer reports **42 ms [S1]**; source expands to exact local excerpt; Mock PDF page reference checked | Retrieved sources do not guarantee every generated claim is supported |
| Concise streamed overlay | Progressive text, structured sections, cancellation and source disclosure; real first text at **4312 ms** | One synthetic run, not a latency percentile/SLA |
| Secure Keychain + fallback | Native dummy-item CRUD test; real credential read and reuse after normal restart | CLI helper has its own macOS authorization identity |
| Graceful failures | Auth/rate/error mappings, lexical fallback, index rollback, bounded reconnect, request cancellation and shutdown tests | Physical permission denial and real network interruption remain manual |
| Meaningful automated tests | **34 core checks**, included in **9 native XCTest cases**, zero failures | Deterministic suite makes no real API calls |
| Native builds/tests pass | Final Release build and native Debug tests pass; integration helper compiles | Passed |
| Real/manual verification steps | Opt-in CLI/native synthetic Live diagnostic and interactive macOS checklist | No fabricated hardware success |
| Current documentation | README, ARCHITECTURE, PRIVACY, VERIFICATION and this audit updated | Requirements document preserved unchanged |

## Real API evidence — installed build 20260914.075740

- User approved Keychain access for the installed build. Normal restart also shows `Credential available. No API request made.` without requiring another credential entry.
- Real Embeddings imported the exact disposable benchmark fixture. SQLite showed model `text-embedding-3-small` and vector dimension **1536**.
- At **08:02:09.744**, the native opt-in diagnostic observed official GPT-Live `session.started`; at **08:02:18.155**, `session.closed`; at **08:02:18.156**, it confirmed synthetic speech transcription and semantic client delegation. Only locally generated synthetic speech was transmitted; no physical microphone/system audio was captured by this check.
- With listening off, the production UI question “What is the latency of Method B in the synthetic benchmark? Cite the source.” completed with “Method B’s latency in the synthetic benchmark is 42 ms. [S1]”. Expanding `[S1]` showed the exact fixture text and filename.
- Metadata timing: retrieval ready **2768 ms**; first answer text **4312 ms** from request start. This is a single run including query embedding, not a general performance guarantee.
- The diagnostic session closed. After cleanup, the same signed application restarted without diagnostic arguments; the production Knowledge list is empty and the overlay shows `Ready — type a question or start listening`.

## Acceptance fixes and verification history

- The original credential returned HTTP 401 / `invalid_api_key`. The user updated it locally. Later CLI access timeouts occurred before API requests and did not establish credential validity. Native application access ultimately succeeded and all three real API paths above passed.
- Fixed a native quit hang: `terminateLater` changed the run-loop mode while cleanup awaited MainActor work. Termination now cancels the first request, finishes async cleanup on the normal loop, then terminates. Generation guards prevent late capture/permission completions from starting sessions after shutdown. Repeated graceful termination/relaunch passed.
- Added local focused-overlay key handling alongside Carbon, preventing Option+Space from inserting a nonbreaking space. Changed document selection to asynchronous `NSOpenPanel.begin`, preserving the event loop. Mock preferences and documents are isolated.
- Real Responses exposed an SSE defect: Foundation `AsyncBytes.lines` omitted blank event separators. Replaced it with bounded UTF-8 byte framing preserving LF/CRLF/CR. New core checks and an actual URLSession/URLProtocol regression test cover fragmented UTF-8 and CRLF without a network call. The corrected real answer then completed successfully.
- An incremental accessibility snapshot temporarily retained a removed Cancel control. A full snapshot confirmed the request had completed. No speculative completion workaround was retained; stale UI observation is not an app failure.
- Latest native XCTest result: **9 cases, 0 failures**, at **08:09:06**. The core suite reports **34 checks**. Final Release compilation and CLI helper compilation also pass.

## Installed artifact and repository

- Installed path: `/Users/careyzhang/Applications/LiveCopilot.app`.
- Version/build: **1.0.0 / 20260914.075740**.
- Installed executable SHA-256: `bd8f79d03933f1606c37108c0d0fb42b239895ba6ed254ea34456a744962aa9c`.
- `codesign --verify --deep --strict` passes. The installed, real-API-tested signature was preserved during final source compilation to avoid unnecessary Keychain reauthorization. Unsigned build products are separate from this installed artifact.
- Source secret-literal scan and `git diff --check` pass. No credentials, private documents, transcripts, runtime databases or test audio are committed. Disposable speech/documents were generated under `/tmp`; the production fixture was removed by exact filename-and-content match through the index deletion API.
- Historical implementation commits and the final acceptance fix are local. No remote push or release publication was performed.
