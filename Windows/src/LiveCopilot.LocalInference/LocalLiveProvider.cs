using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

/// <summary>Single-use session; callbacks are serialized, and hosts marshal them to their UI context.</summary>
public sealed class LocalLiveProvider : ILiveProvider, IRecognitionStatsReporting, IAsyncDisposable
{
    private readonly object gate = new();
    private readonly Func<CancellationToken, Task<ISpeechEngine>> factory;
    private readonly Speaker speaker;
    private readonly bool contextual;
    private readonly DateTimeOffset sessionStart;
    private readonly TimeSpan shutdownTimeout;
    private readonly Channel<byte[]> audio = Channel.CreateUnbounded<byte[]>(new() { SingleReader = true, AllowSynchronousContinuations = false });
    private readonly CancellationTokenSource lifetime = new();
    private Task? worker, shutdown;
    private bool connected, ready, closing, closed, failed, speaking, finalized;
    private int outstanding, offsetMs;
    private long capturedBytes;
    private string partial = "";
    private string[] terms = [], displayTerms = [];
    public Action<LiveEvent>? OnEvent { get; set; }
    public RecognitionStats RecognitionStats { get; } = new();
    public InferenceBackend? Backend { get; private set; }
    public IReadOnlyList<BackendAttempt> BackendAttempts { get; private set; } = [];

    public LocalLiveProvider(string? root = null, Speaker speaker = Speaker.Room, bool contextual = false,
        InferenceOptions? options = null, DateTimeOffset? sessionStart = null)
        : this(ct => SherpaSpeechEngine.CreateAsync(root, contextual, options, ct), speaker, contextual, sessionStart) { }

