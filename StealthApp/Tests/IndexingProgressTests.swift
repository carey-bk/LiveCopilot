import XCTest
import Foundation
import Combine
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
    @MainActor private func coordinator(provider: any EmbeddingProvider, root: URL) -> AppCoordinator {
        let suite = "LiveCopilot-Indexing-Tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                              mockEmbedding: provider, mockKnowledgeDirectory: root.appendingPathComponent("index"))
    }

    private func fixture(_ name: String, paragraphs: Int, root: URL) throws -> URL {
        let url = root.appendingPathComponent(name + ".txt")
        try String(repeating: "Synthetic evidence about document indexing and retrieval.\n\n", count: paragraphs)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor func testBatchProgressIsLiveDocumentWeightedAndExcludesExistingLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ControlledProgressEmbedding()
        let app = coordinator(provider: provider, root: root)
        defer { Task { await app.shutdown() } }
        let index = try XCTUnwrap(app.knowledge)
        _ = try await index.importDocument(fixture("existing", paragraphs: 1, root: root), provider: MockEmbeddingProvider())
        let first = try fixture("first", paragraphs: 40, root: root)
        let second = try fixture("second", paragraphs: 100, root: root)
        let secondChunks = DocumentChunker.chunk(try DocumentParser.extract(second), documentID: "test", name: "test").count
        XCTAssertGreaterThan(secondChunks, 1)
        let advanced = expectation(description: "second document updates UI before embedding returns")
        let finished = expectation(description: "batch finished")
        var samples: [Double] = []
        let values = app.$indexingProgress.sink { samples.append($0) }
        let progress = app.$indexingProgress.filter { $0 > 0.5 && $0 < 1 }.prefix(1).sink { _ in advanced.fulfill() }
        let completion = app.$isIndexing.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        app.importDocuments([first, second])
        await fulfillment(of: [advanced], timeout: 5)
        XCTAssertTrue(app.isIndexing)
        XCTAssertEqual(app.indexingDocumentCount, 2)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 1)
        XCTAssertEqual(app.indexingProgress, (1 + 0.95 / Double(secondChunks)) / 2, accuracy: 0.000001)
        XCTAssertEqual(app.knowledgeDocuments.count, 3, "Existing library must not affect this batch's denominator")
        await provider.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertEqual(app.indexingProgress, 1)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 2)
        XCTAssertTrue(app.indexingSucceeded)
        values.cancel(); progress.cancel(); completion.cancel()

        let reindexed = expectation(description: "whole library reindexed")
        let reindexCompletion = app.$isIndexing.dropFirst().filter { !$0 }.prefix(1).sink { _ in reindexed.fulfill() }
        app.reindexAll()
        XCTAssertEqual(app.indexingDocumentCount, 3)
        XCTAssertEqual(app.indexingProgress, 0)
        await fulfillment(of: [reindexed], timeout: 5)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 3)
        XCTAssertEqual(app.indexingProgress, 1)
        reindexCompletion.cancel()
    }

    @MainActor func testFailedBatchNeverCompletesAndRetryStartsANewSingleDocumentBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = coordinator(provider: ControlledProgressEmbedding(failSecondCall: true), root: root)
        defer { Task { await app.shutdown() } }
        let files = try ["first", "failed", "not-started"].map { try fixture($0, paragraphs: 60, root: root) }
        let stopped = expectation(description: "batch stops after failure")
        let completion = app.$isIndexing.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        app.importDocuments(files)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(app.indexingDocumentCount, 3)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 1)
        XCTAssertGreaterThan(app.indexingProgress, 1.0 / 3)
        XCTAssertLessThan(app.indexingProgress, 2.0 / 3)
        XCTAssertFalse(app.indexingSucceeded)
        XCTAssertEqual(app.knowledgeDocuments.count, 2)
        let failed = try XCTUnwrap(app.knowledgeDocuments.first { $0.status == "Failed" })
        completion.cancel()

        let retried = expectation(description: "failed document reindexed")
        let retryCompletion = app.$isIndexing.dropFirst().filter { !$0 }.prefix(1).sink { _ in retried.fulfill() }
        app.reindex(failed)
        XCTAssertEqual(app.indexingProgress, 0)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 0)
        XCTAssertEqual(app.indexingDocumentCount, 1)
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertTrue(app.indexingSucceeded)
        XCTAssertEqual(app.indexingProgress, 1)
        XCTAssertEqual(app.indexingCompletedDocumentCount, 1)
        retryCompletion.cancel()
    }

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

/// Holds an unfinished embedding request open so the test can inspect published UI state.
private actor ControlledProgressEmbedding: EmbeddingProvider {
    nonisolated let model = "test-progress"
    let failSecondCall: Bool
    private var calls = 0
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(failSecondCall: Bool = false) { self.failSecondCall = failSecondCall }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func embed(_ texts: [String]) async throws -> [[Float]] { try await embed(texts, progress: { _ in }) }
    func embed(_ texts: [String], progress: @Sendable (Int) async -> Void) async throws -> [[Float]] {
        calls += 1
        for index in texts.indices {
            await progress(index + 1)
            if calls == 2 && index == 0 {
                if failSecondCall { throw CopilotError.message("Synthetic embedding failure") }
                if !released { await withCheckedContinuation { waiting = $0 } }
            }
        }
        return texts.map { _ in [1, 0] }
    }
}
