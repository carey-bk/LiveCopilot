# LiveCopilot architecture (V1.2)

The product requirements are `livecopilot_goal.md`. This is an incremental native evolution of Stealth; upstream source and history remain available through Git.

The user's later local-model request extends the original V1 provider scope. Listening and embedding providers are now selected independently; old preferences retain OpenAI on migration. See `LOCAL_MODELS.md` for pinned runtime/model provenance and verification.

## Data flow

```text
ScreenCaptureKit (Them) ── PCMConverter ── selected LiveProvider ─┐
AVAudioEngine (You/Room) ─ PCMConverter ── selected LiveProvider ├─ timestamped fragments
                                                             │  + provider delegation
                                                           ▼
                                      ConversationState + TranscriptStore
                                                           │
     Option+Space / Reply / Recap / Follow-up ──────────────┤
     Manual text (no listening required) ───────────────────┤
                                                           ▼
                                            AppCoordinator.request
                                             RetrievalQuery.formulate
                                                           │
                                  selected EmbeddingProvider (query vector)
                                                           │
                                            local KnowledgeIndex actor
                                   SQLite FTS5/BM25 + cosine + rank fusion
                                                           │
                                     ReasoningProviderFactory → Responses / Chat Completions SSE
                                                           │
                                      SuggestionStore → native OverlayView
```

Listening runs independently of retrieval/reasoning. Manual requests cancel obsolete answers via task cancellation and generation IDs. Automatic requests retain at most the latest pending delegation while an answer runs; a conservative cooldown and duplicate/answered-question state prevent repeated cards. Source counts and stage durations enter diagnostics; content and keys do not.

Local listening uses 16 kHz mono PCM16 (cloud Live retains 24 kHz). Each audio source has a resident native worker running SenseVoiceSmall INT8 and Silero VAD on CPU. Endpointed segments retain up to 200 ms of non-overlapping pre-roll and are bounded at 12 seconds. `LocalLiveProvider` gates delegations with local Chinese/English question rules, waits for stable silence, and reports VAD activity so the coordinator holds pending work while speech resumes. Local ASR is not token-streaming, and the heuristic is not equivalent to Live semantic comprehension. The existing manual hotkey remains the fallback.

`LocalEmbeddingProvider` uses a separate resident native worker running BGE-M3 Q8 through llama.cpp (CLS pooling, L2 normalization, 1024 dimensions). One embedding per IPC request lets interactive retrieval run between import chunks. A content/version-qualified model identity excludes old OpenAI vectors from semantic comparison; FTS keyword retrieval remains compatible, and the UI offers bulk re-indexing.

Workers use serialized, bounded JSON-lines stdin/stdout IPC, no localhost server and no inherited credentials. Blocking reads run off the main actor and consume available pipe bytes without waiting for a full buffer. Cancellation/timeout terminates active inference; close prevents restart. Audio input queues are limited to 12 seconds, and native VAD history to 30 seconds. No local failure switches silently to a cloud provider.

## Native preservation

- The original ScreenCaptureKit content-filter/capture configuration and AVAudioEngine microphone path remain. Independent PCM converters run on capture callbacks and synchronize converter state; output is 16 kHz for local ASR or 24 kHz for Live.
- Remote mode has distinct Them/You sessions; You fragments are mirrored as short context to Them. Room mode uses one microphone session and labels it Room.
- The NSPanel remains floating across Spaces, resizable and nonactivating; it can become key for typed input. Overlay capture exclusion defaults on and is user-configurable; settings/history allow capture. A native `OverlayResizeView` reserves 12 pt edge strips and 28 pt corners, preserving opposite edges while resizing and clamping dimensions. Header buttons are inset from these corners. Capture exclusion still requires real software validation.
- The application uses regular activation policy and `LSUIElement = false`, with a bundled ICNS generated from editable SVG artwork. Dock reopening restores the overlay; menu-bar controls remain available.
- Carbon global hotkeys and settings key recorder remain. Local JSON history retains speaker labels plus raw Live transcript fragments/timestamps. History lives under Application Support/LiveCopilot.
- Keychain is the existing native Security framework flow, hardened to report errors and update without deleting a valid old key first. Service/account follow the user's explicit convention.
- Shutdown completes asynchronous capture/session cleanup on the normal AppKit run loop before terminating. Capture generation checks prevent a late permission or device callback from restarting a session after stop/quit. Focused-overlay shortcut handling complements Carbon registration.

## Official Live contract

Verified against the official documentation on 2026-09-13:

