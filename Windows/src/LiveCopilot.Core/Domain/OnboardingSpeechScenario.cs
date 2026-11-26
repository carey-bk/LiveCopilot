namespace LiveCopilot.Core;

public enum OnboardingSpeechScenario
{
    [EnumMember(Value = "mixedInterview")] MixedInterview,
    [EnumMember(Value = "singleLanguage")] SingleLanguage,
    [EnumMember(Value = "multilingualMeeting")] MultilingualMeeting,
}
