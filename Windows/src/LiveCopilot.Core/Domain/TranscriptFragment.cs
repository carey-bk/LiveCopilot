namespace LiveCopilot.Core;

public sealed record TranscriptFragment([property: JsonRequired] string Id, [property: JsonRequired] Speaker Speaker,
    [property: JsonRequired] string Text,
    [property: JsonPropertyName("startMS"), JsonRequired] int StartMs,
    [property: JsonPropertyName("endMS"), JsonRequired] int EndMs,
    [property: JsonRequired] DateTimeOffset ReceivedAt);
