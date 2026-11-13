using System.Net;
using System.Text;

namespace LiveCopilot.Core.Tests;

public sealed class ReasoningHttpTests
{
    [Theory] [InlineData("\n")] [InlineData("\r\n")] [InlineData("\r")]
    public void FramesUtf8AndBlankEventBoundaries(string newline)
    {
        var framer = new StreamingLines(); var parser = new ServerSentEvents();
        var lines = new List<string>(); var events = new List<string>();
        foreach (var value in Encoding.UTF8.GetBytes("data: 中文🧪" + newline + "data:  second" + newline + newline + ": heartbeat" + newline + newline + "data:last"))
            if (framer.Consume(value) is { } line) lines.Add(line);
        if (framer.Finish() is { } final) lines.Add(final);
        Assert.Equal(new[] { "data: 中文🧪", "data:  second", "", ": heartbeat", "", "data:last" }, lines);
        foreach (var line in lines) if (parser.Consume(line) is { } payload) events.Add(payload);
        if (parser.Finish() is { } last) events.Add(last);
        Assert.Equal(new[] { "中文🧪\n second", "last" }, events);
        Assert.Null(framer.Finish()); Assert.Null(parser.Finish());
    }

    [Fact] public void EmptyDataIsAnEventButCommentsAndMetadataAreNot()
    {
        var parser = new ServerSentEvents();
        Assert.Null(parser.Consume("event: message")); Assert.Null(parser.Consume("id: 1"));
        Assert.Null(parser.Consume(": keepalive")); Assert.Null(parser.Consume(""));
        Assert.Null(parser.Consume("data:")); Assert.Equal("", parser.Consume(""));
        Assert.Null(parser.Consume("data:   spaced")); Assert.Equal("  spaced", parser.Finish());
    }

    [Fact] public void RejectsOversizedLineBeforeUnboundedAllocation()
    {
        var framer = new StreamingLines();
        for (var i = 0; i < StreamingLines.MaximumEventBytes; i++) Assert.Null(framer.Consume(65));
        var error = Assert.Throws<CopilotException>(() => framer.Consume(65));
        Assert.Equal("Reasoning stream contained an oversized event. Retry this question.", error.Message);
    }

    [Fact] public void BoundsWholeMultiLineEventsAndResetsAtBlankBoundary()
    {
        var parser = new ServerSentEvents(); var line = "data:" + new string('x', 600_000);
        parser.Consume(line);
        Assert.Throws<CopilotException>(() => parser.Consume(line));
        parser.Consume(""); parser.Consume(line); Assert.NotNull(parser.Finish());
    }

