import Foundation
import AppKit
import XCTest
@testable import LiveCopilot

final class ModelHealthTests: XCTestCase {
    @MainActor func testRealModelInstallSelfCheckAndRecovery() async throws {
        guard ProcessInfo.processInfo.environment["LIVECOPILOT_TEST_REAL_LAYA"] == "1" else { throw XCTSkip("Opt-in real local model check") }
        let source = LocalModelKind.embedding.location(in: AppPaths.modelsDirectory(mock: false))
        let executable = Bundle.main.resourceURL!.appendingPathComponent("LocalRuntime/livecopilot-inference")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-health-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercise the actual installer, checksum/commit, manager and real native worker.
        let manager = LocalModelManager(root: root, checker: { kind, root in
            try await LocalModelSelfCheck.run(kind, root: root, executable: executable)
        }, installation: { kind, root in
            try await LocalModelInstaller.install(kind, root: root, downloader: { file, target in
                try FileManager.default.copyItem(at: source.appendingPathComponent(file.name), to: target)
            })
        })
        manager.install(.embedding)
        while manager.downloading != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(manager.installed.contains(.embedding) && manager.health[.embedding]?.ready == true)
        let report = manager.health[.embedding]!.diagnostic(kind: .embedding)
        precondition(!report.contains(root.path) && !report.contains(NSUserName()) && !report.contains("Local model self-check."))
        print("PASS verified install → real self-check → ready; privacy-safe diagnostics")
        // Use a private pasteboard; do not overwrite the user's clipboard during tests.
        let board = NSPasteboard.withUniqueName()
        precondition(board.setString(report, forType: .string))
        precondition(board.string(forType: .string) == report)
        board.releaseGlobally()
        print("PASS diagnostic pasteboard roundtrip")
        let fake = root.appendingPathComponent("failing-worker")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":false,\"error\":\"embedding_context\"}'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let failure = try await LocalModelSelfCheck.run(.embedding, root: root, executable: fake)
        precondition(failure.stage == .memory && failure.checksum == "passed")
        precondition(failure.advice(english: false).contains("关闭"))
        let missing = try await LocalModelSelfCheck.run(.embedding, root: root, executable: root.appendingPathComponent("missing"))
        precondition(missing.stage == .runtime)
        print("PASS memory failure and missing runtime give distinct recovery advice")
        let file = LocalModelKind.embedding.location(in: root).appendingPathComponent("bge-m3-Q8_0.gguf")
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data([0, 0, 0, 0])); try handle.close()
        precondition(LocalModelKind.embedding.isInstalled(in: root))
        manager.runSelfCheck(.embedding)
        while manager.downloading != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(manager.health[.embedding]?.stage == .files)
        precondition(manager.health[.embedding]!.advice(english: false).contains("重新下载"))
        manager.install(.embedding)
        while manager.downloading != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(manager.health[.embedding]?.ready == true)
        print("PASS same-size corruption → failed self-check → reinstall → ready")
        let cancelled = LocalModelManager(root: root, checker: { _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(stage: .ready, checkedAt: Date(), checksum: "passed", runtimeCode: "ok")
        })
        cancelled.runSelfCheck(.embedding)
        while cancelled.checking == nil { await Task.yield() }
        cancelled.cancel(); await cancelled.shutdown()
        precondition(cancelled.health[.embedding] == nil && cancelled.checking == nil && cancelled.downloading == nil)
        precondition(LocalModelKind.embedding.isInstalled(in: root))
        print("PASS cancellation never marks ready and preserves installed model")
        await manager.shutdown()
    }

    func testWorkerTimeoutResetsDiagnosticCodeAndProviderFallsBackOnTimeout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("worker-timeout-reset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Direct worker test: timeout -> crash must report "process_ended", then ok resets to "unknown".
        let workerScript = dir.appendingPathComponent("timeout-then-crash-worker")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            text = req.get("text")
            if text == "hang":
                time.sleep(10)
            elif text == "crash":
                sys.exit(1)
            sys.stdout.write(json.dumps({"id": req["id"], "ok": True}) + "\\n"); sys.stdout.flush()
        """.write(to: workerScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workerScript.path)

        let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: dir, executable: workerScript, sigkillGraceSeconds: 0.15)
        defer { worker.close(initiator: .selfCheck) }

        do {
            _ = try await worker.call(["op": "embed", "text": "hang"], timeout: 0.15)
            XCTFail("Expected timeout error")
        } catch is CopilotError {
            XCTAssertEqual(worker.failureCode, "timeout")
        }

        do {
            _ = try await worker.call(["op": "embed", "text": "crash"], timeout: 5.0)
            XCTFail("Expected process_ended error after crash")
        } catch is CopilotError {
            XCTAssertEqual(worker.failureCode, "process_ended", "diagnosticCode remained stuck on timeout after subsequent crash")
        }

        let ok = try await worker.call(["op": "embed", "text": "ok"], timeout: 5.0)
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(worker.failureCode, "unknown", "diagnosticCode should reset on successful reply")

        // 2. LocalEmbeddingProvider falls back to embedding-cpu on GPU timeout.
        let modeLog = dir.appendingPathComponent("timeout-fallback-modes.log")
        let fallbackScript = dir.appendingPathComponent("gpu-timeout-fallback-worker")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        mode = sys.argv[1]
        with open(\(String(reflecting: modeLog.path)), "a") as f:
            f.write(mode + "\\n")
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        vec = [1.0] + [0.0] * 1023
        for line in sys.stdin:
            req = json.loads(line)
            if mode == "embedding" and req.get("text") == "hang-gpu":
                time.sleep(10)
            sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
        """.write(to: fallbackScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallbackScript.path)

        let provider = LocalEmbeddingProvider(directory: dir, executable: fallbackScript, queryTimeout: 0.9, indexingTimeout: 2.0)
        defer { provider.close(initiator: .selfCheck) }

        let vectors = try await provider.embed(["hang-gpu"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors[0].count, 1024)
        XCTAssertEqual(vectors[0][0], 1.0)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding", "embedding-cpu"])
        #endif
    }

    func testConcurrentEmbeddingCallersMigrateToCPUWithoutCancellationError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent-failover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modeLog = dir.appendingPathComponent("modes.log")
        let startedFlag = dir.appendingPathComponent("gpu-started.flag")
        let releaseFlag = dir.appendingPathComponent("gpu-crash.flag")
        let script = dir.appendingPathComponent("concurrent-gpu-crash-worker")
        try """
        #!/usr/bin/env python3
        import json, os, sys, time
        mode = sys.argv[1]
        with open(\(String(reflecting: modeLog.path)), "a") as f:
            f.write(mode + "\\n")
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            text = req.get("text", "")
            if mode == "embedding" and text == "first":
                with open(\(String(reflecting: startedFlag.path)), "w") as f:
                    f.write("started\\n")
                deadline = time.time() + 5.0
                while not os.path.exists(\(String(reflecting: releaseFlag.path))) and time.time() < deadline:
                    time.sleep(0.01)
                sys.exit(1)
            vec = ([1.0, 0.0] if text == "first" else [0.0, 1.0]) + [0.0] * 1022
            sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = LocalEmbeddingProvider(directory: dir, executable: script, queryTimeout: 5.0, indexingTimeout: 5.0)
        defer { provider.close(initiator: .selfCheck) }

        let firstTask = Task { try await provider.embed(["first"]) }
        #if !arch(x86_64)
        let waitDeadline = Date().addingTimeInterval(3.0)
        while !FileManager.default.fileExists(atPath: startedFlag.path) && Date() < waitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedFlag.path), "First caller did not reach GPU worker")
        #endif

        let secondTask = Task { try await provider.embed(["second"]) }
        #if !arch(x86_64)
        // Give the second caller time to enqueue on the GPU worker before triggering the crash.
        try await Task.sleep(nanoseconds: 80_000_000)
        try Data("crash".utf8).write(to: releaseFlag)
        #endif

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        XCTAssertEqual(firstResult.count, 1)
        XCTAssertEqual(firstResult[0].count, 1024)
        XCTAssertEqual(firstResult[0][0], 1.0)
        XCTAssertEqual(secondResult.count, 1)
        XCTAssertEqual(secondResult[0].count, 1024)
        XCTAssertEqual(secondResult[0][1], 1.0)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding", "embedding-cpu"])
        #endif
    }

    func testLocalModelSelfCheckEmbeddingFallsBackToCPUOnMetalCrash() async throws {
        #if arch(x86_64)
        throw XCTSkip("Embedding CPU fallback retry in LocalModelSelfCheck is arm64-only; x86_64 defaults to CPU in-process")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("self-check-cpu-fallback-" + UUID().uuidString)
        let modelDir = LocalModelKind.embedding.location(in: root)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modeLog = root.appendingPathComponent("self-check-modes.log")
        let script = root.appendingPathComponent("metal-crash-self-check-worker")
        try """
        #!/usr/bin/env python3
        import json, sys
        mode = sys.argv[1]
        with open(\(String(reflecting: modeLog.path)), "a") as f:
            f.write(mode + "\\n")
        if mode == "embedding":
            sys.exit(1)
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        vec = [1.0] + [0.0] * 1023
        for line in sys.stdin:
            req = json.loads(line)
            sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let report = try await LocalModelSelfCheck.run(
            .embedding,
            root: root,
            executable: script,
            verifyFiles: { _, _ in }
        )
        XCTAssertEqual(report.stage, .ready)
        XCTAssertTrue(report.ready)
        XCTAssertEqual(report.checksum, "passed")
        XCTAssertEqual(report.runtimeCode, "ok")

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(modes, ["embedding", "embedding-cpu"])

        // When both GPU and CPU workers crash out-of-process, self-check still reports .interrupted.
        let bothCrash = root.appendingPathComponent("both-crash-worker")
        try "#!/bin/sh\nexit 1\n".write(to: bothCrash, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bothCrash.path)

        let failedReport = try await LocalModelSelfCheck.run(
            .embedding,
            root: root,
            executable: bothCrash,
            verifyFiles: { _, _ in }
        )
        XCTAssertEqual(failedReport.stage, .interrupted)
        XCTAssertEqual(failedReport.runtimeCode, "process_ended")
        #endif
    }

    func testQueueWaitTimeoutDuringHealthyIndexingDoesNotFailOverToCPU() async throws {
        XCTAssertEqual(CaptureDiagnostics.Failure(rawValue: "queue_timeout"), .queueTimeout)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("queue-timeout-healthy-gpu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modeLog = dir.appendingPathComponent("modes.log")
        let startedFlag = dir.appendingPathComponent("index-started.flag")
        let releaseFlag = dir.appendingPathComponent("index-release.flag")
        let script = dir.appendingPathComponent("healthy-slow-index-worker")
        try """
        #!/usr/bin/env python3
        import json, os, sys, time
        mode = sys.argv[1]
        with open(\(String(reflecting: modeLog.path)), "a") as f:
            f.write(mode + "\\n")
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        for line in sys.stdin:
            req = json.loads(line)
            text = req.get("text", "")
            if text == "index-chunk":
                with open(\(String(reflecting: startedFlag.path)), "w") as f:
                    f.write("started\\n")
                deadline = time.time() + 5.0
                while not os.path.exists(\(String(reflecting: releaseFlag.path))) and time.time() < deadline:
                    time.sleep(0.01)
                vec = [0.5] + [0.0] * 1023
            elif text == "quick-query":
                vec = [0.25] + [0.0] * 1023
            else:
                vec = [1.0] + [0.0] * 1023
            sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = LocalEmbeddingProvider(directory: dir, executable: script, queryTimeout: 0.25, indexingTimeout: 5.0)
        defer { provider.close(initiator: .selfCheck) }

        // Warm up using the indexing timeout so Python cold-start never races the tight queryTimeout.
        let warmup = try await provider.embed(["warmup"], progress: { _ in })
        XCTAssertEqual(warmup.count, 1)
        XCTAssertTrue(provider.isPrepared)

        let indexTask = Task { try await provider.embed(["index-chunk"], progress: { _ in }) }
        let waitDeadline = Date().addingTimeInterval(3.0)
        while !FileManager.default.fileExists(atPath: startedFlag.path) && Date() < waitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedFlag.path), "Indexing chunk never started on resident worker")

        // Trailing live query waits in the queue behind healthy indexing and hits queryTimeout (0.25s).
        do {
            _ = try await provider.embed(["trailing-query"])
            XCTFail("Expected trailing queued query to throw queue-wait timeout")
        } catch let error as CopilotError {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), "Unexpected error: \(error)")
        }

        // Queue-wait timeout must NOT clear prepared state or kill the running GPU worker.
        XCTAssertTrue(provider.isPrepared)

        try Data("release".utf8).write(to: releaseFlag)

        let indexed = try await indexTask.value
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed[0].count, 1024)
        XCTAssertEqual(indexed[0][0], 0.5)

        let quick = try await provider.embed(["quick-query"])
        XCTAssertEqual(quick.count, 1)
        XCTAssertEqual(quick[0].count, 1024)
        XCTAssertEqual(quick[0][0], 0.25)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(modes.count, 1, "Queue-wait timeout must not respawn or fail over the healthy worker: \(modes)")
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding"])
        #endif

        // Direct worker check: queue timeout reports failureCode "queue_timeout" without clobbering worker.failureCode.
        try? FileManager.default.removeItem(at: startedFlag)
        try? FileManager.default.removeItem(at: releaseFlag)
        let worker = LocalInferenceWorker(mode: "embedding", modelDirectory: dir, executable: script, sigkillGraceSeconds: 0.15)
        defer { worker.close(initiator: .selfCheck) }

        _ = try await worker.call(["op": "embed", "text": "warmup"], timeout: 5.0)
        let activeTask = Task { await worker.callWithOutcome(["op": "embed", "text": "index-chunk"], timeout: 5.0) }
        let workerWaitDeadline = Date().addingTimeInterval(3.0)
        while !FileManager.default.fileExists(atPath: startedFlag.path) && Date() < workerWaitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedFlag.path))

        let queuedOutcome = await worker.callWithOutcome(["op": "embed", "text": "trailing-query"], timeout: 0.2)
        XCTAssertNil(queuedOutcome.response)
        XCTAssertEqual(queuedOutcome.failureCode, "queue_timeout")
        XCTAssertTrue(queuedOutcome.error is CopilotError)
        XCTAssertEqual(worker.failureCode, "unknown", "Queue-wait timeout must not overwrite active worker diagnosticCode")

        try Data("release".utf8).write(to: releaseFlag)
        let activeOutcome = await activeTask.value
        XCTAssertNotNil(activeOutcome.response)
        XCTAssertNil(activeOutcome.failureCode)
        XCTAssertEqual(worker.failureCode, "unknown")
    }

    func testHungGPUEmbeddingTriggersCPUFailover() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hung-gpu-failover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modeLog = dir.appendingPathComponent("modes.log")
        let script = dir.appendingPathComponent("hung-gpu-worker")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        mode = sys.argv[1]
        with open(\(String(reflecting: modeLog.path)), "a") as f:
            f.write(mode + "\\n")
        sys.stdout.write('{"ready":true}\\n'); sys.stdout.flush()
        vec = [1.0] + [0.0] * 1023
        for line in sys.stdin:
            req = json.loads(line)
            if mode == "embedding" and req.get("text") == "hang-gpu":
                time.sleep(10)
            sys.stdout.write(json.dumps({"id": req["id"], "vector": vec}) + "\\n"); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let provider = LocalEmbeddingProvider(directory: dir, executable: script, queryTimeout: 0.9, indexingTimeout: 5.0)
        defer { provider.close(initiator: .selfCheck) }

        let vectors = try await provider.embed(["hang-gpu"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors[0].count, 1024)
        XCTAssertEqual(vectors[0][0], 1.0)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding", "embedding-cpu"])
        #endif
    }
}
