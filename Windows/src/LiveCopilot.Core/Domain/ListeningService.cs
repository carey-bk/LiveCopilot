namespace LiveCopilot.Core;

public enum ListeningService
{
    [EnumMember(Value = "zipformer")] Zipformer,
    [EnumMember(Value = "paraformer")] Paraformer,
    [EnumMember(Value = "apple")] Apple,
    [EnumMember(Value = "openAI")] OpenAI,
}
