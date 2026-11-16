using LiveCopilot.Platform.Layout;

namespace LiveCopilot.Platform.Tests;

public sealed class DialogLayoutTests
{
    [Fact]
    public void CiWorkAreaFitsDefaultAndMinimumWithTwelveDipEdgeGap()
    {
        var fit = DialogLayout.Fit(new(-20, -50, 980, 680), new(0, 0, 1000, 696), 1, 860, 560);
        Assert.Equal(new LayoutRect(12, 12, 976, 672), fit.Bounds);
        Assert.Equal(860, fit.MinWidth);
        Assert.Equal(560, fit.MinHeight);
    }

    [Theory]
    [InlineData(0, 0, 1024, 728, 1)]
    [InlineData(-1280, -100, 1280, 984, 1.25)]
    [InlineData(1920, 48, 1500, 1044, 1.5)]
    [InlineData(-1920, -1080, 1920, 1040, 2)]
    [InlineData(0, 0, 640, 440, 1.5)]
    [InlineData(0, 0, 300, 240, 1)]
    [InlineData(-5, -5, 20, 18, 1)]
    public void OversizedDialogsAndMinimumsStayInsideEveryMonitor(double x, double y, double width, double height, double scale)
    {
        var work = new LayoutRect(x, y, width, height);
        var fit = DialogLayout.Fit(new(x - 600, y + height - 10, 1040 * scale, 840 * scale), work, scale, 940, 640);
        Assert.True(fit.Bounds.X >= work.X && fit.Bounds.Y >= work.Y);
        Assert.True(fit.Bounds.MaxX <= work.MaxX && fit.Bounds.MaxY <= work.MaxY);
        Assert.InRange(fit.MinWidth, 0, fit.MaxWidth);
        Assert.InRange(fit.MinHeight, 0, fit.MaxHeight);
        Assert.InRange(fit.Bounds.Width / scale, fit.MinWidth, fit.MaxWidth);
        Assert.InRange(fit.Bounds.Height / scale, fit.MinHeight, fit.MaxHeight);
    }

    [Fact]
    public void MovingFromSmallMonitorRestoresDesignMinimumWithoutMovingToPrimary()
    {
        var small = DialogLayout.Fit(new(20, 20, 980, 680), new(0, 0, 640, 480), 1, 860, 560);
        Assert.True(small.MinWidth < 860 && small.MinHeight < 560);
        var large = DialogLayout.Fit(small.Bounds with { X = -1800, Y = 80 }, new(-1920, 40, 1920, 1040), 1, 860, 560);
        Assert.Equal(860, large.MinWidth);
        Assert.Equal(560, large.MinHeight);
        Assert.Equal(-1800, large.Bounds.X);
        Assert.Equal(80, large.Bounds.Y);
        Assert.Equal(860, large.Bounds.Width);
        Assert.Equal(560, large.Bounds.Height);
    }

    [Fact]
    public void LargeWorkAreaPreservesUserSizeAndPosition()
    {
        var frame = new LayoutRect(2300, 200, 1100, 800);
        Assert.Equal(frame, DialogLayout.Fit(frame, new(1920, 0, 1920, 1080), 1, 860, 560).Bounds);
    }
}
