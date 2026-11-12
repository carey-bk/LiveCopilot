using LiveCopilot.Core;

namespace LiveCopilot.LocalInference.Tests;

public sealed class EmbeddingTests
{
    [Fact]
    public void TextByteLimitCountsUtf8Bytes()
    {
        EmbeddingContract.ValidateText(new string('a', 100000));
        Assert.Throws<ArgumentException>(() => EmbeddingContract.ValidateText(new string('a', 100001)));
        Assert.Throws<ArgumentException>(() => EmbeddingContract.ValidateText(new string('中', 33334)));
        Assert.Throws<ArgumentException>(() => EmbeddingContract.ValidateText(""));
    }

    [Fact]
    public async Task IdentityDimensionsNormalizationProgressAndPrepareMeetCoreContract()
    {
        var engine = new FakeEmbeddingEngine();
        var created = 0;
        await using var provider = new LocalEmbeddingProvider(_ => { created++; return Task.FromResult<ILocalEmbeddingEngine>(engine); });
        ILocalEmbeddingPreparing contract = provider;
        Assert.Equal("local:bge-m3:q8_0:950f4a8e5e19:cls:l2:v1", contract.Model);
        Assert.False(contract.IsPrepared);
        await contract.PrepareAsync();
        await contract.PrepareAsync();
        Assert.True(contract.IsPrepared);
        Assert.Single(engine.Calls);
        Assert.Equal("warmup", engine.Calls[0].Text);
        var progress = new List<int>();
        var vectors = await contract.EmbedAsync(["one", "two", "three"], n => { progress.Add(n); return Task.CompletedTask; });
        Assert.Equal([1, 2, 3], progress);
        Assert.Equal(3, vectors.Count);
        Assert.All(vectors, vector =>
        {
            Assert.Equal(1024, vector.Count);
            Assert.All(vector, x => Assert.True(float.IsFinite(x)));
            Assert.InRange(vector.Sum(x => (double)x * x), 0.999999, 1.000001);
            Assert.Equal(0.6f, vector[0]); Assert.Equal(0.8f, vector[1]);
        });
        Assert.Equal(1, created);
        Assert.Equal(InferenceBackend.Cpu, provider.Backend);
    }

    [Fact]
    public async Task ProgressRunsBetweenItemsAndCanIssueInteractiveQuery()
    {
        var engine = new FakeEmbeddingEngine();
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        await provider.EmbedAsync(["document one", "document two"], async n =>
        {
            if (n == 1) await provider.EmbedAsync(["query"]);
        }).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(["document one", "query", "document two"], engine.Calls.Select(x => x.Text));
    }

    [Fact]
    public async Task CancelBetweenItemsStopsProgressAndFurtherNativeCalls()
    {
        using var cts = new CancellationTokenSource();
        var engine = new FakeEmbeddingEngine();
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        var progress = new List<int>();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.EmbedAsync(["first", "second"], n =>
        { progress.Add(n); cts.Cancel(); return Task.CompletedTask; }, cts.Token));
        Assert.Equal([1], progress);
        Assert.Single(engine.Calls);
    }

    [Fact]
    public async Task CancellationIsPassedToNativeWorkAndDoesNotPublishVector()
    {
        using var cts = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var engine = new FakeEmbeddingEngine { Evaluate = async ct => { entered.SetResult(); await Task.Delay(Timeout.Infinite, ct); return []; } };
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        var calls = 0;
        var task = provider.EmbedAsync(["text"], _ => { calls++; return Task.CompletedTask; }, cts.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Equal(0, calls);
        Assert.False(provider.IsPrepared);
    }

    [Fact]
    public async Task PreCancelledAndEmptyInputDoNotCreateEngine()
    {
        await using var provider = new LocalEmbeddingProvider(_ => throw new InvalidOperationException("must not load"));
        Assert.Empty(await provider.EmbedAsync([]));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.PrepareAsync(new(true)));
        await Assert.ThrowsAsync<ArgumentException>(() => provider.EmbedAsync([""]));
    }

    [Theory]
    [InlineData(1, 512)]
    [InlineData(512, 512)]
    [InlineData(513, 1024)]
    [InlineData(8192, 8192)]
    public async Task CapacityGrowsToInputTokenCount(int count, int capacity)
    {
        var engine = new FakeEmbeddingEngine { Tokens = count };
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        await provider.EmbedAsync(["text"]);
        Assert.Equal(capacity, Assert.Single(engine.Calls).Capacity);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(8193)]
    public async Task TokenLimitRejectsBeforeEvaluation(int count)
    {
        var engine = new FakeEmbeddingEngine { Tokens = count };
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        await Assert.ThrowsAsync<ArgumentException>(() => provider.EmbedAsync(["text"]));
        Assert.Empty(engine.Calls);
    }

    [Theory]
    [InlineData("dimension")]
    [InlineData("zero")]
    [InlineData("nan")]
    [InlineData("infinity")]
    public async Task InvalidNativeVectorsFailExplicitly(string problem)
    {
        var vector = problem == "dimension" ? new float[3] : new float[1024];
        if (problem == "nan") vector[0] = float.NaN;
        if (problem == "infinity") vector[0] = float.PositiveInfinity;
        var engine = new FakeEmbeddingEngine { Evaluate = _ => Task.FromResult(vector) };
        await using var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        await Assert.ThrowsAsync<InvalidDataException>(() => provider.EmbedAsync(["text"]));
        Assert.False(provider.IsPrepared);
    }

    [Fact]
    public async Task DisposeReleasesEngineAndRejectsFurtherCalls()
    {
        var engine = new FakeEmbeddingEngine();
        var provider = new LocalEmbeddingProvider(_ => Task.FromResult<ILocalEmbeddingEngine>(engine));
        await provider.PrepareAsync();
        await provider.DisposeAsync();
        await provider.DisposeAsync();
        Assert.True(engine.Disposed);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => provider.PrepareAsync());
    }
}
