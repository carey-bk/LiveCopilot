namespace LiveCopilot.LocalInference.Tests;

// Missing weights SKIP; a present but corrupt installation FAILS. Nothing downloads
// in tests. Root may point at an installer-created cache outside the repository.
public sealed class ModelFactAttribute : FactAttribute
{
    public static string Root => Environment.GetEnvironmentVariable("LIVECOPILOT_MODEL_ROOT") ?? "/workspace/livecopilot-models";
    public ModelFactAttribute(LocalModelKind kind)
    {
        if (!Directory.Exists(LocalModels.Get(kind).Location(Root)))
            Skip = $"Missing external model {LocalModels.Get(kind).DirectoryName} under {Root}; no weights are downloaded by tests.";
    }
}

public sealed class NativeIntegrationTests
{
    [ModelFact(LocalModelKind.StreamingSpeech)]
    [Trait("Category", "Integration")]
    public async Task SherpaCpuProcessesPcmAndFlushes()
    {
        using var engine = await SherpaSpeechEngine.CreateAsync(ModelFactAttribute.Root, options: new() { ForceCpu = true });
        Assert.Equal(InferenceBackend.Cpu, engine.Backend);
        // Optional raw mono PCM16 LE / 16 kHz speech fixture. Otherwise exercise silence.
        var fixture = Environment.GetEnvironmentVariable("LIVECOPILOT_ASR_PCM");
        var pcm = fixture is null ? new byte[64000] : await File.ReadAllBytesAsync(fixture);
        Assert.NotEmpty(pcm);
        Assert.Equal(0, pcm.Length % 2);
        var finals = new List<SpeechSegmentResult>();
        for (var i = 0; i < pcm.Length; i += 3200)
            finals.AddRange(engine.Accept(pcm.AsMemory(i, Math.Min(3200, pcm.Length - i))).Segments);
        var flush = engine.Accept(ReadOnlyMemory<byte>.Empty, flush: true);
        finals.AddRange(flush.Segments);
        Assert.False(flush.Speaking);
        Assert.Equal("", flush.Partial);
        if (fixture is null) Assert.Empty(finals); else Assert.Contains(finals, x => !string.IsNullOrWhiteSpace(x.Text));
    }

    [ModelFact(LocalModelKind.Embedding)]
    [Trait("Category", "Integration")]
    public async Task BgeCpuProducesNormalizedVectorsAndRelevantSimilarity()
    {
        await using var provider = new LocalEmbeddingProvider(ModelFactAttribute.Root, new() { ForceCpu = true });
        await provider.PrepareAsync();
        var vectors = await provider.EmbedAsync(["The system latency is 42 milliseconds.", "系统延迟是多少毫秒？", "I like fresh apples and oranges."]);
        Assert.Equal(InferenceBackend.Cpu, provider.Backend);
        Assert.All(vectors, v =>
        {
            Assert.Equal(1024, v.Count);
            Assert.All(v, x => Assert.True(float.IsFinite(x)));
            Assert.InRange(v.Sum(x => (double)x * x), 0.9999, 1.0001);
        });
        static double Dot(IReadOnlyList<float> a, IReadOnlyList<float> b) => a.Zip(b).Sum(x => (double)x.First * x.Second);
        Assert.True(Dot(vectors[0], vectors[1]) > Dot(vectors[0], vectors[2]));
    }
}
