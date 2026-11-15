using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LiveCopilot.Core;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Knowledge;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.App;

public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel viewModel;
    private readonly KnowledgeIndex knowledge;
    private readonly Func<AppSettings, IEmbeddingProvider> createEmbedding;
    private readonly HotkeyManager hotkeys;
    private readonly CancellationTokenSource knowledgeCancellation = new();
    private Task? knowledgeTask;
    private ShortcutEditor? recording;
    private readonly HashSet<PasswordBox> passwordBoxes = [];
    private readonly Dictionary<CredentialEditor, Action> resetHandlers = [];
    private bool closeRequested, closeComplete, clearingPasswords;

    public SettingsWindow(SettingsViewModel viewModel, KnowledgeIndex knowledge,
        Func<AppSettings, IEmbeddingProvider> createEmbedding, HotkeyManager hotkeys)
    {
        this.viewModel = viewModel; this.knowledge = knowledge; this.createEmbedding = createEmbedding; this.hotkeys = hotkeys;
        InitializeComponent();
        DataContext = viewModel;
        viewModel.Saved += Saved;
        viewModel.Cancelled += Cancelled;
        foreach (var credential in viewModel.Credentials)
        {
            Action reset = () => ClearPasswords(credential);
            resetHandlers.Add(credential, reset);
            credential.InputResetRequested += reset;
        }
        Loaded += (_, _) => { try { RefreshDocuments(); } catch (Exception) { KnowledgeMessageText.Text = "无法读取知识库，请检查本地目录权限。"; } };
        PreviewKeyDown += CaptureShortcut;
        PreviewMouseDown += (_, _) => StopRecording();
        Deactivated += (_, _) => StopRecording();
        Pages.SelectionChanged += (_, e) => { if (e.OriginalSource == Pages) StopRecording(); };
        Closing += CloseSettings;
        Closed += (_, _) =>
        {
            viewModel.Saved -= Saved; viewModel.Cancelled -= Cancelled;
            foreach (var (credential, handler) in resetHandlers) credential.InputResetRequested -= handler;
            resetHandlers.Clear(); passwordBoxes.Clear();
            knowledgeCancellation.Dispose();
        };
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
        try { Process.Start(new ProcessStartInfo(viewModel.ProjectUrl) { UseShellExecute = true }); }
        catch (Exception) { MessageBox.Show(this, "无法打开浏览器，请复制项目地址。", "LiveCopilot"); }
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

    private async void CloseSettings(object? sender, CancelEventArgs e)
    {
        if (closeComplete) return;
        e.Cancel = true;
        if (closeRequested) return;
        closeRequested = true; StopRecording(); ClearPasswords();
        await knowledgeCancellation.CancelAsync();
        if (knowledgeTask is not null)
        {
            try { await knowledgeTask; }
            catch (Exception) { /* The operation reports its own sanitized status. */ }
        }
        viewModel.IsBusy = false;
        viewModel.Cancel();
        closeComplete = true; _ = Dispatcher.BeginInvoke(Close);
    }
}
