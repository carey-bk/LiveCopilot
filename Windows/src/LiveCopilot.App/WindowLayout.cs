using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.Platform.Layout;

namespace LiveCopilot.App;

internal static class WindowLayout
{
    internal static void FitWorkArea(Window window)
    {
        // Keep the design minimums so moving back to a larger display restores them.
        var minimumWidth = window.MinWidth;
        var minimumHeight = window.MinHeight;
        HwndSource? source = null;
        var queued = false;
        var closed = false;
        window.SourceInitialized += (_, _) =>
        {
            source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
            source?.AddHook(WindowMessage);
            Fit(position: false);
        };
        // CenterOwner runs during window creation; clamp position after it has finished.
        window.Loaded += (_, _) => Fit(position: true);
        window.Closed += (_, _) => { closed = true; source?.RemoveHook(WindowMessage); };

        nint WindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
        {
            // Let WPF handle DPI changes first, then read the resulting HWND/DPI/monitor.
            // Refit after dragging, display changes, and taskbar/work-area changes too.
            if (message is 0x02E0 or 0x0232 or 0x007E or 0x001A && !queued && !closed)
            {
                queued = true;
                window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
                {
                    queued = false;
                    if (!closed) Fit(position: true);
                });
            }
            return 0;
        }

        void Fit(bool position)
        {
            if (source is null || window.WindowState != WindowState.Normal) return;
            var hwnd = source.Handle;
            var monitorWindow = !position && window.Owner is { } owner ? new WindowInteropHelper(owner).Handle : hwnd;
            var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(MonitorFromWindow(monitorWindow, 2), ref monitor) || !GetWindowRect(hwnd, out var frame)) return;
            var dpi = GetDpiForWindow(monitorWindow);
            var scale = dpi == 0 ? 1 : dpi / 96d;
            var desired = new LayoutRect(frame.Left, frame.Top, window.Width * scale, window.Height * scale);
            var fit = DialogLayout.Fit(desired, monitor.Work.Layout, scale, minimumWidth, minimumHeight);
            // Relax old constraints before applying a potentially smaller monitor's limits.
            window.MinWidth = 0;
            window.MinHeight = 0;
            window.MaxWidth = fit.MaxWidth;
            window.MaxHeight = fit.MaxHeight;
            window.MinWidth = fit.MinWidth;
            window.MinHeight = fit.MinHeight;
            window.Width = fit.Bounds.Width / scale;
            window.Height = fit.Bounds.Height / scale;
            if (position)
            {
                // Native placement keeps negative/mixed-DPI desktop coordinates intact.
                // Floor sizes and ceil origins so rounding never puts an edge outside rcWork.
                _ = SetWindowPos(hwnd, 0, (int)Math.Ceiling(fit.Bounds.X), (int)Math.Ceiling(fit.Bounds.Y),
                    (int)Math.Floor(fit.Bounds.Width), (int)Math.Floor(fit.Bounds.Height), 0x0014); // NOZORDER | NOACTIVATE
                SmokeDiagnostics.Event($"dialog fitted: {window.GetType().Name}; work={monitor.Work.Layout}; bounds={fit.Bounds}; dpi={dpi}");
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        public readonly LayoutRect Layout => new(Left, Top, Right - Left, Bottom - Top);
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint hwnd, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int width, int height, uint flags);
}
