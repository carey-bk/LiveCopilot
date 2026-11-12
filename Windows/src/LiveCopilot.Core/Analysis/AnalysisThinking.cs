namespace LiveCopilot.Core;

public enum AnalysisThinking
{
    [EnumMember(Value = "modelDefault")] ModelDefault,
    [EnumMember(Value = "disabled")] Disabled,
    [EnumMember(Value = "enabled")] Enabled,
    [EnumMember(Value = "low")] Low,
    [EnumMember(Value = "medium")] Medium,
    [EnumMember(Value = "high")] High,
    [EnumMember(Value = "xhigh")] Xhigh,
    [EnumMember(Value = "max")] Max,
}
