using LiveCopilot.Core;
using LiveCopilot.Platform.Audio;

namespace LiveCopilot.Platform.Sessions;

/// Owns the injected stores exclusively until disposal. Provider events serialize store
/// access, while lifecycle operations serialize separately. No external call is made with
/// the state lock held (except the owned synchronous TranscriptStore).
/// Changed may run on any worker thread: observers must return promptly, never synchronously
/// wait for lifecycle methods, and WPF hosts must use Dispatcher.BeginInvoke and read Snapshot.
public sealed class ListeningSession : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly IAudioSourceFactory audioFactory;
    private readonly Func<Speaker, ListeningService, ListeningProvider> providerFactory;
    private readonly TranscriptStore transcript;
    private readonly SessionStore? sessions;
    private readonly AppSettings settings;
    private readonly ICaptureClock? clock;
    private ListeningSnapshot snapshot = new();
    private Run? current;
    private bool disposed;

    public event Action? Changed;
    public ListeningSnapshot Snapshot { get { lock (sync) return snapshot; } }

    public ListeningSession(IAudioSourceFactory audioFactory,
        Func<Speaker, ListeningService, ListeningProvider> providerFactory, AppSettings settings,
        TranscriptStore? transcript = null, SessionStore? sessions = null, ICaptureClock? clock = null)
    {
        this.audioFactory = audioFactory;
        this.providerFactory = providerFactory;
        this.settings = settings with { };
        this.transcript = transcript ?? new();
        this.sessions = sessions;
        this.clock = clock;
    }

    /// Idempotent while active. Cancellation cancels this start; StopAsync also interrupts
    /// model readiness/capture startup. Operational failures are exposed through Snapshot.
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Run run;
            lock (sync)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (current is not null) return;
                if (settings.ListeningService is not (ListeningService.Zipformer or ListeningService.Paraformer))
                {
                    snapshot = snapshot with { State = ListeningState.Failed,
                        Error = "云端听写尚未接入；Windows 仅支持 Zipformer / Paraformer，Apple 听写不可用。" };
                    run = null!;
                }
                else
                {
                    transcript.Clear();
                    run = new(audioFactory, clock);
                    current = run;
                    snapshot = new() { State = ListeningState.Starting, SampleRate = settings.ListeningService.SampleRate() };
                }
            }
            Changed?.Invoke();
            if (run is null) return;
            using var registration = cancellationToken.Register(() => ScheduleStop(run));
            try
            {
                run.System.Capture.Configure(settings.ListeningService.SampleRate());
                run.Microphone.Capture.Configure(settings.ListeningService.SampleRate());
                Prepare(run, run.System);
                Prepare(run, run.Microphone);
                Connect(run, run.System);
                Connect(run, run.Microphone);
                await Task.WhenAll(run.System.Ready.Task, run.Microphone.Ready.Task)
                    .WaitAsync(run.StartCancellation.Token).ConfigureAwait(false);
                CheckStarting(run);
                await StartCaptureAsync(run, run.System).ConfigureAwait(false);
                await StartCaptureAsync(run, run.Microphone).ConfigureAwait(false);
                lock (sync)
                {
                    if (run.StopRequested) throw new OperationCanceledException();
                    run.WasListening = true;
                    snapshot = snapshot with { State = ListeningState.Listening };
                }
                Changed?.Invoke();
            }
            catch (OperationCanceledException) when (run.StopRequested || cancellationToken.IsCancellationRequested)
            { await TearDownAsync(run).ConfigureAwait(false); }
            catch (Exception e)
            {
                Fail(run, "无法开始聆听：" + e.Message);
                await TearDownAsync(run).ConfigureAwait(false);
            }
        }
        finally { lifecycle.Release(); }
    }

    private void Prepare(Run run, Path path)
    {
        CheckStarting(run);
        path.Live = providerFactory(path.Speaker, settings.ListeningService);
        path.Live.Provider.OnEvent = value => Receive(run, path, value);
        path.Capture.Error += message => Fail(run, message);
        // AudioCaptureManager owns the callback lifetime. SendAudio must promptly copy/queue
        // the borrowed PCM, as LocalLiveProvider does. No task/extra audio queue per buffer.
        path.Capture.Pcm16Available += pcm => path.Live.Provider.SendAudio(pcm);
        if (settings.ListeningService == ListeningService.Zipformer)
        {
            if (path.Live.UpdateTerms is null) throw new InvalidOperationException("Zipformer 提供器未提供热词配置。");
            path.Live.UpdateTerms(settings.ProfessionalTerms);
        }
    }

    private void Connect(Run run, Path path)
    {
        CheckStarting(run);
        path.Live!.Provider.Connect("");
        CheckStarting(run);
    }

    private void CheckStarting(Run run)
    {
        lock (sync) if (run.StopRequested) throw new OperationCanceledException();
    }

    private async Task StartCaptureAsync(Run run, Path path)
    {
        CheckStarting(run);
        await path.Capture.StartAsync(run.StartCancellation.Token).ConfigureAwait(false);
        CheckStarting(run);
        if (!path.Capture.IsCapturing)
            throw new InvalidOperationException(path.Capture.LastError ?? "音频采集未能启动。");
        var description = path.Capture.SourceDescription;
        lock (sync) SetPath(path, GetPath(path) with { Capturing = true, SourceDescription = description });
        Changed?.Invoke();
    }

    private ListeningPathSnapshot GetPath(Path path) => path.Speaker == Speaker.Them ? snapshot.System : snapshot.Microphone;
    private void SetPath(Path path, ListeningPathSnapshot value) => snapshot = path.Speaker == Speaker.Them
        ? snapshot with { System = value } : snapshot with { Microphone = value };

    private void Receive(Run run, Path path, LiveEvent value)
    {
        if (value is LiveEvent.Failed failure) { Fail(run, failure.Message); return; }
        string? backend = null;
        if (value is LiveEvent.Ready)
        {
            try { backend = path.Live?.Backend?.Invoke(); }
            catch (Exception e) { Fail(run, "无法读取语音后端状态：" + e.Message); return; }
        }
        string? error = null;
        lock (sync)
        {
            if (current != run || !run.AcceptEvents) return;
            switch (value)
            {
                case LiveEvent.Ready:
                    SetPath(path, GetPath(path) with { Backend = backend });
                    path.Ready.TrySetResult();
                    break;
                case LiveEvent.Transcript final:
                    transcript.Ingest(final.Fragment with { Speaker = path.Speaker });
                    transcript.ClearPartial(path.Speaker);
                    break;
                case LiveEvent.PartialTranscript partial:
                    transcript.SetPartial(partial.Text, path.Speaker);
                    break;
                case LiveEvent.SpeechActivity speech:
                    SetPath(path, GetPath(path) with { SpeechActive = speech.Active });
                    break;
                case LiveEvent.Closed closed:
                    if (!run.Disconnecting) error = "本地语音连接意外关闭，请重新开始聆听。";
                    else if (!closed.Finalized && run.WasListening) error = "本地听写未能完成最后一段转写。";
                    SetPath(path, GetPath(path) with { SpeechActive = false });
                    break;
                default: return;
            }
            RefreshTranscript();
        }
        if (error is not null) Fail(run, error);
        Changed?.Invoke();
    }

    private void RefreshTranscript() => snapshot = snapshot with
    { Lines = transcript.Lines, PartialThem = transcript.PartialThem, PartialYou = transcript.PartialYou };

    private void Fail(Run run, string message)
    {
        lock (sync)
        {
            if (current != run || !run.AcceptEvents) return;
            // The first failure is the actionable cause, even when both paths fail together.
            snapshot = snapshot with { Error = snapshot.Error ?? message };
        }
        ScheduleStop(run);
        Changed?.Invoke();
    }

    private void ScheduleStop(Run run)
    {
        lock (sync)
        {
            if (current != run || run.StopRequested) return;
            run.StopRequested = true;
            snapshot = snapshot with { IsStopping = true };
        }
        // Never stop/cancel captures inline from a PCM/provider callback: it may hold a
        // provider or capture lock, and StopAsync must wait for that callback to finish.
        _ = Task.Run(() => StopRunAsync(run));
    }

    public void Request(SuggestionMode mode)
    {
        lock (sync)
        {
            if (disposed || !settings.EnabledSuggestionModes.Contains(mode)) return;
            var label = mode switch { SuggestionMode.Reply => "回答", SuggestionMode.Recap => "总结", _ => "追问" };
            snapshot = snapshot with { LastRequestedMode = mode, SuggestionStatus = $"已请求{label}，推理服务尚未接入" };
        }
        Changed?.Invoke();
    }

    public async Task StopAsync()
    {
        Run? run;
        lock (sync)
        {
            run = current;
            if (run is null)
            {
                if (snapshot.State == ListeningState.Idle) snapshot = snapshot with { State = ListeningState.Stopped };
            }
            else { run.StopRequested = true; snapshot = snapshot with { IsStopping = true }; }
        }
        Changed?.Invoke();
        if (run is not null) await StopRunAsync(run).ConfigureAwait(false);
    }

    private async Task StopRunAsync(Run run)
    {
        try { await run.StartCancellation.CancelAsync().ConfigureAwait(false); }
        catch (ObjectDisposedException) { /* A serialized teardown already completed. */ }
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (sync) if (current != run) return;
            await TearDownAsync(run).ConfigureAwait(false);
        }
        finally { lifecycle.Release(); }
    }

    private async Task TearDownAsync(Run run)
    {
        lock (sync) { run.StopRequested = true; snapshot = snapshot with { IsStopping = true }; }
        await Task.WhenAll(run.System.Capture.StopAsync(), run.Microphone.Capture.StopAsync()).ConfigureAwait(false);
        lock (sync)
        {
            run.Disconnecting = true;
            snapshot = snapshot with { System = snapshot.System with { Capturing = false },
                Microphone = snapshot.Microphone with { Capturing = false } };
        }
        // Handlers remain installed through both disconnects, including final ASR flush.
        await Task.WhenAll(DisconnectAsync(run, run.System), DisconnectAsync(run, run.Microphone)).ConfigureAwait(false);
        await run.System.Capture.DisposeAsync().ConfigureAwait(false);
        await run.Microphone.Capture.DisposeAsync().ConfigureAwait(false);
        TranscriptLine[] lines;
        ValueList<TranscriptFragment> fragments;
        bool hasContent;
        lock (sync)
        {
            run.AcceptEvents = false;
            lines = transcript.ArchivedLines.ToArray();
            fragments = transcript.FragmentRevisions.ToValueList();
            hasContent = transcript.HasContent;
        }
        if (run.System.Live is { } system) system.Provider.OnEvent = null;
        if (run.Microphone.Live is { } mic) mic.Provider.OnEvent = null;
        if (hasContent && sessions is not null)
        {
            try
            {
                sessions.Save(lines, run.StartedAt, DateTimeOffset.UtcNow, fragments);
                if (sessions.LastError is { } error) PersistenceError(error);
            }
            catch (Exception e) { PersistenceError(e.Message); }
        }
        lock (sync)
        {
            current = null;
            snapshot = snapshot with { State = snapshot.Error is null ? ListeningState.Stopped : ListeningState.Failed,
                IsStopping = false, System = snapshot.System with { SpeechActive = false },
                Microphone = snapshot.Microphone with { SpeechActive = false } };
            RefreshTranscript();
        }
        run.StartCancellation.Dispose();
        Changed?.Invoke();
    }

    private async Task DisconnectAsync(Run run, Path path)
    {
        if (path.Live is null) return;
        try { await path.Live.Provider.DisconnectAsync().ConfigureAwait(false); }
        catch (Exception e) { Fail(run, "停止语音识别失败：" + e.Message); }
    }

    private void PersistenceError(string message)
    {
        lock (sync) snapshot = snapshot with { Error = (snapshot.Error is null ? "" : snapshot.Error + "\n") + "会话保存失败：" + message };
    }

    public async ValueTask DisposeAsync()
    {
        lock (sync) disposed = true;
        await StopAsync().ConfigureAwait(false);
    }

    private sealed class Path(IAudioSourceFactory factory, AudioInput input, Speaker speaker, ICaptureClock? clock)
    {
        public AudioCaptureManager Capture { get; } = new(factory, input, clock);
        public Speaker Speaker { get; } = speaker;
        public ListeningProvider? Live { get; set; }
        public TaskCompletionSource Ready { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Run(IAudioSourceFactory factory, ICaptureClock? clock)
    {
        public Path System { get; } = new(factory, AudioInput.System, Speaker.Them, clock);
        public Path Microphone { get; } = new(factory, AudioInput.Microphone, Speaker.You, clock);
        public CancellationTokenSource StartCancellation { get; } = new();
        public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
        public bool StopRequested { get; set; }
        public bool Disconnecting { get; set; }
        public bool WasListening { get; set; }
        public bool AcceptEvents { get; set; } = true;
    }
}
