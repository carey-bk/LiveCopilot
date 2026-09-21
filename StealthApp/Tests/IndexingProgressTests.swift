import XCTest
import Foundation
@testable import LiveCopilot

private actor ProgressSamples {
    var values: [Double] = []
    var completeWasPersisted = false
    func record(_ value: Double, persisted: Bool) {
        values.append(value)
        if value == 1 { completeWasPersisted = persisted }
    }
}
final class IndexingProgressTests: XCTestCase {
    func testLocalSmallDocumentReportsEveryChunkBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try """
        #!/usr/bin/python3
        import sys, json
        print(json.dumps({"ready": True}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"id": request["id"], "vector": [1.0] * 1024}), flush=True)
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let provider = LocalEmbeddingProvider(directory: root, executable: worker)
        defer { provider.close() }
        let input = root.appendingPathComponent("small.txt")
        try String(repeating: "A synthetic paragraph about indexing progress and retrieval.\n\n", count: 100)
            .write(to: input, atomically: true, encoding: .utf8)
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let samples = ProgressSamples()
        let document = try await index.importDocument(input, provider: provider) { id, value in
            let persisted = (try? await index.documents().contains { $0.id == id && $0.status == "Ready" }) ?? false
            await samples.record(value, persisted: persisted)
        }
        let values = await samples.values
        let persisted = await samples.completeWasPersisted
        XCTAssertGreaterThan(document.chunkCount, 1)
        XCTAssertLessThan(document.chunkCount, 24)
        XCTAssertEqual(values.count, document.chunkCount + 2)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 0.95 })
        XCTAssertTrue(persisted)
    }

    func testProgressAdvancesByBatchAndCompletesOnlyAfterCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("progress.txt")
        try String(repeating: "A synthetic paragraph about indexing progress, retrieval and embedding batches.\n\n", count: 2000)
            .write(to: input, atomically: true, encoding: .utf8)
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let samples = ProgressSamples()
        let document = try await index.importDocument(input, provider: MockEmbeddingProvider()) { id, value in
            let persisted = (try? await index.documents().contains { $0.id == id && $0.status == "Ready" }) ?? false
            await samples.record(value, persisted: persisted)
        }
        let values = await samples.values
        let persisted = await samples.completeWasPersisted
        XCTAssertGreaterThan(document.chunkCount, 24)
        XCTAssertGreaterThan(values.count, 3)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(persisted)
        let failed = ProgressSamples()
        do {
            _ = try await index.reindex(document, provider: FailAfterFirstBatch()) { _, value in
                await failed.record(value, persisted: false)
            }
            XCTFail("Expected embedding failure")
        } catch { }
        let failedValues = await failed.values
        XCTAssertTrue(failedValues.contains { $0 > 0 })
        XCTAssertFalse(failedValues.contains(1), "A failed re-index must not display a completion checkmark")
        let retained = try await index.documents().first { $0.id == document.id }
        XCTAssertEqual(retained?.status, "Ready (re-index failed)")
        XCTAssertEqual(retained?.chunkCount, document.chunkCount)
    }
}
