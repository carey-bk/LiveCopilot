namespace LiveCopilot.App;

public partial class SettingsWindow
{
    partial void ShowOperationGuide()
    {
        if (!viewModel.Save() || Owner is not MainWindow main) return;
        Closed += (_, _) => Dispatcher.BeginInvoke(() => main.ShowOperationGuide(true));
        Close();
    }
}
