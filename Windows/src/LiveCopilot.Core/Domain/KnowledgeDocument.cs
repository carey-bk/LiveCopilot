namespace LiveCopilot.Core;

public sealed record KnowledgeDocument([property: JsonRequired] string Id, [property: JsonRequired] string Name,
    [property: JsonRequired] DateTimeOffset ImportedAt, [property: JsonRequired] string LocalPath,
    [property: JsonRequired] string Status, [property: JsonRequired] int ChunkCount,
    [property: JsonRequired] string EmbeddingModel, string? Error = null);
