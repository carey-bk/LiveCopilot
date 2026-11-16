using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsPresentationTests
{
    [Fact]
    public void SpeechChoicesExcludeAppleAndEnableOpenAICloudRecognition()
    {
        var preferences = new MemoryPreferenceStore();
        var model = new SettingsViewModel(preferences, new MemoryCredentialStore(), new HotkeyStore(preferences));
        Assert.DoesNotContain(model.ListeningServices, choice => choice.Value == ListeningService.Apple);
        Assert.True(model.ListeningServices.Single(choice => choice.Value == ListeningService.OpenAI).IsAvailable);
        Assert.All(model.ListeningServices.Where(choice => choice.Value is ListeningService.Zipformer or ListeningService.Paraformer), choice => Assert.True(choice.IsAvailable));
    }
    [Fact]
    public void AppearanceAndToolsRoundTripWithoutChangingUnavailablePreferences()
    {
        var preferences = new MemoryPreferenceStore();
        new AppSettings { LayaThreshold = 0.63, AutomaticSuggestions = true, ContinuousQuestionPolicy = ContinuousQuestionPolicy.Complete }.Save(preferences);
        var model = new SettingsViewModel(preferences, new MemoryCredentialStore(), new HotkeyStore(preferences));
        model.Background = AppBackground.White; model.RecapEnabled = false; model.FollowUpEnabled = false;
        Assert.True(model.Save());
        var saved = AppSettings.Load(preferences);
        Assert.Equal(AppBackground.White, saved.Background); Assert.False(saved.RecapEnabled); Assert.False(saved.FollowUpEnabled);
        Assert.Equal(0.63, saved.LayaThreshold); Assert.True(saved.AutomaticSuggestions); Assert.Equal(ContinuousQuestionPolicy.Complete, saved.ContinuousQuestionPolicy);
        model.Background = AppBackground.Frosted; model.Cancel(); Assert.Equal(AppBackground.White, model.Background);
    }
}
