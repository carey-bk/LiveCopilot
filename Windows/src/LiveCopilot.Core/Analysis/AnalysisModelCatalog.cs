namespace LiveCopilot.Core;

public sealed record AnalysisModel(string Id, string Name, ReasoningService Service, ValueList<AnalysisThinking> Modes)
{
    public AnalysisThinking RecommendedThinking => Id is "deepseek-flash" or "qwen3.8-flash" or "kimi-k2.6" ? AnalysisThinking.Disabled : AnalysisThinking.Low;
}

public static class AnalysisModelCatalog
{
    public static ValueList<AnalysisModel> Models { get; } =
    [
        new("gpt-6-luna", "GPT-6 Luna", ReasoningService.SeparateOpenAI, [AnalysisThinking.Disabled, AnalysisThinking.Low, AnalysisThinking.Medium, AnalysisThinking.High, AnalysisThinking.Xhigh, AnalysisThinking.Max]),
        new("gpt-6-sol", "GPT-6 Sol", ReasoningService.SeparateOpenAI, [AnalysisThinking.Disabled, AnalysisThinking.Low, AnalysisThinking.Medium, AnalysisThinking.High, AnalysisThinking.Xhigh, AnalysisThinking.Max]),
        new("gpt-6.1-sol", "GPT-6.1 Sol", ReasoningService.SeparateOpenAI, [AnalysisThinking.Low, AnalysisThinking.Medium, AnalysisThinking.High, AnalysisThinking.Xhigh, AnalysisThinking.Max]),
        new("deepseek-flash", "DeepSeek V4.1 Flash", ReasoningService.DeepSeek, [AnalysisThinking.Disabled, AnalysisThinking.Low, AnalysisThinking.High, AnalysisThinking.Max]),
        new("qwen3.8-flash", "Qwen3.8 Flash", ReasoningService.Qwen, [AnalysisThinking.Disabled, AnalysisThinking.Low, AnalysisThinking.Medium, AnalysisThinking.Xhigh]),
        new("glm-5.3-flash", "GLM-5.3 Flash", ReasoningService.Glm, [AnalysisThinking.Low, AnalysisThinking.High, AnalysisThinking.Max]),
        new("glm-5.3-flashx", "GLM-5.3 FlashX", ReasoningService.Glm, [AnalysisThinking.Low, AnalysisThinking.High, AnalysisThinking.Max]),
        new("kimi-k2.6", "Kimi K2.6", ReasoningService.Kimi, [AnalysisThinking.Disabled, AnalysisThinking.Enabled]),
        new("kimi-k3", "Kimi K3", ReasoningService.Kimi, [AnalysisThinking.Low, AnalysisThinking.High, AnalysisThinking.Max])
    ];
    public static ValueList<AnalysisModel> ModelsFor(ReasoningService service) => Models.Where(m => m.Service == (service == ReasoningService.SharedOpenAI ? ReasoningService.SeparateOpenAI : service)).ToValueList();
    public static AnalysisModel? Model(string id, ReasoningService service) => ModelsFor(service).FirstOrDefault(m => m.Id == id.Trim().ToLowerInvariant());
    public static AnalysisModel? Recommended(ReasoningService service) => service switch
    { ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => Model("gpt-6-sol", service), ReasoningService.Glm => Model("glm-5.3-flashx", service), _ => ModelsFor(service).FirstOrDefault() };
    public static AnalysisThinking Normalized(AnalysisThinking value, string id, ReasoningService service)
    {
        var model = Model(id, service);
        if (model is null) return AnalysisThinking.ModelDefault;
        if (model.Modes.Contains(value)) return value;
        if (id == "kimi-k2.6" && value != AnalysisThinking.ModelDefault) return AnalysisThinking.Enabled;
        if (service == ReasoningService.Qwen && value is AnalysisThinking.High or AnalysisThinking.Max) return AnalysisThinking.Xhigh;
        if (service == ReasoningService.DeepSeek && value is AnalysisThinking.Medium or AnalysisThinking.Xhigh) return AnalysisThinking.High;
        return model.RecommendedThinking;
    }
    public static AnalysisThinking Normalized(string value, string model, ReasoningService service)
    {
        if (value == "none") value = "disabled";
        if (value == "minimal" && service is ReasoningService.DeepSeek or ReasoningService.Qwen) value = "low";
        if (value == "ultra" && service == ReasoningService.DeepSeek) value = "max";
        return Normalized(WireEnum.Parse<AnalysisThinking>(value) ?? AnalysisThinking.ModelDefault, model, service);
    }
    public static string Description(ReasoningService service, AppLanguage language, ILocaleProvider? locale = null)
    {
        var text = service switch
        {
            ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => ("Balanced capability and speed at a low cost, for quick questions and everyday meetings.", "综合能力与速度均衡，成本较低，适合快速问答及日常会议。"),
            ReasoningService.DeepSeek => ("Fast, cost-conscious answers for conversations primarily in Chinese.", "擅长中文对话，输出速度快，适合以中文为主的面试和会议。"),
            ReasoningService.Qwen => ("Balanced speed, Chinese-language ability and cost for everyday exchanges.", "适合中英文问答与日常交流，兼顾响应速度、中文能力和成本。"),
            ReasoningService.Glm => ("Faster output than Flash, at a higher price, for longer live answers.", "比普通 Flash 输出更快、价格更高，适合实时生成较长回答。"),
            ReasoningService.Kimi => ("For complex questions. Thinking can delay the visible answer; turn it off for faster replies.", "适合复杂理解与深度回答；思考会延长等待，实时场景可关闭。"),
            _ => ("Use the model ID and endpoint supplied by your service.", "使用服务商提供的模型 ID 与接口地址。")
        };
        return ServiceGuide.Text(text.Item1, text.Item2, language, locale);
    }
    public static string Tags(ReasoningService service, AppLanguage language, ILocaleProvider? locale = null)
    {
        var text = service switch
        {
            ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => ("Technical quality · Responsive", "技术质量 · 速度兼顾"),
            ReasoningService.DeepSeek => ("Chinese-friendly · Low cost", "中文友好 · 低成本"), ReasoningService.Qwen => ("Chinese-friendly · Balanced", "中文友好 · 稳定均衡"),
            ReasoningService.Glm => ("Fast output · Live conversations", "高速输出 · 实时优先"), ReasoningService.Kimi => ("Thinking off · Shorter wait", "关闭思考 · 减少等待"), _ => ("Custom connection", "自定义连接")
        };
        return ServiceGuide.Text(text.Item1, text.Item2, language, locale);
    }
}

