using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

public enum LocalModelState { NotInstalled, Downloading, Verifying, Installed, Failed, Deleting }

public sealed record LocalModelSnapshot(LocalModelState State, long DownloadedBytes, long TotalBytes,
    double BytesPerSecond, bool IsInstalled, bool HasFiles, string Message)
{
    public bool IsBusy => State is LocalModelState.Downloading or LocalModelState.Verifying or LocalModelState.Deleting;
    public double Progress => TotalBytes > 0 ? Math.Clamp(100d * DownloadedBytes / TotalBytes, 0, 100) : 0;
}

/// No UI/native loading. Notifications may originate on worker threads; disposal cancels and drains operations.
public sealed class LocalModelManager : IAsyncDisposable
{
    public delegate Task Downloader(ModelDownload item, string destination, Action<ModelTransferProgress> progress, CancellationToken cancellationToken);
    private sealed class Entry(LocalModelDefinition model, LocalModelSnapshot snapshot)
    {
        public LocalModelDefinition Model { get; } = model;
        public LocalModelSnapshot Snapshot { get; set; } = snapshot;
        public CancellationTokenSource? Cancellation { get; set; }
        public Task<bool>? Operation { get; set; }
    }
    private sealed class InsufficientSpaceException : IOException;
    private readonly object gate = new();
    private readonly Dictionary<LocalModelKind, Entry> entries;
    private readonly Downloader download;
    private readonly Func<string, long> availableBytes;
    private readonly HttpClient? ownedClient;
    private Task? shutdown;
    private bool disposed;
    private const long SpaceReserve = 16 * 1024 * 1024;
    public string Root { get; }
    public event Action<LocalModelKind>? Changed;

    public LocalModelManager(string? root = null, Downloader? downloader = null, Func<string, long>? availableBytes = null,
        IReadOnlyDictionary<LocalModelKind, LocalModelDefinition>? models = null)
    {
        Root = Path.GetFullPath(root ?? LocalModels.DefaultRoot);
        this.availableBytes = availableBytes ?? DiskAvailableBytes;
        if (downloader is null)
        {
            ownedClient = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            download = new ResumableModelDownloader(ownedClient).DownloadAsync;
        }
        else download = downloader;
        entries = (models ?? Enum.GetValues<LocalModelKind>().ToDictionary(k => k, LocalModels.Get))
            .ToDictionary(pair => pair.Key, pair =>
            {
                LocalModelInstaller.ValidateDefinition(pair.Value);
                var installed = pair.Value.IsInstalled(Root);
                return new Entry(pair.Value, new(installed ? LocalModelState.Installed : LocalModelState.NotInstalled,
                    installed ? pair.Value.EstimatedDownloadBytes : CachedBytes(pair.Value), pair.Value.EstimatedDownloadBytes, 0,
                    installed, Directory.Exists(pair.Value.Location(Root)) || Directory.Exists(Cache(pair.Value)),
                    installed ? "已安装" : "未安装"));
            });
        if (entries.Values.Select(e => e.Model.DirectoryName).Distinct(StringComparer.OrdinalIgnoreCase).Count() != entries.Count)
            throw new ArgumentException("Model directories must be unique.", nameof(models));
    }

    public LocalModelSnapshot Snapshot(LocalModelKind kind) { lock (gate) return entries[kind].Snapshot; }
    public Task<bool> StartAsync(LocalModelKind kind, CancellationToken cancellationToken = default) =>
        RunAsync(kind, LocalModelState.Downloading, InstallAsync, cancellationToken);
    public Task<bool> RetryAsync(LocalModelKind kind, CancellationToken cancellationToken = default) => StartAsync(kind, cancellationToken);
    public Task<bool> VerifyAsync(LocalModelKind kind, CancellationToken cancellationToken = default) =>
        RunAsync(kind, LocalModelState.Verifying, (entry, token) => entry.Model.RequireVerifiedAsync(Root, token), cancellationToken);
    public Task<bool> DeleteAsync(LocalModelKind kind, CancellationToken cancellationToken = default) =>
        RunAsync(kind, LocalModelState.Deleting, (entry, token) =>
        {
            token.ThrowIfCancellationRequested();
            if (Directory.Exists(entry.Model.Location(Root))) Directory.Delete(entry.Model.Location(Root), true);
            if (Directory.Exists(Cache(entry.Model))) Directory.Delete(Cache(entry.Model), true);
            return Task.CompletedTask;
        }, cancellationToken);

