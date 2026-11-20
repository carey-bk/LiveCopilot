namespace LiveCopilot.Platform.Overlay;

public readonly record struct DisplayAffinityResult(bool ReturnValue, int ErrorCode);
public interface IWindowDisplayAffinity
{
    DisplayAffinityResult Apply(nint hwnd, uint affinity);
}
public readonly record struct CaptureProtectionStatus(nint Window, uint RequestedAffinity, bool? ReturnValue, int ErrorCode);

/// An API success records a request, never proof of invisibility in a meeting client.
public sealed class WindowCaptureProtection(IWindowDisplayAffinity api)
{
    public const uint None = 0, ExcludeFromCapture = 0x11;
    public CaptureProtectionStatus Status { get; private set; }
    public CaptureProtectionStatus Apply(nint hwnd, bool exclude)
    {
        var flag = exclude ? ExcludeFromCapture : None;
        if (hwnd == 0) return Status = new(hwnd, flag, null, 0);
        var result = api.Apply(hwnd, flag);
        return Status = new(hwnd, flag, result.ReturnValue, result.ErrorCode);
    }
}
