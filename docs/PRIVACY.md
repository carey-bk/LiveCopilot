# Privacy boundary (V1.3)

## Stored locally

- Original imported files are copied without modifying the originals into `~/Library/Application Support/LiveCopilot/knowledge/originals/<document-id>/`.
- `knowledge.sqlite` (and SQLite WAL/SHM) contains document metadata, extracted text/chunks, source/page references, embedding model identifiers, vectors and FTS5 terms.
- Retrieval ranking, keyword search and exact cosine similarity run on the Mac.
- Optional local model weights live in `~/Library/Application Support/LiveCopilot/Models/`. SenseVoiceSmall or Paraformer streaming + Silero VAD processes audio locally; BGE-M3 generates document and query vectors locally. Workers communicate through private stdin/stdout pipes, open no network listener, inherit no API credentials, and do not log audio/text. Raw audio is held in bounded memory, not recorded to disk by this route.
- Apple ASR uses on-device SpeechAnalyzer/SpeechTranscriber and SpeechDetector. Language assets are downloaded and managed by macOS; no fallback to Apple server dictation is implemented. Final captions enter the same local history and selected analysis context.
- Session history is local JSON under `~/Library/Application Support/LiveCopilot/sessions/`. It includes timestamps, speaker labels and raw Live transcript fragments. History is retained until deleted.
- Live/Embeddings key: macOS Keychain generic password, Service **LiveCopilot-OpenAI**, Account **current macOS username**. `OPENAI_API_KEY` is the existing development fallback.
- Optional separate analysis keys: Services **LiveCopilot-Reasoning-OpenAI** and **LiveCopilot-Reasoning-DeepSeek**, Account current username. Compatible services use **LiveCopilot-Reasoning-Compatible**, Account current username plus the canonical endpoint. Changing the endpoint does not reuse another destination's key. There is no fallback from an external analysis service to the Live key.
- Settings persist provider/model/endpoint choices, language and background, never key bytes. The Services page displays credential availability and a fixed mask; it does not return the key to an editable field or reveal its length.
- Metadata-only diagnostics: `~/Library/Logs/LiveCopilot/livecopilot.log`. The application does not log request bodies, authorization headers, transcript text, knowledge chunks or API key values.
- Mock knowledge and history use the `LiveCopilot/Mock` subdirectory; Mock settings use a separate preferences suite.

Local private storage directories are created with user-only permissions where applicable; FileVault is controlled by macOS, not by the app. The app is a personal unsandboxed macOS application so it can use the original native audio capture workflow.

## Sent to the selected service when a feature needs it

- **Apple language download:** macOS obtains its speech assets from Apple when the user requests installation. Subsequent recognition uses the on-device SpeechTranscriber.
- **Model download:** public model weights are fetched from pinned GitHub/Hugging Face locations, verified by SHA-256 and installed locally. No user audio, documents or API keys are sent with these downloads.
- **Listening:** local mode sends no audio to a service and uses local Chinese/English question heuristics. OpenAI Live mode sends system and/or microphone audio plus relevant conversation context to the official Live API. No audio is uploaded while listening is off.
- **Indexing / re-indexing:** local BGE-M3 runs entirely on the Mac. Selecting OpenAI Embeddings sends extracted document chunks to OpenAI; original PDF/DOCX files themselves are not uploaded by this path.
- **Retrieval query:** local BGE-M3 computes the query vector on the Mac. OpenAI Embeddings sends the normalized question and bounded relevant context for a query embedding. Search/ranking over stored vectors is local in both modes.
- **Answer:** current question, relevant conversation and roughly the best six retrieved chunks go to the **selected analysis service**: OpenAI Responses by default, optionally DeepSeek or the configured compatible endpoint. The full knowledge base is not attached to each question. Custom endpoints must use HTTPS; credentials in URL user info, query parameters or fragments are rejected.
- **Live result feedback:** a short completed-answer summary may be returned to an active OpenAI Live session. Local mode retains context inside the application.

OpenAI Live sessions and OpenAI Responses requests set `store: false`. Custom Chat Completions services receive only portable request fields; their storage/retention behavior depends on that provider. This is an API storage setting, **not a claim of zero provider retention**. OpenAI's account-level data controls and applicable policies still apply; see the [official data controls documentation](https://developers.openai.com/api/docs/guides/your-data).

## User controls

Stop listening to end Live sessions; typed questions remain available independently. Select Remote Meeting or In-Person, mute the optional You microphone, disable automatic suggestions, and disable recent conversation for a typed query. Delete a knowledge document to remove its local copy, metadata, chunks, FTS terms and vectors; the original file outside the app stays untouched. Delete session history in History.

Previously transmitted text/audio is governed by the receiving provider's data controls; deleting a local file does not retract earlier API requests. Quitting the app gracefully closes Live sessions, but a network failure may leave final server usage unconfirmed.

Settings and history windows allow capture. The overlay requests exclusion through macOS `sharingType = .none` by default; the General page has a persistent toggle to allow its capture instead. Older settings retain overlay exclusion on migration. White/glass appearance does not change this choice. A developer-only `--mock --ui-preview` launch also permits overlay capture for isolated Mock UI review; `--ui-preview` alone does not override the production preference. This is not a universal secrecy guarantee. Test actual sharing/recording software on the target OS and use the application in accordance with the conversation's agreed rules.

Do not put personal knowledge documents, transcripts, credentials or local database files in the Git repository. `.gitignore` covers local secrets/data/build outputs; it does not inspect arbitrary files placed elsewhere.
