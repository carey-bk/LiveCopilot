# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="100" alt="LiveCopilot logo">

[中文](README.md) · **English** · [English website](https://carey-bk.github.io/LiveCopilot/en/) · [中文介绍页](https://carey-bk.github.io/LiveCopilot/)

A native macOS conversation copilot for interviews, meetings, and academic discussions. Follow live speech, retrieve relevant material from your own documents, and get suggestions you can say aloud. You can also type a question with listening off.

Built with Swift/SwiftUI on the native macOS foundation of [Stealth](https://github.com/vortechron/stealth). No LiveCopilot account, developer-operated relay server, cloud vector database, or spoken AI responses.

Version **1.4.0** adds independent transcript/answer font sizes (11–28 pt) and Qwen, GLM, and Kimi analysis presets. The retired SenseVoiceSmall selection migrates to Paraformer without resetting other preferences or deleting downloaded weights. See [release notes](docs/V1_4_0_UPDATE.md) and the [service guide](docs/SERVICE_GUIDE.md).

Version **1.4.1** retains these features and adds Developer ID signing, hardened runtime, and Apple notarization. Both the app and DMG include stapled tickets. See [distribution validation](docs/V1_4_1_UPDATE.md).

## Download

[Download LiveCopilot 1.4.1 for macOS](https://github.com/carey-bk/LiveCopilot/releases/download/v1.4.1/LiveCopilot-1.4.1-macOS-universal.dmg) · [Release notes and checksums](https://github.com/carey-bk/LiveCopilot/releases/tag/v1.4.1)

Requires **macOS 14+**, on Apple Silicon or Intel. Apple Speech additionally requires **macOS 26+**, supported hardware, and a supported language. No Xcode, Python, Ollama, or developer tools are needed to use the packaged app.

Quit the previous version, open the DMG, and drag `LiveCopilot.app` into Applications (or `~/Applications`). Keep the app at a consistent path.

Version 1.4.1 is signed by **Developer ID Application: Bokai Zhang (666N9BJMD7)** and notarized by Apple. Both the app and DMG carry stapled tickets; normal installation does not require Open Anyway. macOS may still show its standard first-download confirmation. Migrating from an older ad-hoc build may require renewed audio or Keychain permission; later updates preserve the signing team and bundle identity without bypassing system policy.

## Choose your services

| Stage | Options | Data and cost |
|---|---|---|
| Local speech | Apple SpeechAnalyzer / SpeechTranscriber; Paraformer streaming | On-device recognition with no API usage fee. Initial model downloads require internet. |
| Cloud speech | OpenAI Live | Sends audio to OpenAI; billed to your account. Realtime transcription and semantic question detection. |
| Embeddings | Local BGE-M3 or OpenAI Embeddings | BGE-M3 processes text on-device; OpenAI sends indexing/query text to its API. Retrieval stays local. |
| Answers | OpenAI, DeepSeek, Qwen, GLM, Kimi, or a compatible streaming Chat Completions API | Receives the question, relevant conversation, and retrieved passages. Bring your own service key. |

Choose local speech + BGE-M3 + DeepSeek to keep recognition and indexing on your Mac while using DeepSeek for answers. No OpenAI key is needed for that combination. Local models still use disk space, memory, and compute; analysis still sends relevant text to your chosen provider.

Paraformer updates Chinese/English caption previews as you speak. Apple streams supported languages using on-device models. Compare accuracy and latency using your own voice, accent, hardware, and audio conditions. Local automatic suggestions use conservative text-based question detection; pauses alone do not trigger an answer.

## Get started

1. Open Settings → Services. Select a speech route and download its local model, or configure OpenAI Live.
2. Select BGE-M3 or OpenAI Embeddings under the knowledge service. Select an analysis provider and save its API key.
3. Optionally import PDF, Markdown, TXT, or DOCX in Knowledge. Scanned PDFs require external OCR. Rebuild the index after changing embedding models.
4. Choose Interview, Meeting, or Academic Defense. Remote Meeting captures system audio plus an optional microphone; In-Person uses the microphone without promising speaker separation.
5. Start listening and grant the requested macOS audio permissions. Or type a question without starting capture.

Keys are securely stored in the local macOS Keychain. Startup checks silently; a saved-but-inaccessible key is shown as needing authorization. Old manually created `LiveCopilot-OpenAI` and analysis items can be imported once with **Authorize saved key**. Keys never enter source, logs, or editable fields.

## A small window for the conversation

- Chinese and English UI; glass, soft frost, or white backgrounds. Separate transcript and answer font controls under General → Language & appearance, applied immediately and saved.
- Compact when empty, taller as content arrives. Manual resize and right-edge reveal.
- **Refresh** clears the current transcript, draft, answer, and context. Active listening starts fresh; knowledge and saved history remain.
- Replies use spoken paragraphs, with evidence/notes below when useful. General knowledge and reasoning can extend the documents without inventing personal experience.
- Generate answer, recap, and follow-up have distinct task prompts. Source passages can be expanded.
- **About** links to the author's GitHub, repository, and bilingual product guide.

`Option + H` toggles the overlay. Generate answer, recap, and follow-up shortcuts are configurable. The 1.4.2 development defaults are Control–Option–Space, Control–Option–S and Control–Option–X; saved custom bindings are preserved. Recap and follow-up can be disabled independently in General, hiding their buttons and releasing their shortcuts. Screenshot/sharing exclusion is optional; its behavior depends on macOS and the capture application. Settings and History remain capturable.

Qwen, GLM, and Kimi presets use streamed Chat Completions with provider-specific thinking controls. Defaults are `qwen-plus`, `glm-5.2`, and `kimi-k2.6` on domestic general API endpoints. Edit the base URL for a matching region/account, save, then configure its key. Keys are isolated by provider and endpoint. Protocol and mock tests passed; real account access has not been tested with Qwen, GLM, or Kimi credentials. No keys are needed for development/mock testing; enter yours only in the app to validate a real request.

## Privacy and limits

The DMG contains no keys, personal documents, history, or knowledge database. Documents, indexes, and session history stay local. Selected cloud services receive the content described above; their retention policies still apply. Refreshing or deleting local data does not retract previous requests.

Check important facts and citations. The app does not provide OCR, reliable multi-speaker diarization, or cloud backups. Headphones help prevent remote audio leaking into microphone transcription. See [privacy boundaries](docs/PRIVACY.md), [local models](docs/LOCAL_MODELS.md), and [verification notes](docs/VERIFICATION.md).

## Build and verify

Install full Xcode and XcodeGen, then:

```bash
./StealthApp/scripts/test-core.sh
./StealthApp/scripts/build.sh
xcodebuild -project StealthApp/LiveCopilot.xcodeproj -scheme LiveCopilot \
  -configuration Debug -derivedDataPath StealthApp/build CODE_SIGNING_ALLOWED=NO test
```

The build downloads checksum-pinned sherpa-onnx/llama.cpp runtimes and compiles a universal inference helper. Debug uses a separate bundle identifier to avoid taking over production permissions. Mock checks do not use real keys or paid APIs.

From a clean, committed checkout, `./StealthApp/scripts/package-dmg.sh` builds the DMG. See [publishing instructions](docs/RELEASING.md). Preview the bilingual site with `python3 StealthApp/scripts/build-site.py`, then serve `_site/` with a local HTTP server.

## Attribution

Derived from Stealth commit `02b78cc82195a1711e3de11adfaed26011635dae`, by vortechron. Original Git history and the [MIT license](LICENSE) are preserved. Inference runtimes retain their own notices in the app. Editable SVG logos are in [assets/brand](assets/brand/README.md).

[Author: carey-bk](https://github.com/carey-bk) · [LiveCopilot repository](https://github.com/carey-bk/LiveCopilot)
