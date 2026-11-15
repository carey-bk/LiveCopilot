using System.IO;
using System.Text;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Onboarding;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class OnboardingTests
{
    private static OnboardingViewModel Model(IPreferenceStore preferences, bool reopen = false) => new(new(preferences),
        new SettingsViewModel(preferences, new MemoryCredentialStore(), new HotkeyStore(preferences)), reopen);

    [Fact]
    public void FirstRunResumesAndOnlyCompletesAfterSixSteps()
    {
        var preferences = new MemoryPreferenceStore();
        var model = Model(preferences);
        Assert.True(model.IsLanguage); Assert.False(model.BackCommand.CanExecute(null));
        model.NextCommand.Execute(null); model.NextCommand.Execute(null);
        Assert.Equal(2, Model(preferences).Step);
        Assert.False(new OnboardingStateStore(preferences).Load().Completed);
        var finished = 0; model.Finished += () => finished++;
        for (var i = 0; i < 4; i++) model.NextCommand.Execute(null);
        Assert.True(new OnboardingStateStore(preferences).Load().Completed);
        Assert.Equal(1, finished);
        model.NextCommand.Execute(null); Assert.Equal(1, finished);
    }
    [Fact]
    public void SkipPersistsDismissalAndDiscardsUnsavedEdits()
    {
        var preferences = new MemoryPreferenceStore();
        var baseline = new AppSettings { Scenario = ScenarioProfile.Defense }; baseline.Save(preferences);
        var model = Model(preferences); model.Settings.Scenario = ScenarioProfile.Meeting;
        model.Settings.OpenAICredential.Stage("never-save-this-key");
        model.SkipCommand.Execute(null);
        var state = new OnboardingStateStore(preferences).Load();
        Assert.True(state.Completed); Assert.True(state.Skipped);
        Assert.Equal(ScenarioProfile.Defense, AppSettings.Load(preferences).Scenario);
        Assert.False(model.Settings.OpenAICredential.HasPendingChange);
    }
    [Fact]
    public void ReopenStartsAtLanguageAndPreservesSavedConfiguration()
    {
        var preferences = new MemoryPreferenceStore();
        new AppSettings { Scenario = ScenarioProfile.Meeting, Language = AppLanguage.English, CompatibleModel = "existing-model" }.Save(preferences);
        new OnboardingStateStore(preferences).Save(new(5, true));
        var model = Model(preferences, true);
        Assert.True(model.IsLanguage);
        Assert.Equal(AppLanguage.English, model.Settings.Language);
        Assert.Equal(ScenarioProfile.Meeting, model.Settings.Scenario);
        Assert.Equal("existing-model", model.Settings.CompatibleModel);
        Assert.True(new OnboardingStateStore(preferences).Load().Completed);
    }
    [Fact]
    public void BackPersistsNavigationAndStopsAtFirstStep()
    {
        var preferences = new MemoryPreferenceStore(); var model = Model(preferences);
        model.NextCommand.Execute(null); model.BackCommand.Execute(null); model.BackCommand.Execute(null);
        Assert.Equal(0, model.Step); Assert.Equal(0, Model(preferences).Step);
    }
    [Fact]
    public void ContinueSavesLanguageAndScenarioWithoutChangingUnrelatedPreferences()
    {
        var preferences = new MemoryPreferenceStore(); new AppSettings { ExcludeOverlayFromCapture = true }.Save(preferences);
        var model = Model(preferences); model.Settings.Language = AppLanguage.TraditionalChinese;
        model.NextCommand.Execute(null); model.Settings.Scenario = ScenarioProfile.Defense; model.NextCommand.Execute(null);
        var saved = AppSettings.Load(preferences);
        Assert.Equal(AppLanguage.TraditionalChinese, saved.Language); Assert.Equal(ScenarioProfile.Defense, saved.Scenario);
        Assert.True(saved.ExcludeOverlayFromCapture);
    }
    [Theory]
    [InlineData("not json", 0)] [InlineData("null", 0)] [InlineData("{\"Step\":-4}", 0)] [InlineData("{\"Step\":99}", 5)]
    public void CorruptOrOutOfRangeProgressIsRecovered(string json, int expected)
    {
        var preferences = new MemoryPreferenceStore(); preferences.Set(OnboardingStateStore.Key, Encoding.UTF8.GetBytes(json));
        Assert.Equal(expected, Model(preferences).Step);
    }
    [Fact]
    public void FailedProgressWriteDoesNotAdvanceOrClose()
    {
        var preferences = new FailingProgressStore(); var model = Model(preferences); var finished = false;
        model.Finished += () => finished = true;
        model.NextCommand.Execute(null); Assert.Equal(0, model.Step); Assert.NotEmpty(model.Error);
        model.SkipCommand.Execute(null); Assert.False(finished);
        preferences.Fail = false; model.NextCommand.Execute(null); Assert.Equal(1, model.Step); Assert.Empty(model.Error);
    }
    [Fact]
    public void InvalidServiceDraftCannotAdvance()
    {
        var model = Model(new MemoryPreferenceStore()); model.Settings.ReasoningService = ReasoningService.Compatible;
        model.Settings.CompatibleBaseURL = "http://invalid.example";
        model.NextCommand.Execute(null); Assert.Equal(0, model.Step); Assert.NotEmpty(model.Error);
    }
    [Fact]
    public void StopDisablesNavigationAndCancelsSecrets()
    {
        var model = Model(new MemoryPreferenceStore()); model.Settings.DeepSeekCredential.Stage("private-value"); model.Stop();
        Assert.False(model.NextCommand.CanExecute(null)); Assert.False(model.SkipCommand.CanExecute(null));
        Assert.False(model.Settings.DeepSeekCredential.HasPendingChange);
    }
    [Theory]
    [InlineData(0, "IsLanguage")] [InlineData(1, "IsScenario")] [InlineData(2, "IsModels")]
    [InlineData(3, "IsAnalysis")] [InlineData(4, "IsPermissions")] [InlineData(5, "IsReady")]
    public void EachStepHasOneVisiblePageAndAccessibleProgress(int step, string property)
    {
        var preferences = new MemoryPreferenceStore(); new OnboardingStateStore(preferences).Save(new(step)); var model = Model(preferences);
        Assert.True((bool)typeof(OnboardingViewModel).GetProperty(property)!.GetValue(model)!);
        var visible = new[] { model.IsLanguage, model.IsScenario, model.IsModels, model.IsAnalysis, model.IsPermissions, model.IsReady };
        Assert.Single(visible, v => v); Assert.Equal(step + 1, model.Progress); Assert.NotEmpty(model.Title);
    }
    private sealed class FailingProgressStore : IPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public bool Fail { get; set; } = true;
        public bool Contains(string key) => inner.Contains(key);
        public byte[]? Get(string key) => inner.Get(key);
        public void Set(string key, byte[] value)
        {
            if (key == OnboardingStateStore.Key && Fail) throw new IOException("blocked");
            inner.Set(key, value);
        }
    }
}
