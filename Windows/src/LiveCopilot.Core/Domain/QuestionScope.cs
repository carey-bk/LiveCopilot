namespace LiveCopilot.Core;


public static class QuestionScope
{
    public static bool NeedsContext(string question)
    {
        var q = question.ToLowerInvariant().Trim();
        if (q.StartsWith("what about ", StringComparison.Ordinal) || q.StartsWith("how about ", StringComparison.Ordinal) || q.StartsWith('那')) return true;
        if (TextElements.Count(q) < 18 && new[] { "why", "why not", "how so", "为什么", "为什么呢", "然后呢", "怎么做" }.Contains(TextElements.TrimPunctuation(q))) return true;
        return Regex.IsMatch(q, @"\b(it|its|that|those|these|they|their|this approach|this method|the previous|above)\b|它|这个|那个|上述|刚才|刚刚|其中|呢[？?]?$");
    }
}
