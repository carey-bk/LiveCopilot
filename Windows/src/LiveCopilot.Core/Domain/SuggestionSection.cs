namespace LiveCopilot.Core;

public sealed record SuggestionSection(string Title, string Content)
{
    public string Id => Title;
}
