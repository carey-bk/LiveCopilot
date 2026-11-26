using System.IO;
using LiveCopilot.Platform.Audio;
using LiveCopilot.Platform.Overlay;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Tests;

public sealed class OverlaySessionControlsTests
{
    [Fact]
    public async Task MicrophoneOffStartsOnlySystemAndNextRunCanRestoreBothPaths()
    {
        await using var test = new SessionFixture(null, new FakeAudioSource(), new FakeAudioSource(), new FakeAudioSource());
        await test.Session.StartAsync(microphoneEnabled: false);
        Assert.Equal([AudioInput.System], test.Factory.Requested);
        Assert.Single(test.Providers); Assert.True(test.Session.Snapshot.System.Capturing); Assert.False(test.Session.Snapshot.Microphone.Capturing);
        await test.Session.StopAsync(); await test.Session.StartAsync();
        Assert.Equal([AudioInput.System, AudioInput.System, AudioInput.Microphone], test.Factory.Requested);
        Assert.True(test.Session.Snapshot.Microphone.Capturing);
    }
    [Fact]
    public async Task InPersonUsesOnlyMicrophoneAndRoomSpeaker()
    {
        await using var test = new SessionFixture(new() { Mode = OperatingMode.InPerson });
        await test.Session.StartAsync();
        Assert.Equal([AudioInput.Microphone], test.Factory.Requested);
        var provider = Assert.Single(test.Providers); Assert.Equal(Speaker.Room, provider.Speaker);
        provider.Emit(new LiveEvent.Transcript(new("room", Speaker.You, "现场交流", 0, 100, DateTimeOffset.UtcNow)));
        Assert.Equal(Speaker.Room, Assert.Single(test.Session.Snapshot.Lines).Speaker);
    }
    [Fact]
    public async Task InPersonWithoutMicrophoneFailsWithoutOpeningDevices()
    {
        await using var test = new SessionFixture(new() { Mode = OperatingMode.InPerson });
        await test.Session.StartAsync(microphoneEnabled: false);
        Assert.Empty(test.Factory.Requested); Assert.Empty(test.Providers);
        Assert.Contains("需要麦克风", test.Session.Snapshot.Error);
        Assert.True(await test.Session.ResetAsync()); Assert.Null(test.Session.Snapshot.Error);
    }
    [Fact]
    public async Task ResetSavesFinalTranscriptAndIgnoresOldCallbacksWithoutRestartingCapture()
    {
        await using var test = new SessionFixture(); await test.Session.StartAsync();
        var stale = test.You.OnEvent!;
        test.You.Emit(new LiveEvent.Transcript(new("a", Speaker.You, "保留历史", 0, 100, DateTimeOffset.UtcNow)));
        Assert.True(await test.Session.ResetAsync());
        Assert.Single(test.History.Sessions); Assert.Empty(test.Session.Snapshot.Lines);
        Assert.Equal(ListeningState.Idle, test.Session.Snapshot.State); Assert.Empty(test.Session.Snapshot.SuggestionText);
        stale(new LiveEvent.PartialTranscript("迟到回调")); Assert.Empty(test.Session.Snapshot.PartialYou);
        Assert.Equal(2, test.Factory.Requested.Count);
        Assert.True(await test.Session.ResetAsync()); Assert.Single(test.History.Sessions);
    }
    [Fact]
    public async Task ResetPreservesTranscriptIfSavingHistoryFails()
    {
        await using var test = new SessionFixture(); await File.WriteAllTextAsync(test.Root, "blocked");
        await test.Session.StartAsync();
        test.You.Emit(new LiveEvent.Transcript(new("a", Speaker.You, "不能丢失", 0, 100, DateTimeOffset.UtcNow)));
        Assert.False(await test.Session.ResetAsync()); Assert.Single(test.Session.Snapshot.Lines);
        Assert.Contains("会话保存失败", test.Session.Snapshot.Error);
    }
    [Fact]
    public async Task ResetInterruptsPendingStartAndRejectsNewRequestsUntilFlushed()
    {
        await using var test = new SessionFixture(); test.ConfigureProvider = p => p.AutoReady = false;
        var start = test.Session.StartAsync();
        Assert.True(await test.Session.ResetAsync().WaitAsync(TimeSpan.FromSeconds(5)));
        await start; Assert.Equal(ListeningState.Idle, test.Session.Snapshot.State); Assert.Empty(test.Factory.Requested);
    }
    [Fact]
    public void MicrophonePreferenceDoesNotMisreportCurrentCapture()
    {
        var model = new OverlayViewModel(_ => true, _ => { });
        model.UpdateSession(new() { State = ListeningState.Listening, Microphone = new(Capturing: true) });
        model.ToggleMicrophoneCommand.Execute(null);
        Assert.False(model.MicrophoneEnabled); Assert.Contains("当前仍在采集", model.MicrophoneChangeNotice); Assert.Contains("当前正在采集", model.MicrophoneHint); Assert.Contains("下次监听：麦克风关闭", model.MicrophoneHint);
        model.UpdateSession(new()); Assert.DoesNotContain("正在采集", model.MicrophoneHint);
        model.UpdateSession(new(), false); model.ToggleMicrophoneCommand.Execute(null); Assert.False(model.MicrophoneEnabled);
    }
    [Fact]
    public async Task ResetCommandSerializesWorkAndOnlyClearsQuestionAfterSuccess()
    {
        var done = new TaskCompletionSource<bool>(); var calls = 0;
        var model = new OverlayViewModel(_ => true, _ => Assert.Fail(), () => { calls++; return done.Task; }) { Question = "草稿" };
        var finished = new TaskCompletionSource();
        model.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(model.SessionActionError)) finished.TrySetResult(); };
        model.ResetSessionCommand.Execute(null); model.ResetSessionCommand.Execute(null); model.AskCommand.Execute(null);
        Assert.True(model.IsResetting); Assert.Equal(1, calls); Assert.False(model.ToggleMicrophoneCommand.CanExecute(null));
        done.SetResult(true); await finished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(model.Question); Assert.False(model.IsResetting); Assert.True(model.ResetSessionCommand.CanExecute(null));
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task ResetFailureKeepsDraftAndReportsError(bool throws)
    {
        var model = new OverlayViewModel(_ => true, _ => { }, () => throws ? Task.FromException<bool>(new IOException()) : Task.FromResult(false)) { Question = "保留草稿" };
        model.ResetSessionCommand.Execute(null);
        await Task.CompletedTask;
        Assert.Equal("保留草稿", model.Question); Assert.NotEmpty(model.SessionActionError); Assert.False(model.IsResetting);
    }
    [Fact]
    public void AnswerHeightGrowsContractsAndCapsToWorkArea()
    {
        Assert.Equal(420, OverlaySizing.Height(320, 100, 400, 720));
        Assert.Equal(720, OverlaySizing.Height(320, 2000, 400, 720));
        Assert.Equal(400, OverlaySizing.Height(320, 20, 400, 720));
        Assert.Equal(300, OverlaySizing.Height(320, 2000, 400, 300));
    }
}
