using LiveCopilot.Core;

namespace LiveCopilot.LocalInference.Tests;

public sealed class LiveProviderTests
{
    [Fact]
    public async Task MapsReadyReplaceablePreviewsSpeechFinalsAndFlushToCoreEvents()
    {
        var calls = 0;
        var engine = new FakeSpeechEngine { Respond = flush => flush
            ? new([new("<|zh|> final ", 0, 2)], "", false)
            : new([], ++calls == 1 ? "pre" : "preview", true) };
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(_ => Task.FromResult<ISpeechEngine>(engine), Speaker.You);
        provider.OnEvent = log.Add;
        provider.Connect("context");
        await log.Wait<LiveEvent.Ready>();
        provider.SendAudio(new byte[32]);
        provider.SendAudio(new byte[32]);
        await provider.DisconnectAsync();
        var events = log.Snapshot();
        Assert.IsType<LiveEvent.Ready>(events[0]);
        Assert.Equal(["pre", "preview", "", ""], events.OfType<LiveEvent.PartialTranscript>().Select(x => x.Text));
        Assert.Equal([true, false], events.OfType<LiveEvent.SpeechActivity>().Select(x => x.Active));
        var final = Assert.Single(events.OfType<LiveEvent.Transcript>()).Fragment;
        Assert.Equal(" final", final.Text);
        Assert.Equal(Speaker.You, final.Speaker);
        Assert.StartsWith("local-", final.Id);
        Assert.Equal(2, final.EndMs - final.StartMs);
        Assert.True(Assert.IsType<LiveEvent.Closed>(events[^1]).Finalized);
        Assert.Equal(1, engine.Flushes);
        Assert.True(engine.Disposed);
        Assert.Equal(InferenceBackend.DirectML, provider.Backend);
        Assert.NotNull(provider.RecognitionStats.ReadyMs);
        Assert.Empty(events.OfType<LiveEvent.Delegation>());
        Assert.Empty(events.OfType<LiveEvent.Failed>());
    }

    [Fact]
    public async Task AudioIsCopiedAndPumpedInOrderWithShortTail()
    {
        var release = new TaskCompletionSource<ISpeechEngine>(TaskCreationOptions.RunContinuationsAsynchronously);
        var engine = new FakeSpeechEngine();
        await using var provider = new LocalLiveProvider(_ => release.Task);
        var input = Enumerable.Range(0, 32002).Select(i => (byte)(i % 251)).ToArray();
        var expected = input.ToArray();
        provider.Connect("");
        provider.SendAudio(input);
        Array.Fill(input, (byte)0);
        release.SetResult(engine);
        await provider.DisconnectAsync();
        Assert.Equal([16000, 16000, 2], engine.Audio.Select(x => x.Length));
        Assert.Equal(expected, engine.Audio.SelectMany(x => x));
        Assert.Equal(1000, provider.RecognitionStats.BacklogMaxMs);
    }

    [Fact]
    public async Task LoadingBacklogCapAcceptsBoundaryThenFailsInsteadOfDroppingAudio()
    {
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(async ct => { await Task.Delay(Timeout.Infinite, ct); throw new InvalidOperationException(); });
        provider.OnEvent = log.Add;
        provider.Connect("");
        provider.SendAudio(new byte[SpeechConfiguration.MaximumBacklogBytes]);
        Assert.Equal(12000, provider.RecognitionStats.BacklogMaxMs);
        provider.SendAudio(new byte[2]);
        await provider.DisconnectAsync();
        Assert.Equal(RecognitionFailure.SpeechLoadSlow, provider.RecognitionStats.Failure);
        Assert.Single(log.Snapshot().OfType<LiveEvent.Failed>());
        Assert.False(Assert.Single(log.Snapshot().OfType<LiveEvent.Closed>()).Finalized);
    }

    [Fact]
    public async Task BacklogIncludesInFlightNativeWorkAndSuppressesLateResults()
    {
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var engine = new FakeSpeechEngine { Respond = _ =>
        {
            entered.TrySetResult();
            if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
            return new([new("late", 0, 500)], "late", true);
        } };
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(_ => Task.FromResult<ISpeechEngine>(engine));
        provider.OnEvent = log.Add;
        provider.Connect("");
        await log.Wait<LiveEvent.Ready>();
        try
        {
            provider.SendAudio(new byte[16000]);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            provider.SendAudio(new byte[SpeechConfiguration.MaximumBacklogBytes - 16000]);
            provider.SendAudio(new byte[2]);
        }
        finally { release.Set(); }
        await provider.DisconnectAsync();
        Assert.Equal(RecognitionFailure.SpeechBehind, provider.RecognitionStats.Failure);
        Assert.Empty(log.Snapshot().OfType<LiveEvent.Transcript>());
        Assert.Equal(0, engine.Flushes);
        Assert.True(engine.Disposed);
    }

