using System.Runtime.CompilerServices;
using System.Threading.Channels;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Tests;

public sealed class ListeningReasoningTests
{
    [Theory] [InlineData(SuggestionMode.Reply)] [InlineData(SuggestionMode.Recap)] [InlineData(SuggestionMode.FollowUp)]
    public async Task ModesStreamSanitizedTextAndBuildRequestsFromSettings(SuggestionMode mode)
    {
        var provider = new ControlledReasoning();
        var settings = new AppSettings { Scenario = ScenarioProfile.Meeting, AnswerLanguage = AnswerLanguage.Chinese,
            BilingualAnswers = true, AdditionalAnswerInstructions = "简洁回答", KnowledgeMode = KnowledgeMode.Hybrid };
        var transcript = Conversation(); transcript.SetPartial("最新问题？", Speaker.Them);
        await using var session = Session(() => provider, transcript, settings);
        session.Request(mode);
        var request = await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(mode, request.Mode); Assert.Equal(mode, session.Snapshot.LastRequestedMode);
        Assert.Equal(mode switch { SuggestionMode.Reply => "最新问题？", SuggestionMode.Recap => "Summarize the recent conversation, decisions and unresolved questions.", _ => "Suggest one useful follow-up question based on this conversation." }, request.Query.Question);
        Assert.Contains("Them: 已定稿问题？", request.Conversation); Assert.Contains("You: 已经回答", request.Conversation);
        Assert.EndsWith("Them: 最新问题？", request.Conversation);
        Assert.Equal(settings.Scenario, request.Scenario); Assert.Equal(settings.AnswerLanguage, request.AnswerLanguage);
        Assert.True(request.BilingualAnswers); Assert.Equal(settings.AdditionalAnswerInstructions, request.AdditionalAnswerInstructions);
        Assert.Empty(request.Sources); Assert.Contains("No local evidence retrieved.", request.Input);
        Assert.True(session.Snapshot.SuggestionIsLoading);
        await request.OnStreamProgress!(PipelineStage.ReasoningStarted, PipelineTrace.Uptime);
        Assert.Equal("模型正在思考…", session.Snapshot.SuggestionStatus);
        provider.Send("第一段[S");
        await Until(session, s => s.SuggestionText == "第一段");
        var partial = session.Snapshot;
        Assert.True(partial.SuggestionIsLoading); Assert.Equal("正在生成回答…", partial.SuggestionStatus);
        provider.Send("1]，第二段"); provider.Complete();
        await Until(session, s => !s.SuggestionIsLoading);
        Assert.Equal("第一段，第二段", session.Snapshot.SuggestionText); Assert.Equal("回答已完成", session.Snapshot.SuggestionStatus);
        Assert.Null(session.Snapshot.SuggestionError); Assert.Equal("第一段", partial.SuggestionText);
    }

