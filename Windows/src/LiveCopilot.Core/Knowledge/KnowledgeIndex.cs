using Microsoft.Data.Sqlite;

namespace LiveCopilot.Core;

/// SQLite operations are serialized; embedding awaits release the lock so deletion can proceed.
public sealed class KnowledgeIndex : IKnowledgeRetriever, IDisposable
{
    private readonly object gate = new();
    private readonly IDocumentParser parser;
    private SqliteConnection? db;
    private bool disposed;
    public string DirectoryPath { get; }
    public KnowledgeIndex(string directory, IDocumentParser? parser = null)
    { DirectoryPath = Path.GetFullPath(directory); this.parser = parser ?? new TextDocumentParser(); }
    private void EnsureDatabase()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (db is not null) return;
        if (!Directory.Exists(DirectoryPath))
        {
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(DirectoryPath);
            else Directory.CreateDirectory(DirectoryPath, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var path = Path.Combine(DirectoryPath, "knowledge.sqlite");
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false, DefaultTimeout = 5 }.ToString());
        try
        {
            connection.Open(); db = connection;
            Execute("""
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, record BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, record BLOB NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, terms, tokenize='unicode61');
                UPDATE documents SET record=json_set(CAST(record AS TEXT),'$.status','Failed','$.error','Indexing was interrupted. Re-index this document to retry.') WHERE json_extract(CAST(record AS TEXT),'$.status')='Indexing';
                """);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch { db = null; connection.Dispose(); throw; }
    }
    private T Locked<T>(Func<T> operation)
    {
        lock (gate)
        {
            try { EnsureDatabase(); return operation(); }
            catch (SqliteException) { throw new CopilotException("Local knowledge database operation failed. Check disk space and access permissions."); }
        }
    }
    private SqliteCommand Command(string sql, SqliteTransaction? transaction, params object[] parameters)
    {
        var command = db!.CreateCommand(); command.CommandText = sql; command.Transaction = transaction;
        for (var i = 0; i < parameters.Length; i++) command.Parameters.AddWithValue("$p" + i, parameters[i]);
        return command;
    }
    private void Execute(string sql, SqliteTransaction? transaction = null, params object[] parameters)
    { using var command = Command(sql, transaction, parameters); command.ExecuteNonQuery(); }
    private ValueList<T> Read<T>(string sql, params object[] parameters)
    {
        using var command = Command(sql, null, parameters); using var reader = command.ExecuteReader(); var result = new List<T>();
        while (reader.Read()) result.Add(CoreJson.Decode<T>(reader.GetValue(0) is byte[] bytes ? Encoding.UTF8.GetString(bytes) : reader.GetString(0)));
        return result.ToValueList();
    }
    public ValueList<KnowledgeDocument> Documents() => Locked(() => Read<KnowledgeDocument>("SELECT record FROM documents").OrderByDescending(d => d.ImportedAt).ToValueList());
    private void SaveDocument(KnowledgeDocument document, SqliteTransaction? transaction) => Execute(
        "INSERT INTO documents(id,record) VALUES($p0,$p1) ON CONFLICT(id) DO UPDATE SET record=excluded.record", transaction, document.Id, Encoding.UTF8.GetBytes(CoreJson.Encode(document)));
    public void SaveDocument(KnowledgeDocument document) => Locked(() => { SaveDocument(document, null); return true; });
    public void ReplaceChunks(IReadOnlyList<SourceChunk> chunks, KnowledgeDocument document) => Locked(() =>
    {
        if (chunks.Count == 0 || chunks.Any(c => c.Vector.Count == 0 || c.Vector.Any(v => !float.IsFinite(v)) || c.DocumentId != document.Id) || chunks.Select(c => c.Vector.Count).Distinct().Count() != 1)
            throw new CopilotException("Invalid embedding response; the previous index was preserved.");
        using var transaction = db!.BeginTransaction();
        SaveDocument(document, transaction); RemoveChunks(document.Id, transaction);
        foreach (var chunk in chunks)
        {
            Execute("INSERT INTO chunks(id,document_id,record) VALUES($p0,$p1,$p2)", transaction, chunk.Id, chunk.DocumentId, Encoding.UTF8.GetBytes(CoreJson.Encode(chunk)));
            Execute("INSERT INTO chunks_fts(chunk_id,terms) VALUES($p0,$p1)", transaction, chunk.Id, LexicalTokenizer.IndexedText(chunk.Text));
        }
        transaction.Commit(); return true; // Dispose rolls back every uncommitted transaction.
    });
    private void RemoveChunks(string id, SqliteTransaction transaction)
    {
        Execute("DELETE FROM chunks_fts WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id=$p0)", transaction, id);
        Execute("DELETE FROM chunks WHERE document_id=$p0", transaction, id);
    }
    public void Delete(string id) => Locked(() =>
    {
        using (var transaction = db!.BeginTransaction())
        { RemoveChunks(id, transaction); Execute("DELETE FROM documents WHERE id=$p0", transaction, id); transaction.Commit(); }
        // IDs from legacy data are not allowed to escape the originals directory.
        if (id != "." && id != ".." && id == Path.GetFileName(id) && !id.Contains('\\'))
        { var folder = Path.Combine(DirectoryPath, "originals", id); if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        return true;
    });
    public ValueList<SourceChunk> AllChunks() => Locked(() => Read<SourceChunk>("SELECT record FROM chunks"));
    public ValueList<SourceChunk> Lexical(string query, int limit = 24) => Locked(() =>
    {
        var match = LexicalTokenizer.MatchQuery(query);
        return match.Length == 0 ? [] : Read<SourceChunk>("SELECT c.record FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id WHERE chunks_fts MATCH $p0 ORDER BY bm25(chunks_fts) LIMIT $p1", match, limit);
    });
    public ValueList<RetrievedSource> Retrieve(RetrievalQuery query, IReadOnlyList<float>? vector, string model, int limit) => Locked(() =>
    {
        var terms = LexicalTokenizer.RetrievalTerms(query.Lexical).ToHashSet();
        double Coverage(SourceChunk c) => terms.Count == 0 ? 0 : (double)terms.Intersect(LexicalTokenizer.RetrievalTerms(c.Text)).Count() / terms.Count;
        var lexical = Lexical(query.Lexical).Where(c => Coverage(c) >= 0.25).ToArray();
        var similarities = new Dictionary<string, double>();
        SourceChunk[] semantic = [];
        if (vector is not null)
        {
            var floor = model == AppPaths.LocalEmbeddingIdentity ? 0.38 : 0.30;
            semantic = AllChunks().Where(c => c.EmbeddingModel == model && c.Vector.Count == vector.Count)
                .Select(c => { var score = VectorMath.Cosine(c.Vector, vector); similarities[c.Id] = score; return (Chunk: c, Score: score); })
                .Where(c => c.Score >= floor).OrderByDescending(c => c.Score).Take(24).Select(c => c.Chunk).ToArray();
        }
        return VectorMath.Fuse(lexical, semantic, limit).Select(s => s with { SemanticSimilarity = similarities.TryGetValue(s.Id, out var score) ? score : null, LexicalCoverage = Coverage(s.Chunk) }).ToValueList();
    });
    public async Task<KnowledgeDocument> ImportDocumentAsync(string path, IEmbeddingProvider provider, Func<string, double, Task>? progress = null, CancellationToken cancellationToken = default)
    {
        var sections = parser.Extract(path);
        var id = CoreJson.Id(Guid.NewGuid());
        var folder = Path.Combine(DirectoryPath, "originals", id);
        var local = Path.Combine(folder, Path.GetFileName(path));
        AtomicFile.Write(local, await File.ReadAllBytesAsync(path, cancellationToken));
        var document = new KnowledgeDocument(id, Path.GetFileName(path), DateTimeOffset.UtcNow, local, "Indexing", 0, provider.Model);
        SaveDocument(document);
        return await IndexAsync(document, sections, provider, progress, cancellationToken);
    }
    public Task<KnowledgeDocument> ReindexAsync(KnowledgeDocument document, IEmbeddingProvider provider, Func<string, double, Task>? progress = null, CancellationToken cancellationToken = default) =>
        IndexAsync(document, parser.Extract(document.LocalPath), provider, progress, cancellationToken);
    private async Task<KnowledgeDocument> IndexAsync(KnowledgeDocument original, IReadOnlyList<DocumentSection> sections, IEmbeddingProvider provider, Func<string, double, Task>? progress, CancellationToken cancellationToken)
    {
        try
        {
            var chunks = DocumentChunker.Chunk(sections, original.Id, original.Name).ToArray();
            if (chunks.Length > 4000) throw new CopilotException("Document exceeds the V1 limit of 4,000 chunks; split it into smaller documents.");
            if (progress is not null) await progress(original.Id, 0);
            for (var start = 0; start < chunks.Length; start += 24)
            {
                cancellationToken.ThrowIfCancellationRequested(); var end = Math.Min(start + 24, chunks.Length); var batchStart = start;
                var vectors = await provider.EmbedAsync(chunks[start..end].Select(c => c.Text).ToArray(), async count =>
                { if (progress is not null) await progress(original.Id, 0.95 * (batchStart + Math.Clamp(count, 0, end - batchStart)) / Math.Max(1, chunks.Length)); }, cancellationToken);
                if (vectors.Count != end - start) throw new CopilotException("Embedding API returned an incomplete batch.");
                for (var i = 0; i < vectors.Count; i++) chunks[start + i] = chunks[start + i] with { Vector = vectors[i], EmbeddingModel = provider.Model };
            }
            cancellationToken.ThrowIfCancellationRequested();
            var result = Locked(() =>
            {
                if (!Documents().Any(d => d.Id == original.Id)) throw new OperationCanceledException();
                var ready = original with { Status = "Ready", ChunkCount = chunks.Length, EmbeddingModel = provider.Model, Error = null };
                ReplaceChunks(chunks, ready); return ready;
            });
            if (progress is not null) await progress(original.Id, 1);
            return result;
        }
        catch (Exception error)
        {
            try
            {
                Locked(() =>
                {
                    if (Documents().Any(d => d.Id == original.Id)) SaveDocument(original with { Status = original.ChunkCount > 0 ? "Ready (re-index failed)" : "Failed", Error = error.Message });
                    return true;
                });
            }
            catch (Exception e) when (e is CopilotException or IOException or ObjectDisposedException) { }
            throw;
        }
    }
    public void Dispose() { lock (gate) { disposed = true; db?.Dispose(); db = null; } }
}
