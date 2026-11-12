namespace LiveCopilot.Platform.Audio;

/// Start/stop and recovery own a serialized lifecycle; callbacks synchronously convert and
/// emit, with no Task-per-buffer or backlog. Consumers must return promptly and must not
/// synchronously wait for lifecycle methods from a callback. Await StopAsync before reuse.
public sealed class AudioCaptureManager(IAudioSourceFactory factory, AudioInput input, ICaptureClock? clock = null) : IAsyncDisposable
{
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly object dataSync = new();
    private readonly ICaptureClock clock = clock ?? new CaptureClock();
    private readonly List<double> recoveries = [];
    private CancellationTokenSource? session;
    private CancellationTokenRegistration cancellationRegistration;
    private IAudioSource? source;
    private PcmConverter converter = new();
    private Action<ReadOnlyMemory<byte>>? dataHandler;
    private Action<AudioSourceException>? failureHandler;
    private Task recovery = Task.CompletedTask;
    private bool capturing, disposed, recoveryPending;
    private int sampleRate = 16000;
    private string? lastError, sourceDescription;
    private AudioSourceException? sourceFailure;

    public event Action<ReadOnlyMemory<byte>>? Pcm16Available;
    public event Action<string>? Error;
    public bool IsCapturing { get { lock (dataSync) return capturing; } }
    public int SampleRate { get { lock (dataSync) return sampleRate; } }
    public string? LastError { get { lock (dataSync) return lastError; } }
    public string? SourceDescription { get { lock (dataSync) return sourceDescription; } }
    public Task RecoveryCompletion { get { lock (dataSync) return recovery; } }

    public void Configure(int sampleRate)
    {
        lock (dataSync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (session is not null) return;
            converter = new PcmConverter(sampleRate);
            this.sampleRate = sampleRate;
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (dataSync)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (session is not null) return;
                session = new CancellationTokenSource();
                var current = session;
                cancellationRegistration = cancellationToken.Register(() =>
                {
                    lock (dataSync)
                    {
                        if (session != current) return;
                        current.Cancel(); capturing = false;
                    }
                    _ = Task.Run(() => StopSessionAsync(current));
                });
                lastError = null;
                sourceDescription = null;
                recoveries.Clear();
                converter.Reset();
            }
            try { await OpenAsync(session.Token).ConfigureAwait(false); }
            catch (Exception e)
            {
                try { await CloseSourceAsync().ConfigureAwait(false); }
                catch (Exception cleanup) { e = new AudioSourceException(AudioFailureKind.StartFailed, e.Message + " Cleanup failed: " + cleanup.Message, e); }
                finally { EndSession(); }
                if (e is not OperationCanceledException) Report(e);
                else cancellationToken.ThrowIfCancellationRequested();
            }
        }
        finally { lifecycle.Release(); }
    }

    private async Task OpenAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var next = factory.Create(input);
        lock (dataSync)
        {
            source = next;
            sourceFailure = null;
            dataHandler = data => Receive(next, data);
            failureHandler = error => Fail(next, error);
            next.DataAvailable += dataHandler;
            next.Failed += failureHandler;
            capturing = true; // Some sources deliver their first buffer inside StartAsync.
        }
        await next.StartAsync(token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        lock (dataSync)
        {
            if (sourceFailure is not null) throw sourceFailure;
            sourceDescription = next.Description;
        }
    }

    private void Receive(IAudioSource sender, ReadOnlyMemory<byte> data)
    {
        lock (dataSync)
        {
            if (!capturing || source != sender || session?.IsCancellationRequested != false) return;
            try
            {
                var pcm = converter.Convert(data.Span, sender.Format);
                if (pcm.Length > 0) Pcm16Available?.Invoke(pcm);
            }
            catch (Exception e) { Fail(sender, new(AudioFailureKind.StreamFailed, "Audio conversion or consumer callback failed: " + e.Message, e)); }
        }
    }

    private void Fail(IAudioSource sender, AudioSourceException error)
    {
        lock (dataSync)
        {
            if (source != sender || session is null || session.IsCancellationRequested) return;
            capturing = false;
            sourceFailure = error;
            if (recoveryPending) return;
            recoveryPending = true;
            var current = session;
            recovery = Task.Run(() => RecoverAsync(current, error));
        }
    }

    private async Task RecoverAsync(CancellationTokenSource current, AudioSourceException error)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (session != current || current.IsCancellationRequested) return;
            await CloseSourceAsync().ConfigureAwait(false);
            if (input != AudioInput.Microphone || error.Kind != AudioFailureKind.DeviceChanged)
            { EndSession(); Report(error); return; }
            var now = clock.Seconds;
            recoveries.RemoveAll(time => now - time >= 30);
            if (recoveries.Count >= 3) { EndSession(); ReportRecovery(error); return; }
            recoveries.Add(now);
            for (var attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    if (attempt == 1) await clock.Delay(TimeSpan.FromMilliseconds(500), current.Token).ConfigureAwait(false);
                    await OpenAsync(current.Token).ConfigureAwait(false);
                    lock (dataSync) lastError = null;
                    return;
                }
                catch (Exception e)
                {
                    await CloseSourceAsync().ConfigureAwait(false);
                    if (current.IsCancellationRequested) return;
                    if (e is AudioSourceException { Kind: AudioFailureKind.PermissionDenied } || attempt == 1)
                    { EndSession(); ReportRecovery(e); return; }
                }
            }
        }
        catch (Exception e)
        {
            EndSession();
            Report(new AudioSourceException(AudioFailureKind.StreamFailed, "Audio recovery failed: " + e.Message, e));
        }
        finally
        {
            lock (dataSync)
            {
                recoveryPending = false;
                if (source is not null && sourceFailure is not null && session?.IsCancellationRequested == false)
                    Fail(source, sourceFailure);
            }
            lifecycle.Release();
        }
    }

    private void ReportRecovery(Exception e) => Report(new AudioSourceException(AudioFailureKind.DeviceChanged,
        "Microphone device changed; recovery stopped. Check Windows Sound settings and stop/start listening. " + e.Message, e));

    private void Report(Exception e)
    {
        var message = e is AudioSourceException ? e.Message : $"{input} audio start/capture failed: {e.Message}";
        lock (dataSync) lastError = message;
        Error?.Invoke(message);
    }

    private async Task CloseSourceAsync()
    {
        IAudioSource? old;
        lock (dataSync)
        {
            capturing = false;
            old = source;
            source = null;
            if (old is not null) { old.DataAvailable -= dataHandler; old.Failed -= failureHandler; }
            converter.Reset();
        }
        if (old is not null)
        {
            try { await old.StopAsync().ConfigureAwait(false); }
            finally { await old.DisposeAsync().ConfigureAwait(false); }
        }
    }

    private void EndSession()
    {
        lock (dataSync)
        {
            capturing = false;
            cancellationRegistration.Unregister();
            session?.Dispose(); session = null;
        }
    }

    public async Task StopAsync()
    {
        lock (dataSync) { session?.Cancel(); capturing = false; }
        await StopSessionAsync().ConfigureAwait(false);
    }

    private async Task StopSessionAsync(CancellationTokenSource? expected = null)
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (expected is not null && session != expected) return;
            try { await CloseSourceAsync().ConfigureAwait(false); }
            catch (Exception e) { Report(new AudioSourceException(AudioFailureKind.StreamFailed, "Audio stop failed: " + e.Message, e)); }
            finally { EndSession(); }
        }
        finally { lifecycle.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        lock (dataSync) disposed = true;
        await StopAsync().ConfigureAwait(false);
    }
}
