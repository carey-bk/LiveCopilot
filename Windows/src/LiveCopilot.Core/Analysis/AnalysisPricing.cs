namespace LiveCopilot.Core;

public static class AnalysisCurrencyExtensions
{
    public static string Symbol(this AnalysisCurrency value) => value == AnalysisCurrency.Cny ? "¥" : "$";
}
public sealed record AnalysisExchangeRate(double CnyPerUSD, string Date, string SourceURL)
{
    public static AnalysisExchangeRate Snapshot { get; } = new(7.4992 / 1.1206, "2026-10-09", "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml");
    public double Convert(double value, AnalysisCurrency from, AnalysisCurrency to) => from == to ? value : to == AnalysisCurrency.Cny ? value * CnyPerUSD : value / CnyPerUSD;
}
public sealed record AnalysisPrice(string Model, string Route, AnalysisCurrency Currency, double Input, double Output,
    [property: JsonPropertyName("sourceURL")] string SourceURL, string CheckedAt,
    [property: JsonPropertyName("conditionsEN")] string ConditionsEN, [property: JsonPropertyName("conditionsZH")] string ConditionsZH)
{
    public int Unit => 1_000_000;
    public string Conditions(AppLanguage language, ILocaleProvider? locale = null) => ServiceGuide.Text(ConditionsEN, ConditionsZH, language, locale);
}
public sealed record AnalysisPriceDisplay(AnalysisPrice Quote, AnalysisCurrency Currency)
{
    public AnalysisExchangeRate? ExchangeRate => Quote.Currency == Currency ? null : AnalysisExchangeRate.Snapshot;
    public double Input => AnalysisExchangeRate.Snapshot.Convert(Quote.Input, Quote.Currency, Currency);
    public double Output => AnalysisExchangeRate.Snapshot.Convert(Quote.Output, Quote.Currency, Currency);
    public string Amount(double value) => Currency.Symbol() + value.ToString("F2", CultureInfo.InvariantCulture);
    public string Summary(AppLanguage language, ILocaleProvider? locale = null) => ServiceGuide.Text($"Input {Amount(Input)} / Output {Amount(Output)}", $"输入 {Amount(Input)} / 输出 {Amount(Output)}", language, locale);
}

/// Reviewed offline prices from Swift. These are historical snapshots, never live quotes.
public static class AnalysisPricing
{
    public static ValueList<AnalysisPrice> Quotes { get; } = EmbeddedJson.Load<ValueList<AnalysisPrice>>("AnalysisPrices.json");
    public static AnalysisPriceDisplay? Display(AppSettings settings, ILocaleProvider? locale = null)
    {
        if (settings.AnalysisStandardRoute is not { } route || AnalysisModelCatalog.Model(settings.AnalysisModel, settings.ReasoningService) is not { } model) return null;
        var currency = settings.Language.UsesChinese(locale) ? AnalysisCurrency.Cny : AnalysisCurrency.Usd;
        if (AnalysisConfigurations.Selection(settings) is { } row && route is "openai" or "deepseek" or "qwen-cn" or "glm-cn" or "kimi-cn" && WireEnum.Parse<AnalysisCurrency>(row.Currency) is { } native)
        {
            var en = "Configuration table snapshot (2026-10-11), " + row.Processing.Name() + "; standard uncached text rates. Provider region, peak periods, caching and context length may affect billing.";
            var zh = "2026-10-11 配置表报价，" + row.Processing.Name() + "，未缓存文本；实际账单受地域、峰谷时段、缓存及上下文长度影响。";
            if (row.Model == "deepseek-flash")
            { en += " The table uses the USD off-peak rate; peak usage is billed at a higher rate."; zh += " 表中使用美元低峰价，高峰时段费率更高。"; }
            return new(new(row.Model, route, native, row.Input, row.Output, row.PriceURL, "2026-10-11", en, zh), currency);
        }
        var candidates = Quotes.Where(q => q.Model == model.Id && q.Route == route).ToArray();
        var quote = candidates.FirstOrDefault(q => q.Currency == currency) ?? candidates.FirstOrDefault();
        return quote is null ? null : new(quote, currency);
    }
}
