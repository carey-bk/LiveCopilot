namespace LiveCopilot.Core;


internal static class EmbeddedJson
{
    public static T Load<T>(string name)
    {
        using var stream = typeof(EmbeddedJson).Assembly.GetManifestResourceStream("LiveCopilot.Core.Resources." + name)
            ?? throw new InvalidOperationException($"Missing embedded resource {name}.");
        return JsonSerializer.Deserialize<T>(stream, CoreJson.Default) ?? throw new JsonException($"Empty resource {name}.");
    }
}
