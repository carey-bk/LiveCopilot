using System.IO;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Tests;

public sealed partial class ListeningReasoningTests
{
    [Fact]
    public async Task TypedOnlyMultipleAnswersAreArchivedOnceOnStopResetAndDispose()
    {
        using var history = new HistoryDirectory();
        var first = new ControlledReasoning(); var second = new ControlledReasoning();
        var providers = new Queue<ControlledReasoning>([first, second]);
        await using var session = Session(() => providers.Dequeue(), new(), new() { Scenario = ScenarioProfile.Meeting }, history: history.Store);
        session.Ask("虚构问题一"); await first.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        first.Send("虚构回答一"); first.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        session.Ask("虚构问题二"); await second.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        second.Send("虚构回答二"); second.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        await session.StopAsync(); Assert.True(await session.ResetAsync()); await session.DisposeAsync();
        var saved = Assert.Single(history.Reload());
        Assert.Empty(saved.Lines); Assert.Equal(ScenarioProfile.Meeting, saved.Scenario);
        Assert.NotNull(saved.Answers);
        Assert.Equal(["虚构问题一", "虚构问题二"], saved.Answers.Select(a => a.Question));
        Assert.Equal(["虚构回答一", "虚构回答二"], saved.Answers.Select(a => a.Text));
        Assert.All(saved.Answers, a => { Assert.Equal("completed", a.State); Assert.NotNull(a.CompletedAt); });
        Assert.Equal(2, saved.Answers.Select(a => a.Id).Distinct().Count());
    }

    [Fact]
    public async Task AudioSessionArchivesTranscriptAnswersAndCapturedScenarioTogether()
    {
        using var history = new HistoryDirectory(); var transcript = new TranscriptStore(); var provider = new ControlledReasoning();
        await using var session = Session(() => provider, transcript, new() { Scenario = ScenarioProfile.Defense }, history: history.Store);
        await session.StartAsync(); transcript.Commit("虚构实验转写", Speaker.Room);
        session.Configure(new() { Scenario = ScenarioProfile.Meeting });
        session.Ask("虚构实验问题"); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("虚构实验答案"); provider.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        Assert.True(await session.ResetAsync());
        var saved = Assert.Single(history.Reload());
        Assert.Equal("虚构实验转写", Assert.Single(saved.Lines).Content);
        Assert.Equal("虚构实验答案", Assert.Single(saved.Answers!).Text); Assert.Equal(ScenarioProfile.Defense, saved.Scenario);
        Assert.Empty(session.Snapshot.Lines); Assert.Empty(session.Snapshot.SuggestionText);
    }

    [Fact]
    public async Task ResetArchivesPartialAnswerAndLateProviderCannotChangeOrResurrectDeletedHistory()
    {
        using var history = new HistoryDirectory(); var provider = new ControlledReasoning(ignoreCancellation: true);
        await using var session = Session(() => provider, new(), history: history.Store);
        session.Ask("虚构流式问题"); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("已生成部分"); await Until(session, s => s.SuggestionText == "已生成部分");
        Assert.True(await session.ResetAsync());
        var saved = Assert.Single(history.Reload()); var answer = Assert.Single(saved.Answers!);
        Assert.Equal("interrupted", answer.State); Assert.Equal("已生成部分", answer.Text);
        Assert.True(history.Store.Delete(saved));
        provider.Send("迟到内容"); provider.Complete(); await provider.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await session.StopAsync(); Assert.Empty(history.Reload()); Assert.Empty(session.Snapshot.SuggestionText);
    }

    [Fact]
    public async Task StartingAudioArchivesPriorTypedConversationBeforeClearingIt()
    {
        using var history = new HistoryDirectory(); var provider = new ControlledReasoning();
        await using var session = Session(() => provider, new(), history: history.Store);
        session.Ask("虚构独立提问"); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("保存独立回答"); provider.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        await session.StartAsync(); await session.StopAsync();
        Assert.Equal("保存独立回答", Assert.Single(Assert.Single(history.Reload()).Answers!).Text);
    }

    [Fact]
    public async Task TypedHistorySaveFailurePreventsResetAndNewAudioFromDiscardingContent()
    {
        using var history = new HistoryDirectory(); var provider = new ControlledReasoning();
        File.WriteAllText(history.Path, "block directory creation");
        await using var session = Session(() => provider, new(), history: history.Store);
        session.Ask("不能丢失的虚构问题"); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("不能丢失的虚构回答"); provider.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        Assert.False(await session.ResetAsync()); Assert.Contains("会话保存失败", session.Snapshot.Error);
        await session.StartAsync(); Assert.Equal("不能丢失的虚构回答", session.Snapshot.SuggestionText);
        Assert.False(session.Snapshot.System.Capturing); Assert.Empty(history.Store.Sessions);
    }

    [Fact]
    public async Task ArchivePersistsRetrievedCitationMetadataExcerptAndRetrievalWarning()
    {
        using var history = new HistoryDirectory(); var provider = new ControlledReasoning();
        await using var session = Session(() => provider, new(), new() { KnowledgeMode = KnowledgeMode.Hybrid,
            EmbeddingService = EmbeddingService.OpenAI, EmbeddingModel = "synthetic-model" },
            history: history.Store, knowledge: new HistoryKnowledge());
        session.Ask("虚构引用问题"); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("使用虚构证据 [S1]"); provider.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        await session.StopAsync();
        var answer = Assert.Single(Assert.Single(history.Reload()).Answers!);
        Assert.Equal("使用虚构证据 [S1]", answer.Text); Assert.NotNull(answer.Warning);
        var source = Assert.Single(answer.Sources);
        Assert.Equal(new SessionCitation(1, "synthetic-doc", "虚构参考.txt", 2, 3, "虚构引用内容"), source);
    }

    private sealed class HistoryKnowledge : IKnowledgeRetriever
    {
        public ValueList<KnowledgeDocument> Documents() => [new("synthetic-doc", "虚构参考.txt", DateTimeOffset.UtcNow, "unused.txt", "Ready", 1, "synthetic-model")];
        public ValueList<RetrievedSource> Retrieve(RetrievalQuery query, IReadOnlyList<float>? vector, string model, int limit) =>
            [new(new SourceChunk("synthetic-chunk", "synthetic-doc", "虚构参考.txt", 3, 2, "虚构引用内容", [], "synthetic-model"), 1),
             new(new SourceChunk("unused-chunk", "unused-doc", "未引用资料.txt", 0, null, "未引用内容", [], "synthetic-model"), 0.5)];
    }
    private sealed class HistoryDirectory : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "listening-history-" + Guid.NewGuid());
        public SessionStore Store { get; }
        public HistoryDirectory() => Store = new(Path);
        public IReadOnlyList<SessionRecord> Reload() => new SessionStore(Path).Sessions;
        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, true);
            if (File.Exists(Path)) File.Delete(Path);
        }
    }
}
