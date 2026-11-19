import XCTest
import Foundation
@testable import LiveCopilot

final class LayaWorkerTests: XCTestCase {
    func testPinnedInitialDownloadSizeAndIncompleteManifest() throws {
        let pins = try XCTUnwrap(LayaDownloadSize.load())
        XCTAssertEqual(pins.totalBytes, 766_807_229)
        let complete = Data(#"{"python":{"size":10},"source":{"size":20},"wheels":[{"size":30}],"model":[{"size":40},{"size":50}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LayaDownloadSize.self, from: complete).totalBytes, 150)
        let missing = Data(#"{"python":{"size":10},"source":{"size":20},"wheels":[{}],"model":[{"size":40}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LayaDownloadSize.self, from: missing))
        let invalid = LayaDownloadSize(python: .init(size: 10), source: .init(size: 20), wheels: [.init(size: 0)], model: [.init(size: 40)])
        XCTAssertNil(invalid.totalBytes)
    }

    @MainActor func testReadyStateTracksUnexpectedWorkerExitAndIntentionalStop() async throws {
        #if arch(arm64)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("laya-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current"), resources = root.appendingPathComponent("resources")
        let required = ["source/laya_mlx/agent.py", "model/model.safetensors", "model/rl_agent_config.json", "model/encoder/config.json", "model/tokenizer/tokenizer.json"]
        var hashes: [String: String] = [:]
        for name in required {
            let file = current.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file); hashes[name] = String(repeating: "a", count: 64)
        }
        try FileManager.default.createDirectory(at: current.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: current.appendingPathComponent("venv/bin/python3"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": "fixture"]).write(to: resources.appendingPathComponent("pins.json"))
        try JSONSerialization.data(withJSONObject: ["schema": 1, "pin_id": "fixture", "files": hashes]).write(to: current.appendingPathComponent("receipt.json"))
        try Data((ready + "time.sleep(0.3)\nos._exit(7)\n").utf8).write(to: resources.appendingPathComponent("worker.py"))
        let manager = LayaRuntimeManager(root: root, resources: resources)
        XCTAssertEqual(manager.state, .installed)
        manager.prepareInstalledOnce(enabled: false)
        XCTAssertEqual(manager.state, .installed)
        manager.prepareInstalledOnce(enabled: true)
        XCTAssertEqual(manager.state, .loading)
        manager.prepareInstalledOnce(enabled: true)
        XCTAssertEqual(manager.diagnosticEvents.filter { $0.contains("load_and_verify_started") }.count, 1)
        try await manager.prepareAndWait()
        XCTAssertEqual(manager.state, .ready)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(manager.state, .failed)
        manager.prepareInstalledOnce(enabled: true)
        XCTAssertEqual(manager.state, .failed, "No automatic retry loop after failure")
        try await manager.prepareAndWait()
        manager.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(manager.state, .installed, "Intentional stop must not become a crash")
        manager.prepareInstalledOnce(enabled: true)
        XCTAssertEqual(manager.state, .installed, "Returning to setup must not undo an intentional stop")
        manager.checkModel()
        XCTAssertEqual(manager.state, .loading)
        manager.cancel()
        XCTAssertEqual(manager.state, .installed)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(manager.state, .installed, "Cancelled check must not publish a stale ready or failed state")
        try await manager.prepareAndWait()
        XCTAssertTrue(manager.isReady)
        manager.removeDownloadedFiles()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(manager.diagnosticEvents.isEmpty, "Removing the diagnostics UI must not remove runtime logs")
        #endif
    }

    func testBootstrapAcceptsPinnedPythonWithNumericSize() throws {
        let digest = String(repeating: "a", count: 64)
        let data = try JSONSerialization.data(withJSONObject: ["python": [
            "url": "https://example.com/python.tar.gz", "sha256": digest, "size": 24_981_445
        ]])
        let pin = try LayaBootstrap.pythonPin(from: data)
        XCTAssertEqual(pin.url.absoluteString, "https://example.com/python.tar.gz")
        XCTAssertEqual(pin.digest, digest)
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("LayaRuntime/pins.json")
        XCTAssertEqual(try LayaBootstrap.downloadFileTotal(from: Data(contentsOf: resources)), 30)
    }

    func testInstallerFileCountTelemetryAndValidation() async throws {
        let counted = expectation(description: "file count")
        let body = "import json\nprint(json.dumps({'file_index':9,'file_total':32}),flush=True)\nprint(json.dumps({'ready':True,'protocol':1}),flush=True)\n"
        let process = LayaWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", body], file: { index, total in
            XCTAssertEqual(index, 9)
            XCTAssertEqual(total, 32)
            counted.fulfill()
        })
        defer { process.stop() }
        try await process.prepare()
        await fulfillment(of: [counted], timeout: 1)
        let bad = worker("import json\nprint(json.dumps({'file_index':33,'file_total':32}),flush=True)\n")
        defer { bad.stop() }
        do { try await bad.prepare(); XCTFail("Invalid file count accepted") }
        catch LayaRuntimeError.invalidResponse { }
    }

    private func worker(_ body: String) -> LayaWorker {
        LayaWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-B", "-c", body])
    }
    private let ready = "import sys,json,time,os\nprint(json.dumps({'ready':True,'protocol':1}),flush=True)\n"
    func testInstallerTransferTelemetryAndInvalidProgress() async throws {
        let received = expectation(description: "transfer")
        let body = "import json\nprint(json.dumps({'transfer':'model · 50% · 2 MB/s','fraction':0.5}),flush=True)\nprint(json.dumps({'ready':True,'protocol':1}),flush=True)\n"
        let process = LayaWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", body], transfer: { value, detail in
            XCTAssertEqual(value, 0.5)
            XCTAssertTrue(detail.contains("2 MB/s"))
            received.fulfill()
        })
        defer { process.stop() }
        try await process.prepare()
        await fulfillment(of: [received], timeout: 1)
        let bad = worker("import json\nprint(json.dumps({'transfer':'bad','fraction':2}),flush=True)\n")
        defer { bad.stop() }
        do { try await bad.prepare(); XCTFail("Invalid transfer accepted") }
        catch LayaRuntimeError.invalidResponse { }
    }

    func testTimeoutKillsWorkerAndDoesNotHang() async throws {
        let process = worker(ready + "time.sleep(30)\n")
        defer { process.stop() }
        try await process.prepare()
        let start = Date()
        do { _ = try await process.predict(text: "Synthetic question?", context: "", timeout: 0.15); XCTFail("Expected timeout") }
        catch LayaRuntimeError.timedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCrashDoesNotProduceScore() async throws {
        let process = worker(ready + "sys.stdin.readline()\nos._exit(7)\n")
        defer { process.stop() }
        try await process.prepare()
        do { _ = try await process.predict(text: "Synthetic question?", context: ""); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is LayaRuntimeError) }
    }
    func testInvalidScoresAndMismatchedIDsAreRejected() async throws {
        for response in ["{'id':r['id'],'score':True,'input_tokens':10}",
                         "{'id':r['id'],'score':1.5,'input_tokens':10}",
                         "{'id':r['id'],'score':0.9,'input_tokens':2048}",
                         "{'id':'wrong','score':0.9,'input_tokens':10}"] {
            let process = worker(ready + "r=json.loads(sys.stdin.readline())\nprint(json.dumps(" + response + "),flush=True)\ntime.sleep(5)\n")
            defer { process.stop() }
            try await process.prepare()
            do { _ = try await process.predict(text: "Synthetic question?", context: ""); XCTFail("Invalid response accepted") }
            catch LayaRuntimeError.invalidResponse { }
        }
    }
    func testCancellationAndRestartInvalidateOldRequest() async throws {
        let process = worker(ready + "r=json.loads(sys.stdin.readline())\ntime.sleep(30)\n")
        defer { process.stop() }
        try await process.prepare()
        let pending = Task { try await process.predict(text: "Synthetic question?", context: "") }
        try await Task.sleep(nanoseconds: 50_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled result accepted") }
        catch is CancellationError { }
        try await process.prepare()
        process.stop()
    }
}
