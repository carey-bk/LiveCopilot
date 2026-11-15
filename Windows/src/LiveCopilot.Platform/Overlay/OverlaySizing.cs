namespace LiveCopilot.Platform.Overlay;

public static class OverlaySizing
{
    public static double Height(double chrome, double answer, double minimum, double workAreaHeight) =>
        Math.Clamp(chrome + Math.Max(56, answer), Math.Min(minimum, workAreaHeight), workAreaHeight);
}
