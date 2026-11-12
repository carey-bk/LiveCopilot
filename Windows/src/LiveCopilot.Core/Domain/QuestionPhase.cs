namespace LiveCopilot.Core;

public enum QuestionPhase
{
    [EnumMember(Value = "Listening")] Listening,
    [EnumMember(Value = "Possible question forming")] Forming,
    [EnumMember(Value = "Question ready")] Complete,
    [EnumMember(Value = "Assistance in progress")] Working,
    [EnumMember(Value = "Follow-up question")] FollowUp,
    [EnumMember(Value = "Already handled")] Duplicate,
    [EnumMember(Value = "User has already answered")] Answered,
    [EnumMember(Value = "Waiting for complete context")] Waiting,
}
