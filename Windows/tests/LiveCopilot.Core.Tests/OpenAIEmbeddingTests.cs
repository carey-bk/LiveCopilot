using System.Text;

namespace LiveCopilot.Core.Tests;

public sealed class OpenAIEmbeddingTests
{
    [Fact]
    public async Task PostsFloatInputAndRestoresServerIndexOrder()
    {
        var http = new EmbeddingTransport("""{"data":[{"index":1,"embedding":[0.5,1]},{"index":0,"embedding":[1,0]}]}""");
        var provider = new OpenAIEmbeddingProvider("synthetic-test-key", "text-embedding-3-small", http);
        var result = await provider.EmbedAsync(["中文问题", "English"]);
        Assert.Equal("https://api.openai.com/v1/embeddings", http.Endpoint);
        Assert.Equal("POST", http.Method); Assert.Equal("Bearer", http.Scheme);
        Assert.Equal("application/json", http.ContentType);
        Assert.Equal(provider.Model, http.Body.GetProperty("model").GetString());
        Assert.Equal("float", http.Body.GetProperty("encoding_format").GetString());
        Assert.Equal("中文问题", http.Body.GetProperty("input")[0].GetString());
        Assert.Equal(new float[] { 1, 0 }, result[0]); Assert.Equal(new float[] { 0.5f, 1 }, result[1]);
        Assert.Equal(1, http.Calls);
    }

    [Theory]
    [InlineData("{}")] [InlineData("[]")] [InlineData("not JSON")]
    [InlineData("{\"data\":null}")]
    [InlineData("{\"data\":[]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[1]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[1]},{\"index\":0,\"embedding\":[2]}]}")]
    [InlineData("{\"data\":[{\"index\":-1,\"embedding\":[1]},{\"index\":1,\"embedding\":[2]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[1]},{\"index\":2,\"embedding\":[2]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[]},{\"index\":1,\"embedding\":[]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[1]},{\"index\":1,\"embedding\":[1,2]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[1e100]},{\"index\":1,\"embedding\":[1]}]}")]
    [InlineData("{\"data\":[{\"index\":0,\"embedding\":[\"NaN\"]},{\"index\":1,\"embedding\":[1]}]}")]
    [InlineData("{\"data\":[{\"index\":0.5,\"embedding\":[1]},{\"index\":1,\"embedding\":[1]}]}")]
    [InlineData("{\"data\":[{\"embedding\":[1]},{\"index\":1,\"embedding\":[1]}]}")]
    public async Task RejectsMalformedMissingDuplicateNonfiniteOrIncompatibleRows(string response)
    {
        var error = await Assert.ThrowsAsync<CopilotException>(() => new OpenAIEmbeddingProvider("synthetic-test-key", "test", new EmbeddingTransport(response)).EmbedAsync(["a", "b"]));
        Assert.StartsWith("OpenAI returned", error.Message); Assert.Null(error.InnerException);
    }

    [Theory]
    [InlineData(401, "invalid_api_key", ServiceHTTPFailureKind.Authentication)]
    [InlineData(429, "insufficient_quota", ServiceHTTPFailureKind.Billing)]
    [InlineData(403, "", ServiceHTTPFailureKind.Permission)]
    [InlineData(404, "", ServiceHTTPFailureKind.Model)]
    [InlineData(422, "", ServiceHTTPFailureKind.Parameters)]
    [InlineData(429, "rate_limit_exceeded", ServiceHTTPFailureKind.RateLimit)]
    [InlineData(503, "", ServiceHTTPFailureKind.Service)]
    public async Task MapsHttpErrorsWithoutRetainingBody(int status, string code, ServiceHTTPFailureKind kind)
    {
        var payload = JsonSerializer.Serialize(new { error = new { code, message = "sensitive-placeholder" } });
        var http = new EmbeddingTransport(payload) { Status = status };
        var error = await Assert.ThrowsAsync<ServiceHTTPFailure>(() => new OpenAIEmbeddingProvider("synthetic-test-key", "test", http).EmbedAsync(["a"]));
        Assert.Equal(kind, error.Kind); Assert.Equal(status, error.Status);
        Assert.DoesNotContain("sensitive-placeholder", error.ToString());
    }

    [Theory] [InlineData("")] [InlineData(" \t ")] [InlineData("bad\nkey")]
    public async Task InvalidKeysFailBeforeTransport(string key)
    {
        var http = new EmbeddingTransport("{}");
        await Assert.ThrowsAsync<CopilotException>(() => new OpenAIEmbeddingProvider(key, "test", http).EmbedAsync(["a"]));
        Assert.Equal(0, http.Calls);
    }

