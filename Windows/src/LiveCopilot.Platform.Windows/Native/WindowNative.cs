using System.ComponentModel;
using System.Runtime.InteropServices;
using LiveCopilot.Core;
using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.Platform.Windows.Native;

internal static class WindowNative
{
    internal const int MouseActivate = 0x21, NoActivate = 3;
    internal const long NoActivateStyle = 0x08000000, ToolWindowStyle = 0x80;
    [StructLayout(LayoutKind.Sequential)] internal struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect
    {
        public int Left, Top, Right, Bottom;
        public readonly LayoutRect Layout => new(Left, Top, Right - Left, Bottom - Top);
    }
    [StructLayout(LayoutKind.Sequential)] internal struct MonitorInfo
    {
        public int Size;
        public Rect Monitor, Work;
        public uint Flags;
    }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern nint MonitorFromWindow(nint hwnd, uint flags);
    [DllImport("user32.dll")] internal static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetWindowRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetLong64(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetLong32(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)] private static extern nint SetLong64(nint hwnd, int index, nint value);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)] private static extern int SetLong32(nint hwnd, int index, int value);
    internal static void MakeNonActivatingToolWindow(nint hwnd)
    {
        var style = IntPtr.Size == 8 ? (long)GetLong64(hwnd, -20) : GetLong32(hwnd, -20);
        style |= NoActivateStyle | ToolWindowStyle;
        Marshal.SetLastPInvokeError(0);
        var previous = IntPtr.Size == 8 ? SetLong64(hwnd, -20, (nint)style) : SetLong32(hwnd, -20, (int)style);
        if (previous == 0 && Marshal.GetLastWin32Error() != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    internal static MonitorInfo Monitor(nint handle)
    {
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(handle, ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return info;
    }
}

public sealed class Win32WindowDisplayAffinity : IWindowDisplayAffinity
{
    public DisplayAffinityResult Apply(nint hwnd, uint affinity)
    {
        var result = SetWindowDisplayAffinity(hwnd, affinity);
        return new(result, result ? 0 : Marshal.GetLastWin32Error());
    }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
}