    [Theory]
    [InlineData("format")]
    [InlineData("load")]
    [InlineData("inference")]
    public async Task ErrorsAreVisibleAndNeverReportFinalized(string kind)
    {
        var log = new EventLog();
        var engine = new FakeSpeechEngine { Respond = _ => throw new InvalidOperationException("native failure") };
        await using var provider = new LocalLiveProvider(_ => kind == "load"
            ? Task.FromException<ISpeechEngine>(new InvalidDataException("missing model"))
            : Task.FromResult<ISpeechEngine>(engine));
        provider.OnEvent = log.Add;
        provider.Connect("");
        if (kind != "load")
        {
            await log.Wait<LiveEvent.Ready>();
            provider.SendAudio(kind == "format" ? new byte[1] : new byte[32]);
        }
        var failure = await log.Wait<LiveEvent.Failed>();
        Assert.NotEmpty(failure.Message);
        await provider.DisconnectAsync();
        Assert.Single(log.Snapshot().OfType<LiveEvent.Failed>());
        Assert.False(Assert.Single(log.Snapshot().OfType<LiveEvent.Closed>()).Finalized);
    }

    [Fact]
    public async Task MissingModelEmitsFailedThroughProductionProvider()
    {
        using var temp = new TemporaryDirectory();
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(temp.Path, options: new() { ForceCpu = true });
        provider.OnEvent = log.Add;
        provider.Connect("");
        await log.Wait<LiveEvent.Failed>();
        await provider.DisconnectAsync();
        Assert.Empty(log.Snapshot().OfType<LiveEvent.Ready>());
        Assert.False(Assert.Single(log.Snapshot().OfType<LiveEvent.Closed>()).Finalized);
    }

    [Fact]
    public async Task ShutdownDeadlineClosesOnceAndDisposesLateFactoryResult()
    {
        var release = new TaskCompletionSource<ISpeechEngine>(TaskCreationOptions.RunContinuationsAsynchronously);
        var engine = new FakeSpeechEngine();
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(_ => release.Task, shutdownTimeout: TimeSpan.FromMilliseconds(20));
        provider.OnEvent = log.Add;
        provider.Connect("");
        await provider.DisconnectAsync();
        await provider.DisconnectAsync();
        Assert.Equal(RecognitionFailure.Timeout, provider.RecognitionStats.Failure);
        var count = log.Snapshot().Count;
        release.SetResult(engine);
        await Task.Run(async () =>
        {
            while (!engine.Disposed) await Task.Delay(5);
        }).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(count, log.Snapshot().Count);
        Assert.Single(log.Snapshot().OfType<LiveEvent.Closed>());
        Assert.Throws<InvalidOperationException>(() => provider.Connect(""));
    }

    [Fact]
    public async Task TermUpdatesAreAppliedToEngineAndDisplayText()
    {
        var engine = new FakeSpeechEngine { Respond = flush => flush ? new([], "", false) : new([new("openai", 0, 1)], "openai", false) };
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(_ => Task.FromResult<ISpeechEngine>(engine), contextual: true);
        provider.OnEvent = log.Add;
        provider.UpdateTerms(["openai"], ["OpenAI"]);
        provider.Connect("");
        await log.Wait<LiveEvent.Ready>();
        provider.UpdateTerms(["gpu", "openai"], ["GPU", "OpenAI"]);
        provider.SendAudio(new byte[32]);
        await provider.DisconnectAsync();
        Assert.Equal(2, engine.Terms.Count);
        Assert.Equal(["gpu", "openai"], engine.Terms[1]);
        Assert.Equal(" OpenAI", Assert.Single(log.Snapshot().OfType<LiveEvent.Transcript>()).Fragment.Text);
        Assert.Equal(1, provider.RecognitionStats.FinalLagCount);
    }

    [Fact]
    public async Task DisconnectBeforeConnectAndEmptyAudioAreSafe()
    {
        var log = new EventLog();
        await using var provider = new LocalLiveProvider(_ => throw new InvalidOperationException("must not create"));
        provider.OnEvent = log.Add;
        provider.SendAudio(ReadOnlyMemory<byte>.Empty);
        await provider.DisconnectAsync();
        Assert.Single(log.Snapshot().OfType<LiveEvent.Closed>());
        Assert.Throws<InvalidOperationException>(() => provider.UpdateTerms(["gpu"]));
    }
}
