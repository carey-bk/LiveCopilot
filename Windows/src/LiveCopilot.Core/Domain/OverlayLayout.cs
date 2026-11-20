namespace LiveCopilot.Core;

// Pure geometry retains Swift's bottom-left coordinate convention. No window API is used.
public readonly record struct LayoutPoint(double X, double Y);
public readonly record struct LayoutRect(double X, double Y, double Width, double Height)
{
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public LayoutRect Inset(double dx, double dy) => new(X + dx, Y + dy, Width - 2 * dx, Height - 2 * dy);
}
public static class OverlayLayout
{
    public static (double Transcript, double Answer) Panes(double available, double transcriptIdeal, double answerIdeal, bool automatic)
    {
        var room = Math.Max(0, available);
        var transcript = Math.Min(transcriptIdeal, Math.Max(0, room - 28));
        var answer = automatic ? Math.Min(Math.Max(28, answerIdeal), Math.Max(0, room - transcript)) : Math.Max(0, room - transcript);
        return (transcript, answer);
    }
    public static LayoutRect Fitted(LayoutRect frame, double height, LayoutRect visible, bool docked, double minimumHeight = 240)
    {
        var inset = visible.Inset(12, 12);
        var width = Math.Min(frame.Width, inset.Width);
        var minimum = Math.Min(Math.Max(240, minimumHeight), inset.Height);
        var top = Math.Min(Math.Max(frame.MaxY, inset.Y + minimum), inset.MaxY);
        height = Math.Min(Math.Min(Math.Max(minimum, height), top - inset.Y), 900);
        var x = docked ? inset.MaxX - width : Math.Min(Math.Max(frame.X, inset.X), inset.MaxX - width);
        return new(x, top - height, width, height);
    }
    public static bool AtRightEdge(LayoutPoint point, LayoutRect screen, LayoutRect visible) =>
        point.X >= screen.MaxX - 3 && point.X <= screen.MaxX && point.Y >= visible.Y + 12 && point.Y <= visible.MaxY - 12;
}
public sealed class OverlayHoverState
{
    private double? edgeSince, outsideSince;
    public void Reset() { edgeSince = null; outsideSince = null; }
    public bool ShouldReveal(bool atEdge, double now)
    { if (!atEdge) { edgeSince = null; return false; } edgeSince ??= now; return now - edgeSince.Value >= 0.16; }
    public bool ShouldHide(bool inside, bool interacting, double now)
    { if (inside || interacting) { outsideSince = null; return false; } outsideSince ??= now; return now - outsideSince.Value >= 0.9; }
}
