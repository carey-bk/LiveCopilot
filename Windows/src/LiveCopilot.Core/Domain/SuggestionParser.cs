namespace LiveCopilot.Core;


public static class SuggestionParser
{
    public static IReadOnlyList<SuggestionSection> Sections(string text)
    {
        var sections = new List<SuggestionSection>();
        var title = "";
        var body = new List<string>();
        string[] known = ["suggested answer", "evidence & notes", "evidence and notes", "recap", "follow-up", "建议回答", "回答建议", "证据与说明", "证据与备注", "总结", "追问"];
        void Flush()
        {
            var value = string.Join("\n", body).Trim();
            if (value.Length > 0) sections.Add(new(title, value));
            body.Clear();
        }
        foreach (var line in Regex.Split(text, @"\r\n|[\n\r\v\f\u0085\u2028\u2029]"))
        {
            var trimmed = line.Trim();
            var heading = trimmed.Trim('#', '*', ':', '：', ' ');
            if (trimmed.StartsWith("## ", StringComparison.Ordinal) || trimmed.StartsWith("### ", StringComparison.Ordinal) || known.Contains(heading.ToLowerInvariant()))
            { Flush(); title = heading; }
            else body.Add(line);
        }
        Flush();
        return sections;
    }
    public static IReadOnlyList<int> CitedIndices(string text, int sourceCount) => Regex.Matches(text, @"\[S(\d+)\]")
        .Select(x => int.TryParse(x.Groups[1].Value, out var n) ? n : 0)
        .Where(n => n > 0 && n <= sourceCount).Distinct().Order().ToArray();
}
