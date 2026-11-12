using System.Net;
using System.Security.Cryptography;
using System.Text.Json;

namespace LiveCopilot.LocalInference.Tests;

public sealed class ModelTests
{
    private static readonly byte[] Payload = [1, 2, 3, 4];
    private static ModelDownload Item => new(new("https://example.invalid/model"),
        Convert.ToHexString(SHA256.HashData(Payload)), "payload", "payload.bin", Payload.Length);
    private static LocalModelDefinition Model => new("test-model", "4 bytes", [Item]);
    private static Task Download(ModelDownload item, string destination, CancellationToken ct) => File.WriteAllBytesAsync(destination, Payload, ct);

    [Fact]
    public async Task InstallWritesReceiptAndVerifiesUnderInjectedRoot()
    {
        using var temp = new TemporaryDirectory();
        Assert.False(Model.IsInstalled(temp.Path));
        await LocalModelInstaller.InstallAsync(Model, temp.Path, Download);
        Assert.True(Model.IsInstalled(temp.Path));
        await Model.RequireVerifiedAsync(temp.Path);
        Assert.Equal("{\"payload.bin\":4}", await File.ReadAllTextAsync(System.IO.Path.Combine(Model.Location(temp.Path), "installed.json")));
        Assert.Single(Directory.GetDirectories(temp.Path));
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("truncated")]
    [InlineData("malformed")]
    [InlineData("extra")]
    [InlineData("duplicate")]
    [InlineData("zero")]
    public async Task ReceiptAndPayloadDamageAreNotInstalled(string damage)
    {
        using var temp = new TemporaryDirectory();
        await LocalModelInstaller.InstallAsync(Model, temp.Path, Download);
        var file = System.IO.Path.Combine(Model.Location(temp.Path), Item.InstalledName);
        var receipt = System.IO.Path.Combine(Model.Location(temp.Path), "installed.json");
        switch (damage)
        {
            case "missing": File.Delete(file); break;
            case "truncated": await File.WriteAllBytesAsync(file, [1]); break;
            case "malformed": await File.WriteAllTextAsync(receipt, "[]"); break;
            case "extra": await File.WriteAllTextAsync(receipt, "{\"payload.bin\":4,\"extra\":1}"); break;
            case "duplicate": await File.WriteAllTextAsync(receipt, "{\"payload.bin\":4,\"payload.bin\":4}"); break;
            case "zero": await File.WriteAllTextAsync(receipt, "{\"payload.bin\":0}"); break;
        }
        Assert.False(Model.IsInstalled(temp.Path));
        await Assert.ThrowsAsync<InvalidDataException>(() => Model.RequireVerifiedAsync(temp.Path));
    }

    [Fact]
    public async Task SameLengthCorruptionIsCaughtBeforeNativeLoading()
    {
        using var temp = new TemporaryDirectory();
        await LocalModelInstaller.InstallAsync(Model, temp.Path, Download);
        await File.WriteAllBytesAsync(System.IO.Path.Combine(Model.Location(temp.Path), Item.InstalledName), [4, 3, 2, 1]);
        Assert.True(Model.IsInstalled(temp.Path)); // receipt is the cheap Mac-compatible check
        await Assert.ThrowsAsync<InvalidDataException>(() => Model.RequireVerifiedAsync(temp.Path));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedOrCancelledReplacementPreservesInstalledModel(bool cancel)
    {
        using var temp = new TemporaryDirectory();
        using var cts = new CancellationTokenSource();
        await LocalModelInstaller.InstallAsync(Model, temp.Path, Download);
        async Task Broken(ModelDownload item, string destination, CancellationToken ct)
        {
            await File.WriteAllBytesAsync(destination, [9, 9, 9, 9], ct);
            if (cancel) cts.Cancel();
        }
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => LocalModelInstaller.InstallAsync(Model, temp.Path, Broken, cts.Token));
        else await Assert.ThrowsAsync<InvalidDataException>(() => LocalModelInstaller.InstallAsync(Model, temp.Path, Broken));
        await Model.RequireVerifiedAsync(temp.Path);
        Assert.Single(Directory.GetDirectories(temp.Path));
    }

