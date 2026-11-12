namespace LiveCopilot.Core;

public sealed record RetrievedSource(SourceChunk Chunk, double Score, double? SemanticSimilarity = null, double LexicalCoverage = 0)
{
    public string Id => Chunk.Id;
    public string Relevance => (SemanticSimilarity ?? 0) >= 0.58 || LexicalCoverage >= 0.6 ? "strong" : "partial";
}
