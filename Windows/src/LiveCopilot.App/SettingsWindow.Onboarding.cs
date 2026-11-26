namespace LiveCopilot.App;

public partial class SettingsWindow
{
    private MainWindow? onboardingOwner;
    partial void InitializeOnboarding()
    {
        Closed += (_, _) =>
        {
            if (onboardingOwner is { } main) Dispatcher.BeginInvoke(() => main.ShowOnboarding(true));
        };
    }
    partial void ShowOnboarding()
    {
        // Commit the draft before leaving settings; no stale settings window can overwrite the guide.
        if (!viewModel.Save()) return;
        onboardingOwner = Owner as MainWindow;
        Close();
    }
}
