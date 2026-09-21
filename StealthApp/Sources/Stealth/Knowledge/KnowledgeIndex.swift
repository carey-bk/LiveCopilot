import Foundation
import SQLite3

/// Serialized local SQLite access. Re-index commits all new chunks atomically, retaining the
/// previous usable index on any embedding/network failure. No file contents enter diagnostics.
actor KnowledgeIndex {
    private var db: OpaquePointer?
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
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
        while sqlite3_step(s) == SQLITE_ROW { documents.append(try JSONDecoder().decode(KnowledgeDocument.self, from: data(s, column: 0))) }
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
        } catch { try? exec("ROLLBACK"); throw error }
        let folder = directory.appendingPathComponent("originals/\(id)")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func allChunks() throws -> [SourceChunk] {
        let s = try statement("SELECT record FROM chunks"); defer { sqlite3_finalize(s) }
        var chunks: [SourceChunk] = []
        while sqlite3_step(s) == SQLITE_ROW { chunks.append(try JSONDecoder().decode(SourceChunk.self, from: data(s, column: 0))) }
        return chunks
    }
    func lexical(_ query: String, limit: Int = 24) throws -> [SourceChunk] {
        let match = LexicalTokenizer.matchQuery(query)
        guard !match.isEmpty else { return [] }
        let s = try statement("SELECT c.record FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?")
        defer { sqlite3_finalize(s) }; bind(match, at: 1, to: s); sqlite3_bind_int(s, 2, Int32(limit))
        var result: [SourceChunk] = []
        while sqlite3_step(s) == SQLITE_ROW { result.append(try JSONDecoder().decode(SourceChunk.self, from: data(s, column: 0))) }
        return result
    }
    func retrieve(query: RetrievalQuery, vector: [Float]?, model: String, limit: Int) throws -> [RetrievedSource] {
        let lex = try lexical(query.lexical)
        var semantic: [SourceChunk] = []
        if let vector {
            semantic = try allChunks().filter { $0.embeddingModel == model && $0.vector.count == vector.count }
                .map { ($0, VectorMath.cosine($0.vector, vector)) }.filter { $0.1 > 0.15 }
                .sorted { $0.1 > $1.1 }.prefix(24).map { $0.0 }
        }
        return VectorMath.fuse(lexical: lex, semantic: semantic, limit: limit)
    }

    func importDocument(_ url: URL, provider: any EmbeddingProvider, progress: (@Sendable (String, Double) async -> Void)? = nil) async throws -> KnowledgeDocument {
        let sections = try DocumentParser.extract(url)
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent("originals/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: local)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        let document = KnowledgeDocument(id: id, name: url.lastPathComponent, importedAt: Date(), localPath: local.path,
                                         status: "Indexing", chunkCount: 0, embeddingModel: provider.model)
        try saveDocument(document)
        return try await index(document, sections: sections, provider: provider, progress: progress)
    }
    func reindex(_ document: KnowledgeDocument, provider: any EmbeddingProvider, progress: (@Sendable (String, Double) async -> Void)? = nil) async throws -> KnowledgeDocument {
        let sections = try DocumentParser.extract(URL(fileURLWithPath: document.localPath))
        return try await index(document, sections: sections, provider: provider, progress: progress)
    }
    private func index(_ original: KnowledgeDocument, sections: [DocumentSection], provider: any EmbeddingProvider, progress: (@Sendable (String, Double) async -> Void)? = nil) async throws -> KnowledgeDocument {
        var document = original
        do {
            var chunks = DocumentChunker.chunk(sections, documentID: document.id, name: document.name)
            guard chunks.count <= 4000 else { throw CopilotError.message("Document exceeds the V1 limit of 4,000 chunks; split it into smaller documents.") }
            let documentID = document.id
            await progress?(document.id, 0)
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
            guard try documents().contains(where: { $0.id == document.id }) else { throw CancellationError() }
            document.status = "Ready"; document.chunkCount = chunks.count; document.embeddingModel = provider.model; document.error = nil
            try replaceChunks(chunks, document: document)
            await progress?(document.id, 1)
            return document
        } catch {
            if (try? documents().contains(where: { $0.id == document.id })) == true {
                document.status = original.chunkCount > 0 ? "Ready (re-index failed)" : "Failed"
                document.error = error.localizedDescription
                try? saveDocument(document)
            }
            throw error
        }
    }
}
