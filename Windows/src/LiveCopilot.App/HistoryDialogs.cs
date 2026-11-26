using System.Windows;
using LiveCopilot.Core;
using LiveCopilot.Platform.History;

namespace LiveCopilot.App;

internal sealed class HistoryDialogs(Window owner) : IHistoryConfirmationService, IHistoryFileDialogService
{
    public bool Confirm(HistoryConfirmation confirmation) => !AppRuntime.IsSmoke &&
        MessageBox.Show(owner, confirmation.Message, confirmation.Title, MessageBoxButton.YesNo,
            MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;

    public string? SaveFile(HistoryExportRequest request)
    {
        if (AppRuntime.IsSmoke) return null;
        var picker = new Microsoft.Win32.SaveFileDialog
        {
            Title = "导出会话", FileName = request.SuggestedFileName,
            DefaultExt = request.Markdown ? ".md" : ".txt", AddExtension = true, OverwritePrompt = true,
            Filter = request.Markdown ? "Markdown (*.md)|*.md" : "纯文本 (*.txt)|*.txt"
        };
        return picker.ShowDialog(owner) == true ? picker.FileName : null;
    }
}
