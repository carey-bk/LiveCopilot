using System.Collections.Concurrent;
using System.IO;
using LiveCopilot.Platform.Audio;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Tests;

public sealed class ListeningSessionTests
{
    [Fact] public async Task ConstructionDoesNotCreateProvidersOrCaptureAndStopIsSafe()
    {
        await using var test = new SessionFixture();
        Assert.Equal(ListeningState.Idle, test.Session.Snapshot.State);
        Assert.Empty(test.Factory.Requested); Assert.Empty(test.Providers);
        await test.Session.StopAsync(); await test.Session.StopAsync();
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State);
        Assert.Empty(test.Factory.Requested); Assert.Empty(test.Providers);
        Assert.False(Directory.Exists(test.Root));
    }

    [Theory] [InlineData(ListeningService.Zipformer)] [InlineData(ListeningService.Paraformer)]
    public async Task LocalStartConfiguresBothPathsAndRoutesTenMillisecondsOfMonoPcm(ListeningService service)
    {
        var system = new FakeAudioSource(); var mic = new FakeAudioSource();
        await using var test = new SessionFixture(new() { ListeningService = service }, system, mic);
        await test.Session.StartAsync();
        var view = test.Session.Snapshot;
        Assert.Equal(ListeningState.Listening, view.State); Assert.Equal(16000, view.SampleRate);
        Assert.True(view.System.Capturing); Assert.True(view.Microphone.Capturing);
        Assert.Equal(system.Description, view.System.SourceDescription); Assert.Equal(mic.Description, view.Microphone.SourceDescription);
        Assert.Equal("Observed fake backend", view.System.Backend);
        Assert.Equal(new[] { AudioInput.System, AudioInput.Microphone }, test.Factory.Requested);
        system.Push(Signals.Float(480, 2, (_, c) => c == 0 ? .6f : .2f));
        Assert.Empty(test.You.Audio);
        mic.Push(Signals.Float(480, 2, (_, c) => c == 0 ? -.6f : -.2f));
        var them = Assert.Single(test.Them.Audio); var you = Assert.Single(test.You.Audio);
        Assert.Equal(10 * 32, them.Length); Assert.Equal(10 * 32, you.Length);
        Assert.InRange(Signals.Samples(them)[^1], 13000, 13200);
        Assert.InRange(Signals.Samples(you)[^1], -13200, -13000);
        Assert.Equal(Speaker.Them, test.Them.Speaker); Assert.Equal(Speaker.You, test.You.Speaker);
    }

    [Theory] [InlineData(ListeningService.OpenAI)] [InlineData(ListeningService.Apple)]
    public async Task UnsupportedServicesRefuseBeforeAnyProviderOrCapture(ListeningService service)
    {
        await using var test = new SessionFixture(new() { ListeningService = service });
        await test.Session.StartAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains("尚未接入", test.Session.Snapshot.Error);
        Assert.Empty(test.Factory.Requested); Assert.Empty(test.Providers);
    }

    [Fact] public async Task WaitsForBothReadyEventsBeforeOpeningAudio()
    {
        await using var test = new SessionFixture();
        test.ConfigureProvider = provider => provider.AutoReady = false;
        var start = test.Session.StartAsync();
        Assert.Equal(ListeningState.Starting, test.Session.Snapshot.State);
        Assert.Empty(test.Factory.Requested);
        test.Them.Emit(new LiveEvent.Ready());
        Assert.False(start.IsCompleted); Assert.Empty(test.Factory.Requested);
        test.You.Emit(new LiveEvent.Ready());
        await start.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Listening, test.Session.Snapshot.State);
    }

    [Theory] [InlineData(ListeningService.Zipformer)] [InlineData(ListeningService.Paraformer)]
    public async Task TermsAreConfiguredBeforeConnectOnlyForZipformer(ListeningService service)
    {
        var settings = new AppSettings { ListeningService = service, ProfessionalTerms = ["LiveCopilot", "测试术语"] };
        await using var test = new SessionFixture(settings);
        await test.Session.StartAsync();
        foreach (var provider in test.Providers)
        {
            Assert.Equal(service == ListeningService.Zipformer ? new[] { "terms", "connect" } : new[] { "connect" }, provider.Calls);
            Assert.Equal(service == ListeningService.Zipformer ? settings.ProfessionalTerms : [], provider.Terms);
        }
    }

    [Fact] public async Task FinalFragmentsMergeAndPartialsAndSpeechBelongToTheirPaths()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        test.Them.Emit(new LiveEvent.PartialTranscript("对方草稿"));
        test.You.Emit(new LiveEvent.PartialTranscript("我的草稿"));
        test.You.Emit(new LiveEvent.SpeechActivity(true));
        var before = test.Session.Snapshot;
        Assert.Equal("对方草稿", before.PartialThem); Assert.Equal("我的草稿", before.PartialYou);
        Assert.False(before.System.SpeechActive); Assert.True(before.Microphone.SpeechActive);
        test.Them.Emit(Final("first", "你好", 0, 100));
        test.Them.Emit(Final("second", " 世界", 150, 200));
        Assert.Equal("你好 世界", Assert.Single(test.Transcript.Lines).Content);
        Assert.Equal(Speaker.Them, test.Transcript.Lines[0].Speaker);
        Assert.Equal("", test.Session.Snapshot.PartialThem);
        test.You.Emit(Final("own", "收到", 200, 300));
        Assert.Equal(Speaker.You, test.Session.Snapshot.Lines[1].Speaker);
        Assert.Equal(3, test.Transcript.FragmentRevisions.Count);
        test.You.Emit(new LiveEvent.PartialTranscript("新的草稿"));
        test.You.Emit(new LiveEvent.PartialTranscript(""));
        test.You.Emit(new LiveEvent.SpeechActivity(false));
        Assert.Equal("", test.Session.Snapshot.PartialYou); Assert.False(test.Session.Snapshot.Microphone.SpeechActive);
        Assert.Empty(before.Lines); // Previously published snapshots stay immutable.
    }

    [Fact] public async Task ConcurrentProviderEventsSerializeTheStore()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        await Task.WhenAll(Task.Run(() => EmitMany(test.Them)), Task.Run(() => EmitMany(test.You)));
        Assert.Equal(200, test.Transcript.FragmentRevisions.Count);
        Assert.Equal(100, test.Transcript.FragmentRevisions.Count(f => f.Speaker == Speaker.Them));
        Assert.Equal(100, test.Transcript.FragmentRevisions.Count(f => f.Speaker == Speaker.You));
        static void EmitMany(FakeLiveProvider provider)
        { for (var i = 0; i < 100; i++) provider.Emit(Final(provider.Speaker + "-" + i, "词", i * 100, i * 100 + 50)); }
    }

    [Fact] public async Task FailureStopsBothPathsAndRestartUsesFreshProvidersIgnoringStaleEvents()
    {
        var sources = Enumerable.Range(0, 4).Select(_ => new FakeAudioSource()).ToArray();
        await using var test = new SessionFixture(null, sources);
        await test.Session.StartAsync();
        var old = test.Them; var late = old.OnEvent!;
        var failed = Until(test.Session, s => s.State == ListeningState.Failed && !s.IsStopping);
        old.Emit(new LiveEvent.Failed("识别运行失败"));
        await failed;
        Assert.Equal("识别运行失败", test.Session.Snapshot.Error);
        Assert.Equal(1, sources[0].Disposals); Assert.Equal(1, sources[1].Disposals);
        Assert.Equal(1, test.Them.Disconnects); Assert.Equal(1, test.You.Disconnects);
        Assert.False(test.Session.Snapshot.System.Capturing); Assert.False(test.Session.Snapshot.Microphone.Capturing);
        await test.Session.StartAsync();
        Assert.Equal(4, test.Providers.Count); Assert.NotSame(old, test.Them);
        late(Final("late", "不应显示", 0, 100)); late(new LiveEvent.Failed("旧错误"));
        Assert.Empty(test.Session.Snapshot.Lines); Assert.Null(test.Session.Snapshot.Error);
        Assert.Equal(ListeningState.Listening, test.Session.Snapshot.State);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task ProviderFailureBeforeReadyRollsBackWithoutCapture(bool second)
    {
        await using var test = new SessionFixture();
        test.ConfigureProvider = provider =>
        {
            provider.AutoReady = false;
            if ((provider.Speaker == Speaker.You) == second)
                provider.OnConnect = () => provider.Emit(new LiveEvent.Failed("Local model is missing, corrupt, or could not run."));
        };
        await test.Session.StartAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains("missing, corrupt", test.Session.Snapshot.Error);
        Assert.Empty(test.Factory.Requested);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
    }

    [Theory] [InlineData(AudioFailureKind.PermissionDenied)] [InlineData(AudioFailureKind.NoDevice)] [InlineData(AudioFailureKind.StartFailed)]
    public async Task MicrophoneStartFailureRollsBackSystem(AudioFailureKind kind)
    {
        var system = new FakeAudioSource();
        var mic = new FakeAudioSource { StartError = new AudioSourceException(kind, "麦克风无法启动：" + kind) };
        await using var test = new SessionFixture(null, system, mic);
        await test.Session.StartAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Equal("麦克风无法启动：" + kind, test.Session.Snapshot.Error);
        Assert.Equal(1, system.Stops); Assert.Equal(1, system.Disposals); Assert.Equal(1, mic.Disposals);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
    }

    [Theory] [InlineData("factory")] [InlineData("terms")] [InlineData("connect")]
    public async Task ProviderSetupExceptionDisconnectsEveryCreatedProviderBeforeAnyCapture(string stage)
    {
        var audio = new FakeAudioFactory(new(), new());
        var providers = new List<FakeLiveProvider>();
        await using var session = new ListeningSession(audio, (speaker, _) =>
        {
            if (speaker == Speaker.You && stage == "factory") throw new InvalidOperationException("factory failed");
            var provider = new FakeLiveProvider(speaker);
            providers.Add(provider);
            provider.OnConnect = () =>
            {
                if (speaker == Speaker.You && stage == "connect") throw new InvalidOperationException("connect failed");
            };
            return new(provider, terms =>
            {
                if (speaker == Speaker.You && stage == "terms") throw new InvalidOperationException("terms failed");
                provider.UpdateTerms(terms);
            });
        }, new());
        await session.StartAsync();
        Assert.Equal(ListeningState.Failed, session.Snapshot.State);
        Assert.Contains(stage + " failed", session.Snapshot.Error);
        Assert.Empty(audio.Requested);
        Assert.All(providers, p => Assert.Equal(1, p.Disconnects));
    }

    [Fact] public async Task AsynchronousModelFailureInterruptsOtherProvidersPendingReadiness()
    {
        await using var test = new SessionFixture();
        test.ConfigureProvider = p => p.AutoReady = false;
        var start = test.Session.StartAsync();
        await Task.Run(() => test.You.Emit(new LiveEvent.Failed("模型加载失败")));
        await start.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Equal("模型加载失败", test.Session.Snapshot.Error);
        Assert.Empty(test.Factory.Requested);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
    }

    [Fact] public async Task SystemStartFailureNeverStartsMicrophone()
    {
        var mic = new FakeAudioSource();
        await using var test = new SessionFixture(null, new() { StartError = new Exception("System start failed") }, mic);
        await test.Session.StartAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Equal(0, mic.Starts); Assert.Single(test.Factory.Requested);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task FailureFromInsidePcmCallbackNeverWaitsOnItsOwnCapture(bool throws)
    {
        var system = new FakeAudioSource(); var mic = new FakeAudioSource();
        await using var test = new SessionFixture(null, system, mic);
        await test.Session.StartAsync();
        test.Them.OnAudio = () =>
        {
            if (throws) throw new InvalidOperationException("PCM rejected");
            test.Them.Emit(new LiveEvent.Failed("PCM rejected"));
        };
        var failed = Until(test.Session, s => s.State == ListeningState.Failed);
        await Task.Run(() => system.Push(Signals.Float(480, 2, (_, _) => .5f))).WaitAsync(TimeSpan.FromSeconds(5));
        await failed;
        Assert.Contains("PCM rejected", test.Session.Snapshot.Error);
        Assert.Equal(1, system.Disposals); Assert.Equal(1, mic.Disposals);
    }

    [Fact] public async Task AudioStreamFailureStopsBothPaths()
    {
        var system = new FakeAudioSource(); var mic = new FakeAudioSource();
        await using var test = new SessionFixture(null, system, mic);
        await test.Session.StartAsync();
        var failed = Until(test.Session, s => s.State == ListeningState.Failed);
        system.Fail(AudioFailureKind.StreamFailed, "设备断开");
        await failed;
        Assert.Equal("设备断开", test.Session.Snapshot.Error); Assert.Equal(1, mic.Disposals);
    }

    [Fact] public async Task RepeatedStartAndStopNeverDoubleConnectOrSave()
    {
        await using var test = new SessionFixture();
        await Task.WhenAll(test.Session.StartAsync(), test.Session.StartAsync());
        Assert.Equal(2, test.Providers.Count); Assert.All(test.Providers, p => Assert.Equal(1, p.Connects));
        test.Them.Emit(Final("saved", "已保存", 0, 100));
        await Task.WhenAll(test.Session.StopAsync(), test.Session.StopAsync()); await test.Session.StopAsync();
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
        Assert.Single(test.History.Sessions); Assert.Single(Directory.GetFiles(test.Root, "*.json"));
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task StopInterruptsPendingModelReadinessOrCaptureStart(bool capture)
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var system = new FakeAudioSource { StartGate = capture ? gate : null };
        await using var test = new SessionFixture(null, system, new());
        test.ConfigureProvider = p => p.AutoReady = capture;
        var start = test.Session.StartAsync();
        Assert.Equal(ListeningState.Starting, test.Session.Snapshot.State);
        await Task.WhenAll(start, test.Session.StopAsync()).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State); Assert.Null(test.Session.Snapshot.Error);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
        if (capture) Assert.Equal(1, system.Disposals);
    }

    [Fact] public async Task StartupCancellationTearsDownAndDisposePreventsRestart()
    {
        await using var test = new SessionFixture();
        test.ConfigureProvider = p => p.AutoReady = false;
        using var cancellation = new CancellationTokenSource();
        var start = test.Session.StartAsync(cancellation.Token);
        cancellation.Cancel();
        await start.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ListeningState.Stopped, test.Session.Snapshot.State);
        await test.Session.DisposeAsync(); await test.Session.DisposeAsync();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => test.Session.StartAsync());
    }

    [Fact] public async Task StopWaitsForBothCapturesThenBothFlushesBeforeSavingFinalFragments()
    {
        var system = new FakeAudioSource(); var mic = new FakeAudioSource();
        await using var test = new SessionFixture(null, system, mic);
        await test.Session.StartAsync();
        var flush = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var provider in test.Providers)
            provider.OnDisconnect = async () =>
            {
                Assert.Equal(1, system.Stops); Assert.Equal(1, mic.Stops);
                entered.TrySetResult(); await flush.Task;
                provider.Emit(Final(provider.Speaker.ToString(), "停止时的最后一句", 0, 100));
            };
        var stop = test.Session.StopAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(test.History.Sessions); Assert.False(stop.IsCompleted);
        flush.SetResult(); await stop.WaitAsync(TimeSpan.FromSeconds(5));
        var record = Assert.Single(test.History.Sessions);
        Assert.Equal(2, record.Lines.Count); Assert.Equal(2, record.Fragments!.Count);
        Assert.Contains(record.Lines, l => l.Speaker == Speaker.Them); Assert.Contains(record.Lines, l => l.Speaker == Speaker.You);
        Assert.True(record.EndedAt >= record.StartedAt);
        var reloaded = Assert.Single(new SessionStore(test.Root).Sessions);
        Assert.Equal(record.Id, reloaded.Id);
        Assert.Equal(record.Lines.Select(l => (l.Speaker, l.Content)), reloaded.Lines.Select(l => (l.Speaker, l.Content)));
        Assert.Equal(record.Fragments.Select(f => (f.Id, f.Speaker, f.Text)), reloaded.Fragments!.Select(f => (f.Id, f.Speaker, f.Text)));
        Assert.Equal(CoreJson.Iso8601(record.StartedAt), CoreJson.Iso8601(reloaded.StartedAt));
        Assert.Equal(CoreJson.Iso8601(record.EndedAt), CoreJson.Iso8601(reloaded.EndedAt));
    }

    [Fact] public async Task EmptySessionCreatesNoHistoryFiles()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync(); await test.Session.StopAsync();
        Assert.Empty(test.History.Sessions); Assert.False(Directory.Exists(test.Root));
    }

    [Fact] public async Task PersistenceFailureIsVisibleAfterFullTeardownAndNotRetriedBySecondStop()
    {
        await using var test = new SessionFixture();
        await File.WriteAllTextAsync(test.Root, "a file blocks the session directory");
        await test.Session.StartAsync(); test.Them.Emit(Final("save", "需要保存", 0, 100));
        await test.Session.StopAsync(); await test.Session.StopAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains("会话保存失败", test.Session.Snapshot.Error);
        Assert.Single(test.Session.Snapshot.Lines); Assert.Empty(test.History.Sessions);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
        Assert.False(test.Session.Snapshot.System.Capturing); Assert.False(test.Session.Snapshot.Microphone.Capturing);
    }

    [Fact] public async Task CleanupFailureDoesNotPreventOtherProviderDisconnectOrFinalSave()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        test.Them.OnDisconnect = () => throw new IOException("flush failed");
        test.You.OnDisconnect = () => { test.You.Emit(Final("final", "正常的另一路", 0, 100)); return Task.CompletedTask; };
        await test.Session.StopAsync();
        Assert.Contains("flush failed", test.Session.Snapshot.Error);
        Assert.Equal(1, test.You.Disconnects); Assert.Single(test.History.Sessions);
    }

    [Fact] public async Task CaptureStopFailureStillDisposesBothSourcesAndFlushesAndSaves()
    {
        var system = new FakeAudioSource { StopError = new IOException("device stop failed") };
        var mic = new FakeAudioSource();
        await using var test = new SessionFixture(null, system, mic);
        await test.Session.StartAsync();
        test.You.OnDisconnect = () =>
        {
            Assert.Equal(1, system.Disposals); Assert.Equal(1, mic.Disposals);
            test.You.Emit(Final("flush", "最后一句", 0, 100));
            return Task.CompletedTask;
        };
        await test.Session.DisposeAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains("device stop failed", test.Session.Snapshot.Error);
        Assert.All(test.Providers, p => Assert.Equal(1, p.Disconnects));
        Assert.Single(test.History.Sessions);
    }

    [Fact] public async Task UnfinalizedClosePreservesCompletedLinesAndReportsFlushFailure()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        test.Them.Emit(Final("complete", "已定稿内容", 0, 100));
        test.You.OnDisconnect = () =>
        {
            test.You.Emit(new LiveEvent.Closed(false));
            return Task.CompletedTask;
        };
        await test.Session.StopAsync();
        Assert.Equal(ListeningState.Failed, test.Session.Snapshot.State);
        Assert.Contains("最后一段转写", test.Session.Snapshot.Error);
        Assert.Equal("已定稿内容", Assert.Single(Assert.Single(test.History.Sessions).Lines).Content);
    }

    [Fact] public async Task PartialOnlySessionDoesNotInventFinalsOrWriteEmptyHistory()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        test.Them.Emit(new LiveEvent.PartialTranscript("未定稿"));
        await test.Session.StopAsync();
        Assert.Empty(test.Session.Snapshot.Lines); Assert.Empty(test.Session.Snapshot.PartialThem);
        Assert.Empty(test.History.Sessions); Assert.False(Directory.Exists(test.Root));
    }

    [Fact] public async Task UnexpectedCloseFailsWhileDeliberateCloseIsNormal()
    {
        await using var test = new SessionFixture();
        await test.Session.StartAsync();
        var failed = Until(test.Session, s => s.State == ListeningState.Failed);
        test.You.Emit(new LiveEvent.Closed(true)); await failed;
        Assert.Contains("意外关闭", test.Session.Snapshot.Error);
    }

    [Fact] public async Task SuggestionRequestIsVisibleHonestAndDisabledModesAreIgnored()
    {
        await using var test = new SessionFixture(new() { RecapEnabled = false });
        test.Session.Request(SuggestionMode.Reply);
        var view = test.Session.Snapshot;
        Assert.Equal(SuggestionMode.Reply, view.LastRequestedMode);
        Assert.Equal("已请求回答，推理服务尚未接入", view.SuggestionStatus);
        Assert.Empty(view.SuggestionText); Assert.False(view.SuggestionIsLoading); Assert.Null(view.SuggestionError);
        Assert.Empty(view.Lines); Assert.Empty(view.PartialThem); Assert.Empty(view.PartialYou);
        Assert.Empty(test.Providers); Assert.Empty(test.Factory.Requested);
        test.Session.Request(SuggestionMode.Recap);
        Assert.Equal(view, test.Session.Snapshot);
        test.Session.Request(SuggestionMode.FollowUp);
        Assert.Equal(SuggestionMode.FollowUp, test.Session.Snapshot.LastRequestedMode);
    }

    private static LiveEvent.Transcript Final(string id, string text, int start, int end) =>
        new(new(id, Speaker.Room, text, start, end, DateTimeOffset.UtcNow)); // Session owns path identity.

    private static async Task Until(ListeningSession session, Func<ListeningSnapshot, bool> condition)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed() { if (condition(session.Snapshot)) done.TrySetResult(); }
        session.Changed += Changed;
        try { Changed(); await done.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { session.Changed -= Changed; }
    }
}

