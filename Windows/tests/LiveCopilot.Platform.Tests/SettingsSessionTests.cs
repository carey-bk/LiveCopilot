using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Sessions;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsSessionTests
{
    [Fact]
    public async Task SaveRefreshesFutureRequestsAndCredentialsWithoutInterruptingCurrentAnswer()
    {
        var preferences = new MemoryPreferenceStore();
        new AppSettings { KnowledgeMode = KnowledgeMode.General }.Save(preferences);
        var credentials = new MemoryCredentialStore();
        credentials.Save(CredentialReference.Live, "test-original");
        var vm = new SettingsViewModel(preferences, credentials, new HotkeyStore(preferences));
        var audio = new FakeAudioFactory();
        var first = new HeldReasoning();
        var second = new HeldReasoning();
        var providers = new Queue<HeldReasoning>([first, second]);
        var selections = new ConcurrentQueue<AppSettings>();
        var keys = new ConcurrentQueue<string?>();
        var transcript = new TranscriptStore();
        transcript.SetPartial("如何实现这个方案？", Speaker.Them);
        await using var session = new ListeningSession(audio, (_, _) => throw new InvalidOperationException(),
            vm.Snapshot(), transcript, configuredReasoningFactory: selection =>
            {
                selections.Enqueue(selection);
                keys.Enqueue(credentials.Read(selection.AnalysisCredentialReference()));
                return providers.Dequeue();
            });
        vm.Saved += session.Configure;

        session.Request(SuggestionMode.Reply);
        var original = await first.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        vm.ReasoningService = ReasoningService.DeepSeek;
        vm.AnalysisThinking = AnalysisThinking.High;
        vm.DeepSeekCredential.Stage("test-replacement");
        vm.AnswerLanguage = AnswerLanguage.Chinese;
        vm.Scenario = ScenarioProfile.Meeting;
        vm.BilingualAnswers = true;
        vm.AdditionalAnswerInstructions = "给出两个步骤";
        Assert.True(vm.Save());
        Assert.False(first.WasCancelled);
        Assert.True(session.Snapshot.SuggestionIsLoading);
        Assert.Equal(AnswerLanguage.Auto, original.AnswerLanguage);
        Assert.Equal(ScenarioProfile.Interview, original.Scenario);
        Assert.False(original.BilingualAnswers);
        Assert.Single(selections);
        first.Complete();
        await UntilFinished(session);

        // These further edits must not alter the saved session selection.
        vm.AnswerLanguage = AnswerLanguage.English;
        vm.ReasoningService = ReasoningService.SeparateOpenAI;
        vm.Cancel();
        session.Request(SuggestionMode.Recap);
        var updated = await second.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(AnswerLanguage.Chinese, updated.AnswerLanguage);
        Assert.Equal(ScenarioProfile.Meeting, updated.Scenario);
        Assert.True(updated.BilingualAnswers);
        Assert.Equal("给出两个步骤", updated.AdditionalAnswerInstructions);
        Assert.Equal(ReasoningService.DeepSeek, selections.Last().ReasoningService);
        Assert.Equal(AnalysisThinking.High, selections.Last().AnalysisThinking);
        Assert.Equal(new[] { "test-original", "test-replacement" }, keys);
        Assert.Empty(audio.Requested);
        second.Complete();
        await UntilFinished(session);
    }

    [Fact]
    public async Task ChangingEngineDuringStartupKeepsBothPathsConsistentUntilNextStart()
    {
        var audio = new FakeAudioFactory(new(), new(), new(), new());
        var selected = new List<ListeningService>();
        var providers = new List<FakeLiveProvider>();
        var original = new AppSettings { ProfessionalTerms = ["原始术语"] };
        var updated = original with { ListeningService = ListeningService.Paraformer, ProfessionalTerms = ["新术语"] };
        ListeningSession? active = null;
        await using var session = new ListeningSession(audio, (speaker, service) =>
        {
            selected.Add(service);
            var provider = new FakeLiveProvider(speaker);
            providers.Add(provider);
            if (selected.Count == 1)
            {
                active!.Configure(updated);
                updated.ListeningService = ListeningService.Apple; // Configure must take a copy.
            }
            return new(provider, provider.UpdateTerms);
        }, original);
        active = session;
        await session.StartAsync();
        Assert.Equal(ListeningState.Listening, session.Snapshot.State);
        Assert.Equal(new[] { ListeningService.Zipformer, ListeningService.Zipformer }, selected);
        Assert.All(providers, provider => Assert.Equal(new[] { "原始术语" }, provider.Terms));
        await session.StopAsync();
        await session.StartAsync();
        Assert.Equal(ListeningState.Listening, session.Snapshot.State);
        Assert.Equal(new[] { ListeningService.Zipformer, ListeningService.Zipformer,
            ListeningService.Paraformer, ListeningService.Paraformer }, selected);
        Assert.All(providers.Skip(2), provider => Assert.Empty(provider.Terms));
        Assert.All(providers.Take(2), provider => Assert.Equal(1, provider.Disconnects));
    }

    [Fact]
    public async Task ConfigurePublishesChangeWithoutStartingAndRejectsDisposedSession()
    {
        var audio = new FakeAudioFactory();
        await using var session = new ListeningSession(audio, (_, _) => throw new InvalidOperationException(), new());
        var changes = 0;
        session.Changed += () => changes++;
        session.Configure(new() { AnswerFontSize = 20, ExcludeOverlayFromCapture = true });
        Assert.Equal(1, changes);
        Assert.Empty(audio.Requested);
        Assert.Equal(ListeningState.Idle, session.Snapshot.State);
        await session.DisposeAsync();
        Assert.Throws<ObjectDisposedException>(() => session.Configure(new()));
    }

    private static async Task UntilFinished(ListeningSession session)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed() { if (!session.Snapshot.SuggestionIsLoading) done.TrySetResult(); }
        session.Changed += Changed;
        try { Changed(); await done.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        finally { session.Changed -= Changed; }
        Assert.Null(session.Snapshot.SuggestionError);
        Assert.Equal("已回答", session.Snapshot.SuggestionText);
    }

    private sealed class HeldReasoning : IReasoningProvider
    {
        private readonly TaskCompletionSource completed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<AnswerRequest> Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool WasCancelled { get; private set; }
        public void Complete() => completed.TrySetResult();
        public async IAsyncEnumerable<string> Stream(AnswerRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            using var registration = cancellationToken.Register(() => WasCancelled = true);
            Started.TrySetResult(request);
            await completed.Task.WaitAsync(cancellationToken);
            yield return "已回答";
        }
    }
}
