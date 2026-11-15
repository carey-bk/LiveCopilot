using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Onboarding;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsPolishTests
{
    [Theory]
    [InlineData("0.1.0-ci.11+6a430e7abc", "0.1.0-ci.11")]
    [InlineData("1.2.3", "1.2.3")]
    public void SidebarVersionPreservesReleaseLabelAndOmitsBuildMetadata(string full, string shortVersion) => Assert.Equal(shortVersion, SettingsViewModel.CompactVersion(full));
    [Fact]
    public void SpeechChipsTrackEngineAndLanguage()
    {
        var store = new MemoryPreferenceStore(); var settings = new SettingsViewModel(store, new MemoryCredentialStore(), new(store));
        Assert.Contains("术语增强", settings.SpeechChips); Assert.Contains("无 API 费用", settings.SpeechChips);
        settings.ListeningService = ListeningService.Paraformer; settings.LiveSpeechLanguage = LiveSpeechLanguage.English;
        Assert.DoesNotContain("术语增强", settings.SpeechChips); Assert.Contains("英文", settings.SpeechChips);
        settings.ListeningService = ListeningService.OpenAI; Assert.Equal(["云端", "即将推出"], settings.SpeechChips);
    }
    [Fact]
    public void FreshLanguageDefaultsToSimplifiedChineseAndReopenPreservesSystemPreference()
    {
        var store = new MemoryPreferenceStore();
        OnboardingViewModel Create(bool reopen = false) => new(new(store), new(store, new MemoryCredentialStore(), new(store)), reopen);
        var fresh = Create(); Assert.Equal(AppLanguage.SimplifiedChinese, fresh.Settings.Language);
        fresh.NextCommand.Execute(null); Assert.Equal(AppLanguage.SimplifiedChinese, AppSettings.Load(store).Language);
        new AppSettings { Language = AppLanguage.System }.Save(store);
        Assert.Equal(AppLanguage.System, Create(true).Settings.Language);
    }
    [Fact]
    public void UsageSelectionPersistsModeAndTypingWithoutStartingSession()
    {
        var store = new MemoryPreferenceStore();
        OnboardingViewModel Create() => new(new(store), new(store, new MemoryCredentialStore(), new(store)));
        var guide = Create(); guide.Usage = OnboardingUsage.InPerson;
        guide.NextCommand.Execute(null); Assert.Equal(OperatingMode.InPerson, AppSettings.Load(store).Mode);
        Assert.Equal(OnboardingUsage.InPerson, Create().Usage);
        guide.Usage = OnboardingUsage.Typing; guide.NextCommand.Execute(null);
        Assert.True(new OnboardingStateStore(store).Load().PrefersTyping); Assert.Equal(OnboardingUsage.Typing, Create().Usage);
        guide.Usage = OnboardingUsage.RemoteMeeting; guide.NextCommand.Execute(null);
        Assert.Equal(OperatingMode.Remote, AppSettings.Load(store).Mode); Assert.False(new OnboardingStateStore(store).Load().PrefersTyping);
    }
    [Fact]
    public void SkippingDiscardsUnsavedUsageChoice()
    {
        var store = new MemoryPreferenceStore();
        var guide = new OnboardingViewModel(new(store), new(store, new MemoryCredentialStore(), new(store)));
        guide.Usage = OnboardingUsage.InPerson; guide.SkipCommand.Execute(null);
        Assert.Equal(OperatingMode.Remote, AppSettings.Load(store).Mode);
    }
    [Fact]
    public void ProgressAlwaysHasSixSegmentsWithOneCurrentStep()
    {
        var store = new MemoryPreferenceStore(); var guide = new OnboardingViewModel(new(store), new(store, new MemoryCredentialStore(), new(store)));
        for (var i = 0; i < 6; i++)
        {
            Assert.Equal(6, guide.Segments.Count); Assert.Single(guide.Segments, s => s.Current);
            Assert.Equal(i + 1, guide.Segments.Count(s => s.Reached)); Assert.True(guide.Segments[i].Current);
            guide.NextCommand.Execute(null);
        }
    }
}
