using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Sessions;
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
    private readonly CancellationTokenSource knowledgeCancellation = new();
    private Task? knowledgeTask;
    private bool knowledgeBusy, settingsReady;
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
                reasoningFactory: () => ReasoningProviderFactory.Make(settings, credentials, transport),
                knowledgeRetriever: knowledge, embeddingFactory: CreateEmbedding);
            session.Changed += QueueRefresh;
            overlay = new OverlayWindow(settings);
            overlay.Show();
            hotkeys = new HotkeyManager(new HotkeyStore(preferences), new Win32HotkeyRegistrar(),
                session.Request, overlay.ToggleVisibility, error => HostErrorText.Text = error);
            hotkeys.SetEnabledModes(settings.EnabledSuggestionModes);
            RefreshSession(); // Construction and Loaded never start audio or inference.
            CredentialServiceText.Text = "分析服务 API 密钥 · " + settings.ReasoningService.Label();
            RefreshCredentialStatus();
            SharedKeyPanel.Visibility = settings.ReasoningService == ReasoningService.SharedOpenAI ? Visibility.Collapsed : Visibility.Visible;
            KnowledgeModeBox.SelectedIndex = settings.KnowledgeMode switch { KnowledgeMode.General => 0, KnowledgeMode.Hybrid => 1, _ => 2 };
            EmbeddingServiceBox.SelectedIndex = settings.EmbeddingService == EmbeddingService.OpenAI ? 0 : 1;
            settingsReady = true;
            RefreshEmbeddingSelection();
            RefreshDocuments();
        }
        catch (Exception error) { HostErrorText.Text = "初始化失败：" + error.Message; }
    }

    private IEmbeddingProvider CreateEmbedding(AppSettings selection)
    {
        if (selection.EmbeddingService == EmbeddingService.OpenAI)
            return OpenAIEmbeddingProvider.FromCredentials(selection, credentials, transport);
        if (!LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot))
            throw new CopilotException("本地 BGE-M3 尚未安装，请先下载并安装模型；此界面不提供下载。");
        return localEmbedding;
    }

    private void KnowledgeSettingsChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!settingsReady || closeRequested || knowledgeBusy) return;
        var updated = settings with
        {
            KnowledgeMode = KnowledgeModeBox.SelectedIndex switch { 0 => KnowledgeMode.General, 1 => KnowledgeMode.Hybrid, _ => KnowledgeMode.KnowledgeBaseOnly },
            EmbeddingService = EmbeddingServiceBox.SelectedIndex == 0 ? EmbeddingService.OpenAI : EmbeddingService.Local
        };
        try
        {
            updated.Save(preferences);
            settings = updated;
            session?.ConfigureKnowledge(settings);
            overlay?.Configure(settings);
            RefreshEmbeddingSelection();
        }
        catch (Exception)
        {
            settingsReady = false;
            KnowledgeModeBox.SelectedIndex = settings.KnowledgeMode switch { KnowledgeMode.General => 0, KnowledgeMode.Hybrid => 1, _ => 2 };
            EmbeddingServiceBox.SelectedIndex = settings.EmbeddingService == EmbeddingService.OpenAI ? 0 : 1;
            settingsReady = true;
            KnowledgeMessageText.Text = "设置保存失败，请检查本地目录权限。";
        }
    }

    private void RefreshEmbeddingSelection()
    {
        EmbeddingModelText.Text = "当前模型：" + settings.SelectedEmbeddingIdentity;
        KnowledgeMessageText.Text = settings.EmbeddingService == EmbeddingService.Local &&
            !LocalModels.Get(LocalModelKind.Embedding).IsInstalled(LocalModels.DefaultRoot)
            ? "本地 BGE-M3 尚未安装，请先下载并安装模型；此界面不提供下载。已有文档仍可用关键词检索。"
            : "切换 embedding 模型后，可重新索引已有文档以启用对应模型的语义检索。";
    }

    private void SaveSharedApiKey(object sender, RoutedEventArgs e)
    {
        try { credentials.Save(CredentialReference.Live, SharedApiKeyBox.Password); KnowledgeMessageText.Text = "共享 OpenAI 密钥已保存。"; }
        catch (Exception) { KnowledgeMessageText.Text = "共享 OpenAI 密钥保存失败，请检查凭据管理器。"; }
        finally { SharedApiKeyBox.Clear(); }
    }

    private void ClearSharedApiKey(object sender, RoutedEventArgs e)
    {
        SharedApiKeyBox.Clear();
        try { credentials.Clear(CredentialReference.Live); KnowledgeMessageText.Text = "共享 OpenAI 密钥已清除。"; }
        catch (Exception) { KnowledgeMessageText.Text = "共享 OpenAI 密钥清除失败，请检查凭据管理器。"; }
    }

    private void RefreshDocuments()
    {
        if (closeRequested) return;
        var selected = (DocumentsList.SelectedItem as DocumentRow)?.Document.Id;
        var rows = knowledge.Documents().Select(d => new DocumentRow(d)).ToArray();
        DocumentsList.ItemsSource = rows;
        DocumentsList.SelectedItem = rows.FirstOrDefault(r => r.Document.Id == selected);
    }

    private async void ImportDocuments(object sender, RoutedEventArgs e)
    {
        if (knowledgeBusy || closeRequested) return;
        var picker = new Microsoft.Win32.OpenFileDialog { Multiselect = true, CheckFileExists = true,
            Filter = "支持的文档|*.pdf;*.md;*.markdown;*.txt;*.docx", Title = "导入知识库文档" };
        if (picker.ShowDialog(this) != true) return;
        var selectedFiles = picker.FileNames;
        await RunKnowledgeOperation(async token =>
        {
            // Validate the whole batch before any indexing or provider call.
            var files = DocumentImport.Validate(selectedFiles);
            var provider = CreateEmbedding(settings with { });
            for (var i = 0; i < files.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                var file = files[i]; var ordinal = i;
                await knowledge.ImportDocumentAsync(file, provider, (_, fraction) => KnowledgeProgressAsync(
                    $"正在导入 {ordinal + 1}/{files.Count}：{System.IO.Path.GetFileName(file)}", (ordinal + fraction) / files.Count), token);
            }
        }, "文档导入完成。");
    }

    private async void ReindexDocument(object sender, RoutedEventArgs e)
    {
        if (DocumentsList.SelectedItem is not DocumentRow row) { KnowledgeMessageText.Text = "请先选择文档。"; return; }
        await RunKnowledgeOperation(async token =>
            await knowledge.ReindexAsync(row.Document, CreateEmbedding(settings with { }),
                (_, fraction) => KnowledgeProgressAsync("正在重新索引：" + row.Name, fraction), token), "重新索引完成。");
    }

    private async void DeleteDocument(object sender, RoutedEventArgs e)
    {
        if (DocumentsList.SelectedItem is not DocumentRow row) { KnowledgeMessageText.Text = "请先选择文档。"; return; }
        await RunKnowledgeOperation(_ => { knowledge.Delete(row.Document.Id); return Task.CompletedTask; }, "文档已从知识库删除，外部原文件不受影响。");
    }

    private async Task KnowledgeProgressAsync(string message, double fraction)
    {
        await Dispatcher.InvokeAsync(() =>
        {
            if (closeRequested) return;
            KnowledgeMessageText.Text = $"{message}（{fraction:P0}）";
            KnowledgeProgress.Value = fraction * 100;
            RefreshDocuments();
        });
    }

    private async Task RunKnowledgeOperation(Func<CancellationToken, Task> operation, string completed)
    {
        if (knowledgeBusy || closeRequested) return;
        knowledgeBusy = true;
        KnowledgeActionsPanel.IsEnabled = KnowledgeSettingsPanel.IsEnabled = false;
        KnowledgeProgress.Value = 0;
        KnowledgeMessageText.Text = "正在处理文档…";
        try
        {
            knowledgeTask = Task.Run(() => operation(knowledgeCancellation.Token));
            await knowledgeTask;
            KnowledgeProgress.Value = 100;
            KnowledgeMessageText.Text = completed;
        }
        catch (OperationCanceledException) { KnowledgeMessageText.Text = "文档操作已取消。"; }
        catch (Exception error)
        {
            KnowledgeMessageText.Text = error is CopilotException or ServiceHTTPFailure ? error.Message
                : "文档操作失败，请检查文件、模型和本地目录权限后重试。";
        }
        finally
        {
            knowledgeBusy = false;
            KnowledgeActionsPanel.IsEnabled = KnowledgeSettingsPanel.IsEnabled = !closeRequested;
            try { RefreshDocuments(); }
            catch (Exception) { KnowledgeMessageText.Text = "无法读取知识库，请检查本地目录权限和磁盘空间。"; }
        }
    }

    private sealed record DocumentRow(KnowledgeDocument Document)
    {
        public string Name => Document.Name;
        public int ChunkCount => Document.ChunkCount;
        public string EmbeddingModel => Document.EmbeddingModel;
        public string StatusLabel => Document.Status switch { "Ready" => "已就绪", "Indexing" => "正在索引", "Ready (re-index failed)" => "重建失败（保留旧索引）", _ => "失败，请重新索引" };
    }

    private void RefreshCredentialStatus()
    {
        try { CredentialStatusText.Text = string.IsNullOrWhiteSpace(credentials.Read(settings.AnalysisCredentialReference())) ? "未保存" : "已保存"; }
        catch (Exception error) { CredentialStatusText.Text = "读取失败"; HostErrorText.Text = error.Message; }
    }

    private void SaveApiKey(object sender, RoutedEventArgs e)
    {
        try { credentials.Save(settings.AnalysisCredentialReference(), ApiKeyBox.Password); HostErrorText.Text = ""; RefreshCredentialStatus(); }
        catch (Exception error) { HostErrorText.Text = error.Message; }
        finally { ApiKeyBox.Clear(); }
    }

    private void ClearApiKey(object sender, RoutedEventArgs e)
    {
        ApiKeyBox.Clear();
        try { credentials.Clear(settings.AnalysisCredentialReference()); HostErrorText.Text = ""; RefreshCredentialStatus(); }
        catch (Exception error) { HostErrorText.Text = error.Message; }
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
        KnowledgeActionsPanel.IsEnabled = KnowledgeSettingsPanel.IsEnabled = false;
        await knowledgeCancellation.CancelAsync();
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
            if (knowledgeTask is not null)
            {
                try { await knowledgeTask; }
                catch (Exception) { /* The document operation already exposes a safe UI error. */ }
            }
            await localEmbedding.DisposeAsync();
            knowledge.Dispose();
            knowledgeCancellation.Dispose();
            if (session is not null) session.Changed -= QueueRefresh;
            hotkeys?.Dispose();
            transport.Dispose();
            overlay?.Close();
            closeComplete = true;
            Close();
        }
    }
}
