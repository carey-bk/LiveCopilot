namespace LiveCopilot.Core;

public enum EmbeddingService
{
    [EnumMember(Value = "openAI")] OpenAI,
    [EnumMember(Value = "local")] Local,
}
