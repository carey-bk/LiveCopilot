using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace LiveCopilot.Testing;

// Loopback only. No credentials, DNS, external service or production dependency.
internal sealed class LocalLiveServer : IAsyncDisposable
{
    private readonly HttpListener listener = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Channel<Peer> connections = Channel.CreateUnbounded<Peer>();
    private readonly ConcurrentBag<Peer> peers = [];
    private readonly Task accept;
    public Uri Endpoint { get; }
    public bool AutoReady { get; set; } = true;
    public bool AutoClose { get; set; } = true;
    public int? RejectionStatus { get; set; }
    public ConcurrentQueue<(string? Authorization, string? Path)> Requests { get; } = new();
    public LocalLiveServer()
    {
        using var port = new TcpListener(IPAddress.Loopback, 0);
        port.Start();
        var number = ((IPEndPoint)port.LocalEndpoint).Port;
        port.Stop();
        listener.Prefixes.Add($"http://127.0.0.1:{number}/");
        listener.Start();
        Endpoint = new($"ws://127.0.0.1:{number}/v1/live/sessions");
        accept = AcceptAsync();
    }
    public async Task<Peer> NextAsync() => await connections.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    private async Task AcceptAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var request = await listener.GetContextAsync().WaitAsync(lifetime.Token);
                Requests.Enqueue((request.Request.Headers["Authorization"], request.Request.Url?.AbsolutePath));
                if (RejectionStatus is { } status) { request.Response.StatusCode = status; request.Response.Close(); continue; }
                var socket = (await request.AcceptWebSocketAsync(null)).WebSocket;
                var peer = new Peer(socket, request.Response, this, lifetime.Token);
                peers.Add(peer); connections.Writer.TryWrite(peer);
            }
        }
        catch (Exception) when (lifetime.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); listener.Close();
        await accept;
        foreach (var peer in peers) await peer.DisposeAsync();
        lifetime.Dispose();
    }
    internal sealed class Peer : IAsyncDisposable
    {
        private readonly WebSocket socket;
        private readonly HttpListenerResponse response;
        private readonly LocalLiveServer server;
        private readonly CancellationToken token;
        private readonly SemaphoreSlim send = new(1, 1);
        private readonly Channel<JsonElement> incoming = Channel.CreateUnbounded<JsonElement>();
        private readonly Task reader;
        public ConcurrentQueue<JsonElement> Messages { get; } = new();
        public string? FinalTranscript { get; set; }
        public Task Ended => reader;
        public Peer(WebSocket socket, HttpListenerResponse response, LocalLiveServer server, CancellationToken token)
        { this.socket = socket; this.response = response; this.server = server; this.token = token; reader = ReadAsync(); }
        public async Task<JsonElement> NextAsync(string type)
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            while (true)
            {
                var value = await incoming.Reader.ReadAsync(deadline.Token);
                if (value.GetProperty("type").GetString() == type) return value;
            }
        }
        public Task SendAsync(object value, bool fragmented = false) => SendRawAsync(JsonSerializer.SerializeToUtf8Bytes(value), fragmented);
        public async Task SendRawAsync(byte[] bytes, bool fragmented = false)
        {
            await send.WaitAsync(token);
            try
            {
                if (fragmented)
                {
                    var split = bytes.Length / 2;
                    await socket.SendAsync(bytes.AsMemory(0, split), WebSocketMessageType.Text, false, token);
                    await socket.SendAsync(bytes.AsMemory(split), WebSocketMessageType.Text, true, token);
                }
                else await socket.SendAsync(bytes.AsMemory(), WebSocketMessageType.Text, true, token);
            }
            finally { send.Release(); }
        }
        public void Abort() { socket.Abort(); response.Abort(); socket.Dispose(); }
        public async Task CloseTransportAsync() => await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "test", token);
        private async Task ReadAsync()
        {
            try
            {
                var buffer = new byte[8192];
                using var message = new MemoryStream();
                while (true)
                {
                    var result = await socket.ReceiveAsync(buffer.AsMemory(), token);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    message.Write(buffer, 0, result.Count);
                    if (!result.EndOfMessage) continue;
                    using var document = JsonDocument.Parse(message.ToArray());
                    message.SetLength(0);
                    var value = document.RootElement.Clone();
                    Messages.Enqueue(value); incoming.Writer.TryWrite(value);
                    if (value.GetProperty("type").GetString() == "session.start" && server.AutoReady)
                        await SendAsync(new { type = "session.started" });
                    if (value.GetProperty("type").GetString() == "session.close" && server.AutoClose)
                    {
                        if (FinalTranscript is { } final)
                            await SendAsync(new { type = "session.input_transcript.delta", event_id = "final", delta = final, start_ms = 2000, end_ms = 2200 });
                        await SendAsync(new { type = "session.closed" });
                    }
                }
            }
            catch (Exception error) when (error is OperationCanceledException or WebSocketException or ObjectDisposedException) { }
            finally { incoming.Writer.TryComplete(); }
        }
        public async ValueTask DisposeAsync() { socket.Abort(); await reader; socket.Dispose(); send.Dispose(); }
    }
}
