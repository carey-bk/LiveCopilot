using System.Runtime.CompilerServices;

namespace LiveCopilot.Core;

public interface IHttpTransport
{
    Task<(byte[] Data, int Status)> DataAsync(HttpRequestMessage request, CancellationToken cancellationToken);
    IAsyncEnumerable<string> LinesAsync(HttpRequestMessage request, CancellationToken cancellationToken);
}

/// An injected client remains caller-owned. The deadline covers headers and body reads.
public sealed class HttpClientTransport : IHttpTransport, IDisposable
{
    private readonly HttpClient client;
    private readonly bool ownsClient;
    public HttpClientTransport(HttpClient? client = null)
    {
        ownsClient = client is null;
        this.client = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
    }

    public async Task<(byte[] Data, int Status)> DataAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var deadline = Deadline(cancellationToken);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        return (await response.Content.ReadAsByteArrayAsync(deadline.Token).ConfigureAwait(false), (int)response.StatusCode);
    }

    public async IAsyncEnumerable<string> LinesAsync(HttpRequestMessage request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        using var deadline = Deadline(cancellationToken);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
        var buffer = new byte[8192];
        if (!response.IsSuccessStatusCode)
        {
            var count = 0;
            while (count < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(count), deadline.Token).ConfigureAwait(false);
                if (read == 0) break;
                count += read;
            }
            throw new ServiceHTTPFailure((int)response.StatusCode, buffer[..count]);
        }
        var framer = new StreamingLines();
        int length;
        while ((length = await stream.ReadAsync(buffer, deadline.Token).ConfigureAwait(false)) > 0)
        {
            for (var i = 0; i < length; i++)
            {
                deadline.Token.ThrowIfCancellationRequested();
                if (framer.Consume(buffer[i]) is { } line) yield return line;
            }
        }
        if (framer.Finish() is { } last) yield return last;
    }

    private static CancellationTokenSource Deadline(CancellationToken token)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(token);
        source.CancelAfter(TimeSpan.FromSeconds(90));
        return source;
    }
    public void Dispose() { if (ownsClient) client.Dispose(); }
}
