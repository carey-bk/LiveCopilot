using System.Collections.Concurrent;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using System.Text.Json;
using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Sessions;
using LiveCopilot.Testing;

namespace LiveCopilot.Platform.Tests;

public sealed class OpenAIListeningTests
{
    [Theory] [InlineData(OperatingMode.Remote)] [InlineData(OperatingMode.InPerson)]
    public async Task CompleteQuestionAutomaticallyAnswersAndArchivesWithDelegationFeedback(OperatingMode mode)
    {
        await using var test = new Fixture(mode);
        await test.Start();
        Assert.Equal(24000, test.Session.Snapshot.SampleRate);
        Assert.Equal(mode == OperatingMode.Remote ? 2 : 1, test.Audio.Requested.Count);
        var peer = test.QuestionPeer;
        test.Sources[0].Push(Signals.Float(480, 2, (_, _) => .4f));
        var audio = await peer.NextAsync("session.input_audio.append");
        Assert.Equal(480, Convert.FromBase64String(audio.GetProperty("audio").GetString()!).Length);
        await Transcript(peer, "q1", "为什么选择这个方案？");
        await Until(() => test.Session.Snapshot.Lines.Count == 1);
        Assert.Empty(test.Reasoning.Calls); // A transcript alone cannot trigger.
        await Delegate(peer, "d1");
        var call = await test.Reasoning.Next();
        Assert.Equal("为什么选择这个方案？", call.Request.Query.Question);
        Assert.Equal(ScenarioProfile.Meeting, call.Request.Scenario);
        Assert.Contains(mode == OperatingMode.InPerson ? "Room:" : "Them:", call.Request.Conversation);
        call.Finish("测试回答，不调用 API。");
        await Until(() => test.Session.Snapshot.SuggestionText.Length > 0 && !test.Session.Snapshot.SuggestionIsLoading);
        var thinking = await peer.NextAsync("session.thinking.append");
        Assert.Equal("d1", thinking.GetProperty("delegation_id").GetString());
        Assert.Contains("Assistance completed in the text overlay", thinking.GetProperty("content").GetString());
        await Delegate(peer, "d1"); await Delegate(peer, "d2");
        await Task.Delay(800); Assert.Single(test.Reasoning.Calls);
        peer.FinalTranscript = "结束时转写。";
        await test.Session.StopAsync();
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State); Assert.Null(test.Session.Snapshot.Error);
        Assert.Contains(test.Session.Snapshot.Lines, line => line.Content.Contains("结束时转写。", StringComparison.Ordinal));
        var history = Assert.Single(test.History.Sessions);
        Assert.True(Assert.Single(history.Answers!).Automatic);
        Assert.Equal("q1", history.Answers![0].SourceFragmentId);
        Assert.Equal("测试回答，不调用 API。", history.Answers![0].Text);
    }

    [Fact]
    public async Task DelegationBeforeTranscriptWaitsForCompleteText()
    {
        await using var test = new Fixture(); await test.Start();
        await Delegate(test.QuestionPeer, "early"); await Task.Delay(600); Assert.Empty(test.Reasoning.Calls);
        await Transcript(test.QuestionPeer, "t1", "为什么以及"); await Task.Delay(650); Assert.Empty(test.Reasoning.Calls);
        await Transcript(test.QuestionPeer, "t1", "为什么选择这个方案？", completed: true);
        var call = await test.Reasoning.Next(); Assert.Equal("为什么选择这个方案？", call.Request.Query.Question);
    }

    [Theory] [InlineData("disabled")] [InlineData("own")] [InlineData("answered")] [InlineData("stop")]
    public async Task DisabledOwnAnsweredAndStoppedQuestionsNeverGenerate(string reason)
    {
        await using var test = new Fixture(automatic: reason != "disabled"); await test.Start();
        var peer = reason == "own" ? test.You! : test.QuestionPeer;
        await Transcript(peer, "q1", "请解释这个设计方案？");
        await Until(() => test.Session.Snapshot.Lines.Count > 0);
        if (reason == "answered")
        {
            await Transcript(test.You!, "a1", "我已经解释过了。", start: 2000);
            var feedback = await test.QuestionPeer.NextAsync("session.thinking.append");
            Assert.Equal(JsonValueKind.Null, feedback.GetProperty("delegation_id").ValueKind);
            Assert.Contains("You said:", feedback.GetProperty("content").GetString());
        }
        await Delegate(peer, "d1");
        if (reason == "stop") await test.Session.StopAsync();
        await Task.Delay(850); Assert.Empty(test.Reasoning.Calls);
    }

    [Theory]
    [InlineData(ContinuousQuestionPolicy.Fast)] [InlineData(ContinuousQuestionPolicy.Smart)] [InlineData(ContinuousQuestionPolicy.Complete)]
    public async Task FollowUpWaitsForCurrentAnswerAndHonorsQueuePolicy(ContinuousQuestionPolicy policy)
    {
        await using var test = new Fixture(policy: policy); await test.Start();
        await Transcript(test.QuestionPeer, "q1", "为什么选择这个方案？"); await Delegate(test.QuestionPeer, "d1");
        var first = await test.Reasoning.Next();
        await Transcript(test.QuestionPeer, "q2", "还有哪些替代方案？", start: 3000); await Delegate(test.QuestionPeer, "d2");
        await Task.Delay(800); Assert.Single(test.Reasoning.Calls); Assert.False(first.Token.IsCancellationRequested);
        first.Finish("第一条回答。");
        var next = await test.Reasoning.Next(); Assert.Contains("还有哪些替代方案？", next.Request.Query.Question);
        next.Finish("第二条回答。");
        await Until(() => test.Session.Snapshot.SuggestionText == "第二条回答。" && !test.Session.Snapshot.SuggestionIsLoading);
        Assert.Equal(2, test.Reasoning.Calls.Count);
    }

    [Fact]
    public async Task ServerErrorStopsCaptureAndReportsSanitizedFailure()
    {
        await using var test = new Fixture(); await test.Start();
        await test.QuestionPeer.SendAsync(new { type = "error", error = new { code = "invalid_api_key", message = "private speech fake-key" } });
        await Until(() => test.Session.Snapshot.State == ListeningState.Failed && !test.Session.Snapshot.IsStopping);
        Assert.Equal(ServiceHTTPFailureKind.Authentication.Message(), test.Session.Snapshot.Error);
        Assert.All(test.Sources, source => Assert.Equal(1, source.Stops));
    }

    [Fact]
    public async Task DisconnectExhaustionFailsAndRecoveryKeepsSessionListening()
    {
        await using var test = new Fixture(retries: 1); await test.Start();
        test.QuestionPeer.Abort();
        var recovered = await test.Server.NextAsync(); await recovered.NextAsync("session.start");
        await Until(() => test.Session.Snapshot.System.Status is null);
        Assert.Equal(ListeningState.Listening, test.Session.Snapshot.State); Assert.Null(test.Session.Snapshot.Error);
        recovered.Abort();
        await Until(() => test.Session.Snapshot.State == ListeningState.Failed && !test.Session.Snapshot.IsStopping);
        Assert.Equal(OpenAILiveProtocol.ConnectionFailureMessage, test.Session.Snapshot.Error);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task CancellationAndStopDuringStartupNeverStartCapture(bool cancel)
    {
        await using var test = new Fixture(); test.Server.AutoReady = false;
        using var token = new CancellationTokenSource();
        var start = test.Session.StartAsync(token.Token);
        var peer = await test.Server.NextAsync(); await peer.NextAsync("session.start");
        if (cancel) token.Cancel(); else await test.Session.StopAsync();
        await start.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Empty(test.Audio.Requested); Assert.Null(test.Session.Snapshot.Error);
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State);
    }

    [Fact]
    public async Task MissingKeyRefusesBeforeConnectionAndCapture()
    {
        await using var test = new Fixture(missingKey: true); await test.Session.StartAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains(OpenAILiveProvider.MissingKeyMessage, test.Session.Snapshot.Error);
        Assert.Empty(test.Audio.Requested); Assert.Empty(test.Server.Requests);
    }

    [Fact]
    public async Task StartupTimeoutReportsErrorWithoutStartingCapture()
    {
        await using var test = new Fixture(startupTimeout: TimeSpan.FromMilliseconds(200)); test.Server.AutoReady = false;
        await test.Session.StartAsync().WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State); Assert.Empty(test.Audio.Requested);
        Assert.Equal(OpenAILiveProtocol.StartupTimeoutMessage, test.Session.Snapshot.Error);
    }

    [Fact]
    public void SettingsPriceTagsAndCloudAvailabilityRoundTripWithoutConnecting()
    {
        var preferences = new MemoryPreferenceStore(); var keys = new MemoryCredentialStore();
        var model = new SettingsViewModel(preferences, keys, new HotkeyStore(preferences));
        model.ListeningService = ListeningService.OpenAI; model.Language = AppLanguage.SimplifiedChinese;
        Assert.True(model.IsOpenAIListening); Assert.False(model.IsLocalListening);
        Assert.Equal(new[] { "云端", "多语言", "按量计费" }, model.SpeechChips);
        Assert.Equal(ServiceGuide.LivePrice("gpt-live-1", AppLanguage.SimplifiedChinese), model.LivePrice);
        Assert.Contains("$0.10", model.LivePrice); Assert.Contains("静音", model.LivePrice);
        model.AutomaticSuggestions = false; Assert.True(model.Save());
        var saved = AppSettings.Load(preferences); Assert.Equal(ListeningService.OpenAI, saved.ListeningService);
        Assert.True(saved.RequiresOpenAIKey); Assert.False(saved.AutomaticSuggestions);
        model.Language = AppLanguage.English; Assert.Contains("Connected silence", model.LivePrice);
        Assert.Null(keys.Read(CredentialReference.Live));
    }

    private static Task Transcript(LocalLiveServer.Peer peer, string id, string text, int start = 0, bool completed = false) =>
        completed ? peer.SendAsync(new { type = "session.input_transcript.completed", event_id = id, transcript = text, start_ms = start, end_ms = start + 700 }) :
            peer.SendAsync(new { type = "session.input_transcript.delta", event_id = id, delta = text, start_ms = start, end_ms = start + 500 });
    private static Task Delegate(LocalLiveServer.Peer peer, string id) => peer.SendAsync(new { type = "session.delegation.created", delegation = new { target = "client", id } });
    private static async Task Until(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!condition()) await Task.Delay(10, timeout.Token);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly string directory = Path.Combine(Path.GetTempPath(), "line13-session-" + Guid.NewGuid());
        private readonly OperatingMode mode;
        public LocalLiveServer Server { get; } = new();
        public FakeAudioSource[] Sources { get; }
        public FakeAudioFactory Audio { get; }
        public Reasoning Reasoning { get; } = new();
        public ListeningSession Session { get; }
        public SessionStore History { get; }
        public LocalLiveServer.Peer QuestionPeer { get; private set; } = null!;
        public LocalLiveServer.Peer? You { get; private set; }
        public Fixture(OperatingMode mode = OperatingMode.Remote, bool automatic = true, bool missingKey = false,
            ContinuousQuestionPolicy policy = ContinuousQuestionPolicy.Smart, int retries = 0, TimeSpan? startupTimeout = null)
        {
            this.mode = mode;
            Sources = mode == OperatingMode.Remote ? [new(), new()] : [new()]; Audio = new(Sources);
            History = new(directory);
            var settings = new AppSettings { ListeningService = ListeningService.OpenAI, Mode = mode, AutomaticSuggestions = automatic,
                Scenario = ScenarioProfile.Meeting, ContinuousQuestionPolicy = policy, KnowledgeMode = KnowledgeMode.General };
            var credentials = new MemoryCredentialStore(); if (!missingKey) credentials.Save(CredentialReference.Live, "fake-line13-shared-key");
            var options = new OpenAILiveOptions { Endpoint = Server.Endpoint, StartupTimeout = startupTimeout ?? TimeSpan.FromSeconds(3),
                CloseTimeout = TimeSpan.FromMilliseconds(300), MaximumRetries = retries, RetryDelay = TimeSpan.FromMilliseconds(20) };
            Session = new(Audio, (_, _) => throw new InvalidOperationException("Configured factory required"), settings, sessions: History,
                reasoningFactory: () => Reasoning, configuredProviderFactory: (speaker, selection) =>
                    new(OpenAILiveProvider.FromCredentials(selection, credentials, speaker, options)));
        }
        public async Task Start()
        {
            await Session.StartAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(ListeningState.Listening, Session.Snapshot.State);
            for (var i = 0; i < (mode == OperatingMode.Remote ? 2 : 1); i++)
            {
                var peer = await Server.NextAsync(); var start = await peer.NextAsync("session.start");
                if (start.GetProperty("session").GetProperty("instructions").GetString()!.Contains("own microphone", StringComparison.Ordinal)) You = peer;
                else QuestionPeer = peer;
            }
        }
        public async ValueTask DisposeAsync()
        {
            await Session.DisposeAsync(); await Server.DisposeAsync();
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
    private sealed class Reasoning : IReasoningProvider
    {
        private readonly Channel<Call> calls = Channel.CreateUnbounded<Call>();
        public ConcurrentQueue<Call> Calls { get; } = new();
        public async Task<Call> Next() => await calls.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        public async IAsyncEnumerable<string> Stream(AnswerRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            var call = new Call(request, cancellationToken); Calls.Enqueue(call); calls.Writer.TryWrite(call);
            yield return await call.Result.Task.WaitAsync(cancellationToken);
        }
        public sealed record Call(AnswerRequest Request, CancellationToken Token)
        {
            public TaskCompletionSource<string> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
            public void Finish(string text) => Result.TrySetResult(text);
        }
    }
}
