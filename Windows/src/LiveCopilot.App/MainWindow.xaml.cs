using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Lifecycle;
using LiveCopilot.Platform.Overlay;
using LiveCopilot.Platform.Sessions;
using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Windows.Audio;
using LiveCopilot.Platform.Windows.Credentials;
using LiveCopilot.Platform.Windows.Hotkeys;
using LiveCopilot.Platform.Windows.Native;

namespace LiveCopilot.App;

public partial class MainWindow : Window
{
    private readonly OverlayViewModel viewModel;
    private readonly TrayViewModel trayModel;
    private TrayIcon? tray;
    private readonly WindowCaptureProtection protection = new(new Win32WindowDisplayAffinity());
    private bool transcriptCollapsed;
    private HotkeyManager? hotkeys;
    private ListeningSession? session;
    private AppSettings settings = new();
    private readonly ICredentialStore credentials = AppRuntime.IsSmoke ? new MemoryCredentialStore() : new WindowsCredentialStore();
    private readonly HttpClientTransport transport = new();
    private readonly FilePreferenceStore preferences = new();
    private readonly LocalEmbeddingProvider localEmbedding = new();
    private readonly KnowledgeIndex knowledge = new(System.IO.Path.Combine(AppPaths.DataDirectory, "Knowledge"), new DocumentParser());
    private HotkeyStore? hotkeyStore;
    private SettingsWindow? settingsWindow;
    private readonly WindowShutdownCoordinator shutdown;
    private bool closeRequested => shutdown.IsRequested;
    private bool closeComplete => shutdown.IsClosing || shutdown.IsClosed;
    private int refreshQueued;

    public MainWindow()
    {
        InitializeComponent();
        viewModel = new OverlayViewModel(SaveOverlaySettings, question => session?.Ask(question), ResetSessionAsync, preferences);
        InitializeOperationGuide();
        trayModel = new TrayViewModel(SetOverlayVisible, () => OpenSettings(this, new RoutedEventArgs()), Close);
        var cleanupSteps = new List<Func<Task>>
        {
            StopSettingsAsync,
            () => { hotkeys?.Dispose(); return Task.CompletedTask; },
            StopSessionAsync,
            () => localEmbedding.DisposeAsync().AsTask(),
            () => { knowledge.Dispose(); return Task.CompletedTask; },
            () => { transport.Dispose(); return Task.CompletedTask; },
            () => { tray?.Dispose(); tray = null; return Task.CompletedTask; }
        };
        AddShutdownSteps(cleanupSteps);
        shutdown = new(cleanupSteps, action => Dispatcher.BeginInvoke(DispatcherPriority.Background, action), CompleteClose);
        DataContext = viewModel;
        Loaded += InitializeSession;
        IsVisibleChanged += (_, _) => trayModel.SetVisible(IsVisible && WindowState != WindowState.Minimized);
        StateChanged += (_, _) => trayModel.SetVisible(IsVisible && WindowState != WindowState.Minimized);
        SourceInitialized += (_, _) => RefreshProtection();
        Closing += CloseSession;
        Closed += (_, _) => { shutdown.NotifyClosed(); SmokeDiagnostics.Event("main closed"); };
    }

