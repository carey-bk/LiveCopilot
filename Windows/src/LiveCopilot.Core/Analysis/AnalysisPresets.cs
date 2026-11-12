namespace LiveCopilot.Core;

public sealed record AnalysisConnection([property: JsonPropertyName("baseURL"), JsonRequired] string BaseURL,
    [property: JsonRequired] string Model, [property: JsonRequired] AnalysisThinking Thinking = AnalysisThinking.ModelDefault)
{
    public Uri Endpoint() => ServiceEndpoint.Make(BaseURL, "chat/completions");
    public static AnalysisConnection Qwen => Recommended(ReasoningService.Qwen, "https://dashscope.aliyuncs.com/compatible-mode/v1");
    public static AnalysisConnection Glm => Recommended(ReasoningService.Glm, "https://open.bigmodel.cn/api/paas/v4");
    public static AnalysisConnection Kimi => Recommended(ReasoningService.Kimi, "https://api.moonshot.cn/v1");
    private static AnalysisConnection Recommended(ReasoningService service, string baseUrl)
    { var model = AnalysisModelCatalog.Recommended(service)!; return new(baseUrl, model.Id, model.RecommendedThinking); }
}

public static class AnalysisPresetExtensions
{
    public static string Label(this AnalysisThinking value) => value switch
    {
        AnalysisThinking.ModelDefault => "Model default", AnalysisThinking.Disabled => "Off (faster)", AnalysisThinking.Enabled => "On (more thinking)",
        AnalysisThinking.Low => "Low (faster)", AnalysisThinking.Max => "Maximum", _ => value.MenuName()
    };
    public static string? Effort(this AnalysisThinking value) => value is AnalysisThinking.ModelDefault or AnalysisThinking.Disabled or AnalysisThinking.Enabled ? null : value.RawValue();
    public static bool IsPreset(this ReasoningService service) => service is ReasoningService.Qwen or ReasoningService.Glm or ReasoningService.Kimi;
    public static ValueList<AnalysisThinking> AvailableThinkingModes(this ReasoningService service, string model) => AnalysisModelCatalog.Model(model, service)?.Modes ?? [AnalysisThinking.ModelDefault];
    public static AnalysisThinking DefaultThinking(this ReasoningService service, string model) => AnalysisModelCatalog.Model(model, service)?.RecommendedThinking ?? AnalysisThinking.ModelDefault;
    public static AnalysisThinking NormalizedThinking(this ReasoningService service, AnalysisThinking thinking, string model) => AnalysisModelCatalog.Normalized(thinking, model, service);
    public static string? PricingURL(this ReasoningService service) => service switch
    {
        ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => "https://developers.openai.com/api/docs/models",
        ReasoningService.DeepSeek => "https://api-docs.deepseek.com/quick_start/pricing/",
        ReasoningService.Qwen => "https://help.aliyun.com/zh/model-studio/model-pricing", ReasoningService.Glm => "https://bigmodel.cn/pricing",
        ReasoningService.Kimi => "https://platform.kimi.com/docs/pricing/chat", _ => null
    };
    public static string? ConfigurationURL(this ReasoningService service) => service switch
    {
        ReasoningService.Qwen => "https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope",
        ReasoningService.Glm => "https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash",
        ReasoningService.Kimi => "https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart", _ => null
    };
}

public sealed partial record AppSettings
{
    public void SelectAnalysisService(ReasoningService service) => ReasoningService = service;
    public void SelectAnalysisModel(string model)
    {
        if (AnalysisModel == model) return;
        switch (ReasoningService)
        {
            case ReasoningService.SharedOpenAI: case ReasoningService.SeparateOpenAI: ReasoningModel = model; break;
            case ReasoningService.DeepSeek: DeepSeekModel = model; break;
            case ReasoningService.Qwen: case ReasoningService.Glm: case ReasoningService.Kimi: PresetConnection = PresetConnection! with { Model = model }; break;
            default: CompatibleModel = model; break;
        }
        AnalysisThinking = ReasoningService.DefaultThinking(AnalysisModel);
    }
    [JsonIgnore] public AnalysisConnection? PresetConnection
    {
        get => ReasoningService switch { ReasoningService.Qwen => QwenConnection, ReasoningService.Glm => GlmConnection, ReasoningService.Kimi => KimiConnection, _ => null };
        set
        {
            if (value is null) return;
            switch (ReasoningService) { case ReasoningService.Qwen: QwenConnection = value; break; case ReasoningService.Glm: GlmConnection = value; break; case ReasoningService.Kimi: KimiConnection = value; break; }
        }
    }
}

public static class OverlayTypography
{
    public const double Minimum = 11, Maximum = 28;
    public static double Clamped(double value, double fallback) => double.IsFinite(value) ? Math.Clamp(value, Minimum, Maximum) : fallback;
}
