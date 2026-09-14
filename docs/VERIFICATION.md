# Verification and troubleshooting

For the latest language, background and analysis-service update, see `V1_1_UPDATE.md`. The V1 real-API evidence below is historical; it is not a claim of a real DeepSeek call.

## Evidence recorded during development

The latest exact results are maintained in `IMPLEMENTATION_PLAN.md`. Distinguish source implementation, deterministic mocks, native build/test, real API checks, and interactive hardware/UI checks. An API session starting is not proof of successful capture or question detection; setting capture exclusion is not proof of exclusion in a specific meeting app.

## Deterministic checks (no API calls)

### 2026-09-14 — automatic-suggestions switch appearance

The native SwiftUI switch displayed a gray track even with accessibility value `on` in the nonactivating overlay. An explicit tint/active-appearance override did not fix the observed native rendering. `OverlaySwitchStyle` now draws a blue on-track, gray off-track and positional thumb while preserving the shared settings binding and native Toggle accessibility representation. The panel remains nonactivating.

The final universal Release build and 14 native XCTest cases passed (0 failures, 20:02:09); the core suite reported 43 deterministic checks. In an isolated Mock preview, UI clicks verified on/blue and off/gray, Settings reflected the overlay value, and a Settings change updated the overlay. White and glass backgrounds were inspected; the blue on-state remained visible after interacting with Finder. No real audio capture or model API was used for this visual fix. These checks do not establish VoiceOver speech output or physical keyboard navigation on every macOS version.

The current button/task and shared system prompts are documented verbatim in `ASSISTANCE_PROMPTS.md`; this change does not modify them.

Installed as `~/Applications/LiveCopilot.app`, version 1.1.1 / build `20260914.200605`. Strict signature verification passed; both existing Live and analysis credentials became available at 20:06:18 without changing keys. The previous installed app is retained as `LiveCopilot.app.previous.20260914200605`. Signing remains ad-hoc; the new build's ScreenCapture authorization was not exercised by this UI-only verification.

### Suite coverage

`./StealthApp/scripts/test-core.sh` compiles and runs core checks against temporary synthetic files and mocked HTTP providers. Coverage includes Unicode chunking, page/source tracking, cosine edge cases, FTS5/BM25 and CJK search, query escaping, fusion, persistence, deletion, re-index failure/atomic replacement, embedding compatibility, question state, incomplete questions, duplicate/answered suppression, follow-ups, Live event contracts, SSE completion/error handling and structured source parsing.

Xcode `test` additionally verifies typed queries with listening disabled, superseding/cancelling answers, concurrent listening/assistance, stable transcript rows, shutdown cancellation, focused-overlay shortcut handling and native Keychain create/read/update/delete using an isolated dummy item. It never changes the user's real API key.

## Real APIs (opt-in, synthetic material)

The user has authorized real OpenAI integration after key-independent tests. `scripts/integration.sh` reads the specified Keychain item without printing its contents. It creates a temporary synthetic benchmark document, indexes it via OpenAI Embeddings, performs local hybrid retrieval, and verifies that streamed Responses output retains the fixture fact and a source reference.

```bash
./StealthApp/scripts/integration.sh --keychain-check
./StealthApp/scripts/integration.sh
./StealthApp/scripts/integration.sh --live
```

For a paced synthetic speech/delegation check, create test speech locally and pass it to the optional test:

```bash
say -o /tmp/livecopilot-synthetic-question.aiff \
  'In our synthetic benchmark, why did we choose method B, and what is its latency?'
./StealthApp/scripts/integration.sh --live-question --audio /tmp/livecopilot-synthetic-question.aiff
```

The tool sends PCM at real playback pace and waits for transcript/delegation events. Output audio is discarded. This checks protocol and model behavior, **not physical microphone or ScreenCaptureKit behavior**. These commands incur API charges; they are never run by the deterministic suite.

If the installed app has Keychain permission but the separate CLI helper does not, run the same Live check within the installed app's identity. Quit LiveCopilot first, then use the existing installed binary (no rebuild):

```bash
say -o /tmp/livecopilot-synthetic-acceptance.aiff \
  'In our synthetic benchmark, why did we choose method B, and what is its latency?'
open "$HOME/Applications/LiveCopilot.app" --args --verify-live \
  --audio /tmp/livecopilot-synthetic-acceptance.aiff
```

