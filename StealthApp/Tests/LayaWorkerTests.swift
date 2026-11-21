import XCTest
import Foundation
@testable import LiveCopilot

final class LayaWorkerTests: XCTestCase {
    @MainActor func testBundledCoreMLSelectionIgnoresLegacyPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LayaRuntimeManager(root: root, preference: .e8)
        XCTAssertEqual(manager.backend, .w8)
        XCTAssertTrue(manager.isInstalled)
        XCTAssertEqual(manager.engineTitle, "Core ML · W8")
        try await manager.prepareAndWait()
        XCTAssertTrue(manager.isReady)
        manager.stop()
        XCTAssertTrue(manager.isInstalled)
    }

    func testNativeTimeoutAndCancellationReapStoppedProcess() async throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let directory = resources.appendingPathComponent("OfflineModels/laya")
        let worker = LayaWorker(native: directory, resources: resources.appendingPathComponent("LayaRuntime"), precision: "w8")
        defer { worker.stop() }
        for cancel in [false, true] {
            try await worker.prepare()
            let ps = Process(), output = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,ppid=,command="]
            ps.standardOutput = output
            try ps.run()
            let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            let children = listing.split(separator: "\n").compactMap { row -> pid_t? in
                let fields = row.split(separator: " ", maxSplits: 2)
                guard fields.count == 3, Int32(fields[1]) == getpid(),
                      fields[2].contains("/livecopilot-laya "), fields[2].contains(directory.path)
                else { return nil }
                return Int32(fields[0])
            }
            XCTAssertEqual(children.count, 1)
            let pid = try XCTUnwrap(children.first)
            XCTAssertEqual(getpgid(pid), pid)
            XCTAssertEqual(kill(pid, SIGSTOP), 0)
            let pending = Task { try await worker.predict(text: "Synthetic?", context: "", timeout: cancel ? 10 : 0.2) }
            if cancel {
                try await Task.sleep(nanoseconds: 50_000_000)
                pending.cancel()
            }
            do { _ = try await pending.value; XCTFail("Unexpected score") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch LayaRuntimeError.timedOut { XCTAssertFalse(cancel) }
            for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testNativeHelperRejectsCorruptWeightsBeforeReady() async throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("LayaRuntime")
        let pins = try LayaNativeAssets.pins(resources, .w8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in pins.files.keys {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("damaged".utf8).write(to: target)
        }
        try FileManager.default.copyItem(at: resources.appendingPathComponent("native-w8.json"), to: root.appendingPathComponent("receipt.json"))
        let worker = LayaWorker(native: root, resources: resources, precision: "w8")
        defer { worker.stop() }
        do { try await worker.prepare(); XCTFail("Unexpected ready") }
        catch LayaRuntimeError.unavailable {}
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
        for response in ["{'id':r['id'],'score':float('nan'),'input_tokens':10}",
                         "{'id':r['id'],'score':float('inf'),'input_tokens':10}",
                         "{'id':r['id'],'score':True,'input_tokens':10}",
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