    [Fact] public async Task EmptyInputDoesNotRequireCredentialOrCallTransport()
    {
        var http = new EmbeddingTransport("{}");
        Assert.Empty(await new OpenAIEmbeddingProvider("", "test", http).EmbedAsync([]));
        Assert.Equal(0, http.Calls);
    }

    [Fact] public async Task TransportFailureIsSafeAndCancellationIsPreserved()
    {
        var http = new EmbeddingTransport("{}") { Failure = new HttpRequestException("sensitive-placeholder") };
        var provider = new OpenAIEmbeddingProvider("synthetic-test-key", "test", http);
        var error = await Assert.ThrowsAsync<CopilotException>(() => provider.EmbedAsync(["a"]));
        Assert.DoesNotContain("sensitive-placeholder", error.ToString()); Assert.Null(error.InnerException);
        http.Failure = new OperationCanceledException();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.EmbedAsync(["a"]));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        var calls = http.Calls;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.EmbedAsync(["a"], cancelled.Token));
        Assert.Equal(calls, http.Calls);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task UsesLiveCredentialWithEnvironmentFallbackIndependentOfReasoning(bool saved)
    {
        var credentials = new MemoryCredentialStore();
        if (saved) credentials.Save(CredentialReference.Live, "synthetic-live");
        credentials.Save(CredentialReference.SeparateOpenAI, "synthetic-analysis");
        var http = new EmbeddingTransport("""{"data":[{"index":0,"embedding":[1]}]}""");
        var lookups = new List<string>();
        var provider = OpenAIEmbeddingProvider.FromCredentials(new() { ReasoningService = ReasoningService.SeparateOpenAI }, credentials, http,
            name => { lookups.Add(name); return "synthetic-environment"; });
        await provider.EmbedAsync(["a"]);
        Assert.True(http.Key == (saved ? "synthetic-live" : "synthetic-environment"));
        Assert.Equal(saved ? Array.Empty<string>() : ["OPENAI_API_KEY"], lookups);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task IndexOwnsTwentyFourItemBatchesAndRejectsDimensionChangesAcrossBatches(bool incompatible)
    {
        using var root = new TemporaryDirectory();
        var path = Path.Combine(root.Path, "large.txt");
        await File.WriteAllTextAsync(path, string.Concat(Enumerable.Repeat("中文知识库 latency 42 milliseconds.\n", 1800)));
        using var index = new KnowledgeIndex(Path.Combine(root.Path, "index"));
        var http = new BatchTransport(incompatible);
        var provider = new OpenAIEmbeddingProvider("synthetic-test-key", "test-model", http);
        if (incompatible)
        {
            await Assert.ThrowsAsync<CopilotException>(() => index.ImportDocumentAsync(path, provider));
            Assert.Empty(index.AllChunks()); Assert.Equal("Failed", Assert.Single(index.Documents()).Status);
        }
        else
        {
            var document = await index.ImportDocumentAsync(path, provider);
            Assert.Equal(http.Sizes.Sum(), document.ChunkCount);
            Assert.Equal("test-model", document.EmbeddingModel);
        }
        Assert.True(http.Sizes.Count > 1); Assert.Equal(24, http.Sizes[0]);
        Assert.All(http.Sizes.SkipLast(1), size => Assert.Equal(24, size)); Assert.InRange(http.Sizes[^1], 1, 24);
    }

    private sealed class BatchTransport(bool incompatible) : IHttpTransport
    {
        public List<int> Sizes { get; } = [];
        public async Task<(byte[] Data, int Status)> DataAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            var count = json.RootElement.GetProperty("input").GetArrayLength(); Sizes.Add(count);
            var vector = incompatible && Sizes.Count > 1 ? new float[] { 1 } : [1, 0];
            return (JsonSerializer.SerializeToUtf8Bytes(new { data = Enumerable.Range(0, count).Select(index => new { index, embedding = vector }) }), 200);
        }
        public IAsyncEnumerable<string> LinesAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class EmbeddingTransport(string response) : IHttpTransport
    {
        public int Status { get; init; } = 200;
        public Exception? Failure { get; set; }
        public int Calls { get; private set; }
        public string? Endpoint { get; private set; }
        public string? Method { get; private set; }
        public string? Scheme { get; private set; }
        public string? Key { get; private set; }
        public string? ContentType { get; private set; }
        public JsonElement Body { get; private set; }
        public async Task<(byte[] Data, int Status)> DataAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++; Endpoint = request.RequestUri?.AbsoluteUri; Method = request.Method.Method;
            Scheme = request.Headers.Authorization?.Scheme; Key = request.Headers.Authorization?.Parameter;
            ContentType = request.Content?.Headers.ContentType?.MediaType;
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken)); Body = json.RootElement.Clone();
            if (Failure is not null) throw Failure;
            return (Encoding.UTF8.GetBytes(response), Status);
        }
        public IAsyncEnumerable<string> LinesAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
