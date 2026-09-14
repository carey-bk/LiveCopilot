# Privacy boundary (V1.1)

## Stored locally

- Original imported files are copied without modifying the originals into `~/Library/Application Support/LiveCopilot/knowledge/originals/<document-id>/`.
- `knowledge.sqlite` (and SQLite WAL/SHM) contains document metadata, extracted text/chunks, source/page references, embedding model identifiers, vectors and FTS5 terms.
- Retrieval ranking, keyword search and exact cosine similarity run on the Mac.
- Session history is local JSON under `~/Library/Application Support/LiveCopilot/sessions/`. It includes timestamps, speaker labels and raw Live transcript fragments. History is retained until deleted.
- Live/Embeddings key: macOS Keychain generic password, Service **LiveCopilot-OpenAI**, Account **current macOS username**. `OPENAI_API_KEY` is the existing development fallback.
- Optional separate analysis keys: Services **LiveCopilot-Reasoning-OpenAI** and **LiveCopilot-Reasoning-DeepSeek**, Account current username. Compatible services use **LiveCopilot-Reasoning-Compatible**, Account current username plus the canonical endpoint. Changing the endpoint does not reuse another destination's key. There is no fallback from an external analysis service to the Live key.
- Settings persist provider/model/endpoint choices, language and background, never key bytes. The Services page displays credential availability and a fixed mask; it does not return the key to an editable field or reveal its length.
- Metadata-only diagnostics: `~/Library/Logs/LiveCopilot/livecopilot.log`. The application does not log request bodies, authorization headers, transcript text, knowledge chunks or API key values.
- Mock knowledge and history use the `LiveCopilot/Mock` subdirectory; Mock settings use a separate preferences suite.

Local private storage directories are created with user-only permissions where applicable; FileVault is controlled by macOS, not by the app. The app is a personal unsandboxed macOS application so it can use the original native audio capture workflow.

## Sent to the selected service when a feature needs it

- **Listening:** system and/or microphone audio, plus relevant conversation context, sent to the official Live API. No recording is uploaded while listening is off.
- **Indexing / re-indexing:** extracted document chunks sent to OpenAI Embeddings. Original PDF/DOCX files themselves are not uploaded by this path.
- **Retrieval query:** normalized question and bounded relevant context sent for a query embedding. Search/ranking over stored vectors remains local.
- **Answer:** current question, relevant conversation and roughly the best six retrieved chunks go to the **selected analysis service**: OpenAI Responses by default, optionally DeepSeek or the configured compatible endpoint. The full knowledge base is not attached to each question. Custom endpoints must use HTTPS; credentials in URL user info, query parameters or fragments are rejected.
- **Live result feedback:** a short completed-answer summary may be returned to the active Live session so it can track completed assistance and later follow-ups.

OpenAI Live sessions and OpenAI Responses requests set `store: false`. Custom Chat Completions services receive only portable request fields; their storage/retention behavior depends on that provider. This is an API storage setting, **not a claim of zero provider retention**. OpenAI's account-level data controls and applicable policies still apply; see the [official data controls documentation](https://developers.openai.com/api/docs/guides/your-data).

## User controls

Stop listening to end Live sessions; typed questions remain available independently. Select Remote Meeting or In-Person, mute the optional You microphone, disable automatic suggestions, and disable recent conversation for a typed query. Delete a knowledge document to remove its local copy, metadata, chunks, FTS terms and vectors; the original file outside the app stays untouched. Delete session history in History.

Previously transmitted text/audio is governed by the receiving provider's data controls; deleting a local file does not retract earlier API requests. Quitting the app gracefully closes Live sessions, but a network failure may leave final server usage unconfirmed.

The overlay, settings and history request exclusion through macOS `sharingType = .none`; white/glass appearance does not change this. A developer-only `--mock --ui-preview` launch permits capture solely for isolated Mock UI review; `--ui-preview` alone never changes production capture exclusion. This is not a universal secrecy guarantee. Test actual sharing/recording software on the target OS and use the application in accordance with the conversation's agreed rules.

Do not put personal knowledge documents, transcripts, credentials or local database files in the Git repository. `.gitignore` covers local secrets/data/build outputs; it does not inspect arbitrary files placed elsewhere.
