using LiveCopilot.Core;

namespace LiveCopilot.Platform.Layout;

public readonly record struct DialogPlacement(LayoutRect Bounds, double MinWidth, double MinHeight, double MaxWidth, double MaxHeight);

public static class DialogLayout
{
    // Rectangles are physical desktop pixels (including negative monitor origins).
    // WPF constraints and the edge gap are DIPs; never scale desktop origins as DIPs.
    public static DialogPlacement Fit(LayoutRect frame, LayoutRect workArea, double dpiScale,
        double minimumWidth, double minimumHeight)
    {
        var gapX = Math.Min(12 * dpiScale, Math.Max(0, (workArea.Width - 1) / 2));
        var gapY = Math.Min(12 * dpiScale, Math.Max(0, (workArea.Height - 1) / 2));
        var available = workArea.Inset(gapX, gapY);
        var maxWidth = available.Width / dpiScale;
        var maxHeight = available.Height / dpiScale;
        var minWidth = Math.Min(minimumWidth, maxWidth);
        var minHeight = Math.Min(minimumHeight, maxHeight);
        var width = Math.Clamp(frame.Width, minWidth * dpiScale, available.Width);
        var height = Math.Clamp(frame.Height, minHeight * dpiScale, available.Height);
        var bounds = new LayoutRect(Math.Clamp(frame.X, available.X, available.MaxX - width),
            Math.Clamp(frame.Y, available.Y, available.MaxY - height), width, height);
        return new(bounds, minWidth, minHeight, maxWidth, maxHeight);
    }
}
