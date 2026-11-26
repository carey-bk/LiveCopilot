using System.Windows;
using LiveCopilot.Core;
using LiveCopilot.Platform.Onboarding;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.App;

public partial class MainWindow
{
    private OnboardingWindow? onboardingWindow;
    partial void AddShutdownSteps(List<Func<Task>> steps) => steps.Insert(0, () => onboardingWindow?.PrepareForShutdownAsync() ?? Task.CompletedTask);
    partial void FocusActiveGuide(ref bool handled)
    {
        if (onboardingWindow is null) return;
        SetOverlayVisible(true); onboardingWindow.Activate(); handled = true;
    }
    partial void OpenFirstRun()
    {
        // Every ordinary smoke launch skips the wizard; the UI driver explicitly opts in.
        if (AppRuntime.IsSmoke && Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE_ONBOARDING") != "1") return;
        if (!new OnboardingStateStore(preferences).Load().Completed)
            Dispatcher.BeginInvoke(() => ShowOnboarding(false));
        else ShowOperationGuide(false);
    }
    internal void ShowOnboarding(bool reopen)
    {
        if (closeRequested || hotkeyStore is null) return;
        if (onboardingWindow is not null) { onboardingWindow.Activate(); return; }
        SetOverlayVisible(true);
        var draft = new SettingsViewModel(preferences, credentials, hotkeyStore);
        draft.Saved += ApplySettings;
        var model = new OnboardingViewModel(new(preferences), draft, reopen);
        try
        {
            onboardingWindow = new OnboardingWindow(model) { Owner = this };
            onboardingWindow.ShowDialog();
        }
        finally
        {
            draft.Saved -= ApplySettings;
            onboardingWindow = null;
            if (!closeRequested) { Activate(); QuestionInput.Focus(); ShowOperationGuide(false); }
        }
    }
}
