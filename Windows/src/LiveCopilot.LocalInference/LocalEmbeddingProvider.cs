using System.Text;
using LiveCopilot.Core;
using LLama.Common;
using LLama.Native;

namespace LiveCopilot.LocalInference;

public static class EmbeddingContract
{
    public const int Dimensions = 1024;
    public const int MaximumTokens = 8192;
    public const int MaximumUtf8Bytes = 100000;
    public static void ValidateText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var bytes = Encoding.UTF8.GetByteCount(text);
        if (bytes is 0 or > MaximumUtf8Bytes) throw new ArgumentException("Embedding text must contain 1–100000 UTF-8 bytes.", nameof(text));
    }
    public static int Capacity(int tokenCount)
    {
        if (tokenCount is <= 0 or > MaximumTokens) throw new ArgumentException("Embedding input must contain 1–8192 tokens.", nameof(tokenCount));
        var size = 512;
        while (size < tokenCount) size *= 2;
        return size;
    }
    public static ModelParams Parameters(string file, int capacity, bool cpu) => new(file)
    {
        ContextSize = (uint)capacity, BatchSize = (uint)capacity, UBatchSize = (uint)capacity,
        Embeddings = true, PoolingType = LLamaPoolingType.CLS,
        Threads = 4, BatchThreads = 4, GpuLayerCount = cpu ? 0 : 99,
        NoKqvOffload = cpu, OpOffload = !cpu
    };
    public static ValueList<float> Normalize(IReadOnlyList<float> vector)
    {
        if (vector.Count != Dimensions || vector.Any(x => !float.IsFinite(x)))
            throw new InvalidDataException("Local embedding must contain 1024 finite values.");
        var norm = Math.Sqrt(vector.Sum(x => (double)x * x));
        if (norm <= 0) throw new InvalidDataException("Local embedding must not be all zero.");
        return new(vector.Select(x => (float)(x / norm)));
    }
}

public interface ILocalEmbeddingEngine : IDisposable
{
    InferenceBackend Backend { get; }
    IReadOnlyList<BackendAttempt> BackendAttempts => [];
    int CountTokens(string text);
    Task<float[]> EmbedAsync(string text, int capacity, CancellationToken cancellationToken);
}

public sealed class LocalEmbeddingProvider : ILocalEmbeddingPreparing, IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<ILocalEmbeddingEngine>> factory;
    private readonly SemaphoreSlim serial = new(1, 1);
    private ILocalEmbeddingEngine? engine;
    private volatile bool prepared, disposed;
    public string Model => AppPaths.LocalEmbeddingIdentity;
    public bool IsPrepared => prepared;
    public InferenceBackend? Backend => engine?.Backend;
    public IReadOnlyList<BackendAttempt> BackendAttempts => engine?.BackendAttempts ?? [];

    public LocalEmbeddingProvider(string? root = null, InferenceOptions? options = null)
        : this(ct => LlamaEmbeddingEngine.CreateAsync(root, options, ct)) { }
    public LocalEmbeddingProvider(Func<CancellationToken, Task<ILocalEmbeddingEngine>> engineFactory) => factory = engineFactory;

    public async Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!IsPrepared) await EmbedAsync(["warmup"], cancellationToken).ConfigureAwait(false);
    }
    public Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default) =>
        EmbedAsync(texts, _ => Task.CompletedTask, cancellationToken);

    public async Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, Func<int, Task> progress, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(texts); ArgumentNullException.ThrowIfNull(progress);
        ObjectDisposedException.ThrowIf(disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        List<ValueList<float>> vectors = [];
        foreach (var text in texts)
        {
            EmbeddingContract.ValidateText(text);
            await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                engine ??= await factory(cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                var capacity = EmbeddingContract.Capacity(engine.CountTokens(text));
                var vector = await engine.EmbedAsync(text, capacity, cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                vectors.Add(EmbeddingContract.Normalize(vector)); prepared = true;
            }
            catch { prepared = false; throw; }
            finally { serial.Release(); }
            // Release the native queue between items; progress may issue an interactive query.
            await progress(vectors.Count).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
        return vectors;
    }
    public async ValueTask DisposeAsync()
    {
        await serial.WaitAsync().ConfigureAwait(false);
        try { disposed = true; prepared = false; engine?.Dispose(); engine = null; }
        finally { serial.Release(); }
    }
}
