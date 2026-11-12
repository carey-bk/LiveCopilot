namespace LiveCopilot.Core;

public enum ReasoningService
{
    [EnumMember(Value = "sharedOpenAI")] SharedOpenAI,
    [EnumMember(Value = "separateOpenAI")] SeparateOpenAI,
    [EnumMember(Value = "deepSeek")] DeepSeek,
    [EnumMember(Value = "qwen")] Qwen,
    [EnumMember(Value = "glm")] Glm,
    [EnumMember(Value = "kimi")] Kimi,
    [EnumMember(Value = "compatible")] Compatible,
}
