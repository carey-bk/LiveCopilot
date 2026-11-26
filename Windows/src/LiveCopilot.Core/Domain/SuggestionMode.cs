namespace LiveCopilot.Core;

public enum SuggestionMode
{
    [EnumMember(Value = "reply")] Reply,
    [EnumMember(Value = "recap")] Recap,
    [EnumMember(Value = "followUp")] FollowUp,
}
