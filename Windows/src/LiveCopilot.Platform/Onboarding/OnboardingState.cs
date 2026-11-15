using System.Text.Json;
using LiveCopilot.Core;

namespace LiveCopilot.Platform.Onboarding;

public sealed record OnboardingState(int Step = 0, bool Completed = false, bool Skipped = false);

/// Windows-only preference key keeps migration independent of Mac's onboarding version.
public sealed class OnboardingStateStore(IPreferenceStore preferences)
{
    public const string Key = "livecopilot.windows.onboarding.v1";
    public OnboardingState Load()
    {
        try
        {
            if (preferences.Get(Key) is not { } bytes) return new();
            var state = JsonSerializer.Deserialize<OnboardingState>(bytes) ?? new();
            return state with { Step = Math.Clamp(state.Step, 0, 5) };
        }
        catch (JsonException) { return new(); }
    }
    public void Save(OnboardingState state) => preferences.Set(Key, JsonSerializer.SerializeToUtf8Bytes(state));
}
