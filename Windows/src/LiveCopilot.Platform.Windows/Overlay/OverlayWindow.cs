using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.Platform.Overlay;
using LiveCopilot.Platform.Windows.Native;

namespace LiveCopilot.Platform.Windows.Overlay;

/// Non-activating session card. Configure and SetContent run on the UI thread.
/// Its HWND remains alive while edge-hidden.
public sealed class OverlayWindow : Window
{
    private readonly WindowCaptureProtection protection;
    private readonly DispatcherTimer edgeTimer;
    private OverlayController controller;
    private AppSettings settings;
    private HwndSource? source;
    private nint hwnd;
    private bool applying, refreshQueued, closed;
    private double scale = 1;
    private WindowNative.Point? dragStart;
    private LayoutRect dragFrame;
    private readonly StackPanel card = new();
    private readonly TextBlock statusText = new() { Text = "未开始聆听", TextWrapping = TextWrapping.Wrap, Foreground = Brushes.LightGray, Margin = new Thickness(0, 16, 0, 0) };
    private readonly StackPanel transcriptLines = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly TextBlock partialThem = new() { Foreground = Brushes.LightSkyBlue, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock partialYou = new() { Foreground = Brushes.LightGreen, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock suggestionText = new() { Foreground = Brushes.LightGray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) };
    private readonly TextBlock answerText = new() { Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    public CaptureProtectionStatus CaptureProtectionStatus => protection.Status;
    public event Action<CaptureProtectionStatus>? CaptureProtectionChanged;
    public bool EdgeHidden => controller.Hidden;

    public OverlayWindow(AppSettings? settings = null, IWindowDisplayAffinity? affinity = null)
    {
        this.settings = settings ?? new AppSettings();
        protection = new(affinity ?? new Win32WindowDisplayAffinity());
        var work = SystemParameters.WorkArea;
        controller = new(OverlayCoordinates.ToCore(new LayoutRect(work.X, work.Y, work.Width, work.Height)));
        controller.Configure(this.settings);
        Title = "LiveCopilot overlay";
        Width = 480; Height = 280;
        MinWidth = 400; MinHeight = 240; MaxWidth = 700; MaxHeight = 1000;
        Topmost = true; ShowActivated = false; ShowInTaskbar = false;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        Focusable = false;
        card.Children.Add(new TextBlock { Text = "LiveCopilot", FontSize = 22, Foreground = Brushes.White });
        card.Children.Add(statusText);
        card.Children.Add(transcriptLines);
        card.Children.Add(partialThem);
        card.Children.Add(partialYou);
        card.Children.Add(suggestionText);
        card.Children.Add(answerText);
        Content = new Border
        {
            CornerRadius = new CornerRadius(16), Padding = new Thickness(24),
            Background = new SolidColorBrush(Color.FromArgb(232, 28, 32, 40)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(100, 160, 174, 190)), BorderThickness = new Thickness(1),
            Child = new ScrollViewer { Content = card, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false }
        };
        card.SizeChanged += (_, _) => MeasureContent();
        edgeTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(50), DispatcherPriority.Background, (_, _) => PollEdge(), Dispatcher);
        edgeTimer.Stop();
        SourceInitialized += (_, _) => InitializeHandle();
        PreviewMouseLeftButtonDown += BeginDrag;
        PreviewMouseMove += ContinueDrag;
        PreviewMouseLeftButtonUp += (_, _) => { dragStart = null; ReleaseMouseCapture(); controller.Interaction(); };
        LostMouseCapture += (_, _) => dragStart = null;
        Closed += (_, _) => { closed = true; edgeTimer.Stop(); source?.RemoveHook(Message); source = null; hwnd = 0; };
    }

    private void InitializeHandle()
    {
        hwnd = new WindowInteropHelper(this).Handle;
        source?.RemoveHook(Message);
        source = HwndSource.FromHwnd(hwnd);
        source.AddHook(Message);
        WindowNative.MakeNonActivatingToolWindow(hwnd);
        scale = Math.Max(96, WindowNative.GetDpiForWindow(hwnd)) / 96d;
        var monitor = WindowNative.Monitor(WindowNative.MonitorFromWindow(hwnd, 2));
        controller = new(ToCore(monitor.Work.Layout));
        controller.Configure(settings);
        RefreshProtection();
        ApplyFrame();
        MeasureContent();
        if (settings.OverlayEdgeHide) Dispatcher.BeginInvoke(() => { if (!closed) ApplyVisibility(); });
    }

    public void Configure(AppSettings value)
    {
        Dispatcher.VerifyAccess();
        settings = value;
        controller.Configure(settings);
        RefreshProtection();
        ApplyFrame();
        if (hwnd != 0) ApplyVisibility();
    }
    public void ContentHeightChanged(double height) { Dispatcher.VerifyAccess(); controller.ContentHeightChanged(height); ApplyFrame(); }
    public void SetContent(OverlayContent value)
    {
        Dispatcher.VerifyAccess();
        if (closed) return;
        statusText.Text = value.Status;
        transcriptLines.Children.Clear();
        foreach (var line in value.Lines.TakeLast(8))
            transcriptLines.Children.Add(new TextBlock
            {
                Text = $"{(line.Speaker == Speaker.You ? "You · 我" : "Them · 对方")}  {line.Content}",
                Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap,
                FontSize = settings.TranscriptFontSize, Margin = new Thickness(0, 0, 0, 8)
            });
        partialThem.Text = value.PartialThem.Length == 0 ? "" : "Them · 对方（未定稿）  " + value.PartialThem;
        partialYou.Text = value.PartialYou.Length == 0 ? "" : "You · 我（未定稿）  " + value.PartialYou;
        partialThem.FontSize = partialYou.FontSize = settings.TranscriptFontSize;
        suggestionText.Text = value.SuggestionStatus ?? "";
        answerText.Text = value.SuggestionText;
        answerText.FontSize = settings.AnswerFontSize;
        MeasureContent();
    }
    private void MeasureContent()
    {
        if (closed) return;
        // Allow a scrollbar at the geometry cap; measure full content for auto-height.
        card.Measure(new Size(Math.Max(1, controller.Frame.Width - 68), double.PositiveInfinity));
        ContentHeightChanged(card.DesiredSize.Height + 50);
    }
    public void ToggleVisibility() { Dispatcher.VerifyAccess(); controller.Toggle(); ApplyVisibility(); }
    public void Reveal() { Dispatcher.VerifyAccess(); controller.Reveal(); ApplyVisibility(); }

    private LayoutRect ToCore(LayoutRect pixels) => OverlayCoordinates.ToCore(OverlayCoordinates.ToDips(pixels, scale));
    private void ApplyFrame()
    {
        if (hwnd == 0 || applying || closed) return;
        var frame = OverlayCoordinates.ToPixels(OverlayCoordinates.FromCore(controller.Frame), scale);
        applying = true;
        try
        {
            if (!WindowNative.SetWindowPos(hwnd, new nint(-1), (int)Math.Round(frame.X), (int)Math.Round(frame.Y),
                (int)Math.Round(frame.Width), (int)Math.Round(frame.Height), 0x0010)) // SWP_NOACTIVATE; HWND_TOPMOST
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { applying = false; }
    }
    private void ApplyVisibility()
    {
        if (closed) return;
        if (controller.Hidden) Hide();
        else { Show(); ApplyFrame(); RefreshProtection(); }
        if (settings.OverlayEdgeHide) edgeTimer.Start(); else edgeTimer.Stop();
    }
    private void RefreshProtection()
    {
        var status = protection.Apply(hwnd, settings.ExcludeOverlayFromCapture);
        CaptureProtectionChanged?.Invoke(status);
    }
    private nint Message(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == WindowNative.MouseActivate) { handled = true; return WindowNative.NoActivate; }
        if (message is 0x02E0 or 0x007E || (message == 0x0047 && !applying)) QueueMonitorRefresh();
        return 0;
    }
    private void QueueMonitorRefresh()
    {
        if (refreshQueued || closed) return;
        refreshQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            refreshQueued = false;
            if (closed || hwnd == 0) return;
            scale = Math.Max(96, WindowNative.GetDpiForWindow(hwnd)) / 96d;
            var monitor = WindowNative.Monitor(WindowNative.MonitorFromWindow(hwnd, 2));
            controller.SetWorkArea(ToCore(monitor.Work.Layout));
            if (WindowNative.GetWindowRect(hwnd, out var frame)) controller.SetFrame(ToCore(frame.Layout));
            ApplyFrame(); RefreshProtection();
        });
    }
    private void PollEdge()
    {
        if (closed || !WindowNative.GetCursorPos(out var point)) return;
        var monitor = WindowNative.Monitor(WindowNative.MonitorFromPoint(point, 2));
        var before = controller.Hidden;
        controller.UpdatePointer(OverlayCoordinates.ToCore(new LayoutPoint(point.X / scale, point.Y / scale)),
            ToCore(monitor.Monitor.Layout), ToCore(monitor.Work.Layout), Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency,
            (WindowNative.GetAsyncKeyState(1) & 0x8000) != 0 || (WindowNative.GetAsyncKeyState(2) & 0x8000) != 0);
        if (before != controller.Hidden) ApplyVisibility();
    }
    private void BeginDrag(object sender, MouseButtonEventArgs e)
    {
        controller.Interaction();
        if (!controller.Movable || !WindowNative.GetCursorPos(out var point)) return;
        dragStart = point; dragFrame = controller.Frame; CaptureMouse();
    }
    private void ContinueDrag(object sender, MouseEventArgs e)
    {
        if (dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed || !WindowNative.GetCursorPos(out var point)) return;
        controller.Interaction();
        var monitor = WindowNative.Monitor(WindowNative.MonitorFromPoint(point, 2));
        controller.SetWorkArea(ToCore(monitor.Work.Layout));
        controller.SetFrame(dragFrame with { X = dragFrame.X + (point.X - start.X) / scale, Y = dragFrame.Y - (point.Y - start.Y) / scale });
        ApplyFrame();
    }
}
