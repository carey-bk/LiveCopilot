using LiveCopilot.Core;

namespace LiveCopilot.Platform.Overlay;

/// Small display contract; the host supplies status and marshals updates to the UI thread.
public sealed record OverlayContent(string Status, ValueList<TranscriptLine> Lines,
    string PartialThem = "", string PartialYou = "", string? SuggestionStatus = null);

/// Coordinates must all use the same units. Negating Y about screen zero supports
/// negative-origin monitors; no primary-display height assumption is needed.
public static class OverlayCoordinates
{
    public static LayoutRect ToCore(LayoutRect topLeft) => new(topLeft.X, -topLeft.Y - topLeft.Height, topLeft.Width, topLeft.Height);
    public static LayoutRect FromCore(LayoutRect bottomLeft) => ToCore(bottomLeft);
    public static LayoutPoint ToCore(LayoutPoint topLeft) => new(topLeft.X, -topLeft.Y);
    public static LayoutRect ToDips(LayoutRect pixels, double scale) => new(pixels.X / scale, pixels.Y / scale, pixels.Width / scale, pixels.Height / scale);
    public static LayoutRect ToPixels(LayoutRect dips, double scale) => new(dips.X * scale, dips.Y * scale, dips.Width * scale, dips.Height * scale);
}

/// UI-thread shell state; uses existing Core geometry and hover timing unchanged.
public sealed class OverlayController
{
    private readonly OverlayHoverState hover = new();
    private double desiredHeight = 280;
    public bool AutoHeight { get; private set; } = true;
    public bool EdgeHide { get; private set; }
    public bool Hidden { get; private set; }
    public bool Movable => !EdgeHide;
    public LayoutRect Frame { get; private set; }
    public LayoutRect WorkArea { get; private set; }

    public OverlayController(LayoutRect workArea)
    {
        WorkArea = workArea;
        Frame = new(workArea.MaxX - 480 - 24, workArea.MaxY - 280 - 24, 480, 280);
        Fit();
    }
    public void Configure(AppSettings settings)
    {
        AutoHeight = settings.OverlayAutoHeight;
        if (EdgeHide != settings.OverlayEdgeHide)
        { EdgeHide = settings.OverlayEdgeHide; Hidden = EdgeHide; hover.Reset(); }
        Fit();
    }
    public void SetWorkArea(LayoutRect workArea) { WorkArea = workArea; Fit(); }
    public void ContentHeightChanged(double height)
    {
        if (!double.IsFinite(height) || height <= 0) return;
        desiredHeight = height;
        if (AutoHeight) Fit();
    }
    public void SetFrame(LayoutRect frame) { Frame = frame; Fit(); }
    public void Interaction() => hover.Reset();
    public void Reveal() { Hidden = false; hover.Reset(); Fit(); }
    public void Hide() { Hidden = true; hover.Reset(); }
    public void Toggle() { if (Hidden) Reveal(); else Hide(); }
    public void UpdatePointer(LayoutPoint point, LayoutRect screen, LayoutRect visible, double now, bool interacting)
    {
        if (!EdgeHide) return;
        if (interacting) { hover.Reset(); return; }
        if (Hidden)
        {
            if (hover.ShouldReveal(OverlayLayout.AtRightEdge(point, screen, visible), now))
            { WorkArea = visible; Reveal(); }
        }
        else
        {
            var region = Frame.Inset(-12, -12);
            var inside = point.X >= region.X && point.X <= region.MaxX && point.Y >= region.Y && point.Y <= region.MaxY;
            if (hover.ShouldHide(inside, false, now)) Hide();
        }
    }
    private void Fit()
    {
        Frame = OverlayLayout.Fitted(Frame with { Width = Math.Clamp(Frame.Width, 400, 700) },
            Math.Clamp(AutoHeight ? desiredHeight : Frame.Height, 240, 1000), WorkArea, EdgeHide);
    }
}
