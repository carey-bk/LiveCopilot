namespace LiveCopilot.Core;

public static class ReasoningProviderFactory
{
    public const string MissingKeyMessage = "Configure the analysis service API key in Services.";

    public static IReasoningProvider Make(AppSettings settings, string? liveKey, string? analysisKey, IHttpTransport transport)
    {
        var key = settings.ReasoningService == ReasoningService.SharedOpenAI ? liveKey : analysisKey;
        ReasoningHTTP.Validate(key, settings.AnalysisModel);
        return settings.ReasoningService switch
        {
            ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI =>
                new OpenAIReasoningProvider(key!, settings.ReasoningModel, transport, settings.ReasoningEffort, settings.AnalysisProcessing),
            ReasoningService.DeepSeek => new ChatCompletionsProvider(key!, settings.DeepSeekModel,
                new("https://api.deepseek.com/chat/completions"), transport, deepSeekEffort: settings.DeepSeekEffort),
            ReasoningService.Qwen or ReasoningService.Glm or ReasoningService.Kimi =>
                new ChatCompletionsProvider(key!, settings.PresetConnection!.Model, settings.PresetConnection.Endpoint(), transport,
                    settings.ReasoningService, settings.PresetConnection.Thinking),
            ReasoningService.Compatible => new ChatCompletionsProvider(key!, settings.CompatibleModel, settings.CompatibleEndpoint(), transport),
            _ => throw new CopilotException("Select a supported analysis service in Services.")
        };
    }

    /// Environment keys are read only when the selected vault account has no key, never persisted.
    public static IReasoningProvider Make(AppSettings settings, ICredentialStore credentials, IHttpTransport transport,
        Func<string, string?>? environment = null)
    {
        var key = credentials.Read(settings.AnalysisCredentialReference());
        if (string.IsNullOrWhiteSpace(key))
        {
            var variable = settings.ReasoningService switch
            {
                ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => "OPENAI_API_KEY",
                ReasoningService.DeepSeek => "DEEPSEEK_API_KEY", _ => null
            };
            if (variable is not null) key = (environment ?? Environment.GetEnvironmentVariable)(variable);
        }
        return Make(settings, settings.ReasoningService == ReasoningService.SharedOpenAI ? key : null, key, transport);
    }
}
