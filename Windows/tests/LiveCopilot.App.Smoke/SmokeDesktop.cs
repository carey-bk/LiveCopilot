#if WINDOWS
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;

namespace LiveCopilot.App.Smoke;

internal static class SmokeDesktop
{
    internal static AutomationElement? FindWindow(int pid, string id)
    {
        var condition = new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty, pid),
            new PropertyCondition(AutomationElement.AutomationIdProperty, id),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        // Owned WPF dialogs can sit below their owner in the UIA tree instead of
        // being direct desktop children. Do not walk every process's descendants.
        var desktopMatch = Probe(() => AutomationElement.RootElement.FindFirst(TreeScope.Children, condition));
        if (desktopMatch is not null)
        {
            Console.WriteLine($"Found {id} as a desktop UIA child.");
            return desktopMatch;
        }
        foreach (var hwnd in TopLevelWindows(pid))
        {
            var match = Probe(() =>
            {
                var window = AutomationElement.FromHandle(hwnd);
                return window.FindFirst(TreeScope.Element | TreeScope.Descendants, condition);
            });
            if (match is not null)
            {
                Console.WriteLine($"Found {id} via process HWND 0x{hwnd.ToInt64():X} (including owned windows).");
                return match;
            }
        }
        return null;
    }

    private static AutomationElement? Probe(Func<AutomationElement?> find)
    {
        try { return find(); }
        catch (ElementNotAvailableException) { return null; }
        catch (COMException) { return null; } // HWND/provider can disappear between enumeration and lookup.
    }

    private static List<IntPtr> TopLevelWindows(int pid)
    {
        var windows = new List<IntPtr>();
        if (!EnumWindows((hwnd, parameter) =>
        {
            _ = GetWindowThreadProcessId(hwnd, out var windowPid);
            if (windowPid == (uint)pid) windows.Add(hwnd); // Includes owned, modal and hidden top-level HWNDs.
            return true;
        }, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return windows;
    }

    internal static bool TryClick(AutomationElement main, AutomationElement button)
    {
        if (!main.Current.IsEnabled || !button.Current.IsEnabled || button.Current.IsOffscreen)
            return false;
        var hwnd = new IntPtr(main.Current.NativeWindowHandle);
        _ = SetForegroundWindow(hwnd);
        if (GetForegroundWindow() != hwnd)
            return false; // Foreground activation can be asynchronous; the caller keeps polling.
        if (!button.TryGetClickablePoint(out var point))
            return false;
        if (!main.Current.IsEnabled || !button.Current.IsEnabled) return false;
        if (!SetCursorPos((int)Math.Round(point.X), (int)Math.Round(point.Y)))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        Input[] clicks =
        [
            new() { Data = new InputData { Mouse = new MouseInput { Flags = 0x0002 } } }, // MOUSEEVENTF_LEFTDOWN
            new() { Data = new InputData { Mouse = new MouseInput { Flags = 0x0004 } } }  // MOUSEEVENTF_LEFTUP
        ];
        if (SendInput((uint)clicks.Length, clicks, Marshal.SizeOf<Input>()) != (uint)clicks.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        Console.WriteLine("Settings: sent physical mouse click after Invoke did not open a window.");
        return true;
    }

    internal static void CaptureDesktop(string file) => ScreenCapture.Desktop(file);

    internal static void Diagnose(int? pid, string output)
    {
        // Save the screen before any potentially blocked UIA calls or process cleanup.
        TryDiagnostic(() => CaptureDesktop(Path.Combine(output, "failure-desktop.png")));
        if (pid is null) return;
        TryDiagnostic(() =>
        {
            using var log = new StreamWriter(Path.Combine(output, "windows.jsonl")) { AutoFlush = true };
            foreach (var hwnd in TopLevelWindows(pid.Value))
            {
                // Flush native facts first so the watchdog cannot erase evidence of a hung UIA provider.
                log.WriteLine(JsonSerializer.Serialize(new
                {
                    pid, hwnd = $"0x{hwnd.ToInt64():X}", owner = $"0x{GetWindow(hwnd, 4).ToInt64():X}",
                    visible = IsWindowVisible(hwnd), enabled = IsWindowEnabled(hwnd)
                }));
                try
                {
                    var info = AutomationElement.FromHandle(hwnd).Current;
                    log.WriteLine(JsonSerializer.Serialize(new
                    {
                        hwnd = $"0x{hwnd.ToInt64():X}", info.AutomationId, info.Name,
                        controlType = info.ControlType.ProgrammaticName, info.IsEnabled, info.IsOffscreen
                    }));
                }
                catch (Exception error) { log.WriteLine($"UIA unavailable: {error.GetType().FullName}"); }
            }
        });

        void TryDiagnostic(Action action)
        {
            try { action(); }
            catch (Exception error) { Console.Error.WriteLine($"Failure diagnostics: {error}"); }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputData { [FieldOffset(0)] public MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput { public int X, Y; public uint MouseData, Flags, Time; public UIntPtr ExtraInfo; }
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
#endif