internal sealed class FakeLiveProvider(Speaker speaker)
    : ILiveProvider
{
    public Speaker Speaker { get; } = speaker;
    public Action<LiveEvent>? OnEvent { get; set; }
    public bool AutoReady { get; set; } = true;
    public Action? OnConnect { get; set; }
    public Action? OnAudio { get; set; }
    public Func<Task>? OnDisconnect { get; set; }
    public int Connects { get; private set; }
    public int Disconnects { get; private set; }
    public List<string> Calls { get; } = [];
    public IReadOnlyList<string> Terms { get; private set; } = [];
    public ConcurrentQueue<byte[]> Audio { get; } = new();
    public void UpdateTerms(IReadOnlyList<string> terms) { Calls.Add("terms"); Terms = terms.ToArray(); }
    public void Connect(string context)
    { Connects++; Calls.Add("connect"); OnConnect?.Invoke(); if (AutoReady) Emit(new LiveEvent.Ready()); }
    public void SendAudio(ReadOnlyMemory<byte> data) { Audio.Enqueue(data.ToArray()); OnAudio?.Invoke(); }
    public void AppendContext(string text, string? delegationId) => throw new InvalidOperationException("No reasoning/context service in the listening session.");
    public async Task DisconnectAsync()
    {
        Disconnects++; if (OnDisconnect is not null) await OnDisconnect();
        Emit(new LiveEvent.PartialTranscript("")); Emit(new LiveEvent.Closed(true));
    }
    public void Emit(LiveEvent value) => OnEvent?.Invoke(value);
}

