using System;
#if WINDOWS
using System.Diagnostics;
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
        var historyRunId = Guid.NewGuid().ToString("N");
        var historyDirectory = Path.Combine(Path.GetTempPath(), "LiveCopilot-smoke-" + historyRunId);
        try
        {
            var history = HistoryFixtures.Seed(historyDirectory);
            var historyFiles = Directory.GetFiles(Path.Combine(historyDirectory, "sessions"))
                .ToDictionary(path => path, File.ReadAllBytes);
            var start = new ProcessStartInfo(Path.GetFullPath(args[0]))
            {
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
            };
            start.WorkingDirectory = Path.GetDirectoryName(start.FileName)!;
            start.Environment["LIVECOPILOT_SMOKE"] = "1";
            start.Environment["LIVECOPILOT_SMOKE_ONBOARDING"] = "1";
            start.Environment["LIVECOPILOT_SMOKE_GUIDE"] = "1";
            start.Environment["LIVECOPILOT_SMOKE_DATA_ID"] = historyRunId;
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
            var guide = Wait(() => FindWindow(app.Id, "OnboardingWindow"), app, TimeSpan.FromSeconds(10), "first-run onboarding");
            for (var step = 0; step < 6; step++)
            {
                Wait(() => guide.Current.ItemStatus == step.ToString() ? guide : null, app, TimeSpan.FromSeconds(5), $"onboarding step {step + 1}");
                Thread.Sleep(350);
                var compact = SmokeDesktop.RequireFitsWorkArea(guide);
                RequireFullyVisible(guide, "OnboardingNext");
                RequireFullyVisible(guide, "OnboardingBack");
                if (compact && step is 0 or 1)
                {
                    var intro = Find(guide, "OnboardingIntroScroll");
                    if (intro.TryGetCurrentPattern(ScrollPattern.Pattern, out var introPattern) && ((ScrollPattern)introPattern).Current.VerticallyScrollable)
                        throw new InvalidOperationException($"Onboarding step {step + 1} should fit without left-column scrolling.");
                    RequireFullyVisible(guide, step == 0 ? "OnboardingLanguageHint" : "OnboardingScenarioHint");
                    if (step == 0 && Find(guide, "OnboardingLanguageHint").Current.BoundingRectangle.Height > 24 * SmokeDesktop.DpiScale(guide))
                        throw new InvalidOperationException("Onboarding language hint wrapped onto a second line.");
                    if (step == 1) RequireFullyVisible(guide, "OnboardingScenario");
                }
                if (compact && step == 2)
                    foreach (var id in new[] { "ModelCardZipformer", "ModelCardParaformer", "ModelCardEmbedding" })
                    {
                        RequireFullyVisible(guide, id);
                        RequireFullyVisible(guide, id + "Download");
                        RequireFullyVisible(guide, id + "Hint");
                    }
                Capture(guide, Path.Combine(output, $"onboarding-{step + 1:00}.png"));
                if (step == 2)
                {
                    ScrollControlsIntoView(guide, "OnboardingDetailScroll", "ModelCardEmbedding", "ModelCardEmbeddingDownload", "ModelCardEmbeddingHint");
                    RequireModelCards(guide, ["ModelCardEmbedding"]);
                    Capture(guide, Path.Combine(output, "onboarding-03-lower.png"));
                }
                if (step == 5)
                {
                    ScrollTo(guide, "OnboardingDetailScroll", 100);
                    RequireFullyVisible(guide, "ReadyJev");
                    Capture(guide, Path.Combine(output, "onboarding-06-lower.png"));
                }
                Invoke(guide, "OnboardingNext");
            }
            Wait(() => FindWindow(app.Id, "OnboardingWindow") is null ? main : null, app, TimeSpan.FromSeconds(10), "onboarding completed");
            Wait(() => ReadySettingsButton(main), app, TimeSpan.FromSeconds(10), "settings button enabled and visible");
            var operationGuide = Wait(() => VisibleGuide(main), app, TimeSpan.FromSeconds(10), "operation guide");
            for (var step = 0; step < 4; step++)
            {
                Wait(() => operationGuide.Current.ItemStatus == step.ToString() ? operationGuide : null, app, TimeSpan.FromSeconds(5), $"operation tip {step + 1}");
                Thread.Sleep(350);
                RequireFullyVisible(main, "OperationGuideNext");
                Capture(main, Path.Combine(output, $"overlay-guide-{step + 1:00}.png"));
                Invoke(main, "OperationGuideNext");
            }
            Wait(() => VisibleGuide(main) is null ? main : null, app, TimeSpan.FromSeconds(5), "operation guide dismissed");
            Thread.Sleep(350);
            Capture(main, Path.Combine(output, "00-overlay-idle.png"));
            // Toggle only the next-run preference. Smoke never opens an audio device.
            Invoke(main, "ToggleMicrophone");
            if (!Find(main, "ToggleMicrophone").Current.Name.Contains("关闭", StringComparison.Ordinal)) throw new InvalidOperationException("Microphone preference did not change.");
            Invoke(main, "ToggleMicrophone");
            CaptureAutoHeight(main, app, output);
            CaptureMenu(main, "KnowledgeModeMenu", Path.Combine(output, "overlay-knowledge-menu.png"));
            CaptureMenu(main, "AnswerLanguageMenu", Path.Combine(output, "overlay-answer-language.png"));
            // Invoke can stay blocked while WPF ShowDialog runs its nested dispatcher.
            var mainHwnd = new IntPtr(main.Current.NativeWindowHandle);
            openSettings = Task.Run(() => InvokeSettings(mainHwnd));
            var settings = WaitForSettings(main, app, openSettings);
            Thread.Sleep(350);
            SmokeDesktop.RequireFitsWorkArea(settings);
            RequireFullyVisible(settings, "SaveSettings");
            RequireFullyVisible(settings, "CancelSettings");
            string[] pages = ["GeneralPage", "ServicesPage", "KnowledgePage", "HistoryPage", "ShortcutsPage", "AboutPage"];
            var actual = settings.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem))
                .Cast<AutomationElement>().Select(element => element.Current.AutomationId).Where(id => id.EndsWith("Page", StringComparison.Ordinal)).ToArray();
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
                if (pages[i] == "HistoryPage") CaptureHistory(settings, app, output, history);
                if (pages[i] == "GeneralPage")
                {
                    ScrollControlsIntoView(settings, "GeneralScroll", "OverlayAutoHeight", "OverlayCaptureProtection");
                    Capture(settings, Path.Combine(output, "settings-general-middle.png"));
                    ScrollTo(settings, "GeneralScroll", 100);
                    Capture(settings, Path.Combine(output, "settings-general-lower.png"));
                    ScrollTo(settings, "GeneralScroll", 0);
                }
                if (pages[i] == "ServicesPage")
                {
                    string[] services = ["SpeechServiceTab", "TriggerServiceTab", "KnowledgeServiceTab", "AnalysisServiceTab"];
                    foreach (var service in services)
                    {
                        Select(settings, service); Thread.Sleep(350);
                        if (service == "SpeechServiceTab") RequireModelCards(settings, ["ModelCardZipformer"]);
                        if (service == "KnowledgeServiceTab") RequireModelCards(settings, ["ModelCardEmbedding"]);
                        Capture(settings, Path.Combine(output, $"services-{service}.png"));
                        if (service == "SpeechServiceTab")
                        {
                            ScrollTo(settings, "SpeechServiceScroll", 100);
                            RequireModelCards(settings, ["ModelCardParaformer"]);
                            RequireFullyVisible(settings, "ModelCardParaformerDownload");
                            Capture(settings, Path.Combine(output, "services-speech-lower.png"));
                            ScrollTo(settings, "SpeechServiceScroll", 0);
                            var choice = Find(settings, "ListeningServiceChoice");
                            ((ExpandCollapsePattern)choice.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
                            Thread.Sleep(200);
                            var cloud = choice.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, "OpenAI 云端 · GPT-Live-1"))
                                ?? throw new InvalidOperationException("OpenAI cloud choice missing");
                            if (!cloud.Current.IsEnabled) throw new InvalidOperationException("OpenAI cloud choice disabled");
                            ((SelectionItemPattern)cloud.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
                            ((ExpandCollapsePattern)choice.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Collapse();
                            Thread.Sleep(350);
                            foreach (var id in new[] { "OpenAILivePrice", "OpenAILiveCloudTag", "OpenAILiveMultilingualTag", "OpenAILiveUsageTag", "OpenAILiveCard", "OpenAILiveAutomatic", "OpenAILiveKeyHint" })
                                RequireFullyVisible(settings, id);
                            Capture(settings, Path.Combine(output, "services-speech-openai.png"));
                        }
                        if (service == "AnalysisServiceTab")
                        {
                            ScrollTo(settings, "AnalysisServiceScroll", 100);
                            RequireFullyVisible(settings, "独立 OpenAI 推理");
                            Capture(settings, Path.Combine(output, "services-analysis-keys.png"));
                        }
                    }
                }
            }
            // Check before normal app exit, which intentionally removes its temporary data directory.
            if (Directory.GetFiles(Path.Combine(historyDirectory, "sessions")).Length != historyFiles.Count ||
                historyFiles.Any(pair => !File.Exists(pair.Key) || !pair.Value.SequenceEqual(File.ReadAllBytes(pair.Key))))
                throw new InvalidOperationException("History smoke must leave all seeded sessions and drafts unchanged.");
            // Reopen tips through settings, skip them, then verify they stay dismissed after setup.
            Select(settings, "GeneralPage");
            ScrollTo(settings, "GeneralScroll", 0);
            Invoke(settings, "OpenOperationGuide");
            Wait(() => VisibleGuide(main) is not null && main.Current.IsEnabled ? main : null, app, TimeSpan.FromSeconds(10), "reopened operation guide");
            Invoke(main, "OperationGuideSkip");
            if (!openSettings.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Settings did not close normally.");
            openSettings = Task.Run(() => InvokeSettings(mainHwnd));
            settings = WaitForSettings(main, app, openSettings);
            Select(settings, "GeneralPage");
            ScrollTo(settings, "GeneralScroll", 0);
            Invoke(settings, "OpenOnboarding");
            var reopened = Wait(() => FindWindow(app.Id, "OnboardingWindow"), app, TimeSpan.FromSeconds(10), "reopened onboarding");
            Wait(() => reopened.Current.ItemStatus == "0" ? reopened : null, app, TimeSpan.FromSeconds(5), "reopened first step");
            Invoke(reopened, "OnboardingSkip");
            Wait(() => FindWindow(app.Id, "OnboardingWindow") is null ? main : null, app, TimeSpan.FromSeconds(10), "skipped onboarding");
            if (VisibleGuide(main) is not null) throw new InvalidOperationException("Completed operation guide opened again.");
            if (!openSettings.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Settings did not close normally.");
            Wait(() => FindWindow(app.Id, "SettingsWindow") is null && main.Current.IsEnabled ? main : null,
                app, TimeSpan.FromSeconds(10), "settings closed");
            if (!PostMessage(new IntPtr(main.Current.NativeWindowHandle), 0x0010, IntPtr.Zero, IntPtr.Zero))
                throw new InvalidOperationException("Could not request normal window close.");
            // Exercise repeated exit requests while the application drains its session.
            // The HWND may already be gone; the first request above must always succeed.
            var closeRequestsSent = 1;
            for (var i = 0; i < 2; i++)
                if (PostMessage(mainHwnd, 0x0010, IntPtr.Zero, IntPtr.Zero)) closeRequestsSent++;
            Console.WriteLine($"Posted {closeRequestsSent} normal close requests.");
            if (!app.WaitForExit(15000)) throw new TimeoutException("App did not exit normally within 15 seconds.");
            app.WaitForExit(); // Drain redirected output callbacks before disposing the writers.
            if (app.ExitCode != 0) throw new InvalidOperationException($"App exited with code {app.ExitCode}.");
            if (Directory.GetFiles(output, "*.png").Length != 34) throw new InvalidOperationException("Expected thirty-four screenshots.");
            var events = File.ReadAllLines(Path.Combine(output, "app-events.log"));
            foreach (var stage in new[] { "main shutdown requested", "main shutdown cleanup complete; closing", "main closed", "app exited: 0" })
                if (events.Count(line => line.EndsWith(" " + stage, StringComparison.Ordinal)) != 1)
                    throw new InvalidOperationException($"Expected exactly one shutdown event: {stage}.");
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new
            { success = true, startupMs, appExitCode = app.ExitCode, pages, screenshots = 34, closeRequestsSent,
                historySessions = history.Count, historyActionsInvoked = false,
                historyScreenshots = new[] { "settings-history-list.png", "settings-history-detail.png" } }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"PASS: main ready in {startupMs} ms; overlay, six settings pages, four service tabs and six onboarding steps captured; app exit code 0.");
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
            try { if (Directory.Exists(historyDirectory)) Directory.Delete(historyDirectory, recursive: true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { Console.Error.WriteLine("Could not remove temporary smoke data: " + error.Message); }
        }
#else
        Console.WriteLine("SKIP: WPF UI smoke requires an interactive Windows desktop.");
        return 0;
#endif
    }

#if WINDOWS
    private static void CaptureHistory(AutomationElement settings, Process app, string output,
        System.Collections.Generic.IReadOnlyList<LiveCopilot.Core.SessionRecord> history)
    {
        foreach (var row in history)
            RequireFullyVisible(settings, "HistorySession-" + LiveCopilot.Core.CoreJson.Id(row.Id));
        foreach (var id in new[] { "HistorySearch", "HistoryOpen", "HistoryDelete", "HistoryClearAll", "HistoryExportMarkdown", "HistoryExportText" })
        {
            RequireFullyVisible(settings, id);
            if (!Find(settings, id).Current.IsEnabled) throw new InvalidOperationException($"History action is disabled: {id}");
        }
        Capture(settings, Path.Combine(output, "settings-history-list.png"));
        Invoke(settings, "HistoryOpen");
        Wait(() => settings.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "HistoryDetailTitle"))
            is { Current.IsOffscreen: false } ? settings : null, app, TimeSpan.FromSeconds(5), "history detail");
        Thread.Sleep(350);
        foreach (var id in new[] { "HistoryBack", "HistoryDetailDelete", "HistoryDetailExportMarkdown", "HistoryDetailExportText" })
        {
            RequireFullyVisible(settings, id);
            if (!Find(settings, id).Current.IsEnabled) throw new InvalidOperationException($"History action is disabled: {id}");
        }
        var answer = history[0].Answers![0];
        RequireFullyVisible(settings, "HistoryEvent-speech-" + LiveCopilot.Core.CoreJson.Id(history[0].Lines[0].Id));
        RequireFullyVisible(settings, "HistoryEvent-question-" + LiveCopilot.Core.CoreJson.Id(answer.Id));
        ScrollControlsIntoView(settings, "HistoryTimeline", "HistoryEvent-answer-" + LiveCopilot.Core.CoreJson.Id(answer.Id));
        RequireFullyVisible(settings, "HistoryEvent-answer-" + LiveCopilot.Core.CoreJson.Id(answer.Id) + "-Sources");
        Capture(settings, Path.Combine(output, "settings-history-detail.png"));
        Invoke(settings, "HistoryBack");
        Thread.Sleep(350);
        Select(settings, "HistorySession-" + LiveCopilot.Core.CoreJson.Id(history[2].Id));
        Invoke(settings, "HistoryOpen"); Thread.Sleep(350);
        var scroll = (ScrollPattern)Find(settings, "HistoryTimeline").GetCurrentPattern(ScrollPattern.Pattern);
        if (!scroll.Current.VerticallyScrollable) throw new InvalidOperationException("Long history must scroll.");
        ScrollTo(settings, "HistoryTimeline", 100);
        RequireFullyVisible(settings, "HistoryEvent-speech-" + LiveCopilot.Core.CoreJson.Id(history[2].Lines[^1].Id));
        Invoke(settings, "HistoryBack");
        Thread.Sleep(350);
        Console.WriteLine("History: three synthetic sessions; transcript, question, answer and citation visible; long history scrolls; destructive/export actions checked without invocation.");
    }

    private static void Invoke(AutomationElement root, string id) =>
        ((InvokePattern)Find(root, id).GetCurrentPattern(InvokePattern.Pattern)).Invoke();
    private static void Select(AutomationElement root, string id) =>
        ((SelectionItemPattern)Find(root, id).GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
    private static void CaptureMenu(AutomationElement main, string id, string file)
    {
        var menu = (ExpandCollapsePattern)Find(main, id).GetCurrentPattern(ExpandCollapsePattern.Pattern);
        menu.Expand(); Thread.Sleep(350);
        if (menu.Current.ExpandCollapseState != ExpandCollapseState.Expanded) throw new InvalidOperationException($"Menu did not open: {id}");
        // WPF Popup has its own HWND and is omitted by PrintWindow(main).
        var bounds = main.Current.BoundingRectangle;
        // Include popup items in screen coordinates, then crop to the app and its menu.
        var items = Find(main, id).FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem));
        var visibleItems = 0;
        foreach (AutomationElement item in items)
            if (!item.Current.IsOffscreen && !item.Current.BoundingRectangle.IsEmpty) { bounds.Union(item.Current.BoundingRectangle); visibleItems++; }
        if (visibleItems == 0) throw new InvalidOperationException($"No visible popup items: {id}");
        bounds.Inflate(8, 8);
        ScreenCapture.Region(bounds, file);
        menu.Collapse(); Thread.Sleep(150);
    }

    private static AutomationElement? VisibleGuide(AutomationElement main)
    {
        var guide = main.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "OperationGuide"));
        return guide is not null && !guide.Current.IsOffscreen ? guide : null;
    }
    private static void ScrollTo(AutomationElement root, string id, double percent)
    {
        var scroll = (ScrollPattern)Find(root, id).GetCurrentPattern(ScrollPattern.Pattern);
        if (scroll.Current.VerticallyScrollable) scroll.SetScrollPercent(ScrollPattern.NoScroll, percent);
        Thread.Sleep(350);
    }
    private static void RequireFullyVisible(AutomationElement root, string id)
    {
        var item = Find(root, id);
        var rect = item.Current.BoundingRectangle;
        if (item.Current.IsOffscreen || rect.IsEmpty || !root.Current.BoundingRectangle.Contains(rect))
            throw new InvalidOperationException($"Control is clipped by its window: {id}");
        for (var parent = TreeWalker.ControlViewWalker.GetParent(item); parent is not null && !parent.Equals(root); parent = TreeWalker.ControlViewWalker.GetParent(parent))
            if (parent.TryGetCurrentPattern(ScrollPattern.Pattern, out _) && !parent.Current.BoundingRectangle.Contains(rect))
                throw new InvalidOperationException($"Control is clipped by its scroll viewport: {id}");
    }
    private static void ScrollControlsIntoView(AutomationElement root, string scrollId, params string[] ids)
    {
        // Search actual UIA rectangles instead of assuming that 50% is the middle section.
        // This also works when font metrics or the available work area change.
        for (var percent = 0; percent <= 100; percent += 5)
        {
            ScrollTo(root, scrollId, percent);
            var viewport = Find(root, scrollId).Current.BoundingRectangle;
            if (!ids.All(id =>
                {
                    var control = Find(root, id).Current;
                    return !control.IsOffscreen && !control.BoundingRectangle.IsEmpty && viewport.Contains(control.BoundingRectangle);
                })) continue;
            foreach (var id in ids) RequireFullyVisible(root, id);
            Console.WriteLine($"Fully visible together in {scrollId}: {string.Join(", ", ids)} at {percent}%.");
            return;
        }
        throw new InvalidOperationException($"Controls cannot fit together in {scrollId}: {string.Join(", ", ids)}");
    }
    private static void CaptureAutoHeight(AutomationElement main, Process app, string output)
    {
        var hwnd = new IntPtr(main.Current.NativeWindowHandle);
        var initial = main.Current.BoundingRectangle.Height;
        var questionHeight = Find(main, "ManualQuestion").Current.BoundingRectangle.Height;
        var transcriptHeight = Find(main, "TranscriptScroll").Current.BoundingRectangle.Height;
        if (!PostMessage(hwnd, 0x8000 + 71, new IntPtr(1), IntPtr.Zero)) throw new InvalidOperationException("Cannot inject smoke answer.");
        Wait(() => main.Current.BoundingRectangle.Height > initial + 40 ? main : null, app, TimeSpan.FromSeconds(5), "answer auto height expanded");
        Thread.Sleep(350);
        var expanded = main.Current.BoundingRectangle.Height;
        var scroll = (ScrollPattern)Find(main, "AnswerScroll").GetCurrentPattern(ScrollPattern.Pattern);
        if (!scroll.Current.VerticallyScrollable) throw new InvalidOperationException("Long answer must scroll independently.");
        RequireFullyVisible(main, "ManualQuestion");
        if (Math.Abs(Find(main, "ManualQuestion").Current.BoundingRectangle.Height - questionHeight) > 1) throw new InvalidOperationException("Answer growth resized the question input.");
        if (Math.Abs(Find(main, "TranscriptScroll").Current.BoundingRectangle.Height - transcriptHeight) > 1) throw new InvalidOperationException("Answer growth resized the transcript viewport.");
        Capture(main, Path.Combine(output, "overlay-autoheight-expanded.png"));
        Invoke(main, "ResetSession");
        Wait(() => main.Current.BoundingRectangle.Height < expanded - 40 ? main : null, app, TimeSpan.FromSeconds(5), "answer auto height contracted");
        Thread.Sleep(350);
        Capture(main, Path.Combine(output, "overlay-autoheight-reset.png"));
        Console.WriteLine($"Auto height: {initial} -> {expanded} -> {main.Current.BoundingRectangle.Height}; long answer scrollable.");
    }

    private static void RequireModelCards(AutomationElement settings, string[] ids)
    {
        foreach (var id in ids)
        {
            var card = Find(settings, id);
            if (card.Current.IsOffscreen)
            {
                for (var parent = TreeWalker.ControlViewWalker.GetParent(card); parent is not null; parent = TreeWalker.ControlViewWalker.GetParent(parent))
                    if (parent.TryGetCurrentPattern(ScrollPattern.Pattern, out var pattern) && ((ScrollPattern)pattern).Current.VerticallyScrollable)
                    { ((ScrollPattern)pattern).SetScrollPercent(ScrollPattern.NoScroll, 100); Thread.Sleep(350); break; }
            }
            if (card.Current.IsOffscreen || card.Current.BoundingRectangle.IsEmpty || string.IsNullOrWhiteSpace(card.Current.Name))
                throw new InvalidOperationException($"Model card is not visible: {id}.");
            if (card.Current.ItemStatus != "未安装") throw new InvalidOperationException($"Unexpected smoke model state: {id}.");
            if (Find(settings, id + "Download").Current.IsEnabled)
                throw new InvalidOperationException($"Smoke must disable model downloads: {id}.");
            Console.WriteLine($"Visible model card: {id}; {card.Current.Name}; downloads disabled.");
        }
    }
#endif

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
    private static void Capture(AutomationElement window, string file) =>
        ScreenCapture.Window(new IntPtr(window.Current.NativeWindowHandle), file);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
#endif
}
