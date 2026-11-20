namespace LiveCopilot.Core;


/// Deterministic fallback for platforms without NaturalLanguage. Hosts may inject a statistical detector.
public sealed class TextLanguageDetector : ITextLanguageDetector
{
    public bool IsChinese(string text)
    {
        var unquoted = Regex.Replace(text, "[“\\\"].*?[”\\\"]", "");
        if (Regex.IsMatch(unquoted, @"[\u3400-\u9fff].*(是什么|怎么|如何|为什么|能否|吗|呢|的|了)|^(请|为什么|如何|怎么|这个|什么)")) return true;
        if (Regex.IsMatch(unquoted, @"(?i)^\s*(what|how|why|when|where|who|can|could|would|please|explain|tell)\b")) return false;
        var han = unquoted.EnumerateRunes().Count(r => r.Value is >= 0x3400 and <= 0x9fff);
        var latin = Regex.Matches(unquoted, @"[A-Za-z]+").Count;
        return han > 0 && han >= latin * 2;
    }
}
