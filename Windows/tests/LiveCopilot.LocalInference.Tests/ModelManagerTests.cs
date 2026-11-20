using System.Collections.Concurrent;
using System.Net;
using LiveCopilot.Core;
using static LiveCopilot.LocalInference.Tests.ModelDownloadTests;

namespace LiveCopilot.LocalInference.Tests;

public sealed class ModelManagerTests
{
    private const LocalModelKind Kind = LocalModelKind.Embedding;
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);
    private static LocalModelManager Manager(string root, LocalModelManager.Downloader? download = null, Func<string, long>? space = null,
        LocalModelDefinition? model = null) => new(root, download ?? Download, space ?? (_ => long.MaxValue), new Dictionary<LocalModelKind, LocalModelDefinition> { [Kind] = model ?? Model });
    private static Task Download(ModelDownload item, string destination, Action<ModelTransferProgress> progress, CancellationToken ct) =>
        File.WriteAllBytesAsync(destination, Payload, ct);
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static string Cache(string root) => Path.Combine(root, ".downloads", Model.DirectoryName);

    [Fact]
    public async Task ProgressInstalledAndHashFailureStatesAreObservableAndChinese()
    {
        using var temp = new TemporaryDirectory();
        await using var manager = Manager(temp.Path, async (item, path, progress, ct) =>
        {
            progress(new(2, 123));
            await File.WriteAllBytesAsync(path, Payload, ct);
        });
        var snapshots = new ConcurrentQueue<LocalModelSnapshot>();
        manager.Changed += kind => snapshots.Enqueue(manager.Snapshot(kind));
        Assert.Equal(LocalModelState.NotInstalled, manager.Snapshot(Kind).State);
        Assert.True(await manager.StartAsync(Kind));
        Assert.Contains(snapshots, s => s.State == LocalModelState.Downloading && s.DownloadedBytes == 2 && s.TotalBytes == 4 && s.BytesPerSecond == 123 && s.Progress == 50);
        Assert.Contains(snapshots, s => s.State == LocalModelState.Verifying);
        Assert.Equal(LocalModelState.Installed, manager.Snapshot(Kind).State);
        Assert.True(await manager.VerifyAsync(Kind));
        await File.WriteAllBytesAsync(Path.Combine(Model.Location(temp.Path), Item.InstalledName), [4, 3, 2, 1]);
        Assert.False(await manager.VerifyAsync(Kind));
        Assert.Equal(LocalModelState.Failed, manager.Snapshot(Kind).State);
        Assert.Contains("校验失败", manager.Snapshot(Kind).Message);
    }

    [Fact]
    public async Task InsufficientSpaceFailsBeforeAnyDownloaderOrStage()
    {
        using var temp = new TemporaryDirectory();
        var calls = 0;
        await using var manager = Manager(temp.Path, (_, _, _, _) => { calls++; throw new InvalidOperationException(); }, _ => 0);
        Assert.False(await manager.StartAsync(Kind));
        Assert.Equal(0, calls);
        Assert.Contains("磁盘空间不足", manager.Snapshot(Kind).Message);
        Assert.Empty(Directory.GetDirectories(temp.Path, ".install-*"));
        Assert.False(Directory.Exists(Cache(temp.Path)));
        Assert.False(Model.IsInstalled(temp.Path));
    }

    [Fact]
    public async Task PreflightIncludesFullStageInAdditionToRemainingDownload()
    {
        using var temp = new TemporaryDirectory();
        Directory.CreateDirectory(Cache(temp.Path));
        await File.WriteAllBytesAsync(Path.Combine(Cache(temp.Path), Item.InstalledName + ".partial"), Payload[..2]);
        // 2 remaining bytes + 4-byte stage + 16 MiB reserve; one byte short must fail.
        await using var manager = Manager(temp.Path, space: _ => 16 * 1024 * 1024 + 5);
        Assert.False(await manager.StartAsync(Kind));
        Assert.Contains("磁盘空间不足", manager.Snapshot(Kind).Message);
    }

    [Fact]
    public async Task SameModelRejectsConcurrentStartVerifyDeleteUntilCancellationDrains()
    {
        using var temp = new TemporaryDirectory();
        var started = Signal(); var calls = 0;
        await using var manager = Manager(temp.Path, async (_, _, _, ct) =>
        { Interlocked.Increment(ref calls); started.SetResult(); await Task.Delay(Timeout.Infinite, ct); });
        var first = manager.StartAsync(Kind);
        await started.Task.WaitAsync(Deadline);
        Assert.False(await manager.StartAsync(Kind));
        Assert.False(await manager.RetryAsync(Kind));
        Assert.False(await manager.VerifyAsync(Kind));
        Assert.False(await manager.DeleteAsync(Kind));
        manager.Cancel(Kind);
        Assert.False(await first.WaitAsync(Deadline));
        Assert.Equal(1, calls);
        Assert.False(manager.Snapshot(Kind).IsBusy);
        Assert.Contains("已取消", manager.Snapshot(Kind).Message);
    }

    [Fact]
    public async Task CancelledHttpTransferResumesAfterManagerRecreation()
    {
        using var temp = new TemporaryDirectory();
        var waiting = Signal();
        using var handler = new Handler(_ => new(HttpStatusCode.OK)
        {
            Content = new StreamContent(new PrefixStream(Payload[..2], async ct =>
            { waiting.TrySetResult(); await Task.Delay(Timeout.Infinite, ct); }))
        });
        using var client = new HttpClient(handler);
        await using (var first = Manager(temp.Path, new ResumableModelDownloader(client).DownloadAsync))
        {
            var pending = first.StartAsync(Kind);
            await waiting.Task.WaitAsync(Deadline);
            first.Cancel(Kind);
            Assert.False(await pending.WaitAsync(Deadline));
            Assert.Equal(Payload[..2], await File.ReadAllBytesAsync(Path.Combine(Cache(temp.Path), Item.InstalledName + ".partial")));
            Assert.False(Model.IsInstalled(temp.Path));
        }
        using var resumed = new Handler(_ => RangedResponse(Payload[2..], 2));
        using var resumedClient = new HttpClient(resumed);
        await using var second = Manager(temp.Path, new ResumableModelDownloader(resumedClient).DownloadAsync);
        Assert.Equal(2, second.Snapshot(Kind).DownloadedBytes);
        Assert.True(await second.RetryAsync(Kind));
        Assert.Equal("bytes=2-", Assert.Single(resumed.Requests).Range);
        await Model.RequireVerifiedAsync(temp.Path);
        Assert.False(Directory.Exists(Cache(temp.Path)));
    }

    [Fact]
    public async Task FailedReplacementPreservesInstalledModelAndRetryRecovers()
    {
        using var temp = new TemporaryDirectory();
        await LocalModelInstaller.InstallAsync(Model, temp.Path, (item, file, ct) => File.WriteAllBytesAsync(file, Payload, ct));
        var calls = 0;
        await using var manager = Manager(temp.Path, async (_, file, _, ct) =>
            await File.WriteAllBytesAsync(file, ++calls == 1 ? [4, 3, 2, 1] : Payload, ct));
        Assert.False(await manager.StartAsync(Kind));
        Assert.True(manager.Snapshot(Kind).IsInstalled);
        await Model.RequireVerifiedAsync(temp.Path);
        Assert.Empty(Directory.GetFiles(Cache(temp.Path)));
        Assert.True(await manager.RetryAsync(Kind));
        Assert.Equal(2, calls);
        Assert.Equal(LocalModelState.Installed, manager.Snapshot(Kind).State);
    }

    [Fact]
    public async Task DeleteRemovesInstallationAndPartialCacheButKeepsOtherFiles()
    {
        using var temp = new TemporaryDirectory();
        await using var manager = Manager(temp.Path);
        Assert.True(await manager.StartAsync(Kind));
        Directory.CreateDirectory(Cache(temp.Path));
        await File.WriteAllBytesAsync(Path.Combine(Cache(temp.Path), Item.InstalledName + ".partial"), [1, 2]);
        var unrelated = Path.Combine(temp.Path, "unrelated");
        await File.WriteAllTextAsync(unrelated, "keep");
        Assert.True(await manager.DeleteAsync(Kind));
        Assert.False(Model.IsInstalled(temp.Path));
        Assert.False(Directory.Exists(Model.Location(temp.Path)));
        Assert.False(Directory.Exists(Cache(temp.Path)));
        Assert.False(manager.Snapshot(Kind).HasFiles);
        Assert.Equal(LocalModelState.NotInstalled, manager.Snapshot(Kind).State);
        Assert.Equal("keep", await File.ReadAllTextAsync(unrelated));
    }

    [Fact]
    public async Task DisposeCancelsWaitsAndIsIdempotent()
    {
        using var temp = new TemporaryDirectory();
        var started = Signal(); var finished = false;
        var manager = Manager(temp.Path, async (_, _, _, ct) =>
        {
            started.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, ct); }
            finally { finished = true; }
        });
        var operation = manager.StartAsync(Kind);
        await started.Task.WaitAsync(Deadline);
        await Task.WhenAll(manager.DisposeAsync().AsTask(), manager.DisposeAsync().AsTask()).WaitAsync(Deadline);
        Assert.True(finished);
        Assert.False(await operation);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => manager.StartAsync(Kind));
    }

    [Fact]
    public async Task SeparateManagersCannotMutateTheSameModelConcurrently()
    {
        using var temp = new TemporaryDirectory();
        var started = Signal();
        await using var first = Manager(temp.Path, async (_, _, _, ct) => { started.TrySetResult(); await Task.Delay(Timeout.Infinite, ct); });
        await using var second = Manager(temp.Path, (_, _, _, _) => throw new InvalidOperationException("must not download"));
        var pending = first.StartAsync(Kind);
        await started.Task.WaitAsync(Deadline);
        Assert.False(await second.StartAsync(Kind));
        Assert.Contains("另一应用", second.Snapshot(Kind).Message);
        first.Cancel(Kind);
        await pending.WaitAsync(Deadline);
    }

    [Fact]
    public async Task RetryKeepsEarlierVerifiedFilesAcrossMultiFileFailure()
    {
        using var temp = new TemporaryDirectory();
        var other = Item with { Name = "other", InstalledName = "other.bin" };
        var model = Model with { Downloads = [Item, other] };
        var firstCalls = 0; var secondCalls = 0;
        await using var manager = Manager(temp.Path, async (item, path, _, ct) =>
        {
            if (item.InstalledName == Item.InstalledName) firstCalls++;
            else if (++secondCalls == 1) throw new HttpRequestException("synthetic failure");
            await File.WriteAllBytesAsync(path, Payload, ct);
        }, model: model);
        Assert.False(await manager.StartAsync(Kind));
        Assert.Contains("网络", manager.Snapshot(Kind).Message);
        Assert.True(await manager.RetryAsync(Kind));
        Assert.Equal(1, firstCalls);
        Assert.Equal(2, secondCalls);
        await model.RequireVerifiedAsync(temp.Path);
    }

    [Fact]
    public async Task FailedEmbeddingPreparationCanUseNewlyInstalledModelWithoutRecreatingProvider()
    {
        using var temp = new TemporaryDirectory();
        await using var embeddings = new LocalEmbeddingProvider(async ct =>
        {
            await Model.RequireVerifiedAsync(temp.Path, ct);
            return new FakeEmbeddingEngine();
        });
        await Assert.ThrowsAsync<InvalidDataException>(() => embeddings.PrepareAsync());
        await using var manager = Manager(temp.Path);
        Assert.True(await manager.StartAsync(Kind));
        await embeddings.PrepareAsync();
        Assert.True(embeddings.IsPrepared);
        Assert.Single(await embeddings.EmbedAsync(["安装后立即使用"]));
    }

    [Fact]
    public async Task RestartedSpeechProviderCanLoadAfterInstallation()
    {
        using var temp = new TemporaryDirectory();
        async Task<ISpeechEngine> Factory(CancellationToken ct)
        { await Model.RequireVerifiedAsync(temp.Path, ct); return new FakeSpeechEngine(); }
        await using (var first = new LocalLiveProvider(Factory))
        {
            var events = new EventLog(); first.OnEvent = events.Add; first.Connect("");
            await events.Wait<LiveEvent.Failed>();
        }
        await using var manager = Manager(temp.Path);
        Assert.True(await manager.StartAsync(Kind));
        await using var next = new LocalLiveProvider(Factory);
        var ready = new EventLog(); next.OnEvent = ready.Add; next.Connect("");
        await ready.Wait<LiveEvent.Ready>();
    }

    [Fact]
    public async Task ObserverFailureCannotBreakInstallation()
    {
        using var temp = new TemporaryDirectory();
        await using var manager = Manager(temp.Path);
        manager.Changed += _ => throw new InvalidOperationException("view closed");
        Assert.True(await manager.StartAsync(Kind));
        await Model.RequireVerifiedAsync(temp.Path);
    }
}
