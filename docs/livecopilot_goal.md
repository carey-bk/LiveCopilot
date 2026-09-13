# LiveCopilot — Codex Development Goal

## Recommended execution mode

Use **Codex Local on the target Mac** as the primary development environment for this project.

This is a native macOS Swift/SwiftUI application. The agent should be able to use the local Xcode toolchain and macOS SDK, run `xcodebuild`, inspect compiler errors, exercise app lifecycle behavior, and prepare the project for real ScreenCaptureKit, AVAudioEngine, Keychain, microphone, and screen/audio permission testing.

Cloud tasks may be used later for isolated code review, documentation, or non-macOS-specific refactors, but the main implementation should stay local so the agent can repeatedly build and validate the native application.

## Repository and product identity

Fork `vortechron/stealth` and evolve the fork into a personal native macOS application named **LiveCopilot**.

Do not rewrite the application in Electron, Tauri, Python, or a web framework. Preserve the useful native Swift/SwiftUI foundation.

## Product goal

Build a production-usable personal real-time AI copilot for:

- interviews;
- meetings;
- academic defenses/presentations.

The application listens to a live conversation on macOS and helps the user in real time. It must support three ways to request assistance:

1. **Automatic question detection** — detect when another participant asks a meaningful question and proactively generate guidance.
2. **Manual conversation trigger** — preserve a global hotkey that asks for guidance based on the current/recent conversation even if automatic detection did not fire.
3. **Manual text query** — provide a text input box where the user can type any question or instruction and receive an answer using the same knowledge/RAG/reasoning pipeline. This must work even when live listening is disabled.

The response should combine:

- the current question;
- recent conversation context;
- relevant information from a user-provided knowledge base;
- the OpenAI reasoning model's own general knowledge and reasoning.

The result should appear as concise, high-value text in the existing private macOS overlay. No AI voice output is required.

## V1 provider strategy: all OpenAI

For V1, use OpenAI APIs end-to-end to minimize dependencies and make the first usable version easy to run.

Use one configurable OpenAI API key for:

- GPT-Live-1 / current official Live API for real-time conversation understanding;
- OpenAI Embeddings for knowledge-base embeddings;
- a configurable strong OpenAI text/reasoning model for answer synthesis.

Store the user's API key in macOS Keychain. Never commit secrets to the repository.

During development and automated tests, support environment-variable fallback such as `OPENAI_API_KEY` and use mock providers wherever practical so most tests do not consume API credits.

Do not require Ollama in V1.

## Provider abstraction for future upgrades

Although V1 is OpenAI-only, do not tightly couple architecture to permanent model names or a single provider implementation.

Create clean abstractions for at least:

- `LiveProvider`
- `EmbeddingProvider`
- `ReasoningProvider`

The V1 implementations should be OpenAI-backed.

The interfaces should make it possible later to add:

- alternative reasoning APIs such as DeepSeek/OpenAI-compatible providers;
- built-in local embeddings;
- Ollama/local embedding providers;
- alternate future Live models.

Do not implement these alternate providers unless necessary for a clean interface. Scope V1 around a working all-OpenAI product.

## GPT-Live-1 role

Integrate GPT-Live-1 through the **current official Live API**. Do not assume that changing the old `gpt-realtime` model string is sufficient.

GPT-Live-1 should act primarily as the real-time conversation/comprehension layer:

- continuously understand incoming speech;
- handle pauses, interruptions, corrections and follow-up questions;
- determine when a meaningful question has formed;
- maintain enough conversation state to understand context;
- recognize when a later question is a follow-up to an earlier question/answer;
- decide when automatic assistance should be triggered;
- continue listening while deeper RAG/reasoning work runs independently.

Do **not** make GPT-Live-1 responsible for all deep reasoning or knowledge retrieval.

Use client/backend delegation or an equivalent asynchronous orchestration design so continued live listening is not blocked by retrieval or answer generation.

No spoken model output is needed. Text/transcript and event/state output are sufficient.

## Audio modes

Support at least two operating modes.

### Remote Meeting mode

Preserve Stealth's useful dual-input model:

- system audio = remote participant(s) / `Them`;
- microphone = user / `You`.

