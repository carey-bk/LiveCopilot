namespace LiveCopilot.Core;


internal static class PromptText
{
    private static readonly IReadOnlyDictionary<string, string> Values = EmbeddedJson.Load<Dictionary<string, string>>("Prompts.json");
    public static string Get(string name) => Values[name];
}
