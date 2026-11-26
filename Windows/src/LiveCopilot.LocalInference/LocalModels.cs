using System.Security.Cryptography;
using System.Text.Json;
using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

public enum LocalModelKind { StreamingSpeech, Embedding, TerminologySpeech }

public sealed record ModelDownload(Uri Url, string Sha256, string Name, string InstalledName,
    long KnownByteCount, bool AvailableOnDistribution = true, IReadOnlyList<Uri>? Mirrors = null)
{
    public string OssKey => "local/" + Name;

    public async Task VerifyAsync(string file, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read,
            1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (input.Length != KnownByteCount) throw new InvalidDataException("Model file size verification failed.");
        var hash = await SHA256.HashDataAsync(input, cancellationToken).ConfigureAwait(false);
        if (!Convert.ToHexString(hash).Equals(Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Model SHA-256 verification failed. Reinstall the model.");
    }
}

public sealed record LocalModelDefinition(string DirectoryName, string DownloadSize, IReadOnlyList<ModelDownload> Downloads)
{
    public long EstimatedDownloadBytes => Downloads.Sum(x => x.KnownByteCount);
    public IReadOnlyList<string> Files => Downloads.Select(x => x.InstalledName).ToArray();
    public string Location(string root) => Path.Combine(root, DirectoryName);

    // Match the Mac receipt check. Full hashes are checked separately before native loading.
    public bool IsInstalled(string root)
    {
        try
        {
            var directory = Location(root);
            using var receipt = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "installed.json")));
            var properties = receipt.RootElement.EnumerateObject().ToArray();
            if (properties.Length != Files.Count || !properties.Select(x => x.Name).ToHashSet(StringComparer.Ordinal).SetEquals(Files)) return false;
            return properties.All(p => p.Value.TryGetInt64(out var size) && size > 0 &&
                new FileInfo(Path.Combine(directory, p.Name)) is { Exists: true } file &&
                (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0 && file.Length == size);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        { return false; }
    }

    public async Task RequireVerifiedAsync(string root, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsInstalled(root)) throw new InvalidDataException("Local model is missing or corrupt. Install it before using local inference.");
        foreach (var file in Downloads)
            await file.VerifyAsync(Path.Combine(Location(root), file.InstalledName), cancellationToken).ConfigureAwait(false);
    }
}

public static class LocalModels
{
    public static string DefaultRoot => Path.Combine(AppPaths.DataDirectory, "Models");
    private const string Paraformer = "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/8e40c43232a1c5c66c82111efc5820d3accca11b/";
    private const string ZipHf = "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/";
    private const string ZipMs = "https://modelscope.cn/models/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/fe4123ca09cd7efaef00fe0ed88219211bc5b77e/";
    public static Uri DistributionBase { get; } = new("https://modelscope.cn/models/careybk/livecopilot-model-assets/resolve/a5ba0b9be08e7d8f7438e3762791ac5b62c1e253/");
    private static ModelDownload Para(string file, string hash, long size) => new(new(Paraformer + file), hash, "paraformer-" + file, file, size);
    private static ModelDownload Zip(string file, string installed, string hash, long size, bool mirror = true) =>
        new(new(ZipHf + file), hash, "zipformer-" + file, installed, size, false,
            mirror ? Array.AsReadOnly<Uri>([new(ZipMs + file), new(ZipHf + file)]) : Array.Empty<Uri>());
    public static ModelDownload Vad { get; } = new(new("https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"),
        "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", "silero_vad.onnx", "silero_vad.onnx", 643854);
    private static readonly LocalModelDefinition Streaming = new("paraformer-streaming-zh-en-int8-v1", "238 MB", Array.AsReadOnly<ModelDownload>([
        Para("encoder.int8.onnx", "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a", 165462184),
        Para("decoder.int8.onnx", "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f", 71664561),
        Para("tokens.txt", "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6", 75756), Vad]));
    private static readonly LocalModelDefinition Terms = new("zipformer-streaming-zh-en-hotwords-v1", "200 MB", Array.AsReadOnly<ModelDownload>([
        Zip("encoder-epoch-99-avg-1.int8.onnx", "encoder.int8.onnx", "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b", 181895032),
        Zip("decoder-epoch-99-avg-1.onnx", "decoder.onnx", "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d", 13876452),
        Zip("joiner-epoch-99-avg-1.int8.onnx", "joiner.int8.onnx", "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0", 3228404),
        Zip("tokens.txt", "tokens.txt", "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3", 56317),
        Zip("bpe.vocab", "bpe.vocab", "d0b642f3a2eacd5fadefdeff9e0e1358cab729647cbb7fe58cf738e1f7407029", 12564, false), Vad]));
    private static readonly LocalModelDefinition Embedding = new("bge-m3-q8-v1", "635 MB", Array.AsReadOnly<ModelDownload>([
        new(new("https://huggingface.co/gpustack/bge-m3-GGUF/resolve/2d48f1737679ad900d5c26c5aad5410e9c70fdca/bge-m3-Q8_0.gguf"),
            "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167", "bge-m3-Q8_0.gguf", "bge-m3-Q8_0.gguf", 634553760,
            Mirrors: Array.AsReadOnly<Uri>([new("https://modelscope.cn/models/gpustack/bge-m3-GGUF/resolve/master/bge-m3-Q8_0.gguf")]))]));
    public static LocalModelDefinition Get(LocalModelKind kind) => kind switch
    {
        LocalModelKind.StreamingSpeech => Streaming,
        LocalModelKind.TerminologySpeech => Terms,
        LocalModelKind.Embedding => Embedding,
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
