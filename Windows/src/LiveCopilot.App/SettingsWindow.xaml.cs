using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.History;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Lifecycle;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.App;

public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel viewModel;
    private void HistoryLoaded(object sender, RoutedEventArgs e) => History.Refresh();
    private void OpenOperationGuide(object sender, RoutedEventArgs e) => ShowOperationGuide();
    partial void ShowOperationGuide();
    private readonly KnowledgeIndex knowledge;
    private readonly Func<AppSettings, IEmbeddingProvider> createEmbedding;
    private readonly HotkeyManager hotkeys;
    private readonly LocalModelManager models = new();
    public HistoryViewModel History { get; }
    public ModelCardViewModel ZipformerModel { get; }
    public ModelCardViewModel ParaformerModel { get; }
    public ModelCardViewModel EmbeddingModelCard { get; }
    private int modelRefreshQueued;
    private readonly CancellationTokenSource knowledgeCancellation = new();
    private Task? knowledgeTask;
    private ShortcutEditor? recording;
    private readonly HashSet<PasswordBox> passwordBoxes = [];
    private readonly Dictionary<CredentialEditor, Action> resetHandlers = [];
    private readonly WindowShutdownCoordinator shutdown;
    private bool closeRequested => shutdown.IsRequested;
    private bool clearingPasswords;

    public SettingsWindow(SettingsViewModel viewModel, KnowledgeIndex knowledge,
        Func<AppSettings, IEmbeddingProvider> createEmbedding, HotkeyManager hotkeys)
    {
        this.viewModel = viewModel; this.knowledge = knowledge; this.createEmbedding = createEmbedding; this.hotkeys = hotkeys;
        ZipformerModel = new(LocalModelKind.TerminologySpeech, models);
        ParaformerModel = new(LocalModelKind.StreamingSpeech, models);
        EmbeddingModelCard = new(LocalModelKind.Embedding, models);
        var historyDialogs = new HistoryDialogs(this);
        History = new(new SessionStore(), historyDialogs, historyDialogs);
        InitializeComponent();
        WindowLayout.FitWorkArea(this);
        shutdown = new([
            () => { IsEnabled = false; StopRecording(); ClearPasswords(); return Task.CompletedTask; },
            () => knowledgeCancellation.CancelAsync(),
            () => models.DisposeAsync().AsTask(),
            async () => { if (knowledgeTask is not null) await knowledgeTask; },
            () => { viewModel.IsBusy = false; viewModel.Cancel(); return Task.CompletedTask; }
        ], action => Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, action), CompleteClose);
        SmokeDiagnostics.Event("settings InitializeComponent completed");
        DataContext = viewModel;
        InitializeOnboarding();
        viewModel.Saved += Saved;
        viewModel.Cancelled += Cancelled;
        models.Changed += ModelChanged;
        foreach (var credential in viewModel.Credentials)
        {
            Action reset = () => ClearPasswords(credential);
            resetHandlers.Add(credential, reset);
            credential.InputResetRequested += reset;
        }
        Loaded += (_, _) => { try { RefreshDocuments(); } catch (Exception) { KnowledgeMessageText.Text = "无法读取知识库，请检查本地目录权限。"; } };
        Loaded += (_, _) => SmokeDiagnostics.Event("settings loaded");
        PreviewKeyDown += CaptureShortcut;
        PreviewMouseDown += (_, _) => StopRecording();
        Deactivated += (_, _) => StopRecording();
        Pages.SelectionChanged += (_, e) => { if (e.OriginalSource == Pages) StopRecording(); };
        Closing += CloseSettings;
        Closed += (_, _) =>
        {
            var cleanup = PrepareForShutdownAsync();
            shutdown.NotifyClosed();
            viewModel.Saved -= Saved; viewModel.Cancelled -= Cancelled;
            models.Changed -= ModelChanged;
            foreach (var (credential, handler) in resetHandlers) credential.InputResetRequested -= handler;
            resetHandlers.Clear(); passwordBoxes.Clear();
            // Owned windows can be forcibly closed without Closing. Still drain their
            // document operation before releasing its cancellation source/shared services.
            _ = DisposeKnowledgeCancellationAsync(cleanup);
        };
    }

    partial void InitializeOnboarding();
    partial void ShowOnboarding();
    private void OpenOnboarding(object sender, RoutedEventArgs e) => ShowOnboarding();

    private void ModelChanged(LocalModelKind _)
    {
        if (Interlocked.Exchange(ref modelRefreshQueued, 1) != 0) return;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            Interlocked.Exchange(ref modelRefreshQueued, 0);
            if (closeRequested) return;
            ZipformerModel.Refresh(); ParaformerModel.Refresh(); EmbeddingModelCard.Refresh();
            viewModel.RefreshModelAvailability();
        });
    }

    private async void DownloadModel(object sender, RoutedEventArgs e)
    {
        if (closeRequested || sender is not Button { DataContext: ModelCardViewModel card } || !card.CanDownload) return;
        await models.RetryAsync(card.Kind);
    }
    private void CancelModel(object sender, RoutedEventArgs e)
    {
        if (!closeRequested && sender is Button { DataContext: ModelCardViewModel card }) models.Cancel(card.Kind);
    }
    private async void VerifyModel(object sender, RoutedEventArgs e)
    {
        if (closeRequested || sender is not Button { DataContext: ModelCardViewModel card } || !card.CanVerify) return;
        await models.VerifyAsync(card.Kind);
    }
    private async void DeleteModel(object sender, RoutedEventArgs e)
    {
        if (closeRequested || sender is not Button { DataContext: ModelCardViewModel card } || !card.CanDelete) return;
        await models.DeleteAsync(card.Kind);
    }

    private void CredentialChanged(object sender, RoutedEventArgs e)
    {
        if (!clearingPasswords && sender is PasswordBox { DataContext: CredentialEditor credential } box)
            credential.Stage(box.Password);
    }
    private void CredentialLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is PasswordBox box) passwordBoxes.Add(box);
    }
    private void ClearPasswords(CredentialEditor? credential = null)
    {
        clearingPasswords = true;
        try
        {
            foreach (var box in passwordBoxes)
                if (credential is null || ReferenceEquals(box.DataContext, credential)) box.Clear();
        }
        finally { clearingPasswords = false; }
    }
    private void Saved(AppSettings _) { StopRecording(); ClearPasswords(); }
    private void Cancelled() { if (!closeRequested) Close(); }

    private void RecordShortcut(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: ShortcutEditor shortcut } button) return;
        StopRecording(); recording = shortcut;
        hotkeys.SetRecording(true); button.Focus();
        RecordingText.Text = "正在录制“" + shortcut.Label + "”：请按组合键（Esc 取消）。";
    }
    private void CaptureShortcut(object sender, KeyEventArgs e)
    {
        if (recording is null) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        if (key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None) { StopRecording(); return; }
        var modifiers = HotkeyModifiers.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= HotkeyModifiers.Control;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= HotkeyModifiers.Alt;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= HotkeyModifiers.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) modifiers |= HotkeyModifiers.Windows;
        viewModel.RecordShortcut(recording, new((uint)KeyInterop.VirtualKeyFromKey(key), modifiers));
        StopRecording();
    }
    private void StopRecording()
    {
        if (recording is null) return;
        recording = null; RecordingText.Text = ""; hotkeys.SetRecording(false);
    }
    private void OpenProject(object sender, RoutedEventArgs e)
    {
        if (AppRuntime.IsSmoke) return;
        try { Process.Start(new ProcessStartInfo(viewModel.ProjectUrl) { UseShellExecute = true }); }
        catch (Exception) { MessageBox.Show(this, "无法打开浏览器，请复制项目地址。", "LiveCopilot"); }
    }
    private async void CheckUpdates(object sender, RoutedEventArgs e)
    {
        var status = await viewModel.CheckUpdatesAsync();
        UpdateStatusText.Text = status == LiveCopilot.Platform.Updates.UpdateCheckStatus.Disabled
            ? "更新检查已关闭。" : "更新源尚未配置，未发送网络请求。";
    }
    private bool CanOperateDocuments()
    {
        if (closeRequested || viewModel.IsBusy) return false;
        if (!viewModel.HasChanges && !viewModel.HasErrors) return true;
        KnowledgeMessageText.Text = "请先保存设置，再导入、删除或重新索引文档。";
        return false;
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
        if (!CanOperateDocuments()) return;
        var picker = new Microsoft.Win32.OpenFileDialog { Multiselect = true, CheckFileExists = true,
            Filter = "支持的文档|*.pdf;*.md;*.markdown;*.txt;*.docx", Title = "导入知识库文档" };
        if (picker.ShowDialog(this) != true) return;
        var selectedFiles = picker.FileNames;
        await RunKnowledgeOperation(async token =>
        {
            // Validate the whole batch before any indexing or provider call.
            var files = DocumentImport.Validate(selectedFiles);
            var provider = createEmbedding(viewModel.Snapshot());
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
            await knowledge.ReindexAsync(row.Document, createEmbedding(viewModel.Snapshot()),
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
        if (!CanOperateDocuments()) return;
        viewModel.IsBusy = true;

        KnowledgeProgress.Value = 0;
        KnowledgeMessageText.Text = "正在处理文档…";
        try
        {
            var token = knowledgeCancellation.Token;
            knowledgeTask = Task.Run(() => operation(token));
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
            viewModel.IsBusy = false;

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

    internal Task PrepareForShutdownAsync() => shutdown.RequestCloseAsync();

    private async Task DisposeKnowledgeCancellationAsync(Task cleanup)
    {
        await cleanup;
        knowledgeCancellation.Dispose();
    }

    private void CompleteClose()
    {
        foreach (var error in shutdown.Errors)
            if (error is not OperationCanceledException) SmokeDiagnostics.Exception("settings shutdown cleanup", error);
        Close();
    }

    private void CloseSettings(object? sender, CancelEventArgs e)
    {
        if (shutdown.IsClosing || shutdown.IsClosed) return;
        e.Cancel = true;
        _ = PrepareForShutdownAsync();
    }
}
