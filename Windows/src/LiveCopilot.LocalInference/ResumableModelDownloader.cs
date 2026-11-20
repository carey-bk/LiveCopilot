using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

public sealed record ModelTransferProgress(long BytesReceived, double BytesPerSecond, bool IsVerifying = false);

/// Downloads into a persistent .partial beside the destination. Only verified bytes are published.
public sealed class ResumableModelDownloader(HttpClient client)
{
    public async Task DownloadAsync(ModelDownload item, string destination, Action<ModelTransferProgress> progress,
        CancellationToken cancellationToken = default)
    {
        AppRuntime.RequireInteractive("模型下载");
        cancellationToken.ThrowIfCancellationRequested();
        var partial = destination + ".partial";
        if (File.Exists(partial) && new FileInfo(partial).Length >= item.KnownByteCount)
        {
            try { await PublishAsync(); return; }
            catch (InvalidDataException) { File.Delete(partial); }
        }
        Exception? last = null;
        foreach (var url in LocalModelInstaller.CandidateUrls(item))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await TransferAsync(url).ConfigureAwait(false);
                await PublishAsync().ConfigureAwait(false);
                return;
            }
            catch (InvalidDataException error) { File.Delete(partial); last = error; }
            catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
                error is HttpRequestException or IOException or OperationCanceledException)
            { last = error; } // Keep a truncated transfer for the next mirror/retry.
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (last is InvalidDataException) throw new InvalidDataException("模型大小或 SHA256 校验失败，请重试。", last);
        throw new HttpRequestException("所有模型下载地址均失败，请检查网络后重试。", last);

        async Task PublishAsync()
        {
            progress(new(new FileInfo(partial).Length, 0, true));
            await item.VerifyAsync(partial, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(partial, destination, overwrite: true);
        }

        async Task TransferAsync(Uri url)
        {
            // One retry without Range when the server rejects it or returns an invalid Content-Range.
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(30));
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
                var range = response.Content.Headers.ContentRange;
                var validRange = range is { Unit: "bytes" } && range.From == offset &&
                    range.To == item.KnownByteCount - 1 && range.Length == item.KnownByteCount;
                if (offset > 0 && (response.StatusCode is HttpStatusCode.RequestedRangeNotSatisfiable or
                    HttpStatusCode.BadRequest or HttpStatusCode.NotImplemented ||
                    response.StatusCode == HttpStatusCode.PartialContent && !validRange))
                { File.Delete(partial); continue; }
                response.EnsureSuccessStatusCode();
                if (response.StatusCode == HttpStatusCode.OK) offset = 0;
                else if (response.StatusCode != HttpStatusCode.PartialContent || !validRange)
                    throw new InvalidDataException("模型服务器返回了无效的下载范围。");
                if (response.Content.Headers.ContentLength is { } length && length != item.KnownByteCount - offset)
                    throw new InvalidDataException("模型服务器返回的文件大小不符。");

                await using var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
                await using var output = new FileStream(partial, offset == 0 ? FileMode.Create : FileMode.Append,
                    FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
                var bytes = offset;
                var watch = Stopwatch.StartNew();
                var lastReport = TimeSpan.Zero;
                progress(new(bytes, 0));
                var buffer = new byte[81920];
                while (true)
                {
                    timeout.CancelAfter(TimeSpan.FromSeconds(30)); // Inactivity timeout, not a size-dependent total deadline.
                    var count = await input.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
                    if (count == 0) break;
                    if (bytes + count > item.KnownByteCount) throw new InvalidDataException("模型下载超过预期大小。");
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                    bytes += count;
                    if (watch.Elapsed - lastReport >= TimeSpan.FromMilliseconds(100) || bytes == item.KnownByteCount)
                    {
                        progress(new(bytes, (bytes - offset) / Math.Max(watch.Elapsed.TotalSeconds, 0.001)));
                        lastReport = watch.Elapsed;
                    }
                }
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                if (bytes != item.KnownByteCount) throw new IOException("模型下载中断，可重试续传。");
                return;
            }
            throw new InvalidDataException("模型服务器不支持有效的文件下载范围。");
        }
    }
}