Preserve explicit speaker labeling wherever possible.

GPT-Live-1 should primarily detect questions from the remote/system-audio side while the application retains the user's microphone transcript so the backend can understand what the user has already answered.

### In-Person / Defense mode

Support a room-microphone-only mode for physical interviews, meetings, defenses and presentations where multiple people may be captured by one microphone.

Perfect diarization is not required for V1.

The system should still detect likely questions and provide assistance from the conversation context.

Design audio and conversation interfaces so better diarization or multiple microphones could be added later.

## Conversation state and automatic triggering

Implement a clear conversation/question state layer rather than triggering on every VAD pause.

It should conceptually track states such as:

- listening;
- possible question forming;
- question sufficiently complete;
- assistance in progress;
- follow-up question;
- duplicate/already answered question.

Automatic triggering should:

- avoid firing on incomplete sentences;
- avoid triggering repeatedly for the same question;
- recognize obvious follow-ups where practical;
- remain conservative enough not to flood the overlay;
- expose enough state/logging to debug false positives and missed questions.

Preserve a manual hotkey fallback, such as the existing Option+Space behavior, which forces assistance using the recent conversation context.

## Manual text query box

Add an easily accessible text input to the overlay/application.

The user must be able to type a question or instruction at any time, for example:

- "How should I respond if they challenge the sample size?"
- "Find the revenue number in my documents."
- "Explain why method B was not used."

Pipeline:

`typed query -> optional recent conversation context -> knowledge retrieval -> reasoning model -> streamed overlay answer`

Requirements:

- must not require an active GPT-Live-1 session;
- should use the same knowledge base and reasoning pipeline as automatic/manual-live assistance;
- should support streaming output;
- should allow the application to serve as a normal knowledge-grounded AI copilot when listening is turned off.

## Local knowledge base and RAG

The persistent knowledge base and retrieval index must live on the user's Mac.

V1 supported formats:

- PDF;
- Markdown;
- plain text.

Add DOCX if straightforward and stable.

Implement:

- document import;
- extraction/parsing;
- chunking;
- metadata and source tracking;
- embedding/index generation;
- deletion;
- re-indexing;
- retrieval;
- citation/source propagation into answers.

### Storage and retrieval

Prefer a simple robust local architecture:

- SQLite for document/chunk metadata and persisted vectors;
- SQLite FTS5/BM25 for lexical retrieval;
- exact cosine similarity over local vectors is acceptable for expected personal knowledge-base sizes;
- combine semantic and lexical results using a simple hybrid ranking/fusion approach;
- return roughly the best 5-8 relevant chunks by default.

Do not introduce Qdrant, cloud vector databases, Docker, or distributed infrastructure in V1.

### OpenAI Embeddings in V1

Use a configurable OpenAI embedding model for V1.

Important privacy behavior:

- original document files remain local;
- parsed documents/chunks and generated vectors are persisted locally;
- text chunks necessarily sent to the OpenAI Embeddings API during indexing should be documented clearly;
- retrieval itself should happen locally against the locally stored index;
- only retrieved chunks relevant to a reasoning request should be sent to the answer model rather than uploading the whole knowledge base for each question.

Implement the embedding layer behind `EmbeddingProvider` so a future built-in local embedding implementation can replace OpenAI Embeddings without rewriting the RAG system.

## Query formulation and RAG quality

Do not simply embed the last transcript sentence.

Before retrieval, form a normalized retrieval query using the detected question and relevant conversation state.

Example:

Raw follow-up: `What about latency?`

Better retrieval intent: `Compare the latency impact of the selected method versus the previously discussed alternative in the current experiment.`

Use conversation context to improve retrieval while keeping the process low-latency.

When useful, allow lexical terms/numbers/entity names from the raw transcript to supplement semantic retrieval so exact facts are not lost.

## Reasoning and answer synthesis

Use a separate configurable strong OpenAI text/reasoning model for final answer generation.

Do not hard-code the whole architecture around one permanent model identifier.

The reasoning request should include, as useful:

- normalized current question;
- recent conversation context;
- what the user has already said;
- locally retrieved chunks with source metadata;
- scenario-specific instructions.

