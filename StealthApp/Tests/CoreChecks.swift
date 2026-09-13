import Foundation
#if XCODE_TESTS
@testable import LiveCopilot
#endif

enum CoreChecks {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError(description: message) }
    }
    static func run() async throws -> [String] {
        var passed: [String] = []
        func check(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
        let fixture = "Experiment A has 128 samples. Method B latency is 42 ms. Revenue in 2025 was 18.7 million."
        let chunks = DocumentChunker.chunk([.init(text: String(repeating: fixture + "\n", count: 40), page: 3)], documentID: "doc", name: "study.pdf", maxCharacters: 256, overlap: 30)
        try check("chunk bounds and page/source metadata") {
            try expect(chunks.count > 10, "long document must be chunked")
            try expect(chunks.allSatisfy { $0.text.count <= 256 && $0.page == 3 && $0.documentID == "doc" && $0.documentName == "study.pdf" }, "source metadata lost")
            try expect(chunks.map(\.ordinal) == Array(chunks.indices), "ordinals are not consecutive")
        }
        try check("Unicode chunks preserve Chinese text and emoji") {
            let text = String(repeating: "样本量为128，延迟42毫秒。🧪", count: 40)
            let values = DocumentChunker.chunk([.init(text: text, page: nil)], documentID: "c", name: "中文.txt", maxCharacters: 128, overlap: 0)
            try expect(values.map(\.text).joined() == text, "chunk boundaries corrupted Unicode")
        }
        try check("empty input and overlap safety") {
            try expect(DocumentChunker.chunk([.init(text: "  \n", page: nil)], documentID: "e", name: "e").isEmpty, "empty chunk created")
            try expect(!DocumentChunker.chunk([.init(text: fixture, page: nil)], documentID: "e", name: "e", maxCharacters: 0, overlap: 900).isEmpty, "unsafe chunk settings")
        }
        try check("cosine similarity handles zero mismatched and nonfinite vectors") {
            try expect(abs(VectorMath.cosine([1, 0], [1, 0]) - 1) < 0.0001, "identity cosine")
            try expect(VectorMath.cosine([1, 0], [0, 1]) == 0, "orthogonal cosine")
            try expect(VectorMath.cosine([0, 0], [1, 0]) == 0, "zero vector")
            try expect(VectorMath.cosine([1], [1, 0]) == 0, "dimension mismatch")
            try expect(VectorMath.cosine([.nan], [1]) == 0, "NaN propagated")
        }
        try check("hybrid fusion rewards agreement and deduplicates") {
            let result = VectorMath.fuse(lexical: [chunks[0], chunks[1]], semantic: [chunks[1], chunks[2]], limit: 6)
            try expect(result.first?.id == chunks[1].id && result.count == 3, "hybrid ranking wrong")
        }
        try check("follow-up retrieval retains previous entities and exact numbers") {
            let q = RetrievalQuery.formulate(question: "  What about latency?\n", context: "You: We used method B with 128 samples.", previousQuestion: "Why choose B over A?")
            try expect(q.question == "What about latency?", "normalization")
            try expect(q.semantic.contains("method B") && q.semantic.contains("B over A") && q.lexical.contains("128"), "follow-up lost context")
        }
        try check("structured suggestion tolerant streaming and source IDs") {
            let text = "## Core answer\nUse B.\n\n## Evidence\n42 ms [S1] and 128 samples [S2]. Invalid [S99]"
            try expect(SuggestionParser.sections(text).count == 2, "section parsing")
            try expect(SuggestionParser.sections("Plain partial answer").first?.content == "Plain partial answer", "plain output lost")
            try expect(SuggestionParser.citedIndices(text, sourceCount: 2) == [1, 2], "unknown citation accepted")
        }
        let now = Date()
        func f(_ text: String, id: String, speaker: Speaker = .them, start: Int = 0, at: Date = now) -> TranscriptFragment {
            .init(id: id, speaker: speaker, text: text, startMS: start, endMS: start + 500, receivedAt: at)
        }
        try check("fragments cannot trigger assistance; incomplete question is held") {
            var state = ConversationState()
            _ = state.append(f("Why did you choose the", id: "a"))
            try expect(state.phase == .forming, "fragment triggered work")
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == nil, "incomplete sentence accepted")
            _ = state.append(f(" larger sample size?", id: "b", start: 500))
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == "Why did you choose the larger sample size?", "completed question lost")
            try expect(!state.append(f("duplicate event", id: "b")), "repeated event appended")
        }
        try check("duplicate suppression and genuine follow-up") {
            var state = ConversationState(); _ = state.append(f("Why choose method B?", id: "a"))
            let q = state.candidate(speaker: .them, now: now, cooldown: 0)!
            state.begin(q, speaker: .them, now: now); state.finish(success: true, question: q)
            try expect(state.candidate(speaker: .them, now: now.addingTimeInterval(10), cooldown: 0) == nil, "duplicate trigger")
            _ = state.append(f("What about latency?", id: "b", start: 2500))
            try expect(state.candidate(speaker: .them, now: now.addingTimeInterval(10), cooldown: 0) == "What about latency?", "follow-up missed")
            try expect(state.phase == .followUp, "follow-up state")
        }
        try check("already answered remote question and force fallback") {
            var state = ConversationState(); _ = state.append(f("What is the sample size?", id: "q"))
            _ = state.append(f("128 samples.", id: "a", speaker: .you, at: now.addingTimeInterval(1)))
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0) == nil && state.phase == .answered, "answered question repeated")
            try expect(state.candidate(speaker: .them, now: now, cooldown: 0, force: true) != nil, "manual override blocked")
        }
        try check("failed question may retry and Room has no false You identity") {
            var state = ConversationState(); _ = state.append(f("Why not method A?", id: "r", speaker: .room))
            let q = state.candidate(speaker: .room, now: now, cooldown: 0)!
            state.begin(q, speaker: .room, now: now); state.finish(success: false, question: q)
            try expect(state.candidate(speaker: .room, now: now.addingTimeInterval(1), cooldown: 7) != nil, "failure blocked retry")
        }
        try check("official Live session startup and no obsolete fields") {
            let body = LiveProtocol.start(model: "gpt-live-1", speaker: .room, scenario: .defense, context: "Prior topic")
            let session = body["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            try expect(body["type"] as? String == "session.start", "wrong startup")
            try expect(LiveProtocol.endpoint.path == "/v1/live/sessions" && LiveProtocol.endpoint.query == nil, "old endpoint")
            try expect(audio["format"] != nil && audio["input"] == nil && session["output_modalities"] == nil, "Realtime fields leaked")
            try expect((session["delegation"] as? [String: String])?["type"] == "client", "wrong delegation")
        }
        try check("Live delegation uses opaque ID and not invented question text") {
            let event = LiveProtocol.parse(["type": "session.delegation.created", "offset_ms": 1500, "delegation": ["id": "opaque_X", "target": "client"]], speaker: .them)
            if case .delegation(let id, let ms) = event { try expect(id == "opaque_X" && ms == 1500, "delegation fields") }
            else { throw CheckError(description: "delegation not parsed") }
            try expect(LiveProtocol.parse(["type": "session.output_audio.delta", "delta": "x"], speaker: .them) == nil, "output audio used")
        }
        try check("SSE multiline data and heartbeat handling") {
            var sse = ServerSentEvents()
            try expect(sse.consume(": ping") == nil, "heartbeat emitted")
            _ = sse.consume("data: first"); _ = sse.consume("data: second")
            try expect(sse.consume("") == "first\nsecond", "SSE multiline")
        }
        try check("HTTP failure messages do not include secrets") {
            for code in [401, 403, 429, 500, 400] {
                do { try OpenAIHTTP.check(code); throw CheckError(description: "HTTP failure accepted") }
                catch is CopilotError { }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("experiment.txt")
        try (fixture + "\n样本量128，延迟42毫秒。").write(to: input, atomically: true, encoding: .utf8)
        let index = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let doc = try await index.importDocument(input, provider: MockEmbeddingProvider())
        try expect(doc.status == "Ready" && doc.chunkCount > 0, "indexing failed"); passed.append("document import and embedded local persistence")
        let lexical = try await index.lexical("42 128 latency")
        try expect(lexical.first?.documentID == doc.id, "lexical retrieval failed"); passed.append("SQLite FTS5 BM25 retrieval")
        let chinese = try await index.lexical("样本量")
        try expect(!chinese.isEmpty, "CJK retrieval failed"); passed.append("CJK lexical segmentation")
        let quote = try await index.lexical("\" OR * (NEAR) DROP TABLE chunks;")
        _ = quote; passed.append("FTS user query escaping")
        let persisted = try KnowledgeIndex(directory: root.appendingPathComponent("index"))
        let restored = try await persisted.allChunks()
        try expect(restored.count == doc.chunkCount && restored[0].embeddingModel == "mock-embedding-v1", "reopened index lost vectors"); passed.append("index reopens with source metadata and vectors")
        let query = RetrievalQuery.formulate(question: "latency 42", context: "")
        let v = try await MockEmbeddingProvider().embed([query.semantic])[0]
        let hybrid = try await index.retrieve(query: query, vector: v, model: "mock-embedding-v1", limit: 6)
        try expect(!hybrid.isEmpty, "hybrid failed"); passed.append("local hybrid retrieval end to end")
        let wrong = try await index.retrieve(query: .formulate(question: "zzzzunrelated", context: ""), vector: v, model: "different-model", limit: 6)
        try expect(wrong.isEmpty, "incompatible model vectors used"); passed.append("embedding model mismatch exclusion")
        do { _ = try await index.reindex(doc, provider: FailingEmbedding()); throw CheckError(description: "failed embedding accepted") }
        catch is CopilotError { }
        let retained = try await index.allChunks()
        try expect(retained == restored, "failed re-index destroyed old index"); passed.append("failed re-index preserves previous usable index")
        let newDoc = try await index.reindex(doc, provider: MockEmbeddingProvider())
        let indexed = try await index.allChunks()
        try expect(indexed.count == newDoc.chunkCount, "re-index duplicated chunks"); passed.append("successful re-index atomically replaces chunks")
        try await index.delete(doc.id)
        let empty = try await index.allChunks(); let emptyLex = try await index.lexical("latency")
        try expect(empty.isEmpty && emptyLex.isEmpty, "deletion left chunks or FTS rows"); passed.append("delete removes originals vectors metadata and FTS")
        // Provider tests exercise production request encoding/decoding and streamed error paths with no network.
        let transport = FixtureTransport(body: Data(#"{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}"#.utf8), status: 200, events: [])
        let embeddings = try await OpenAIEmbeddingProvider(key: "test-only", model: "fixture", transport: transport).embed(["first", "second"])
        try expect(embeddings == [[1, 0], [0, 1]], "provider didn't reorder indexed vectors"); passed.append("embedding provider parses ordered batches")
        let answer = AnswerRequest(query: query, conversation: "", scenario: .meeting, sources: hybrid)
        let events = ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"Core answer\"}", "", "data: {\"type\":\"response.completed\"}", ""]
        var text = ""
        for try await delta in OpenAIReasoningProvider(key: "test-only", model: "fixture", transport: FixtureTransport(body: Data(), status: 200, events: events)).stream(answer) { text += delta }
        try expect(text == "Core answer", "stream failed"); passed.append("Responses streams useful text before completion")
        do {
            for try await _ in OpenAIReasoningProvider(key: "test-only", model: "fixture", transport: FixtureTransport(body: Data(), status: 200, events: Array(events.prefix(2)))).stream(answer) { }
            throw CheckError(description: "truncated stream accepted")
        } catch is CopilotError { }
        passed.append("truncated reasoning stream fails visibly")
        try check("reasoning evidence instructions and scenario differences") {
            try expect(answer.input.contains("[S1]") && answer.instructions.contains("untrusted"), "source/prompt contract lost")
            try expect(ScenarioProfile.defense.instructions != ScenarioProfile.interview.instructions, "profiles identical")
        }
        try check("Live append byte budget preserves Unicode boundaries") {
            let original = String(repeating: "中文🧪 context ", count: 100)
            let excerpt = OpenAILiveProvider.contextExcerpt(original)
            try expect(excerpt.utf8.count <= 450 && original.hasPrefix(excerpt), "Live context exceeds token-safe budget")
        }
        let gate = GatedEmbedding()
        let importing = Task { try await index.importDocument(input, provider: gate) }
        await gate.waitUntilCalled()
        let pending = try await index.documents()
        guard let pendingDocument = pending.first else { throw CheckError(description: "missing indexing record") }
        try await index.delete(pendingDocument.id)
        await gate.release()
        do { _ = try await importing.value; throw CheckError(description: "deleted document was resurrected") }
        catch is CancellationError { }
        let afterDeletion = try await index.allChunks()
        try expect(afterDeletion.isEmpty, "in-flight delete left vectors")
        passed.append("deletion during suspended embedding cannot resurrect document")
        let large = root.appendingPathComponent("large.txt")
        try String(repeating: fixture + "\n", count: 500).write(to: large, atomically: true, encoding: .utf8)
        do { _ = try await index.importDocument(large, provider: FailAfterFirstBatch()); throw CheckError(description: "partial indexing accepted") }
        catch is CopilotError { }
        let afterFailure = try await index.allChunks(), failedDocs = try await index.documents()
        try expect(afterFailure.isEmpty && failedDocs.first?.status == "Failed", "partial index became searchable")
        passed.append("mid-batch indexing failure leaves retryable metadata and no partial vectors")
        return passed
    }
}
struct FailingEmbedding: EmbeddingProvider {
    let model = "failing"
    func embed(_ texts: [String]) async throws -> [[Float]] { throw CopilotError.message("Mock embedding unavailable") }
}
struct FixtureTransport: HTTPTransport {
    let body: Data
    let status: Int
    let events: [String]
    func data(for request: URLRequest) async throws -> (Data, Int) { (body, status) }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

actor GatedEmbedding: EmbeddingProvider {
    nonisolated let model = "gated"
    private var called = false
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<[[Float]], Error>?
    private var count = 0
    func waitUntilCalled() async {
        if called { return }
        await withCheckedContinuation { entered = $0 }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        count = texts.count; called = true; entered?.resume(); entered = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: Array(repeating: [1, 0], count: count)); pending = nil }
}
actor FailAfterFirstBatch: EmbeddingProvider {
    nonisolated let model = "partial-failure"
    private var calls = 0
    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        if calls > 1 { throw CopilotError.message("Synthetic second batch failure") }
        return Array(repeating: [1, 0], count: texts.count)
    }
}