public static class AnalysisThinkingExtensions
{
    public static bool IsAdvanced(this AnalysisThinking value) => value is AnalysisThinking.Medium or AnalysisThinking.High or AnalysisThinking.Xhigh or AnalysisThinking.Max;
    public static string MenuName(this AnalysisThinking value) => value switch { AnalysisThinking.Disabled => "Off", AnalysisThinking.Enabled => "On", AnalysisThinking.ModelDefault => "Default", _ => value.ToString() };
    public static string ReferenceKey(this AnalysisThinking value) => value == AnalysisThinking.Disabled ? "none" : value.RawValue();
    public static string DisplayName(this AnalysisThinking value, AppLanguage language, ILocaleProvider? locale = null) => value switch
    {
        AnalysisThinking.ModelDefault => ServiceGuide.Text("Model default", "模型默认", language, locale),
        AnalysisThinking.Disabled => ServiceGuide.Text("Off", "Off · 关闭思考", language, locale), AnalysisThinking.Enabled => ServiceGuide.Text("On", "On · 开启思考", language, locale), _ => value.MenuName()
    };
}

public sealed partial record AppSettings
{
    [JsonIgnore] public AnalysisThinking AnalysisThinking
    {
        get => ReasoningService switch
        {
            ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => AnalysisModelCatalog.Normalized(ReasoningEffort, AnalysisModel, ReasoningService),
            ReasoningService.DeepSeek => AnalysisModelCatalog.Normalized(DeepSeekEffort, AnalysisModel, ReasoningService),
            ReasoningService.Qwen or ReasoningService.Glm or ReasoningService.Kimi => ReasoningService.NormalizedThinking(PresetConnection!.Thinking, AnalysisModel), _ => AnalysisThinking.ModelDefault
        };
        set
        {
            var mode = AnalysisModelCatalog.Normalized(value, AnalysisModel, ReasoningService);
            switch (ReasoningService)
            {
                case ReasoningService.SharedOpenAI: case ReasoningService.SeparateOpenAI: ReasoningEffort = mode == AnalysisThinking.ModelDefault ? "" : mode.ReferenceKey(); break;
                case ReasoningService.DeepSeek: DeepSeekEffort = mode == AnalysisThinking.ModelDefault ? "" : mode.ReferenceKey(); break;
                case ReasoningService.Qwen: case ReasoningService.Glm: case ReasoningService.Kimi: PresetConnection = PresetConnection! with { Thinking = mode }; break;
            }
        }
    }
    [JsonIgnore] public bool UsesRecommendedAnalysis => AnalysisModelCatalog.Recommended(ReasoningService) is { } model && AnalysisModel == model.Id && AnalysisThinking == model.RecommendedThinking && AnalysisProcessing == AnalysisProcessing.Standard;
    [JsonIgnore] public bool IsOpenAIAnalysis => ReasoningService is ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI;
    [JsonIgnore] public bool SupportsOpenAIFast => IsOpenAIAnalysis && AnalysisModel is "gpt-6-luna" or "gpt-6-sol" or "gpt-6.1-sol";
    [JsonIgnore] public bool UsesOpenAIFast => AnalysisProcessing == AnalysisProcessing.Fast;
    public void SelectRecommendedAnalysisService(ReasoningService service) { SelectAnalysisService(service); ApplyAnalysisRecommendation(); }
    public void ApplyAnalysisRecommendation()
    {
        if (AnalysisModelCatalog.Recommended(ReasoningService) is not { } model) return;
        SelectAnalysisModel(model.Id); AnalysisThinking = model.RecommendedThinking;
        if (IsOpenAIAnalysis) OpenAIProcessing = AnalysisProcessing.Standard;
    }
    [JsonIgnore] public string? AnalysisStandardRoute
    {
        get
        {
            if (IsOpenAIAnalysis) return "openai";
            if (ReasoningService == ReasoningService.DeepSeek) return "deepseek";
            if (PresetConnection is not { } connection) return null;
            Uri endpoint;
            try { endpoint = connection.Endpoint(); } catch (CopilotException) { return null; }
            if (!endpoint.IsDefaultPort) return null;
            var route = endpoint.AbsoluteUri switch
            {
                "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions" => "qwen-cn",
                "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions" => "qwen-intl",
                "https://open.bigmodel.cn/api/paas/v4/chat/completions" => "glm-cn",
                "https://api.z.ai/api/paas/v4/chat/completions" => "glm-intl",
                "https://api.moonshot.cn/v1/chat/completions" => "kimi-cn",
                "https://api.moonshot.ai/v1/chat/completions" => "kimi-intl", _ => null
            };
            return route?.StartsWith(ReasoningService.RawValue() + "-", StringComparison.Ordinal) == true ? route : null;
        }
    }
}
