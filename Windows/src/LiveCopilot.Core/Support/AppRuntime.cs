namespace LiveCopilot.Core;

public static class AppRuntime
{
    public static bool IsSmoke => Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE") == "1";
    private static readonly Guid SmokeRunId = Guid.NewGuid();
    // Only a GUID can be supplied by the smoke harness; never accept a path to user data.
    internal static string SmokeDataDirectory => Path.Combine(Path.GetTempPath(), "LiveCopilot-smoke-" +
        (Guid.TryParseExact(Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE_DATA_ID"), "N", out var id) ? id : SmokeRunId).ToString("N"));

    public static void RequireInteractive(string operation)
    {
        if (IsSmoke) throw new CopilotException("冒烟模式禁止" + operation + "。");
    }
}
