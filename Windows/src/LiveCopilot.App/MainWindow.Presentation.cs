using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.App;

public partial class MainWindow
{
    private bool autoHeightQueued;
    private double? heightBeforeGuide;
    private double heightBeforeDrag;
    private bool manualSizing;
    private string? smokeAnswer;
    private const int SmokePresentationMessage = 0x8000 + 71;

    private void InitializeOperationGuide()
    {
        viewModel.Guide.PropertyChanged += GuidePresentationChanged;
        viewModel.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(OverlayViewModel.IsResetting)) RefreshSession(); else if (e.PropertyName == nameof(OverlayViewModel.MicrophoneChangeNotice)) QueueAutoHeight(); };
        SourceInitialized += (_, _) => HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(PresentationMessage);
        SizeChanged += (_, e) => { if (e.WidthChanged) QueueAutoHeight(); };
        Loaded += (_, _) => QueueAutoHeight();
    }

    internal void ShowOperationGuide(bool reopen)
    {
        if (closeRequested || (AppRuntime.IsSmoke && Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE_GUIDE") != "1")) return;
        SetOverlayVisible(true);
        viewModel.Guide.Configure(hotkeyStore?.Combo(SuggestionMode.Reply).ToString() ?? "Ctrl+Alt+Space", hotkeyStore?.ToggleOverlay.ToString() ?? "Alt+H", settings.ExcludeOverlayFromCapture);
        viewModel.Guide.Open(reopen);
    }

    private void GuidePresentationChanged(object? sender, PropertyChangedEventArgs e)
    {
        var guide = viewModel.Guide;
        if (guide.IsVisible) heightBeforeGuide ??= Height;
        else if (heightBeforeGuide is { } previous)
        {
            heightBeforeGuide = null;
            if (!settings.OverlayAutoHeight) Height = previous;
        }
        Highlight(StartButton, guide.HighlightStart);
        Highlight(ReplyButton, guide.HighlightAnswer);
        Highlight(PinButton, guide.HighlightPin);
        Highlight(SettingsButton, guide.HighlightSettings);
        QueueAutoHeight();
    }
    private void Highlight(Button button, bool active) => button.BorderBrush = active ? (Brush)FindResource("Accent") : Brushes.Transparent;

    private void QueueAutoHeight()
    {
        if (autoHeightQueued) return;
        autoHeightQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            autoHeightQueued = false;
            if (closeRequested || manualSizing || (!settings.OverlayAutoHeight && !viewModel.Guide.IsVisible)) return;
            var width = Math.Max(1, ActualWidth - 30);
            // Measure chrome independently: the answer ScrollViewer must not dictate fixed rows.
            OverlayLayout.Measure(new Size(width, double.PositiveInfinity));
            AnswerPanel.Measure(new Size(Math.Max(1, width - SystemParameters.VerticalScrollBarWidth), double.PositiveInfinity));
            var chrome = OverlayLayout.DesiredSize.Height - AnswerScroll.DesiredSize.Height + 30;
            OverlayLayout.InvalidateMeasure();
            var area = SystemParameters.WorkArea;
            Height = OverlaySizing.Height(chrome, AnswerPanel.DesiredSize.Height, MinHeight, Math.Min(MaxHeight, area.Height - 24));
            if (Top + Height > area.Bottom - 12) Top = Math.Max(area.Top + 12, area.Bottom - Height - 12);
        });
    }

    private IntPtr PresentationMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == 0x0231) heightBeforeDrag = Height; // WM_ENTERSIZEMOVE
        if (message == 0x0214) manualSizing = true; // WM_SIZING: streaming must not fight the drag.
        if (message == 0x0232)
        {
            manualSizing = false;
            if (Math.Abs(Height - heightBeforeDrag) > 1 && !viewModel.Guide.IsVisible)
                SaveOverlaySettings(settings with { OverlayAutoHeight = false });
            else QueueAutoHeight();
        }
        // Isolated smoke fixture: no provider, credentials, audio or real model involved.
        if (message == SmokePresentationMessage && AppRuntime.IsSmoke)
        {
            if (wParam.ToInt32() == 1)
                smokeAnswer = "演示回答 · 用于检查回答区自动伸缩\n\n" + string.Join("\n\n", Enumerable.Repeat("先说明目标，再介绍具体的方法。结合项目中的职责、行动与结果，给出可以直接说出口的回答。长回答仅在下方独立滚动，转写与输入保持固定。", 12));
            else smokeAnswer = null;
            RefreshSession();
            handled = true;
        }
        return IntPtr.Zero;
    }
}
