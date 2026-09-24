# Local audio and knowledge models

Dev 20260924.008 update: Paraformer and Apple Speech only produce captions and speech activity. When automatic suggestions are enabled, Laya decides whether a completed local utterance needs analysis; the former provider question-rule selector and provider delegation have been removed. GPT-Live-1 uses its own client delegation. The V1.4.0 and V1.3.0 notes below are historical records of the previous behavior.

The user's September 14 request extends the original OpenAI-only V1 scope. Preserve the native Swift app and the selectable OpenAI Live/Embeddings services. The local route must not require an OpenAI credential or silently send audio/document indexing requests to the cloud.

Current in V1.4.0 (historical acceptance notes below retain their original scope):

1. Package pinned native sherpa-onnx and llama.cpp runtimes with the application. Paraformer bilingual streaming INT8 + Silero VAD handles audio; BGE-M3 Q8 handles dense embeddings.
2. Add verified, cancellable model downloads and independent listening/embedding selectors. Downloaded weights live outside the repository and application bundle.
3. Connect native audio capture, bounded local inference workers and conservative Chinese/English question rules to the existing conversation/RAG pipeline. Preserve the manual shortcut fallback.
4. Exercise missing/corrupt models, cancellation, index compatibility, startup/shutdown, Chinese/English synthetic audio and real local retrieval; then compile, inspect the UI and install once.

