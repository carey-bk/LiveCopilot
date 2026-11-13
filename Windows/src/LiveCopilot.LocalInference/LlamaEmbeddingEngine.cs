using System.Text;
using LLama;
using LLama.Native;

namespace LiveCopilot.LocalInference;

public sealed class LlamaEmbeddingEngine : ILocalEmbeddingEngine
{
    private static readonly object RuntimeGate = new();
    private readonly string modelPath;
    private LLamaWeights? weights;
    private LLamaContext? context;
    private int capacity;
    private bool disposed;
    private readonly List<BackendAttempt> attempts = [];
    public InferenceBackend Backend { get; private set; }
    public IReadOnlyList<BackendAttempt> BackendAttempts => attempts.AsReadOnly();
    public int ContextCapacity => capacity;

    public static async Task<ILocalEmbeddingEngine> CreateAsync(string? root = null, InferenceOptions? options = null, CancellationToken cancellationToken = default)
    {
        root ??= LocalModels.DefaultRoot;
        var model = LocalModels.Get(LocalModelKind.Embedding);
        await model.RequireVerifiedAsync(root, cancellationToken).ConfigureAwait(false);
        var engine = new LlamaEmbeddingEngine(Path.Combine(model.Location(root), model.Files[0]), options ?? new());
        try
        {
            try { await engine.LoadWeightsAsync(cancellationToken).ConfigureAwait(false); engine.EnsureContext(512); }
            catch (Exception e) when (engine.Backend != InferenceBackend.Cpu && e is not OperationCanceledException)
            { await engine.FallbackToCpuAsync(512, cancellationToken).ConfigureAwait(false); }
            cancellationToken.ThrowIfCancellationRequested();
            return engine;
        }
        catch { engine.Dispose(); throw; }
    }
    private LlamaEmbeddingEngine(string path, InferenceOptions options)
    {
        modelPath = path;
        lock (RuntimeGate)
        {
            if (!NativeLibraryConfig.LLama.LibraryHasLoaded)
            {
                var choices = BackendSelection.Embedding(options.HardwareProbe.Detect(), options.ForceCpu);
                NativeLibraryConfig.All.WithCuda(choices.Contains(InferenceBackend.Cuda))
                    .WithVulkan(choices.Contains(InferenceBackend.Vulkan)).WithAutoFallback(true);
            }
            var offload = NativeApi.llama_supports_gpu_offload();
            var metadata = NativeApi.GetLoadedNativeLibrary(NativeLibraryName.LLama)?.Metadata;
            Backend = options.ForceCpu || !offload ? InferenceBackend.Cpu
                : metadata?.UseCuda == true ? InferenceBackend.Cuda
                : metadata?.UseVulkan == true ? InferenceBackend.Vulkan : InferenceBackend.Cpu;
        }
        attempts.Add(new(Backend, "runtime_selected"));
    }
    private async Task LoadWeightsAsync(CancellationToken cancellationToken)
    {
        weights = await LLamaWeights.LoadFromFileAsync(EmbeddingContract.Parameters(modelPath, 512, Backend == InferenceBackend.Cpu), cancellationToken).ConfigureAwait(false);
        if (weights.EmbeddingSize != EmbeddingContract.Dimensions) throw new InvalidDataException("BGE-M3 must have 1024 output dimensions.");
        attempts.Add(new(Backend, "model_loaded"));
    }
    private void EnsureContext(int required)
    {
        if (context is not null && capacity >= required) return;
        context?.Dispose(); context = null; capacity = 0;
        context = weights!.CreateContext(EmbeddingContract.Parameters(modelPath, required, Backend == InferenceBackend.Cpu));
        context.NativeHandle.SetEmbeddings(true);
        capacity = required;
    }
    private async Task FallbackToCpuAsync(int required, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        attempts.Add(new(Backend, "allocation_or_inference_failed"));
        context?.Dispose(); context = null; weights?.Dispose(); weights = null; capacity = 0;
        Backend = InferenceBackend.Cpu;
        await LoadWeightsAsync(cancellationToken).ConfigureAwait(false);
        EnsureContext(required);
    }
    public int CountTokens(string text)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        EmbeddingContract.ValidateText(text);
        return weights!.Tokenize(text, add_bos: true, special: false, Encoding.UTF8).Length;
    }
    public async Task<float[]> EmbedAsync(string text, int capacity, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        EmbeddingContract.ValidateText(text);
        cancellationToken.ThrowIfCancellationRequested();
        var count = CountTokens(text);
        var required = EmbeddingContract.Capacity(count);
        if (capacity < required) throw new ArgumentException("Insufficient embedding capacity.", nameof(capacity));
        try { return await EvaluateAsync(text, required, cancellationToken).ConfigureAwait(false); }
        catch (Exception e) when (Backend != InferenceBackend.Cpu && e is not OperationCanceledException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await FallbackToCpuAsync(required, cancellationToken).ConfigureAwait(false);
            return await EvaluateAsync(text, required, cancellationToken).ConfigureAwait(false);
        }
    }
    private async Task<float[]> EvaluateAsync(string text, int required, CancellationToken cancellationToken)
    {
        EnsureContext(required);
        var tokens = weights!.Tokenize(text, add_bos: true, special: false, Encoding.UTF8);
        context!.NativeHandle.MemoryClear(true);
        var batch = new LLamaBatch();
        // Match the Mac batch: request every token's output, including CLS at
        // position zero. LLamaSharp 0.27 AddRange's flag is only logitsLast.
        for (var i = 0; i < tokens.Length; i++) batch.Add(tokens[i], i, LLamaSeqId.Zero, logits: true);
        // BGE is bidirectional; all tokens fit in one batch AND one microbatch.
        if (weights.NativeHandle.HasEncoder && !weights.NativeHandle.HasDecoder)
        {
            if (await context.EncodeAsync(batch, cancellationToken).ConfigureAwait(false) != EncodeResult.Ok)
                throw new InvalidOperationException("Local embedding encode failed.");
        }
        else if (await context.DecodeAsync(batch, cancellationToken).ConfigureAwait(false) != DecodeResult.Ok)
            throw new InvalidOperationException("Local embedding decode failed.");
        cancellationToken.ThrowIfCancellationRequested();
        return context.NativeHandle.GetEmbeddingsSeq(LLamaSeqId.Zero).ToArray();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; context?.Dispose(); weights?.Dispose(); context = null; weights = null;
    }
}
