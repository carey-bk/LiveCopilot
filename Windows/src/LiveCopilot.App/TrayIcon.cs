using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.App;

/// Shell notification icon; no WinForms or third-party UI dependency. Re-add after Explorer restarts.
internal sealed class TrayIcon : IDisposable
{
    private const int Callback = 0x8001;
    private readonly HwndSource source;
    private readonly TrayViewModel model;
    private readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private NotifyData data;
    private bool disposed;
    private nint ownedIcon;
    public TrayIcon(Window owner, TrayViewModel model)
    {
        this.model = model;
        var hwnd = new WindowInteropHelper(owner).Handle;
        source = HwndSource.FromHwnd(hwnd);
        using (var iconStream = Application.GetResourceStream(new Uri("Resources/AppIcon.png", UriKind.Relative))?.Stream)
        {
            if (iconStream is not null)
            {
                using var bytes = new System.IO.MemoryStream(); iconStream.CopyTo(bytes);
                ownedIcon = CreateIconFromResourceEx(bytes.ToArray(), (uint)bytes.Length, true, 0x00030000, 32, 32, 0);
            }
        }
        data = new() { Size = Marshal.SizeOf<NotifyData>(), Window = hwnd, Id = 1, Flags = 7,
            CallbackMessage = Callback, Icon = ownedIcon != 0 ? ownedIcon : LoadIcon(0, 32512), Tip = "LiveCopilot", Info = "", InfoTitle = "" };
        source.AddHook(Message);
        if (!ShellNotifyIcon(0, ref data)) { Dispose(); throw new InvalidOperationException("无法创建系统托盘图标。"); }
    }
    private nint Message(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (disposed) return 0;
        if ((uint)message == taskbarCreated) _ = ShellNotifyIcon(0, ref data);
        if (message != Callback) return 0;
        if ((int)lParam == 0x0203) model.ToggleCommand.Execute(null);
        if ((int)lParam is 0x0205 or 0x007B)
        {
            _ = SetForegroundWindow(hwnd);
            var menu = new ContextMenu();
            menu.Items.Add(new MenuItem { Header = model.ToggleLabel, Command = model.ToggleCommand });
            menu.Items.Add(new MenuItem { Header = "设置", Command = model.SettingsCommand });
            menu.Items.Add(new Separator());
            menu.Items.Add(new MenuItem { Header = "退出 LiveCopilot", Command = model.ExitCommand });
            menu.Closed += (_, _) => PostMessage(hwnd, 0, 0, 0);
            menu.IsOpen = true;
        }
        handled = true;
        return 0;
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; _ = ShellNotifyIcon(2, ref data); source.RemoveHook(Message);
        if (ownedIcon != 0) { _ = DestroyIcon(ownedIcon); ownedIcon = 0; }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyData
    {
        public int Size; public nint Window; public uint Id, Flags; public int CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [DllImport("user32.dll")] private static extern nint CreateIconFromResourceEx(byte[] bits, uint size, [MarshalAs(UnmanagedType.Bool)] bool icon, uint version, int width, int height, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShellNotifyIcon(uint message, ref NotifyData data);
    [DllImport("user32.dll", EntryPoint = "LoadIconW")] private static extern nint LoadIcon(nint instance, int name);
    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);
}
