using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using LiveCopilot.Platform.Hotkeys;

namespace LiveCopilot.Platform.Windows.Hotkeys;

/// Construct/dispose on a running WPF Dispatcher thread. WM_HOTKEY callbacks run there.
public sealed class Win32HotkeyRegistrar : IHotkeyRegistrar
{
    private readonly HwndSource window;
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly HashSet<int> registrations = [];
    private bool disposed;
    public event Action<int>? Pressed;

    public Win32HotkeyRegistrar()
    {
        window = new HwndSource(new HwndSourceParameters("LiveCopilot global shortcuts")
        { ParentWindow = new nint(-3), WindowStyle = 0, Width = 0, Height = 0 }); // HWND_MESSAGE
        window.AddHook(Message);
    }
    public HotkeyRegistration Register(int id, HotkeyCombo combo, bool noRepeat)
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!combo.IsValid) return new(false, 87);
        var success = RegisterHotKey(window.Handle, id, (uint)combo.Modifiers | (noRepeat ? 0x4000u : 0), combo.KeyCode);
        if (success) registrations.Add(id);
        return new(success, success ? 0 : Marshal.GetLastWin32Error());
    }
    public void Unregister(int id)
    {
        dispatcher.VerifyAccess();
        if (registrations.Remove(id)) UnregisterHotKey(window.Handle, id);
    }
    private nint Message(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x0312 && registrations.Contains((int)wParam))
        { handled = true; Pressed?.Invoke((int)wParam); }
        return 0;
    }
    public void Dispose()
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        foreach (var id in registrations.ToArray()) Unregister(id);
        disposed = true;
        window.RemoveHook(Message);
        window.Dispose();
    }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint hwnd, int id);
}
