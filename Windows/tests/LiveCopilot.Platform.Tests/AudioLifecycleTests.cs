using LiveCopilot.Platform.Audio;

namespace LiveCopilot.Platform.Tests;

public sealed class AudioLifecycleTests
{
    [Fact] public async Task CallerCancellationStopsTheSessionAndAllowsRestart()
    {
        var first = new FakeAudioSource();
        using var cancellation = new CancellationTokenSource();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first, new()), AudioInput.Microphone);
        await manager.StartAsync(cancellation.Token); cancellation.Cancel();
        await first.DisposedSignal.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.False(manager.IsCapturing);
        await manager.StartAsync(); Assert.True(manager.IsCapturing);
    }

    [Fact] public async Task StopFailureStillDisposesAndLeavesManagerRestartable()
    {
        var first = new FakeAudioSource { StopError = new Exception("Device stop failed") };
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first, new()), AudioInput.System);
        await manager.StartAsync(); await manager.StopAsync();
        Assert.False(manager.IsCapturing); Assert.Equal(1, first.Disposals); Assert.Contains("stop failed", manager.LastError);
        await manager.StartAsync(); Assert.True(manager.IsCapturing); Assert.Null(manager.LastError);
    }

    [Fact] public async Task FailureDuringStartIsNotReportedAsSuccessfulCapture()
    {
        var first = new FakeAudioSource(); first.DuringStart = () => first.Fail(AudioFailureKind.StreamFailed, "Start callback failed");
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first), AudioInput.System);
        await manager.StartAsync(); await manager.RecoveryCompletion;
        Assert.False(manager.IsCapturing); Assert.Contains("Start callback failed", manager.LastError); Assert.Equal(1, first.Disposals);
    }

    [Fact] public async Task FailureInsideRecoveryStartIsRetriedOnceThenStopped()
    {
        var first = new FakeAudioSource(); var second = new FakeAudioSource(); var third = new FakeAudioSource();
        second.DuringStart = () => second.Fail(); third.DuringStart = () => third.Fail();
        var clock = new FakeClock();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first, second, third), AudioInput.Microphone, clock);
        await manager.StartAsync(); first.Fail(); await manager.RecoveryCompletion;
        Assert.False(manager.IsCapturing); Assert.Equal(1, clock.Delays); Assert.Equal(1, third.Disposals);
    }

    [Fact] public async Task PermissionDenialDuringRecoveryDoesNotRetry()
    {
        var first = new FakeAudioSource(); var clock = new FakeClock();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first,
            new() { StartError = new AudioSourceException(AudioFailureKind.PermissionDenied, "Microphone privacy denied") }), AudioInput.Microphone, clock);
        await manager.StartAsync(); first.Fail(); await manager.RecoveryCompletion;
        Assert.False(manager.IsCapturing); Assert.Equal(0, clock.Delays); Assert.Contains("privacy denied", manager.LastError);
    }

    [Fact] public async Task StartStopAreIdempotentAndConfigureIsIgnoredUntilStopped()
    {
        var source = new FakeAudioSource();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.System);
        Assert.Equal(16000, manager.SampleRate);
        await manager.StopAsync(); await manager.StartAsync(); await manager.StartAsync();
        manager.Configure(24000); manager.Configure(-1);
        Assert.Equal(16000, manager.SampleRate); Assert.Equal(1, source.Starts);
        Assert.True(manager.IsCapturing); Assert.Contains("Injected", manager.SourceDescription);
        await manager.StopAsync(); await manager.StopAsync();
        Assert.False(manager.IsCapturing); Assert.Equal(1, source.Stops); Assert.Equal(1, source.Disposals);
        manager.Configure(24000); Assert.Equal(24000, manager.SampleRate);
    }

    [Fact] public async Task EmitIsSynchronousWithNoQueuedBacklog()
    {
        var source = new FakeAudioSource { Format = new(16000, 1, PcmEncoding.Int16) };
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.System);
        var callbacks = 0; var thread = 0;
        manager.Pcm16Available += _ => { callbacks++; thread = Environment.CurrentManagedThreadId; };
        await manager.StartAsync();
        for (var i = 1; i <= 1000; i++)
        { source.Push(new byte[32]); Assert.Equal(i, callbacks); Assert.Equal(Environment.CurrentManagedThreadId, thread); }
        await manager.StopAsync(); source.Push(new byte[32]); Assert.Equal(1000, callbacks);
    }

    [Fact] public async Task StopDropsLateCallbacksAndResetsPartialFramesAndFilter()
    {
        var first = new FakeAudioSource(); var second = new FakeAudioSource();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first, second), AudioInput.System);
        var output = new List<byte>(); manager.Pcm16Available += d => output.AddRange(d.ToArray());
        await manager.StartAsync();
        first.Push(Signals.Float(480, 2, (_, _) => 1)); first.Push([255, 255, 255]);
        var late = first.SnapshotCallback();
        await manager.StopAsync(); output.Clear(); await manager.StartAsync();
        late(Signals.Float(480, 2, (_, _) => 1)); second.Push(new byte[480 * 8]);
        Assert.Equal(320, output.Count); Assert.All(output, b => Assert.Equal(0, b));
    }

    [Fact] public async Task StopCanCancelAnInFlightStart()
    {
        var source = new FakeAudioSource { StartGate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.Microphone);
        var start = manager.StartAsync();
        var stop = manager.StopAsync();
        await Task.WhenAll(start, stop).WaitAsync(TimeSpan.FromSeconds(3));
        Assert.False(manager.IsCapturing); Assert.Equal(1, source.Disposals);
    }

    [Theory]
    [InlineData(AudioFailureKind.PermissionDenied, "Microphone privacy denied: enable desktop microphone access.")]
    [InlineData(AudioFailureKind.NoDevice, "No capture device. Connect a microphone.")]
    [InlineData(AudioFailureKind.StartFailed, "WASAPI start failed.")]
    public async Task StartErrorsAreVisibleAndReleaseSource(AudioFailureKind kind, string text)
    {
        var source = new FakeAudioSource { StartError = new AudioSourceException(kind, text) };
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.Microphone);
        string? reported = null; manager.Error += message => reported = message;
        await manager.StartAsync();
        Assert.False(manager.IsCapturing); Assert.Equal(text, reported); Assert.Equal(text, manager.LastError); Assert.Equal(1, source.Disposals);
    }

    [Fact] public async Task MicrophoneRecoversAtMostThreeTimesInThirtySeconds()
    {
        var sources = Enumerable.Range(0, 4).Select(_ => new FakeAudioSource()).ToArray();
        var factory = new FakeAudioFactory(sources);
        await using var manager = new AudioCaptureManager(factory, AudioInput.Microphone, new FakeClock());
        await manager.StartAsync();
        foreach (var source in sources) { source.Fail(); await manager.RecoveryCompletion; }
        Assert.False(manager.IsCapturing); Assert.Equal(4, factory.Requested.Count);
        Assert.Contains("recovery stopped", manager.LastError); Assert.All(sources, s => Assert.Equal(1, s.Disposals));
    }

    [Fact] public async Task RecoveryBudgetExpiresAfterThirtySeconds()
    {
        var sources = Enumerable.Range(0, 5).Select(_ => new FakeAudioSource()).ToArray();
        var clock = new FakeClock();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(sources), AudioInput.Microphone, clock);
        await manager.StartAsync();
        for (var i = 0; i < 4; i++) { clock.Seconds = i * 31; sources[i].Fail(); await manager.RecoveryCompletion; Assert.True(manager.IsCapturing); }
    }

    [Fact] public async Task FailedRecoveryGetsExactlyOneDelayedRetry()
    {
        var first = new FakeAudioSource();
        var fail = new FakeAudioSource { StartError = new Exception("Route not ready") };
        var last = new FakeAudioSource { StartError = new Exception("Still unavailable") };
        var factory = new FakeAudioFactory(first, fail, last); var clock = new FakeClock();
        await using var manager = new AudioCaptureManager(factory, AudioInput.Microphone, clock);
        await manager.StartAsync(); first.Fail(); await manager.RecoveryCompletion;
        Assert.Equal(1, clock.Delays); Assert.Equal(3, factory.Requested.Count); Assert.False(manager.IsCapturing);
        Assert.Contains("stop/start", manager.LastError); Assert.Equal(1, last.Disposals);
    }

    [Fact] public async Task DelayedRecoveryCanSucceedAndClearError()
    {
        var first = new FakeAudioSource(); var last = new FakeAudioSource(); var clock = new FakeClock();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(first, new() { StartError = new Exception("Route settling") }, last), AudioInput.Microphone, clock);
        await manager.StartAsync(); first.Fail(); await manager.RecoveryCompletion;
        Assert.True(manager.IsCapturing); Assert.Null(manager.LastError); Assert.Equal(1, clock.Delays);
    }

    [Fact] public async Task StopDuringRetryCancelsRestart()
    {
        var first = new FakeAudioSource(); var clock = new FakeClock { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var factory = new FakeAudioFactory(first, new() { StartError = new Exception("Unavailable") }, new());
        await using var manager = new AudioCaptureManager(factory, AudioInput.Microphone, clock);
        await manager.StartAsync(); first.Fail();
        await clock.EnteredDelay.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await manager.StopAsync(); await manager.RecoveryCompletion;
        Assert.Equal(2, factory.Requested.Count); Assert.False(manager.IsCapturing);
    }

    [Fact] public async Task SystemDeviceLossFailsClearlyWithoutRestart()
    {
        var source = new FakeAudioSource(); var factory = new FakeAudioFactory(source);
        await using var manager = new AudioCaptureManager(factory, AudioInput.System);
        await manager.StartAsync(); source.Fail(message: "System audio device disconnected"); await manager.RecoveryCompletion;
        Assert.False(manager.IsCapturing); Assert.Single(factory.Requested); Assert.Contains("disconnected", manager.LastError);
    }

    [Fact] public async Task InvalidFormatAndThrowingConsumerFailInsteadOfSilentlyDroppingAudio()
    {
        foreach (var invalidFormat in new[] { true, false })
        {
            var source = new FakeAudioSource();
            if (invalidFormat) source.Format = new(0, 2, PcmEncoding.Float32);
            await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.System);
            manager.Pcm16Available += _ => throw new InvalidOperationException("Consumer rejected PCM");
            await manager.StartAsync(); source.Push(new byte[480 * 8]); await manager.RecoveryCompletion;
            Assert.False(manager.IsCapturing); Assert.Contains("failed", manager.LastError);
        }
    }

    [Fact] public async Task ConcurrentPushAndStopDoesNotEmitAfterStopReturns()
    {
        var source = new FakeAudioSource();
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.System);
        var count = 0; manager.Pcm16Available += _ => Interlocked.Increment(ref count);
        await manager.StartAsync();
        var late = source.SnapshotCallback();
        var pushing = Task.Run(() => { for (var i = 0; i < 100; i++) late(new byte[480 * 8]); });
        await manager.StopAsync(); var stoppedCount = count; await pushing;
        Assert.Equal(stoppedCount, count);
    }
}
