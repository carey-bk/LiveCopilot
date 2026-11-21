import Foundation
import AppKit
import XCTest
@testable import LiveCopilot

final class ModelHealthTests: XCTestCase {
    func testRetiredIndexMigrationAndCleanup() async throws {
        struct Fixed: EmbeddingProvider {
            let model: String
            let dimensions: Int
            func embed(_ texts: [String]) async throws -> [[Float]] {
                texts.map { _ in Array(repeating: Float(0.1), count: dimensions) }
            }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let db = try KnowledgeIndex(directory: root.appendingPathComponent("knowledge"))
        let models = root.appendingPathComponent("Models"), laya = root.appendingPathComponent("Laya")
        let weights = models.appendingPathComponent("bge-m3-q8-v1")
        let venv = laya.appendingPathComponent("installs/fixture/venv")
        for dir in [weights, venv] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(at: laya.appendingPathComponent("current"), withDestinationURL: venv.deletingLastPathComponent())
        let file = root.appendingPathComponent("minutes.txt")
        try "Arctic migration fixture".write(to: file, atomically: true, encoding: .utf8)
        let old = try await db.importDocument(file, provider: Fixed(model: "local:bge-m3:legacy", dimensions: 1024))
        let original = URL(fileURLWithPath: old.localPath)
        let contents = try Data(contentsOf: original)
        try fm.removeItem(at: original)
        let arctic = Fixed(model: LocalModelKind.embeddingIdentity, dimensions: 768)
        let missing = try await db.migrateToArctic(provider: arctic, includeRemote: true)
        XCTAssertEqual(missing, [old.name])
        do { _ = try await db.removeRetiredModels(models: models, laya: laya); XCTFail("Cleaned before migration") }
        catch { XCTAssertTrue(fm.fileExists(atPath: weights.path)); XCTAssertTrue(fm.fileExists(atPath: venv.path)) }
        let previous = try await db.documents()
        XCTAssertEqual(previous, [old])
        try contents.write(to: original)
        let remaining = try await db.migrateToArctic(provider: arctic, includeRemote: true)
        XCTAssertTrue(remaining.isEmpty)
        let records = try await db.documents(), chunks = try await db.allChunks()
        XCTAssertEqual(records.first?.id,old.id); XCTAssertEqual(records.first?.importedAt,old.importedAt)
        XCTAssertEqual(records.first?.embeddingModel,arctic.model); XCTAssertEqual(records.first?.localPath,old.localPath)
        XCTAssertEqual(chunks.first?.vector.count,768)
        let removed = try await db.removeRetiredModels(models: models, laya: laya)
        XCTAssertEqual(removed,2); XCTAssertFalse(fm.fileExists(atPath: weights.path)); XCTAssertFalse(fm.fileExists(atPath: venv.path))
        XCTAssertEqual(try Data(contentsOf: original),contents)
    }
    func testBundledArcticSelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let health = try await LocalModelSelfCheck.run(.embedding, root: root)
        XCTAssertEqual(health.stage, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
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
        vec = [1.0] + [0.0] * 767
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
        XCTAssertEqual(vectors[0].count, 768)
        XCTAssertEqual(vectors[0][0], 1.0)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding-cpu"])
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
                vec = [0.5] + [0.0] * 767
            elif text == "quick-query":
                vec = [0.25] + [0.0] * 767
            else:
                vec = [1.0] + [0.0] * 767
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
        XCTAssertEqual(indexed[0].count, 768)
        XCTAssertEqual(indexed[0][0], 0.5)

        let quick = try await provider.embed(["quick-query"])
        XCTAssertEqual(quick.count, 1)
        XCTAssertEqual(quick[0].count, 768)
        XCTAssertEqual(quick[0][0], 0.25)
        XCTAssertTrue(provider.isPrepared)

        let modes = try String(contentsOf: modeLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(modes.count, 1, "Queue-wait timeout must not respawn or fail over the healthy worker: \(modes)")
        #if arch(x86_64)
        XCTAssertEqual(modes, ["embedding-cpu"])
        #else
        XCTAssertEqual(modes, ["embedding-cpu"])
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

}
