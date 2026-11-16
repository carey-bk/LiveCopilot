using System.Net.WebSockets;
using System.Threading.Channels;

namespace LiveCopilot.Core;

public sealed record OpenAILiveOptions
{
    public Uri Endpoint { get; init; } = OpenAILiveProtocol.Endpoint;
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(20);
    public TimeSpan CloseTimeout { get; init; } = TimeSpan.FromSeconds(8);
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromSeconds(1);
    public int MaximumRetries { get; init; } = 3;
}

/// Single-use session. One sender and one receiver per connection; callbacks are serialized.
/// Audio is copied synchronously, bounded, and discarded on reconnect just as on Mac.
public sealed class OpenAILiveProvider : ILiveProvider, IAsyncDisposable
{
    public const string MissingKeyMessage = "请先在设置 → 服务 → 分析与回答 → API Key 中配置共享 OpenAI API 密钥，再开始云端聆听。";
    private const int MaximumQueuedBytes = 192_000;
    private readonly object gate = new();
    private readonly string key, model;
    private readonly Speaker speaker;
    private readonly ScenarioProfile scenario;
    private readonly LiveSpeechLanguage language;
    private readonly OpenAILiveOptions options;
    private readonly CancellationTokenSource lifetime = new();
    private Connection? connection;
    private Task? worker, shutdown;
    private string context = "";
    private bool closing, closed, ready;
    public Action<LiveEvent>? OnEvent { get; set; }

    public OpenAILiveProvider(string key, string model, Speaker speaker, ScenarioProfile scenario,
        LiveSpeechLanguage language, OpenAILiveOptions? options = null)
    {
        this.key = key.Trim(); this.model = model; this.speaker = speaker; this.scenario = scenario; this.language = language;
        this.options = options ?? new();
        if (this.options.StartupTimeout <= TimeSpan.Zero || this.options.CloseTimeout <= TimeSpan.Zero ||
            this.options.RetryDelay < TimeSpan.Zero || this.options.MaximumRetries is < 0 or > 3)
            throw new ArgumentOutOfRangeException(nameof(options));
    }

    public static OpenAILiveProvider FromCredentials(AppSettings settings, ICredentialStore credentials, Speaker speaker,
        OpenAILiveOptions? options = null)
    {
        AppRuntime.RequireInteractive("云端聆听");
        // Shared Credential Manager / DPAPI entry only; never inspect environment secrets.
        var key = credentials.Read(CredentialReference.Live);
        if (string.IsNullOrWhiteSpace(key)) throw new CopilotException(MissingKeyMessage);
        return new(key, settings.LiveModel, speaker, settings.Scenario, settings.LiveSpeechLanguage, options);
    }

    public void Connect(string context)
    {
        AppRuntime.RequireInteractive("云端聆听");
        lock (gate)
        {
            if (closed || closing) throw new InvalidOperationException("Create a new provider for a new session.");
            if (worker is not null) return;
            if (string.IsNullOrWhiteSpace(key) || key.Any(char.IsControl))
            {
                closed = true;
                OnEvent?.Invoke(new LiveEvent.Failed(string.IsNullOrWhiteSpace(key) ? MissingKeyMessage : "OpenAI API 密钥含无效字符，请重新保存。"));
                return;
            }
            this.context = TextElements.Suffix(context, 6000);
            worker = Task.Run(RunAsync);
        }
    }

    public void SendAudio(ReadOnlyMemory<byte> data)
    {
        lock (gate)
        {
            if (!ready || closing || closed || connection is null || data.Length % 2 != 0) return;
            if (data.Length > MaximumQueuedBytes)
            { connection.Overflow.TrySetResult(); return; }
            Enqueue(connection, JsonSerializer.SerializeToUtf8Bytes(new { type = "session.input_audio.append", audio = Convert.ToBase64String(data.Span) }));
        }
    }

    public void AppendContext(string text, string? delegationId)
    {
        lock (gate)
        {
            if (closed || closing) return;
            context = TextElements.Suffix(context + "\n" + text, 6000);
            if (!ready || connection is null) return;
            Enqueue(connection, JsonSerializer.SerializeToUtf8Bytes(new { type = "session.thinking.append", event_id = Guid.NewGuid().ToString(),
                delegation_id = delegationId, content = OpenAILiveProtocol.ContextExcerpt(text) }));
        }
    }

    // All queue accounting includes the in-flight send, and all access is under gate.
    private static void Enqueue(Connection c, byte[] data, bool bounded = true)
    {
        if (bounded && c.QueuedBytes + data.Length > MaximumQueuedBytes) { c.Overflow.TrySetResult(); return; }
        c.QueuedBytes += data.Length;
        c.Queue.Writer.TryWrite(data);
    }

