namespace LiveCopilot.Core.Tests;

public sealed class AnalysisPresetTests
{
    public static IEnumerable<object[]> ConfigurationIds => AnalysisConfigurations.All.Select(r => new object[] { r.Id });
    [Theory] [MemberData(nameof(ConfigurationIds))]
    public void EachConfigurationKeepsSelectionJsonPricingAndMeasurementIdentity(int id)
    {
        var row = AnalysisConfigurations.All.Single(r => r.Id == id);
        var settings = new AppSettings(); settings.SelectAnalysisService(row.Service); settings.SelectAnalysisModel(row.Model);
        settings.AnalysisThinking = row.Thinking; settings.AnalysisProcessing = row.Processing;
        settings.Language = row.Currency == "USD" ? AppLanguage.English : AppLanguage.SimplifiedChinese;
        Assert.Equal(id, AnalysisConfigurations.Selection(settings)?.Id);
        Assert.Equal(settings, CoreJson.Decode<AppSettings>(CoreJson.Encode(settings)));
        var price = Assert.IsType<AnalysisPriceDisplay>(AnalysisPricing.Display(settings));
        Assert.Equal(row.Input, price.Input); Assert.Equal(row.Output, price.Output);
        Assert.Equal(row, CoreJson.Decode<AnalysisConfiguration>(CoreJson.Encode(row)));
        Assert.NotNull(AnalysisMetricTiers.Range(row.Ttft, AnalysisMetricTiers.Latency));
        Assert.NotNull(AnalysisMetricTiers.Range(row.Speed, AnalysisMetricTiers.Generation));
        if (row.Kind == AnalysisReferenceKind.Estimate)
        { Assert.Null(row.FirstTokenSeconds); Assert.Null(row.TokensPerSecond); Assert.Null(AnalysisPerformance.Selection(settings).MatchingSample); }
        else { Assert.NotNull(row.FirstTokenSeconds); Assert.NotNull(row.TokensPerSecond); }
        if (row.Processing != AnalysisProcessing.Standard) Assert.Null(AnalysisPerformance.Selection(settings).MatchingSample);
    }
    [Fact] public void CatalogKeepsAllReviewedRowsAndRecommendations()
    {
        Assert.Equal(58, AnalysisConfigurations.All.Count); Assert.Equal(9, AnalysisModelCatalog.Models.Count);
        Assert.Equal(27, AnalysisConfigurations.All.Count(r => r.Kind == AnalysisReferenceKind.Estimate));
        Assert.Equal(4, AnalysisConfigurations.All.Count(r => r.Kind == AnalysisReferenceKind.Community));
        Assert.Equal(27, AnalysisConfigurations.All.Count(r => r.Kind == AnalysisReferenceKind.PublicSnapshot));
        Assert.Equal([1, 2, 3, 4, 5], AnalysisConfigurations.TopFive.Select(r => r.Rank!.Value));
        Assert.Equal(["gpt-6-sol", "deepseek-flash", "gpt-6-luna", "gpt-6-sol", "glm-5.3-flashx"], AnalysisConfigurations.TopFive.Select(r => r.Model));
        Assert.True(AnalysisConfigurations.Recommended("gpt-6-luna", AnalysisThinking.Low, AnalysisProcessing.Fast));
        Assert.False(AnalysisConfigurations.ModelIsRecommended("kimi-k3"));
        foreach (var row in AnalysisConfigurations.All.Where(r => r.ProviderDefault))
        { var settings = new AppSettings(); settings.SelectRecommendedAnalysisService(row.Service); Assert.Equal(row.Id, AnalysisConfigurations.Selection(settings)?.Id); }
        Assert.Equal("default", AnalysisProcessing.Standard.WireValue());
    }
    [Fact] public void ProviderSwitchRestoresChoicesAndExplicitRecommendationKeepsEndpoint()
    {
        var settings = new AppSettings { ReasoningEffort = "high", OpenAIProcessing = AnalysisProcessing.Fast };
        settings.SelectAnalysisService(ReasoningService.DeepSeek); settings.DeepSeekEffort = "max";
        settings.SelectAnalysisService(ReasoningService.Qwen); settings.AnalysisThinking = AnalysisThinking.Xhigh;
        settings.SelectAnalysisService(ReasoningService.SeparateOpenAI); Assert.Equal(AnalysisThinking.High, settings.AnalysisThinking);
        settings.SelectAnalysisService(ReasoningService.DeepSeek); Assert.Equal(AnalysisThinking.Max, settings.AnalysisThinking);
        settings.SelectAnalysisService(ReasoningService.Qwen); Assert.Equal(AnalysisThinking.Xhigh, settings.AnalysisThinking);
        settings.GlmConnection = settings.GlmConnection with { BaseURL = "https://api.z.ai/api/paas/v4", Model = "glm-5.3-flash", Thinking = AnalysisThinking.Max };
        settings.SelectRecommendedAnalysisService(ReasoningService.Glm);
        Assert.Equal("glm-5.3-flashx", settings.AnalysisModel); Assert.Equal(AnalysisThinking.Low, settings.AnalysisThinking);
        Assert.Equal("https://api.z.ai/api/paas/v4", settings.PresetConnection!.BaseURL);
        settings.SelectRecommendedAnalysisService(ReasoningService.SeparateOpenAI);
        Assert.True(settings.UsesRecommendedAnalysis); Assert.Equal(AnalysisProcessing.Standard, settings.AnalysisProcessing);
        settings.AnalysisThinking = AnalysisThinking.High; settings.SelectAnalysisModel("gpt-6-sol"); Assert.Equal(AnalysisThinking.High, settings.AnalysisThinking);
        settings.SelectAnalysisModel("gpt-6-luna"); Assert.Equal(AnalysisThinking.Low, settings.AnalysisThinking);
    }
    [Fact] public void ThinkingAliasesAreScopedAndUnknownModelsHaveNoCapabilities()
    {
        Assert.Equal(AnalysisThinking.High, AnalysisModelCatalog.Normalized("medium", "deepseek-flash", ReasoningService.DeepSeek));
        Assert.Equal(AnalysisThinking.Max, AnalysisModelCatalog.Normalized("ultra", "deepseek-flash", ReasoningService.DeepSeek));
        Assert.Equal(AnalysisThinking.Xhigh, AnalysisModelCatalog.Normalized(AnalysisThinking.Max, "qwen3.8-flash", ReasoningService.Qwen));
        Assert.Equal(AnalysisThinking.Enabled, AnalysisModelCatalog.Normalized(AnalysisThinking.High, "kimi-k2.6", ReasoningService.Kimi));
        Assert.Equal(AnalysisThinking.Low, AnalysisModelCatalog.Normalized(AnalysisThinking.Disabled, "gpt-6.1-sol", ReasoningService.SeparateOpenAI));
        Assert.Equal(AnalysisThinking.ModelDefault, AnalysisModelCatalog.Normalized("high", "unknown", ReasoningService.SeparateOpenAI));
        foreach (var model in AnalysisModelCatalog.Models)
            foreach (var option in model.Modes) Assert.Equal(option, AnalysisModelCatalog.Normalized(option, model.Id, model.Service));
    }
    [Theory]
    [InlineData("http://example.com", "chat/completions")]
    [InlineData("https://user:password@example.com", "chat/completions")]
    [InlineData("https://example.com?key=fixture", "chat/completions")]
    [InlineData("https://example.com#fragment", "chat/completions")]
    [InlineData("https://example.com", "../secrets")]
    [InlineData("https://example.com", "https://other.com")]
    public void UnsafeEndpointsAreRejected(string url, string path) => Assert.Throws<CopilotException>(() => ServiceEndpoint.Make(url, path));
    [Fact] public void EndpointCredentialIdentityAndPricesAreScopedToRegion()
    {
        Assert.Equal("https://example.com/v1/chat/completions", ServiceEndpoint.Make("https://EXAMPLE.com:443/v1/", "/chat/completions").AbsoluteUri);
        var settings = new AppSettings { Language = AppLanguage.SimplifiedChinese }; settings.SelectAnalysisService(ReasoningService.Qwen);
        var credential = settings.AnalysisCredentialReference(); Assert.Equal(0.8, AnalysisPricing.Display(settings)!.Input);
        settings.SelectAnalysisModel("custom-model"); Assert.Equal(credential, settings.AnalysisCredentialReference()); Assert.Null(AnalysisPricing.Display(settings));
        settings.ApplyAnalysisRecommendation(); settings.QwenConnection = settings.QwenConnection with { BaseURL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" };
        Assert.NotEqual(credential, settings.AnalysisCredentialReference()); Assert.Equal(1.094, AnalysisPricing.Display(settings)!.Input);
        settings.QwenConnection = settings.QwenConnection with { BaseURL = "https://proxy.example/v1" };
        Assert.Null(settings.AnalysisStandardRoute); Assert.Null(AnalysisPricing.Display(settings)); Assert.Null(AnalysisPerformance.Selection(settings).MatchingSample);
        settings.SelectAnalysisService(ReasoningService.Glm); settings.GlmConnection = settings.GlmConnection with { BaseURL = "https://api.z.ai/api/paas/v4" };
        Assert.Null(AnalysisPricing.Display(settings));
        settings.SelectAnalysisService(ReasoningService.Compatible); settings.CompatibleModel = "gpt-6-sol"; Assert.Null(AnalysisPricing.Display(settings));
    }
    [Fact] public void CurrencyConversionDoesNotChangeRouteAndTtftDoesNotInventVisibleLatency()
    {
        var settings = new AppSettings { Language = AppLanguage.English }; settings.SelectAnalysisModel("gpt-6-luna");
        Assert.Equal(0.1, AnalysisPricing.Display(settings)!.Input); Assert.Null(AnalysisPricing.Display(settings)!.ExchangeRate);
        Assert.Null(AnalysisPerformance.Selection(settings).MatchingSample!.FirstAnswerSeconds);
        settings.Language = AppLanguage.TraditionalChinese;
        Assert.Equal(0.1 * 7.4992 / 1.1206, AnalysisPricing.Display(settings)!.Input, 8);
        Assert.Contains("¥0.67", AnalysisPricing.Display(settings)!.Summary(settings.Language));
        settings.SelectAnalysisService(ReasoningService.Kimi); settings.AnalysisThinking = AnalysisThinking.Enabled;
        Assert.Equal(80.95, AnalysisPerformance.Selection(settings).MatchingSample!.FirstAnswerSeconds);
        Assert.Equal(2.75, AnalysisPerformance.Selection(settings).MatchingSample!.FirstTokenSeconds);
        settings.SelectAnalysisService(ReasoningService.DeepSeek); Assert.Equal(1.15, AnalysisPerformance.Selection(settings).MatchingSample!.FirstAnswerSeconds);
        Assert.Contains("Input $0.15", ServiceGuide.AnalysisPrice(ReasoningService.DeepSeek, "deepseek-flash", AppLanguage.English));
    }
    [Fact] public void MetricBoundariesDoNotHideUncertainty()
    {
        Assert.Equal(AnalysisMetricTier.Fast, AnalysisMetricTiers.Latency(1.5)); Assert.Equal(AnalysisMetricTier.Steady, AnalysisMetricTiers.Latency(1.5001));
        Assert.Equal(AnalysisMetricTier.Slow, AnalysisMetricTiers.Latency(3.5001)); Assert.Null(AnalysisMetricTiers.Latency(double.PositiveInfinity));
        Assert.Equal(AnalysisMetricTier.Fast, AnalysisMetricTiers.Generation(100)); Assert.Equal(AnalysisMetricTier.Steady, AnalysisMetricTiers.Generation(50)); Assert.Null(AnalysisMetricTiers.Generation(0));
        Assert.Equal(AnalysisMetricTier.Inexpensive, AnalysisMetricTiers.Price(10, AnalysisCurrency.Cny)); Assert.Equal(AnalysisMetricTier.ModeratePrice, AnalysisMetricTiers.Price(7.5, AnalysisCurrency.Usd));
        Assert.Equal(AnalysisMetricTier.Uncertain, AnalysisMetricTiers.Range("0.9–2.5", AnalysisMetricTiers.Latency));
        foreach (var invalid in new[] { "", "N/A", "3–1", "NaN", "1–2–3", "-2–1" }) Assert.Null(AnalysisMetricTiers.Range(invalid, AnalysisMetricTiers.Latency));
    }
}