    [Fact] public async Task SecondRequestCancelsOldStreamAndIgnoresLateDeltasAndProgress()
    {
        var first = new ControlledReasoning(ignoreCancellation: true); var second = new ControlledReasoning();
        var providers = new Queue<ControlledReasoning>([first, second]);
        await using var session = Session(() => providers.Dequeue());
        session.Request(SuggestionMode.Reply);
        var oldRequest = await first.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        first.Send("旧答案"); await Until(session, s => s.SuggestionText == "旧答案");
        session.Request(SuggestionMode.Recap);
        await second.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await first.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(session.Snapshot.SuggestionText);
        second.Send("新答案"); await Until(session, s => s.SuggestionText == "新答案");
        var current = session.Snapshot;
        await oldRequest.OnStreamProgress!(PipelineStage.ReasoningStarted, PipelineTrace.Uptime);
        first.Send("迟到文本"); first.Complete(); await first.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(current, session.Snapshot);
        second.Complete(); await Until(session, s => !s.SuggestionIsLoading);
        Assert.Equal("新答案", session.Snapshot.SuggestionText); Assert.Equal(SuggestionMode.Recap, session.Snapshot.LastRequestedMode);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task StopAndDisposeCancelEvenUncooperativeStreamWithoutWaitingForIt(bool dispose)
    {
        var provider = new ControlledReasoning(ignoreCancellation: true);
        await using var session = Session(() => provider);
        session.Request(SuggestionMode.Reply); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("部分答案"); await Until(session, s => s.SuggestionText == "部分答案");
        if (dispose) await session.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        else await session.StopAsync().WaitAsync(TimeSpan.FromSeconds(5));
        await provider.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("回答已取消", session.Snapshot.SuggestionStatus); Assert.False(session.Snapshot.SuggestionIsLoading);
        var stopped = session.Snapshot;
        provider.Send("迟到"); provider.Complete(); await provider.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(stopped, session.Snapshot); Assert.Equal("部分答案", stopped.SuggestionText);
        if (dispose) { session.Request(SuggestionMode.Recap); Assert.Equal(stopped, session.Snapshot); }
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task EmptyConversationRefusesBeforeFactoryEvenWithIncludeConversationOff(bool includeConversation)
    {
        var calls = 0;
        await using var session = Session(() => { calls++; return new ControlledReasoning(); }, new(), new() { IncludeConversation = includeConversation });
        session.Request(SuggestionMode.Reply);
        Assert.Equal("还没有对话。先开始听写，或等有转写后再请求。", session.Snapshot.SuggestionStatus);
        Assert.Empty(session.Snapshot.SuggestionText); Assert.False(session.Snapshot.SuggestionIsLoading); Assert.Equal(0, calls);
    }

    [Fact] public async Task PartialThemAloneIsEnoughAndLatestYouFallsBackToReplyPrompt()
    {
        var provider = new ControlledReasoning(); var transcript = new TranscriptStore(); transcript.SetPartial("正在问的问题", Speaker.Them);
        await using (var session = Session(() => provider, transcript))
        {
            session.Request(SuggestionMode.Reply); var request = await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal("正在问的问题", request.Query.Question); Assert.Equal("Them: 正在问的问题", request.Conversation);
        }
        var own = new TranscriptStore(); own.Commit("我的发言", Speaker.You);
        var fallback = new ControlledReasoning();
        await using var ownSession = Session(() => fallback, own);
        ownSession.Request(SuggestionMode.Reply);
        Assert.Equal("Help me answer the latest substantive question in this conversation.", (await fallback.Started.Task.WaitAsync(TimeSpan.FromSeconds(5))).Query.Question);
    }

    [Fact] public async Task IncludeConversationFalseAlsoExcludesRetrievalSemanticContext()
    {
        var transcript = new TranscriptStore(); transcript.Commit("context must stay local", Speaker.You); transcript.SetPartial("为什么？", Speaker.Them);
        var provider = new ControlledReasoning();
        await using var session = Session(() => provider, transcript, new() { IncludeConversation = false });
        session.Request(SuggestionMode.Reply);
        var request = await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(request.Conversation); Assert.DoesNotContain("context must stay local", request.Input);
        Assert.DoesNotContain("context must stay local", request.Query.Semantic); Assert.Equal("为什么？", request.Query.Question);
    }

    [Fact] public async Task MissingKeyFactorySurfacesChineseStatusWithoutFabricatedAnswer()
    {
        await using var session = Session(() => throw new CopilotException(ReasoningProviderFactory.MissingKeyMessage));
        session.Request(SuggestionMode.Reply);
        await Until(session, s => !s.SuggestionIsLoading);
        Assert.Equal("请先配置分析服务 API 密钥", session.Snapshot.SuggestionStatus);
        Assert.Equal("请先配置分析服务 API 密钥", session.Snapshot.SuggestionError); Assert.Empty(session.Snapshot.SuggestionText);
    }

    [Fact] public async Task ProviderErrorUsesSafeMessageAndRetainsPartialAnswer()
    {
        var provider = new ControlledReasoning();
        await using var session = Session(() => provider);
        session.Request(SuggestionMode.Reply); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("已生成"); await Until(session, s => s.SuggestionText == "已生成");
        var error = new ServiceHTTPFailure(401, System.Text.Encoding.UTF8.GetBytes("""{"error":{"message":"untrusted body"}}"""));
        provider.Complete(error); await Until(session, s => !s.SuggestionIsLoading);
        Assert.Equal(error.Message, session.Snapshot.SuggestionError); Assert.Equal("回答失败：" + error.Message, session.Snapshot.SuggestionStatus);
        Assert.Equal("已生成", session.Snapshot.SuggestionText);
    }

    [Fact] public async Task TimeoutFailsAndCancelsEvenIfProviderIgnoresCancellation()
    {
        var provider = new ControlledReasoning(ignoreCancellation: true);
        await using var session = Session(() => provider, timeout: TimeSpan.FromMilliseconds(200));
        session.Request(SuggestionMode.Reply); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Until(session, s => s.SuggestionError is not null);
        await provider.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("回答超时，请手动重试。", session.Snapshot.SuggestionError);
        Assert.Equal("回答超时，请手动重试。", session.Snapshot.SuggestionStatus); Assert.False(session.Snapshot.SuggestionIsLoading);
        var expired = session.Snapshot;
        provider.Send("超时后的文本"); provider.Complete(); await provider.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(expired, session.Snapshot);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task KnowledgeBaseOnlyUsesExistingMissingEvidenceWithoutCallingFactory(bool bilingual)
    {
        var calls = 0;
        await using var session = Session(() => { calls++; throw new InvalidOperationException(); }, settings: new()
        { KnowledgeMode = KnowledgeMode.KnowledgeBaseOnly, AnswerLanguage = AnswerLanguage.English, BilingualAnswers = bilingual });
        session.Request(SuggestionMode.Reply); await Until(session, s => !s.SuggestionIsLoading);
        var expected = bilingual ? AnswerLanguage.Chinese.MissingEvidence("已定稿问题？") + "\n" + AnswerLanguage.English.MissingEvidence("已定稿问题？") : AnswerLanguage.English.MissingEvidence("已定稿问题？");
        Assert.Equal(expected, session.Snapshot.SuggestionText); Assert.Equal("未找到知识库证据", session.Snapshot.SuggestionStatus);
        Assert.Null(session.Snapshot.SuggestionError); Assert.Equal(0, calls);
    }

    [Theory] [InlineData(KnowledgeMode.General)] [InlineData(KnowledgeMode.Hybrid)]
    public async Task NonStrictModesCallProviderWithEmptySources(KnowledgeMode mode)
    {
        var provider = new ControlledReasoning();
        await using var session = Session(() => provider, settings: new() { KnowledgeMode = mode });
        session.Request(SuggestionMode.Reply); var request = await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(mode, request.KnowledgeMode); Assert.Empty(request.Sources); Assert.Contains("No local evidence retrieved.", request.Input);
    }

    [Theory] [InlineData(SuggestionMode.Recap)] [InlineData(SuggestionMode.FollowUp)]
    public async Task DisabledModesDoNotCancelActiveRequestOrCallFactory(SuggestionMode mode)
    {
        var provider = new ControlledReasoning(); var calls = 0;
        await using var session = Session(() => { calls++; return provider; }, settings: new() { RecapEnabled = false, FollowUpEnabled = false });
        session.Request(SuggestionMode.Reply); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var before = session.Snapshot; session.Request(mode);
        Assert.Equal(before, session.Snapshot); Assert.Equal(1, calls); Assert.False(provider.Cancelled.Task.IsCompleted);
    }

    [Fact] public async Task StartingNewListeningRunCancelsSuggestionFromPreviousTranscript()
    {
        var provider = new ControlledReasoning(ignoreCancellation: true);
        await using var session = Session(() => provider);
        session.Request(SuggestionMode.Reply); await provider.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await session.StartAsync(); await provider.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        provider.Send("旧会话"); provider.Complete(); await provider.Disposed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Listening, session.Snapshot.State); Assert.Empty(session.Snapshot.SuggestionText);
        Assert.Empty(session.Snapshot.Lines); Assert.Null(session.Snapshot.SuggestionStatus);
    }

    private static TranscriptStore Conversation()
    {
        var transcript = new TranscriptStore(); transcript.Commit("已定稿问题？", Speaker.Them); transcript.Commit("已经回答", Speaker.You); return transcript;
    }
    private static ListeningSession Session(Func<IReasoningProvider> factory, TranscriptStore? transcript = null, AppSettings? settings = null, TimeSpan? timeout = null) =>
        new(new FakeAudioFactory(new(), new()), (speaker, _) =>
        {
            var live = new FakeLiveProvider(speaker); return new(live, live.UpdateTerms);
        }, settings ?? new(), transcript ?? Conversation(), reasoningFactory: factory, answerTimeout: timeout);

    private static async Task Until(ListeningSession session, Func<ListeningSnapshot, bool> condition)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed() { if (condition(session.Snapshot)) done.TrySetResult(); }
        session.Changed += Changed;
        try { Changed(); await done.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { session.Changed -= Changed; }
    }

    private sealed class ControlledReasoning(bool ignoreCancellation = false) : IReasoningProvider
    {
        private readonly Channel<string> deltas = Channel.CreateUnbounded<string>();
        public TaskCompletionSource<AnswerRequest> Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Disposed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Send(string delta) => deltas.Writer.TryWrite(delta);
        public void Complete(Exception? error = null) => deltas.Writer.TryComplete(error);
        public async IAsyncEnumerable<string> Stream(AnswerRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            using var registration = cancellationToken.Register(() => Cancelled.TrySetResult());
            Started.TrySetResult(request);
            try
            {
                await foreach (var delta in deltas.Reader.ReadAllAsync(ignoreCancellation ? default : cancellationToken)) yield return delta;
            }
            finally { Disposed.TrySetResult(); }
        }
    }
}
