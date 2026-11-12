using LiveCopilot.Core;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Windows.Hotkeys;
using LiveCopilot.Platform.Windows.Overlay;

namespace LiveCopilot.App;
public partial class MainWindow : System.Windows.Window
{
    private OverlayWindow? overlay;
    private HotkeyManager? hotkeys;
    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var preferences = new FilePreferenceStore();
            var settings = AppSettings.Load(preferences);
            overlay = new OverlayWindow(settings);
            overlay.Show();
            hotkeys = new HotkeyManager(new HotkeyStore(preferences), new Win32HotkeyRegistrar(),
                mode => Title = $"LiveCopilot — {mode} (shell only)", overlay.ToggleVisibility,
                error => Title = error);
            hotkeys.SetEnabledModes(settings.EnabledSuggestionModes);
        };
        Closed += (_, _) => { hotkeys?.Dispose(); overlay?.Close(); };
    }
}
