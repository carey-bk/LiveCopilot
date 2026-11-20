namespace LiveCopilot.Core.Tests;

public sealed class KnowledgeIndexTests
{
    private const string Document = "Experiment A has 128 samples. Method B latency is 42 ms. 样本量128，延迟42毫秒。";

    [Fact]
    public void ConstructionIsLazyAndChunkingPreservesUnicodeMetadataAndBounds()
    {
        using var root = new TemporaryDirectory(false);
        using var index = new KnowledgeIndex(root.Path);
        Assert.False(Directory.Exists(root.Path));
        var text = string.Concat(Enumerable.Repeat("样本量为128，延迟42毫秒。🧪", 40));
        var chunks = DocumentChunker.Chunk([new(text, 3)], "doc", "study.txt", 128, 0);
        Assert.Equal(text, string.Concat(chunks.Select(c => c.Text)));
        Assert.Equal(Enumerable.Range(0, chunks.Count), chunks.Select(c => c.Ordinal));
        Assert.All(chunks, chunk =>
        {
            Assert.Equal("doc", chunk.DocumentId);
            Assert.Equal("study.txt", chunk.DocumentName);
            Assert.Equal(3, chunk.Page);
            Assert.InRange(new System.Globalization.StringInfo(chunk.Text).LengthInTextElements, 1, 128);
        });
        Assert.Empty(DocumentChunker.Chunk([new(" \n ")], "empty", "empty.txt"));
        Assert.NotEmpty(DocumentChunker.Chunk([new(Document)], "safe", "safe.txt", 0, 900));
    }

    [Fact]
    public async Task TextImportPersistsVectorsSupportsCjkRetrievalAndDeletesOriginals()
    {
        using var root = new TemporaryDirectory();
        var path = Path.Combine(root.Path, "experiment.txt");
        await File.WriteAllTextAsync(path, Document);
        var directory = Path.Combine(root.Path, "index");
        using var index = new KnowledgeIndex(directory);
        var progress = new List<double>();
        var doc = await index.ImportDocumentAsync(path, new Embeddings(), (_, value) => { progress.Add(value); return Task.CompletedTask; });
        Assert.Equal("Ready", doc.Status);
        Assert.True(doc.ChunkCount > 0);
        Assert.Equal(0, progress[0]);
        Assert.Equal(1, progress[^1]);
        Assert.Equal(doc.Id, index.Lexical("42 128 latency")[0].DocumentId);
        Assert.NotEmpty(index.Lexical("样本量"));
        _ = index.Lexical("\" OR * (NEAR) DROP TABLE chunks;");
        var chunks = index.AllChunks();
        using (var reopened = new KnowledgeIndex(directory)) Assert.Equal(chunks, reopened.AllChunks());
        Assert.NotEmpty(index.Retrieve(RetrievalQuery.Formulate("latency 42", ""), [1, 0], "test-embedding", 6));
        Assert.Empty(index.Retrieve(RetrievalQuery.Formulate("zzzzunrelated", ""), [1, 0], "different-model", 6));
        Assert.Equal(Document, await File.ReadAllTextAsync(doc.LocalPath));
        index.Delete(doc.Id);
        Assert.Empty(index.Documents());
        Assert.Empty(index.AllChunks());
        Assert.Empty(index.Lexical("latency"));
        Assert.False(File.Exists(doc.LocalPath));
    }

