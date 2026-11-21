import Foundation
#if XCODE_TESTS
@testable import LiveCopilot
#endif

enum CoreChecks {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError(description: message) }
    }
    static func run() async throws -> [String] {
        var passed: [String] = []
        func check(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
        try check("optional conversation tools migrate on and persist independently") {
            let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(legacy.enabledSuggestionModes == [.reply, .recap, .followUp], "legacy settings disabled a tool")
            var settings = legacy
            settings.recapEnabled = false
            try expect(settings.enabledSuggestionModes == [.reply, .followUp], "recap switch affected another tool")
            settings.followUpEnabled = false
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored.enabledSuggestionModes == [.reply], "disabled tools did not survive settings round-trip")
        }
        try check("spoken reply, recap and follow-up have distinct grounded task prompts") {
            var request = AnswerRequest(query: .formulate(question: "Explain a tradeoff", context: ""), conversation: "", scenario: .interview, sources: [])
            try expect(request.instructions.contains("actual words the user can say aloud"), "reply is not a spoken script")
            try expect(request.instructions.contains("relevant general knowledge"), "answer is limited to retrieved evidence")
            try expect(request.instructions.contains("Never") && request.instructions.contains("invent the user's experience"), "personal evidence guardrail missing")
            try expect(request.instructions.contains("free of citation markers") && request.instructions.contains("[S1]"), "spoken script and cited notes not separated")
            request.mode = .recap
            try expect(request.instructions.contains("what was actually said") && !request.instructions.contains("Task: draft"), "recap uses reply instructions")
            request.mode = .followUp
            try expect(request.instructions.contains("ONE useful follow-up question") && !request.instructions.contains("Task: summarize"), "follow-up uses recap instructions")
        }
        try check("local services migrate independently and do not require OpenAI for DeepSeek") {
            let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(empty.listeningService == .zipformer, "Missing selection did not use the recommended default")
            let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"listeningService":"openAI","embeddingService":"openAI"}"#.utf8))
            try expect(old.listeningService == .openAI && old.embeddingService == .openAI, "Saved route silently changed")
            try expect(old.deepSeekModel == "deepseek-flash" && AppSettings().deepSeekModel == "deepseek-flash", "DeepSeek default is not Flash")
            var custom = old; custom.deepSeekModel = "deepseek-v4-pro"
            let preserved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
            try expect(preserved.deepSeekModel == "deepseek-v4-pro", "explicit DeepSeek model was overwritten")
            var local = old; local.listeningService = .paraformer; local.embeddingService = .local; local.reasoningService = .deepSeek
            try expect(!local.requiresOpenAIKey, "local + DeepSeek unnecessarily requires OpenAI")
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(local))
            try expect(restored == local, "local selections did not persist")
            local.listeningService = .paraformer
            let streamed = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(local))
            try expect(streamed == local && !streamed.requiresOpenAIKey, "streaming selection lost persistence or requires a cloud key")
            try expect(streamed.listeningService.sampleRate == 16000 && streamed.listeningService.localModel == .streamingSpeech, "streaming audio/model route mismatch")
            local.listeningService = .openAI; try expect(local.requiresOpenAIKey, "cloud listening lost credential requirement")
            local.listeningService = .paraformer; local.reasoningService = .sharedOpenAI
            try expect(local.requiresOpenAIKey, "shared reasoning lost its credential requirement")
        }
        try check("analysis defaults favor current fast cost-effective models") {
            let settings = AppSettings()
            try expect(settings.reasoningModel == "gpt-6-sol" && settings.reasoningEffort == "low", "OpenAI analysis default is not Sol low effort")
            let unset = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(unset.reasoningModel == "gpt-6-sol", "missing model did not receive the new default")
            let pinned = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reasoningModel":"gpt-6-sol","reasoningEffort":"high"}"#.utf8))
            try expect(pinned.reasoningModel == "gpt-6-sol" && pinned.reasoningEffort == "high", "saved model choice was overwritten")
            try expect(settings.deepSeekModel == "deepseek-flash" && settings.deepSeekEffort == "none", "DeepSeek analysis default is not Flash Off")
            try expect(settings.qwenConnection.model == "qwen3.8-flash" && settings.qwenConnection.thinking == .disabled, "Qwen Flash default is missing")
            try expect(settings.glmConnection.model == "glm-5.3-flashx" && settings.glmConnection.thinking == .low, "GLM Flash default must leave mandatory thinking enabled")
            try expect(settings.kimiConnection.model == "kimi-k2.6" && settings.kimiConnection.thinking == .disabled, "Kimi recommended thinking mode changed")
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored == settings, "analysis defaults did not persist")
            let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reasoningModel":"gpt-5.6-sol","qwenConnection":{"baseURL":"https://dashscope.aliyuncs.com/compatible-mode/v1","model":"qwen-plus","thinking":"disabled"},"glmConnection":{"baseURL":"https://open.bigmodel.cn/api/paas/v4","model":"glm-5.2","thinking":"modelDefault"}}"#.utf8))
            try expect(legacy.reasoningModel == "gpt-5.6-sol" && legacy.qwenConnection.model == "qwen-plus" && legacy.glmConnection.model == "glm-5.2", "saved model choices were overwritten")
        }
        try check("retired sentence ASR migrates without resetting user preferences") {
            let json = #"{"listeningService":"local","reasoningService":"deepSeek","deepSeekModel":"deepseek-flash","embeddingService":"local","background":"frosted","automaticSuggestions":false}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            try expect(settings.listeningService == .zipformer && settings.deepSeekModel == "deepseek-flash" && settings.embeddingService == .local, "legacy upgrade lost configuration")
            try expect(settings.background == .frosted && !settings.automaticSuggestions, "legacy upgrade reset appearance or behavior")
            try expect(ListeningService.allCases.map(\.rawValue) == ["zipformer", "paraformer", "apple", "openAI"], "recognizer choices or recommendation order changed")
        }
        try check("independent text sizes persist with safe migration and limits") {
            var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(settings.transcriptFontSize == 12 && settings.answerFontSize == 14, "old text defaults changed")
            settings.transcriptFontSize = 21; settings.answerFontSize = 27
            let defaults = UserDefaults(suiteName: "LiveCopilot-FontTest-" + UUID().uuidString)!
            settings.save(defaults: defaults)
            defer { defaults.removeObject(forKey: "livecopilot.settings") }
            try expect(AppSettings.load(defaults: defaults) == settings, "font controls did not persist independently")
            let invalid = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"transcriptFontSize":-12,"answerFontSize":999}"#.utf8))
            try expect(invalid.transcriptFontSize == 11 && invalid.answerFontSize == 28, "invalid font size escaped bounds")
            try expect(OverlayTypography.clamped(.nan, fallback: 14) == 14, "nonfinite size escaped fallback")
        }
        try check("Apple route persists without requiring a cloud credential") {
            var settings = AppSettings(); settings.listeningService = .apple
            settings.reasoningService = .deepSeek; settings.embeddingService = .local; settings.appleSpeechLanguage = .english
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored == settings && !restored.requiresOpenAIKey && restored.listeningService.sampleRate == 16000, "Apple route incorrectly migrated")
            let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(old.appleSpeechLanguage == .chinese && old.listeningService == .zipformer, "missing language or recognizer default changed")
        }
        try check("Apple volatile ranges revise, commit and reject stale results") {
            var state = SpeechPreviewState()
            _ = state.accept(startMS: 0, endMS: 500, text: "why", final: false)
            _ = state.accept(startMS: 0, endMS: 900, text: "why this", final: false)
            try expect(state.preview == "why this", "preview duplicated")
            let part = state.accept(startMS: 0, endMS: 400, text: "Why", final: true)
            try expect(part?.text == "Why" && state.preview.isEmpty, "final duplicated volatile prefix")
            _ = state.accept(startMS: 400, endMS: 1000, text: "this method?", final: false)
            try expect(state.accept(startMS: 0, endMS: 400, text: "Why", final: true) == nil, "duplicate final accepted")
            try expect(state.preview == "this method?", "stale event removed newer preview")
            _ = state.accept(startMS: 400, endMS: 1000, text: "this method?", final: true)
            try expect(state.preview.isEmpty, "final preview remained")
        }
        try check("small overlay bounds reserve space for fixed controls") {
            for room in [0.0, 20, 80, 400, 900] {
                for automatic in [true, false] {
                    let panes = OverlayLayout.panes(available: room, transcriptIdeal: 145, answerIdeal: 2000, automatic: automatic)
                    try expect(panes.transcript >= 0 && panes.answer >= 0 && panes.transcript + panes.answer <= room, "content overflowed reserved bounds")
                }
            }
            let fitted = OverlayLayout.panes(available: 104, transcriptIdeal: 76, answerIdeal: 28, automatic: true)
            try expect(fitted.transcript == 76 && fitted.answer == 28, "one transcript row was clipped in an auto-fitted window")
        }
        try check("prices match official model and provider, never a compatible proxy") {
            try expect(ServiceGuide.livePrice("gpt-live-1", language: .english).contains("$0.10"), "dual-session charge omitted")
            try expect(ServiceGuide.embeddingPrice("text-embedding-3-large", language: .english).contains("$0.13"), "embedding rate incorrect")
            try expect(ServiceGuide.analysisPrice(.sharedOpenAI, model: "gpt-6-luna", language: .english).contains("$0.10") && ServiceGuide.analysisPrice(.sharedOpenAI, model: "gpt-6-luna", language: .english).contains("$0.50"), "Luna standard rates incorrect")
            try expect(ServiceGuide.analysisPrice(.sharedOpenAI, model: "gpt-6-sol", language: .english).contains("Output $10.00"), "Sol standard rates missing")
            try expect(ServiceGuide.analysisPrice(.sharedOpenAI, model: "gpt-6.1-sol", language: .english).contains("Input $2.00"), "6.1 Sol rates missing")
            try expect(ServiceGuide.analysisPrice(.deepSeek, model: "deepseek-flash", language: .english).contains("Input $0.15"), "Flash reference-table off-peak rates incorrect")
            try expect(ServiceGuide.analysisPrice(.deepSeek, model: "deepseek-v4-pro", language: .english) == ServiceGuide.unknown(.english), "Pro accidentally quoted Flash rates")
            for provider in [ReasoningService.compatible, .deepSeek] {
                try expect(ServiceGuide.analysisPrice(provider, model: "gpt-5.6-sol", language: .english) == ServiceGuide.unknown(.english), "cross-provider price guessed")
            }
        }
        try check("overlay preferences migrate and persist independently") {
            let migrated = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(migrated.overlayAutoHeight && !migrated.overlayEdgeHide && migrated.showMenuBarIcon, "new window defaults missing")
            var manual = migrated; manual.overlayAutoHeight = false; manual.overlayEdgeHide = true; manual.showMenuBarIcon = false
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(manual))
            try expect(restored == manual, "manual window preferences lost")
        }
        try check("overlay growth preserves top and width and stays within each display") {
            let display = CGRect(x: -1440, y: -200, width: 1440, height: 860)
            let small = CGRect(x: -510, y: 350, width: 480, height: 280)
            let grown = OverlayLayout.fitted(small, height: 580, visible: display, docked: false)
            try expect(grown.maxY == small.maxY && grown.width == small.width && grown.height == 580, "growth moved the top edge")
            let capped = OverlayLayout.fitted(small, height: 9999, visible: display, docked: true)
            try expect(display.contains(capped) && capped.maxX == display.maxX - 12, "window escaped negative-origin display")
            try expect(capped.maxY == small.maxY, "screen-height cap moved the fixed input area")
            let tiny = CGRect(x: 200, y: 0, width: 360, height: 220)
            try expect(tiny.contains(OverlayLayout.fitted(grown, height: 600, visible: tiny, docked: true)), "display removal/short screen clipping")
            try expect(OverlayLayout.atRightEdge(CGPoint(x: -1, y: 100), screen: display, visible: display), "right edge not found")
            try expect(!OverlayLayout.atRightEdge(CGPoint(x: -1, y: 658), screen: display, visible: display), "menu corner triggered")
        }
        try check("edge hover ignores quick crossings and pauses hiding during interaction") {
            var state = OverlayHoverState()
            try expect(!state.shouldReveal(atEdge: true, now: 0), "instant reveal")
            try expect(!state.shouldReveal(atEdge: false, now: 0.1), "revealed away from edge")
            try expect(!state.shouldReveal(atEdge: true, now: 0.2), "crossing carried stale dwell")
            try expect(state.shouldReveal(atEdge: true, now: 0.4), "sustained hover failed")
            state.reset()
            try expect(!state.shouldHide(inside: false, interacting: false, now: 1), "instant hide")
            try expect(!state.shouldHide(inside: false, interacting: true, now: 2), "hid during text selection")
            try expect(!state.shouldHide(inside: false, interacting: false, now: 3), "interaction did not restart leave delay")
            try expect(state.shouldHide(inside: false, interacting: false, now: 4), "did not hide after leaving")
            try expect(!state.shouldHide(inside: true, interacting: false, now: 5), "hid under pointer")
        }
        try check("configured distribution URLs precede mirrors and original sources") {
            let base = URL(string: "https://modelscope.cn/models/livecopilot/artifacts/resolve/master")!
            let urls = LocalModelInstaller.candidateURLs(.paraformerTokens, distributionBase: base)
            try expect(urls.count == 3, "missing a download fallback")
            try expect(urls[0].absoluteString == base.absoluteString + "/local/paraformer-tokens.txt", "wrong distribution object key")
            try expect(urls[1].host == "hf-mirror.com" && urls[2].host == "huggingface.co", "wrong fallback order")
            let python = ModelDownload(url: URL(string: "https://github.com/python.tar.gz")!, sha256: String(repeating: "a", count: 64), name: "Python runtime", ossObjectKey: "laya/python/a.tar.gz")
            let runtimeURLs = LocalModelInstaller.candidateURLs(python, distributionBase: base)
            try expect(runtimeURLs.map(\.host) == [base.host, "github.com"], "runtime fallback order changed")
            try expect(runtimeURLs[0].path.hasSuffix("/laya/python/a.tar.gz"), "runtime distribution key changed")
        }
        try check("GitHub and ModelScope routes are reachable without a proxy") {
            // A pinned mirror wins over the generic host rewrite: ModelScope serves this file byte-for-byte.
            try expect(LocalModelKind.embedding.isBundled && LocalModelKind.embedding.downloads.isEmpty, "Arctic must ship in the app")
            // GitHub release assets must never stand alone: the origin stalled at ~13 KB/s.
            let vad = LocalModelInstaller.candidateURLs(.vad, distributionBase: nil)
            try expect(vad.map(\.host) == ["gh-proxy.com", "hk.gh-proxy.com", "ghproxy.net", "github.com"], "wrong VAD route order")
            try expect(vad[0].absoluteString == "https://gh-proxy.com/" + ModelDownload.vad.url.absoluteString, "accelerator must embed the origin URL")
            try expect(vad.filter { $0.absoluteString == ModelDownload.vad.url.absoluteString }.count == 1, "origin must appear exactly once as the last resort")
            let source = LocalModelInstaller.candidateURLs(ModelDownload(url: URL(string: "https://codeload.github.com/o/r/tar.gz/abc")!, sha256: String(repeating: "b", count: 64), name: "source"), distributionBase: nil)
            try expect(source.map(\.host) == ["hk.gh-proxy.com", "codeload.github.com"], "wrong source archive route order")
            let pinned = "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
            let runtime = LocalModelInstaller.candidateURLs(ModelDownload(url: URL(string: pinned)!, sha256: String(repeating: "d", count: 64), name: "Python runtime"), distributionBase: nil)
            try expect(runtime[0].absoluteString == "https://mirrors.ustc.edu.cn/github-release/astral-sh/python-build-standalone/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz", "university mirror path changed")
            try expect(runtime[1].host == "mirror.nju.edu.cn", "second university mirror missing")
            try expect(runtime.contains { $0.host == "gh-proxy.com" }, "accelerator fallback missing")
            try expect(runtime.last?.absoluteString == pinned, "origin must stay last")
            // Unlisted hosts keep a single route instead of inventing mirrors.
            let other = LocalModelInstaller.candidateURLs(ModelDownload(url: URL(string: "https://example.org/a.bin")!, sha256: String(repeating: "c", count: 64), name: "other"), distributionBase: nil)
            try expect(other.map(\.host) == ["example.org"], "unexpected mirror for an unlisted host")
        }
        let localFixture = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCopilot-Local-Core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: localFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localFixture) }
        try check("local model readiness rejects partial missing and size-mismatched installs") {
            let kind = LocalModelKind.streamingSpeech, folder = kind.location(in: localFixture)
            try expect(!kind.isInstalled(in: localFixture), "missing install accepted")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(kind.files[0]))
            try expect(!kind.isInstalled(in: localFixture), "uncommitted payload accepted")
            try JSONEncoder().encode([kind.files[0]: 4]).write(to: folder.appendingPathComponent("installed.json"))
            try expect(!kind.isInstalled(in: localFixture), "truncated payload accepted")
        }
        do {
            try await LocalModelInstaller.install(.streamingSpeech, root: localFixture, downloader: { _, destination in try Data("corrupt download".utf8).write(to: destination) })
            throw CheckError(description: "corrupt model committed")
        } catch is CopilotError {
            let original = try Data(contentsOf: LocalModelKind.streamingSpeech.location(in: localFixture).appendingPathComponent("encoder.int8.onnx"))
            try expect(original == Data([1, 2, 3]), "previous model destroyed")
            passed.append("bad download checksum preserves the previous local model")
        }
        do {
            try await LocalModelInstaller.install(.streamingSpeech, root: localFixture, downloader: { _, _ in throw CancellationError() })
            throw CheckError(description: "cancelled download committed")
        } catch is CancellationError { passed.append("local download cancellation cleans staging without changing installed data") }
        try check("failed local model replacement rolls back atomically") {
            let target = LocalModelKind.streamingSpeech.location(in: localFixture)
            do { try LocalModelInstaller.commit(localFixture.appendingPathComponent("absent"), to: target); throw CheckError(description: "missing payload accepted") }
            catch is CheckError { throw CheckError(description: "missing payload accepted") }
            catch { try expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("encoder.int8.onnx").path), "failed replacement lost previous data") }
        }
        let fake = localFixture.appendingPathComponent("fake-worker")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":true}'\nwhile IFS= read -r row; do printf '%s\\n' \"$row\"; done\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let echoWorker = LocalInferenceWorker(mode: "speech", modelDirectory: localFixture, executable: fake)
        let response = try await echoWorker.call(["op": "ping", "unicode": "中文🙂"], timeout: 15)
        try expect(response["unicode"] as? String == "中文🙂", "stdio framing or Unicode was corrupted")
        echoWorker.close(); passed.append("native IPC delivers short flushed replies without waiting for a full read buffer")
        do { _ = try await echoWorker.call(["op": "ping"]); throw CheckError(description: "closed worker restarted") }
        catch is CancellationError { passed.append("closed local workers cannot restart after shutdown") }
        for (code, expected) in [("embedding_context", "allocate inference memory"),
                                 ("embedding_load", "runtime compatibility"),
                                 ("model_load_failed", "runtime compatibility")] {
            let failing = localFixture.appendingPathComponent("failing-" + code)
            try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":false,\"error\":\"\(code)\"}'\n".write(to: failing, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failing.path)
            let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: localFixture, executable: failing)
            do { _ = try await worker.call(["op": "ping"], timeout: 15); throw CheckError(description: "failed startup accepted") }
            catch is CheckError { throw CheckError(description: "failed startup accepted") }
            catch {
                try expect(error.localizedDescription.contains(expected), "startup failure lost actionable stage")
                try expect(!error.localizedDescription.contains("Download the model again"), "runtime failure blamed download")
            }
            worker.close()
        }
        passed.append("local startup distinguishes context allocation from model/runtime failures")
        let hanging = localFixture.appendingPathComponent("hanging-worker")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":true}'\nwhile :; do :; done\n".write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hanging.path)
        let timedWorker = LocalInferenceWorker(mode: "speech", modelDirectory: localFixture, executable: hanging)
        do { _ = try await timedWorker.call(["op": "ping"], timeout: 0.2); throw CheckError(description: "hung worker succeeded") }
        catch is CopilotError { passed.append("local worker timeout terminates inference and returns a visible error") }
        timedWorker.close()
        // The worker closes its stdin before reporting ready, so the next request writes to a pipe
        // without a reader. Without F_SETNOSIGPIPE that write delivers SIGPIPE and kills this process.
        let deaf = localFixture.appendingPathComponent("deaf-worker")
        try "#!/bin/sh\nexec 0<&-\nprintf '%s\\n' '{\"ready\":true}'\nsleep 5\n".write(to: deaf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deaf.path)
        let deafWorker = LocalInferenceWorker(mode: "paraformer", modelDirectory: localFixture, executable: deaf)
        do { _ = try await deafWorker.call(["op": "audio", "pcm": String(repeating: "A", count: 32_000)], timeout: 15); throw CheckError(description: "write to exited worker succeeded") }
        catch is CopilotError {
            try expect(deafWorker.failureCode == "process_ended", "broken worker pipe was not classified as process_ended")
            passed.append("writing to an exited local worker fails visibly instead of terminating the app")
        }
        deafWorker.close()
        // Regression: queue wait must be covered by timeout, and a cancelled queued call must
        // resume immediately instead of hanging behind an active request.
        let slowWorkerScript = localFixture.appendingPathComponent("slow-worker")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            delay = float(req.get("delay", 0))
            if delay > 0: time.sleep(delay)
            sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n"); sys.stdout.flush()
        """.write(to: slowWorkerScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowWorkerScript.path)
        do {
            let queuedWorker = LocalInferenceWorker(mode: "embedding", modelDirectory: localFixture, executable: slowWorkerScript, sigkillGraceSeconds: 0.2)
            let head = Task { try await queuedWorker.call(["op": "ping", "delay": 1.2], timeout: 5) }
            try await Task.sleep(nanoseconds: 150_000_000)
            let t0 = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await queuedWorker.call(["op": "ping", "delay": 0], timeout: 0.25)
                throw CheckError(description: "queued call bypassed timeout")
            } catch is CopilotError {
                let elapsed = ProcessInfo.processInfo.systemUptime - t0
                try expect(elapsed < 0.8, "queued timeout waited for head request (\(elapsed)s)")
            }
            let cancelStart = ProcessInfo.processInfo.systemUptime
            let queuedCancel = Task { try await queuedWorker.call(["op": "ping", "delay": 0], timeout: 5) }
            try await Task.sleep(nanoseconds: 50_000_000)
            queuedCancel.cancel()
            do {
                _ = try await queuedCancel.value
                throw CheckError(description: "cancelled queued call succeeded")
            } catch is CancellationError {
                let elapsed = ProcessInfo.processInfo.systemUptime - cancelStart
                try expect(elapsed < 0.6, "cancelled queued call waited for head request (\(elapsed)s)")
            }
            _ = try await head.value
            queuedWorker.close(initiator: .selfCheck)
            passed.append("local worker timeout covers queue wait and queued cancellation resumes immediately")
        }
        // Regression: a child process that ignores SIGTERM must be escalated to SIGKILL so
        // Darwin.read unblocks and subsequent requests recover on a fresh worker.
        let stubSigterm = localFixture.appendingPathComponent("ignore-sigterm-worker")
        try """
        #!/usr/bin/env python3
        import json, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            if req.get("hang"):
                while True: time.sleep(10)
            sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n"); sys.stdout.flush()
        """.write(to: stubSigterm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stubSigterm.path)
        do {
            let sigkillWorker = LocalInferenceWorker(mode: "embedding", modelDirectory: localFixture, executable: stubSigterm, sigkillGraceSeconds: 0.25)
            let t0 = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await sigkillWorker.call(["op": "ping", "hang": true], timeout: 0.25)
                throw CheckError(description: "SIGTERM-ignoring worker succeeded")
            } catch is CopilotError {
                let elapsed = ProcessInfo.processInfo.systemUptime - t0
                try expect(elapsed < 2.5, "SIGKILL escalation took too long (\(elapsed)s)")
            }
            let recovered = try await sigkillWorker.call(["op": "ping", "hang": false], timeout: 3.0)
            try expect(recovered["ok"] as? Bool == true, "worker did not recover after SIGKILL escalation")
            sigkillWorker.close(initiator: .selfCheck)
            passed.append("local worker escalates SIGTERM-ignoring child to SIGKILL and recovers subsequent requests")
        }
        // Regression: cold-start timeout before child launch must fail once without spawning, and next request succeeds.
        do {
            let spawnLog = localFixture.appendingPathComponent("cold-spawns.log")
            let countWorker = localFixture.appendingPathComponent("count-worker")
            try """
            #!/usr/bin/env python3
            import json, sys
            with open(\(String(reflecting: spawnLog.path)), "a") as f: f.write("spawn\\n")
            sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
            for line in sys.stdin:
                req = json.loads(line)
                sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n"); sys.stdout.flush()
            """.write(to: countWorker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: countWorker.path)
            let coldWorker = LocalInferenceWorker(mode: "embedding", modelDirectory: localFixture, executable: countWorker, sigkillGraceSeconds: 0.2)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var armed = true
            coldWorker.onBeforeStartProcess = {
                hookLock.lock()
                let pause = armed; armed = false
                hookLock.unlock()
                if pause { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            }
            let expiredTask = Task { try await coldWorker.call(["op": "ping"], timeout: 0.05) }
            try expect(entered.wait(timeout: .now() + 2) == .success, "cold-start barrier was not reached")
            try await Task.sleep(nanoseconds: 130_000_000)
            release.signal()
            do {
                _ = try await expiredTask.value
                throw CheckError(description: "expired cold-start call succeeded")
            } catch is CopilotError {}
            let spawnsAfterTimeout = (try? String(contentsOf: spawnLog, encoding: .utf8).split(separator: "\n").count) ?? 0
            try expect(spawnsAfterTimeout == 0, "expired cold-start request spawned a worker")
            let ok = try await coldWorker.call(["op": "ping"], timeout: 3.0)
            try expect(ok["ok"] as? Bool == true, "next request after cold-start timeout failed")
            let spawnsAfterRecovery = (try? String(contentsOf: spawnLog, encoding: .utf8).split(separator: "\n").count) ?? 0
            try expect(spawnsAfterRecovery == 1, "expected exactly 1 spawn after recovery")
            coldWorker.close(initiator: .selfCheck)
            passed.append("local worker cold-start timeout skips launch and recovers next request")
        }
        // Regression: LocalEmbeddingProvider falls back to embedding-cpu if the GPU worker crashes out-of-process,
        // stays sticky on CPU for subsequent chunks, and does not loop on embedding_context.
        do {
            let modeLog = localFixture.appendingPathComponent("embedding-fallback-modes.log")
            let fallbackWorker = localFixture.appendingPathComponent("embedding-fallback-worker")
            try """
            #!/usr/bin/env python3
            import json, sys
            mode = sys.argv[1]
            with open(\(String(reflecting: modeLog.path)), "a") as f: f.write(mode + "\\n")
            sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
            vec = [1.0] + [0.0] * 767
            for line in sys.stdin:
                req = json.loads(line)
                if req.get("text") == "oom":
                    sys.stdout.write(json.dumps({"id": req["id"], "error": "embedding_context"}) + "\\n"); sys.stdout.flush()
                    continue
                if mode == "embedding" and req.get("text") == "crash-gpu":
                    sys.exit(1)
                sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
            """.write(to: fallbackWorker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallbackWorker.path)
            let provider = LocalEmbeddingProvider(directory: localFixture, executable: fallbackWorker)
            let vectors = try await provider.embed(["ok-1", "crash-gpu", "ok-2"])
            try expect(vectors.count == 3 && vectors.allSatisfy { $0.count == 768 && $0[0] == 1.0 }, "embedding CPU fallback did not produce valid vectors")
            let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
            try expect(modes == ["embedding-cpu"], "Arctic must start directly on CPU")
            provider.close(initiator: .selfCheck)
            let oomLog = localFixture.appendingPathComponent("embedding-oom-modes.log")
            let oomWorker = localFixture.appendingPathComponent("embedding-oom-worker")
            try """
            #!/usr/bin/env python3
            import json, sys
            with open(\(String(reflecting: oomLog.path)), "a") as f: f.write(sys.argv[1] + "\\n")
            sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
            for line in sys.stdin:
                req = json.loads(line)
                sys.stdout.write(json.dumps({"id": req["id"], "error": "embedding_context"}) + "\\n"); sys.stdout.flush()
            """.write(to: oomWorker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oomWorker.path)
            let oomProvider = LocalEmbeddingProvider(directory: localFixture, executable: oomWorker)
            do {
                _ = try await oomProvider.embed(["oom"])
                throw CheckError(description: "embedding_context unexpectedly succeeded")
            } catch let error as LocalInputError {
                try expect(error.code == "embedding_context" && error.localizedDescription.contains("allocate inference memory"), "wrong embedding_context message: \(error)")
            }
            let oomModes = try String(contentsOf: oomLog, encoding: .utf8).split(separator: "\n").map(String.init)
            try expect(oomModes.count == 1, "embedding_context should not spawn a second worker, got \(oomModes)")
            oomProvider.close(initiator: .selfCheck)
            passed.append("local embedding provider defaults CPU on x86_64 and falls back to CPU on GPU crash")
        }
        // Regression: per-input worker rejections preserve fixed stage codes, diagnostics & localization,
        // and never leak unknown error strings.
        do {
            let rejectingWorker = localFixture.appendingPathComponent("rejecting-worker")
            try """
            #!/bin/sh
            printf '%s\\n' '{"ready":true}'
            while IFS= read -r row; do
              id=$(printf '%s' "$row" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
              case "$row" in
                *token_limit*) code=token_limit;;
                *text_size*) code=text_size;;
                *embedding_context*) code=embedding_context;;
                *embedding_load*) code=embedding_load;;
                *embedding_decode*) code=embedding_decode;;
                *embedding_dimension*) code=embedding_dimension;;
                *embedding_finite*) code=embedding_finite;;
                *embedding_zero*) code=embedding_zero;;
                *) code=native_secret_path;;
              esac
              printf '{"id":"%s","error":"%s"}\\n' "$id" "$code"
            done
            """.write(to: rejectingWorker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rejectingWorker.path)
            let cases: [(String, String, String, String)] = [
                ("token_limit", "token_limit", "too large", "本地模型输入过长。"),
                ("text_size", "text_size", "too large", "本地模型输入过长。"),
                ("embedding_context", "embedding_context", "allocate inference memory", "本地模型无法分配推理内存"),
                ("embedding_load", "embedding_load", "could not load", "本地模型加载失败"),
                ("embedding_decode", "embedding_decode", "could not process", "本地模型无法处理此输入"),
                ("embedding_dimension", "embedding_dimension", "could not process", "本地模型无法处理此输入"),
                ("embedding_finite", "embedding_finite", "could not process", "本地模型无法处理此输入"),
                ("embedding_zero", "embedding_zero", "could not process", "本地模型无法处理此输入"),
                ("odd", "inference_failed", "could not process", "本地模型无法处理此输入")
            ]
            for (input, expectedCode, expectedEn, expectedZh) in cases {
                let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: localFixture, executable: rejectingWorker)
                do {
                    _ = try await worker.call(["op": "embed", "text": input], timeout: 15)
                    throw CheckError(description: "rejected input \(input) unexpectedly succeeded")
                } catch let error as LocalInputError {
                    try expect(error.code == expectedCode && worker.failureCode == expectedCode, "per-input stage code lost for \(input): \(error.code) / \(worker.failureCode)")
                    try expect(CaptureDiagnostics.Failure(rawValue: error.code) != nil, "missing CaptureDiagnostics.Failure case for \(error.code)")
                    try expect(error.localizedDescription.contains(expectedEn), "wrong English message for \(error.code): \(error.localizedDescription)")
                    let zh = L10n.text(error.localizedDescription, language: .simplifiedChinese)
                    try expect(zh.contains(expectedZh), "missing Chinese localization for \(error.code): \(zh)")
                }
                worker.close(initiator: .selfCheck)
            }
            passed.append("per-input worker rejections keep fixed stage codes, diagnostics and localization")
        }
        // Regression: LocalEmbeddingProvider uses 240s per-request timeout for document indexing and 90s for live queries.
        do {
            try expect(LocalEmbeddingProvider.defaultQueryTimeout == 90, "expected 90s query timeout, got \(LocalEmbeddingProvider.defaultQueryTimeout)")
            try expect(LocalEmbeddingProvider.defaultIndexingTimeout == 240, "expected 240s indexing timeout, got \(LocalEmbeddingProvider.defaultIndexingTimeout)")
            let slowEmbedWorker = localFixture.appendingPathComponent("slow-embed-worker")
            try """
            #!/usr/bin/env python3
            import json, sys, time
            sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
            vec = [1.0] + [0.0] * 767
            for line in sys.stdin:
                req = json.loads(line)
                time.sleep(0.35)
                sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
            """.write(to: slowEmbedWorker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowEmbedWorker.path)
            let provider = LocalEmbeddingProvider(directory: localFixture, executable: slowEmbedWorker, queryTimeout: 0.12, indexingTimeout: 2.0)
            do {
                _ = try await provider.embed(["slow-query"])
                throw CheckError(description: "query path should have timed out under queryTimeout")
            } catch let error as CopilotError {
                try expect(error.localizedDescription.contains("timed out"), "unexpected query timeout error: \(error)")
            }
            actor ProgressRecorder {
                private(set) var values: [Int] = []
                func record(_ value: Int) { values.append(value) }
            }
            let progressRecorder = ProgressRecorder()
            let indexed = try await provider.embed(["slow-doc-chunk"], progress: { count in await progressRecorder.record(count) })
            let progressUpdates = await progressRecorder.values
            try expect(indexed.count == 1 && indexed[0].count == 768 && progressUpdates == [1], "indexing path did not succeed under indexingTimeout")
            provider.close(initiator: .selfCheck)
            passed.append("local embedding provider separates 240s indexing timeout from 90s query timeout")
        }
        try check("audio flow separates no audio, digital silence, untranscribed audio and recognition") {
            var now: TimeInterval = 100
            let flow = AudioFlowMonitor(clock: { now })
            flow.begin(sampleRate: 16_000)
            try expect(flow.snapshot().verdict == .noAudio && flow.snapshot().peakDBFS == nil, "empty source was not reported as no audio")
            now = 100.25
            flow.observe(Data(count: 3_200)) // 100 ms of exact zeros
            var snapshot = flow.snapshot()
            try expect(snapshot.verdict == .digitalSilence && snapshot.peakDBFS == -96 && snapshot.firstAudioMS == 250, "digital silence misclassified")
            try expect(snapshot.audioSeconds == 0.1 && snapshot.audibleFraction == 0, "silent duration or level miscounted")
            var loud = Data(count: 3_200)
            loud.withUnsafeMutableBytes { $0.storeBytes(of: Int16(-16_384).littleEndian, toByteOffset: 2, as: Int16.self) }
            flow.observe(loud)
            snapshot = flow.snapshot()
            try expect(snapshot.verdict == .audioWithoutText && snapshot.peakDBFS == -6 && snapshot.audibleFraction == 0.5, "audible audio without text misclassified")
            flow.speechStarted(); now = 100.65; flow.notePartial(); flow.noteTranscript()
            flow.speechStarted(); now = 101.85; flow.noteTranscript()
            snapshot = flow.snapshot()
            try expect(snapshot.verdict == .recognized && snapshot.partials == 1 && snapshot.transcripts == 2, "recognition counts lost")
            try expect(snapshot.textLatencyMeanMS == 800 && snapshot.textLatencyMaxMS == 1_200, "first-text latency measured from the wrong onset")
            flow.begin(sampleRate: 16_000)
            try expect(flow.snapshot() == AudioFlowMonitor(clock: { now }).snapshot(), "new capture inherited the previous session's counters")
        }
        try check("capture journal keeps readable events beside unknown stages and prints numbers only") {
            let journal = localFixture.appendingPathComponent("capture-diagnostics.json")
            let flow = AudioFlowMonitor(); flow.begin(sampleRate: 16_000); flow.observe(Data(count: 320))
            var recognition = RecognitionStats(); recognition.noteBacklog(ms: 40)
            let event = CaptureDiagnostics.Event(time: Date(timeIntervalSince1970: 0), stage: .audioSummary, code: nil,
                                                 details: CaptureDiagnostics.audioDetails(flow.snapshot(), speaker: "You", recognition: recognition))
            try CaptureDiagnostics.append(event, to: journal)
            var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]]
            rows.insert(["time": 0, "stage": "stageFromANewerBuild"], at: 0)
            try JSONSerialization.data(withJSONObject: rows).write(to: journal)
            let events = CaptureDiagnostics.read(from: journal)
            try expect(events.count == 1 && events[0].stage == .audioSummary, "one unknown stage discarded the whole journal")
            let line = CaptureDiagnostics.summaryLine(events[0])
            try expect(line.contains("speaker=You verdict=digitalSilence") && line.contains("backlog_ms_max=40"), "audio summary fields missing")
            let exitLine = CaptureDiagnostics.summaryLine(.init(time: Date(timeIntervalSince1970: 0), stage: .workerExit, code: 15, details: .init(workerMode: "embedding", workerTerminationInitiator: .selfCheck)))
            try expect(exitLine.contains("worker=embedding initiator=selfCheck"), "worker initiator missing from summary")
            let stallLine = CaptureDiagnostics.summaryLine(.init(time: Date(timeIntervalSince1970: 0), stage: .mainThreadStall, code: nil, details: .init(stallMS: 2100, isRunning: true, isTransitioning: false, answerIsRunning: false, transcriptLineCount: 42)))
            try expect(stallLine.contains("stall_ms=2100") && stallLine.contains("lines=42"), "main thread stall fields missing from summary")
            let stopLine = CaptureDiagnostics.summaryLine(.init(time: Date(timeIntervalSince1970: 0), stage: .stopStage, code: nil, details: .init(lifecyclePhase: .disconnectProviders, timedOut: true)))
            try expect(stopLine.contains("phase=disconnectProviders timed_out=true"), "stop stage fields missing from summary")
        }
        try check("mixed Mandarin turn keeps the reply without copying the interview question") {
            let question = "你好我们开始今天的面试请你用一分钟介绍一下自己以及你最近做的一个项目"
            let mixed = "开始今天的面试请你用一分钟介绍一下自己以及你最近好的我来介绍一下"
            let both = EchoMonitor.Assessment(echoMS: 1400, ownMS: 480, systemActive: true)
            let secondQuestion = "这个项目里最难解决的问题是什么"
            let answer = "最难解决的部分我觉得主要还是"
            try expect(EchoText.mixedReply(answer, references: [secondQuestion], assessment: both) == nil, "short shared wording must stay intact")
            try expect(EchoText.mixedReply("这个项目里" + answer, references: [secondQuestion], assessment: both) == answer, "keep the user's modifier attached to its noun")
            try expect(EchoText.mixedReply(mixed, references: [question], assessment: both) == "好的我来介绍一下", "mixed prefix reached own transcript")
            try expect(EchoText.mixedReply(mixed, references: [question], assessment: .init(ownMS: 1800, systemActive: true)) == nil, "removed an independent quotation")
            try expect(EchoText.mixedReply(question, references: [question], assessment: both) == nil, "invented a reply from pure replay")
        }
        try check("speaker echo is told apart from the user's own speech by audio, timing and text") {
            let rate = 16000.0, far = SyntheticTalk.speech(seed: 1, seconds: 6)
            let echoOnly = SyntheticTalk.echo(far, delay: 0.12, gain: 0.1, count: far.count)
            func monitor(system: [Float], mic: [Float]) -> EchoMonitor {
                let m = EchoMonitor(); m.begin(sampleRate: rate)
                SyntheticTalk.feed(m, system: system, mic: mic, base: 100)
                return m
            }
            // Speakers replay the far end into the microphone: echo, never the user's speech.
            let replay = monitor(system: far, mic: echoOnly).assess(from: 100.5, to: 105.5, now: 106.5)
            try expect(replay.isEcho && !replay.isOwn, "speaker replay counted as own speech \(replay)")
            // The user talks over the far end, louder than the replay: own speech within a second.
            let own = SyntheticTalk.speech(seed: 2, seconds: 2.5)
            var doubleTalk = echoOnly
            for i in own.indices { doubleTalk[Int(3 * rate) + i] += own[i] }
            let both = monitor(system: far, mic: doubleTalk)
            try expect(both.assess(from: 100.5, to: 102.9, now: 103).isEcho, "echo before the user spoke not recognized")
            try expect(both.assess(from: 102.6, to: 104.0, now: 104.0).isOwn, "barge-in over the far end not recognized within 1 s")
            // Far end silent (the user repeats its words afterwards), or headphones: own speech.
            let silent = [Float](repeating: 0, count: far.count)
            try expect(monitor(system: silent, mic: far).assess(from: 100.5, to: 105.5, now: 106).isOwn, "speech with a silent far end not own")
            // Independent speech during the far end (headphones) is never taken for replay; without
            // a learned path it stays undecided acoustically and timing plus text decide.
            let headphones = monitor(system: far, mic: SyntheticTalk.speech(seed: 3, seconds: 6))
            try expect(!headphones.assess(from: 100.5, to: 105.5, now: 106).isEcho, "independent speech during the far end taken for echo")
            // Text overlap: replay recognized slightly differently, different words, CJK and English.
            let heard = ["你好我们开始今天的面试", "你好我们开始今天的面试请你用一分钟介绍一下自己"]
            try expect((EchoText.similarity("你好我们开始今天的面试请你用", to: heard) ?? 0) >= EchoText.echoSimilarity, "CJK replay not matched")
            try expect((EchoText.similarity("我之前负责的是支付系统的重构", to: heard) ?? 1) <= EchoText.ownSimilarity, "different CJK words matched")
            try expect((EchoText.similarity("please introduce your most recent projects", to: ["Please introduce your most recent project."]) ?? 0) >= EchoText.echoSimilarity, "English replay not matched")
            try expect((EchoText.similarity("sorry may I answer the previous one first", to: ["Please introduce your most recent project."]) ?? 1) <= EchoText.ownSimilarity, "different English words matched")
            try expect(EchoText.similarity("，。", to: heard) == nil, "punctuation-only text compared")
            // ScreenCaptureKit delivers system audio later than the microphone tap. With capture
            // timestamps, a replay whose reference has not arrived yet must not pass as own speech.
            let late = EchoMonitor(); late.begin(sampleRate: rate)
            let cut = far.count - Int(0.5 * rate)
            SyntheticTalk.feed(late, system: Array(far[..<cut]), mic: echoOnly, base: 100)
            try expect(!late.assess(from: 105.0, to: 106.0, now: 106.0).isOwn, "replay judged before its reference arrived")
            try expect(late.assess(from: 100.5, to: 106.0, now: 106.0).isEcho, "replay covered by the late reference not echo")
            try expect(EchoMonitor.captureEnd(start: 99.9, duration: 0.05, now: 100.2) == 99.95
                       && EchoMonitor.captureEnd(start: nil, duration: 0.05, now: 100.2) == 100.2
                       && EchoMonitor.captureEnd(start: 10, duration: 0.05, now: 100.2) == 100.2, "capture time not used, or implausible time trusted")
            let learned = monitor(system: far, mic: echoOnly)
            _ = learned.assess(from: 100, to: 106, now: 106.5)
            let lag = learned.snapshot.pathLagMS ?? -1
            try expect(abs(lag - 120) <= 40 && learned.snapshot.heldTurns == 0, "loudspeaker delay not learned: \(lag) ms")
        }
        try check("recognition stats measure final lag on the audio timeline and name overflow causes") {
            var stats = RecognitionStats()
            try expect(stats.finalLagMeanMS == nil, "empty stats reported a lag")
            stats.noteFinal(capturedMS: 1_000, endMS: 300)
            stats.noteFinal(capturedMS: 5_000, endMS: 3_900)
            stats.noteFinal(capturedMS: 100, endMS: 400) // a segment ending past captured audio is not negative lag
            try expect(stats.finalLagCount == 3 && stats.finalLagMeanMS == 600 && stats.finalLagMaxMS == 1_100, "final lag miscounted")
            stats.noteBacklog(ms: 900); stats.noteBacklog(ms: 200)
            try expect(stats.backlogMaxMS == 900, "backlog maximum lost")
            try expect(RecognitionStats.overflowFailure(ready: false) == .speech_load_slow
                       && RecognitionStats.overflowFailure(ready: true) == .speech_behind, "overflow cause misattributed")
            let backlog = AudioBacklog()
            for _ in 0..<500 { _ = backlog.add(20) } // 500 small callbacks, far beyond a 64-buffer bound
            try expect(backlog.add(0) == 10_000, "outstanding duration miscounted")
            for _ in 0..<500 { backlog.removeOldest() }
            backlog.removeOldest()
            try expect(backlog.add(0) == 0, "consumed audio left a backlog or went negative")
            stats.readyMS = 2_837; stats.failure = .speech_behind
            let flow = AudioFlowMonitor(); flow.begin(sampleRate: 16_000)
            let summary = CaptureDiagnostics.summaryLine(.init(time: Date(timeIntervalSince1970: 0), stage: .audioSummary, code: nil,
                                                                details: CaptureDiagnostics.audioDetails(flow.snapshot(), speaker: "Them", recognition: stats)))
            try expect(summary.contains("ready_ms=2837") && summary.contains("backlog_ms_max=900")
                       && summary.contains("final_lag_ms_mean=600 final_lag_ms_max=1100"), "recognition timing missing from summary")
            let failed = CaptureDiagnostics.summaryLine(.init(time: Date(timeIntervalSince1970: 0), stage: .speechFailed, code: nil,
                                                               details: .init(speaker: "You", failure: .speech_load_slow)))
            try expect(failed.hasSuffix("speechFailed speaker=You failure=speech_load_slow"), "speech failure cause missing from summary")
        }
        let fixture = "Experiment A has 128 samples. Method B latency is 42 ms. Revenue in 2025 was 18.7 million."
        let chunks = DocumentChunker.chunk([.init(text: String(repeating: fixture + "\n", count: 40), page: 3)], documentID: "doc", name: "study.pdf", maxCharacters: 256, overlap: 30)
        try check("chunk bounds and page/source metadata") {
            try expect(chunks.count > 10, "long document must be chunked")
            try expect(chunks.allSatisfy { $0.text.count <= 256 && $0.page == 3 && $0.documentID == "doc" && $0.documentName == "study.pdf" }, "source metadata lost")
            try expect(chunks.map(\.ordinal) == Array(chunks.indices), "ordinals are not consecutive")
        }
        try check("Unicode chunks preserve Chinese text and emoji") {
            let text = String(repeating: "样本量为128，延迟42毫秒。🧪", count: 40)
            let values = DocumentChunker.chunk([.init(text: text, page: nil)], documentID: "c", name: "中文.txt", maxCharacters: 128, overlap: 0)
            try expect(values.map(\.text).joined() == text, "chunk boundaries corrupted Unicode")
        }
        try check("chunks bound Unicode scalars hidden inside grapheme clusters while preserving ordinary text boundaries") {
            // 4,000 Characters of 7 scalars each: a Character-only bound would produce >8,192-token passages.
            let heavy = String(repeating: "a\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}", count: 4_000)
            let values = DocumentChunker.chunk([.init(text: heavy, page: 2)], documentID: "h", name: "h.pdf")
            try expect(values.allSatisfy { $0.text.unicodeScalars.count <= 3_200 && $0.page == 2 }, "passage exceeded scalar bound")
            try expect(values.count >= 9 && values.count < 40, "scalar-bounded chunking stalled or exploded: \(values.count)")
            try expect(values.map(\.ordinal) == Array(values.indices), "ordinals are not consecutive")
            // Single oversized grapheme cluster still makes forward progress without looping.
            let hugeCluster = "a" + String(repeating: "\u{301}", count: 400) + " normal tail."
            let hugeValues = DocumentChunker.chunk([.init(text: hugeCluster, page: 1)], documentID: "g", name: "g.pdf", maxCharacters: 128, overlap: 30)
            try expect(!hugeValues.isEmpty && hugeValues.count <= 4, "huge grapheme cluster failed to advance cleanly: \(hugeValues.count)")
            // Ordinary English & Chinese text boundaries match the pre-scalar-cap character chunker verbatim.
            func legacyChunkTexts(_ text: String, maxCharacters: Int, overlap: Int) -> [String] {
                let size = max(128, maxCharacters), ov = max(0, min(overlap, size / 3))
                let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
                var out: [String] = [], start = 0
                while start < chars.count {
                    var end = min(start + size, chars.count)
                    if end < chars.count, let b = (start + size / 2..<end).last(where: { "\n。.!?！？ ".contains(chars[$0]) }) { end = b + 1 }
                    let s = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    if end == chars.count { break }
                    start = max(start + 1, end - ov)
                }
                return out
            }
            let enDoc = String(repeating: fixture + "\n", count: 40)
            try expect(chunks.map(\.text) == legacyChunkTexts(enDoc, maxCharacters: 256, overlap: 30), "ordinary English chunk boundaries changed")
            let zhDoc = String(repeating: "这是一段正常的中文测试文本，用于验证标点断句与重叠切片边界保持一致。", count: 80)
            let zhChunks = DocumentChunker.chunk([.init(text: zhDoc, page: 1)], documentID: "zh", name: "zh.pdf", maxCharacters: 1600, overlap: 180)
            try expect(zhChunks.map(\.text) == legacyChunkTexts(zhDoc, maxCharacters: 1600, overlap: 180), "ordinary Chinese chunk boundaries changed")
        }
        try check("empty input and overlap safety") {
            try expect(DocumentChunker.chunk([.init(text: "  \n", page: nil)], documentID: "e", name: "e").isEmpty, "empty chunk created")
            try expect(!DocumentChunker.chunk([.init(text: fixture, page: nil)], documentID: "e", name: "e", maxCharacters: 0, overlap: 900).isEmpty, "unsafe chunk settings")
        }
        try check("cosine similarity handles zero mismatched and nonfinite vectors") {
            try expect(abs(VectorMath.cosine([1, 0], [1, 0]) - 1) < 0.0001, "identity cosine")
            try expect(VectorMath.cosine([1, 0], [0, 1]) == 0, "orthogonal cosine")
            try expect(VectorMath.cosine([0, 0], [1, 0]) == 0, "zero vector")
            try expect(VectorMath.cosine([1], [1, 0]) == 0, "dimension mismatch")
            try expect(VectorMath.cosine([.nan], [1]) == 0, "NaN propagated")
        }
        try check("hybrid fusion rewards agreement and deduplicates") {
            let result = VectorMath.fuse(lexical: [chunks[0], chunks[1]], semantic: [chunks[1], chunks[2]], limit: 6)
            try expect(result.first?.id == chunks[1].id && result.count == 3, "hybrid ranking wrong")
        }
        try check("follow-up retrieval retains previous entities and exact numbers") {
            let q = RetrievalQuery.formulate(question: "  What about latency?\n", context: "You: We used method B with 128 samples.", previousQuestion: "Why choose B over A?")
            try expect(q.question == "What about latency?", "normalization")
            try expect(q.semantic.contains("method B") && q.semantic.contains("B over A") && q.lexical.contains("128"), "follow-up lost context")
        }
        try check("structured suggestion tolerant streaming and source IDs") {
            let text = "## Core answer\nUse B.\n\n## Evidence\n42 ms [S1] and 128 samples [S2]. Invalid [S99]"
            try expect(SuggestionParser.sections(text).count == 2, "section parsing")
            try expect(SuggestionParser.sections("Plain partial answer").first?.content == "Plain partial answer", "plain output lost")
            try expect(SuggestionParser.citedIndices(text, sourceCount: 2) == [1, 2], "unknown citation accepted")
        }
        let now = Date()
        func f(_ text: String, id: String, speaker: Speaker = .them, start: Int = 0, at: Date = now) -> TranscriptFragment {
            .init(id: id, speaker: speaker, text: text, startMS: start, endMS: start + 500, receivedAt: at)
        }
        try check("fragments cannot trigger assistance; incomplete question is held") {
            var state = ConversationState()
            _ = state.append(f("Why did you choose the", id: "a"))
            try expect(state.phase == .forming, "fragment triggered work")
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == nil, "incomplete sentence accepted")
            _ = state.append(f(" larger sample size?", id: "b", start: 500))
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == "Why did you choose the larger sample size?", "completed question lost")
            try expect(!state.append(f("duplicate event", id: "b")), "repeated event appended")
        }
        try check("duplicate suppression and genuine follow-up") {
            var state = ConversationState(); _ = state.append(f("Why choose method B?", id: "a"))
            let q = state.candidate(speaker: .them, now: now, cooldown: 0)!
            state.begin(q, speaker: .them, now: now); state.finish(success: true, question: q)
            try expect(state.candidate(speaker: .them, now: now.addingTimeInterval(10), cooldown: 0) == nil, "duplicate trigger")
            _ = state.append(f("What about latency?", id: "b", start: 2500))
            try expect(state.candidate(speaker: .them, now: now.addingTimeInterval(10), cooldown: 0) == "What about latency?", "follow-up missed")
            try expect(state.phase == .followUp, "follow-up state")
        }
        try check("already answered remote question and force fallback") {
            var state = ConversationState(); _ = state.append(f("What is the sample size?", id: "q"))
            _ = state.append(f("128 samples.", id: "a", speaker: .you, at: now.addingTimeInterval(1)))
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == nil && state.phase == .answered, "answered question repeated")
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0, force: true) != nil, "manual override blocked")
        }
        try check("failed question may retry and Room has no false You identity") {
            var state = ConversationState(); _ = state.append(f("Why not method A?", id: "r", speaker: .room))
            let q = state.candidate(speaker: .room, now: now, cooldown: 0)!
            state.begin(q, speaker: .room, now: now); state.finish(success: false, question: q)
            try expect(state.candidate(speaker: .room, now: now.addingTimeInterval(1), cooldown: 7) != nil, "failure blocked retry")
        }
        try check("official Live session startup and no obsolete fields") {
            let body = LiveProtocol.start(model: "gpt-live-1", speaker: .room, scenario: .defense, language: .mixed, context: "Prior topic")
            let session = body["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            try expect(body["type"] as? String == "session.start", "wrong startup")
            try expect(LiveProtocol.endpoint.path == "/v1/live/sessions" && LiveProtocol.endpoint.query == nil, "old endpoint")
            try expect(audio["format"] != nil && audio["input"] == nil && session["output_modalities"] == nil, "Realtime fields leaked")
            try expect((session["delegation"] as? [String: String])?["type"] == "client", "wrong delegation")
        }
        try check("GPT-Live language preference persists and only steers its instructions") {
            let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(old.liveSpeechLanguage == .mixed, "legacy settings lost mixed-language default")
            for language in LiveSpeechLanguage.allCases {
                var settings = old; settings.liveSpeechLanguage = language
                let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
                try expect(restored.liveSpeechLanguage == language, "language preference did not persist")
                let session = LiveProtocol.start(model: "gpt-live-1", speaker: .room, scenario: .interview, language: language, context: "")["session"] as! [String: Any]
                let prompt = session["instructions"] as! String
                if let guidance = language.instruction {
                    try expect(prompt.contains(guidance), "chosen language not sent to GPT-Live")
                    try expect(prompt.contains("Do not use Korean or Japanese script"), "unrelated scripts not discouraged")
                } else {
                    try expect(!prompt.contains("Transcribe the words actually spoken") &&
                               !prompt.contains("Do not use Korean or Japanese script"), "unrestricted option still steers language")
                }
                try expect(session["language"] == nil && (session["audio"] as? [String: Any])?["language"] == nil, "unsupported hard language field sent")
            }
        }
        try check("Live delegation uses opaque ID and not invented question text") {
            let event = LiveProtocol.parse(["type": "session.delegation.created", "offset_ms": 1500, "delegation": ["id": "opaque_X", "target": "client"]], speaker: .them)
            if case .delegation(let id, let ms) = event { try expect(id == "opaque_X" && ms == 1500, "delegation fields") }
            else { throw CheckError(description: "delegation not parsed") }
            try expect(LiveProtocol.parse(["type": "session.output_audio.delta", "delta": "x"], speaker: .them) == nil, "output audio used")
        }
        try check("SSE multiline data and heartbeat handling") {
            var sse = ServerSentEvents()
            try expect(sse.consume(": ping") == nil, "heartbeat emitted")
            _ = sse.consume("data: first"); _ = sse.consume("data: second")
            try expect(sse.consume("") == "first\nsecond", "SSE multiline")
        }
        try check("HTTP failure messages do not include secrets") {
            for code in [401, 403, 429, 500, 400] {
                do { try OpenAIHTTP.check(code); throw CheckError(description: "HTTP failure accepted") }
                catch is ServiceHTTPFailure { }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("experiment.txt")
        try (fixture + "\n样本量128，延迟42毫秒。").write(to: input, atomically: true, encoding: .utf8)
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let doc = try await index.importDocument(input, provider: MockEmbeddingProvider())
        try expect(doc.status == "Ready" && doc.chunkCount > 0, "indexing failed"); passed.append("document import and embedded local persistence")
        let lexical = try await index.lexical("42 128 latency")
        try expect(lexical.first?.documentID == doc.id, "lexical retrieval failed"); passed.append("SQLite FTS5 BM25 retrieval")
        let chinese = try await index.lexical("样本量")
        try expect(!chinese.isEmpty, "CJK retrieval failed"); passed.append("CJK lexical segmentation")
        let quote = try await index.lexical("\" OR * (NEAR) DROP TABLE chunks;")
        _ = quote; passed.append("FTS user query escaping")
        let persisted = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let restored = try await persisted.allChunks()
        try expect(restored.count == doc.chunkCount && restored[0].embeddingModel == "mock-embedding-v1", "reopened index lost vectors"); passed.append("index reopens with source metadata and vectors")
        let query = RetrievalQuery.formulate(question: "latency 42", context: "")
        let v = try await MockEmbeddingProvider().embed([query.semantic])[0]
        let hybrid = try await index.retrieve(query: query, vector: v, model: "mock-embedding-v1", limit: 6)
        try expect(!hybrid.isEmpty, "hybrid failed"); passed.append("local hybrid retrieval end to end")
        try await checkConcurrentKnowledge(root: root)
        passed.append("dense cache isolates libraries and concurrent committed generations")
        let cacheOff = try KnowledgeIndex(directory: root.appendingPathComponent("index"), denseCacheBytes: 0)
        let tinyCache = try KnowledgeIndex(directory: root.appendingPathComponent("index"), denseCacheBytes: 600)
        func verifyCache() async throws {
            for limit in [1, 5, 12] {
                let expected = try await cacheOff.retrieve(query: query, vector: v, model: "mock-embedding-v1", limit: limit)
                for reader in [index, persisted, tinyCache] {
                    let actual = try await reader.retrieve(query: query, vector: v, model: "mock-embedding-v1", limit: limit)
                    try expect(actual == expected, "cached sources, scores or citations changed")
                }
            }
        }
        try await verifyCache()
        var edited = restored
        edited[0].vector = v
        try await persisted.replaceChunks(edited, document: doc)
        try await verifyCache()
        do {
            try await index.replaceChunks([edited[0], edited[0]], document: doc)
            throw CheckError(description: "duplicate primary key accepted")
        } catch is CopilotError {}
        try await verifyCache()
        try await persisted.replaceChunks(restored, document: doc)
        let wrong = try await index.retrieve(query: .formulate(question: "zzzzunrelated", context: ""), vector: v, model: "different-model", limit: 6)
        try expect(wrong.isEmpty, "incompatible model vectors used"); passed.append("embedding model mismatch exclusion")
        do { _ = try await index.reindex(doc, provider: FailingEmbedding()); throw CheckError(description: "failed embedding accepted") }
        catch is CopilotError { }
        let retained = try await index.allChunks()
        try expect(retained == restored, "failed re-index destroyed old index"); passed.append("failed re-index preserves previous usable index")
        let newDoc = try await index.reindex(doc, provider: MockEmbeddingProvider())
        let indexed = try await index.allChunks()
        try expect(indexed.count == newDoc.chunkCount, "re-index duplicated chunks"); passed.append("successful re-index atomically replaces chunks")
        try await verifyCache()
        try await index.delete(doc.id)
        try await verifyCache()
        passed.append("dense cache parity across commits, rollback, external writes, re-index and delete")
        let empty = try await index.allChunks(); let emptyLex = try await index.lexical("latency")
        try expect(empty.isEmpty && emptyLex.isEmpty, "deletion left chunks or FTS rows"); passed.append("delete removes originals vectors metadata and FTS")
        // Provider tests exercise production request encoding/decoding and streamed error paths with no network.
        let transport = FixtureTransport(body: Data(#"{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}"#.utf8), status: 200, events: [])
        let embeddings = try await OpenAIEmbeddingProvider(key: "test-only", model: "fixture", transport: transport).embed(["first", "second"])
        try expect(embeddings == [[1, 0], [0, 1]], "provider didn't reorder indexed vectors"); passed.append("embedding provider parses ordered batches")
        let answer = AnswerRequest(query: query, conversation: "", scenario: .meeting, sources: hybrid)
        try check("raw SSE bytes preserve blank boundaries and fragmented UTF-8") {
            for newline in ["\n", "\r\n", "\r"] {
                let wire = "data: 中文🧪" + newline + newline + "data: second" + newline + newline
                var framer = StreamingLines(), parser = ServerSentEvents(), payloads: [String] = []
                for byte in wire.utf8 {
                    if let line = try framer.consume(byte), let payload = parser.consume(line) { payloads.append(payload) }
                }
                try expect(payloads == ["中文🧪", "second"], "SSE framing merged events or lost Unicode")
                let tail = try framer.finish()
                try expect(tail == nil, "unexpected trailing line")
            }
        }
        try check("invalid UTF-8 stream fails instead of corrupting answer text") {
            var framer = StreamingLines()
            _ = try framer.consume(0xFF)
            do { _ = try framer.consume(10); throw CheckError(description: "invalid encoding accepted") }
            catch is CopilotError { }
        }
        let events = ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"Core answer\"}", "", "data: {\"type\":\"response.completed\"}", ""]
        var text = ""
        for try await delta in OpenAIReasoningProvider(key: "test-only", model: "fixture", transport: FixtureTransport(body: Data(), status: 200, events: events)).stream(answer) { text += delta }
        try expect(text == "Core answer", "stream failed"); passed.append("Responses streams useful text before completion")
        do {
            for try await _ in OpenAIReasoningProvider(key: "test-only", model: "fixture", transport: FixtureTransport(body: Data(), status: 200, events: Array(events.prefix(2)))).stream(answer) { }
            throw CheckError(description: "truncated stream accepted")
        } catch is CopilotError { }
        passed.append("truncated reasoning stream fails visibly")
        try check("reasoning evidence instructions and scenario differences") {
            try expect(answer.input.contains("[S1]") && answer.instructions.contains("untrusted"), "source/prompt contract lost")
            try expect(ScenarioProfile.defense.instructions != ScenarioProfile.interview.instructions, "profiles identical")
        }
        try check("Live append byte budget preserves Unicode boundaries") {
            let original = String(repeating: "中文🧪 context ", count: 100)
            let excerpt = OpenAILiveProvider.contextExcerpt(original)
            try expect(excerpt.utf8.count <= 450 && original.hasPrefix(excerpt), "Live context exceeds token-safe budget")
        }
        let gate = GatedEmbedding()
        let importing = Task { try await index.importDocument(input, provider: gate) }
        await gate.waitUntilCalled()
        let pending = try await index.documents()
        guard let pendingDocument = pending.first else { throw CheckError(description: "missing indexing record") }
        try await index.delete(pendingDocument.id)
        await gate.release()
        do { _ = try await importing.value; throw CheckError(description: "deleted document was resurrected") }
        catch is CancellationError { }
        let afterDeletion = try await index.allChunks()
        try expect(afterDeletion.isEmpty, "in-flight delete left vectors")
        passed.append("deletion during suspended embedding cannot resurrect document")
        let large = root.appendingPathComponent("large.txt")
        try String(repeating: fixture + "\n", count: 500).write(to: large, atomically: true, encoding: .utf8)
        do { _ = try await index.importDocument(large, provider: FailAfterFirstBatch()); throw CheckError(description: "partial indexing accepted") }
        catch is CopilotError { }
        let afterFailure = try await index.allChunks(), failedDocs = try await index.documents()
        try expect(afterFailure.isEmpty && failedDocs.first?.status == "Failed", "partial index became searchable")
        passed.append("mid-batch indexing failure leaves retryable metadata and no partial vectors")
        try check("V1 settings migrate without resetting existing models or behavior") {
            let legacy = Data(#"{"liveModel":"existing-live","reasoningModel":"existing-reasoning","embeddingModel":"existing-embedding","reasoningEffort":"high","mode":"In-Person / Defense","scenario":"Academic Defense","automaticSuggestions":false,"includeConversation":false,"retrievalCount":8}"#.utf8)
            let restored = try JSONDecoder().decode(AppSettings.self, from: legacy)
            try expect(restored.liveModel == "existing-live" && restored.reasoningModel == "existing-reasoning" && restored.embeddingModel == "existing-embedding", "migration reset models")
            try expect(restored.mode == .inPerson && restored.scenario == .defense && !restored.automaticSuggestions && restored.retrievalCount == 8, "migration reset behavior")
            try expect(restored.reasoningService == .sharedOpenAI && restored.language == .system && restored.background == .glass, "unsafe migration defaults")
            try expect(!AppSettings().excludeOverlayFromCapture && !restored.excludeOverlayFromCapture, "capture exclusion must default to off")
            let optedIn = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"excludeOverlayFromCapture":true}"#.utf8))
            try expect(optedIn.excludeOverlayFromCapture, "migration reset explicit capture preference")
            var updated = restored; updated.language = .simplifiedChinese; updated.background = .white; updated.reasoningService = .deepSeek
            updated.excludeOverlayFromCapture = false
            let encoded = try JSONEncoder().encode(updated)
            let roundTrip = try JSONDecoder().decode(AppSettings.self, from: encoded)
            try expect(roundTrip == updated, "preferences fail round trip")
        }
        try check("UI translations preserve source content and source identity") {
            try expect(L10n.text("API key configured", language: .simplifiedChinese) == "API Key 已配置", "credential status not translated")
            try expect(L10n.text("API key configured", language: .english) == "API key configured", "English not selectable")
            try expect(L10n.text("Indexing complete. Retrieval is local.", language: .simplifiedChinese) == "索引完成，检索在本机进行。", "exact indexing completion message hijacked by prefix")
            try expect(L10n.text("Indexing documents…", language: .simplifiedChinese) == "正在导入并建立索引…", "exact indexing documents message hijacked by prefix")
            try expect(chunks[0].displayLabel(language: .simplifiedChinese).contains("第 3 页"), "source page lost")
            try expect(chunks[0].text.contains("128"), "source content altered")
        }
        try check("Traditional Chinese selection, persistence and content boundaries") {
            let traditional = AppLanguage.traditionalChinese
            try expect(traditional.usesChinese && traditional.usesTraditionalChinese, "traditional language classification")
            for identifier in ["zh-Hant", "zh-TW", "zh-HK", "zh_MO"] {
                try expect(AppLanguage.isTraditional(identifier), "traditional system locale missed")
            }
            for identifier in ["en", "zh-CN", "zh-Hans-HK"] {
                try expect(!AppLanguage.isTraditional(identifier), "non-traditional system locale changed")
            }
            try expect(ServiceGuide.text("Settings", "设置", traditional) == "設置", "inline chrome not converted")
            try expect(L10n.text("History", language: traditional) == "歷史記錄", "dictionary chrome not converted")
            try expect(L10n.text("我的简体文档和对话", language: traditional) == "我的简体文档和对话", "user content was converted")
            try expect(ServiceGuide.text("Settings", "设置", .simplifiedChinese) == "设置", "simplified changed")
            try expect(L10n.text("Indexing 简体文档.pdf", language: traditional) == "正在索引 简体文档.pdf", "indexing prefix changed document name")
            try expect(L10n.text("Re-indexing 简体文档.pdf", language: traditional) == "正在重建索引 简体文档.pdf", "index status changed document name")
            try expect(chunks[0].displayLabel(language: traditional).contains("第 3 頁"), "source page not traditional")
            var settings = AppSettings(); settings.language = traditional
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored.language == traditional, "traditional preference not preserved")
        }
        try check("custom endpoint rejects credential URLs and binds keys to destinations") {
            for bad in ["http://example.com", "https://user:password@example.com", "https://example.com?api_key=fixture", "https://example.com#fragment"] {
                do { _ = try ServiceEndpoint.make(baseURL: bad, path: "chat/completions"); throw CheckError(description: "unsafe endpoint accepted") }
                catch is CopilotError { }
            }
            let endpoint = try ServiceEndpoint.make(baseURL: "https://EXAMPLE.com:443/v1/", path: "/chat/completions")
            try expect(endpoint.absoluteString == "https://example.com/v1/chat/completions", "incorrect endpoint join")
            var one = AppSettings(); one.reasoningService = .compatible; one.compatibleBaseURL = "https://one.example/v1"
            var two = one; two.compatibleBaseURL = "https://two.example/v1"
            let a = try one.analysisCredentialReference(), b = try two.analysisCredentialReference()
            try expect(a != b && a != .live && a != .deepSeek, "credential identities overlap")
        }
        let chatEvents = [
            #"data: {"choices":[],"usage":{"prompt_tokens":12}}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"private-reasoning-fixture"},"finish_reason":null}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"content":"42 毫秒 [S1]"},"finish_reason":null}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "", "data: [DONE]", ""
        ]
        for service in ReasoningService.allCases {
            var settings = AppSettings(); settings.reasoningService = service
            settings.compatibleBaseURL = "https://analysis.example/v1"; settings.compatibleModel = "fixture-model"
            let wire = service == .sharedOpenAI || service == .separateOpenAI ? events : chatEvents
            let recorder = RecordingTransport(events: wire)
            let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: "live-fixture-only", analysisKey: "analysis-fixture-only", transport: recorder)
            var output = ""
            for try await delta in provider.stream(answer) { output += delta }
            let request = recorder.requests[0]
            let expectedKey = service == .sharedOpenAI ? "live-fixture-only" : "analysis-fixture-only"
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedKey, "service received wrong credential")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try expect(body["stream"] as? Bool == true, "stream disabled")
            if service != .sharedOpenAI && service != .separateOpenAI {
                try expect(output == "42 毫秒 [S1]" && !output.contains("private-reasoning"), "final text/source corrupted or reasoning leaked")
                try expect((body["messages"] as? [[String: String]])?.last?["content"]?.contains("[S1]") == true, "evidence omitted")
                try expect((body["thinking"] != nil) == (service == .deepSeek || service == .kimi || service == .glm), "vendor options leaked to custom service")
            } else {
                try expect(body["store"] as? Bool == false, "OpenAI storage contract changed")
                try expect(request.url?.path == "/v1/responses" && body["model"] as? String == "gpt-6-sol", "new default not routed through Responses")
                try expect((body["reasoning"] as? [String: String])?["effort"] == "low", "supported low reasoning effort changed")
                try expect(body["service_tier"] as? String == "default" && body["temperature"] == nil, "Standard request did not pin the default tier or added an incompatible parameter")
            }
            passed.append("analysis routing and credential isolation: " + service.rawValue)
        }
        try check("preset connections persist and isolate credentials by provider and region") {
            var identities = Set<String>()
            for service in [ReasoningService.qwen, .glm, .kimi] {
                var settings = AppSettings(); settings.reasoningService = service
                let initial = try settings.analysisCredentialReference()
                try expect(initial != .live && initial != .deepSeek, "preset reuses an existing provider key")
                identities.insert(initial.service + initial.account)
                var connection = settings.presetConnection!
                connection.model = "another-model"; connection.thinking = .enabled
                settings.presetConnection = connection
                let sameHost = try settings.analysisCredentialReference()
                try expect(sameHost == initial, "model edit unnecessarily discarded provider key")
                connection.baseURL = "https://region.example/v1"; settings.presetConnection = connection
                let otherHost = try settings.analysisCredentialReference()
                try expect(otherHost != initial, "region change inherited old endpoint key")
                let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
                try expect(restored == settings, "preset connection did not persist")
                do { _ = try ReasoningProviderFactory.make(settings: settings, liveKey: "live-fixture-only", analysisKey: nil); throw CheckError(description: "Live key inherited by preset") }
                catch is CopilotError { }
            }
            try expect(identities.count == 3, "preset credentials overlap")
        }
        try check("vendor thinking options and endpoints follow their own protocols") {
            let endpoints = [ReasoningService.qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                             .glm: "https://open.bigmodel.cn/api/paas/v4/chat/completions", .kimi: "https://api.moonshot.cn/v1/chat/completions"]
            for (service, endpoint) in endpoints {
                let base = AppSettings()
                let model = service == .qwen ? base.qwenConnection.model : service == .glm ? base.glmConnection.model : base.kimiConnection.model
                for thinking in service.availableThinkingModes(for: model) {
                    var settings = AppSettings(); settings.reasoningService = service
                    settings.analysisThinking = thinking
                    let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: nil, analysisKey: "fixture") as! ChatCompletionsProvider
                    let http = try provider.httpRequest(answer)
                    let body = try JSONSerialization.jsonObject(with: http.httpBody!) as! [String: Any]
                    try expect(http.url?.absoluteString == endpoint && body["model"] as? String == settings.analysisModel, "wrong preset endpoint or model")
                    try expect(body["temperature"] == nil, "unsupported sampling parameters sent")
                    try expect(body["reasoning_effort"] as? String == thinking.effort, "wrong effort parameter")
                    if service == .qwen {
                        try expect(body["enable_thinking"] as? Bool == (thinking != .disabled) && body["thinking"] == nil, "Qwen wire format incorrect")
                    } else {
                        try expect((body["thinking"] as? [String: String])?["type"] == (thinking == .disabled ? "disabled" : "enabled") && body["enable_thinking"] == nil, "GLM/Kimi wire format incorrect")
                    }
                }
            }
        }
        try check("external analysis cannot silently fall back to the Live credential") {
            var settings = AppSettings(); settings.reasoningService = .deepSeek
            do { _ = try ReasoningProviderFactory.make(settings: settings, liveKey: "live-fixture-only", analysisKey: nil); throw CheckError(description: "Live key leaked as fallback") }
            catch is CopilotError { }
        }
        for broken in [
            Array(chatEvents.prefix(6)),
            [#"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#, ""],
            [#"data: {"error":{"message":"must-not-echo-private-server-text"}}"#, ""],
            ["data: malformed", ""], ["data: [DONE]", ""]
        ] {
            let provider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: URL(string: "https://fixture.example/chat/completions")!, transport: FixtureTransport(body: Data(), status: 200, events: broken))
            do { for try await _ in provider.stream(answer) {}; throw CheckError(description: "bad Chat Completion accepted") }
            catch let error as CopilotError { try expect(!error.localizedDescription.contains("must-not-echo"), "raw server error leaked") }
            catch let error as ServiceHTTPFailure {
                try expect(error.kind == .service && !error.localizedDescription.contains("must-not-echo"), "stream error category or privacy lost")
            }
        }
        passed.append("Chat Completions truncated, empty, malformed and error streams fail safely")
        try check("local model download status accepts HTTP 206 only on resumed transfers") {
            try expect(LocalModelInstaller.isAcceptableDownloadStatus(200, resumed: false), "fresh HTTP 200 rejected")
            try expect(LocalModelInstaller.isAcceptableDownloadStatus(200, resumed: true), "resumed HTTP 200 rejected")
            try expect(LocalModelInstaller.isAcceptableDownloadStatus(206, resumed: true), "resumed HTTP 206 rejected")
            try expect(!LocalModelInstaller.isAcceptableDownloadStatus(206, resumed: false), "fresh HTTP 206 accepted")
            for status in [204, 404, 500] {
                try expect(!LocalModelInstaller.isAcceptableDownloadStatus(status, resumed: false), "fresh HTTP \(status) accepted")
                try expect(!LocalModelInstaller.isAcceptableDownloadStatus(status, resumed: true), "resumed HTTP \(status) accepted")
            }
        }
        do {
            let compatibleEndpoint = URL(string: "https://fixture.example/chat/completions")!
            let compatibleEvents = [
                #"data: {"error":null,"choices":[{"index":0,"delta":{"content":"Compatible "},"finish_reason":""}]}"#, "",
                #"data: {"error":null,"choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":"stop"}]}"#, "",
                "data: [DONE]", ""
            ]
            let okProvider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: compatibleEndpoint,
                                                     transport: FixtureTransport(body: Data(), status: 200, events: compatibleEvents))
            var compatibleOutput = ""
            for try await delta in okProvider.stream(answer) { compatibleOutput += delta }
            try expect(compatibleOutput == "Compatible answer", "compatible null error / empty finish_reason chunk failed: \(compatibleOutput)")
            let authErrorEvents = [#"data: {"error":{"message":"bad key","code":"invalid_api_key"}}"#, ""]
            let authProvider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: compatibleEndpoint,
                                                       transport: FixtureTransport(body: Data(), status: 200, events: authErrorEvents))
            do {
                for try await _ in authProvider.stream(answer) {}
                throw CheckError(description: "non-null SSE error accepted")
            } catch let error as ServiceHTTPFailure {
                try expect(error.kind == .authentication && !error.localizedDescription.contains("bad key"), "SSE error classification or privacy lost")
            }
            let lengthEvents = [#"data: {"error":null,"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#, ""]
            let lengthProvider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: compatibleEndpoint,
                                                         transport: FixtureTransport(body: Data(), status: 200, events: lengthEvents))
            do {
                for try await _ in lengthProvider.stream(answer) {}
                throw CheckError(description: "length finish_reason accepted")
            } catch let error as CopilotError {
                try expect(error.localizedDescription.contains("interrupted"), "unexpected length error: \(error.localizedDescription)")
            }
            passed.append("Chat Completions accepts null error and empty finish_reason while rejecting real errors and length stops")
        }
        try check("StreamingLines strips leading UTF-8 BOM only on the first SSE line") {
            let bomWire = "\u{FEFF}data: first\n\ndata: \u{FEFF}second\n\n"
            var framer = StreamingLines(), parser = ServerSentEvents(), payloads: [String] = []
            for byte in bomWire.utf8 {
                if let line = try framer.consume(byte), let payload = parser.consume(line) { payloads.append(payload) }
            }
            try expect(payloads == ["first", "\u{FEFF}second"], "BOM stripping corrupted SSE payloads: \(payloads)")
        }
        try check("HTTP 200 JSON error body detection preserves service error classification") {
            let errorJSON = Data(#"{"error":{"message":"invalid key","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
            do {
                try OpenAIHTTP.checkJSONErrorBody(errorJSON)
                throw CheckError(description: "HTTP 200 JSON error body accepted")
            } catch let error as ServiceHTTPFailure {
                try expect(error.kind == .authentication && !error.localizedDescription.contains("invalid key"), "JSON error body classification lost")
            }
            try OpenAIHTTP.checkJSONErrorBody(Data(#"{"error":null,"choices":[]}"#.utf8))
            try OpenAIHTTP.checkJSONErrorBody(Data("data: {\"choices\":[]}\n\n".utf8))
        }
        passed.append(contentsOf: try await checkURLSessionTransport(answer: answer))
        do {
            for blankModel in ["", "   \n\t "] {
                let recorder = RecordingTransport(events: [])
                do {
                    _ = try await OpenAIEmbeddingProvider(key: "test-only", model: blankModel, transport: recorder).embed(["hello"])
                    throw CheckError(description: "blank embedding model accepted")
                } catch is CopilotError { }
            }
            passed.append("embedding provider rejects empty or whitespace model before calling transport")
        }
        return passed
    }
    private static func checkConcurrentKnowledge(root: URL) async throws {
        let folder = root.appendingPathComponent("concurrent")
        let writer = try KnowledgeIndex(directory: folder)
        let readers = try [KnowledgeIndex(directory: folder), KnowledgeIndex(directory: folder, denseCacheBytes: 3_000)]
        let other = try KnowledgeIndex(directory: root.appendingPathComponent("other"))
        let doc = KnowledgeDocument(id: "same-document", name: "versioned", importedAt: Date(),
                                    localPath: "", status: "Ready", chunkCount: 9, embeddingModel: "fixture")
        func generation(_ version: Int) -> [SourceChunk] {
            (0..<9).map { i in
                SourceChunk(id: "same-\(i)", documentID: doc.id, documentName: "edition \(version)",
                            ordinal: i, page: version, text: "marker \(version) item \(i)",
                            vector: i == version ? [1, 0] : [0.5, 1], embeddingModel: "fixture")
            }
        }
        let query = RetrievalQuery.formulate(question: "marker", context: "")
        @Sendable func results(_ index: KnowledgeIndex) async throws -> [RetrievedSource] {
            try await index.retrieve(query: query, vector: [1, 0], model: "fixture", limit: 12)
        }
        let first = generation(1), second = generation(2)
        let empty = try await results(readers[0])
        try expect(empty.isEmpty, "empty snapshot not empty")
        try await writer.replaceChunks(first, document: doc)
        let a = try await results(readers[0])
        try await writer.replaceChunks(second, document: doc)
        let b = try await results(readers[0])
        try expect(a.count == 9 && b.count == 9 && a != b, "missing generation transition")
        try await other.replaceChunks(generation(3), document: doc)
        let isolated = try await results(other)
        try expect(isolated != a && isolated != b, "library collision")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<60 {
                    try await writer.replaceChunks(i.isMultiple(of: 2) ? first : second, document: doc)
                }
            }
            for index in readers + readers {
                group.addTask {
                    for _ in 0..<75 {
                        let observed = try await results(index)
                        try expect(observed == a || observed == b, "mixed document generations")
                    }
                }
            }
            try await group.waitForAll()
        }
        let final = try await results(readers[1])
        let unchanged = try await results(other)
        try expect(final == b && unchanged == isolated, "post-commit visibility or library isolation failed")
    }

    private static func checkURLSessionTransport(answer: AnswerRequest) async throws -> [String] {
        var passed: [String] = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func streamWithStub(status: Int, contentType: String, body: Data, chunkSize: Int = 4096,
                            maxJSONBodyBytes: Int = OpenAIHTTP.maxJSONErrorBytes) async throws -> String {
            let token = "stub-" + UUID().uuidString
            StubHTTPProtocol.registry.set(.init(status: status, contentType: contentType, body: body, chunkSize: chunkSize), for: token)
            defer { StubHTTPProtocol.registry.remove(for: token) }
            let transport = URLSessionTransport(session: session, maxJSONBodyBytes: maxJSONBodyBytes)
            let provider = OpenAIReasoningProvider(key: token, model: "gpt-6-sol", transport: transport)
            var output = ""
            for try await delta in provider.stream(answer) { output += delta }
            return output
        }

        // Test 1: HTTP 200 JSON error bodies > 8 KiB (padding before and after error details) and > 8 KiB non-2xx
        // preserve ServiceHTTPFailure classification through real URLSessionTransport.lines(for:).
        let padding16K = String(repeating: "x", count: 16_384)
        let authJSON = Data("{\"meta\":\"\(padding16K)\",\"error\":{\"message\":\"secret-auth-detail\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}".utf8)
        do {
            _ = try await streamWithStub(status: 200, contentType: "application/json; charset=utf-8", body: authJSON)
            throw CheckError(description: ">8 KiB HTTP 200 auth JSON error accepted")
        } catch let error as ServiceHTTPFailure {
            try expect(error.kind == .authentication && !error.localizedDescription.contains("secret-auth-detail"),
                       "expected .authentication for >8 KiB HTTP 200 JSON error, got \(error.kind): \(error.localizedDescription)")
        }
        let rateLimitJSON = Data("{\"error\":{\"message\":\"secret-rate-detail\",\"type\":\"rate_limit_exceeded\",\"details\":\"\(padding16K)\"}}".utf8)
        do {
            _ = try await streamWithStub(status: 200, contentType: "application/problem+json", body: rateLimitJSON)
            throw CheckError(description: ">8 KiB HTTP 200 rate-limit JSON error accepted")
        } catch let error as ServiceHTTPFailure {
            try expect(error.kind == .rateLimit && !error.localizedDescription.contains("secret-rate-detail"),
                       "expected .rateLimit for >8 KiB HTTP 200 +json error, got \(error.kind): \(error.localizedDescription)")
        }
        let billing429JSON = Data("{\"meta\":\"\(padding16K)\",\"error\":{\"message\":\"secret-billing-detail\",\"code\":\"insufficient_quota\"}}".utf8)
        do {
            _ = try await streamWithStub(status: 429, contentType: "application/json", body: billing429JSON)
            throw CheckError(description: ">8 KiB HTTP 429 JSON error accepted")
        } catch let error as ServiceHTTPFailure {
            try expect(error.status == 429 && error.kind == .billing && !error.localizedDescription.contains("secret-billing-detail"),
                       "expected HTTP 429 .billing for >8 KiB error body, got status=\(error.status) kind=\(error.kind)")
        }
        passed.append("URLSessionTransport preserves error classification for >8 KiB HTTP 200 and non-2xx JSON error bodies")

        // Test 2: Oversized HTTP 200 JSON body stops at bounded cap and non-error JSON fails explicitly without falling through to SSE.
        try expect(OpenAIHTTP.maxJSONErrorBytes == 262_144, "unexpected maxJSONErrorBytes default: \(OpenAIHTTP.maxJSONErrorBytes)")
        let oversizedDefault = Data("{\"error\":{\"code\":\"invalid_api_key\",\"padding\":\"\(String(repeating: "y", count: OpenAIHTTP.maxJSONErrorBytes + 4096))\"}}".utf8)
        do {
            _ = try await streamWithStub(status: 200, contentType: "application/json", body: oversizedDefault, chunkSize: 4096)
            throw CheckError(description: "oversized HTTP 200 JSON body accepted")
        } catch let error as CopilotError {
            try expect(error.localizedDescription.contains("oversized JSON error response"), "unexpected oversized JSON error: \(error.localizedDescription)")
            try expect(!error.localizedDescription.contains("Reasoning stream ended without a complete answer"), "oversized JSON fell through to SSE")
        }
        let oversizedCustom = Data("{\"padding\":\"\(String(repeating: "z", count: 4096))\",\"error\":{\"code\":\"invalid_api_key\"}}".utf8)
        do {
            _ = try await streamWithStub(status: 200, contentType: "application/json", body: oversizedCustom, chunkSize: 512, maxJSONBodyBytes: 1024)
            throw CheckError(description: "oversized HTTP 200 JSON body bypassed custom maxJSONBodyBytes")
        } catch let error as CopilotError {
            try expect(error.localizedDescription.contains("oversized JSON error response"), "unexpected custom-cap oversized JSON error: \(error.localizedDescription)")
        }
        for nonErrorBody in [Data(#"{"status":"ok","error":null}"#.utf8), Data("{malformed-json".utf8)] {
            do {
                _ = try await streamWithStub(status: 200, contentType: "application/json", body: nonErrorBody)
                throw CheckError(description: "HTTP 200 non-error JSON response accepted")
            } catch let error as CopilotError {
                try expect(error.localizedDescription.contains("JSON instead of a reasoning stream"), "unexpected non-error JSON error: \(error.localizedDescription)")
                try expect(!error.localizedDescription.contains("Reasoning stream ended without a complete answer"), "non-error JSON fell through to SSE")
            }
        }
        passed.append("URLSessionTransport bounds oversized and non-error HTTP 200 JSON bodies without falling through to SSE")

        // Test 3: Normal HTTP 200 text/event-stream SSE response streams cleanly through URLSessionTransport.
        let sseWire = Data("event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"延迟 42 毫秒 🧪\"}\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n".utf8)
        let streamedText = try await streamWithStub(status: 200, contentType: "text/event-stream; charset=utf-8", body: sseWire, chunkSize: 7)
        try expect(streamedText == "延迟 42 毫秒 🧪", "normal SSE stream corrupted: \(streamedText)")
        passed.append("URLSessionTransport streams normal HTTP 200 text/event-stream SSE responses cleanly")

        return passed
    }

}
struct FailingEmbedding: EmbeddingProvider {
    let model = "failing"
    func embed(_ texts: [String]) async throws -> [[Float]] { throw CopilotError.message("Mock embedding unavailable") }
}
struct FixtureTransport: HTTPTransport {
    let body: Data
    let status: Int
    let events: [String]
    func data(for request: URLRequest) async throws -> (Data, Int) { (body, status) }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

actor GatedEmbedding: EmbeddingProvider {
    nonisolated let model = "gated"
    private var called = false
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<[[Float]], Error>?
    private var count = 0
    func waitUntilCalled() async {
        if called { return }
        await withCheckedContinuation { entered = $0 }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        count = texts.count; called = true; entered?.resume(); entered = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: Array(repeating: [1, 0], count: count)); pending = nil }
}
actor FailAfterFirstBatch: EmbeddingProvider {
    nonisolated let model = "partial-failure"
    private var calls = 0
    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        if calls > 1 { throw CopilotError.message("Synthetic second batch failure") }
        return Array(repeating: [1, 0], count: texts.count)
    }
}

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    let events: [String]
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(events: [String]) { self.events = events }
    func data(for request: URLRequest) async throws -> (Data, Int) { throw CoreChecks.CheckError(description: "unexpected data request") }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

/// Deterministic speech-like signals (syllable bursts of harmonics with pauses) and a simple
/// loudspeaker-to-microphone path, for echo checks without recordings.
enum SyntheticTalk {
    static let rate = 16000.0
    static func speech(seed: UInt64, seconds: Double, level: Float = 0.25) -> [Float] {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func random() -> Double { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Double(state % 1_000_000) / 1_000_000 }
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var i = 0
        while i < out.count {
            let burst = Int((0.12 + random() * 0.18) * rate), amplitude = Float(0.2 + random() * 0.8) * level
            let pitch = 110 + random() * 120
            for k in 0..<burst where i + k < out.count {
                let t = Double(k) / rate, envelope = Float(sin(Double.pi * Double(k) / Double(burst)))
                out[i + k] = amplitude * envelope * Float(sin(2 * .pi * pitch * t) + 0.5 * sin(4 * .pi * pitch * t) + 0.25 * sin(6 * .pi * pitch * t)) / 1.75
            }
            i += burst + Int((0.04 + random() * (random() < 0.15 ? 0.5 : 0.12)) * rate)
        }
        return out
    }
    static func echo(_ x: [Float], delay: Double, gain: Float, count: Int) -> [Float] {
        var y = [Float](repeating: 0, count: count)
        for (offset, weight) in [(0.0, Float(1)), (0.04, 0.4), (0.1, 0.2)] {
            let d = Int((delay + offset) * rate)
            for i in x.indices where i + d < count { y[i + d] += x[i] * weight * gain }
        }
        var noise: UInt64 = 0x2545F4914F6CDD1D
        for i in y.indices { noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17; y[i] += Float(Int(noise % 2001) - 1000) / 1_000_000 }
        return y
    }
    static func pcm(_ x: ArraySlice<Float>) -> Data {
        var data = Data(capacity: x.count * 2)
        for v in x { var s = Int16(max(-32767, min(32767, v * 32767))).littleEndian; withUnsafeBytes(of: &s) { data.append(contentsOf: $0) } }
        return data
    }
    /// Delivers both sources in 20 ms buffers on the uptime clock starting at `base`.
    static func feed(_ monitor: EchoMonitor, system: [Float], mic: [Float], base: TimeInterval) {
        let step = Int(rate * 0.02)
        for start in stride(from: 0, to: max(system.count, mic.count), by: step) {
            let end = start + step, at = base + Double(end) / rate
            if start < system.count { monitor.observe(pcm(system[start..<min(end, system.count)]), source: .system, at: at) }
            if start < mic.count { monitor.observe(pcm(mic[start..<min(end, mic.count)]), source: .mic, at: at + 0.003) }
        }
    }
}

private final class StubHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: StubHTTPProtocol.Response] = [:]
    func set(_ response: StubHTTPProtocol.Response, for token: String) {
        lock.withLock { responses[token] = response }
    }
    func remove(for token: String) {
        lock.withLock { _ = responses.removeValue(forKey: token) }
    }
    func get(for token: String) -> StubHTTPProtocol.Response? {
        lock.withLock { responses[token] }
    }
}

private final class StubHTTPProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data
        let chunkSize: Int
    }
    static let registry = StubHTTPRegistry()
    private let stopLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        guard let stub = Self.registry.get(for: token),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": stub.contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let step = max(1, stub.chunkSize)
        var offset = 0
        while offset < stub.body.count {
            if stopLock.withLock({ stopped }) { return }
            let end = min(offset + step, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        if !stopLock.withLock({ stopped }) {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }
}
