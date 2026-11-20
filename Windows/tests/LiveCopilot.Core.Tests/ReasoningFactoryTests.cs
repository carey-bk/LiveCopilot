using static LiveCopilot.Core.Tests.ReasoningFixtures;

namespace LiveCopilot.Core.Tests;

public sealed class ReasoningFactoryTests
{
    [Theory]
    [InlineData(ReasoningService.SharedOpenAI, "https://api.openai.com/v1/responses")]
    [InlineData(ReasoningService.SeparateOpenAI, "https://api.openai.com/v1/responses")]
    [InlineData(ReasoningService.DeepSeek, "https://api.deepseek.com/chat/completions")]
    [InlineData(ReasoningService.Qwen, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")]
    [InlineData(ReasoningService.Glm, "https://open.bigmodel.cn/api/paas/v4/chat/completions")]
    [InlineData(ReasoningService.Kimi, "https://api.moonshot.cn/v1/chat/completions")]
    [InlineData(ReasoningService.Compatible, "https://test.invalid/v1/chat/completions")]
    public async Task FactoryRoutesEndpointModelAndKeys(ReasoningService service, string endpoint)
    {
        var settings = Settings(service);
        var transport = Transport(service);
        var provider = ReasoningProviderFactory.Make(settings, "test-live", "test-analysis", transport);
        Assert.Equal("答案", await Collect(provider));
        Assert.Equal(service == ReasoningService.SharedOpenAI ? "test-live" : "test-analysis", transport.Key);
        Assert.Equal(endpoint, transport.Endpoint!.AbsoluteUri);
        Assert.Equal(settings.AnalysisModel, transport.Body.GetProperty("model").GetString());
    }

    [Theory]
    [InlineData(ReasoningService.SharedOpenAI)] [InlineData(ReasoningService.SeparateOpenAI)]
    [InlineData(ReasoningService.DeepSeek)] [InlineData(ReasoningService.Qwen)] [InlineData(ReasoningService.Glm)]
    [InlineData(ReasoningService.Kimi)] [InlineData(ReasoningService.Compatible)]
    public void MissingSelectedKeyNeverFallsBackToOtherKey(ReasoningService service)
    {
        var transport = Transport(service);
        var error = Assert.Throws<CopilotException>(() => ReasoningProviderFactory.Make(Settings(service),
            service == ReasoningService.SharedOpenAI ? " " : "test-live", service == ReasoningService.SharedOpenAI ? "test-analysis" : null, transport));
        Assert.Equal("Configure the analysis service API key in Services.", error.Message); Assert.Equal(0, transport.Calls);
    }

    [Theory] [InlineData(ReasoningService.DeepSeek)] [InlineData(ReasoningService.Compatible)] [InlineData(ReasoningService.Qwen)]
    public void MissingModelFailsBeforeTransport(ReasoningService service)
    {
        var settings = Settings(service); settings.DeepSeekModel = " "; settings.CompatibleModel = " "; settings.QwenConnection = settings.QwenConnection with { Model = " " };
        var transport = Transport(service);
        var error = Assert.Throws<CopilotException>(() => ReasoningProviderFactory.Make(settings, "test-key", "test-key", transport));
        Assert.Equal("Enter an analysis model name in Services.", error.Message); Assert.Equal(0, transport.Calls);
    }

    [Fact] public void DirectProvidersValidateKeysAndModelsBeforeTransport()
    {
        var transport = Transport(ReasoningService.Compatible);
        Assert.Throws<CopilotException>(() => new ChatCompletionsProvider(" ", "custom", new("https://test.invalid"), transport));
        Assert.Throws<CopilotException>(() => new ChatCompletionsProvider("test-key", " ", new("https://test.invalid"), transport));
        Assert.Throws<CopilotException>(() => new OpenAIReasoningProvider("", "gpt-6-sol", transport));
        var error = Assert.Throws<CopilotException>(() => new OpenAIReasoningProvider("test\nkey", "gpt-6-sol", transport));
        Assert.Equal("The analysis API key contains invalid characters. Save a valid key in Services.", error.Message);
        Assert.Equal(0, transport.Calls);
    }

    [Fact] public void MemoryCredentialsAreIsolatedAndWhitespaceSaveClears()
    {
        ICredentialStore store = new MemoryCredentialStore();
        Assert.Null(store.Read(CredentialReference.Live));
        store.Save(CredentialReference.Live, " test-key "); store.Save(CredentialReference.DeepSeek, "test-deepseek");
        Assert.Equal("test-key", store.Read(CredentialReference.Live)); Assert.Null(store.Read(CredentialReference.SeparateOpenAI));
        store.Save(CredentialReference.Live, " \t\n"); Assert.Null(store.Read(CredentialReference.Live));
        Assert.Equal("test-deepseek", store.Read(CredentialReference.DeepSeek));
        store.Clear(CredentialReference.DeepSeek); store.Clear(CredentialReference.DeepSeek); Assert.Null(store.Read(CredentialReference.DeepSeek));
        var a = new CredentialReference("preset", "|https://a.invalid"); var b = new CredentialReference("preset", "|https://b.invalid");
        store.Save(a, "test-key"); Assert.Null(store.Read(b));
    }

    [Theory]
    [InlineData(ReasoningService.SharedOpenAI, "OPENAI_API_KEY")]
    [InlineData(ReasoningService.SeparateOpenAI, "OPENAI_API_KEY")]
    [InlineData(ReasoningService.DeepSeek, "DEEPSEEK_API_KEY")]
    public async Task EnvironmentFallbackIsReadOnlyAndVaultWins(ReasoningService service, string variable)
    {
        var settings = Settings(service); var store = new MemoryCredentialStore(); var transport = Transport(service);
        var reads = new List<string>();
        string? EnvironmentKey(string name) { reads.Add(name); return "test-env"; }
        await Collect(ReasoningProviderFactory.Make(settings, store, transport, EnvironmentKey));
        Assert.Equal(new[] { variable }, reads); Assert.Equal("test-env", transport.Key);
        Assert.Null(store.Read(settings.AnalysisCredentialReference()));
        store.Save(settings.AnalysisCredentialReference(), "test-vault"); reads.Clear();
        await Collect(ReasoningProviderFactory.Make(settings, store, transport, EnvironmentKey));
        Assert.Empty(reads); Assert.Equal("test-vault", transport.Key);
    }

    [Theory] [InlineData(ReasoningService.Qwen)] [InlineData(ReasoningService.Glm)] [InlineData(ReasoningService.Kimi)] [InlineData(ReasoningService.Compatible)]
    public void OtherVendorsNeverReadEnvironmentOrLiveAccount(ReasoningService service)
    {
        var store = new MemoryCredentialStore(); store.Save(CredentialReference.Live, "test-live");
        var reads = 0; var transport = Transport(service);
        Assert.Throws<CopilotException>(() => ReasoningProviderFactory.Make(Settings(service), store, transport, _ => { reads++; return "test-env"; }));
        Assert.Equal(0, reads); Assert.Equal(0, transport.Calls);
    }

    private static AppSettings Settings(ReasoningService service) => new()
    { ReasoningService = service, CompatibleBaseURL = "https://test.invalid/v1", CompatibleModel = "custom" };
    private static FakeHttpTransport Transport(ReasoningService service) => service is ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI
        ? new(OpenAIText, OpenAIComplete) : new(ChatText, "[DONE]");
}
