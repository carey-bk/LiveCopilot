import XCTest
import Foundation
@testable import LiveCopilot

final class LayaWorkerTests: XCTestCase {
    private func worker(_ body: String) -> LayaWorker {
        LayaWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-B", "-c", body])
    }
    private let ready = "import sys,json,time,os\nprint(json.dumps({'ready':True,'protocol':1}),flush=True)\n"
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
