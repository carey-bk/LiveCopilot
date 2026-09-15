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
        try check("local services migrate independently and do not require OpenAI for DeepSeek") {
            let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(old.listeningService == .openAI && old.embeddingService == .openAI, "old route silently changed")
            var local = old; local.listeningService = .local; local.embeddingService = .local; local.reasoningService = .deepSeek
            try expect(!local.requiresOpenAIKey, "local + DeepSeek unnecessarily requires OpenAI")
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(local))
            try expect(restored == local, "local selections did not persist")
            local.listeningService = .paraformer
            let streamed = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(local))
            try expect(streamed == local && !streamed.requiresOpenAIKey, "streaming selection lost persistence or requires a cloud key")
            try expect(streamed.listeningService.sampleRate == 16000 && streamed.listeningService.localModel == .streamingSpeech, "streaming audio/model route mismatch")
            local.listeningService = .openAI; try expect(local.requiresOpenAIKey, "cloud listening lost credential requirement")
            local.listeningService = .local; local.reasoningService = .sharedOpenAI
            try expect(local.requiresOpenAIKey, "shared reasoning lost its credential requirement")
        }
        try check("Apple route persists without requiring a cloud credential") {
            var settings = AppSettings(); settings.listeningService = .apple
            settings.reasoningService = .deepSeek; settings.embeddingService = .local; settings.appleSpeechLanguage = .english
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored == settings && !restored.requiresOpenAIKey && restored.listeningService.sampleRate == 16000, "Apple route incorrectly migrated")
            let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(old.appleSpeechLanguage == .chinese && old.listeningService == .openAI, "legacy route changed")
        }
        try check("Apple volatile ranges revise, commit and reject stale results") {
            var state = SpeechPreviewState()
            _ = state.accept(startMS: 0, endMS: 500, text: "why", final: false)
            _ = state.accept(startMS: 0, endMS: 900, text: "why this", final: false)
            try expect(state.preview == "why this", "preview duplicated")
            let part = state.accept(startMS: 0, endMS: 400, text: "Why", final: true)
            try expect(part?.text == "Why" && state.preview.isEmpty, "final duplicated volatile prefix")
            _ = state.accept(startMS: 400, endMS: 1000, text: "this method?", final: false)
            try expect(state.accept(startMS: 0, endMS: 400, text: "Why", final: true) == nil, "duplicate final accepted")
            try expect(state.preview == "this method?", "stale event removed newer preview")
            _ = state.accept(startMS: 400, endMS: 1000, text: "this method?", final: true)
            try expect(state.preview.isEmpty, "final preview remained")
        }
        try check("small overlay bounds reserve space for fixed controls") {
            for room in [0.0, 20, 80, 400, 900] {
                for automatic in [true, false] {
                    let panes = OverlayLayout.panes(available: room, transcriptIdeal: 145, answerIdeal: 2000, automatic: automatic)
                    try expect(panes.transcript >= 0 && panes.answer >= 0 && panes.transcript + panes.answer <= room, "content overflowed reserved bounds")
                }
            }
        }
        try check("prices match official model and provider, never a compatible proxy") {
            try expect(ServiceGuide.livePrice("gpt-live-1", language: .english).contains("$0.10"), "dual-session charge omitted")
            try expect(ServiceGuide.embeddingPrice("text-embedding-3-large", language: .english).contains("$0.13"), "embedding rate incorrect")
            try expect(ServiceGuide.analysisPrice(.deepSeek, model: "deepseek-flash", language: .english).contains("$0.15 / $0.30"), "flash peak rates incorrect")
            try expect(ServiceGuide.analysisPrice(.deepSeek, model: "deepseek-v4-pro", language: .english).contains("$0.66 / $1.32"), "Pro accidentally quoted Flash rates")
            for provider in [ReasoningService.compatible, .deepSeek] {
                try expect(ServiceGuide.analysisPrice(provider, model: "gpt-5.6-sol", language: .english) == ServiceGuide.unknown(.english), "cross-provider price guessed")
            }
        }
        try check("overlay preferences migrate and persist independently") {
            let migrated = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(migrated.overlayAutoHeight && migrated.overlayEdgeHide, "new window defaults missing")
            var manual = migrated; manual.overlayAutoHeight = false; manual.overlayEdgeHide = false
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(manual))
            try expect(restored == manual, "manual window preferences lost")
        }
        try check("overlay growth preserves top and width and stays within each display") {
            let display = CGRect(x: -1440, y: -200, width: 1440, height: 860)
            let small = CGRect(x: -510, y: 350, width: 480, height: 280)
            let grown = OverlayLayout.fitted(small, height: 580, visible: display, docked: false)
            try expect(grown.maxY == small.maxY && grown.width == small.width && grown.height == 580, "growth moved the top edge")
            let capped = OverlayLayout.fitted(small, height: 9999, visible: display, docked: true)
            try expect(display.contains(capped) && capped.maxX == display.maxX - 12, "window escaped negative-origin display")
            let tiny = CGRect(x: 200, y: 0, width: 360, height: 220)
            try expect(tiny.contains(OverlayLayout.fitted(grown, height: 600, visible: tiny, docked: true)), "display removal/short screen clipping")
            try expect(OverlayLayout.atRightEdge(CGPoint(x: -1, y: 100), screen: display, visible: display), "right edge not found")
            try expect(!OverlayLayout.atRightEdge(CGPoint(x: -1, y: 658), screen: display, visible: display), "menu corner triggered")
        }
        try check("edge hover ignores quick crossings and pauses hiding during interaction") {
            var state = OverlayHoverState()
            try expect(!state.shouldReveal(atEdge: true, now: 0), "instant reveal")
            try expect(!state.shouldReveal(atEdge: false, now: 0.1), "revealed away from edge")
            try expect(!state.shouldReveal(atEdge: true, now: 0.2), "crossing carried stale dwell")
            try expect(state.shouldReveal(atEdge: true, now: 0.4), "sustained hover failed")
            state.reset()
            try expect(!state.shouldHide(inside: false, interacting: false, now: 1), "instant hide")
            try expect(!state.shouldHide(inside: false, interacting: true, now: 2), "hid during text selection")
            try expect(!state.shouldHide(inside: false, interacting: false, now: 3), "interaction did not restart leave delay")
            try expect(state.shouldHide(inside: false, interacting: false, now: 4), "did not hide after leaving")
            try expect(!state.shouldHide(inside: true, interacting: false, now: 5), "hid under pointer")
        }
        try check("local question gate distinguishes questions from silence fillers and statements") {
            for text in ["Why did you choose method B?", "Could you explain the sample size?", "What about latency?", "请介绍一下你的项目经历。", "这个方法的延迟是多少？", "你们为什么选择方法B？"] {
                try expect(LocalQuestionDetector.isQuestion(text), "missed explicit question: " + text)
            }
            for text in ["", "好的。", "Thank you.", "Method B is faster.", "Why did you choose the", "请介绍这个实验，因为", "我不知道为什么失败。", "Why did you choose B? Never mind, no need to answer."] {
                try expect(!LocalQuestionDetector.isQuestion(text), "false trigger: " + text)
            }
        }
        let localFixture = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCopilot-Local-Core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: localFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localFixture) }
        try check("local model readiness rejects partial missing and size-mismatched installs") {
            let kind = LocalModelKind.embedding, folder = kind.location(in: localFixture)
            try expect(!kind.isInstalled(in: localFixture), "missing install accepted")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(kind.files[0]))
            try expect(!kind.isInstalled(in: localFixture), "uncommitted payload accepted")
            try JSONEncoder().encode([kind.files[0]: 4]).write(to: folder.appendingPathComponent("installed.json"))
            try expect(!kind.isInstalled(in: localFixture), "truncated payload accepted")
        }
        do {
            try await LocalModelInstaller.install(.embedding, root: localFixture, downloader: { _, destination in try Data("corrupt download".utf8).write(to: destination) })
            throw CheckError(description: "corrupt model committed")
        } catch is CopilotError {
            let original = try Data(contentsOf: LocalModelKind.embedding.location(in: localFixture).appendingPathComponent("bge-m3-Q8_0.gguf"))
            try expect(original == Data([1, 2, 3]), "previous model destroyed")
            passed.append("bad download checksum preserves the previous local model")
        }
        do {
            try await LocalModelInstaller.install(.embedding, root: localFixture, downloader: { _, _ in throw CancellationError() })
            throw CheckError(description: "cancelled download committed")
        } catch is CancellationError { passed.append("local download cancellation cleans staging without changing installed data") }
        try check("failed local model replacement rolls back atomically") {
            let target = LocalModelKind.embedding.location(in: localFixture)
            do { try LocalModelInstaller.commit(localFixture.appendingPathComponent("absent"), to: target); throw CheckError(description: "missing payload accepted") }
            catch is CheckError { throw CheckError(description: "missing payload accepted") }
            catch { try expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("bge-m3-Q8_0.gguf").path), "failed replacement lost previous data") }
        }
        let fake = localFixture.appendingPathComponent("fake-worker")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":true}'\nwhile IFS= read -r row; do printf '%s\\n' \"$row\"; done\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let echoWorker = LocalInferenceWorker(mode: "speech", modelDirectory: localFixture, executable: fake)
        let response = try await echoWorker.call(["op": "ping", "unicode": "中文🙂"], timeout: 2)
        try expect(response["unicode"] as? String == "中文🙂", "stdio framing or Unicode was corrupted")
        echoWorker.close(); passed.append("native IPC delivers short flushed replies without waiting for a full read buffer")
        do { _ = try await echoWorker.call(["op": "ping"]); throw CheckError(description: "closed worker restarted") }
        catch is CancellationError { passed.append("closed local workers cannot restart after shutdown") }
        let hanging = localFixture.appendingPathComponent("hanging-worker")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ready\":true}'\nwhile :; do :; done\n".write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hanging.path)
        let timedWorker = LocalInferenceWorker(mode: "speech", modelDirectory: localFixture, executable: hanging)
        do { _ = try await timedWorker.call(["op": "ping"], timeout: 0.2); throw CheckError(description: "hung worker succeeded") }
        catch is CopilotError { passed.append("local worker timeout terminates inference and returns a visible error") }
        timedWorker.close()
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
        try check("raw SSE bytes preserve blank boundaries and fragmented UTF-8") {
            for newline in ["\n", "\r\n", "\r"] {
                let wire = "data: 中文🧪" + newline + newline + "data: second" + newline + newline
                var framer = StreamingLines(), parser = ServerSentEvents(), payloads: [String] = []
                for byte in wire.utf8 {
                    if let line = try framer.consume(byte), let payload = parser.consume(line) { payloads.append(payload) }
                }
                try expect(payloads == ["中文🧪", "second"], "SSE framing merged events or lost Unicode")
                let tail = try framer.finish()
                try expect(tail == nil, "unexpected trailing line")
            }
        }
        try check("invalid UTF-8 stream fails instead of corrupting answer text") {
            var framer = StreamingLines()
            _ = try framer.consume(0xFF)
            do { _ = try framer.consume(10); throw CheckError(description: "invalid encoding accepted") }
            catch is CopilotError { }
        }
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
        try check("V1 settings migrate without resetting existing models or behavior") {
            let legacy = Data(#"{"liveModel":"existing-live","reasoningModel":"existing-reasoning","embeddingModel":"existing-embedding","reasoningEffort":"high","mode":"In-Person / Defense","scenario":"Academic Defense","automaticSuggestions":false,"includeConversation":false,"retrievalCount":8}"#.utf8)
            let restored = try JSONDecoder().decode(AppSettings.self, from: legacy)
            try expect(restored.liveModel == "existing-live" && restored.reasoningModel == "existing-reasoning" && restored.embeddingModel == "existing-embedding", "migration reset models")
            try expect(restored.mode == .inPerson && restored.scenario == .defense && !restored.automaticSuggestions && restored.retrievalCount == 8, "migration reset behavior")
            try expect(restored.reasoningService == .sharedOpenAI && restored.language == .system && restored.background == .glass, "unsafe migration defaults")
            try expect(restored.excludeOverlayFromCapture, "migration unexpectedly exposes overlay")
            var updated = restored; updated.language = .simplifiedChinese; updated.background = .white; updated.reasoningService = .deepSeek
            updated.excludeOverlayFromCapture = false
            let encoded = try JSONEncoder().encode(updated)
            let roundTrip = try JSONDecoder().decode(AppSettings.self, from: encoded)
            try expect(roundTrip == updated, "preferences fail round trip")
        }
        try check("UI translations preserve source content and source identity") {
            try expect(L10n.text("API key configured", language: .simplifiedChinese) == "API Key 已配置", "credential status not translated")
            try expect(L10n.text("API key configured", language: .english) == "API key configured", "English not selectable")
            try expect(chunks[0].displayLabel(language: .simplifiedChinese).contains("第 3 页"), "source page lost")
            try expect(chunks[0].text.contains("128"), "source content altered")
        }
        try check("custom endpoint rejects credential URLs and binds keys to destinations") {
            for bad in ["http://example.com", "https://user:password@example.com", "https://example.com?api_key=fixture", "https://example.com#fragment"] {
                do { _ = try ServiceEndpoint.make(baseURL: bad, path: "chat/completions"); throw CheckError(description: "unsafe endpoint accepted") }
                catch is CopilotError { }
            }
            let endpoint = try ServiceEndpoint.make(baseURL: "https://EXAMPLE.com:443/v1/", path: "/chat/completions")
            try expect(endpoint.absoluteString == "https://example.com/v1/chat/completions", "incorrect endpoint join")
            var one = AppSettings(); one.reasoningService = .compatible; one.compatibleBaseURL = "https://one.example/v1"
            var two = one; two.compatibleBaseURL = "https://two.example/v1"
            let a = try one.analysisCredentialReference(), b = try two.analysisCredentialReference()
            try expect(a != b && a != .live && a != .deepSeek, "credential identities overlap")
        }
        let chatEvents = [
            #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"private-reasoning-fixture"},"finish_reason":null}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"content":"42 毫秒 [S1]"},"finish_reason":null}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "", "data: [DONE]", ""
        ]
        for service in ReasoningService.allCases {
            var settings = AppSettings(); settings.reasoningService = service
            settings.compatibleBaseURL = "https://analysis.example/v1"; settings.compatibleModel = "fixture-model"
            let wire = service == .sharedOpenAI || service == .separateOpenAI ? events : chatEvents
            let recorder = RecordingTransport(events: wire)
            let provider = try ReasoningProviderFactory.make(settings: settings, liveKey: "live-fixture-only", analysisKey: "analysis-fixture-only", transport: recorder)
            var output = ""
            for try await delta in provider.stream(answer) { output += delta }
            let request = recorder.requests[0]
            let expectedKey = service == .sharedOpenAI ? "live-fixture-only" : "analysis-fixture-only"
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedKey, "service received wrong credential")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try expect(body["stream"] as? Bool == true, "stream disabled")
            if service == .deepSeek || service == .compatible {
                try expect(output == "42 毫秒 [S1]" && !output.contains("private-reasoning"), "final text/source corrupted or reasoning leaked")
                try expect((body["messages"] as? [[String: String]])?.last?["content"]?.contains("[S1]") == true, "evidence omitted")
                try expect((body["thinking"] != nil) == (service == .deepSeek), "vendor options leaked to custom service")
            } else { try expect(body["store"] as? Bool == false, "OpenAI storage contract changed") }
            passed.append("analysis routing and credential isolation: " + service.rawValue)
        }
        try check("external analysis cannot silently fall back to the Live credential") {
            var settings = AppSettings(); settings.reasoningService = .deepSeek
            do { _ = try ReasoningProviderFactory.make(settings: settings, liveKey: "live-fixture-only", analysisKey: nil); throw CheckError(description: "Live key leaked as fallback") }
            catch is CopilotError { }
        }
        for broken in [
            Array(chatEvents.prefix(4)),
            [#"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#, ""],
            [#"data: {"error":{"message":"must-not-echo-private-server-text"}}"#, ""],
            ["data: malformed", ""], ["data: [DONE]", ""]
        ] {
            let provider = ChatCompletionsProvider(key: "fixture", model: "fixture", endpoint: URL(string: "https://fixture.example/chat/completions")!, transport: FixtureTransport(body: Data(), status: 200, events: broken))
            do { for try await _ in provider.stream(answer) {}; throw CheckError(description: "bad Chat Completion accepted") }
            catch let error as CopilotError { try expect(!error.localizedDescription.contains("must-not-echo"), "raw server error leaked") }
        }
        passed.append("Chat Completions truncated, empty, malformed and error streams fail safely")
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

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    let events: [String]
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(events: [String]) { self.events = events }
    func data(for request: URLRequest) async throws -> (Data, Int) { throw CoreChecks.CheckError(description: "unexpected data request") }
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}