    public void Cancel(LocalModelKind kind)
    {
        lock (gate) entries[kind].Cancellation?.Cancel();
    }

    private Task<bool> RunAsync(LocalModelKind kind, LocalModelState state, Func<Entry, CancellationToken, Task> operation,
        CancellationToken cancellationToken)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var entry = entries[kind];
            if (entry.Operation is not null) return Task.FromResult(false);
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            entry.Cancellation = cancellation;
            entry.Snapshot = entry.Snapshot with { State = state, BytesPerSecond = 0, Message = Label(state) };
            return entry.Operation = Task.Run(async () =>
            {
                // Taking the gate in Notify/Snapshot ensures Operation is set before observers run.
                Notify(kind);
                string? failure = null;
                var cancelled = false;
                var success = false;
                try
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    Directory.CreateDirectory(Path.Combine(Root, ".downloads"));
                    // FileShare.None also serializes separate manager instances/processes using this root.
                    using var lease = new FileStream(Path.Combine(Root, ".downloads", entry.Model.DirectoryName + ".lock"),
                        FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                    await operation(entry, cancellation.Token).ConfigureAwait(false);
                    success = true;
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { cancelled = true; }
                catch (Exception error) { failure = Explain(error); }
                finally
                {
                    var installed = entry.Model.IsInstalled(Root);
                    lock (gate)
                    {
                        entry.Snapshot = entry.Snapshot with
                        {
                            State = failure is not null ? LocalModelState.Failed : installed ? LocalModelState.Installed : LocalModelState.NotInstalled,
                            IsInstalled = installed,
                            HasFiles = Directory.Exists(entry.Model.Location(Root)) || Directory.Exists(Cache(entry.Model)),
                            DownloadedBytes = installed ? entry.Model.EstimatedDownloadBytes : CachedBytes(entry.Model),
                            BytesPerSecond = 0,
                            Message = failure ?? (cancelled
                                ? installed ? "已取消；已安装文件保留。" : "已取消；已下载数据保留，可继续下载。"
                                : installed ? state == LocalModelState.Verifying ? "已安装，校验通过" : "已安装" : "未安装")
                        };
                        entry.Operation = null;
                        entry.Cancellation = null;
                        cancellation.Dispose();
                    }
                    Notify(kind);
                }
                return success;
            });
        }
    }

    private async Task InstallAsync(Entry entry, CancellationToken token)
    {
        var model = entry.Model;
        var kind = entries.Single(pair => ReferenceEquals(pair.Value, entry)).Key;
        // Retain cache on cancellation; installer uses a separate full-size stage and preserves the old install.
        var needed = checked(2 * model.EstimatedDownloadBytes - CachedBytes(model) + SpaceReserve);
        if (availableBytes(Root) < needed) throw new InsufficientSpaceException();
        var cache = Cache(model);
        Directory.CreateDirectory(cache);
        var counts = model.Downloads.ToDictionary(item => item.InstalledName, item => CachedFileBytes(model, item));
        foreach (var item in model.Downloads)
        {
            token.ThrowIfCancellationRequested();
            var file = Path.Combine(cache, item.InstalledName);
            void Progress(ModelTransferProgress progress)
            {
                counts[item.InstalledName] = Math.Clamp(progress.BytesReceived, 0, item.KnownByteCount);
                var phase = progress.IsVerifying ? LocalModelState.Verifying : LocalModelState.Downloading;
                lock (gate) entry.Snapshot = entry.Snapshot with
                { State = phase, DownloadedBytes = counts.Values.Sum(), BytesPerSecond = progress.BytesPerSecond, Message = Label(phase) };
                Notify(kind);
            }
            var cached = false;
            if (File.Exists(file))
            {
                Progress(new(item.KnownByteCount, 0, true));
                try { await item.VerifyAsync(file, token).ConfigureAwait(false); cached = true; }
                catch (InvalidDataException) { File.Delete(file); }
            }
            if (!cached)
            {
                await download(item, file, Progress, token).ConfigureAwait(false);
                Progress(new(item.KnownByteCount, 0, true));
                try { await item.VerifyAsync(file, token).ConfigureAwait(false); }
                catch (InvalidDataException) { File.Delete(file); File.Delete(file + ".partial"); throw; }
            }
            counts[item.InstalledName] = item.KnownByteCount;
        }
        lock (gate) entry.Snapshot = entry.Snapshot with { State = LocalModelState.Verifying, BytesPerSecond = 0, Message = "校验并安装中" };
        Notify(kind);
        await LocalModelInstaller.InstallAsync(model, Root, async (item, destination, ct) =>
        {
            await using var input = File.OpenRead(Path.Combine(cache, item.InstalledName));
            await using var output = File.Create(destination);
            await input.CopyToAsync(output, ct).ConfigureAwait(false);
        }, token).ConfigureAwait(false);
        // Successful publication must remain successful even if optional cache cleanup fails.
        try { Directory.Delete(cache, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private string Cache(LocalModelDefinition model) => Path.Combine(Root, ".downloads", model.DirectoryName);
    private long CachedBytes(LocalModelDefinition model) => model.Downloads.Sum(item => CachedFileBytes(model, item));
    private long CachedFileBytes(LocalModelDefinition model, ModelDownload item)
    {
        try
        {
            var file = Path.Combine(Cache(model), item.InstalledName);
            return Math.Clamp(File.Exists(file) ? new FileInfo(file).Length : File.Exists(file + ".partial") ? new FileInfo(file + ".partial").Length : 0,
                0, item.KnownByteCount);
        }
        catch (IOException) { return 0; }
        catch (UnauthorizedAccessException) { return 0; }
    }

    private void Notify(LocalModelKind kind)
    {
        Action<LocalModelKind>? handlers;
        lock (gate) handlers = Changed;
        if (handlers is null) return;
        foreach (Action<LocalModelKind> observer in handlers.GetInvocationList())
        { try { observer(kind); } catch (Exception) { /* A closing view cannot break installation. */ } }
    }

    private static string Label(LocalModelState state) => state switch
    {
        LocalModelState.Downloading => "下载中", LocalModelState.Verifying => "校验中",
        LocalModelState.Deleting => "删除中", _ => "未安装"
    };
    private static string Explain(Exception error) => error switch
    {
        InsufficientSpaceException => "磁盘空间不足，请释放空间后重试（需容纳下载缓存和安装副本）。",
        InvalidDataException => "模型大小或 SHA256 校验失败，请重试下载。",
        UnauthorizedAccessException => "无法访问模型目录，请检查目录权限。",
        HttpRequestException or OperationCanceledException => "下载失败，请检查网络连接后重试；已下载数据保留。",
        IOException => "模型文件操作失败，请检查磁盘空间、目录权限，或停止聆听及文档任务后重试。模型也可能正被另一应用使用。",
        CopilotException => "当前运行模式不允许下载模型。",
        _ => "模型操作失败，请重试。"
    };

    private static long DiskAvailableBytes(string root)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        var drive = DriveInfo.GetDrives().Where(d => path.StartsWith(d.RootDirectory.FullName, comparison))
            .OrderByDescending(d => d.RootDirectory.FullName.Length).First();
        return drive.AvailableFreeSpace;
    }

    public ValueTask DisposeAsync()
    {
        lock (gate)
        {
            if (shutdown is not null) return new(shutdown);
            disposed = true;
            foreach (var entry in entries.Values) entry.Cancellation?.Cancel();
            var pending = entries.Values.Select(e => e.Operation).OfType<Task<bool>>().ToArray();
            return new(shutdown = DrainAsync(pending));
        }
    }
    private async Task DrainAsync(Task<bool>[] pending)
    {
        await Task.WhenAll(pending).ConfigureAwait(false);
        ownedClient?.Dispose();
    }
}
