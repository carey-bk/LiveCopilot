namespace LiveCopilot.Core;

public static class AppRuntime
{
    public static bool IsSmoke => Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE") == "1";
    internal static readonly string SmokeDataDirectory = Path.Combine(Path.GetTempPath(), "LiveCopilot-smoke-" + Guid.NewGuid().ToString("N"));

    public static void RequireInteractive(string operation)
    {
        if (IsSmoke) throw new CopilotException("冒烟模式禁止" + operation + "。");
    }
}
