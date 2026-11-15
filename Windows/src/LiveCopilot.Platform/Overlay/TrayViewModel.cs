using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Overlay;

public sealed class TrayViewModel : ObservableObject
{
    private bool visible = true, closing;
    public TrayViewModel(Action<bool> show, Action settings, Action exit)
    {
        ToggleCommand = new(() => { SetVisible(!visible); show(visible); }, () => !closing);
        SettingsCommand = new(settings, () => !closing);
        ExitCommand = new(() => { BeginShutdown(); exit(); }, () => !closing);
    }
    public string ToggleLabel => visible ? "隐藏悬浮窗" : "显示悬浮窗";
    public RelayCommand ToggleCommand { get; }
    public RelayCommand SettingsCommand { get; }
    public RelayCommand ExitCommand { get; }
    public void SetVisible(bool value) { visible = value; Notify(nameof(ToggleLabel)); }
    public void BeginShutdown() { closing = true; ToggleCommand.Refresh(); SettingsCommand.Refresh(); ExitCommand.Refresh(); }
}
