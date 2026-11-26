using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.Platform.Tests;

public sealed class OverlayTests
{
    [Theory]
    [InlineData(0, 0, 1920, 1080)] [InlineData(-1920, -600, 1920, 1080)] [InlineData(1920, 300, 2560, 1440)]
    public void CoordinatesRoundTripAcrossNegativeAndOffsetMonitors(double x, double y, double width, double height)
    {
        var rect = new LayoutRect(x, y, width, height);
        var core = OverlayCoordinates.ToCore(rect);
        Assert.Equal(-y, core.MaxY); Assert.Equal(-y - height, core.Y);
        Assert.Equal(rect, OverlayCoordinates.FromCore(core));
        Assert.Equal(new(x, -y), OverlayCoordinates.ToCore(new LayoutPoint(x, y)));
    }
    [Theory] [InlineData(1)] [InlineData(1.25)] [InlineData(1.5)] [InlineData(2)]
    public void DpiConversionUsesCommonUnitsForFrameAndWorkArea(double scale)
    {
        var pixels = new LayoutRect(-2560, -200, 2560, 1400);
        var dips = OverlayCoordinates.ToDips(pixels, scale);
        Assert.Equal(pixels, OverlayCoordinates.ToPixels(dips, scale));
        var shell = new OverlayController(OverlayCoordinates.ToCore(dips));
        var positioned = OverlayCoordinates.ToPixels(OverlayCoordinates.FromCore(shell.Frame), scale);
        Assert.Equal(24 * scale, pixels.MaxX - positioned.MaxX, 6);
        Assert.Equal(24 * scale, positioned.Y - pixels.Y, 6);
    }
    [Fact] public void DefaultTopRightUsesTwentyFourDipMarginAndCoreFitting()
    {
        var work = new LayoutRect(-1920, -1080, 1920, 1040); var shell = new OverlayController(work);
        Assert.Equal(work.MaxX - 24, shell.Frame.MaxX); Assert.Equal(work.MaxY - 24, shell.Frame.MaxY);
        Assert.Equal(480, shell.Frame.Width); Assert.Equal(280, shell.Frame.Height);
        shell.ContentHeightChanged(500);
        Assert.Equal(work.MaxY - 24, shell.Frame.MaxY); Assert.Equal(500, shell.Frame.Height);
    }
    [Fact] public void AutoHeightPreferenceBoundsAndCoreNineHundredCapAreHonored()
    {
        var shell = new OverlayController(new(0, 0, 2000, 1600));
        shell.ContentHeightChanged(2000); Assert.Equal(900, shell.Frame.Height);
        shell.Configure(new() { OverlayAutoHeight = false });
        shell.ContentHeightChanged(260); Assert.Equal(900, shell.Frame.Height);
        shell.Configure(new() { OverlayAutoHeight = true }); Assert.Equal(260, shell.Frame.Height);
        shell.ContentHeightChanged(10); Assert.Equal(240, shell.Frame.Height);
        shell.ContentHeightChanged(double.NaN); Assert.Equal(240, shell.Frame.Height);
        shell.SetFrame(shell.Frame with { Width = 2000 }); Assert.Equal(700, shell.Frame.Width);
        shell.SetFrame(shell.Frame with { Width = 100 }); Assert.Equal(400, shell.Frame.Width);
    }
    [Fact] public void EdgeHideUsesCoreTimingAndInteractionResetsTimers()
    {
        var screen = new LayoutRect(0, -1080, 1920, 1080); var visible = screen with { Height = 1040 };
        var shell = new OverlayController(visible);
        shell.Configure(new() { OverlayEdgeHide = true }); Assert.True(shell.Hidden); Assert.False(shell.Movable);
        var edge = new LayoutPoint(1919, -400);
        shell.UpdatePointer(edge, screen, visible, 0, false); Assert.True(shell.Hidden);
        shell.UpdatePointer(edge, screen, visible, .15, false); Assert.True(shell.Hidden);
        shell.UpdatePointer(edge, screen, visible, .17, false); Assert.False(shell.Hidden);
        var outside = new LayoutPoint(500, -500);
        shell.UpdatePointer(outside, screen, visible, 1, false);
        shell.UpdatePointer(outside, screen, visible, 1.89, false); Assert.False(shell.Hidden);
        shell.UpdatePointer(outside, screen, visible, 1.95, true); Assert.False(shell.Hidden);
        shell.UpdatePointer(outside, screen, visible, 2, false);
        shell.UpdatePointer(outside, screen, visible, 2.91, false); Assert.True(shell.Hidden);
        shell.Configure(new() { OverlayEdgeHide = false }); Assert.False(shell.Hidden); Assert.True(shell.Movable);
    }
    [Fact] public void PointerLeavingEdgeResetsRevealAndHiddenContentCanGrow()
    {
        var screen = new LayoutRect(-1920, -1080, 1920, 1080); var shell = new OverlayController(screen);
        shell.Configure(new() { OverlayEdgeHide = true }); shell.ContentHeightChanged(600); Assert.True(shell.Hidden);
        shell.UpdatePointer(new(-1, -500), screen, screen, 0, false);
        shell.UpdatePointer(new(-200, -500), screen, screen, .1, false);
        shell.UpdatePointer(new(-1, -500), screen, screen, .2, false); Assert.True(shell.Hidden);
        shell.UpdatePointer(new(-1, -500), screen, screen, .37, false); Assert.False(shell.Hidden);
        Assert.Equal(600, shell.Frame.Height);
    }
    [Fact] public void EdgeRevealCanMoveToAnotherMonitorAndFitWithinWorkArea()
    {
        var shell = new OverlayController(new(0, -1080, 1920, 1040)); shell.Configure(new() { OverlayEdgeHide = true });
        var other = new LayoutRect(-1920, -800, 1920, 800); var edge = new LayoutPoint(-1, -400);
        shell.UpdatePointer(edge, other, other, 0, false); shell.UpdatePointer(edge, other, other, .2, false);
        Assert.False(shell.Hidden); Assert.Equal(other, shell.WorkArea);
        Assert.Equal(-12, shell.Frame.MaxX); Assert.True(shell.Frame.Y >= other.Y + 12);
    }
    [Fact] public void CaptureAffinityIsOptInAndWaitsForHandle()
    {
        var api = new FakeAffinity(); var protection = new WindowCaptureProtection(api);
        Assert.False(new AppSettings().ExcludeOverlayFromCapture);
        Assert.Null(protection.Apply(0, true).ReturnValue); Assert.Empty(api.Requests);
        Assert.True(protection.Apply(10, false).ReturnValue);
        protection.Apply(10, true); protection.Apply(20, true); protection.Apply(20, false);
        Assert.Equal(new (nint, uint)[] { (10, 0), (10, 0x11), (20, 0x11), (20, 0) }, api.Requests);
        Assert.Equal(new CaptureProtectionStatus(20, 0, true, 0), protection.Status);
    }
    [Fact] public void AffinityFailureExposesActualReturnAndError()
    {
        var api = new FakeAffinity { Result = new(false, 87) }; var protection = new WindowCaptureProtection(api);
        Assert.Equal(new CaptureProtectionStatus(5, 0x11, false, 87), protection.Apply(5, true));
    }
}
internal sealed class FakeAffinity : IWindowDisplayAffinity
{
    public List<(nint, uint)> Requests { get; } = [];
    public DisplayAffinityResult Result { get; set; } = new(true, 0);
    public DisplayAffinityResult Apply(nint hwnd, uint affinity) { Requests.Add((hwnd, affinity)); return Result; }
}
