namespace LiveCopilot.Core;

public enum KnowledgeMode
{
    [EnumMember(Value = "general")] General,
    [EnumMember(Value = "hybrid")] Hybrid,
    [EnumMember(Value = "knowledgeBaseOnly")] KnowledgeBaseOnly,
}
