using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace LiveCopilot.LocalInference.Tests;

public sealed class ModelDownloadTests
{
    internal static readonly byte[] Payload = [1, 2, 3, 4];
    internal static ModelDownload Item => new(new("https://origin.invalid/model"),
        Convert.ToHexString(SHA256.HashData(Payload)), "payload", "payload.bin", Payload.Length, false);
    internal static LocalModelDefinition Model => new("test-model", "4 B", [Item]);

    [Fact]
    public async Task ReportsBytesSpeedAndVerificationBeforeAtomicallyReplacingDestination()
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllTextAsync(destination, "previous");
        using var handler = new Handler(_ => Response(Payload));
        using var client = new HttpClient(handler);
        var progress = new List<ModelTransferProgress>();
        await new ResumableModelDownloader(client).DownloadAsync(Item, destination, value =>
        {
            Assert.Equal("previous", File.ReadAllText(destination));
            progress.Add(value);
        });
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
        Assert.Contains(progress, p => p.BytesReceived == 4 && p.BytesPerSecond > 0 && !p.IsVerifying);
        Assert.True(progress[^1].IsVerifying);
        Assert.False(File.Exists(destination + ".partial"));
    }

    [Fact]
    public async Task FallsBackInCandidateOrderOnHttpAndHashFailures()
    {
        using var temp = new TemporaryDirectory();
        var item = Item with { AvailableOnDistribution = true, Mirrors = [new("https://mirror.invalid/model")] };
        using var handler = new Handler(request => request.RequestUri!.Host switch
        {
            "modelscope.cn" => new(HttpStatusCode.ServiceUnavailable),
            "mirror.invalid" => Response([9, 9, 9, 9]),
            _ => Response(Payload)
        });
        using var client = new HttpClient(handler);
        var destination = Path.Combine(temp.Path, "model");
        await new ResumableModelDownloader(client).DownloadAsync(item, destination, _ => { });
        Assert.Equal(LocalModelInstaller.CandidateUrls(item), handler.Requests.Select(x => x.Url));
        Assert.All(handler.Requests, request => Assert.Null(request.Range));
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ResumesWithRangeOrRestartsWhenServerIgnoresIt(bool supportsRange)
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllBytesAsync(destination + ".partial", Payload[..2]);
        using var handler = new Handler(_ => supportsRange ? RangedResponse(Payload[2..], 2) : Response(Payload));
        using var client = new HttpClient(handler);
        var progress = new List<ModelTransferProgress>();
        await new ResumableModelDownloader(client).DownloadAsync(Item, destination, progress.Add);
        Assert.Equal("bytes=2-", Assert.Single(handler.Requests).Range);
        Assert.Equal(supportsRange ? 2 : 0, progress[0].BytesReceived);
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task UnsatisfiedOrWrongRangeRetriesSameUrlFromZero(bool unsatisfied)
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllBytesAsync(destination + ".partial", Payload[..2]);
        using var handler = new Handler(request => request.Headers.Range is null ? Response(Payload)
            : unsatisfied ? new(HttpStatusCode.RequestedRangeNotSatisfiable) : RangedResponse(Payload[2..], 1));
        using var client = new HttpClient(handler);
        await new ResumableModelDownloader(client).DownloadAsync(Item, destination, _ => { });
        Assert.Equal(["bytes=2-", null], handler.Requests.Select(x => x.Range));
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Fact]
    public async Task TruncatedTransferContinuesFromNextMirror()
    {
        using var temp = new TemporaryDirectory();
        var item = Item with { Mirrors = [new("https://mirror.invalid/model")] };
        using var handler = new Handler(request => request.RequestUri!.Host == "mirror.invalid"
            ? new(HttpStatusCode.OK) { Content = new StreamContent(new PrefixStream(Payload[..2], _ => Task.FromException(new IOException("connection dropped")))) }
            : RangedResponse(Payload[2..], 2));
        using var client = new HttpClient(handler);
        var destination = Path.Combine(temp.Path, "model");
        await new ResumableModelDownloader(client).DownloadAsync(item, destination, _ => { });
        Assert.Equal([null, "bytes=2-"], handler.Requests.Select(x => x.Range));
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.NotImplemented)]
    public async Task ServerRejectingRangeRetriesWithoutIt(HttpStatusCode rejection)
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllBytesAsync(destination + ".partial", Payload[..2]);
        using var handler = new Handler(request => request.Headers.Range is null ? Response(Payload) : new(rejection));
        using var client = new HttpClient(handler);
        await new ResumableModelDownloader(client).DownloadAsync(Item, destination, _ => { });
        Assert.Equal(["bytes=2-", null], handler.Requests.Select(x => x.Range));
        Assert.All(handler.Requests, request => Assert.Equal(Item.Url, request.Url));
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Fact]
    public async Task CancellationBeforeVerificationPreservesDestinationAndResumesWithoutNetwork()
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllTextAsync(destination, "previous");
        using var handler = new Handler(_ => Response(Payload));
        using var client = new HttpClient(handler);
        using var cancellation = new CancellationTokenSource();
        var downloader = new ResumableModelDownloader(client);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => downloader.DownloadAsync(Item, destination,
            progress => { if (progress.IsVerifying) cancellation.Cancel(); }, cancellation.Token));
        Assert.Equal("previous", await File.ReadAllTextAsync(destination));
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination + ".partial"));
        await downloader.DownloadAsync(Item, destination, _ => { });
        Assert.Single(handler.Requests);
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
        Assert.False(File.Exists(destination + ".partial"));
    }

    [Fact]
    public async Task HashMismatchDeletesPartialAndPreservesOldDestination()
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllTextAsync(destination, "previous");
        using var handler = new Handler(_ => Response([4, 3, 2, 1]));
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ResumableModelDownloader(client).DownloadAsync(Item, destination, _ => { }));
        Assert.False(File.Exists(destination + ".partial"));
        Assert.Equal("previous", await File.ReadAllTextAsync(destination));
    }

    [Theory]
    [InlineData(4)]
    [InlineData(5)]
    public async Task CompletePartialIsVerifiedAndOversizedPartialIsDiscarded(int size)
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        await File.WriteAllBytesAsync(destination + ".partial", size == 4 ? Payload : [1, 2, 3, 4, 5]);
        using var handler = new Handler(_ => Response(Payload));
        using var client = new HttpClient(handler);
        await new ResumableModelDownloader(client).DownloadAsync(Item, destination, _ => { });
        Assert.Equal(size == 4 ? 0 : 1, handler.Requests.Count);
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
    }

    [Fact]
    public async Task OversizedBodyWithoutContentLengthIsBoundedAndDeleted()
    {
        using var temp = new TemporaryDirectory();
        var destination = Path.Combine(temp.Path, "model");
        using var handler = new Handler(_ => new(HttpStatusCode.OK)
        { Content = new StreamContent(new PrefixStream([1, 2, 3, 4, 5], _ => Task.CompletedTask)) });
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ResumableModelDownloader(client).DownloadAsync(Item, destination, _ => { }));
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    [Fact]
    public async Task PreCancelledDownloadDoesNotSendOrCreateFiles()
    {
        using var temp = new TemporaryDirectory();
        using var handler = new Handler(_ => throw new InvalidOperationException("must not send"));
        using var client = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ResumableModelDownloader(client)
            .DownloadAsync(Item, Path.Combine(temp.Path, "model"), _ => { }, new(true)));
        Assert.Empty(handler.Requests);
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    internal static HttpResponseMessage Response(byte[] bytes) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
    internal static HttpResponseMessage RangedResponse(byte[] bytes, long offset)
    {
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(bytes) };
        response.Content.Headers.ContentRange = new ContentRangeHeaderValue(offset, 3, 4);
        return response;
    }
    internal sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<(Uri Url, string? Range)> Requests { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.RequestUri!, request.Headers.Range?.ToString()));
            return Task.FromResult(respond(request));
        }
    }
    // Nonseekable, unknown-length network body. The second read can block/fail after a durable prefix.
    internal sealed class PrefixStream(byte[] prefix, Func<CancellationToken, Task> afterPrefix) : Stream
    {
        private int position;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => position; set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (position == prefix.Length) { await afterPrefix(cancellationToken); return 0; }
            var count = Math.Min(prefix.Length - position, buffer.Length);
            prefix.AsMemory(position, count).CopyTo(buffer); position += count;
            return count;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
    }
}
