using System;
#if WINDOWS
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
#endif

namespace LiveCopilot.App.Smoke;

internal static class Program
{
    [MTAThread]
    private static int Main(string[] args)
    {
#if WINDOWS
        if (args.Length != 2) { Console.Error.WriteLine("Usage: Smoke <published-app.exe> <screenshots-directory>"); return 2; }
        _ = SetProcessDpiAwarenessContext(new IntPtr(-4)); // Match physical pixel coordinates on scaled desktops.
        var output = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(output);
        using var appStdout = new StreamWriter(Path.Combine(output, "app-stdout.log")) { AutoFlush = true };
        using var appStderr = new StreamWriter(Path.Combine(output, "app-stderr.log")) { AutoFlush = true };
        Process? app = null;
        Task<bool>? openSettings = null;
        try
        {
            var start = new ProcessStartInfo(Path.GetFullPath(args[0]))
            {
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
            };
            start.WorkingDirectory = Path.GetDirectoryName(start.FileName)!;
            start.Environment["LIVECOPILOT_SMOKE"] = "1";
            start.Environment["LIVECOPILOT_INFERENCE_CPU"] = "1";
            start.Environment["LIVECOPILOT_SMOKE_LOG_DIRECTORY"] = output;
            var watch = Stopwatch.StartNew();
            app = Process.Start(start) ?? throw new InvalidOperationException("App did not start.");
            app.OutputDataReceived += (_, data) => { if (data.Data is not null) appStdout.WriteLine(data.Data); };
            app.ErrorDataReceived += (_, data) => { if (data.Data is not null) appStderr.WriteLine(data.Data); };
            app.BeginOutputReadLine();
            app.BeginErrorReadLine();
            Console.WriteLine($"Started PID {app.Id}; waiting at most 30 seconds for the real main window.");
            var main = Wait(() => FindWindow(app.Id, "MainWindow"), app, TimeSpan.FromSeconds(30), "main window");
            Wait(() => main.Current.ItemStatus == "ready" ? main : null, app,
                TimeSpan.FromSeconds(30) - watch.Elapsed, "main window initialization");
            var startupMs = watch.ElapsedMilliseconds;
            if (startupMs > 30000) throw new TimeoutException("Main window was not ready within 30 seconds.");
            Wait(() => ReadySettingsButton(main), app, TimeSpan.FromSeconds(10), "settings button enabled and visible");
            Thread.Sleep(350);
            Capture(main, Path.Combine(output, "00-main.png"));
            // Invoke can stay blocked while WPF ShowDialog runs its nested dispatcher.
            var mainHwnd = new IntPtr(main.Current.NativeWindowHandle);
            openSettings = Task.Run(() => InvokeSettings(mainHwnd));
            var settings = WaitForSettings(main, app, openSettings);
            string[] pages = ["GeneralPage", "ServicesPage", "KnowledgePage", "HistoryPage", "ShortcutsPage", "AboutPage"];
            var actual = settings.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem))
                .Cast<AutomationElement>().Select(element => element.Current.AutomationId).ToArray();
            if (!actual.Order().SequenceEqual(pages.Order())) throw new InvalidOperationException("Settings pages changed; every page must have smoke coverage.");
            for (var i = 0; i < pages.Length; i++)
            {
                var tab = Find(settings, pages[i]);
                var selection = (SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern);
                selection.Select();
                Wait(() => selection.Current.IsSelected ? tab : null, app, TimeSpan.FromSeconds(5), pages[i]);
                Thread.Sleep(350); // Let WPF layout and the compositor finish after UIA selection.
                Capture(settings, Path.Combine(output, $"{i + 1:00}-{pages[i]}.png"));
                Console.WriteLine($"Selected and captured {pages[i]} ({tab.Current.Name}).");
            }
            ((InvokePattern)Find(settings, "CancelSettings").GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            if (!openSettings.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Settings did not close normally.");
            Wait(() => FindWindow(app.Id, "SettingsWindow") is null && main.Current.IsEnabled ? main : null,
                app, TimeSpan.FromSeconds(10), "settings closed");
            if (!PostMessage(new IntPtr(main.Current.NativeWindowHandle), 0x0010, IntPtr.Zero, IntPtr.Zero))
                throw new InvalidOperationException("Could not request normal window close.");
            if (!app.WaitForExit(15000)) throw new TimeoutException("App did not exit normally within 15 seconds.");
            app.WaitForExit(); // Drain redirected output callbacks before disposing the writers.
            if (app.ExitCode != 0) throw new InvalidOperationException($"App exited with code {app.ExitCode}.");
            if (Directory.GetFiles(output, "*.png").Length != 7) throw new InvalidOperationException("Expected seven screenshots.");
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new
            { success = true, startupMs, appExitCode = app.ExitCode, pages, screenshots = 7 }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"PASS: main ready in {startupMs} ms; all six settings pages captured; app exit code 0.");
            return 0;
        }
        catch (Exception error)
        {
            File.WriteAllText(Path.Combine(output, "failure.txt"), error.ToString());
            Console.Error.WriteLine(error);
            Console.Error.WriteLine($"Settings Invoke task: {openSettings?.Status.ToString() ?? "not started"}.");
            SmokeDesktop.Diagnose(app?.Id, output);
            return 1;
        }
        finally
        {
            if (app is not null)
            {
                // Failure cleanup only; success requires the normal close path above.
                if (!app.HasExited) app.Kill(entireProcessTree: true);
                if (app.WaitForExit(5000)) app.WaitForExit();
                app.Dispose();
            }
        }
#else
        Console.WriteLine("SKIP: WPF UI smoke requires an interactive Windows desktop.");
        return 0;
#endif
    }