    private async Task RunAsync()
    {
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                lifetime.Token.ThrowIfCancellationRequested();
                using var c = new Connection(lifetime.Token);
                lock (gate)
                {
                    if (closing) return;
                    connection = c;
                    OnEvent?.Invoke(new LiveEvent.Status(speaker.RawValue() + ": connecting to Live…"));
                }
                var retry = true;
                string? failure = null;
                Task? sender = null, receiver = null;
                try
                {
                    c.Socket.Options.SetRequestHeader("Authorization", "Bearer " + key);
                    c.Socket.Options.CollectHttpResponseDetails = true;
                    c.Cancellation.CancelAfter(options.StartupTimeout);
                    await c.Socket.ConnectAsync(options.Endpoint, c.Cancellation.Token).ConfigureAwait(false);
                    lock (gate) Enqueue(c, OpenAILiveProtocol.Start(model, speaker, scenario, language, context), bounded: false);
                    sender = SendAsync(c);
                    receiver = ReceiveAsync(c);
                    var finished = await Task.WhenAny(sender, receiver, c.Overflow.Task).ConfigureAwait(false);
                    if (finished == c.Overflow.Task) throw new CopilotException(OpenAILiveProtocol.UploadTooSlowMessage);
                    await finished.ConfigureAwait(false);
                    return; // A session.closed event is the only successful receiver completion.
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { return; }
                catch (Exception error)
                {
                    if (c.Cancellation.IsCancellationRequested) failure = OpenAILiveProtocol.StartupTimeoutMessage;
                    else if (error is ServiceHTTPFailure service) { failure = service.Message; retry = false; }
                    else if ((int)c.Socket.HttpStatusCode is 400 or 401 or 402 or 403 or 404 or 429)
                    { failure = new ServiceHTTPFailure((int)c.Socket.HttpStatusCode).Message; retry = false; }
                    else if (error is CopilotException) failure = OpenAILiveProtocol.UploadTooSlowMessage;
                    else failure = OpenAILiveProtocol.TransportFailure(error);
                }
                finally
                {
                    lock (gate) { ready = false; connection = null; }
                    c.Cancellation.Cancel(); c.Socket.Abort();
                    // Observe both tasks before disposing the socket or opening a new generation.
                    foreach (var task in new[] { sender, receiver })
                        if (task is not null) { try { await task.ConfigureAwait(false); } catch (Exception) { } }
                }
                lock (gate)
                {
                    if (closing) return;
                    retry &= attempt < options.MaximumRetries;
                    OnEvent?.Invoke(new LiveEvent.Failed(failure!, retry));
                }
                if (!retry) return;
                await Task.Delay(options.RetryDelay * (1 << attempt), lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        finally
        {
            lock (gate)
            {
                ready = false;
                if (!closed) { closed = true; OnEvent?.Invoke(new LiveEvent.Closed(false)); }
            }
        }
    }

    private async Task SendAsync(Connection c)
    {
        await foreach (var data in c.Queue.Reader.ReadAllAsync(c.Cancellation.Token).ConfigureAwait(false))
        {
            await c.Socket.SendAsync(data.AsMemory(), WebSocketMessageType.Text, true, c.Cancellation.Token).ConfigureAwait(false);
            lock (gate) c.QueuedBytes -= data.Length;
        }
    }

    private async Task ReceiveAsync(Connection c)
    {
        var buffer = new byte[8192];
        using var message = new MemoryStream();
        while (true)
        {
            var result = await c.Socket.ReceiveAsync(buffer.AsMemory(), c.Cancellation.Token).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) throw new WebSocketException();
            if (message.Length + result.Count > 1_048_576) throw new WebSocketException();
            message.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage) continue;
            var bytes = message.ToArray();
            var value = OpenAILiveProtocol.Parse(bytes, speaker);
            message.SetLength(0);
            lock (gate)
            {
                if (connection != c || closed) return;
                switch (value)
                {
                    case LiveEvent.Ready:
                        if (closing) continue;
                        ready = true; c.Cancellation.CancelAfter(Timeout.InfiniteTimeSpan); break;
                    case LiveEvent.Transcript transcript:
                        context = TextElements.Suffix(context + transcript.Fragment.Text, 6000); break;
                    case LiveEvent.Failed:
                        // Reuse the category parser; never surface server prose or raw exceptions.
                        throw new ServiceHTTPFailure(0, bytes);
                    case LiveEvent.Closed:
                        closed = true; OnEvent?.Invoke(value); return;
                }
                if (value is not null) OnEvent?.Invoke(value);
            }
        }
    }

    public Task DisconnectAsync()
    {
        lock (gate)
        {
            if (shutdown is not null) return shutdown;
            closing = true;
            if (ready && !closed && connection is { } c)
            {
                while (c.Queue.Reader.TryRead(out var data)) c.QueuedBytes -= data.Length;
                Enqueue(c, JsonSerializer.SerializeToUtf8Bytes(new { type = "session.close", event_id = Guid.NewGuid().ToString() }), bounded: false);
            }
            else lifetime.Cancel();
            shutdown = Task.Run(CloseAsync);
            return shutdown;
        }
    }
    private async Task CloseAsync()
    {
        try { if (worker is not null) await worker.WaitAsync(options.CloseTimeout).ConfigureAwait(false); }
        catch (TimeoutException) { lifetime.Cancel(); if (worker is not null) await worker.ConfigureAwait(false); }
        lock (gate)
        {
            if (!closed) { closed = true; OnEvent?.Invoke(new LiveEvent.Closed(false)); }
        }
        lifetime.Dispose();
    }
    public async ValueTask DisposeAsync() => await DisconnectAsync().ConfigureAwait(false);

    private sealed class Connection(CancellationToken token) : IDisposable
    {
        public ClientWebSocket Socket { get; } = new();
        public CancellationTokenSource Cancellation { get; } = CancellationTokenSource.CreateLinkedTokenSource(token);
        public Channel<byte[]> Queue { get; } = Channel.CreateUnbounded<byte[]>(new() { AllowSynchronousContinuations = false });
        public TaskCompletionSource Overflow { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int QueuedBytes { get; set; }
        public void Dispose() { Cancellation.Dispose(); Socket.Dispose(); }
    }
}