    [Fact] public void FramerBoundsRawMultiLineEventIncludingCrLfAndResetsAtBoundary()
    {
        var line = Encoding.UTF8.GetBytes("data: " + new string('x', 600_000) + "\r\n");
        var framer = new StreamingLines();
        foreach (var value in line) framer.Consume(value);
        framer.Consume(13); framer.Consume(10); // blank boundary resets the event budget
        foreach (var value in line) framer.Consume(value);
        Assert.Throws<CopilotException>(() => { foreach (var value in line) framer.Consume(value); });
        var manyShortLines = new StreamingLines();
        Assert.Throws<CopilotException>(() =>
        {
            for (var i = 0; i < StreamingLines.MaximumEventBytes / 3 + 1; i++)
            { manyShortLines.Consume(65); manyShortLines.Consume(13); manyShortLines.Consume(10); }
        });
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public void InvalidUtf8HasSafeClearMessage(bool atEof)
    {
        var framer = new StreamingLines(); framer.Consume(0xc3);
        var error = Assert.Throws<CopilotException>(() => { if (atEof) framer.Finish(); else framer.Consume(10); });
        Assert.Equal("Reasoning stream contained invalid text encoding. Retry this question.", error.Message);
    }

    [Fact] public async Task HttpTransportPreservesBlanksAcrossSingleByteReadsAndDisposesBody()
    {
        var stream = new CountingStream(Encoding.UTF8.GetBytes("data: 中\r\n\r\ndata: 文\n\n"), 1);
        using var client = Client(HttpStatusCode.OK, stream);
        using var transport = new HttpClientTransport(client);
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://test.invalid/stream");
        var lines = new List<string>();
        await foreach (var line in transport.LinesAsync(request)) lines.Add(line);
        Assert.Equal(new[] { "data: 中", "", "data: 文", "" }, lines);
        Assert.True(stream.Disposed);
    }

    [Theory]
    [InlineData(401, ServiceHTTPFailureKind.Authentication)]
    [InlineData(429, ServiceHTTPFailureKind.RateLimit)]
    [InlineData(403, ServiceHTTPFailureKind.Permission)]
    [InlineData(500, ServiceHTTPFailureKind.Service)]
    public async Task HttpFailuresReadAtMost8192BytesAndNeverExposeRawBody(int status, ServiceHTTPFailureKind kind)
    {
        var stream = new CountingStream(Encoding.UTF8.GetBytes(new string('x', 20_000)));
        using var client = Client((HttpStatusCode)status, stream);
        using var transport = new HttpClientTransport(client);
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://test.invalid/stream");
        var error = await Assert.ThrowsAsync<ServiceHTTPFailure>(async () => { await foreach (var _ in transport.LinesAsync(request)) { } });
        Assert.Equal(kind, error.Kind); Assert.Equal(kind.Message() + $" (HTTP {status})", error.Message);
        Assert.Equal(8192, stream.ReadBytes); Assert.True(stream.Disposed);
    }

    [Fact] public async Task HttpFailureUsesErrorCodeAndDataPathReturnsStatus()
    {
        var body = Encoding.UTF8.GetBytes("""{"error":{"code":"insufficient_quota","message":"untrusted provider body"}}""");
        using var client = Client(HttpStatusCode.TooManyRequests, new CountingStream(body));
        using var transport = new HttpClientTransport(client);
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://test.invalid/stream");
        var error = await Assert.ThrowsAsync<ServiceHTTPFailure>(async () => { await foreach (var _ in transport.LinesAsync(request)) { } });
        Assert.Equal(ServiceHTTPFailureKind.Billing, error.Kind);
        using var dataClient = Client(HttpStatusCode.Unauthorized, new CountingStream(body));
        using var dataTransport = new HttpClientTransport(dataClient);
        using var dataRequest = new HttpRequestMessage(HttpMethod.Post, "https://test.invalid/data");
        var result = await dataTransport.DataAsync(dataRequest, default);
        Assert.Equal(401, result.Status); Assert.Equal(body, result.Data);
    }

    [Fact] public async Task HttpTransportHonorsCancellationDuringBodyRead()
    {
        using var cancellation = new CancellationTokenSource();
        var stream = new CountingStream(Encoding.UTF8.GetBytes("data: first\n\ndata: later\n\n"), 1);
        using var client = Client(HttpStatusCode.OK, stream);
        using var transport = new HttpClientTransport(client);
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://test.invalid/stream");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in transport.LinesAsync(request, cancellation.Token)) cancellation.Cancel();
        });
        Assert.True(stream.Disposed);
    }

    private static HttpClient Client(HttpStatusCode status, Stream stream) => new(new Handler(status, stream));
    private sealed class Handler(HttpStatusCode status, Stream stream) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(status) { Content = new StreamContent(stream) });
    }
    private sealed class CountingStream(byte[] bytes, int chunkSize = int.MaxValue) : MemoryStream(bytes)
    {
        public int ReadBytes { get; private set; }
        public bool Disposed { get; private set; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = await base.ReadAsync(buffer[..Math.Min(buffer.Length, chunkSize)], cancellationToken);
            ReadBytes += count; return count;
        }
        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
    }
}