This explicit diagnostic uses only the supplied synthetic audio file, does not start microphone/system capture, and reports fixed status messages in the overlay and metadata log. Cancellation closes its Live connection. A normal launch does not run it. Ad-hoc rebuilding changes the app's code signature and macOS may require access approval for the new build; a previous approval is not proof that a different binary is authorized.

## Interactive macOS checklist

1. Launch the installed app, verify menu-bar icon and overlay. Open Settings and History, close/reopen each. Show/hide with `⌥H`. Resize the overlay and confirm the input/answer remain reachable.
2. With listening **off**, type a question and submit with Ask and Return. Verify progressive output, Cancel, Copy, recent-context toggle, and readable errors on invalid model names. Restore valid settings afterward.
3. Import a nonprivate test PDF/TXT/MD/DOCX. Wait for Ready. Ask a question about an exact number. Expand `[S1]`, check text/page/filename, re-index, restart app and verify persistence. Delete only the test document and verify it no longer appears in retrieval.
4. Test In-Person first: grant Microphone, speak a complete question, observe Room transcript and automatic suggestion. Try a fragmented sentence, pause, continue; check it does not flood the overlay. Test a follow-up and `⌥Space` fallback.
5. Test Remote Meeting using headphones: grant Screen & System Audio Recording, play nonprivate speech in another app and speak into the mic. Confirm Them/You labels; a question from Them should generate help while your own transcript remains available. Mute/unmute You.
6. While a longer answer streams, continue speaking and ask a follow-up. Transcripts should continue; only the latest pending automatic request is retained. Turn automatic suggestions off and confirm manual assistance still works.
7. Deny one permission and verify the remaining input or manual text continues. Disconnect/reconnect network, inspect the visible connection status, then stop/start after retries are exhausted. Stop/quit while a connection is starting and confirm no paid session remains intentionally active.
8. In the actual meeting application's shared-screen preview or a separate viewer, check whether the overlay is excluded. Repeat after macOS/meeting-app updates. If visible, hide the overlay or adjust the sharing workflow before relying on privacy.

## Troubleshooting

