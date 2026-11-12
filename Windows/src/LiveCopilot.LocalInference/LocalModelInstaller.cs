using System.Text.Json;

namespace LiveCopilot.LocalInference;

public static class LocalModelInstaller
{
    public delegate Task Downloader(ModelDownload item, string destination, CancellationToken cancellationToken);

    public static IReadOnlyList<Uri> CandidateUrls(ModelDownload item, Uri? distributionBase = null) =>
        (item.AvailableOnDistribution ? new[] { new Uri(distributionBase ?? LocalModels.DistributionBase, item.OssKey) } : [])
        .Concat(item.Mirrors ?? []).Append(item.Url).Distinct().ToArray();

    public static async Task DownloadAsync(HttpClient client, ModelDownload item, string destination, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var temporary = destination + ".download-" + Guid.NewGuid();
        Exception? last = null;
        try
        {
            foreach (var url in CandidateUrls(item))
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
                    response.EnsureSuccessStatusCode();
                    await using (var output = File.Create(temporary))
                        await response.Content.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
                    await item.VerifyAsync(temporary, cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    File.Move(temporary, destination, overwrite: true);
                    return;
                }
                catch (Exception e) when (!cancellationToken.IsCancellationRequested && e is IOException or InvalidDataException or HttpRequestException or OperationCanceledException)
                { last = e; File.Delete(temporary); }
            }
            throw new IOException("Model download or verification failed. Previous installation was preserved.", last);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static Task InstallAsync(LocalModelKind kind, string root, Downloader downloader, CancellationToken cancellationToken = default) =>
        InstallAsync(LocalModels.Get(kind), root, downloader, cancellationToken);

    // Callers serialize installs/removals for a root. Payload and backup stay on the same filesystem.
    public static async Task InstallAsync(LocalModelDefinition model, string root, Downloader downloader, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        static bool IsLeaf(string name) => !string.IsNullOrWhiteSpace(name) && name is not "." and not ".." &&
            name.IndexOfAny(['/', '\\', ':']) < 0 && !Path.IsPathRooted(name);
        if (!IsLeaf(model.DirectoryName) || model.Downloads.Count == 0 ||
            model.Downloads.Any(x => !IsLeaf(x.InstalledName) || x.InstalledName.Equals("installed.json", StringComparison.OrdinalIgnoreCase)) ||
            model.Files.Distinct(StringComparer.OrdinalIgnoreCase).Count() != model.Files.Count)
            throw new ArgumentException("Model directories and filenames must be unique leaf names.", nameof(model));
        Directory.CreateDirectory(root);
        var stage = Path.Combine(root, ".install-" + Guid.NewGuid());
        var previous = Path.Combine(root, ".previous-" + Guid.NewGuid());
        var destination = model.Location(root);
        Directory.CreateDirectory(stage);
        try
        {
            foreach (var item in model.Downloads)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var file = Path.Combine(stage, item.InstalledName);
                await downloader(item, file, cancellationToken).ConfigureAwait(false);
                await item.VerifyAsync(file, cancellationToken).ConfigureAwait(false);
            }
            await File.WriteAllTextAsync(Path.Combine(stage, "installed.json"),
                JsonSerializer.Serialize(model.Downloads.ToDictionary(x => x.InstalledName, x => x.KnownByteCount)), cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var existed = Directory.Exists(destination);
            if (existed) Directory.Move(destination, previous);
            try { Directory.Move(stage, destination); }
            catch { if (existed) Directory.Move(previous, destination); throw; }
            if (existed) TryDelete(previous);
        }
        finally { TryDelete(stage); }
    }

    private static void TryDelete(string directory)
    {
        try { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
