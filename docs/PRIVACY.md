# V1 privacy boundary

## Stored locally

- Original imported files are copied without modifying the originals into `~/Library/Application Support/LiveCopilot/knowledge/originals/<document-id>/`.
- `knowledge.sqlite` (and SQLite WAL/SHM) contains document metadata, extracted text/chunks, source/page references, embedding model identifiers, vectors and FTS5 terms.
- Retrieval ranking, keyword search and exact cosine similarity run on the Mac.
- Session history is local JSON under `~/Library/Application Support/LiveCopilot/sessions/`. It includes timestamps, speaker labels and raw Live transcript fragments. History is retained until deleted.
- API key: macOS Keychain generic password, Service **LiveCopilot-OpenAI**, Account **current macOS username**. An `OPENAI_API_KEY` environment variable is a development fallback. No Key is embedded in the application bundle.
- Metadata-only diagnostics: `~/Library/Logs/LiveCopilot/livecopilot.log`. The application does not log request bodies, authorization headers, transcript text, knowledge chunks or API key values.
- Mock knowledge and history use the `LiveCopilot/Mock` subdirectory; Mock settings use a separate preferences suite.

Local private storage directories are created with user-only permissions where applicable; FileVault is controlled by macOS, not by the app. The app is a personal unsandboxed macOS application so it can use the original native audio capture workflow.

## Sent to OpenAI when a feature needs it

- **Listening:** system and/or microphone audio, plus relevant conversation context, sent to the official Live API. No recording is uploaded while listening is off.
- **Indexing / re-indexing:** extracted document chunks sent to OpenAI Embeddings. Original PDF/DOCX files themselves are not uploaded by this path.
- **Retrieval query:** normalized question and bounded relevant context sent for a query embedding. Search/ranking over stored vectors remains local.
- **Answer:** current question, relevant conversation and roughly the best six retrieved chunks sent to OpenAI Responses. The full knowledge base is not attached to each question.
- **Live result feedback:** a short completed-answer summary may be returned to the active Live session so it can track completed assistance and later follow-ups.

Live sessions and Responses requests set `store: false`. This is an API storage setting, **not a claim of zero provider retention**. OpenAI's account-level data controls and applicable policies still apply; see the [official data controls documentation](https://developers.openai.com/api/docs/guides/your-data).

## User controls

Stop listening to end Live sessions; typed questions remain available independently. Select Remote Meeting or In-Person, mute the optional You microphone, disable automatic suggestions, and disable recent conversation for a typed query. Delete a knowledge document to remove its local copy, metadata, chunks, FTS terms and vectors; the original file outside the app stays untouched. Delete session history in History.

Previously transmitted text/audio is governed by OpenAI's data controls; deleting a local file does not retract earlier API requests. Quitting the app gracefully closes Live sessions, but a network failure may leave final server usage unconfirmed.

The overlay requests exclusion through macOS `sharingType = .none`. This is not a universal secrecy guarantee. Test actual sharing/recording software on the target OS and use the application in accordance with the conversation's agreed rules.

Do not put personal knowledge documents, transcripts, credentials or local database files in the Git repository. `.gitignore` covers local secrets/data/build outputs; it does not inspect arbitrary files placed elsewhere.