| Symptom | Action |
|---|---|
| `xcodebuild` says CLT or license missing | Install/open Xcode; complete its setup; use `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if needed. |
| XcodeGen not found | `brew install xcodegen`; or set `XCODEGEN_BIN` to a complete official XcodeGen installation. Keep its `share/xcodegen` presets next to `bin`. |
| No Dock icon | Versions through 1.1.0 were menu-bar-only. Version 1.1.1 restores the Dock icon; verify the installed version. |
| Keychain read denied / interaction required | Unlock login Keychain and Mac. Launch the installed app and allow access to `LiveCopilot-OpenAI/current username`. Do not paste the Key into chat. CLI may have a different Keychain access identity from the app. |
| Shell environment Key not seen in GUI | Launch the binary from that same shell, or use Keychain. Finder/`open` do not necessarily inherit shell exports. |
| 401 / 403 | Check OpenAI project Key and model access. A valid text API Key does not prove access to GPT-Live-1. |
| 429 | Check API billing, credits and rate limits; retry after limits recover. |
| No transcript | Verify selected mode, input permissions/device, active Live readiness, actual source audio and network. |
| You contains remote speech | Use headphones or mute the optional You microphone. Room mode intentionally does not distinguish speakers. |
| No automatic answer | Check Auto, complete the substantive question, inspect question state; use `⌥Space`. Pauses alone never trigger work. |
| Embedding failure | Existing index stays usable for re-index failures; retry indexing later. Query embedding errors fall back to local keyword retrieval. |
| Scanned / locked PDF | OCR/unlock it outside the app before import. |
| Model changed, semantic retrieval sparse | Re-index documents with the selected embedding model. Older vectors remain excluded from incompatible comparisons. |
| Reasoning fails halfway | Partial text is retained; retry or choose compatible model/effort. |
| Permissions return after rebuild | Ad-hoc signatures may require reapproval. Use a stable signing identity for repeated builds. |
| Screen Recording is enabled but every start prompts again | The visible switch may refer to an older ad-hoc code identity. If macOS TCC logs report `Failed to match existing code requirement` for `com.livecopilot.app` / `kTCCServiceScreenCapture`, quit LiveCopilot, run `tccutil reset ScreenCapture com.livecopilot.app`, reopen the same installed app and grant Screen & System Audio Recording again. Follow any macOS quit/reopen request. This resets only this app's screen-capture authorization, not microphone or Keychain access; do not reset all services/apps. |
| Final Live usage unconfirmed | A disconnect prevented `session.closed`; check OpenAI usage if needed. The app released the local connection. |

### Screen-capture identity mismatch observed on 2026-09-14

The installed 1.1.1 build `20260914.191619` was the only running LiveCopilot copy. Its signature was valid but ad-hoc. macOS TCC logs repeatedly reported that the saved ScreenCapture code requirement did not match the current executable; system-audio start failed with TCC denial while microphone capture succeeded. The enabled Settings switch alone therefore did not prove current access.

The application was quit and its ScreenCapture authorization reset with the scoped command above, then the identical app was reopened without rebuilding/re-signing or changing credentials. After the user granted access, the application logged `AUDIO capture started OK` at 19:33:47; the user also confirmed normal behavior after the stop/start check. Avoid fixing this symptom by repeatedly rebuilding: an ad-hoc rebuild changes the code identity again. A consistent signing identity is the longer-term requirement for smoother updates, distinct from Apple notarization. That signing migration has not yet been performed; future ad-hoc updates may still require renewed permissions.

Do not treat logs from macOS `com.apple.linkd.autoShortcut` or the build-time AppIntents metadata extractor as application test failures when the actual compiler/tests succeed; investigate application errors separately.

## Verified delivery — 2026-09-14

Installed build **20260914.075740** has passed real API acceptance with the updated Keychain credential:

- **Embeddings:** the production UI indexed a synthetic document with `text-embedding-3-small`; its 1536-dimensional vector was verified in local SQLite.
- **Responses:** with listening off, the app streamed and completed the correct **42 ms [S1]** answer. The source disclosure showed the exact synthetic document. First text was **4.3 seconds** in this single run.
- **Official Live:** a paced, locally generated synthetic question produced a transcript and semantic client delegation; both `session.started` and `session.closed` were observed. This verifies the real protocol/model path, not physical audio capture.
- **Native:** Release builds, **34 core checks** and **9 XCTest cases** pass. Tests include a real URLSession transport with a synthetic URLProtocol fixture for SSE boundaries and fragmented UTF-8; no network/key is used by that fixture.
- **UI/lifecycle:** isolated Mock tests covered Ask/Return, automatic suggestions, focused Option+Space, modes/profiles, four-format import, PDF page/excerpt disclosure and persistence. Graceful quit/relaunch passed. The final production app restarted normally, reused Keychain access and shows Ready with listening off.

Acceptance fixed a native termination hang, focused shortcut character insertion, synchronous modal file selection and a real SSE framing bug caused by `AsyncBytes.lines` dropping blank separators. The synthetic production knowledge fixture was deleted by exact name/content match after verification; original test files remain under `/tmp`. No private user document or microphone recording was used.

The earlier 401 applied to the old credential and is resolved. The CLI helper's separate Keychain timeout was an OS access issue, not a failed API authentication for the installed app. Do not replace or resend the working Key merely to run that helper.

### 本机首次体验（约 3–5 分钟）

1. 打开 `~/Applications/LiveCopilot.app`，在设置 → Knowledge 导入一份自己允许发送提取文本给 OpenAI 的资料，等待 Ready。保持监听关闭，提问一个资料中的数字并展开 `[S1]` 核对。
2. 选择 **In-Person**，点击开始并在系统提示中授予麦克风权限。说一个完整问题，检查 Room 转写和自动建议；再用 `⌥Space` 手动触发。
3. 戴耳机切换 **Remote Meeting**，按提示授予屏幕/系统音频权限。用另一应用播放非隐私语音，检查 Them；自己说话检查 You，测试静音及在其他应用前台时的快捷键。
4. 在实际会议软件的共享预览或另一台观看设备中检查悬浮窗排除效果。结束后停止监听。

Physical audio and permission behavior, real network interruption, background global keypresses, full visual/resize checks and actual meeting-app sharing exclusion remain **manual checks, not passed automated evidence**. The longer checklist above covers these cases and expected behavior. This boundary follows the supplied requirement to prepare an interactive path for audio behaviors requiring user participation.
