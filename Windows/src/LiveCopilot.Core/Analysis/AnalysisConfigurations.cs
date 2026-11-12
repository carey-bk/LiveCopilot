namespace LiveCopilot.Core;

public static class AnalysisProcessingExtensions
{
    public static string Name(this AnalysisProcessing value) => value.ToString();
    public static string WireValue(this AnalysisProcessing value) => value == AnalysisProcessing.Standard ? "default" : value.RawValue();
}

public sealed record AnalysisConfiguration(int Id,
    ReasoningService Service,
    string Model,
    string Name,
    AnalysisThinking Thinking,
    AnalysisProcessing Processing,
    bool Recommended,
    bool ProviderDefault,
    int? Rank,
    string Reason,
    string Limits,
    AnalysisReferenceKind Kind,
    string Ttft,
    string Speed,
    double? FirstTokenSeconds,
    double? TokensPerSecond,
    string Currency,
    double Input,
    double Output,
    string Source,
    [property: JsonPropertyName("sourceURL")] string SourceURL,
    [property: JsonPropertyName("priceURL")] string PriceURL,
    string Date,
    string Basis,
    string Presentation)
{
    [JsonIgnore] public string Label => Name + " · " + Thinking.MenuName() + " · " + Processing.Name();
}
public sealed record FeaturedAnalysisConfiguration(ReasoningService Service, string Model, string Name, AnalysisProcessing Processing, string English, string Chinese)
{
    public string Title => Name + " · Low · " + Processing.Name();
}
public static class AnalysisConfigurations
{
    public static ValueList<FeaturedAnalysisConfiguration> Featured { get; } =
    [
        new(ReasoningService.SeparateOpenAI, "gpt-6-sol", "GPT-6 Sol", AnalysisProcessing.Fast, "Strong reasoning balanced with response speed, for technical interviews.", "推理能力强，兼顾响应速度，适合专业技术面试。"),
        new(ReasoningService.SeparateOpenAI, "gpt-6-luna", "GPT-6 Luna", AnalysisProcessing.Fast, "Fast generation at very low cost, for frequent live questions.", "高速生成、成本极低，适合高频实时问答。"),
        new(ReasoningService.DeepSeek, "deepseek-flash", "DeepSeek Flash", AnalysisProcessing.Standard, "Excellent Chinese comprehension with balanced speed and value.", "中文理解出色，速度与性价比兼顾。"),
        new(ReasoningService.Glm, "glm-5.3-flashx", "GLM-5.3 FlashX", AnalysisProcessing.Standard, "Very fast output, for quickly composing longer answers.", "生成速度极快，适合需要快速组织长回答的场景。"),
    ];
    public static ValueList<AnalysisConfiguration> All { get; } = EmbeddedJson.Load<ValueList<AnalysisConfiguration>>("AnalysisConfigurations.json");
    public static ValueList<AnalysisConfiguration> Rows(string model) => All.Where(r => r.Model == model).ToValueList();
    public static AnalysisConfiguration? Selection(AppSettings settings) => settings.AnalysisStandardRoute is null ? null : All.FirstOrDefault(r => r.Model == settings.AnalysisModel && r.Thinking == settings.AnalysisThinking && r.Processing == settings.AnalysisProcessing);
    public static bool Recommended(string model, AnalysisThinking thinking, AnalysisProcessing processing) =>
        (thinking == AnalysisThinking.Low && Featured.Any(r => r.Model == model && r.Processing == processing)) || All.Any(r => r.Model == model && r.Thinking == thinking && r.Processing == processing && r.Recommended);
    public static bool ModelIsRecommended(string model) => Rows(model).Any(r => r.Recommended);
    public static ValueList<AnalysisProcessing> ProcessingModes(string model) => Enum.GetValues<AnalysisProcessing>().Where(p => Rows(model).Any(r => r.Processing == p)).ToValueList();
    public static ValueList<AnalysisConfiguration> TopFive { get; } = All.Where(r => r.Rank is not null).OrderBy(r => r.Rank).ToValueList();
    public static string TopReason(int rank, AppLanguage language, ILocaleProvider? locale = null)
    {
        (string English, string Chinese)[] texts =
        [
            ("Balanced quality and speed", "质量速度最平衡"),
            ("Quick Chinese answers at low cost", "中文快答且成本低"),
            ("Very fast first token, very low cost", "极快首字，费用极低"),
            ("Stronger reasoning for complex technical questions", "复杂技术题质量更高"),
            ("Fast output; verify time to the visible answer", "生成极快，需测首答")
        ];
        return rank < 1 || rank > texts.Length ? "" : ServiceGuide.Text(texts[rank - 1].English, texts[rank - 1].Chinese, language, locale);
    }
}
public sealed partial record AppSettings
{
    [JsonIgnore] public AnalysisProcessing AnalysisProcessing
    {
        get => IsOpenAIAnalysis && AnalysisConfigurations.ProcessingModes(AnalysisModel).Contains(OpenAIProcessing) ? OpenAIProcessing : AnalysisProcessing.Standard;
        set { if (IsOpenAIAnalysis) OpenAIProcessing = AnalysisConfigurations.ProcessingModes(AnalysisModel).Contains(value) ? value : AnalysisProcessing.Standard; }
    }
}