internal sealed class SessionFixture : IAsyncDisposable
{
    public string Root { get; } = System.IO.Path.Combine(AppContext.BaseDirectory, "session-test-" + Guid.NewGuid());
    public SessionStore History { get; }
    public TranscriptStore Transcript { get; } = new();
    public FakeAudioFactory Factory { get; }
    public List<FakeLiveProvider> Providers { get; } = [];
    public FakeLiveProvider Them => Providers[^2];
    public FakeLiveProvider You => Providers[^1];
    public Action<FakeLiveProvider>? ConfigureProvider { get; set; }
    public ListeningSession Session { get; }

    public SessionFixture(AppSettings? settings = null, params FakeAudioSource[] sources)
    {
        History = new(Root);
        Factory = new(sources.Length == 0 ? [new(), new()] : sources);
        Session = new(Factory, (speaker, _) =>
        {
            var provider = new FakeLiveProvider(speaker); Providers.Add(provider); ConfigureProvider?.Invoke(provider);
            return new(provider, provider.UpdateTerms, () => "Observed fake backend");
        }, settings ?? new(), Transcript, History);
    }

    public async ValueTask DisposeAsync()
    {
        await Session.DisposeAsync();
        if (Directory.Exists(Root)) Directory.Delete(Root, true);
        if (File.Exists(Root)) File.Delete(Root);
    }
}
