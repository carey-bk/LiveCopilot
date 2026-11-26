namespace LiveCopilot.Core;

public enum AnalysisMetricTier { Fast, Steady, Slow, Inexpensive, ModeratePrice, Expensive, Uncertain }

public static class AnalysisMetricTiers
{
    public static AnalysisMetricTier? Latency(double? seconds) => seconds is not { } n || !double.IsFinite(n) || n < 0 ? null : n <= 1.5 ? AnalysisMetricTier.Fast : n <= 3.5 ? AnalysisMetricTier.Steady : AnalysisMetricTier.Slow;
    public static AnalysisMetricTier? Generation(double? tokens) => tokens is not { } n || !double.IsFinite(n) || n <= 0 ? null : n >= 100 ? AnalysisMetricTier.Fast : n >= 50 ? AnalysisMetricTier.Steady : AnalysisMetricTier.Slow;
    public static AnalysisMetricTier? Price(double? output, AnalysisCurrency currency)
    {
        if (output is not { } n || !double.IsFinite(n) || n < 0) return null;
        return n <= (currency == AnalysisCurrency.Cny ? 10 : 1.5) ? AnalysisMetricTier.Inexpensive : n <= (currency == AnalysisCurrency.Cny ? 50 : 7.5) ? AnalysisMetricTier.ModeratePrice : AnalysisMetricTier.Expensive;
    }
    public static (double Lower, double Upper)? Bounds(string text)
    {
        var parts = text.Split('–');
        if (parts.Length is < 1 or > 2 || !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var lower) ||
            !double.TryParse(parts[^1], NumberStyles.Float, CultureInfo.InvariantCulture, out var upper) || !double.IsFinite(lower) || !double.IsFinite(upper) || lower < 0 || upper < lower) return null;
        return (lower, upper);
    }
    public static AnalysisMetricTier? Range(string text, Func<double?, AnalysisMetricTier?> classify)
    {
        if (Bounds(text) is not { } bounds || classify(bounds.Lower) is not { } first || classify(bounds.Upper) is not { } last) return null;
        return first == last ? first : AnalysisMetricTier.Uncertain;
    }
}

public sealed record AnalysisPerformanceSample(string Model, string Effort, double FirstTokenSeconds, double TokensPerSecond,
    double? FirstAnswerSeconds, string Source, string Url, string Route, string CapturedAt, string Method, bool ProductReference = false);
public sealed record AnalysisPerformanceSelection(string Effort, AnalysisPerformanceSample? Sample, bool MatchesConfiguration)
{
    public AnalysisPerformanceSample? MatchingSample => MatchesConfiguration ? Sample : null;
}
public static class AnalysisPerformance
{
    public static ValueList<AnalysisPerformanceSample> Samples { get; } = AnalysisConfigurations.All
        .Where(r => r.Kind != AnalysisReferenceKind.Estimate && r.FirstTokenSeconds is not null && r.TokensPerSecond is not null)
        .Select(r => new AnalysisPerformanceSample(r.Model, r.Thinking.ReferenceKey(), r.FirstTokenSeconds!.Value, r.TokensPerSecond!.Value,
            r.Model == "kimi-k2.6" && r.Thinking == AnalysisThinking.Enabled ? 80.95 : r.Model is "deepseek-flash" or "kimi-k2.6" && r.Thinking == AnalysisThinking.Disabled ? r.FirstTokenSeconds : null,
            r.Source, r.SourceURL, r.Service.RawValue(), r.Date, r.Basis, r.Kind == AnalysisReferenceKind.Community)).ToValueList();
    public static AnalysisPerformanceSelection Selection(AppSettings settings)
    {
        var effort = settings.AnalysisThinking.ReferenceKey();
        if (settings.AnalysisProcessing != AnalysisProcessing.Standard || settings.AnalysisStandardRoute is null || AnalysisModelCatalog.Model(settings.AnalysisModel, settings.ReasoningService) is not { } model)
            return new(effort, null, false);
        var sample = Samples.FirstOrDefault(s => s.Model == model.Id && s.Effort == effort);
        return new(effort, sample, sample is not null);
    }
}