#if WINDOWS
    private static AutomationElement? FindWindow(int pid, string id) => SmokeDesktop.FindWindow(pid, id);
    private static AutomationElement? ReadySettingsButton(AutomationElement main)
    {
        var button = Find(main, "OpenSettings");
        return main.Current.IsEnabled && button.Current.IsEnabled && !button.Current.IsOffscreen ? button : null;
    }
    private static bool InvokeSettings(IntPtr mainHwnd)
    {
        try
        {
            // Acquire UIA objects on the MTA worker that invokes the modal dialog.
            var button = Find(AutomationElement.FromHandle(mainHwnd), "OpenSettings");
            if (!button.Current.IsEnabled || button.Current.IsOffscreen)
            {
                Console.WriteLine("Settings: button became unavailable before Invoke; will wait before clicking.");
                return false;
            }
            if (!button.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern))
            {
                Console.WriteLine("Settings: InvokePattern unavailable; will try a click.");
                return false;
            }
            Console.WriteLine("Settings: invoking enabled button.");
            ((InvokePattern)pattern).Invoke();
            Console.WriteLine("Settings: Invoke returned.");
            return true;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"Settings Invoke failed: {error}");
            return false; // Observed here; the main MTA thread can try a click while polling windows.
        }
    }
    private static AutomationElement WaitForSettings(AutomationElement main, Process app, Task<bool> invoke)
    {
        var watch = Stopwatch.StartNew();
        var clicked = false;
        var clickRequested = false;
        return Wait(() =>
        {
            if (FindWindow(app.Id, "SettingsWindow") is { } settings) return settings;
            // Invoke may return before dispatch, throw, or remain inside ShowDialog.
            // Allow dispatch time, then fall back once, only if the owner is still enabled.
            if (!clicked && ((invoke.IsCompletedSuccessfully && !invoke.Result) || watch.Elapsed >= TimeSpan.FromSeconds(3))
                && ReadySettingsButton(main) is { } button)
            {
                // Recheck after reading button state so a just-created modal is not clicked over.
                if (FindWindow(app.Id, "SettingsWindow") is { } opened) return opened;
                if (!clickRequested) Console.WriteLine("Settings: waiting for foreground/button readiness for click fallback.");
                clickRequested = true;
                clicked = SmokeDesktop.TryClick(main, button);
            }
            return null;
        }, app, TimeSpan.FromSeconds(15), "settings window (desktop UIA and process HWNDs)");
    }
    private static AutomationElement Find(AutomationElement root, string id) => root.FindFirst(TreeScope.Descendants,
        new PropertyCondition(AutomationElement.AutomationIdProperty, id)) ?? throw new InvalidOperationException($"Missing control: {id}");
    private static AutomationElement Wait(Func<AutomationElement?> find, Process app, TimeSpan timeout, string description)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < timeout)
        {
            if (app.HasExited) throw new InvalidOperationException($"App exited early ({app.ExitCode}) while waiting for {description}.");
            try { if (find() is { } element) return element; }
            catch (ElementNotAvailableException) { }
            Thread.Sleep(100);
        }
        throw new TimeoutException($"Timed out waiting for {description}.");
    }
    private static void Capture(AutomationElement window, string file)
    {
        var hwnd = new IntPtr(window.Current.NativeWindowHandle);
        if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, out var rect)) throw new InvalidOperationException("Window is not visible.");
        if (rect.Right - rect.Left < 100 || rect.Bottom - rect.Top < 100) throw new InvalidOperationException("Window is too small.");
        using var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            var hdc = graphics.GetHdc();
            try { if (!PrintWindow(hwnd, hdc, 2)) throw new InvalidOperationException("PrintWindow failed; interactive desktop required."); }
            finally { graphics.ReleaseHdc(hdc); }
        }
        // Refuse uniform/blank captures instead of uploading misleading evidence.
        var colors = new System.Collections.Generic.HashSet<int>();
        for (var y = 20; y < bitmap.Height - 20; y += 7)
            for (var x = 20; x < bitmap.Width - 20; x += 7) colors.Add(bitmap.GetPixel(x, y).ToArgb());
        if (colors.Count < 8) throw new InvalidOperationException("Screenshot is blank or not rendered.");
        bitmap.Save(file, ImageFormat.Png);
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
#endif
}
