using System.IO;
using System.Runtime.CompilerServices;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Overlay;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Tests;

public sealed class ListeningKnowledgeTests
{
    private const string Identity = "text-embedding-3-small";
    private const string SemanticWarning = "语义检索不可用，已改用本地关键词检索";

    [Theory] [InlineData(SuggestionMode.Reply)] [InlineData(SuggestionMode.Recap)] [InlineData(SuggestionMode.FollowUp)]
    public async Task GeneralNeverReadsDocumentsOrCreatesEmbeddings(SuggestionMode mode)
    {
        var index = new Retriever { FailDocuments = true }; var reasoning = new Reasoning();
        var calls = 0;
        await using var session = Session(new() { KnowledgeMode = KnowledgeMode.General }, index,
            _ => { calls++; throw new InvalidOperationException(); }, () => reasoning);
        session.Request(mode); await Finished(session);
        Assert.Equal(0, index.DocumentCalls); Assert.Equal(0, index.RetrievalCalls); Assert.Equal(0, calls);
        Assert.Empty(Assert.Single(reasoning.Requests).Sources); Assert.Null(session.Snapshot.Warning);
        Assert.Empty(session.Snapshot.Sources); Assert.DoesNotContain("[S", session.Snapshot.SuggestionText);
    }

    [Theory]
    [InlineData(KnowledgeMode.Hybrid, SuggestionMode.Reply)] [InlineData(KnowledgeMode.Hybrid, SuggestionMode.Recap)]
    [InlineData(KnowledgeMode.Hybrid, SuggestionMode.FollowUp)] [InlineData(KnowledgeMode.KnowledgeBaseOnly, SuggestionMode.Reply)]
    [InlineData(KnowledgeMode.KnowledgeBaseOnly, SuggestionMode.Recap)] [InlineData(KnowledgeMode.KnowledgeBaseOnly, SuggestionMode.FollowUp)]
    public async Task RetrievesSemanticQueryAndPassesBoundedSourcesToRequestSnapshotAndOverlay(KnowledgeMode knowledgeMode, SuggestionMode mode)
    {
        var index = new Retriever { Sources = Enumerable.Range(1, 8).Select(Source).ToValueList() };
        var embedding = new Embedding(); var reasoning = new Reasoning();
        await using var session = Session(new() { KnowledgeMode = knowledgeMode, RetrievalCount = 3 }, index, _ => embedding, () => reasoning);
        session.Request(mode); await Finished(session);
        var request = Assert.Single(reasoning.Requests);
        Assert.Equal(mode, request.Mode); Assert.Equal(knowledgeMode, request.KnowledgeMode);
        Assert.Equal(request.Query.Semantic, Assert.Single(embedding.Texts)); Assert.Equal(request.Query, index.Query);
        Assert.Equal(new float[] { 1, 0 }, index.Vector); Assert.Equal(Identity, index.Model); Assert.Equal(3, index.Limit);
        Assert.Equal(index.Sources.Take(3), request.Sources); Assert.Equal(request.Sources, session.Snapshot.Sources);
        Assert.Contains("[S1]", request.Input); Assert.Contains("中文证据1", request.Input); Assert.DoesNotContain("中文证据4", request.Input);
        Assert.Equal("回答[S1]。", session.Snapshot.SuggestionText); Assert.Null(session.Snapshot.Warning);
        var overlay = Display(session.Snapshot);
        Assert.Equal("[S1] 文档1.pdf · 第 1 页\n[S2] 文档2.pdf · 第 2 页\n[S3] 文档3.pdf · 第 3 页", overlay.SourceText(3));
        Assert.DoesNotContain("文档3", overlay.SourceText(2)); Assert.Null(overlay.Warning);
    }

