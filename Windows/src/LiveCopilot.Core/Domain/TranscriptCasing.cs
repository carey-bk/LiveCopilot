namespace LiveCopilot.Core;

public static class TranscriptCasing
{
    public static string Format(string text, IReadOnlyList<string>? terms = null)
    {
        terms ??= [];
        var letters = text.Where(char.IsAsciiLetter).ToArray();
        if (letters.Length == 0 || letters.Any(char.IsLower)) return RestoreTerms(text, terms);
        var result = text.ToLowerInvariant();
        string[] names = ["AI", "API", "SQL", "HTTP", "HTTPS", "URL", "JSON", "HTML", "CSS", "CPU", "GPU", "RAM", "SDK", "UI", "UX", "USB", "TCP", "IP", "DNS", "LLM", "GPT", "iOS", "macOS", "GitHub", "OpenAI", "ChatGPT", "Python", "JavaScript", "TypeScript", "SQL", "I", "I'm", "I've", "I'll", "I'd", .. terms.Where(t => t.Length > 0)];
        foreach (var name in names.OrderByDescending(TextElements.Count))
            result = Regex.Replace(result, @"(?i)(?<![\p{L}\p{N}_])" + Regex.Escape(name) + @"(?![\p{L}\p{N}_])", _ => name, RegexOptions.CultureInvariant);
        result = Regex.Replace(result, @"(^|[.!?。！？]\s+)([A-Za-z]+)", m =>
        {
            var word = m.Groups[2].Value;
            return m.Groups[1].Value + (word != word.ToLowerInvariant() || names.Contains(word) ? word : char.ToUpperInvariant(word[0]) + word[1..]);
        });
        return RestoreTerms(result, terms);
    }
    private static string RestoreTerms(string text, IReadOnlyList<string> terms)
    {
        foreach (var term in terms.Where(t => t.Any(char.IsAsciiLetter)))
        {
            string[] forms = term.ToUpperInvariant() switch
            {
                "GPT-6" => [term, "GPT SIX", "GPT六", "G P T SIX", "GPT 6"],
                "NEXT.JS" => [term, "NEXT JS", "NEXT J S", "NEXT DOT JS"], "TYPESCRIPT" => [term, "TYPE SCRIPT"],
                "PYTORCH" => [term, "PY TORCH", "PIE TORCH"], "LIVECOPILOT" => [term, "LIVE CO PILOT", "LIVE COPILOT"], _ => [term]
            };
            foreach (var form in forms.Where(f => f.Length > 0))
                text = Regex.Replace(text, @"(?i)(?<![A-Za-z0-9_])" + string.Join(@"\s*", form.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(Regex.Escape)) + @"(?![A-Za-z0-9_])", _ => term, RegexOptions.CultureInvariant);
        }
        return text;
    }
}
