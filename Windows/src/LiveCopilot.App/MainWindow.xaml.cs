using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Sessions;
using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Windows.Audio;
using LiveCopilot.Platform.Windows.Credentials;
using LiveCopilot.Platform.Windows.Hotkeys;
using LiveCopilot.Platform.Windows.Overlay;

namespace LiveCopilot.App;

public partial class MainWindow : Window
{
    private OverlayWindow? overlay;
    private HotkeyManager? hotkeys;
    private ListeningSession? session;
    private AppSettings settings = new();
    private readonly ICredentialStore credentials = new WindowsCredentialStore();
    private readonly HttpClientTransport transport = new();
    private readonly FilePreferenceStore preferences = new();
    private readonly LocalEmbeddingProvider localEmbedding = new();
    private readonly KnowledgeIndex knowledge = new(System.IO.Path.Combine(AppPaths.DataDirectory, "Knowledge"), new DocumentParser());
    private HotkeyStore? hotkeyStore;
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
            settings = AppSettings.Load(preferences);
            session = new(new WasapiAudioSourceFactory(), CreateProvider, settings,
                new TranscriptStore(), new SessionStore(),
                configuredReasoningFactory: selection => ReasoningProviderFactory.Make(selection, credentials, transport),
                knowledgeRetriever: knowledge, embeddingFactory: CreateEmbedding);
            session.Changed += QueueRefresh;
            overlay = new OverlayWindow(settings);
            overlay.Show();
            hotkeyStore = new HotkeyStore(preferences);
            hotkeys = new HotkeyManager(hotkeyStore, new Win32HotkeyRegistrar(),
                session.Request, overlay.ToggleVisibility, error => HostErrorText.Text = "快捷键注册失败，请在设置中更换被占用的组合。\n" + error);
            hotkeys.SetEnabledModes(settings.EnabledSuggestionModes);
            RefreshSession(); // Construction and Loaded never start audio or inference.
            SettingsButton.IsEnabled = true;
        }
        catch (Exception error) { HostErrorText.Text = "初始化失败：" + error.Message; }
    }

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        if (closeRequested || hotkeyStore is null || hotkeys is null) return;
        var viewModel = new SettingsViewModel(preferences, credentials, hotkeyStore,
            service => service is ListeningService.Zipformer or ListeningService.Paraformer &&
                LocalModels.Get(service == ListeningService.Zipformer ? LocalModelKind.TerminologySpeech : LocalModelKind.StreamingSpeech).IsInstalled(LocalModels.DefaultRoot),
            () => LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot), typeof(MainWindow).Assembly);
        viewModel.Saved += ApplySettings;
        try { new SettingsWindow(viewModel, knowledge, CreateEmbedding, hotkeys) { Owner = this }.ShowDialog(); }
        finally { viewModel.Saved -= ApplySettings; }
    }

    private void ApplySettings(AppSettings value)
    {
        settings = value with { };
        session?.Configure(settings);
        overlay?.Configure(settings);
        hotkeys?.SetEnabledModes(settings.EnabledSuggestionModes);
        RefreshSession(); // Re-render existing text immediately with the saved font sizes.
    }

    private IEmbeddingProvider CreateEmbedding(AppSettings selection)
    {
        if (selection.EmbeddingService == EmbeddingService.OpenAI)
            return OpenAIEmbeddingProvider.FromCredentials(selection, credentials, transport);
        if (!LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot))
            throw new CopilotException("本地 BGE-M3 尚未安装，请先下载并安装模型；此界面不提供下载。");
        return localEmbedding;
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
        StopButton.IsEnabled = !closeRequested && !view.IsStopping && (view.SuggestionIsLoading || view.State is (ListeningState.Starting or ListeningState.Listening));
        overlay?.SetContent(new(view.Status + (view.Error is null ? "" : "\n" + view.Error),
            view.Lines, view.PartialThem, view.PartialYou, view.SuggestionStatus, view.SuggestionText)
            { Sources = view.Sources, Warning = view.Warning });
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
        SettingsButton.IsEnabled = false;
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
            await localEmbedding.DisposeAsync();
            knowledge.Dispose();
            if (session is not null) session.Changed -= QueueRefresh;
            hotkeys?.Dispose();
            transport.Dispose();
            overlay?.Close();
            closeComplete = true;
            Close();
        }
    }
}
