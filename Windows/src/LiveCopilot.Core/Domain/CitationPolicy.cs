namespace LiveCopilot.Core;


public static class CitationPolicy
{
    public static string Sanitized(string raw, int sourceCount)
    {
        var text = Regex.Replace(raw, @"\[S(\d+)\]", m => !long.TryParse(m.Groups[1].Value, out var n) || n < 1 || n > sourceCount ? "" : m.Value);
        return Regex.Replace(text, @"\[S\d*$", "");
    }
}
