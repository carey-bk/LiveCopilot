namespace LiveCopilot.Core;

public interface ILocaleProvider { IReadOnlyList<string> PreferredLanguages { get; } }
public sealed class CultureLocaleProvider : ILocaleProvider
{
    public IReadOnlyList<string> PreferredLanguages => [CultureInfo.CurrentUICulture.Name];
}
public interface IChineseTextConverter { string ToTraditional(string text); }

/// Offline ICU Hans-Hant snapshot for application copy; hosts may supply a full transliterator.
public sealed class InterfaceChineseTextConverter : IChineseTextConverter
{
    private static readonly IReadOnlyDictionary<string, string> Map = EmbeddedJson.Load<Dictionary<string, string>>("Interface.zh-Hant.json");
    public string ToTraditional(string text)
    {
        if (Map.TryGetValue(text, out var translated)) return translated;
        return string.Concat(text.EnumerateRunes().Select(r => Map.GetValueOrDefault(r.ToString(), r.ToString())));
    }
}
public static class AppLanguageExtensions
{
    public static bool UsesChinese(this AppLanguage language, ILocaleProvider? locale = null) => language switch
    {
        AppLanguage.System => (locale ?? new CultureLocaleProvider()).PreferredLanguages.FirstOrDefault()?.StartsWith("zh", StringComparison.Ordinal) == true,
        AppLanguage.English => false, _ => true
    };
    public static bool IsTraditional(string identifier)
    {
        var parts = identifier.Replace('_', '-').ToLowerInvariant().Split('-');
        return parts[0] == "zh" && !parts.Contains("hans") && parts.Any(p => p is "hant" or "tw" or "hk" or "mo");
    }
    public static bool UsesTraditionalChinese(this AppLanguage language, ILocaleProvider? locale = null) => language == AppLanguage.TraditionalChinese ||
        (language == AppLanguage.System && IsTraditional((locale ?? new CultureLocaleProvider()).PreferredLanguages.FirstOrDefault() ?? "en"));
    public static CultureInfo Locale(this AppLanguage language, ILocaleProvider? locale = null) => CultureInfo.GetCultureInfo(language.UsesTraditionalChinese(locale) ? "zh-Hant" : language.UsesChinese(locale) ? "zh-Hans" : "en");
    public static string InterfaceText(this AppLanguage language, string text, ILocaleProvider? locale = null, IChineseTextConverter? converter = null) =>
        language.UsesTraditionalChinese(locale) ? (converter ?? new InterfaceChineseTextConverter()).ToTraditional(text) : text;
}

public static class L10n
{
    public static IReadOnlyDictionary<string, string> Chinese { get; } = new System.Collections.ObjectModel.ReadOnlyDictionary<string, string>(EmbeddedJson.Load<Dictionary<string, string>>("Localization.zh-Hans.json"));
    public static string Text(string text, AppLanguage language, ILocaleProvider? locale = null, IChineseTextConverter? converter = null)
    {
        if (!language.UsesChinese(locale)) return text;
        foreach (var (prefix, translated) in new[] { ("Indexing ", "正在索引 "), ("Re-indexing ", "正在重建索引 ") })
            if (text.StartsWith(prefix, StringComparison.Ordinal)) return language.InterfaceText(translated, locale, converter) + text[prefix.Length..];
        var result = SimplifiedText(text, language, locale, converter);
        return result == text ? text : language.InterfaceText(result, locale, converter);
    }
    private static string SimplifiedText(string text, AppLanguage language, ILocaleProvider? locale, IChineseTextConverter? converter)
    {
        if (Chinese.TryGetValue(text, out var translated)) return translated;
        if (ServiceHTTPFailure.KindFromSafeMessage(text) is { } kind && Chinese.TryGetValue(kind.Message(), out translated)) return translated + text[kind.Message().Length..];
        if (text.StartsWith("Listening · ", StringComparison.Ordinal))
            return string.Join(" · ", text.Split(" · ").Select(p => p.EndsWith(" ready", StringComparison.Ordinal) ? Text(p[..^6], language, locale, converter) + " 已就绪" : Text(p, language, locale, converter)));
        if (text.StartsWith("Keychain access failed (", StringComparison.Ordinal))
            return "钥匙串访问失败 " + text["Keychain access failed ".Length..].Split('.')[0] + "。请解锁登录钥匙串，并允许 LiveCopilot 访问所选服务的凭据。";
        foreach (var speaker in Enum.GetValues<Speaker>())
        {
            if (text == speaker.RawValue() + ": connecting to Live…") return Text(speaker.RawValue(), language, locale, converter) + "：正在连接实时服务…";
            if (text == speaker.RawValue() + ": disconnected — stop/start listening to retry.") return Text(speaker.RawValue(), language, locale, converter) + "：连接已断开，请重新开始监听。";
        }
        (string Pattern, string Replacement)[] rules =
        [
            (@"^Live authentication/access failed \(([a-z_]+)\).*$", "实时服务验证失败（$1），请检查密钥与模型权限。"),
            (@"^Live command/session failed \(([a-z_]+)\).*$", "实时会话请求失败（$1），请检查模型配置、权限和网络。"),
            (@"^Service authentication/access failed \((\d+)\).*$", "服务身份验证或访问失败（$1），请在“服务”中检查密钥与模型权限。"),
            (@"^Service rejected the request \((\d+)\).*$", "服务拒绝请求（$1），请检查模型名称和配置。"),
            (@"^Service is temporarily unavailable \((\d+)\).*$", "服务暂不可用（$1），请稍后重试。"),
            (@"^Service request failed \(HTTP (\d+)\).*$", "服务请求失败（HTTP $1），请检查网络后重试。")
        ];
        foreach (var rule in rules) if (Regex.IsMatch(text, rule.Pattern)) return Regex.Replace(text, rule.Pattern, rule.Replacement);
        return text;
    }
}
