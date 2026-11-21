import Foundation
import SQLite3

/// Serialized local SQLite access. Re-index commits all new chunks atomically, retaining the
/// previous usable index on any embedding/network failure. No file contents enter diagnostics.
actor KnowledgeIndex {
    private var db: OpaquePointer?
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // Per database connection. Keep a rowid-ordered prefix; scan the uncached suffix
    // in the same order so equal cosines keep their original rank at the cutoff.
    private struct DenseCache {
        var chunks: [SourceChunk] = []
        var chargedBytes = 0
        var lastRowID: Int64?
        var complete = false
        var full = false
        var dataVersion: Int64?
    }
    private var denseCache = DenseCache()
    private let denseCacheBytes: Int

    init(directory: URL, denseCacheBytes: Int = ProcessInfo.processInfo.environment["LIVECOPILOT_DISABLE_DENSE_CACHE"] == "1" ? 0 : 64 * 1024 * 1024) throws {
        self.denseCacheBytes = max(0, denseCacheBytes)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("knowledge.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CopilotError.message("Cannot open local knowledge database.")
        }
        sqlite3_busy_timeout(db, 5000)
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, record BLOB NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, terms, tokenize='unicode61');
        UPDATE documents SET record=json_set(CAST(record AS TEXT),'$.status','Failed','$.error','Indexing was interrupted. Re-index this document to retry.') WHERE json_extract(CAST(record AS TEXT),'$.status')='Indexing';
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw CopilotError.message("Cannot initialize SQLite/FTS5 knowledge database.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    deinit { sqlite3_close(db) }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw databaseError() }
        return s
    }
    private func databaseError() -> Error { CopilotError.message("Local knowledge database operation failed. Check disk space and access permissions.") }
    private func bind(_ text: String, at index: Int32, to s: OpaquePointer) {
        sqlite3_bind_text(s, index, text, -1, transient)
    }
    private func bind(_ data: Data, at index: Int32, to s: OpaquePointer) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32($0.count), transient) }
    }
    private func data(_ s: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(s, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, column)))
    }
    private func done(_ s: OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw databaseError() } }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() } }

    func documents() throws -> [KnowledgeDocument] {
        let s = try statement("SELECT record FROM documents"); defer { sqlite3_finalize(s) }
        var documents: [KnowledgeDocument] = []
        let decoder = JSONDecoder()
        var step = sqlite3_step(s)
        while step == SQLITE_ROW {
            documents.append(try decoder.decode(KnowledgeDocument.self, from: data(s, column: 0)))
            step = sqlite3_step(s)
        }
        guard step == SQLITE_DONE else { throw databaseError() }
        return documents.sorted { $0.importedAt > $1.importedAt }
    }
    func saveDocument(_ document: KnowledgeDocument) throws {
        let s = try statement("INSERT INTO documents(id,record) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record")
        defer { sqlite3_finalize(s) }
        bind(document.id, at: 1, to: s); bind(try JSONEncoder().encode(document), at: 2, to: s); try done(s)
    }
    func replaceChunks(_ chunks: [SourceChunk], document: KnowledgeDocument) throws {
        guard !chunks.isEmpty, chunks.allSatisfy({ !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite) && $0.documentID == document.id }),
              Set(chunks.map { $0.vector.count }).count == 1 else { throw CopilotError.message("Invalid embedding response; the previous index was preserved.") }
        try exec("BEGIN IMMEDIATE")
        do {
            try saveDocument(document)
            try removeChunks(document.id)
            for chunk in chunks {
                let s = try statement("INSERT INTO chunks(id,document_id,record) VALUES(?,?,?)")
                defer { sqlite3_finalize(s) }
                bind(chunk.id, at: 1, to: s); bind(chunk.documentID, at: 2, to: s)
                bind(try JSONEncoder().encode(chunk), at: 3, to: s); try done(s)
                let f = try statement("INSERT INTO chunks_fts(chunk_id,terms) VALUES(?,?)")
                defer { sqlite3_finalize(f) }
                bind(chunk.id, at: 1, to: f); bind(LexicalTokenizer.indexedText(chunk.text), at: 2, to: f); try done(f)
            }
            try exec("COMMIT")
            denseCache = DenseCache()
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func removeChunks(_ documentID: String) throws {
        let f = try statement("DELETE FROM chunks_fts WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id=?)")
        defer { sqlite3_finalize(f) }; bind(documentID, at: 1, to: f); try done(f)
        let s = try statement("DELETE FROM chunks WHERE document_id=?")
        defer { sqlite3_finalize(s) }; bind(documentID, at: 1, to: s); try done(s)
    }
    func delete(_ id: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try removeChunks(id)
            let s = try statement("DELETE FROM documents WHERE id=?")
            defer { sqlite3_finalize(s) }; bind(id, at: 1, to: s); try done(s)
            try exec("COMMIT")
            denseCache = DenseCache()
        } catch { try? exec("ROLLBACK"); throw error }
        let folder = directory.appendingPathComponent("originals/\(id)")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func allChunks() throws -> [SourceChunk] {
        let s = try statement("SELECT record FROM chunks"); defer { sqlite3_finalize(s) }
        var chunks: [SourceChunk] = []
        let decoder = JSONDecoder()
        var step = sqlite3_step(s)
        while step == SQLITE_ROW {
            chunks.append(try decoder.decode(SourceChunk.self, from: data(s, column: 0)))
            step = sqlite3_step(s)
        }
        guard step == SQLITE_DONE else { throw databaseError() }
        return chunks
    }
    func lexical(_ query: String, limit: Int = 24) throws -> [SourceChunk] {
        let match = LexicalTokenizer.matchQuery(query)
        guard !match.isEmpty else { return [] }
        let s = try statement("SELECT c.record FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?")
        defer { sqlite3_finalize(s) }; bind(match, at: 1, to: s); sqlite3_bind_int(s, 2, Int32(limit))
        var result: [SourceChunk] = []
        let decoder = JSONDecoder()
        var step = sqlite3_step(s)
        while step == SQLITE_ROW {
            result.append(try decoder.decode(SourceChunk.self, from: data(s, column: 0)))
            step = sqlite3_step(s)
        }
        guard step == SQLITE_DONE else { throw databaseError() }
        return result
    }
    func retrieve(query: RetrievalQuery, vector: [Float]?, model: String, limit: Int) throws -> [RetrievedSource] {
        guard vector != nil, denseCacheBytes > 0 else {
            return try rankedSources(query: query, vector: vector, model: model, limit: limit)
        }
        // One WAL snapshot covers version checking, FTS and the dense scan, even
        // if another connection replaces a document during this request.
        try exec("BEGIN")
        do {
            let version = try databaseVersion()
            if denseCache.dataVersion != version {
                denseCache = DenseCache(dataVersion: version)
            }
            let sources = try rankedSources(query: query, vector: vector, model: model, limit: limit)
            try exec("COMMIT")
            return sources
        } catch {
            try? exec("ROLLBACK")
            denseCache = DenseCache()
            throw error
        }
    }

    private func databaseVersion() throws -> Int64 {
        let s = try statement("PRAGMA data_version")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_int64(s, 0)
    }

    private func visitDenseChunks(_ visit: (SourceChunk) -> Void) throws {
        for chunk in denseCache.chunks { visit(chunk) }
        guard !denseCache.complete else { return }
        let last = denseCache.lastRowID
        let sql = last == nil ? "SELECT rowid,record FROM chunks ORDER BY rowid"
                              : "SELECT rowid,record FROM chunks WHERE rowid > ? ORDER BY rowid"
        let s = try statement(sql)
        defer { sqlite3_finalize(s) }
        if let last { sqlite3_bind_int64(s, 1, last) }
        let decoder = JSONDecoder()
        var step = sqlite3_step(s)
        while step == SQLITE_ROW {
            let chunk = try decoder.decode(SourceChunk.self, from: data(s, column: 1))
            if !denseCache.full {
                // Charge slack for array capacity, strings, ARC storage and the entry.
                let strings = chunk.id.utf8.count + chunk.documentID.utf8.count + chunk.documentName.utf8.count
                    + chunk.text.utf8.count + chunk.embeddingModel.utf8.count
                let charge = 512 + chunk.vector.count * 8 + strings * 2
                if charge <= denseCacheBytes - denseCache.chargedBytes {
                    denseCache.chunks.append(chunk)
                    denseCache.chargedBytes += charge
                    denseCache.lastRowID = sqlite3_column_int64(s, 0)
                } else {
                    denseCache.full = true
                }
            }
            visit(chunk)
            step = sqlite3_step(s)
        }
        guard step == SQLITE_DONE else { throw databaseError() }
        denseCache.complete = !denseCache.full
    }

    private func rankedSources(query: RetrievalQuery, vector: [Float]?, model: String, limit: Int) throws -> [RetrievedSource] {
        let terms = Set(LexicalTokenizer.retrievalTerms(query.lexical))
        func coverage(_ chunk: SourceChunk) -> Double {
            guard !terms.isEmpty else { return 0 }
            return Double(terms.intersection(LexicalTokenizer.retrievalTerms(chunk.text)).count) / Double(terms.count)
        }
        let lex = try lexical(query.lexical).filter { coverage($0) >= 0.25 }
        var semantic: [SourceChunk] = []
        var similarities: [String: Double] = [:]
        if let vector {
            // Absolute relevance is separate from RRF rank. A top-ranked unrelated
            // item is still unrelated. These conservative floors are not probabilities.
            let floor = model == LocalModelKind.embeddingIdentity ? LocalModelKind.retrievalFloor : 0.30
            if denseCacheBytes == 0 {
                semantic = try allChunks().filter { $0.embeddingModel == model && $0.vector.count == vector.count }
                    .map { chunk -> (SourceChunk, Double) in
                        let score = VectorMath.cosine(chunk.vector, vector)
                        similarities[chunk.id] = score
                        return (chunk, score)
                    }.filter { $0.1 >= floor }
                    .sorted { $0.1 > $1.1 }.prefix(24).map { $0.0 }
            } else {
                let lexicalIDs = Set(lex.map(\.id))
                var best: [(chunk: SourceChunk, score: Double)] = []
                try visitDenseChunks { chunk in
                    guard chunk.embeddingModel == model, chunk.vector.count == vector.count else { return }
                    let score = VectorMath.cosine(chunk.vector, vector)
                    if lexicalIDs.contains(chunk.id) { similarities[chunk.id] = score }
                    guard score >= floor else { return }
                    if best.count == 24 {
                        guard score > best[23].score else { return }
                        best.removeLast()
                    }
                    let index = best.firstIndex { $0.score < score } ?? best.endIndex
                    best.insert((chunk, score), at: index)
                }
                semantic = best.map(\.chunk)
                for hit in best { similarities[hit.chunk.id] = hit.score }
            }
        }
        let fusedLexical = vector != nil && model == LocalModelKind.embeddingIdentity
            ? lex.filter { (similarities[$0.id] ?? 0) >= 0.24 } : lex
        return VectorMath.fuse(lexical: fusedLexical, semantic: semantic, limit: limit).map {
            var source = $0
            source.semanticSimilarity = similarities[source.id]
            source.lexicalCoverage = coverage(source.chunk)
            return source
        }
    }

    private static let maxChunksPerDocument = 4000
    private static let maxChunksMessage = "Document exceeds the V1 limit of 4,000 chunks; split it into smaller documents."

    private nonisolated static func runOffActor<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func extractAndChunk(
        _ url: URL,
        documentID: String,
        name: String,
        textEncoding: DocumentParser.TextEncodingChoice = .automatic
    ) async throws -> [SourceChunk] {
        try await runOffActor {
            let sections = try DocumentParser.extract(url, textEncoding: textEncoding)
            try Task.checkCancellation()
            let chunks = DocumentChunker.chunk(sections, documentID: documentID, name: name, maxChunks: maxChunksPerDocument)
            try Task.checkCancellation()
            guard !chunks.isEmpty else {
                throw CopilotError.message("No extractable text. Scanned PDFs need OCR before import.")
            }
            guard chunks.count <= maxChunksPerDocument else {
                throw CopilotError.message(maxChunksMessage)
            }
            return chunks
        }
    }

    func importDocument(
        _ url: URL,
        textEncoding: DocumentParser.TextEncodingChoice = .automatic,
        provider: any EmbeddingProvider,
        progress: (@Sendable (String, Double) async -> Void)? = nil
    ) async throws -> KnowledgeDocument {
        let id = UUID().uuidString
        let name = url.lastPathComponent
        let chunks = try await Self.extractAndChunk(url, documentID: id, name: name, textEncoding: textEncoding)
        try Task.checkCancellation()
        let folder = directory.appendingPathComponent("originals/\(id)")
        let local = folder.appendingPathComponent(name)
        try await Self.runOffActor {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                try FileManager.default.copyItem(at: url, to: local)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        let document = KnowledgeDocument(id: id, name: name, importedAt: Date(), localPath: local.path,
                                         status: "Indexing", chunkCount: 0, embeddingModel: provider.model)
        do {
            try Task.checkCancellation()
            try saveDocument(document)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return try await index(document, chunks: chunks, provider: provider, progress: progress)
    }
    /// Only migrate local indexes when the user has explicitly selected a cloud provider.
    func migrateToArctic(provider: any EmbeddingProvider, includeRemote: Bool) async throws -> [String] {
        guard provider.model == LocalModelKind.embeddingIdentity else { throw CopilotError.message("Arctic is not available.") }
        var pending = [String]()
        let originals = directory.appendingPathComponent("originals").standardizedFileURL.resolvingSymlinksInPath()
        for doc in try documents() where doc.embeddingModel != provider.model && (includeRemote || doc.embeddingModel.hasPrefix("local:")) {
            try Task.checkCancellation()
            let local = originals.appendingPathComponent(doc.id).appendingPathComponent(doc.name).standardizedFileURL.resolvingSymlinksInPath()
            guard !doc.id.contains("/"), doc.id != "..", doc.id != ".",
                  local.deletingLastPathComponent().path == originals.appendingPathComponent(doc.id).path,
                  FileManager.default.isReadableFile(atPath: local.path) else { pending.append(doc.name); continue }
            do {
                let chunks = try await Self.extractAndChunk(local, documentID: doc.id, name: doc.name)
                _ = try await index(doc, chunks: chunks, provider: provider, progress: nil, migration: true)
            } catch is CancellationError { throw CancellationError() }
            catch { pending.append(doc.name) }
        }
        return pending
    }

    func removeRetiredModels(models: URL, laya: URL, includeRemote: Bool = false) throws -> Int {
        guard try !documents().contains(where: { (includeRemote || $0.embeddingModel.hasPrefix("local:")) && $0.embeddingModel != LocalModelKind.embeddingIdentity }) else {
            throw CopilotError.message("Some local documents still need their original files or an index rebuild. Legacy files have been kept.")
        }
        let fm = FileManager.default
        for root in [models, laya] where fm.fileExists(atPath: root.path) {
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CopilotError.message("Unexpected legacy root. Files have been kept.")
            }
        }
        let base = laya.resolvingSymlinksInPath()
        let current = base.appendingPathComponent("current").resolvingSymlinksInPath()
        var paths = [models.resolvingSymlinksInPath().appendingPathComponent("bge-m3-q8-v1")]
        if current.path == base.appendingPathComponent("current").path ||
           current.deletingLastPathComponent().path == base.appendingPathComponent("installs").path {
            paths.append(current.appendingPathComponent("venv"))
        }
        var count = 0
        for path in paths where fm.fileExists(atPath: path.path) {
            // Do not follow a redirected parent or recycle an unrelated target.
            guard path.resolvingSymlinksInPath().path == path.path,
                  (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw CopilotError.message("Unexpected legacy model path. Files have been kept.")
            }
            try fm.removeItem(at: path)
            count += 1
        }
        return count
    }

    func reindex(_ document: KnowledgeDocument, provider: any EmbeddingProvider, progress: (@Sendable (String, Double) async -> Void)? = nil) async throws -> KnowledgeDocument {
        let localURL = URL(fileURLWithPath: document.localPath)
        let chunks: [SourceChunk]
        do {
            chunks = try await Self.extractAndChunk(localURL, documentID: document.id, name: document.name)
        } catch {
            if !(error is CancellationError) {
                markFailedIfPresent(document, error: error)
            }
            throw error
        }
        return try await index(document, chunks: chunks, provider: provider, progress: progress)
    }
    private func index(_ original: KnowledgeDocument, chunks initialChunks: [SourceChunk], provider: any EmbeddingProvider, progress: (@Sendable (String, Double) async -> Void)? = nil, migration: Bool = false) async throws -> KnowledgeDocument {
        do {
            var chunks = initialChunks
            guard chunks.count <= Self.maxChunksPerDocument else { throw CopilotError.message(Self.maxChunksMessage) }
            let documentID = original.id
            await progress?(original.id, 0)
            for start in stride(from: 0, to: chunks.count, by: 24) {
                try Task.checkCancellation()
                let end = min(start + 24, chunks.count)
                let total = chunks.count
                let vectors = try await provider.embed(chunks[start..<end].map(\.text)) { completed in
                    let count = min(end - start, max(0, completed))
                    await progress?(documentID, 0.95 * Double(start + count) / Double(max(1, total)))
                }
                guard vectors.count == end - start else { throw CopilotError.message("Embedding API returned an incomplete batch.") }
                for (i, vector) in vectors.enumerated() { chunks[start + i].vector = vector; chunks[start + i].embeddingModel = provider.model }
            }
            try Task.checkCancellation()
            // A deletion while awaiting the network must not resurrect the document.
            guard try documents().contains(where: { $0.id == original.id && (!migration || $0 == original) }) else { throw CancellationError() }
            var committed = original
            committed.status = "Ready"; committed.chunkCount = chunks.count; committed.embeddingModel = provider.model; committed.error = nil
            try replaceChunks(chunks, document: committed)
            await progress?(committed.id, 1)
            return committed
        } catch {
            if !migration { markFailedIfPresent(original, error: error) }
            throw error
        }
    }
    private func markFailedIfPresent(_ original: KnowledgeDocument, error: Error) {
        if (try? documents().contains(where: { $0.id == original.id })) == true {
            var failed = original
            failed.status = original.chunkCount > 0 ? "Ready (re-index failed)" : "Failed"
            failed.error = error.localizedDescription
            try? saveDocument(failed)
        }
    }
}