    public LocalLiveProvider(Func<CancellationToken, Task<ISpeechEngine>> engineFactory, Speaker speaker = Speaker.Room,
        bool contextual = false, DateTimeOffset? sessionStart = null, TimeSpan? shutdownTimeout = null)
    {
        factory = engineFactory; this.speaker = speaker; this.contextual = contextual;
        this.sessionStart = sessionStart ?? DateTimeOffset.UtcNow;
        this.shutdownTimeout = shutdownTimeout ?? TimeSpan.FromSeconds(15);
    }
    public void UpdateTerms(IReadOnlyList<string> value, IReadOnlyList<string>? display = null)
    {
        if (!contextual) throw new InvalidOperationException("Hotwords require the terminology model.");
        SpeechConfiguration.Hotwords(value);
        lock (gate) { terms = value.ToArray(); displayTerms = (display ?? value).ToArray(); }
    }
    public void Connect(string context)
    {
        lock (gate)
        {
            if (closed || closing) throw new InvalidOperationException("Create a new provider for a new session.");
            if (connected) return;
            connected = true;
            offsetMs = Math.Max(0, (int)(DateTimeOffset.UtcNow - sessionStart).TotalMilliseconds);
            worker = Task.Run(RunAsync);
        }
    }
    public void SendAudio(ReadOnlyMemory<byte> data)
    {
        lock (gate)
        {
            if (!connected || closing || failed || closed) return;
            if (data.Length % 2 != 0) { Fail("Audio must be mono PCM16 little-endian at 16000 Hz."); return; }
            // Include in-flight native work; never discard audio and claim successful finalization.
            if ((long)outstanding + data.Length > SpeechConfiguration.MaximumBacklogBytes)
            {
                RecognitionStats.Failure = RecognitionStats.OverflowFailure(ready);
                Fail(ready ? "Local recognition fell behind. Stop/start listening." : "Local speech model took too long to load. Stop/start listening.");
                return;
            }
            capturedBytes += data.Length; outstanding += data.Length;
            RecognitionStats.NoteBacklog(outstanding / SpeechConfiguration.BytesPerMillisecond);
            for (var offset = 0; offset < data.Length; offset += SpeechConfiguration.PumpBytes)
                audio.Writer.TryWrite(data.Slice(offset, Math.Min(SpeechConfiguration.PumpBytes, data.Length - offset)).ToArray());
        }
    }
    private async Task RunAsync()
    {
        var started = Stopwatch.GetTimestamp();
        try
        {
            using var engine = await factory(lifetime.Token).ConfigureAwait(false);
            lifetime.Token.ThrowIfCancellationRequested();
            string[]? sentTerms = null;
            void ApplyTerms()
            {
                string[] snapshot;
                lock (gate) snapshot = terms;
                if (contextual && (sentTerms is null || !snapshot.SequenceEqual(sentTerms)))
                { engine.SetTerms(snapshot); sentTerms = snapshot; }
            }
            ApplyTerms();
            lock (gate)
            {
                if (closed || failed) return;
                Backend = engine.Backend; BackendAttempts = engine.BackendAttempts; ready = true;
                RecognitionStats.ReadyMs = (int)Stopwatch.GetElapsedTime(started).TotalMilliseconds;
                OnEvent?.Invoke(new LiveEvent.Ready());
            }
            await foreach (var data in audio.Reader.ReadAllAsync(lifetime.Token).ConfigureAwait(false))
            {
                lifetime.Token.ThrowIfCancellationRequested(); ApplyTerms();
                var result = engine.Accept(data);
                lock (gate)
                {
                    outstanding -= data.Length;
                    if (!failed && !closed) Consume(result, false);
                }
            }
            lifetime.Token.ThrowIfCancellationRequested();
            var final = engine.Accept(ReadOnlyMemory<byte>.Empty, flush: true);
            lock (gate)
            {
                if (!failed && !closed) { Consume(final, true); finalized = outstanding == 0; }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception)
        {
            lock (gate) Fail("Local model is missing, corrupt, or could not run. Check model files and the native runtime.");
        }
        finally
        {
            while (audio.Reader.TryRead(out _)) { }
            lock (gate) { outstanding = 0; ready = false; }
        }
    }
    private void Consume(SpeechResult result, bool flush)
    {
        if (speaking != result.Speaking) { speaking = result.Speaking; OnEvent?.Invoke(new LiveEvent.SpeechActivity(speaking)); }
        foreach (var segment in result.Segments)
        {
            var text = Regex.Replace(segment.Text, @"<\|[^>]+\|>", "").Trim();
            if (contextual) text = TranscriptCasing.Format(text, displayTerms);
            if (text.Length == 0) continue;
            if (!flush) RecognitionStats.NoteFinal(checked((int)(capturedBytes / 32)), segment.EndMs);
            OnEvent?.Invoke(new LiveEvent.Transcript(new("local-" + Guid.NewGuid(), speaker, " " + text,
                offsetMs + segment.StartMs, offsetMs + segment.EndMs, DateTimeOffset.UtcNow)));
        }
        if (partial != result.Partial)
        {
            partial = result.Partial;
            OnEvent?.Invoke(new LiveEvent.PartialTranscript(contextual ? TranscriptCasing.Format(partial, displayTerms) : partial));
        }
    }
    private void Fail(string message)
    {
        if (failed || closed) return;
        failed = true; finalized = false;
        RecognitionStats.Failure ??= RecognitionFailure.InferenceFailed;
        audio.Writer.TryComplete(); lifetime.Cancel();
        partial = ""; OnEvent?.Invoke(new LiveEvent.PartialTranscript(""));
        if (speaking) { speaking = false; OnEvent?.Invoke(new LiveEvent.SpeechActivity(false)); }
        OnEvent?.Invoke(new LiveEvent.Failed(message));
    }
    public void AppendContext(string text, string? delegationId) { /* The host owns conversation context. */ }
    public Task DisconnectAsync()
    {
        lock (gate)
        {
            if (shutdown is not null) return shutdown;
            closing = true; audio.Writer.TryComplete();
            shutdown = Task.Run(CloseAsync);
            return shutdown;
        }
    }
    private async Task CloseAsync()
    {
        try { if (worker is not null) await worker.WaitAsync(shutdownTimeout).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            lock (gate) { RecognitionStats.Failure = RecognitionFailure.Timeout; Fail("Local speech finalization timed out."); }
        }
        lock (gate)
        {
            closed = true; ready = false;
            if (speaking) { speaking = false; OnEvent?.Invoke(new LiveEvent.SpeechActivity(false)); }
            partial = ""; OnEvent?.Invoke(new LiveEvent.PartialTranscript(""));
            OnEvent?.Invoke(new LiveEvent.Closed(finalized && !failed));
        }
        // In-process native calls cannot safely be killed. A late completion is suppressed;
        // RunAsync owns and disposes its engine when that call returns.
    }
    public async ValueTask DisposeAsync() => await DisconnectAsync().ConfigureAwait(false);
}
