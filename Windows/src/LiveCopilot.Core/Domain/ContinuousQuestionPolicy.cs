namespace LiveCopilot.Core;

public enum ContinuousQuestionPolicy
{
    [EnumMember(Value = "fast")] Fast,
    [EnumMember(Value = "smart")] Smart,
    [EnumMember(Value = "complete")] Complete,
}
