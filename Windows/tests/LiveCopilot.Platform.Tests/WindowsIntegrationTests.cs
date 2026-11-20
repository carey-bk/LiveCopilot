#if WINDOWS
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Windows.Hotkeys;
using LiveCopilot.Platform.Windows.Overlay;
#endif

namespace LiveCopilot.Platform.Tests;

public sealed class WindowsDesktopFactAttribute : FactAttribute
{
    public WindowsDesktopFactAttribute()
    {
#if WINDOWS
        if (!OperatingSystem.IsWindows() || !Environment.UserInteractive || Environment.GetEnvironmentVariable("LIVECOPILOT_WINDOWS_INTEGRATION") != "1")
            Skip = "Requires an interactive Windows desktop and LIVECOPILOT_WINDOWS_INTEGRATION=1; CI cannot verify meeting focus/share behavior.";
#else
        Skip = "Requires Windows/WPF; net8.0 Linux runs injected platform tests only.";
#endif
    }
}

public sealed class WindowsIntegrationTests
{
    [WindowsDesktopFact]
    public void WindowCreationUsesNonActivatingStylesAndAffinityWrapper()
    {
#if WINDOWS
        Sta(() =>
        {
            var affinity = new FakeAffinity();
            var window = new OverlayWindow(new(), affinity);
            try
            {
                window.Show();
                var hwnd = new WindowInteropHelper(window).Handle;
                Assert.NotEqual(0, hwnd); Assert.True(window.Topmost); Assert.False(window.ShowActivated);
                var style = IntPtr.Size == 8 ? (long)GetWindowLongPtr(hwnd, -20) : GetWindowLong(hwnd, -20);
                Assert.NotEqual(0, style & 0x08000000); Assert.NotEqual(0, style & 0x80);
                Assert.Contains((hwnd, 0u), affinity.Requests);
                window.Configure(new() { ExcludeOverlayFromCapture = true }); Assert.Contains((hwnd, 0x11u), affinity.Requests);
                window.ToggleVisibility(); window.ToggleVisibility();
            }
            finally { window.Close(); }
        });
#else
        Assert.Fail("Windows-only test must be skipped by the attribute.");
#endif
    }
    [WindowsDesktopFact]
    public void RealGlobalHotkeyCanBeRegisteredAndReleased()
    {
#if WINDOWS
        Sta(() =>
        {
            using var registrar = new Win32HotkeyRegistrar();
            var combo = new HotkeyCombo(0x87, HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift); // F24
            var result = registrar.Register(1, combo, true);
            Assert.True(result.Success, $"Interactive shortcut probe unavailable (Win32 {result.ErrorCode}); close conflicting utilities or unset LIVECOPILOT_WINDOWS_INTEGRATION for headless CI.");
            registrar.Unregister(1);
            Assert.True(registrar.Register(2, combo, true).Success);
        });
#else
        Assert.Fail("Windows-only test must be skipped by the attribute.");
#endif
    }
#if WINDOWS
    private static void Sta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { action(); } catch (Exception e) { failure = e; } });
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(10)), "Window test did not complete within 10 seconds.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(nint hwnd, int index);
#endif
}
