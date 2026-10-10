import XCTest
@testable import LiveCopilot

private final class PreparationEmbedding: LocalEmbeddingPreparing, @unchecked Sendable {
    let model = LocalModelKind.embeddingIdentity
    private let lock = NSLock()
    private var ready = false
    private var preparations = 0
    private var requests = 0
    var isPrepared: Bool { lock.withLock { ready } }
    var preparationCount: Int { lock.withLock { preparations } }
    var requestCount: Int { lock.withLock { requests } }
    func prepare() async throws {
        lock.withLock { preparations += 1 }
        try await Task.sleep(nanoseconds: 80_000_000)
        lock.withLock { ready = true }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { requests += 1 }
        return texts.map { _ in [1, 0, 0] }
    }
}

final class RetrievalPreparationTests: XCTestCase {
    @MainActor func testPreparationIsLocalSingleFlightAndDoesNotRunQueries() async throws {
        let suite = "LiveCopilot-Preparation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let provider = PreparationEmbedding()
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
                                 mockEmbedding: provider, mockKnowledgeDirectory: root)
        await app.refreshKnowledge()
        XCTAssertEqual(provider.preparationCount, 0, "Empty libraries must not load a model")
        let index = try XCTUnwrap(app.knowledge)
        let doc = KnowledgeDocument(id: "fixture", name: "Synthetic", importedAt: Date(), localPath: "",
                                    status: "Ready", chunkCount: 1, embeddingModel: provider.model)
        var chunk = try XCTUnwrap(DocumentChunker.chunk([.init(text: "Synthetic method B latency is 42 ms.", page: nil)],
                                                        documentID: doc.id, name: doc.name).first)
        chunk.vector = [1, 0, 0]; chunk.embeddingModel = provider.model
        try await index.replaceChunks([chunk], document: doc)
        app.settings.embeddingService = .openAI
        await app.refreshKnowledge()
        XCTAssertEqual(provider.preparationCount, 0, "Remote mode must never prewarm an embedding request")
        app.settings.embeddingService = .local
        await app.refreshKnowledge(); await app.refreshKnowledge()
        for _ in 0..<100 where !provider.isPrepared { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(provider.isPrepared)
        XCTAssertEqual(provider.preparationCount, 1)
        XCTAssertEqual(provider.requestCount, 0, "Preparation must not retrieve every transcript fragment")
        await app.refreshKnowledge()
        XCTAssertEqual(provider.preparationCount, 1, "Reuse the resident model")
        app.askText("What is the latency of method B?")
        for _ in 0..<100 where app.suggestion.isLoading { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(app.suggestion.error)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertFalse(app.suggestion.sources.isEmpty)
        XCTAssertNotNil(app.suggestion.trace?.milliseconds(.embeddingComplete))
        await app.shutdown()
    }

    @MainActor func testWaitingStateDistinguishesRetrievalFromModelResponse() {
        let store = SuggestionStore()
        store.begin(); store.trace = PipelineTrace()
        XCTAssertEqual(store.waitingMessage, "Retrieving evidence…")
        store.mark(.ragComplete); store.mark(.modelRequest)
        XCTAssertEqual(store.waitingMessage, "Waiting for the model's answer…")
        store.begin()
        XCTAssertEqual(store.waitingMessage, "Retrieving evidence…")
    }
}
