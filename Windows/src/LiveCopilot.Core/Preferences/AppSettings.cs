namespace LiveCopilot.Core;

// Platform-specific selections are persisted as data only; no Apple/Laya runtime is included.
[JsonConverter(typeof(AppSettingsJsonConverter))]
public sealed partial record AppSettings
{
    public const string DefaultsKey = "livecopilot.settings";
    public static string DefaultReasoningModel => AnalysisModelCatalog.Recommended(ReasoningService.SeparateOpenAI)!.Id;
    public ListeningService ListeningService { get; set; } = ListeningService.Zipformer;
    public LiveSpeechLanguage LiveSpeechLanguage { get; set; } = LiveSpeechLanguage.Mixed;
    public ValueList<string> ProfessionalTerms { get; set; } = LiveCopilot.Core.ProfessionalTerms.Examples;
    public bool ProfessionalTermsEnabled { get; set; } = false;
    public string AppleSpeechLanguage { get; set; } = "chinese";
    public EmbeddingService EmbeddingService { get; set; } = EmbeddingService.OpenAI;
    public string LiveModel { get; set; } = "gpt-live-1";
    public string ReasoningModel { get; set; } = DefaultReasoningModel;
    public string EmbeddingModel { get; set; } = "text-embedding-3-small";
    public string ReasoningEffort { get; set; } = "low";
    public AnalysisProcessing OpenAIProcessing { get; set; } = AnalysisProcessing.Standard;
    public OperatingMode Mode { get; set; } = OperatingMode.Remote;
    public ScenarioProfile Scenario { get; set; } = ScenarioProfile.Interview;
    public bool AutomaticSuggestions { get; set; } = true;
    public double LayaThreshold { get; set; } = 0.8;
    public ContinuousQuestionPolicy ContinuousQuestionPolicy { get; set; } = ContinuousQuestionPolicy.Smart;
    public bool BilingualAnswers { get; set; } = false;
    public string AdditionalAnswerInstructions { get; set; } = "";
    public bool RecapEnabled { get; set; } = true;
    public bool FollowUpEnabled { get; set; } = true;
    public bool IncludeConversation { get; set; } = true;
    public int RetrievalCount { get; set; } = 5;
    public KnowledgeMode KnowledgeMode { get; set; } = KnowledgeMode.Hybrid;
    public AnswerLanguage AnswerLanguage { get; set; } = AnswerLanguage.Auto;
    public AppLanguage Language { get; set; } = AppLanguage.System;
    public AppBackground Background { get; set; } = AppBackground.Glass;
    public bool OverlayAutoHeight { get; set; } = true;
    public bool OverlayEdgeHide { get; set; } = false;
    public bool ShowMenuBarIcon { get; set; } = true;
    public bool ExcludeOverlayFromCapture { get; set; } = false;
    public ReasoningService ReasoningService { get; set; } = ReasoningService.SharedOpenAI;
    public double TranscriptFontSize { get; set; } = 12;
    public double AnswerFontSize { get; set; } = 14;
    public AnalysisConnection QwenConnection { get; set; } = AnalysisConnection.Qwen;
    public AnalysisConnection GlmConnection { get; set; } = AnalysisConnection.Glm;
    public AnalysisConnection KimiConnection { get; set; } = AnalysisConnection.Kimi;
    public string DeepSeekModel { get; set; } = AnalysisModelCatalog.Recommended(ReasoningService.DeepSeek)!.Id;
    public string DeepSeekEffort { get; set; } = "none";
    public string CompatibleBaseURL { get; set; } = "";
    public string CompatiblePath { get; set; } = "chat/completions";
    public string CompatibleModel { get; set; } = "";

