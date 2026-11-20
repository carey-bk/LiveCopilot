namespace LiveCopilot.Core;

public sealed record CredentialReference(string Service, string AccountSuffix = "")
{
    public string Account => Environment.UserName + AccountSuffix;
    public static CredentialReference Live { get; } = new("LiveCopilot-OpenAI");
    public static CredentialReference SeparateOpenAI { get; } = new("LiveCopilot-Reasoning-OpenAI");
    public static CredentialReference DeepSeek { get; } = new("LiveCopilot-Reasoning-DeepSeek");
}

public static class ServiceEndpoint
{
    public static Uri Make(string baseUrl, string path)
    {
        var baseValue = baseUrl.Trim();
        path = path.Trim().Trim('/').Trim();
        if (!Uri.TryCreate(baseValue, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host.Length == 0 ||
            uri.UserInfo.Length > 0 || baseValue.Contains('@') || baseValue.Contains('?') || baseValue.Contains('#') ||
            path.Length == 0 || path.Contains("://", StringComparison.Ordinal) || path.Contains('?') || path.Contains('#') || path.Split('/').Contains(".."))
            throw new CopilotException("Enter an HTTPS base URL and API path without credentials, query parameters or fragments.");
        var builder = new UriBuilder(uri) { Scheme = "https", Host = uri.Host.ToLowerInvariant(), Port = uri.IsDefaultPort ? -1 : uri.Port };
        var prefix = uri.AbsolutePath.Trim('/');
        builder.Path = "/" + (prefix.Length == 0 ? path : prefix + "/" + path);
        return builder.Uri;
    }
}

public static class PreferenceLabels
{
    public static bool UsesLightAppearance(this AppBackground value) => value != AppBackground.Glass;
    public static string Label(this AppBackground value) => value switch { AppBackground.Glass => "Translucent glass", AppBackground.Frosted => "Soft frosted", _ => "Solid white" };
    public static string Detail(this AppBackground value) => value switch
    {
        AppBackground.Glass => "Translucent glass lets more of your desktop show through.",
        AppBackground.Frosted => "Soft frosted keeps a hint of the background with a light veil for clearer text.",
        _ => "Solid white keeps dark text readable over any wallpaper."
    };
    public static string Label(this ReasoningService value) => value switch
    {
        ReasoningService.SharedOpenAI => "Use Live service's OpenAI", ReasoningService.SeparateOpenAI => "OpenAI · separate key",
        ReasoningService.DeepSeek => "DeepSeek", ReasoningService.Qwen => "Qwen", ReasoningService.Glm => "GLM · Zhipu",
        ReasoningService.Kimi => "Kimi · Moonshot", _ => "OpenAI-compatible"
    };
    public static string Label(this ContinuousQuestionPolicy value) => value switch
    { ContinuousQuestionPolicy.Fast => "Fast response", ContinuousQuestionPolicy.Smart => "Smart merging", _ => "Complete question first" };
    public static string? Instruction(this LiveSpeechLanguage value) => value switch
    {
        LiveSpeechLanguage.Chinese => "Expect primarily Mandarin Chinese. Write spoken Mandarin in Simplified Chinese. Preserve English names and technical terms only when actually spoken. Do not translate or invent words to fit this preference.",
        LiveSpeechLanguage.English => "Expect primarily English, including accented English. Write spoken English in English. Preserve Mandarin only when it is clearly spoken. Do not translate or invent words to fit this preference.",
        LiveSpeechLanguage.Mixed => "Expect Mandarin Chinese and English, possibly alternating within one sentence. Write each spoken span in its original language: Simplified Chinese for Mandarin and English for English. Keep actually spoken English names and technical terms. Do not translate.",
        _ => null
    };
}

public static class ProfessionalTerms
{
    public static ValueList<string> Examples { get; } = ["Vue", "React", "TypeScript", "Next.js", "PyTorch", "GPT-6", "LiveCopilot"];
    public static ValueList<string> Clean(string text) => Regex.Split(text, @"\r\n|[\n\r\v\f\u0085\u2028\u2029]")
        .Select(x => x.Trim().Normalize()).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToValueList();
}
