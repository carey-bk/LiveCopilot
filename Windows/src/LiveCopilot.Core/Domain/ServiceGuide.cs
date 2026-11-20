namespace LiveCopilot.Core;

public static class ServiceGuide
{
    public const string Checked = "2026-09-25";
    public static string Text(string en, string zh, AppLanguage language, ILocaleProvider? locale = null) => language.UsesChinese(locale) ? language.InterfaceText(zh, locale) : en;
    public static string Listening(ListeningService service, AppLanguage language, ILocaleProvider? locale = null) => service switch
    {
        ListeningService.OpenAI => Text("OpenAI · cloud, semantic question detection", "OpenAI · 云端，语义判断提问", language, locale),
        ListeningService.Apple => Text("Apple · local/free, one language, macOS 26+", "Apple · 本地/免费，单语言，macOS 26+", language, locale),
        ListeningService.Zipformer => Text("Zipformer · local/free, terminology enhancement", "Zipformer · 本地/免费，术语增强", language, locale),
        _ => Text("Paraformer · local/free, Chinese/English streaming", "Paraformer · 本地/免费，中英文流式", language, locale)
    };
    public static string LivePrice(string model, AppLanguage language, ILocaleProvider? locale = null) => model != "gpt-live-1" ? Unknown(language, locale) : Text(
        "GPT-Live-1: $0.05/min per session, billed per second. Remote Meeting with system audio + microphone opens two sessions: about $0.10/min. Connected silence also counts. Backend model/tool usage is extra.",
        "GPT-Live-1：每路会话 $0.05/分钟，按秒计费。远程会议同时开启系统音频和麦克风时为两路，约 $0.10/分钟。连接期间的静音也计时；后端模型/工具另计费。", language, locale);
    public static string EmbeddingPrice(string model, AppLanguage language, bool compact = false, ILocaleProvider? locale = null)
    {
        var price = model switch { "text-embedding-3-small" => "0.02", "text-embedding-3-large" => "0.13", _ => null };
        if (price is null) return Unknown(language, locale);
        if (compact) return Text($"${price} / 1M input tokens", $"每百万输入 token ${price}", language, locale);
        return Text($"{model}: ${price} per 1M input tokens. Charged for document indexing and query embeddings; re-indexing sends the text again.",
            $"{model}：每百万输入 token ${price}。文档建库与检索问题的向量化均计费；重新建库会再次处理文本。", language, locale);
    }
    public static string AnalysisPrice(ReasoningService service, string model, AppLanguage language, ILocaleProvider? locale = null)
    {
        var settings = new AppSettings { Language = language };
        settings.SelectAnalysisService(service); settings.SelectAnalysisModel(model);
        return AnalysisPricing.Display(settings, locale) is { } price ? price.Summary(language, locale) + Text(" per 1M tokens. ", " / 每 100 万 Token。", language, locale) + price.Quote.Conditions(language, locale) : Unknown(language, locale);
    }
    public static string Unknown(AppLanguage language, ILocaleProvider? locale = null) => Text("Pricing is set by this model's provider; no verified price for this selection. Check its billing page before use.", "当前选择暂无已核对报价，价格由模型服务商决定，请以其计费页面为准。", language, locale);
}