    private void InitializeSession(object sender, RoutedEventArgs e)
    {
        if (session is not null || closeRequested) return;
        try
        {
            settings = AppSettings.Load(preferences);
            session = new(AppRuntime.IsSmoke ? new SmokeAudioSourceFactory() : new WasapiAudioSourceFactory(), CreateProvider, settings,
                new TranscriptStore(), new SessionStore(),
                configuredReasoningFactory: selection => ReasoningProviderFactory.Make(selection, credentials, transport),
                knowledgeRetriever: knowledge, embeddingFactory: CreateEmbedding);
            session.Changed += QueueRefresh;
            viewModel.Configure(settings);
            ConfigureAppearance();
            try { tray = new TrayIcon(this, trayModel); }
            catch (Exception error) { HostErrorText.Text = error.Message + " 可使用任务栏恢复窗口。"; }
            hotkeyStore = new HotkeyStore(preferences);
            hotkeys = new HotkeyManager(hotkeyStore, AppRuntime.IsSmoke ? new SmokeHotkeyRegistrar() : new Win32HotkeyRegistrar(),
                mode => { if (!closeRequested) session.Request(mode); },
                () => { if (!closeRequested) trayModel.ToggleCommand.Execute(null); },
                error => HostErrorText.Text = "快捷键注册失败，请在设置中更换被占用的组合。\n" + error);
            hotkeys.SetEnabledModes(settings.EnabledSuggestionModes);
            RefreshSession(); // Construction and Loaded never start audio or inference.
            SettingsButton.IsEnabled = true;
            AutomationProperties.SetItemStatus(this, "ready");
            SmokeDiagnostics.Event("main ready; settings enabled");
            OpenFirstRun();
        }
        catch (Exception error)
        {
            SmokeDiagnostics.Exception("main initialization", error);
            HostErrorText.Text = "初始化失败：" + error.Message;
        }
    }

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        SmokeDiagnostics.Event("settings requested");
        if (closeRequested || hotkeyStore is null || hotkeys is null)
        {
            SmokeDiagnostics.Event("settings request ignored: main closing or uninitialized");
            return;
        }
        var guideFocused = false;
        FocusActiveGuide(ref guideFocused);
        if (guideFocused) return;
        if (settingsWindow is not null) { settingsWindow.Activate(); return; }
        SetOverlayVisible(true);
        var viewModel = new SettingsViewModel(preferences, credentials, hotkeyStore,
            service => service is ListeningService.Zipformer or ListeningService.Paraformer &&
                LocalModels.Get(service == ListeningService.Zipformer ? LocalModelKind.TerminologySpeech : LocalModelKind.StreamingSpeech).IsInstalled(LocalModels.DefaultRoot),
            () => LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot), typeof(MainWindow).Assembly,
            () => NativeRuntimeSupport.SpeechUnavailable, () => NativeRuntimeSupport.EmbeddingUnavailable, NativeRuntimeSupport.Notice);
        viewModel.Saved += ApplySettings;
        try
        {
            settingsWindow = new SettingsWindow(viewModel, knowledge, CreateEmbedding, hotkeys) { Owner = this };
            settingsWindow.ShowDialog();
        }
        finally
        {
            settingsWindow = null;
            viewModel.Saved -= ApplySettings;
            SmokeDiagnostics.Event("settings dialog returned");
        }
    }

    private void ApplySettings(AppSettings value)
    {
        if (closeRequested) return;
        settings = value with { };
        session?.Configure(settings);
        viewModel.Configure(settings);
        ConfigureAppearance();
        hotkeys?.SetEnabledModes(settings.EnabledSuggestionModes);
        RefreshSession(); // Re-render existing text immediately with the saved font sizes.
    }

    private IEmbeddingProvider CreateEmbedding(AppSettings selection)
    {
        AppRuntime.RequireInteractive("嵌入服务");
        if (selection.EmbeddingService == EmbeddingService.OpenAI)
            return OpenAIEmbeddingProvider.FromCredentials(selection, credentials, transport);
        NativeRuntimeSupport.RequireEmbedding();
        if (!LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot))
            throw new CopilotException("本地 BGE-M3 尚未安装，请在设置 → 服务 → 知识库模型中下载。");
        return localEmbedding;
    }

    private static ListeningProvider CreateProvider(Speaker speaker, ListeningService service)
    {
        NativeRuntimeSupport.RequireSpeech();
        var provider = new LocalLiveProvider(speaker: speaker, contextual: service == ListeningService.Zipformer);
        return new(provider, terms => provider.UpdateTerms(terms), () => provider.Backend?.ToString());
    }

    private async void StartListening(object sender, RoutedEventArgs e)
    {
        if (session is null || closeRequested || viewModel.IsResetting) return;
        StartButton.IsEnabled = false;
        try { AppRuntime.RequireInteractive("音频采集"); await session.StartAsync(microphoneEnabled: viewModel.MicrophoneEnabled); }
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

    private async Task<bool> ResetSessionAsync()
    {
        if (session is null || closeRequested) return false;
        var reset = await session.ResetAsync();
        if (reset) { HostErrorText.Text = ""; smokeAnswer = null; }
        RefreshSession();
        return reset;
    }

    private void QueueRefresh()
    {
        // Coalesce worker notifications. Read the latest immutable snapshot on Dispatcher,
        // so queued updates cannot redraw an old session after a restart.
        if (Interlocked.Exchange(ref refreshQueued, 1) != 0) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            Interlocked.Exchange(ref refreshQueued, 0);
            if (!closeRequested) RefreshSession();
        });
    }

    private void RefreshSession()
    {
        if (session is null || closeRequested) return;
        var view = session.Snapshot;
        viewModel.UpdateSession(view, !closeRequested);
        Title = "LiveCopilot — " + view.Status;
        ErrorText.Text = view.Error ?? "";
        StateText.Text = view.State == ListeningState.Idle ? "就绪，可以输入问题或开始监听" : view.Status;
        SuggestionText.Text = view.SuggestionStatus ?? "";
        StartButton.IsEnabled = !viewModel.IsResetting && !AppRuntime.IsSmoke && !closeRequested && !view.IsStopping && view.State is not (ListeningState.Starting or ListeningState.Listening);
        StopButton.IsEnabled = !viewModel.IsResetting && !closeRequested && !view.IsStopping && (view.SuggestionIsLoading || view.State is (ListeningState.Starting or ListeningState.Listening));
        TranscriptLines.Children.Clear();
        foreach (var line in view.Lines)
            TranscriptLines.Children.Add(new TextBlock { Text = $"{(line.Speaker == Speaker.You ? "我" : line.Speaker == Speaker.Room ? "现场" : "对方")}  {line.Content}",
                FontSize = settings.TranscriptFontSize, Margin = new Thickness(0, 0, 0, 6) });
        TranscriptPlaceholder.Visibility = view.Lines.Count == 0 && view.PartialThem.Length == 0 && view.PartialYou.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        PartialThem.Text = view.PartialThem;
        PartialYou.Text = view.PartialYou;
        PartialThem.FontSize = PartialYou.FontSize = settings.TranscriptFontSize;
        AnswerText.Text = smokeAnswer ?? (view.SuggestionText.Length == 0 ? "在上方输入问题，或开始监听以获取回答。" : view.SuggestionText);
        AnswerText.FontSize = settings.AnswerFontSize;
        AnswerText.Foreground = (System.Windows.Media.Brush)FindResource(view.SuggestionText.Length == 0 && smokeAnswer is null ? "SecondaryInk" : "Ink");
        SourcesText.Text = new OverlayContent(view.Status, view.Lines) { Sources = view.Sources }.SourceText(settings.RetrievalCount);
        WarningText.Text = view.Warning ?? "";
        if (viewModel.FollowTranscript) TranscriptScroll.ScrollToEnd();
        viewModel.SetEnabled(!AppRuntime.IsSmoke && !view.IsStopping);
        RecapButton.Visibility = settings.RecapEnabled ? Visibility.Visible : Visibility.Collapsed;
        FollowUpButton.Visibility = settings.FollowUpEnabled ? Visibility.Visible : Visibility.Collapsed;
        ScenarioText.Text = settings.Scenario switch { ScenarioProfile.Meeting => "会议", ScenarioProfile.Defense => "学术答辩", _ => "面试" };
        ShortcutText.Text = hotkeyStore?.ToggleOverlay.ToString() ?? "";
        QueueAutoHeight();
    }

    partial void OpenFirstRun();
    partial void FocusActiveGuide(ref bool handled);
    partial void AddShutdownSteps(List<Func<Task>> steps);

    private bool SaveOverlaySettings(AppSettings value)
    {
        if (closeRequested) return false;
        try { value.Save(preferences); ApplySettings(value); return true; }
        catch (Exception) { HostErrorText.Text = "无法保存偏好，请检查本地目录权限。"; return false; }
    }
    private void RefreshProtection()
    {
        var result = protection.Apply(new WindowInteropHelper(this).Handle, settings.ExcludeOverlayFromCapture);
        if (result.ReturnValue == false) HostErrorText.Text = "Windows 未能应用共享隐藏，请在设置中检查捕获保护。";
    }
    private void ConfigureAppearance()
    {
        OverlayBorder.Background = (System.Windows.Media.Brush)FindResource(settings.Background == AppBackground.White ? "Surface" : settings.Background == AppBackground.Frosted ? "CardSurface" : "OverlaySurface");
        RefreshProtection();
        viewModel.Guide.Configure(hotkeyStore?.Combo(SuggestionMode.Reply).ToString() ?? "Ctrl+Alt+Space", hotkeyStore?.ToggleOverlay.ToString() ?? "Alt+H", settings.ExcludeOverlayFromCapture);
    }
    private void SetOverlayVisible(bool visible)
    {
        if (closeRequested) return;
        if (visible) { Show(); WindowState = WindowState.Normal; Activate(); RefreshProtection(); }
        else if (tray is not null) Hide();
        else WindowState = WindowState.Minimized;
        trayModel.SetVisible(visible);
    }
    private void HideOverlay(object sender, RoutedEventArgs e) => SetOverlayVisible(false);
    private void ExitApplication(object sender, RoutedEventArgs e) => Close();
    private void TogglePin(object sender, RoutedEventArgs e) => Topmost = !Topmost;
    private void DragHeader(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed) return;
        for (var target = e.OriginalSource as DependencyObject; target is not null; target = System.Windows.Media.VisualTreeHelper.GetParent(target))
            if (target is System.Windows.Controls.Primitives.ButtonBase) return;
        DragMove();
    }
    private void CollapseTranscript(object sender, RoutedEventArgs e)
    {
        transcriptCollapsed = !transcriptCollapsed;
        TranscriptScroll.Visibility = transcriptCollapsed ? Visibility.Collapsed : Visibility.Visible;
        CollapseGlyph.Text = transcriptCollapsed ? "\uE70D" : "\uE70E";
        CollapseLabel.Text = transcriptCollapsed ? "展开转写" : "折叠转写";
        AutomationProperties.SetName(CollapseButton, CollapseLabel.Text);
        RefreshSession();
    }
    private void RequestReply(object sender, RoutedEventArgs e) { if (!AppRuntime.IsSmoke && !closeRequested) session?.Request(SuggestionMode.Reply); }
    private void RequestRecap(object sender, RoutedEventArgs e) { if (!AppRuntime.IsSmoke && !closeRequested) session?.Request(SuggestionMode.Recap); }
    private void RequestFollowUp(object sender, RoutedEventArgs e) { if (!AppRuntime.IsSmoke && !closeRequested) session?.Request(SuggestionMode.FollowUp); }

    private void CloseSession(object? sender, CancelEventArgs e)
    {
        if (closeComplete) return;
        e.Cancel = true;
        trayModel.BeginShutdown();
        viewModel.SetEnabled(false);
        viewModel.UpdateSession(session?.Snapshot ?? new(), false);
        StartButton.IsEnabled = StopButton.IsEnabled = false;
        SettingsButton.IsEnabled = false;
        if (!closeRequested) SmokeDiagnostics.Event("main shutdown requested");
        _ = shutdown.RequestCloseAsync();
    }

    private Task StopSettingsAsync() => settingsWindow?.PrepareForShutdownAsync() ?? Task.CompletedTask;

    private async Task StopSessionAsync()
    {
        if (session is null) return;
        session.Changed -= QueueRefresh;
        await session.DisposeAsync();
        if (session.Snapshot.Error is not null)
            SmokeDiagnostics.Event("session shutdown reported an error");
    }

    private void CompleteClose()
    {
        foreach (var error in shutdown.Errors) SmokeDiagnostics.Exception("main shutdown cleanup", error);
        SmokeDiagnostics.Event("main shutdown cleanup complete; closing");
        Close();
    }
}