The reasoning model may use both retrieved local material and its own general knowledge/reasoning.

However, the UI/output must distinguish where practical between:

- facts/evidence supported by the user's knowledge base;
- useful general model knowledge or reasoning.

Knowledge-base-derived factual claims should retain source references.

## Output design

Do not generate long essays by default.

The overlay must prioritize information a user can scan while actively speaking.

Use a structured response model conceptually containing:

- **Question**
- **Core answer**
- **Key points**
- **Evidence / numbers from knowledge base**
- **Useful general context / reasoning**
- **Watch-outs / caveats**
- **Sources**

Not every section is required for every answer.

Stream useful content to the overlay as soon as it becomes available rather than waiting for the entire answer to finish.

The overlay should remain compact and legible during live use.

## Scenario profiles

Introduce a `ScenarioProfile` or equivalent abstraction.

Implement V1 profiles for:

- Interview;
- Meeting;
- Academic Defense.

Profiles may influence:

- system prompts;
- tone;
- answer length;
- how aggressively automatic questions are detected;
- response structure;
- whether the model emphasizes concise talking points, factual retrieval, caveats, or technical depth.

Do **not** implement emergency medical dispatch functionality in V1.

However, avoid architecture choices that would prevent a future separate high-assurance EMS dispatch application/profile from reusing the audio, Live, RAG and conversation-state layers.

## Existing Stealth functionality to preserve

Preserve or improve these existing components unless there is a compelling technical reason to change them:

- native Swift / SwiftUI architecture;
- ScreenCaptureKit system-audio capture;
- AVAudioEngine microphone capture;
- menu-bar behavior;
- always-on-top/private overlay;
- screen-share exclusion behavior if currently implemented;
- global hotkeys;
- local session history;
- macOS Keychain secret storage;
- native build/signing workflow.

Before making large architectural changes, inspect how these components currently work and prefer incremental evolution over unnecessary rewrites.

## Settings and UX

Add settings needed for:

- OpenAI API key;
- Live model configuration where appropriate;
- reasoning model;
- embedding model;
- operating mode: Remote Meeting / In-Person;
- scenario: Interview / Meeting / Academic Defense;
- automatic suggestions on/off;
- local knowledge-base management;
- sensible retrieval settings where useful.

Defaults should be useful without requiring the user to understand RAG parameters.

The API key should be entered once and stored securely in macOS Keychain.

## Reliability and graceful degradation

Handle failures without making the whole application unusable.

Cover at least:

- OpenAI API authentication errors;
- Live connection failure/disconnect/reconnect;
- embedding API failure;
- partial/failed indexing;
- empty RAG results;
- malformed reasoning output;
- reasoning-model failure;
- microphone permission failures;
- system-audio/screen-capture permission failures;
- network interruption.

Where possible, transcripts and manual text queries should continue to work when unrelated subsystems fail.

Provide clear user-visible error messages instead of silent failure.

## Latency as a first-class requirement

Optimize the critical live path:

`question completion -> trigger -> local retrieval -> reasoning request -> first useful overlay text`

Keep retrieval local after indexing.

Run independent work concurrently where safe.

Stream the reasoning response.

Instrument key stages so latency can be inspected during development.

Do not introduce infrastructure whose complexity/latency is not justified by measured need.

## Privacy boundary

Document the V1 privacy boundary explicitly.

### Local

- original knowledge-base files;
- extracted/chunked document storage;
- embedding vectors/index;
- retrieval operations;
- local session/history/state where implemented;
- API key in macOS Keychain.

### Sent to OpenAI when required

- live audio/transcription context required by GPT-Live-1;
- document text chunks sent for OpenAI Embeddings during indexing;
- current question/relevant conversation context;
- only the retrieved knowledge chunks required for a reasoning request.

Never commit private documents, transcripts, credentials, or API keys.

## Testing strategy

Do not stop after modifying source files.

Build the native macOS project repeatedly throughout development.

Use mocks/fakes for API-heavy deterministic tests so the test suite does not require real OpenAI calls.

Add automated tests for components such as:

