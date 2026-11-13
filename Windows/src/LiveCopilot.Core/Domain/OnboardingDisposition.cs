namespace LiveCopilot.Core;

public enum OnboardingDisposition
{
    [EnumMember(Value = "inProgress")] InProgress,
    [EnumMember(Value = "deferred")] Deferred,
    [EnumMember(Value = "completed")] Completed,
    [EnumMember(Value = "existingUser")] ExistingUser,
}
