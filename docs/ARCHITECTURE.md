# LiveCopilot V1 architecture

The product requirements are `livecopilot_goal.md`. This is an incremental native evolution of Stealth; upstream source and history remain available through Git.

## Data flow

```text
ScreenCaptureKit (Them) ── PCMConverter ── OpenAILiveProvider ─┐
AVAudioEngine (You/Room) ─ PCMConverter ── OpenAILiveProvider ├─ timestamped fragments
                                                           │  + semantic client delegation
                                                           ▼
                                      ConversationState + TranscriptStore
                                                           │
     Option+Space / Reply / Recap / Follow-up ──────────────┤
     Manual text (no listening required) ───────────────────┤
                                                           ▼
                                            AppCoordinator.request
                                             RetrievalQuery.formulate
                                                           │
                                  OpenAIEmbeddingProvider (query vector)
                                                           │
                                            local KnowledgeIndex actor
                                   SQLite FTS5/BM25 + cosine + rank fusion
                                                           │
                                     OpenAIReasoningProvider / Responses SSE
                                                           │
                                      SuggestionStore → native OverlayView
```

Listening runs independently of retrieval/reasoning. Manual requests cancel obsolete answers via task cancellation and generation IDs. Automatic requests retain at most the latest pending delegation while an answer runs; a conservative cooldown and duplicate/answered-question state prevent repeated cards. Source counts and stage durations enter diagnostics; content and keys do not.

## Native preservation

- The original ScreenCaptureKit content-filter/capture configuration and AVAudioEngine microphone path remain. Independent PCM converters run on capture callbacks and synchronize converter state. The input is mono signed PCM16 LE, 24 kHz.
- Remote mode has distinct Them/You sessions; You fragments are mirrored as short context to Them. Room mode uses one microphone session and labels it Room.
- The NSPanel remains floating across Spaces, resizable, nonactivating and configured with `sharingType = .none`; it can become key for typed input. Capture exclusion still requires real software validation.
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

`LiveProvider`, `EmbeddingProvider`, and `ReasoningProvider` define the boundaries. V1 only implements OpenAI and deterministic mocks. No alternate production providers or distributed infrastructure are included.

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
