import XCTest
import Foundation
@testable import LiveCopilot

final class LayaWorkerTests: XCTestCase {
    func testBootstrapAcceptsPinnedPythonWithNumericSize() throws {
        let digest = String(repeating: "a", count: 64)
        let data = try JSONSerialization.data(withJSONObject: ["python": [
            "url": "https://example.com/python.tar.gz", "sha256": digest, "size": 24_981_445
        ]])
        let pin = try LayaBootstrap.pythonPin(from: data)
        XCTAssertEqual(pin.url.absoluteString, "https://example.com/python.tar.gz")
        XCTAssertEqual(pin.digest, digest)
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("LayaRuntime/pins.json")
        XCTAssertEqual(try LayaBootstrap.downloadFileTotal(from: Data(contentsOf: resources)), 32)
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
