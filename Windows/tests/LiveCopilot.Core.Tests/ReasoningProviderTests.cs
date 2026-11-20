using static LiveCopilot.Core.Tests.ReasoningFixtures;

namespace LiveCopilot.Core.Tests;

public sealed class ReasoningProviderTests
{
    [Fact] public async Task ResponsesShowsOnlyFinalTextAndRefusalAndReportsProgressOnce()
    {
        var transport = new FakeHttpTransport(
            """{"type":"unknown.future","text":"hidden"}""",
            """{"type":"response.output_item.added","item":{"type":"reasoning","text":"hidden"}}""",
            """{"type":"response.output_item.added","item":{"type":"reasoning","text":"hidden"}}""",
            OpenAIText, """{"type":"response.refusal.delta","delta":"。"}""", OpenAIComplete, "[DONE]");
        var answer = Answer(); var stages = new List<PipelineStage>();
        answer.OnStreamProgress = (stage, time) => { Assert.True(time > 0); stages.Add(stage); return Task.CompletedTask; };
        Assert.Equal("答案。", await Collect(new OpenAIReasoningProvider("test-key", "gpt-6-sol", transport), answer));
        Assert.Equal(new[] { PipelineStage.FirstServiceEvent, PipelineStage.ReasoningStarted }, stages);
        Assert.Equal("https://api.openai.com/v1/responses", transport.Endpoint!.AbsoluteUri);
        Assert.Equal("POST", transport.Method); Assert.Equal("Bearer", transport.Scheme); Assert.Equal("test-key", transport.Key);
        Assert.Equal("application/json", transport.ContentType);
        var body = transport.Body;
        Assert.Equal("gpt-6-sol", body.GetProperty("model").GetString());
        Assert.Equal(answer.Instructions, body.GetProperty("instructions").GetString()); Assert.Equal(answer.Input, body.GetProperty("input").GetString());
        Assert.True(body.GetProperty("stream").GetBoolean()); Assert.False(body.GetProperty("store").GetBoolean());
        Assert.Equal(2800, body.GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("default", body.GetProperty("service_tier").GetString());
        Assert.Equal("low", body.GetProperty("reasoning").GetProperty("effort").GetString());
    }

    [Theory] [InlineData("gpt-6-sol", "none", "none")] [InlineData("gpt-6.1-sol", "none", "low")] [InlineData("custom-model", "high", null)]
    public async Task ResponsesNormalizesEffortAndTitleLimit(string model, string effort, string? expected)
    {
        var transport = new FakeHttpTransport(OpenAIText, OpenAIComplete);
        var answer = Answer(); answer.SessionTitleInput = "Naming excerpt";
        await Collect(new OpenAIReasoningProvider("test-key", model, transport, effort, AnalysisProcessing.Fast), answer);
        Assert.Equal(512, transport.Body.GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("fast", transport.Body.GetProperty("service_tier").GetString());
        Assert.Equal(expected is not null, transport.Body.TryGetProperty("reasoning", out var reasoning));
        if (expected is not null) Assert.Equal(expected, reasoning.GetProperty("effort").GetString());
    }

    [Theory]
    [InlineData("""{"type":"response.failed","response":{"error":{"code":"invalid_api_key","message":"untrusted"}}}""", ServiceHTTPFailureKind.Authentication)]
    [InlineData("""{"type":"error","code":"rate_limit_exceeded"}""", ServiceHTTPFailureKind.RateLimit)]
    [InlineData("""{"error":{"code":"insufficient_quota","message":"untrusted"}}""", ServiceHTTPFailureKind.Billing)]
    public async Task ResponsesErrorsUseSharedSafeTaxonomy(string payload, ServiceHTTPFailureKind kind)
    {
        var error = await Assert.ThrowsAsync<ServiceHTTPFailure>(() => Collect(new OpenAIReasoningProvider("test-key", "gpt-6-sol", new FakeHttpTransport(payload))));
        Assert.Equal(kind, error.Kind); Assert.Equal(kind.Message(), error.Message);
    }

    [Fact] public async Task ResponsesIncompleteRetainsAlreadyDeliveredText()
    {
        var provider = new OpenAIReasoningProvider("test-key", "gpt-6-sol", new FakeHttpTransport(OpenAIText, """{"type":"response.incomplete"}"""));
        await using var iterator = provider.Stream(Answer()).GetAsyncEnumerator();
        Assert.True(await iterator.MoveNextAsync()); Assert.Equal("答案", iterator.Current);
        var error = await Assert.ThrowsAsync<CopilotException>(async () => await iterator.MoveNextAsync());
        Assert.Equal("The answer was cut short. Partial text is retained; retry or choose a lower reasoning effort.", error.Message);
    }

    [Theory] [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task ResponsesRequiresCompletedAndNonemptyText(int scenario)
    {
        string[] events = scenario switch { 0 => [], 1 => [OpenAIText, "[DONE]"], 2 => [OpenAIComplete], _ => ["""{"type":"response.output_text.delta","delta":""}""", OpenAIComplete] };
        var error = await Assert.ThrowsAsync<CopilotException>(() => Collect(new OpenAIReasoningProvider("test-key", "gpt-6-sol", new FakeHttpTransport(events))));
        Assert.Equal("Reasoning stream ended without a complete answer. Check the network and retry.", error.Message);
    }

    [Theory] [InlineData("broken")] [InlineData("[]")] [InlineData("{}")]
    public async Task MalformedEventsHaveSafeMessages(string payload)
    {
        foreach (var provider in new IReasoningProvider[] {
            new OpenAIReasoningProvider("test-key", "gpt-6-sol", new FakeHttpTransport(payload)),
            new ChatCompletionsProvider("test-key", "custom", new("https://test.invalid/chat"), new FakeHttpTransport(payload)) })
        {
            var error = await Assert.ThrowsAsync<CopilotException>(() => Collect(provider));
            Assert.Equal("Malformed reasoning stream. Retry this question.", error.Message);
        }
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task ChatStreamsFinalContentOnlyAndAcceptsDoneOrStop(bool stop)
    {
        var transport = new FakeHttpTransport(
            """{"choices":[{"index":1,"delta":{"content":"wrong choice"}},{"index":0,"delta":{"reasoning_content":"hidden"}}]}""",
            """{"choices":[{"delta":{"reasoning_content":"hidden again"}}]}""", ChatText,
            stop ? """{"choices":[{"delta":{},"finish_reason":"stop"}]}""" : "[DONE]",
            "malformed after completion should not be read");
        var answer = Answer(); var stages = new List<PipelineStage>();
        answer.OnStreamProgress = (stage, _) => { stages.Add(stage); return Task.CompletedTask; };
        Assert.Equal("答案", await Collect(new ChatCompletionsProvider("test-key", "custom", new("https://test.invalid/chat"), transport), answer));
        Assert.Equal(new[] { PipelineStage.FirstServiceEvent, PipelineStage.ReasoningStarted }, stages);
        Assert.Equal("https://test.invalid/chat", transport.Endpoint!.AbsoluteUri);
        Assert.Equal("POST", transport.Method); Assert.Equal("Bearer", transport.Scheme); Assert.Equal("test-key", transport.Key);
        Assert.True(transport.Body.GetProperty("stream").GetBoolean()); Assert.Equal(4096, transport.Body.GetProperty("max_tokens").GetInt32());
        Assert.Equal(answer.Instructions, transport.Body.GetProperty("messages")[0].GetProperty("content").GetString());
        Assert.Equal("system", transport.Body.GetProperty("messages")[0].GetProperty("role").GetString());
        Assert.Equal(answer.Input, transport.Body.GetProperty("messages")[1].GetProperty("content").GetString());
        Assert.Equal("user", transport.Body.GetProperty("messages")[1].GetProperty("role").GetString());
    }

    [Theory] [InlineData("length")] [InlineData("content_filter")] [InlineData("tool_calls")]
    public async Task ChatOtherFinishReasonsFailAfterPartialText(string reason)
    {
        var transport = new FakeHttpTransport(ChatText, JsonSerializer.Serialize(new { choices = new[] { new { finish_reason = reason } } }));
        var provider = new ChatCompletionsProvider("test-key", "custom", new("https://test.invalid/chat"), transport);
        await using var iterator = provider.Stream(Answer()).GetAsyncEnumerator();
        Assert.True(await iterator.MoveNextAsync()); Assert.Equal("答案", iterator.Current);
        var error = await Assert.ThrowsAsync<CopilotException>(async () => await iterator.MoveNextAsync());
        Assert.Equal("The analysis answer was interrupted or exceeded its limit. Partial text is retained; retry.", error.Message);
    }

    [Theory] [InlineData(0)] [InlineData(1)] [InlineData(2)]
    public async Task ChatRequiresCompletionAndText(int scenario)
    {
        string[] events = scenario switch { 0 => [], 1 => [ChatText], _ => ["""{"choices":[{"delta":{"reasoning_content":"hidden"}}]}""", "[DONE]"] };
        var error = await Assert.ThrowsAsync<CopilotException>(() => Collect(new ChatCompletionsProvider("test-key", "custom", new("https://test.invalid/chat"), new FakeHttpTransport(events))));
        Assert.Equal("Reasoning stream ended without a complete answer. Check the network and retry.", error.Message);
    }

    [Fact] public async Task ChatErrorsUseSharedTaxonomy()
    {
        var provider = new ChatCompletionsProvider("test-key", "custom", new("https://test.invalid/chat"), new FakeHttpTransport("""{"error":{"code":"model_not_found","message":"untrusted"}}"""));
        var error = await Assert.ThrowsAsync<ServiceHTTPFailure>(() => Collect(provider));
        Assert.Equal(ServiceHTTPFailureKind.Model, error.Kind); Assert.Equal(ServiceHTTPFailureKind.Model.Message(), error.Message);
    }

    [Theory]
    [InlineData(ReasoningService.DeepSeek, "deepseek-flash", AnalysisThinking.Disabled, "disabled", null, null)]
    [InlineData(ReasoningService.DeepSeek, "deepseek-flash", AnalysisThinking.High, "enabled", null, "high")]
    [InlineData(ReasoningService.Qwen, "qwen3.8-flash", AnalysisThinking.Disabled, null, false, null)]
    [InlineData(ReasoningService.Qwen, "qwen3.8-flash", AnalysisThinking.High, null, true, "xhigh")]
    [InlineData(ReasoningService.Glm, "glm-5.3-flashx", AnalysisThinking.Low, "enabled", null, "low")]
    [InlineData(ReasoningService.Kimi, "kimi-k2.6", AnalysisThinking.Disabled, "disabled", null, null)]
    [InlineData(ReasoningService.Kimi, "kimi-k2.6", AnalysisThinking.Enabled, "enabled", null, null)]
    [InlineData(ReasoningService.Kimi, "kimi-k3", AnalysisThinking.High, null, null, "high")]
    [InlineData(ReasoningService.Kimi, " KIMI-K3 ", AnalysisThinking.Max, null, null, "max")]
    [InlineData(ReasoningService.Compatible, "custom", AnalysisThinking.High, null, null, null)]
    [InlineData(ReasoningService.Qwen, "custom", AnalysisThinking.High, null, null, null)]
    public async Task ChatVendorFieldsAreIsolated(ReasoningService service, string model, AnalysisThinking thinking, string? toggle, bool? enable, string? effort)
    {
        var transport = new FakeHttpTransport(ChatText, "[DONE]");
        var provider = new ChatCompletionsProvider("test-key", model, new("https://test.invalid/chat"), transport,
            service, thinking, service == ReasoningService.DeepSeek ? thinking.ReferenceKey() : null);
        var answer = Answer(); answer.SessionTitleInput = "title";
        await Collect(provider, answer);
        var body = transport.Body;
        Assert.Equal(512, body.GetProperty("max_tokens").GetInt32());
        Assert.Equal(toggle is not null, body.TryGetProperty("thinking", out var actualToggle));
        if (toggle is not null) Assert.Equal(toggle, actualToggle.GetProperty("type").GetString());
        Assert.Equal(enable is not null, body.TryGetProperty("enable_thinking", out var actualEnable));
        if (enable is not null) Assert.Equal(enable, actualEnable.GetBoolean());
        Assert.Equal(effort is not null, body.TryGetProperty("reasoning_effort", out var actualEffort));
        if (effort is not null) Assert.Equal(effort, actualEffort.GetString());
        Assert.False(body.TryGetProperty("temperature", out _)); Assert.False(body.TryGetProperty("top_p", out _));
        Assert.False(body.TryGetProperty("reasoning", out _)); Assert.False(body.TryGetProperty("service_tier", out _));
    }
}