    [Fact]
    public async Task PreCancelledInstallAndHashDoNotTouchDisk()
    {
        using var temp = new TemporaryDirectory();
        var root = System.IO.Path.Combine(temp.Path, "unused");
        var token = new CancellationToken(true);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => LocalModelInstaller.InstallAsync(Model, root, Download, token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Item.VerifyAsync("absent", token));
        Assert.False(Directory.Exists(root));
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("..\\escape")]
    [InlineData("installed.json")]
    public async Task InstallerRejectsNonPayloadNames(string name)
    {
        using var temp = new TemporaryDirectory();
        await Assert.ThrowsAsync<ArgumentException>(() => LocalModelInstaller.InstallAsync(Model with { Downloads = [Item with { InstalledName = name }] }, temp.Path, Download));
        Assert.Empty(Directory.GetFileSystemEntries(temp.Path));
    }

    [Fact]
    public async Task DownloadTriesMirrorAfterHashFailureAndPublishesOnlyVerifiedFile()
    {
        using var temp = new TemporaryDirectory();
        var handler = new DownloadHandler();
        using var client = new HttpClient(handler);
        var destination = System.IO.Path.Combine(temp.Path, "download");
        await File.WriteAllTextAsync(destination, "previous");
        await LocalModelInstaller.DownloadAsync(client, Item, destination);
        Assert.Equal(2, handler.Calls);
        Assert.Equal(Payload, await File.ReadAllBytesAsync(destination));
        Assert.Single(Directory.GetFiles(temp.Path));
    }

    private sealed class DownloadHandler : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(++Calls == 1 ? [9, 9, 9, 9] : Payload) });
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProductionEnginesRejectMissingAndFakeReceipts(bool fakeReceipt)
    {
        using var temp = new TemporaryDirectory();
        if (fakeReceipt)
        {
            foreach (var kind in Enum.GetValues<LocalModelKind>())
            {
                var model = LocalModels.Get(kind);
                Directory.CreateDirectory(model.Location(temp.Path));
                foreach (var file in model.Files) await File.WriteAllBytesAsync(System.IO.Path.Combine(model.Location(temp.Path), file), [1]);
                await File.WriteAllTextAsync(System.IO.Path.Combine(model.Location(temp.Path), "installed.json"), JsonSerializer.Serialize(model.Files.ToDictionary(x => x, _ => 1)));
            }
        }
        var options = new InferenceOptions { ForceCpu = true };
        await Assert.ThrowsAsync<InvalidDataException>(() => SherpaSpeechEngine.CreateAsync(temp.Path, options: options));
        await Assert.ThrowsAsync<InvalidDataException>(() => SherpaSpeechEngine.CreateAsync(temp.Path, contextual: true, options: options));
        await using var embeddings = new LocalEmbeddingProvider(temp.Path, options);
        await Assert.ThrowsAsync<InvalidDataException>(() => embeddings.PrepareAsync());
        Assert.False(embeddings.IsPrepared);
    }

    [Fact]
    public void RegistryPinsMacDirectoriesAndFileSizes()
    {
        Assert.EndsWith(System.IO.Path.Combine("LiveCopilot", "Models"), LocalModels.DefaultRoot);
        Assert.Equal("paraformer-streaming-zh-en-int8-v1", LocalModels.Get(LocalModelKind.StreamingSpeech).DirectoryName);
        Assert.Equal("zipformer-streaming-zh-en-hotwords-v1", LocalModels.Get(LocalModelKind.TerminologySpeech).DirectoryName);
        var bge = Assert.Single(LocalModels.Get(LocalModelKind.Embedding).Downloads);
        Assert.Equal("bge-m3-Q8_0.gguf", bge.InstalledName);
        Assert.Equal(634553760, bge.KnownByteCount);
        Assert.Equal("950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167", bge.Sha256);
        Assert.Equal(643854, LocalModels.Vad.KnownByteCount);
        foreach (var kind in Enum.GetValues<LocalModelKind>())
            Assert.All(LocalModels.Get(kind).Downloads, x => { Assert.Equal(64, x.Sha256.Length); Assert.True(x.KnownByteCount > 0); });
    }
}