DeepSeek (or the user's selected analysis service) still receives the question, relevant recent conversation and retrieved excerpts when an answer is requested. VAD endpoints are not semantic question completion; the local trigger is a conservative heuristic, not equivalent to a Live comprehension model.

## Configuration

- Services → Live service → **Local · Paraformer-zh-streaming** for live Chinese/English captions (approximately 238 MB). This bilingual export supports both languages; it is not an English accuracy guarantee. V1.4 removes the non-streaming SenseVoiceSmall selection and automatically migrates its saved preference to Paraformer. Existing weights are left on disk; download Paraformer if it is not installed.
- Services → Knowledge service → **Local · BGE-M3**. Download the embedding pack if missing (approximately 635 MB).
- Services → Analysis service → **DeepSeek**, using its existing Keychain credential. OpenAI Live and OpenAI Embeddings remain independently selectable; old settings retain those routes on upgrade until explicitly changed.
- Model downloads use SHA-256 verification, retry/resume when the server supplies resume data, cancellation, staging and atomic replacement with rollback. A failed install preserves the prior model. After installation, inference works without network access. No Python/Ollama/Docker runtime is required.
- Switching embedding providers requires re-indexing. The Knowledge page identifies mismatched documents and provides **Re-index all**. Document copies stay local, and failed re-indexing preserves previous vectors. A missing/unusable query model can fall back visibly to local keyword retrieval; import requires the selected model to be installed.

Weights are outside the app at `~/Library/Application Support/LiveCopilot/Models/`. Receipts mark completed installations and record exact file sizes; a missing/truncated payload is not considered installed. Full cryptographic checks run during installation rather than rehashing every large model at each app launch. Runtime load failures remain visible, with no automatic cloud fallback.

## Runtime and model provenance

| Component | Pinned source | License / behavior |
| --- | --- | --- |
| sherpa-onnx | [v1.13.8 universal macOS shared runtime](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8) | Apache-2.0; Paraformer and VAD C APIs; CPU inference |
| llama.cpp | [b10955 macOS universal framework](https://github.com/ggml-org/llama.cpp/releases/tag/b10955) | MIT; BGE-M3, Metal/CPU backend |
| Paraformer streaming INT8 | [sherpa-onnx bilingual deployment](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/paraformer-models.html), [pinned conversion](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/tree/8e40c43232a1c5c66c82111efc5820d3accca11b) | Apache-2.0; encoder 165,462,184 bytes, decoder 71,664,561 bytes, tokens 75,756 bytes; zh/en; CPU |
| Silero VAD | [sherpa-onnx maintained ONNX export](https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html) | 643,854 bytes; 16 kHz; 512-sample windows |
| BGE-M3 | [BAAI model](https://huggingface.co/BAAI/bge-m3), [GPUStack Q8 conversion](https://huggingface.co/gpustack/bge-m3-GGUF/tree/2d48f1737679ad900d5c26c5aad5410e9c70fdca) | Q8_0, 634,553,760 bytes; CLS pooling, L2 normalization, 1024 dimensions; up to 8192 input tokens |

Exact runtime and weight SHA-256 values are pinned in `scripts/build-local-runtime.sh` and `Core/LocalModels.swift`. Native third-party license notices ship in the app. Build-generated runtime binaries and downloaded weights are ignored by Git. The helper's architecture is universal arm64/x86_64; execution was validated on the user's Apple M4 Max, not on Intel hardware.

## Local trigger and latency

Paraformer retains streaming encoder/decoder state across audio chunks. It emits replaceable previews while speech continues; the UI renders these separately from committed transcripts. VAD starts decoding with up to 500 ms of buffered audio, finalizes after pauses or a 12-second segment, and creates fresh decoding state for the next utterance. Stop signals final input and drains the final short chunk. The model does not supply word timestamps; fragment offsets use audio/VAD boundaries. Preview latency includes VAD onset, the model chunk and inference time, and is not a fixed 600 ms guarantee.

The local trigger recognizes explicit Chinese/English questions and requests, rejects common fillers, incomplete endings, reported questions and explicit cancellations, and waits 900 ms for stable local silence before delegation. The existing coordinator then applies its 650 ms settling interval, scenario cooldown, duplicate/answered-question suppression and latest-pending policy. Resumed VAD speech holds pending assistance. `You` transcripts never delegate; Room does not identify individual speakers. Indirect questions, rhetorical phrasing, interruptions and ASR errors can still cause misses or false positives. No small LLM or cloud classification call is hidden in this route. Use the manual hotkey whenever necessary.

## V1.2.2 streaming acceptance

The bilingual model produces replaceable live captions and stable final sentences; Chinese/English fixture question delegation, no self-delegation, silence suppression and stop/normal-endpoint equivalence passed. Streaming preview count was 6 for the English fixture and 10 for Chinese. **English terminology was imperfect**: “latency” became “lency” in the live fixture, also misrecognized by the upstream example. Chinese recognized “延迟” but rendered method B as “方法比.” For English-heavy conversations, compare Apple English or GPT-Live-1; support for a language is not an accuracy guarantee. See [the exact verification boundaries](VERIFICATION.md). Final GUI and hardware capture checks remain pending because the Mac was locked.

## Recorded verification — 2026-09-14

- **52 deterministic core checks** passed: preference migration, credential requirements, Chinese/English trigger rules, invalid/partial downloads, cancellation, atomic install rollback, short JSON-lines reads, worker timeout/shutdown, and existing RAG/API regression coverage.
- **14 native XCTest cases**, zero failures; final run at **21:20:12**. Universal Release build passed. Framework minimum deployment versions were inspected: llama macOS 13.3, ONNX Runtime Intel 10.15 / arm64 11.0; the app still targets macOS 14.
- Real SenseVoice + Silero transcribed locally generated English and Chinese questions correctly and delegated once. The same English question on `You` transcribed with zero delegations. Silence produced no transcript; flushing speech without a final silence retained the final question. No real microphone/system capture or cloud API was used in this test.
- BGE-M3 gave cosine **0.7773** for a Chinese latency question paired with the matching English fact versus **0.3283** for an unrelated food sentence. A real local import persisted 1024-dimensional vectors; reopening SQLite and querying in Chinese retrieved the English **42 milliseconds** fixture. A warm synthetic query including embedding/retrieval took **12 ms** in the final run. This tiny fixture is not a relevance benchmark or production latency SLA; initial runtime/shader loading was substantially slower in the first run.
- Mock UI verified three independent service roles, local selectors, missing-model status, network download initiation/cancellation/retry state, and DeepSeek selection. Installed production UI verified both models ready and the existing DeepSeek credential available. The three existing knowledge documents were backed up and re-indexed locally: **3 Ready documents, 8 vectors, 1024 dimensions**, all carrying the local BGE-M3 identity. No document contents entered diagnostics or Git.
- Installed **1.2.0 / 20260914.212128** at `~/Applications/LiveCopilot.app`. Main executable SHA-256: `f3087d9ee99a4145b8b889d94b01dbaa0a1559af8b9026f2ee3946a469ce62bd`. Strict recursive code-sign verification passed. Previous app: `LiveCopilot.app.previous.20260914212128`; preferences and SQLite backups are in the app's local `Backups` folder. The selected configuration is local speech + local embeddings + the user's existing DeepSeek model. Signing remains ad-hoc.
- New real DeepSeek answers and macOS capture permissions were not part of the local-model fixture check. Prior V1 cloud/hardware evidence remains historical. This update has not been published as a new GitHub release.

For repeatable developer acceptance, run `scripts/build-local-runtime.sh`, then `scripts/test-local.sh <isolated-model-root> <absolute-runtime-executable> <verified-download-cache>`. The cache contains the download names pinned in `LocalModels.swift` (including `paraformer-encoder.int8.onnx`, `paraformer-decoder.int8.onnx` and `paraformer-tokens.txt`). The test generates synthetic speech with macOS `say`, installs verified model copies into the isolated root and makes no cloud API calls. `paraformer-only` limits the run to streaming speech. Paraformer fixtures are paced at real time and assert multiple previews before the audio finishes, one Laya gate decision for each non-user question, no provider rule delegation, silence suppression and stop flushing.

## Apple speech (V1.3.0)

Services → Live service → Apple selects `SpeechAnalyzer` + `SpeechTranscriber` and Apple's `SpeechDetector`. Requires macOS 26+ and a supported device/locale; the app still runs on macOS 14+ with its other providers. Choose Mandarin (`zh_CN`) or English US (`en_US`) separately from the interface language. This route does not automatically switch languages or diarize room speakers.

The Services card reserves the selected locale and reports readiness, with an explicit download button if needed. Apple manages shared language assets, so they do not appear in LiveCopilot's Models folder. Reservation is needed even if another app has already downloaded the assets; it does not itself download speech models. Runtime never falls back to server recognition.

Audio enters at mono PCM16/16 kHz, is adapted to the analyzer's compatible format, and carries source-relative timestamps. Revisable preview ranges remain outside conversation context. Only finalized text enters history and retrieval. Apple speech activity and final text feed Laya's local decision; silence alone does not trigger analysis. The two remote audio sources use separate providers; microphone (`You`) does not auto-trigger. Stopping drains the analyzer's final result, with a 15-second cancellation deadline once initialized. A truly silent stream may be rejected by Apple's recognizer at finalization; the app treats only that specific no-speech rejection as a clean stop.

Run `StealthApp/scripts/test-apple.sh /path/to/synthetic-fixtures` (en.aiff, zh.aiff, own.aiff). `APPLE_ASR_INSTALL=1` explicitly permits the test process to acquire language assets first. No capture or cloud API keys are used. [1.3.0 evidence](V1_3_0_UPDATE.md) includes sample accuracy limits.
