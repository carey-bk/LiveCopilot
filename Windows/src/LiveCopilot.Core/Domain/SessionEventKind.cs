namespace LiveCopilot.Core;

public enum SessionEventKind
{
    [EnumMember(Value = "room")] Room,
    [EnumMember(Value = "nearby")] Nearby,
    [EnumMember(Value = "own")] Own,
    [EnumMember(Value = "question")] Question,
    [EnumMember(Value = "answer")] Answer,
}