    [Theory] [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)]
    public async Task UnavailableOrInvalidSemanticVectorsFallBackToKeywords(int failure)
    {
        var index = new Retriever(); var reasoning = new Reasoning();
        var embedding = new Embedding
        {
            Model = failure == 1 ? "wrong-provider" : Identity,
            Failure = failure == 2 ? new InvalidOperationException("sensitive-placeholder") : null,
            Vectors = failure switch { 3 => [], 4 => [[]], 5 => [[float.NaN]], _ => [[1, 0]] }
        };
        await using var session = Session(new() { KnowledgeMode = KnowledgeMode.Hybrid }, index,
            _ => failure == 0 ? throw new InvalidOperationException("sensitive-placeholder") : embedding, () => reasoning);
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Null(index.Vector); Assert.Equal(1, index.RetrievalCalls);
        Assert.Equal(SemanticWarning, session.Snapshot.Warning); Assert.Equal(SemanticWarning, Display(session.Snapshot).Warning);
        Assert.Single(Assert.Single(reasoning.Requests).Sources); Assert.Null(session.Snapshot.SuggestionError);
        Assert.DoesNotContain("sensitive-placeholder", session.Snapshot.ToString());
    }

    [Theory] [InlineData(EmbeddingService.OpenAI)] [InlineData(EmbeddingService.Local)]
    public async Task MismatchedDocumentIdentitySkipsEmbeddingFactoryButStillSearches(EmbeddingService service)
    {
        var index = new Retriever { Records = [Document("old-model")] }; var reasoning = new Reasoning(); var calls = 0;
        var settings = new AppSettings { KnowledgeMode = KnowledgeMode.Hybrid, EmbeddingService = service };
        await using var session = Session(settings, index, _ => { calls++; throw new InvalidOperationException(); }, () => reasoning);
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Equal(0, calls); Assert.Equal(1, index.RetrievalCalls); Assert.Null(index.Vector);
        Assert.Equal(settings.SelectedEmbeddingIdentity, index.Model); Assert.Null(session.Snapshot.Warning);
        Assert.Single(Assert.Single(reasoning.Requests).Sources);
    }

    [Fact] public async Task LocalIdentityIsUsedForMatchingDocumentsAndVectorQuery()
    {
        var index = new Retriever { Records = [Document(AppPaths.LocalEmbeddingIdentity)] };
        var embedding = new Embedding { Model = AppPaths.LocalEmbeddingIdentity }; var reasoning = new Reasoning();
        await using var session = Session(new() { EmbeddingService = EmbeddingService.Local }, index, _ => embedding, () => reasoning);
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Single(embedding.Texts); Assert.Equal(AppPaths.LocalEmbeddingIdentity, index.Model); Assert.NotNull(index.Vector);
    }

    [Theory] [InlineData(KnowledgeMode.Hybrid)] [InlineData(KnowledgeMode.KnowledgeBaseOnly)]
    public async Task DocumentsWithoutChunksSkipBothEmbeddingAndRetrieval(KnowledgeMode mode)
    {
        var index = new Retriever { Records = [Document(Identity) with { ChunkCount = 0 }] }; var calls = 0;
        var reasoning = new Reasoning();
        await using var session = Session(new() { KnowledgeMode = mode }, index, _ => { calls++; throw new InvalidOperationException(); }, () => reasoning);
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Equal(1, index.DocumentCalls); Assert.Equal(0, index.RetrievalCalls); Assert.Equal(0, calls); Assert.Null(session.Snapshot.Warning);
        Assert.Equal(mode == KnowledgeMode.Hybrid ? 1 : 0, reasoning.Requests.Count);
        if (mode == KnowledgeMode.KnowledgeBaseOnly) Assert.Equal("未找到知识库证据", session.Snapshot.SuggestionStatus);
    }

    [Theory]
    [InlineData(KnowledgeMode.Hybrid, 0)] [InlineData(KnowledgeMode.Hybrid, 1)] [InlineData(KnowledgeMode.Hybrid, 2)]
    [InlineData(KnowledgeMode.KnowledgeBaseOnly, 0)] [InlineData(KnowledgeMode.KnowledgeBaseOnly, 1)] [InlineData(KnowledgeMode.KnowledgeBaseOnly, 2)]
    public async Task DatabaseFailuresWarnAndStrictModeNeverCallsModel(KnowledgeMode mode, int failure)
    {
        var index = new Retriever { FailDocuments = failure == 1, FailRetrieve = failure == 2 };
        var reasoning = new Reasoning(); var calls = 0;
        await using var session = Session(new() { KnowledgeMode = mode, AnswerLanguage = AnswerLanguage.Chinese }, failure == 0 ? null : index,
            _ => new Embedding(), () => { calls++; return reasoning; });
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Contains("知识库不可用", session.Snapshot.Warning); Assert.Empty(session.Snapshot.Sources); Assert.Null(session.Snapshot.SuggestionError);
        Assert.DoesNotContain("sensitive-placeholder", session.Snapshot.ToString());
        Assert.Equal(mode == KnowledgeMode.Hybrid ? 1 : 0, calls);
        if (mode == KnowledgeMode.KnowledgeBaseOnly)
            Assert.Equal(AnswerLanguage.Chinese.MissingEvidence("延迟是多少？"), session.Snapshot.SuggestionText);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task NoMatchingEvidenceInStrictModeUsesMissingEvidenceWithoutFactory(bool bilingual)
    {
        var index = new Retriever { Sources = [] }; var calls = 0;
        await using var session = Session(new() { KnowledgeMode = KnowledgeMode.KnowledgeBaseOnly, AnswerLanguage = AnswerLanguage.Chinese, BilingualAnswers = bilingual },
            index, _ => new Embedding(), () => { calls++; throw new InvalidOperationException(); });
        session.Request(SuggestionMode.Reply); await Finished(session);
        Assert.Equal(0, calls); Assert.Equal(1, index.RetrievalCalls); Assert.Empty(session.Snapshot.Sources);
        var expected = AnswerLanguage.Chinese.MissingEvidence("延迟是多少？") + (bilingual ? "\n" + AnswerLanguage.English.MissingEvidence("延迟是多少？") : "");
        Assert.Equal(expected, session.Snapshot.SuggestionText);
    }

    [Fact] public async Task IncludeConversationFalseDoesNotSendContextToEmbedding()
    {
        var embedding = new Embedding(); var reasoning = new Reasoning();
        await using var session = Session(new() { IncludeConversation = false }, new Retriever(), _ => embedding, () => reasoning);
        session.Request(SuggestionMode.FollowUp); await Finished(session);
        Assert.DoesNotContain("context stays local", Assert.Single(embedding.Texts));
        Assert.Empty(Assert.Single(reasoning.Requests).Conversation);
    }

    [Theory] [InlineData("stop")] [InlineData("dispose")] [InlineData("timeout")]
    public async Task CancellationDuringEmbeddingIgnoresLateResultsAndDoesNotFallBack(string action)
    {
        var embedding = new Embedding { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var index = new Retriever(); var calls = 0;
        await using var session = Session(new(), index, _ => embedding, () => { calls++; return new Reasoning(); },
            action == "timeout" ? TimeSpan.FromMilliseconds(300) : null);
        session.Request(SuggestionMode.Reply); await embedding.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (action == "stop") await session.StopAsync().WaitAsync(TimeSpan.FromSeconds(5));
        else if (action == "dispose") await session.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        else await Finished(session);
        await embedding.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var stopped = session.Snapshot;
        embedding.Gate.SetResult(); await embedding.Returned.Task.WaitAsync(TimeSpan.FromSeconds(5));
        // The continuation drains cancellation before a second request can publish results.
        Assert.Equal(action == "timeout" ? "回答超时，请手动重试。" : "回答已取消", stopped.SuggestionStatus);
        Assert.Null(stopped.Warning); Assert.Empty(stopped.Sources); Assert.Equal(0, index.RetrievalCalls); Assert.Equal(0, calls);
        Assert.Equal(stopped, session.Snapshot);
    }

    [Fact] public async Task ActiveRequestKeepsSettingsAndNextRequestClearsSourcesAndWarning()
    {
        var embedding = new Embedding { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var index = new Retriever(); var reasoning = new Reasoning();
        await using var session = Session(new(), index, _ => embedding, () => reasoning);
        session.Request(SuggestionMode.Reply); await embedding.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        session.ConfigureKnowledge(new() { KnowledgeMode = KnowledgeMode.General, EmbeddingModel = "changed-model" });
        embedding.Gate.SetResult(); await Finished(session);
        Assert.Equal(KnowledgeMode.Hybrid, Assert.Single(reasoning.Requests).KnowledgeMode); Assert.Equal(Identity, index.Model);
        Assert.Single(session.Snapshot.Sources);
        session.Request(SuggestionMode.Recap); await Finished(session);
        Assert.Equal(KnowledgeMode.General, reasoning.Requests[1].KnowledgeMode);
        Assert.Empty(session.Snapshot.Sources); Assert.Null(session.Snapshot.Warning); Assert.Equal(1, index.DocumentCalls);
    }

    [Fact] public async Task ReplacementRequestDuringEmbeddingRejectsOldSourcesAndWarnings()
    {
        var embedding = new Embedding { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously), Failure = new InvalidOperationException("late") };
        var index = new Retriever(); var reasoning = new Reasoning();
        await using var session = Session(new(), index, _ => embedding, () => reasoning);
        session.Request(SuggestionMode.Reply); await embedding.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        session.ConfigureKnowledge(new() { KnowledgeMode = KnowledgeMode.General }); session.Request(SuggestionMode.Recap);
        await Finished(session); await embedding.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var latest = session.Snapshot; embedding.Gate.SetResult(); await embedding.Returned.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(latest, session.Snapshot); Assert.Equal(SuggestionMode.Recap, Assert.Single(reasoning.Requests).Mode);
        Assert.Null(latest.Warning); Assert.Empty(latest.Sources); Assert.Equal(0, index.RetrievalCalls);
    }

    [Fact] public async Task RealChineseDocumentImportsReindexesRetrievesAndDeletesThroughSessionBoundary()
    {
        var root = Path.Combine(Path.GetTempPath(), "livecopilot-rag-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "中文资料.md"); await File.WriteAllTextAsync(path, "# 延迟是多少？\n测量结果为42毫秒，样本量128。");
            using var index = new KnowledgeIndex(Path.Combine(root, "index"), new DocumentParser());
            var document = await index.ImportDocumentAsync(path, new Embedding { Model = "previous-model" });
            var reasoning = new Reasoning();
            await using var session = Session(new(), index, _ => throw new InvalidOperationException("must not embed"), () => reasoning);
            session.Request(SuggestionMode.Reply); await Finished(session);
            var source = Assert.Single(Assert.Single(reasoning.Requests).Sources);
            Assert.Equal(document.Id, source.Chunk.DocumentId); Assert.Contains("42毫秒", source.Chunk.Text);
            Assert.Equal("[S1] 中文资料.md", Display(session.Snapshot).SourceText(5));
            var updated = await index.ReindexAsync(document, new Embedding());
            Assert.Equal(Identity, updated.EmbeddingModel); Assert.NotEqual(source.Id, index.AllChunks()[0].Id);
            index.Delete(document.Id); Assert.Empty(index.Documents()); Assert.Empty(index.AllChunks());
            Assert.False(File.Exists(document.LocalPath)); Assert.True(File.Exists(path));
        }
        finally { Directory.Delete(root, true); }
    }

    private static OverlayContent Display(ListeningSnapshot view) => new(view.Status, view.Lines, SuggestionText: view.SuggestionText)
        { Sources = view.Sources, Warning = view.Warning };
    private static KnowledgeDocument Document(string model) => new("doc", "资料.pdf", DateTimeOffset.UtcNow, "unused.pdf", "Ready", 1, model);
    private static RetrievedSource Source(int i) => new(new SourceChunk("chunk" + i, "doc", $"文档{i}.pdf", i - 1, i, $"中文证据{i}", [1, 0], Identity), 1);
    private static ListeningSession Session(AppSettings settings, IKnowledgeRetriever? index, Func<AppSettings, IEmbeddingProvider> embedding,
        Func<IReasoningProvider> reasoning, TimeSpan? timeout = null)
    {
        var transcript = new TranscriptStore(); transcript.Commit("context stays local", Speaker.You); transcript.Commit("延迟是多少？", Speaker.Them);
        return new(new FakeAudioFactory(new(), new()), (_, _) => throw new InvalidOperationException("No audio expected"),
            settings, transcript, reasoningFactory: reasoning, answerTimeout: timeout, knowledgeRetriever: index, embeddingFactory: embedding);
    }
    private static async Task Finished(ListeningSession session)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed() { if (!session.Snapshot.SuggestionIsLoading) done.TrySetResult(); }
        session.Changed += Changed;
        try { Changed(); await done.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { session.Changed -= Changed; }
    }
    private sealed class Retriever : IKnowledgeRetriever
    {
        public ValueList<KnowledgeDocument> Records { get; init; } = [Document(Identity)];
        public ValueList<RetrievedSource> Sources { get; init; } = [Source(1)];
        public bool FailDocuments { get; init; }
        public bool FailRetrieve { get; init; }
        public int DocumentCalls { get; private set; }
        public int RetrievalCalls { get; private set; }
        public RetrievalQuery? Query { get; private set; }
        public IReadOnlyList<float>? Vector { get; private set; }
        public string? Model { get; private set; }
        public int Limit { get; private set; }
        public ValueList<KnowledgeDocument> Documents()
        { DocumentCalls++; if (FailDocuments) throw new IOException("sensitive-placeholder"); return Records; }
        public ValueList<RetrievedSource> Retrieve(RetrievalQuery query, IReadOnlyList<float>? vector, string model, int limit)
        {
            RetrievalCalls++; Query = query; Vector = vector; Model = model; Limit = limit;
            if (FailRetrieve) throw new IOException("sensitive-placeholder"); return Sources;
        }
    }
    private sealed class Embedding : IEmbeddingProvider
    {
        public string Model { get; init; } = Identity;
        public Exception? Failure { get; init; }
        public IReadOnlyList<ValueList<float>> Vectors { get; init; } = [[1, 0]];
        public IReadOnlyList<string> Texts { get; private set; } = [];
        public TaskCompletionSource? Gate { get; init; }
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Returned { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
        {
            using var registration = cancellationToken.Register(() => Cancelled.TrySetResult());
            Texts = texts.ToArray(); Started.TrySetResult();
            try
            {
                if (Gate is not null) await Gate.Task; // Deliberately ignores cancellation.
                if (Failure is not null) throw Failure;
                return Vectors;
            }
            finally { Returned.TrySetResult(); }
        }
    }
    private sealed class Reasoning : IReasoningProvider
    {
        public List<AnswerRequest> Requests { get; } = [];
        public async IAsyncEnumerable<string> Stream(AnswerRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            Requests.Add(request); cancellationToken.ThrowIfCancellationRequested();
            yield return "回答[S1][S99]。"; await Task.CompletedTask;
        }
    }
}
