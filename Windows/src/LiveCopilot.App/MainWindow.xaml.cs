using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Sessions;
using LiveCopilot.Platform.Windows.Audio;
using LiveCopilot.Platform.Windows.Hotkeys;
using LiveCopilot.Platform.Windows.Overlay;

namespace LiveCopilot.App;

public partial class MainWindow : Window
{
    private OverlayWindow? overlay;
    private HotkeyManager? hotkeys;
    private ListeningSession? session;
    private bool closeRequested, closeComplete;
    private int refreshQueued;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += InitializeSession;
        Closing += CloseSession;
    }

    private void InitializeSession(object sender, RoutedEventArgs e)
    {
        if (session is not null || closeRequested) return;
        try
        {
            var preferences = new FilePreferenceStore();
            var settings = AppSettings.Load(preferences);
            session = new(new WasapiAudioSourceFactory(), CreateProvider, settings,
                new TranscriptStore(), new SessionStore());
            session.Changed += QueueRefresh;
            overlay = new OverlayWindow(settings);
            overlay.Show();
            hotkeys = new HotkeyManager(new HotkeyStore(preferences), new Win32HotkeyRegistrar(),
                session.Request, overlay.ToggleVisibility, error => HostErrorText.Text = error);
            hotkeys.SetEnabledModes(settings.EnabledSuggestionModes);
            RefreshSession(); // Construction and Loaded never start audio or inference.
        }
        catch (Exception error) { HostErrorText.Text = "初始化失败：" + error.Message; }
    }

    private static ListeningProvider CreateProvider(Speaker speaker, ListeningService service)
    {
        var provider = new LocalLiveProvider(speaker: speaker, contextual: service == ListeningService.Zipformer);
        return new(provider, terms => provider.UpdateTerms(terms), () => provider.Backend?.ToString());
    }

    private async void StartListening(object sender, RoutedEventArgs e)
    {
        if (session is null || closeRequested) return;
        StartButton.IsEnabled = false;
        try { await session.StartAsync(); }
        catch (Exception error) { HostErrorText.Text = "无法开始聆听：" + error.Message; }
        finally { RefreshSession(); }
    }

    private async void StopListening(object sender, RoutedEventArgs e)
    {
        if (session is null || closeRequested) return;
        StopButton.IsEnabled = false;
        try { await session.StopAsync(); }
        catch (Exception error) { HostErrorText.Text = "停止失败：" + error.Message; }
        finally { RefreshSession(); }
    }

    private void QueueRefresh()
    {
        // Coalesce worker notifications. Read the latest immutable snapshot on Dispatcher,
        // so queued updates cannot redraw an old session after a restart.
        if (Interlocked.Exchange(ref refreshQueued, 1) != 0) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            Interlocked.Exchange(ref refreshQueued, 0);
            if (!closeComplete) RefreshSession();
        });
    }

    private void RefreshSession()
    {
        if (session is null || closeComplete) return;
        var view = session.Snapshot;
        Title = "LiveCopilot — " + view.Status;
        StateText.Text = view.Status;
        ErrorText.Text = view.Error ?? "";
        SystemText.Text = Describe("系统 / Them", view.System);
        MicrophoneText.Text = Describe("麦克风 / You", view.Microphone);
        SuggestionText.Text = view.SuggestionStatus ?? "";
        StartButton.IsEnabled = !closeRequested && !view.IsStopping && view.State is not (ListeningState.Starting or ListeningState.Listening);
        StopButton.IsEnabled = !closeRequested && !view.IsStopping && view.State is (ListeningState.Starting or ListeningState.Listening);
        overlay?.SetContent(new(view.Status + (view.Error is null ? "" : "\n" + view.Error),
            view.Lines, view.PartialThem, view.PartialYou, view.SuggestionStatus));
    }

    private static string Describe(string label, ListeningPathSnapshot path) =>
        $"{label} · {(path.Capturing ? "采集中" : "未采集")}\n{path.SourceDescription ?? "尚未启动音频源"}\n语音后端：{path.Backend ?? "尚未就绪"}";

    private async void CloseSession(object? sender, CancelEventArgs e)
    {
        if (closeComplete) return;
        e.Cancel = true;
        if (closeRequested) return;
        closeRequested = true;
        StartButton.IsEnabled = StopButton.IsEnabled = false;
        try
        {
            if (session is not null)
            {
                await session.DisposeAsync();
                RefreshSession();
                if (session.Snapshot.Error is { } error)
                    MessageBox.Show(this, error, "会话结束提示", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "停止会话失败", MessageBoxButton.OK, MessageBoxImage.Error); }
        finally
        {
            if (session is not null) session.Changed -= QueueRefresh;
            hotkeys?.Dispose();
            overlay?.Close();
            closeComplete = true;
            Close();
        }
    }
}
