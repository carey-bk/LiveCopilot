namespace LiveCopilot.Core;

public enum AnswerState
{
    [EnumMember(Value = "queued")] Queued,
    [EnumMember(Value = "generating")] Generating,
    [EnumMember(Value = "completed")] Completed,
    [EnumMember(Value = "interrupted")] Interrupted,
    [EnumMember(Value = "failed")] Failed,
}
