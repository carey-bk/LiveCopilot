# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="88" alt="LiveCopilot">

**English** · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

**Follow the conversation. Find your evidence. Answer in your own words.**

A native macOS assistant for interviews, meetings and academic discussions. LiveCopilot transcribes speech, retrieves relevant passages from your documents and streams answer suggestions in a floating window. You can also type a question without starting the microphone.

[Download 2.12](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12) · [Product website](https://carey-bk.github.io/LiveCopilot/en/) · [Release notes](docs/releases/2.12.md)

## Download and requirements

**2.12 · 538 MB · Universal macOS app · Developer ID signed and Apple notarized**

[Download DMG from GitHub](https://github.com/carey-bk/LiveCopilot/releases/download/v2.12/LiveCopilot-2.12-macOS-universal.dmg) · [Release page and checksums](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12) · Netdisk mirrors are listed on the [product website](https://carey-bk.github.io/LiveCopilot/en/#download).

| Component | Requirement |
|---|---|
| Application | macOS 14 or later; Apple Silicon or Intel |
| Local Laya automatic triggering | Apple Silicon; model included |
| Apple local speech | macOS 26 or later, supported hardware and language |
| AI answers | Your own API key for a supported analysis service |

The installer **includes the Arctic retrieval model and the Laya trigger model**, so searching your documents and automatic triggering need no model download. The optional local speech models are downloaded in the setup guide or Settings → Services: Zipformer about **200 MB**, Paraformer about **238 MB**; on macOS 26, Apple on-device speech needs no LiveCopilot download. No separate Python, Ollama or Docker installation is needed. Local models use disk space and your Mac's memory and compute.

Open the DMG, drag LiveCopilot into Applications and launch it there. Existing users can choose **LiveCopilot → Check for Updates…** in the application menu: 2.11 downloads a 2.1 MB delta and 2.10.0 a 3.7 MB delta; older versions download the full installer. From 2.12, updates switch to a Hong Kong mirror when GitHub cannot be reached. Normal upgrades preserve settings, API keys, documents and history. Documents indexed with the earlier BGE-M3 model are re-indexed with Arctic automatically when their original files are available.

## What’s new in 2.12?

- Fixed: with many answers, the overlay could freeze for minutes (affected 2.10 and 2.11).
- Overlay tips light up what they point at and dim the rest of the window.
- Report a problem packs the app log, freeze records and macOS reports into a ZIP you can review, then opens an email to the author with it attached. When the app stops responding for more than 3 seconds, it records where it was stuck.
- In-app updates try GitHub first and switch to a Hong Kong mirror when GitHub cannot be reached; the download page link opens the website's download section.
- The setup guide's answer-service step fits without scrolling; the built-in Arctic model no longer shows download wording.

Full notes: [docs/releases/2.12.md](docs/releases/2.12.md).

## Start your first conversation

1. **Install and open the setup guide.** The six-step guide walks you through choosing an input mode, preparing speech recognition and testing your answer service. The guide can be reopened from Overview in Settings.
2. **Prepare speech recognition.** On macOS 26, Apple on-device speech is the default. For Chinese/English you can also download the local Zipformer. Arctic for document retrieval and Laya for automatic triggering on Apple Silicon are already included.
3. **Connect your analysis service.** Choose OpenAI, DeepSeek, Qwen, GLM, Kimi or a compatible streaming Chat Completions endpoint, then save your API key.
4. **Add context if needed.** Import PDF, Markdown, TXT or DOCX into Knowledge. Scanned PDFs need OCR first. Rebuild document indexes after changing the embedding model.
5. **Listen or type.** In-person mode uses the microphone; remote-meeting mode captures system audio with an optional microphone. Grant the relevant macOS permissions. You can also type with listening off.
6. **Review the session.** Read answers and source passages in the floating window, then revisit questions, answers and citations in History.

`⌥H` shows or hides the floating window. Answer, recap and follow-up shortcuts are configurable. Always review important facts and citations.

## Choose where processing happens

| Stage | Available services | What leaves your Mac? |
|---|---|---|
| Speech recognition | Local Zipformer, Paraformer or Apple; OpenAI Live | Local recognition stays on-device. OpenAI Live sends audio to OpenAI. |
| Document indexing and retrieval | Local Arctic (included) or OpenAI Embeddings | Arctic runs locally. OpenAI Embeddings receives indexing/query text; retrieval storage remains local. |
| Automatic response triggering | Local Laya for local speech; OpenAI Live's semantic delegation | Laya's decision runs on-device. Cloud speech follows its provider's data handling. |
| Answer generation and automatic titles | Your selected analysis API | Relevant question/conversation text and selected evidence; automatic titles use session Q&A context. |

For example, **Zipformer + Arctic + DeepSeek** keeps speech recognition and indexing local and uses DeepSeek for answers. That combination does not require an OpenAI key. Local processing has no API usage fee; cloud services may charge your account.

## Privacy and practical limits

- API keys are stored in the local macOS Keychain. Documents, indexes and session history are stored locally. There is no LiveCopilot account or developer-operated relay server.
- Local speech does **not** mean fully offline answers: the chosen analysis provider receives relevant text. Its retention and billing policies apply. Deleting local history cannot retract earlier API requests.
- Screen-sharing/recording exclusion is optional and off by default. Verify it with the actual meeting application; settings and history remain visible to capture.
- No built-in OCR, guaranteed speaker separation, spoken AI responses or cloud backup. Laya may miss a request or trigger incorrectly. Intel app support does not imply Intel support for Laya.

[Privacy details](docs/PRIVACY.md) · [Service guide](docs/SERVICE_GUIDE.md) · [Local models](docs/LOCAL_MODELS.md)

## Development and documentation

Built with Swift/SwiftUI. Full Xcode and XcodeGen are required to build from source:

```bash
./StealthApp/scripts/test-core.sh
./StealthApp/scripts/build.sh
xcodebuild -project StealthApp/LiveCopilot.xcodeproj -scheme LiveCopilot \
  -configuration Debug -derivedDataPath StealthApp/build CODE_SIGNING_ALLOWED=NO test
```

Model weights are not stored in Git: release packaging stages the bundled Arctic and Laya models from a local asset folder and checks them before signing. Native runtime dependencies are checksum-pinned. Debug uses a separate bundle identifier. Mock checks need no API key or paid requests. Distribution signing and notarization are separate steps; follow the release guide before packaging.

| Documentation | Purpose |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | Components and data flow |
| [Verification](docs/VERIFICATION.md) | Tests and evidence boundaries |
| [Model distribution](docs/MODEL_RELEASE_READINESS.md) | Model pins and release requirements |
| [Release guide](docs/RELEASING.md) | Signing, notarization, packaging and updates |
| [Report an issue](https://github.com/carey-bk/LiveCopilot/issues) | Include app/macOS versions and model diagnostics; omit keys and private conversation text |

Technical documentation is maintained in English. These three README editions describe the same release; the app's interface is available in English, Simplified Chinese and Traditional Chinese.

## Credits and license

Derived from [vortechron/stealth](https://github.com/vortechron/stealth), preserving upstream Git history and the [MIT license](LICENSE). Runtime dependencies retain their own license notices. [Author: carey-bk](https://github.com/carey-bk).

---

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)
