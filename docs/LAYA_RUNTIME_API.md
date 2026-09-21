# Laya runtime integration contract

Native integration interface. User setup and behavior are described in [LAYA.md](LAYA.md).

`@MainActor LayaRuntimeManager(root: URL, resources: URL? = nil)` owns an isolated installation below `root`. Default resources are `Bundle.main.resourceURL/LayaRuntime`; add **Resources/LayaRuntime as a folder resource** to the Xcode target. The manager does not access API credentials.

- `@Published private(set) var state: State`, where `State` is `unsupported`, `notInstalled`, `installed`, `installing`, `loading`, `ready`, or `failed`.
- `@Published private(set) var message: String` and `progress: Double?` report fixed, transcript-free status messages.
- `var isReady: Bool`, `var isBusy: Bool`, `var isInstalled: Bool`.
- `install()` explicitly downloads the pinned Python/runtime/model and warms the worker. `prepare()` only warms an existing installation; it never downloads implicitly.
- `prepareAndWait() async throws` waits for a local warmup. `predict(text: String, context: String) async throws -> Double` returns the model's `answers.needs_response.probabilities.respond` (positive intent probability), never `confidence` or `action.act_probability`.
- `cancel()` cancels installation/warmup and tears down the current worker. `stop()` releases the warm process and invalidates in-flight requests while keeping downloaded files. `shutdown() async` also joins pending preparation.
- Keep manual generation available when the manager is not ready or errors. On stopping/resetting/changing gate, invalidate the trigger controller before calling `stop()`.

Local real-model checks will install at `~/Library/Application Support/LiveCopilot/Development/Laya`, exclusively for the Dev app. The production app/data and shared ASR models are untouched.

The Python worker uses a persistent NDJSON channel, pins the multilingual checkpoint, classifies the latest utterance as structured JSON, computes a token-aware suffix budget including the actual question/options prefix, and never logs transcripts. Both the native process wrapper and worker reject malformed/oversized/non-finite responses. Warmup uses a fixed synthetic statement. Scores are uncalibrated for this product until measured on representative conversations.