- [WebSocket connection](https://developers.openai.com/api/docs/guides/voice-websockets?api=live): connect to `wss://api.openai.com/v1/live/sessions`, authenticate with bearer key, send `session.start`, wait for `session.started`, then send `session.input_audio.append`. The PCM format sits under `session.audio.format`.
- [Client delegation](https://developers.openai.com/api/docs/guides/live-delegation?delegation-mode=client): `session.delegation.created` contains an opaque `delegation.id` and timestamp, **not question text**. The app owns transcript context and the independent RAG/Responses task. Results return with `session.thinking.append` and the original ID, never a spoken commentary append.
- [Session and transcripts](https://developers.openai.com/api/docs/guides/live-conversations): transcript deltas carry `start_ms` and `end_ms`, with no authoritative turn-completed event. UI grouping is revisable and never itself triggers work. Shutdown sends `session.close` and waits for `session.closed`; timeout is reported as unconfirmed final usage.
- No Realtime input-buffer commit, `response.create` voice loop, `output_modalities`, or old `/v1/realtime?model=` is used in Live. Output audio events are discarded, with no playback engine. The prompt asks for silence; Live remains a voice model and duration billing still applies.

Each provider uses bounded reconnects (three attempts), startup timeout, bounded outgoing queue, generation checks against old sockets and cancellation. Audio buffered during failed upload is discarded rather than replayed as if current. Model/mode changes apply to newly started sessions.

## Knowledge store

`KnowledgeIndex` is an actor with one serialized SQLite connection, WAL, foreign keys and FTS5. Document and chunk metadata/vectors are persisted as typed Codable records. A separate FTS table stores lexical terms, including CJK bigrams so Chinese text is searchable.

`DocumentParser` uses PDFKit, Foundation UTF-8/UTF-16 decoding and native NSAttributedString DOCX import. PDF page numbers survive into chunks. Paragraph/punctuation-aware character chunks use overlap and retain document IDs, ordinal and original filenames. Originals are copied into the app-owned local directory, never modified in place.

Indexing batches 24 chunks per Embeddings request. New vectors are validated for batch count, dimension, model identity and finite values. Only a fully completed index is committed in one transaction. Failed re-indexing retains the previous vectors; failed initial indexing retains a retryable document record. Deletion during an in-flight request cannot resurrect the document.

Retrieval combines up to 24 lexical hits and 24 semantic hits with reciprocal rank fusion, returning six by default (3–8 in settings). Semantic scoring only compares vectors with the same model identifier and dimension. A failed query embedding uses lexical results with a visible warning. Query normalization includes the actual current question, relevant prior context and the prior question; lexical matching keeps raw entities and numbers.

## Reasoning and UI

The [Responses API stream](https://developers.openai.com/api/docs/guides/streaming-responses) uses the configurable reasoning model, effort, `store: false` and bounded output. The application parses SSE incrementally and displays text immediately; absence of a completion event, malformed events, API errors and incomplete output fail visibly without hiding partial text.

The transport frames raw UTF-8 bytes with a bounded buffer and preserves blank LF/CRLF/CR lines as SSE event boundaries. It deliberately avoids Foundation `AsyncBytes.lines`, which omitted empty separators during native acceptance. A URLSession/URLProtocol regression test covers split Unicode bytes and CRLF without making a network request.

Evidence has per-request `[S1]` IDs tied to local chunk metadata. Prompts distinguish local evidence from model reasoning and treat documents/transcripts as untrusted reference data. The tolerant Markdown section parser permits plain or partial output. The UI includes the question, compact sections, source excerpts, stage timing, cancel/copy, and optional conversation context for typed queries.

`LiveProvider`, `EmbeddingProvider`, and `ReasoningProvider` define the boundaries. `ReasoningProviderFactory` selects OpenAI Responses (shared or separate Key), DeepSeek Chat Completions, or a custom compatible Chat Completions endpoint. V1.2 adds local listening and embeddings; selecting both with DeepSeek does not require or initiate a read of the OpenAI credential on startup. Vendor-specific thinking options are emitted only for DeepSeek. Only `delta.content` is displayed; `reasoning_content` is ignored. Error bodies are not echoed.

`AppSettings` decodes older V1 records field by field, defaulting only new preferences. `AppLanguage` and `L10n` translate application chrome/status messages without translating user documents or transcripts; model answers still follow the question language. Backgrounds offer glass, soft frosted and solid white. `WindowBackgroundView` shares the surface between overlay/settings/history: soft frosted layers a 72–78% opaque, slightly cool light gradient over native material, keeping Aqua/dark text and reducing backdrop contrast; solid white is opaque; glass retains its original behavior. Settings/history clear their native window backing only for soft frosted. Existing background selections and raw storage values remain valid. Window capture exclusion remains independent of appearance.

Credentials stay outside Codable settings. Existing Live identity is preserved. Separate OpenAI and DeepSeek identities cannot fall back to the Live key. Compatible credentials are additionally scoped to their canonical endpoint. Changing a selected service invalidates the cached analysis credential; revision IDs discard delayed reads from a previous selection. Requests snapshot the selected provider and credential before streaming. Missing OpenAI embeddings can degrade to lexical retrieval while a separately configured analysis provider remains usable.

## Files and builds

- `StealthApp/Sources/Stealth/Core`: provider contracts, profiles, conversation state, query and suggestion types.
- `Knowledge`: parsing, chunking, SQLite/FTS/vector retrieval.
- `Providers`: official OpenAI HTTP/SSE and Live protocol.
- `Stores/AppCoordinator.swift`: lifecycle, trigger orchestration and UI stores.
- `Audio`, `Hotkeys`, `Overlay`, `Settings`, `Support`: reused native foundation and integration.
- `project.yml`: source of truth for generated Xcode project, Release app and XCTest target.
- `scripts/test-core.sh`: deterministic tests without GUI/API keys. XCTest adds app orchestration and isolated Keychain coverage.
- `scripts/integration.sh`: opt-in real APIs using only synthetic documents/audio.
- `Support/LiveSmokeCheck.swift`: shared synthetic Live protocol check, also available through the installed app's explicit `--verify-live --audio <path>` startup option when its Keychain identity is already authorized. Normal launches never run it or start paid listening automatically.

Mock mode uses a separate knowledge/history directory and preferences suite. Production credentials are never used by mock providers.
