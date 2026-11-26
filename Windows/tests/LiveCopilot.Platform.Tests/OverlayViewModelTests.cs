using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.Platform.Tests;

public sealed class OverlayViewModelTests
{
    [Fact]
    public void AskingRequiresNonWhitespaceAndStopsDuringShutdown()
    {
        var asked = new List<string>();
        var model = new OverlayViewModel(_ => true, asked.Add);
        model.AskCommand.Execute(null);
        model.Question = "  面试如何准备？  ";
        model.AskCommand.Execute(null);
        model.SetEnabled(false);
        model.AskCommand.Execute(null);
        Assert.Equal(["面试如何准备？"], asked);
    }
    [Fact]
    public void PreferencesPersistBeforeTheyChangeAndPreserveOtherSettings()
    {
        AppSettings? saved = null;
        var model = new OverlayViewModel(s => { saved = s; return true; }, _ => { });
        model.Configure(new() { CompatibleModel = "private-model", Scenario = ScenarioProfile.Meeting });
        model.KnowledgeMode = KnowledgeMode.General;
        model.AnswerLanguage = AnswerLanguage.English;
        model.IncludeConversation = false;
        Assert.Equal("private-model", saved!.CompatibleModel);
        Assert.Equal(ScenarioProfile.Meeting, saved.Scenario);
        Assert.Equal(KnowledgeMode.General, saved.KnowledgeMode);
        Assert.Equal(AnswerLanguage.English, saved.AnswerLanguage);
        Assert.False(saved.IncludeConversation);
    }
    [Fact]
    public void FailedSaveKeepsLastAppliedPreference()
    {
        var model = new OverlayViewModel(_ => false, _ => { });
        model.KnowledgeMode = KnowledgeMode.General;
        Assert.Equal(KnowledgeMode.Hybrid, model.KnowledgeMode);
    }
    [Fact]
    public void TrayVisibilityAndLabelFollowExternalWindowChanges()
    {
        var visibility = new List<bool>();
        var model = new TrayViewModel(visibility.Add, () => { }, () => { });
        model.ToggleCommand.Execute(null);
        Assert.Equal("显示悬浮窗", model.ToggleLabel);
        model.SetVisible(true);
        model.ToggleCommand.Execute(null);
        Assert.Equal([false, false], visibility);
    }
    [Fact]
    public void TrayExitIsIdempotentAndDisablesAllActions()
    {
        var shows = 0; var settings = 0; var exits = 0;
        var model = new TrayViewModel(_ => shows++, () => settings++, () => exits++);
        model.SettingsCommand.Execute(null);
        model.ExitCommand.Execute(null);
        model.ExitCommand.Execute(null);
        model.ToggleCommand.Execute(null);
        model.SettingsCommand.Execute(null);
        Assert.Equal(1, exits); Assert.Equal(1, settings); Assert.Equal(0, shows);
    }
    [Fact]
    public void ExternalShutdownAlsoDisablesTray()
    {
        var model = new TrayViewModel(_ => Assert.Fail(), () => Assert.Fail(), () => Assert.Fail());
        model.BeginShutdown();
        model.ToggleCommand.Execute(null); model.SettingsCommand.Execute(null); model.ExitCommand.Execute(null);
    }
}