    [JsonIgnore] public bool RequiresOpenAIKey => ListeningService == ListeningService.OpenAI || EmbeddingService == EmbeddingService.OpenAI || ReasoningService == ReasoningService.SharedOpenAI;
    [JsonIgnore] public string SelectedEmbeddingIdentity => EmbeddingService == EmbeddingService.Local ? AppPaths.LocalEmbeddingIdentity : EmbeddingModel;
    [JsonIgnore] public ValueList<SuggestionMode> EnabledSuggestionModes => Enum.GetValues<SuggestionMode>().Where(IsEnabled).ToValueList();
    public bool IsEnabled(SuggestionMode mode) => mode switch { SuggestionMode.Reply => true, SuggestionMode.Recap => RecapEnabled, _ => FollowUpEnabled };
    internal void NormalizeDecoded()
    {
        ProfessionalTerms = LiveCopilot.Core.ProfessionalTerms.Clean(string.Join("\n", ProfessionalTerms));
        AdditionalAnswerInstructions = TextElements.Prefix(AdditionalAnswerInstructions, 4000);
        LayaThreshold = double.IsFinite(LayaThreshold) ? Math.Clamp(LayaThreshold, 0.5, 0.99) : 0.8;
        TranscriptFontSize = OverlayTypography.Clamped(TranscriptFontSize, 12);
        AnswerFontSize = OverlayTypography.Clamped(AnswerFontSize, 14);
        RetrievalCount = Math.Clamp(RetrievalCount, 3, 8);
    }
    public static AppSettings Load(IPreferenceStore? store = null)
    {
        try { return (store ?? new FilePreferenceStore()).Get(DefaultsKey) is { } data ? CoreJson.Decode<AppSettings>(Encoding.UTF8.GetString(data)) : new(); }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { return new(); }
    }
    public void Save(IPreferenceStore? store = null) => (store ?? new FilePreferenceStore()).Set(DefaultsKey, Encoding.UTF8.GetBytes(CoreJson.Encode(this)));
    [JsonIgnore] public string AnalysisModel => ReasoningService switch
    {
        ReasoningService.SharedOpenAI or ReasoningService.SeparateOpenAI => ReasoningModel,
        ReasoningService.DeepSeek => DeepSeekModel,
        ReasoningService.Qwen or ReasoningService.Glm or ReasoningService.Kimi => PresetConnection!.Model,
        _ => CompatibleModel
    };
    public CredentialReference AnalysisCredentialReference() => ReasoningService switch
    {
        ReasoningService.SharedOpenAI => CredentialReference.Live,
        ReasoningService.SeparateOpenAI => CredentialReference.SeparateOpenAI,
        ReasoningService.DeepSeek => CredentialReference.DeepSeek,
        ReasoningService.Qwen or ReasoningService.Glm or ReasoningService.Kimi => new("LiveCopilot-Reasoning-" + ReasoningService.RawValue(), "|" + PresetConnection!.Endpoint().AbsoluteUri),
        _ => new("LiveCopilot-Reasoning-Compatible", "|" + CompatibleEndpoint().AbsoluteUri)
    };
    public Uri CompatibleEndpoint() => ServiceEndpoint.Make(CompatibleBaseURL, CompatiblePath);
}

internal sealed class AppSettingsJsonConverter : JsonConverter<AppSettings>
{
    private static readonly System.Reflection.PropertyInfo[] Fields = typeof(AppSettings).GetProperties()
        .Where(p => p.SetMethod is not null && !Attribute.IsDefined(p, typeof(JsonIgnoreAttribute))).ToArray();
    private static string Key(System.Reflection.PropertyInfo property) => JsonNamingPolicy.CamelCase.ConvertName(property.Name);
    public override AppSettings Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("Expected settings object.");
        var result = new AppSettings();
        foreach (var property in Fields)
            if (document.RootElement.TryGetProperty(Key(property), out var value) && value.ValueKind != JsonValueKind.Null)
                property.SetValue(result, value.Deserialize(property.PropertyType, options));
        result.NormalizeDecoded();
        return result;
    }
    public override void Write(Utf8JsonWriter writer, AppSettings value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        foreach (var property in Fields)
        {
            writer.WritePropertyName(Key(property));
            JsonSerializer.Serialize(writer, property.GetValue(value), property.PropertyType, options);
        }
        writer.WriteEndObject();
    }
}