    [Fact]
    public async Task ReindexFailureRetainsOldChunksAndSuccessfulRetryReplacesThem()
    {
        using var root = new TemporaryDirectory();
        var path = Path.Combine(root.Path, "experiment.md");
        await File.WriteAllTextAsync(path, Document);
        using var index = new KnowledgeIndex(Path.Combine(root.Path, "index"));
        var doc = await index.ImportDocumentAsync(path, new Embeddings());
        var original = index.AllChunks();
        await Assert.ThrowsAsync<CopilotException>(() => index.ReindexAsync(doc, new Embeddings(failOnBatch: 1)));
        Assert.Equal(original, index.AllChunks());
        Assert.Equal("Ready (re-index failed)", Assert.Single(index.Documents()).Status);
        var updated = await index.ReindexAsync(doc, new Embeddings());
        Assert.Equal(updated.ChunkCount, index.AllChunks().Count);
        Assert.NotEqual(original[0].Id, index.AllChunks()[0].Id);
        Assert.Null(Assert.Single(index.Documents()).Error);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeletedOrCancelledImportRejectsLateEmbeddingResults(bool cancel)
    {
        using var root = new TemporaryDirectory();
        var path = Path.Combine(root.Path, "experiment.txt");
        await File.WriteAllTextAsync(path, Document);
        using var index = new KnowledgeIndex(Path.Combine(root.Path, "index"));
        using var cancellation = new CancellationTokenSource();
        var provider = new GatedEmbeddings();
        var importing = index.ImportDocumentAsync(path, provider, cancellationToken: cancellation.Token);
        await provider.Started.WaitAsync(TimeSpan.FromSeconds(5));
        var pending = Assert.Single(index.Documents());
        if (cancel) cancellation.Cancel();
        else index.Delete(pending.Id);
        provider.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => importing.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Empty(index.AllChunks());
        Assert.Empty(index.Lexical("latency"));
        if (cancel) Assert.Equal("Failed", Assert.Single(index.Documents()).Status);
        else Assert.Empty(index.Documents());
    }

    [Fact]
    public async Task MidBatchFailureDoesNotPublishPartialVectors()
    {
        using var root = new TemporaryDirectory();
        var path = Path.Combine(root.Path, "large.txt");
        await File.WriteAllTextAsync(path, string.Concat(Enumerable.Repeat(Document + "\n", 600)));
        using var index = new KnowledgeIndex(Path.Combine(root.Path, "index"));
        await Assert.ThrowsAsync<CopilotException>(() => index.ImportDocumentAsync(path, new Embeddings(failOnBatch: 2)));
        Assert.Empty(index.AllChunks());
        Assert.Empty(index.Lexical("latency"));
        Assert.Equal("Failed", Assert.Single(index.Documents()).Status);
    }

    [Fact]
    public void VectorMathRejectsInvalidInputsAndFusionRewardsAgreement()
    {
        Assert.Equal(1, VectorMath.Cosine([1, 0], [1, 0]));
        Assert.Equal(0, VectorMath.Cosine([1, 0], [0, 1]));
        Assert.Equal(0, VectorMath.Cosine([0, 0], [1, 0]));
        Assert.Equal(0, VectorMath.Cosine([1], [1, 0]));
        Assert.Equal(0, VectorMath.Cosine([float.NaN], [1]));
        var a = Fixtures.Chunk("a"); var b = Fixtures.Chunk("b"); var c = Fixtures.Chunk("c");
        var result = VectorMath.Fuse([a, b], [b, c], 6);
        Assert.Equal("b", result[0].Id);
        Assert.Equal(3, result.Count);
    }

    private sealed class Embeddings(int failOnBatch = 0) : IEmbeddingProvider
    {
        private int batch;
        public string Model => "test-embedding";
        public Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (++batch == failOnBatch) throw new CopilotException("Synthetic embedding failure");
            return Task.FromResult<IReadOnlyList<ValueList<float>>>(texts.Select(_ => new ValueList<float>([1, 0])).ToArray());
        }
    }

    private sealed class GatedEmbeddings : IEmbeddingProvider
    {
        private readonly TaskCompletionSource started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string Model => "test-embedding";
        public Task Started => started.Task;
        public void Release() => release.TrySetResult();
        public async Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
        {
            started.TrySetResult();
            await release.Task; // Ignore cancellation to exercise the index's own commit guard.
            return texts.Select(_ => new ValueList<float>([1, 0])).ToArray();
        }
    }
}
