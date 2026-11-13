namespace LiveCopilot.Core;

/// Read-only session boundary; hosts own the index and embedding provider lifetimes.
public interface IKnowledgeRetriever
{
    ValueList<KnowledgeDocument> Documents();
    ValueList<RetrievedSource> Retrieve(RetrievalQuery query, IReadOnlyList<float>? vector, string model, int limit);
}
