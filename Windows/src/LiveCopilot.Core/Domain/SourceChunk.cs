namespace LiveCopilot.Core;

public sealed record SourceChunk(
    [property: JsonRequired] string Id,
    [property: JsonPropertyName("documentID"), JsonRequired] string DocumentId,
    [property: JsonRequired] string DocumentName, [property: JsonRequired] int Ordinal,
    int? Page, [property: JsonRequired] string Text, [property: JsonRequired] ValueList<float> Vector,
    [property: JsonRequired] string EmbeddingModel)
{
    [JsonIgnore] public string SourceLabel => $"{DocumentName} · " + (Page is { } p ? $"p.{p} · " : "") + $"chunk {Ordinal + 1}";
    public string DisplayLabel(AppLanguage language, ILocaleProvider? locale = null) => !language.UsesChinese(locale) ? SourceLabel
        : $"{DocumentName} · " + (Page is { } p ? language.InterfaceText($"第 {p} 页 · ", locale) : "") + $"片段 {Ordinal + 1}";
}
