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

    func testGB18030AndBOMTextDocumentsDecodeAndIndexAccurately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))

        let pureChinese = "这是一个纯中文的知识库测试文档，包含核心指标与架构说明。"
        let pureURL = root.appendingPathComponent("gb18030-pure.txt")
        try XCTUnwrap(pureChinese.data(using: gb18030)).write(to: pureURL)
        let pureSections = try DocumentParser.extract(pureURL)
        XCTAssertEqual(pureSections.map(\.text), [pureChinese])
        let pureDoc = try await index.importDocument(pureURL, provider: MockEmbeddingProvider())
        XCTAssertEqual(pureDoc.status, "Ready")
        XCTAssertGreaterThan(pureDoc.chunkCount, 0)
        let pureHits = try await index.lexical("知识库")
        XCTAssertFalse(pureHits.isEmpty)

        let mixedMarkdown = "# 系统设计说明\r\n- Latency P99: 42ms\t吞吐量 10,000 QPS\r\n结论：支持GB18030与ASCII混排，标点（《》【】—…）无乱码。\n"
        let mixedURL = root.appendingPathComponent("gb18030-mixed.md")
        try XCTUnwrap(mixedMarkdown.data(using: gb18030)).write(to: mixedURL)
        let mixedSections = try DocumentParser.extract(mixedURL)
        XCTAssertEqual(mixedSections.map(\.text), [mixedMarkdown])
        let mixedDoc = try await index.importDocument(mixedURL, provider: MockEmbeddingProvider())
        XCTAssertEqual(mixedDoc.status, "Ready")
        XCTAssertGreaterThan(mixedDoc.chunkCount, 0)
        let mixedHits = try await index.lexical("吞吐量")
        XCTAssertFalse(mixedHits.isEmpty)

        let bomSample = "UTF BOM 文档测试: alpha-123\n第二行。"
        let utf8BOMURL = root.appendingPathComponent("utf8-bom.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(bomSample.utf8)).write(to: utf8BOMURL)
        let utf8Decoded = try DocumentParser.extract(utf8BOMURL)
        XCTAssertEqual(utf8Decoded.map(\.text), [bomSample])
        XCTAssertNotEqual(utf8Decoded.first?.text.unicodeScalars.first, "\u{FEFF}")

        let utf16LEURL = root.appendingPathComponent("utf16-le-bom.txt")
        try (Data([0xFF, 0xFE]) + XCTUnwrap(bomSample.data(using: .utf16LittleEndian))).write(to: utf16LEURL)
        XCTAssertEqual(try DocumentParser.extract(utf16LEURL).map(\.text), [bomSample])

        let utf16BEURL = root.appendingPathComponent("utf16-be-bom.txt")
        try (Data([0xFE, 0xFF]) + XCTUnwrap(bomSample.data(using: .utf16BigEndian))).write(to: utf16BEURL)
        XCTAssertEqual(try DocumentParser.extract(utf16BEURL).map(\.text), [bomSample])
    }

    func testStrictTextDecoderRejectsBinaryCorruptAndUnsupportedEncodings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )

        func expectRejected(_ data: Data, name: String) throws {
            XCTAssertThrowsError(try DocumentParser.decodeText(data), "\(name) should be rejected by decodeText")
            let url = root.appendingPathComponent(name + ".txt")
            try data.write(to: url)
            XCTAssertThrowsError(try DocumentParser.extract(url), "\(name) should be rejected by extract")
        }

        // Binary headers with NULs and control bytes
        try expectRejected(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]), name: "png-binary")
        try expectRejected(Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00]), name: "zip-binary")

        // Non-BOM UTF-16 containing NUL bytes
        try expectRejected(XCTUnwrap("Hello World\n".data(using: .utf16LittleEndian)), name: "nobom-utf16le")
        try expectRejected(XCTUnwrap("Hello World\n".data(using: .utf16BigEndian)), name: "nobom-utf16be")

        // Invalid ISO-8859-1 and truncated GB18030 sequences
        try expectRejected(XCTUnwrap("Café résumé\n".data(using: .isoLatin1)), name: "latin1-invalid")
        let truncatedGB = try XCTUnwrap("中文测试".data(using: gb18030)).dropLast(1)
        try expectRejected(Data(truncatedGB), name: "truncated-gb18030")

        // UTF-8 BOM followed by invalid UTF-8 (must not fall back to GB18030)
        try expectRejected(Data([0xEF, 0xBB, 0xBF]) + XCTUnwrap("中文".data(using: gb18030)), name: "utf8bom-with-gb18030")

        // UTF-16 BOM with odd byte count or unpaired surrogates
        try expectRejected(Data([0xFF, 0xFE, 0x41, 0x00, 0x42]), name: "utf16le-odd")
        try expectRejected(Data([0xFE, 0xFF, 0x00, 0x41, 0x42]), name: "utf16be-odd")
        try expectRejected(Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]), name: "utf16le-unpaired-surrogate")
        try expectRejected(Data([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41]), name: "utf16be-unpaired-surrogate")

        // UTF-32 LE BOM (FF FE 00 00) and BE BOM (00 00 FE FF) must not be misread as UTF-16
        try expectRejected(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]), name: "utf32le-bom")
        try expectRejected(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41]), name: "utf32be-bom")
    }

    func testReplaceChunksFailurePreservesCommittedMetadataOnImportAndReindex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))

        // 1. Initial import fails during replaceChunks due to inconsistent dimensions across batches (> 24 chunks).
        let multiBatchURL = try fixture("inconsistent-import", paragraphs: 1200, root: root)
        let expectedChunks = DocumentChunker.chunk(try DocumentParser.extract(multiBatchURL), documentID: "check", name: "check").count
        XCTAssertGreaterThan(expectedChunks, 24, "Fixture must span at least two embedding batches")
        do {
            _ = try await index.importDocument(multiBatchURL, provider: MismatchedBatchDimensionEmbedding(model: "bad-model-v1"))
            XCTFail("Expected replaceChunks to reject mismatched vector dimensions across batches")
        } catch is CopilotError { }
        let docsAfterFail = try await index.documents()
        let importedAfterFail = try XCTUnwrap(docsAfterFail.first)
        XCTAssertEqual(importedAfterFail.status, "Failed")
        XCTAssertEqual(importedAfterFail.chunkCount, 0, "Failed initial import must persist chunkCount 0, not uncommitted chunk count")
        XCTAssertNotNil(importedAfterFail.error)
        let chunksAfterFail = try await index.allChunks()
        XCTAssertTrue(chunksAfterFail.isEmpty)

        // 2. Successful import with old model, then re-index with a NEW model and modified chunk count fails in replaceChunks.
        let docURL = try fixture("reindex-rollback", paragraphs: 80, root: root)
        let originalDoc = try await index.importDocument(docURL, provider: MockEmbeddingProvider())
        XCTAssertEqual(originalDoc.status, "Ready")
        XCTAssertEqual(originalDoc.embeddingModel, "mock-embedding-v1")
        XCTAssertGreaterThan(originalDoc.chunkCount, 0)
        let originalChunks = try await index.allChunks().filter { $0.documentID == originalDoc.id }
        XCTAssertEqual(originalChunks.count, originalDoc.chunkCount)

        // Expand the stored original so re-index produces >24 chunks (different chunkCount AND multi-batch mismatch).
        try String(repeating: "Expanded synthetic evidence about document indexing and retrieval.\n\n", count: 1200)
            .write(to: URL(fileURLWithPath: originalDoc.localPath), atomically: true, encoding: .utf8)
        let expandedChunks = DocumentChunker.chunk(
            try DocumentParser.extract(URL(fileURLWithPath: originalDoc.localPath)),
            documentID: originalDoc.id,
            name: originalDoc.name
        ).count
        XCTAssertGreaterThan(expandedChunks, 24)
        XCTAssertNotEqual(expandedChunks, originalDoc.chunkCount)

        do {
            _ = try await index.reindex(originalDoc, provider: MismatchedBatchDimensionEmbedding(model: "new-embedding-v2"))
            XCTFail("Expected re-index replaceChunks to fail on inconsistent batch dimensions")
        } catch is CopilotError { }

        let docsAfterReindexFail = try await index.documents()
        let persistedDoc = try XCTUnwrap(docsAfterReindexFail.first { $0.id == originalDoc.id })
        XCTAssertEqual(persistedDoc.status, "Ready (re-index failed)")
        XCTAssertEqual(persistedDoc.chunkCount, originalDoc.chunkCount, "Failed re-index must keep the previously committed chunkCount")
        XCTAssertEqual(persistedDoc.embeddingModel, originalDoc.embeddingModel, "Failed re-index must keep the previously committed embeddingModel")
        XCTAssertNotNil(persistedDoc.error)
        let retainedChunks = try await index.allChunks().filter { $0.documentID == originalDoc.id }
        XCTAssertEqual(retainedChunks, originalChunks)
        let retainedHits = try await index.lexical("Synthetic evidence")
        XCTAssertFalse(retainedHits.isEmpty)
    }

    func testOversizedTextExceedingChunkLimitRejectsCleanlyWithoutOrphanFilesOrRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let indexDir = root.appendingPathComponent("index")
        let index = try KnowledgeIndex(directory: indexDir)
        let bigURL = root.appendingPathComponent("oversized.txt")
        // ~6.6 MB repeated text: well under the 50 MB file size cap, but produces > 4,000 chunks.
        let sentence = "Synthetic knowledge base sentence with clear punctuation for chunking limits. "
        try String(repeating: sentence, count: 85_000).write(to: bigURL, atomically: true, encoding: .utf8)

        // Verify DocumentChunker stops early at maxChunks + 1 without materializing all chunks.
        let sections = try DocumentParser.extract(bigURL)
        let capped = DocumentChunker.chunk(sections, documentID: "probe", name: "oversized.txt", maxChunks: 4000)
        XCTAssertEqual(capped.count, 4001)

        do {
            _ = try await index.importDocument(bigURL, provider: MockEmbeddingProvider())
            XCTFail("Expected importDocument to reject documents exceeding 4,000 chunks")
        } catch let error as CopilotError {
            XCTAssertEqual(error.localizedDescription, "Document exceeds the V1 limit of 4,000 chunks; split it into smaller documents.")
        }

        let documents = try await index.documents()
        XCTAssertTrue(documents.isEmpty, "Rejected oversized document must not leave a Failed row in documents")
        let originals = indexDir.appendingPathComponent("originals")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "Rejected oversized document must not leave orphan files in originals/")
    }

    func testDocxZipBombAndEntryCountGuardsRejectWithoutDecompressing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func appendLE16(_ data: inout Data, _ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func appendLE32(_ data: inout Data, _ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        func appendLE64(_ data: inout Data, _ value: UInt64) {
            appendLE32(&data, UInt32(value & 0xFFFF_FFFF))
            appendLE32(&data, UInt32((value >> 32) & 0xFFFF_FFFF))
        }
        func makeSyntheticZip(entries: [(name: String, uncompressed: UInt64, useZip64Extra: Bool)], overrideEntryCount: UInt16? = nil) -> Data {
            var archive = Data()
            var centralDirectory = Data()
            for entry in entries {
                let nameBytes = Data(entry.name.utf8)
                let localOffset = UInt32(archive.count)
                // Local file header (30 bytes + name)
                appendLE32(&archive, 0x0403_4B50)
                appendLE16(&archive, 20) // version needed
                appendLE16(&archive, 0)  // flags
                appendLE16(&archive, 8)  // deflate
                appendLE16(&archive, 0); appendLE16(&archive, 0) // mod time/date
                appendLE32(&archive, 0)  // crc32
                appendLE32(&archive, 0)  // compressed size
                appendLE32(&archive, entry.useZip64Extra ? 0xFFFF_FFFF : UInt32(min(entry.uncompressed, UInt64(UInt32.max))))
                appendLE16(&archive, UInt16(nameBytes.count))
                appendLE16(&archive, 0)  // extra length
                archive.append(nameBytes)

                // Central directory file header (46 bytes + name + optional zip64 extra)
                var extra = Data()
                if entry.useZip64Extra {
                    appendLE16(&extra, 0x0001) // ZIP64 extra header ID
                    appendLE16(&extra, 8)      // payload size (original size only)
                    appendLE64(&extra, entry.uncompressed)
                }
                appendLE32(&centralDirectory, 0x0201_4B50)
                appendLE16(&centralDirectory, 20) // version made by
                appendLE16(&centralDirectory, 20) // version needed
                appendLE16(&centralDirectory, 0)  // flags
                appendLE16(&centralDirectory, 8)  // deflate
                appendLE16(&centralDirectory, 0); appendLE16(&centralDirectory, 0) // mod time/date
                appendLE32(&centralDirectory, 0)  // crc32
                appendLE32(&centralDirectory, 0)  // compressed size
                appendLE32(&centralDirectory, entry.useZip64Extra ? 0xFFFF_FFFF : UInt32(min(entry.uncompressed, UInt64(UInt32.max))))
                appendLE16(&centralDirectory, UInt16(nameBytes.count))
                appendLE16(&centralDirectory, UInt16(extra.count))
                appendLE16(&centralDirectory, 0)  // comment length
                appendLE16(&centralDirectory, 0)  // disk number
                appendLE16(&centralDirectory, 0)  // internal attrs
                appendLE32(&centralDirectory, 0)  // external attrs
                appendLE32(&centralDirectory, localOffset)
                centralDirectory.append(nameBytes)
                centralDirectory.append(extra)
            }
            let cdOffset = UInt32(archive.count)
            archive.append(centralDirectory)
            let count = overrideEntryCount ?? UInt16(entries.count)
            // End of Central Directory (22 bytes)
            appendLE32(&archive, 0x0605_4B50)
            appendLE16(&archive, 0); appendLE16(&archive, 0) // disk numbers
            appendLE16(&archive, count)
            appendLE16(&archive, count)
            appendLE32(&archive, UInt32(centralDirectory.count))
            appendLE32(&archive, cdOffset)
            appendLE16(&archive, 0) // comment length
            return archive
        }

        // Valid small ZIP passes the archive guard without false positives.
        let safeZipURL = root.appendingPathComponent("safe.docx")
        try makeSyntheticZip(entries: [("word/document.xml", 4_096, false)]).write(to: safeZipURL)
        XCTAssertNoThrow(try DocumentParser.validateDocxArchive(safeZipURL))

        // 1. Single entry declaring >100 MB uncompressed while only ~140 bytes on disk.
        let singleBombURL = root.appendingPathComponent("single-bomb.docx")
        try makeSyntheticZip(entries: [("word/document.xml", 150_000_000, false)]).write(to: singleBombURL)
        XCTAssertThrowsError(try DocumentParser.extract(singleBombURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Document is too large to extract safely"))
        }

        // 2. Cumulative total across multiple entries exceeding 100 MB.
        let multiBombURL = root.appendingPathComponent("multi-bomb.docx")
        try makeSyntheticZip(entries: [
            ("word/document.xml", 60_000_000, false),
            ("word/styles.xml", 60_000_000, false)
        ]).write(to: multiBombURL)
        XCTAssertThrowsError(try DocumentParser.extract(multiBombURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Document is too large to extract safely"))
        }

        // 3. ZIP64 extra field declaring >100 MB uncompressed.
        let zip64BombURL = root.appendingPathComponent("zip64-bomb.docx")
        try makeSyntheticZip(entries: [("word/document.xml", 250_000_000, true)]).write(to: zip64BombURL)
        XCTAssertThrowsError(try DocumentParser.extract(zip64BombURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Document is too large to extract safely"))
        }

        // 4. Entry count exceeding the 5,000-entry limit.
        let tooManyEntriesURL = root.appendingPathComponent("many-entries.docx")
        try makeSyntheticZip(entries: [("word/document.xml", 100, false)], overrideEntryCount: 5_001).write(to: tooManyEntriesURL)
        XCTAssertThrowsError(try DocumentParser.extract(tooManyEntriesURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Document is too large to extract safely"))
        }

        // 5. Non-ZIP file with .docx extension fails with a clear error.
        let corruptURL = root.appendingPathComponent("not-a-zip.docx")
        try Data("this is not a valid zip archive".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try DocumentParser.extract(corruptURL)) { error in
            XCTAssertTrue(error is CopilotError)
        }

        // Importing a zip-bomb through KnowledgeIndex leaves zero DB rows and zero orphan files.
        let indexDir = root.appendingPathComponent("index")
        let index = try KnowledgeIndex(directory: indexDir)
        do {
            _ = try await index.importDocument(singleBombURL, provider: MockEmbeddingProvider())
            XCTFail("Expected zip-bomb docx import to fail")
        } catch let error as CopilotError {
            XCTAssertTrue(error.localizedDescription.contains("Document is too large to extract safely"))
        }
        let docsAfterBomb = try await index.documents()
        XCTAssertTrue(docsAfterBomb.isEmpty)
        let originals = (try? FileManager.default.contentsOfDirectory(atPath: indexDir.appendingPathComponent("originals").path)) ?? []
        XCTAssertTrue(originals.isEmpty)
    }

    func testRollingWindowChunkerMatchesReferenceImplementationAndRespectsMaxChunks() {
        func referenceChunk(_ sections: [DocumentSection], maxCharacters: Int, overlap: Int) -> [(text: String, page: Int?)] {
            let size = max(128, maxCharacters), ov = max(0, min(overlap, size / 3))
            let maxScalars = size * 2
            var out: [(String, Int?)] = []
            for section in sections {
                let chars = Array(section.text.replacingOccurrences(of: "\r\n", with: "\n"))
                var scalars = [0]
                scalars.reserveCapacity(chars.count + 1)
                for ch in chars { scalars.append(scalars[scalars.count - 1] + ch.unicodeScalars.count) }
                var start = 0
                while start < chars.count {
                    var end = min(start + size, chars.count)
                    if scalars[end] - scalars[start] > maxScalars {
                        var low = start + 1, high = end
                        while low < high {
                            let mid = (low + high + 1) / 2
                            if scalars[mid] - scalars[start] <= maxScalars { low = mid } else { high = mid - 1 }
                        }
                        end = low
                    }
                    if end < chars.count {
                        let lower = start + (end - start) / 2
                        if let boundary = (lower..<end).last(where: { "\n。.!?！？ ".contains(chars[$0]) }) { end = boundary + 1 }
                    }
                    let text = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append((text, section.page)) }
                    if end == chars.count { break }
                    start = max(start + 1, end - min(ov, (end - start) / 3))
                }
            }
            return out
        }

        let sections: [DocumentSection] = [
            .init(text: String(repeating: "Line one with CRLF.\r\nLine two with punctuation! Question? ", count: 90), page: 1),
            .init(text: "   \r\n  \t  \n  ", page: 2),
            .init(text: String(repeating: "中文段落测试，支持全角标点。还有感叹号！和问号？以及表情🧪👨‍👩‍👧‍👦\r\n", count: 80), page: 3),
            .init(text: String(repeating: "a\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}", count: 900) + "\r\nNormal tail.", page: 4),
            .init(text: "x" + String(repeating: "\u{301}", count: 400) + " after oversized cluster.", page: 5)
        ]

        for (maxChars, overlap) in [(128, 0), (256, 30), (1600, 180), (128, 999)] {
            let expected = referenceChunk(sections, maxCharacters: maxChars, overlap: overlap)
            let actual = DocumentChunker.chunk(sections, documentID: "doc", name: "parity.txt",
                                               maxCharacters: maxChars, overlap: overlap)
            XCTAssertEqual(actual.map(\.text), expected.map(\.text), "Text mismatch for (\(maxChars), \(overlap))")
            XCTAssertEqual(actual.map(\.page), expected.map(\.page), "Page mismatch for (\(maxChars), \(overlap))")
            XCTAssertEqual(actual.map(\.ordinal), Array(actual.indices))

            if expected.count > 5 {
                let capped = DocumentChunker.chunk(sections, documentID: "doc", name: "parity.txt",
                                                   maxCharacters: maxChars, overlap: overlap, maxChunks: 5)
                XCTAssertEqual(capped.count, 6)
                XCTAssertEqual(capped.prefix(5).map(\.text), expected.prefix(5).map(\.text))
            }
        }
    }

    func testOffActorExtractionDoesNotBlockConcurrentKnowledgeIndexReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let indexDir = root.appendingPathComponent("index")
        let index = try KnowledgeIndex(directory: indexDir)
        let existingURL = try fixture("existing", paragraphs: 5, root: root)
        let existingDoc = try await index.importDocument(existingURL, provider: MockEmbeddingProvider())

        let bigURL = root.appendingPathComponent("concurrent-oversized.txt")
        try String(repeating: "Concurrent off-actor extraction verification sentence with punctuation. ", count: 95_000)
            .write(to: bigURL, atomically: true, encoding: .utf8)

        let importTask = Task {
            try await index.importDocument(bigURL, provider: MockEmbeddingProvider())
        }

        // Concurrent actor reads should stay responsive and return the committed document while extraction runs off-actor.
        for _ in 0..<5 {
            let docs = try await index.documents()
            XCTAssertEqual(docs.map(\.id), [existingDoc.id])
            let hits = try await index.lexical("Synthetic evidence")
            XCTAssertFalse(hits.isEmpty)
            await Task.yield()
        }

        do {
            _ = try await importTask.value
            XCTFail("Expected oversized concurrent import to be rejected")
        } catch let error as CopilotError {
            XCTAssertEqual(error.localizedDescription, "Document exceeds the V1 limit of 4,000 chunks; split it into smaller documents.")
        }

        let finalDocs = try await index.documents()
        XCTAssertEqual(finalDocs.map(\.id), [existingDoc.id])
        let originals = try FileManager.default.contentsOfDirectory(atPath: indexDir.appendingPathComponent("originals").path)
        XCTAssertEqual(originals, [existingDoc.id])
    }

    func testAmbiguousLatin1TextIsRejectedInAutomaticModePreviewedAndImportableWithExplicitEncoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Latin-1 "élève": Foundation round-trips [E9 6C E8 76 65] under GB18030 as "閘鑦e".
        let eleveData = Data([0xE9, 0x6C, 0xE8, 0x76, 0x65])
        XCTAssertThrowsError(try DocumentParser.decodeText(eleveData)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ambiguous"))
        }
        XCTAssertThrowsError(try DocumentParser.decodeText(eleveData, encoding: .automatic)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ambiguous"))
        }

        // Preview reports ambiguity with both ISO-8859-1 and GB18030 candidates.
        let preview = DocumentParser.previewText(eleveData)
        XCTAssertTrue(preview.ambiguous)
        XCTAssertNil(preview.detectedEncoding)
        XCTAssertEqual(preview.sampleText, "")
        XCTAssertEqual(preview.candidates.first { $0.encoding == .isoLatin1 }?.sample, "élève")
        XCTAssertEqual(preview.candidates.first { $0.encoding == .gb18030 }?.sample, "閘鑦e")

        // Explicit encoding choices decode deterministically (including rare GBK-only GB18030).
        XCTAssertEqual(try DocumentParser.decodeText(eleveData, encoding: .isoLatin1), "élève")
        XCTAssertEqual(try DocumentParser.decodeText(eleveData, encoding: .gb18030), "閘鑦e")

        // Additional Latin-1 words that previously round-tripped through GB18030 as mojibake.
        for word in ["Müller", "François", "naïve", "Straße", "résumés"] {
            let latin1Bytes = try XCTUnwrap(word.data(using: .isoLatin1))
            XCTAssertThrowsError(try DocumentParser.decodeText(latin1Bytes), "\(word) must fail in automatic mode")
            XCTAssertEqual(try DocumentParser.decodeText(latin1Bytes, encoding: .isoLatin1), word)
        }

        // End-to-end KnowledgeIndex import rejects automatic mode and succeeds with explicit .isoLatin1.
        let eleveURL = root.appendingPathComponent("eleve.txt")
        try eleveData.write(to: eleveURL)
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        do {
            _ = try await index.importDocument(eleveURL, provider: MockEmbeddingProvider())
            XCTFail("Expected ambiguous Latin-1 file to be rejected in automatic mode")
        } catch let error as CopilotError {
            XCTAssertTrue(error.localizedDescription.contains("ambiguous"))
        }
        let docsAfterReject = try await index.documents()
        XCTAssertTrue(docsAfterReject.isEmpty)

        let imported = try await index.importDocument(eleveURL, textEncoding: .isoLatin1, provider: MockEmbeddingProvider())
        XCTAssertEqual(imported.status, "Ready")
        XCTAssertEqual(imported.chunkCount, 1)
        let chunks = try await index.allChunks()
        XCTAssertEqual(chunks.map(\.text), ["élève"])
    }

    func testAutomaticGB18030AndExplicitEncodingsStillDecodeAndRejectBinary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))

        // Normal Chinese GB18030 text imports cleanly in automatic mode and previews unambiguously.
        let normalChinese = "中文知识库内容：系统延迟分析与架构设计（GB18030编码）。"
        let normalData = try XCTUnwrap(normalChinese.data(using: gb18030))
        let normalPreview = DocumentParser.previewText(normalData, maxCharacters: 12)
        XCTAssertFalse(normalPreview.ambiguous)
        XCTAssertEqual(normalPreview.detectedEncoding, .gb18030)
        XCTAssertEqual(normalPreview.sampleText, String(normalChinese.prefix(12)))
        XCTAssertEqual(try DocumentParser.decodeText(normalData), normalChinese)

        let normalURL = root.appendingPathComponent("normal-gb18030.txt")
        try normalData.write(to: normalURL)
        let normalDoc = try await index.importDocument(normalURL, provider: MockEmbeddingProvider())
        XCTAssertEqual(normalDoc.status, "Ready")
        let normalHits = try await index.lexical("延迟分析")
        XCTAssertFalse(normalHits.isEmpty)

        // Mixed Chinese GB18030 + ASCII/English + occasional rare GBK char imports cleanly in automatic mode.
        let mixedGB = "项目架构与延迟分析：方案B响应时间为120ms，包含镕和〇等扩展字符。"
        let mixedData = try XCTUnwrap(mixedGB.data(using: gb18030))
        XCTAssertEqual(try DocumentParser.decodeText(mixedData), mixedGB)
        let mixedURL = root.appendingPathComponent("mixed-gb18030.txt")
        try mixedData.write(to: mixedURL)
        let mixedDoc = try await index.importDocument(mixedURL, provider: MockEmbeddingProvider())
        XCTAssertEqual(mixedDoc.status, "Ready")

        // Explicit UTF-8, UTF-16 BOM, and binary rejection still behave strictly.
        let utf8Sample = "Explicit UTF-8 文本"
        let utf8Data = Data(utf8Sample.utf8)
        XCTAssertEqual(try DocumentParser.decodeText(utf8Data, encoding: .utf8), utf8Sample)
        let utf8Preview = DocumentParser.previewText(utf8Data)
        XCTAssertEqual(utf8Preview.detectedEncoding, .utf8)
        XCTAssertFalse(utf8Preview.ambiguous)

        let utf16LEData = Data([0xFF, 0xFE]) + (try XCTUnwrap(utf8Sample.data(using: .utf16LittleEndian)))
        XCTAssertEqual(try DocumentParser.decodeText(utf16LEData, encoding: .utf16), utf8Sample)
        let utf16Preview = DocumentParser.previewText(utf16LEData)
        XCTAssertEqual(utf16Preview.detectedEncoding, .utf16)
        XCTAssertFalse(utf16Preview.ambiguous)

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        for choice in DocumentParser.TextEncodingChoice.allCases {
            XCTAssertThrowsError(try DocumentParser.decodeText(pngHeader, encoding: choice), "PNG binary must fail under \(choice)")
        }
        let binaryPreview = DocumentParser.previewText(pngHeader)
        XCTAssertNil(binaryPreview.detectedEncoding)
        XCTAssertFalse(binaryPreview.ambiguous)
        XCTAssertTrue(binaryPreview.candidates.isEmpty)
    }
}

/// Returns 4-dim vectors on batch 1 and 8-dim vectors on subsequent batches so `replaceChunks` rejects the batch.
private actor MismatchedBatchDimensionEmbedding: EmbeddingProvider {
    nonisolated let model: String
    private var batch = 0
    init(model: String) { self.model = model }
    func embed(_ texts: [String]) async throws -> [[Float]] { try await embed(texts, progress: { _ in }) }
    func embed(_ texts: [String], progress: @Sendable (Int) async -> Void) async throws -> [[Float]] {
        batch += 1
        await progress(texts.count)
        let dimensions = batch == 1 ? 4 : 8
        return texts.map { _ in [Float](repeating: 1, count: dimensions) }
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
