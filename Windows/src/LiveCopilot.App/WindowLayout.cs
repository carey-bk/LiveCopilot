using System.Windows;

namespace LiveCopilot.App;

internal static class WindowLayout
{
    // WorkArea is in DIPs, so small displays and scaled desktops keep the footer reachable.
    internal static void FitWorkArea(Window window)
    {
        var area = SystemParameters.WorkArea;
        window.MinHeight = Math.Min(window.MinHeight, Math.Max(320, area.Height - 24));
        window.MinWidth = Math.Min(window.MinWidth, Math.Max(480, area.Width - 24));
        window.Height = Math.Max(window.MinHeight, Math.Min(window.Height, area.Height - 24));
        window.Width = Math.Max(window.MinWidth, Math.Min(window.Width, area.Width - 24));
        window.Loaded += (_, _) =>
        {
            // CenterOwner can put a tall dialog above the desktop when the overlay is near an edge.
            window.Left = Math.Clamp(window.Left, area.Left + 12, Math.Max(area.Left + 12, area.Right - window.ActualWidth - 12));
            window.Top = Math.Clamp(window.Top, area.Top + 12, Math.Max(area.Top + 12, area.Bottom - window.ActualHeight - 12));
        };
    }
}