- document chunking;
- document metadata/source tracking;
- lexical retrieval;
- vector similarity;
- hybrid ranking/fusion;
- normalized retrieval-query generation where deterministic;
- question/conversation state transitions;
- duplicate-trigger suppression;
- follow-up handling where testable;
- structured suggestion parsing;
- provider failure handling.

Also add opt-in integration tests or a documented manual test path for real OpenAI APIs.

## Local macOS verification

Because this project is being developed locally on the target Mac, use the native toolchain to verify as much as practical:

- `xcodebuild` succeeds;
- app launches;
- permissions flows do not crash;
- Keychain storage works;
- menu bar and overlay work;
- hotkeys work;
- manual text query works;
- document import/index/retrieval works;
- API-backed manual query works when a valid key is supplied.

For audio behaviors that require the user's participation or another live audio source, prepare a concise checklist and make the app easy to test interactively.

Do not fabricate successful hardware/audio validation if it cannot actually be exercised automatically.

## Documentation

Update README and architecture/setup documentation.

Provide a concise first-run path:

1. build/install LiveCopilot on macOS;
2. launch the app and grant required permissions;
3. enter an OpenAI API key;
4. select models/defaults;
5. import documents and wait for indexing;
6. select Interview / Meeting / Academic Defense;
7. choose Remote Meeting or In-Person mode;
8. start live listening and receive automatic suggestions;
9. use the manual hotkey if needed;
10. use the manual text box for direct questions.

Document model/API assumptions, architecture, privacy boundaries, known limitations, and troubleshooting steps.

## Scope discipline

Prioritize a genuinely usable V1 for Interview / Meeting / Academic Defense.

Do not spend time on:

- EMS/medical dispatch workflows;
- multi-user SaaS;
- account systems;
- billing;
- Windows/mobile support;
- cloud dashboards/databases;
- Ollama/local LLM integration;
- complex distributed vector databases;
- unrelated UI redesigns.

Prefer simple native solutions that make the Mac application reliable and easy to use.

## Required development behavior for Codex

Treat this as an end-to-end implementation goal, not a code suggestion task.

First inspect the repository and establish a working baseline build.

Then create and maintain an implementation plan. Work incrementally, build/test after meaningful milestones, diagnose failures, and continue toward the acceptance criteria without waiting for step-by-step user instructions.

Preserve working functionality unless replacement is necessary.

If official GPT-Live-1 API details differ from assumptions in this document, follow the current official OpenAI API specification and document the adaptation. Do not emulate Live behavior using an obsolete API solely to satisfy wording here.

Do not expose, print, commit, or log the user's full API key.

## Acceptance criteria

The V1 goal is complete when all of the following are true:

- The project builds successfully as a native macOS application.
- Existing useful Stealth macOS capture/overlay behavior has not been unnecessarily regressed.
- The app is branded/configured as LiveCopilot.
- GPT-Live-1 is integrated through the current official Live API.
- Live conversation state can automatically trigger assistance for meaningful questions.
- A manual conversation hotkey can force assistance.
- A manual text input can request an answer without a Live session.
- Remote Meeting and In-Person modes exist.
- Interview, Meeting and Academic Defense scenario profiles exist.
- Users can import supported local documents.
- Documents are chunked and embedded using OpenAI Embeddings in V1.
- Embeddings/vectors, chunks, metadata, indexes and retrieval remain persisted/operated locally after indexing.
- Hybrid semantic + lexical retrieval works.
- A configurable strong OpenAI reasoning model combines question + conversation + retrieved context + general knowledge.
- Knowledge-base-supported claims can show source references.
- Suggestions stream into a concise structured overlay.
- API keys are stored using macOS Keychain with safe development fallback.
- Important failure modes degrade gracefully.
- Deterministic core components have meaningful automated tests.
- Native build/tests pass.
- Real-API/manual macOS verification steps are documented.
- README/setup/architecture/privacy documentation is current.

Before declaring the task complete, review the implementation against every acceptance criterion, run all available builds and tests, fix failures found, and leave the repository in a state where the user can launch LiveCopilot on their Mac, enter their OpenAI API key, import their own documents, and test it in a real interview, meeting, or defense.
