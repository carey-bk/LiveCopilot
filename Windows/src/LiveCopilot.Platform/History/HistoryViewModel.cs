using System.Globalization;
using LiveCopilot.Core;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.History;

public sealed record HistoryConfirmation(string Title, string Message);
public interface IHistoryConfirmationService
{
    bool Confirm(HistoryConfirmation confirmation);
}
public sealed record HistoryExportRequest(string SuggestedFileName, bool Markdown);
public interface IHistoryFileDialogService
{
    string? SaveFile(HistoryExportRequest request);
}

/// Owns a separate UI-thread store; reload reads atomic snapshots written by ListeningSession.
/// No WPF or dialogs are required to exercise any history operation.
public sealed class HistoryViewModel : ObservableObject
{
    private readonly SessionStore store;
    private readonly IHistoryConfirmationService confirmation;
    private readonly IHistoryFileDialogService files;
    private string query = "", status = "";
    private HistorySessionRow? selected;
    private bool detail;
    public IReadOnlyList<HistorySessionRow> Sessions { get; private set; } = [];
    public IReadOnlyList<HistoryEventRow> Timeline { get; private set; } = [];
    public string Query
    {
        get => query;
        set { if (query == value) return; query = value; Notify(); ShowDetail = false; Filter(); }
    }
    public HistorySessionRow? Selected
    {
        get => selected;
        set
        {
            selected = value;
            Timeline = (value?.Record.Timeline ?? []).Select(e => new HistoryEventRow(e)).ToArray();
            Notify(); Notify(nameof(Timeline)); Notify(nameof(AnswerNotice));
            if (value is null) ShowDetail = false;
            RefreshCommands();
        }
    }
    public bool ShowDetail { get => detail; private set { detail = value; Notify(); Notify(nameof(ShowList)); } }
    public bool ShowList => !ShowDetail;
    public bool IsEmpty => Sessions.Count == 0;
    public string EmptyMessage => string.IsNullOrWhiteSpace(Query) ? "还没有会话。结束聆听或重置后，可在这里回看已保存的内容。" : "没有找到相关会话，请尝试其他标题、转写、问题或回答关键词。";
    public string CountLabel => $"{Sessions.Count} 条会话";
    public string Status { get => status; private set { status = value; Notify(); } }
    public string LoadNotice => store.LoadIssues.Count > 0 ? $"已跳过 {store.LoadIssues.Count} 个无法读取或版本不受支持的文件，诊断已记录。" : "";
    public string AnswerNotice => Selected?.Record.Answers is not { Count: > 0 } ? "这条记录仅包含转写，没有保存问答。" : "";
    public RelayCommand RefreshCommand { get; }
    public RelayCommand OpenCommand { get; }
    public RelayCommand BackCommand { get; }
    public RelayCommand DeleteCommand { get; }
    public RelayCommand ClearCommand { get; }
    public RelayCommand ExportMarkdownCommand { get; }
    public RelayCommand ExportTextCommand { get; }

    public HistoryViewModel(SessionStore store, IHistoryConfirmationService confirmation, IHistoryFileDialogService files)
    {
        this.store = store; this.confirmation = confirmation; this.files = files;
        RefreshCommand = new(Refresh);
        OpenCommand = new(() => ShowDetail = true, () => Selected is not null);
        BackCommand = new(() => ShowDetail = false);
        DeleteCommand = new(Delete, () => Selected is not null);
        ClearCommand = new(Clear, () => store.HasFiles);
        ExportMarkdownCommand = new(() => Export(true), () => Selected is not null);
        ExportTextCommand = new(() => Export(false), () => Selected is not null);
        Filter();
    }
    public void Refresh()
    {
        store.Reload(); Filter();
        Status = store.LastError is null ? "" : "无法完整读取历史记录，请检查本地目录权限。";
    }
    private void Filter()
    {
        var id = Selected?.Record.Id;
        Sessions = store.Sessions.Where(s => s.Matches(Query)).OrderByDescending(s => s.StartedAt)
            .Select(s => new HistorySessionRow(s)).ToArray();
        Notify(nameof(Sessions));
        Selected = Sessions.FirstOrDefault(s => s.Record.Id == id) ?? Sessions.FirstOrDefault();
        Notify(nameof(IsEmpty)); Notify(nameof(EmptyMessage)); Notify(nameof(CountLabel)); Notify(nameof(LoadNotice));
        RefreshCommands();
    }
    private void RefreshCommands()
    {
        OpenCommand.Refresh(); DeleteCommand.Refresh(); ClearCommand.Refresh(); ExportMarkdownCommand.Refresh(); ExportTextCommand.Refresh();
    }
    private void Delete()
    {
        if (Selected is not { } row || !confirmation.Confirm(new("删除这条会话？", $"将永久删除“{row.Title}”的本地转写、问答和引用，以及转写副本。此操作无法撤销。"))) return;
        var success = store.Delete(row.Record);
        ShowDetail = false; Filter();
        Status = success ? "会话已删除。" : "未能完整删除会话，请检查本地目录权限后重试。";
    }
    private void Clear()
    {
        if (!confirmation.Confirm(new("清空全部历史记录？", "将永久删除全部本地会话、问答、引用和转写副本，包括无法读取或版本不受支持的历史文件。已导出到其他目录的文件不受影响。此操作无法撤销。"))) return;
        var success = store.Clear();
        ShowDetail = false; Filter();
        Status = success ? "历史记录已清空。" : "部分历史记录未能删除，请检查本地目录权限后重试。";
    }
    private void Export(bool markdown)
    {
        if (Selected is not { } row) return;
        try
        {
            var path = files.SaveFile(new(Path.ChangeExtension(row.Record.ExportFilename, markdown ? ".md" : ".txt"), markdown));
            if (path is null) return;
            store.Export(row.Record, path, markdown);
            Status = "会话已导出。";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        { Status = "导出失败，请检查目标文件及目录权限后重试。"; }
    }
}

public sealed record HistorySessionRow(SessionRecord Record)
{
    public string AutomationId => "HistorySession-" + CoreJson.Id(Record.Id);
    public string TitleId => AutomationId + "-Title";
    public string MetadataId => AutomationId + "-Metadata";
    public string Title => Record.Title;
    public string DateLabel => Record.StartedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.CurrentCulture);
    public string DurationLabel => Record.Duration >= 60 ? $"{(long)Record.Duration / 60} 分 {(long)Record.Duration % 60} 秒" : $"{(long)Record.Duration} 秒";
    public string ScenarioLabel => Record.Scenario switch { ScenarioProfile.Interview => "面试", ScenarioProfile.Meeting => "会议", ScenarioProfile.Defense => "学术答辩", _ => "未记录场景" };
    public string Metadata => $"{DateLabel}  ·  {DurationLabel}  ·  {ScenarioLabel}";
}
public sealed record HistoryEventRow(SessionEvent Event)
{
    public string AutomationId => "HistoryEvent-" + Event.Id;
    public string ContentId => AutomationId + "-Content";
    public string HeadingId => AutomationId + "-Heading";
    public string StatusId => AutomationId + "-Status";
    public string SourcesId => AutomationId + "-Sources";
    public string Heading => Event.Role(false) + "  ·  " + Event.At.ToLocalTime().ToString("HH:mm:ss", CultureInfo.CurrentCulture);
    public string Content => Event.Content;
    public string Status => Event.Kind != SessionEventKind.Answer || Event.Answer is not { } answer ? "" : string.Join("\n",
        new[] { answer.State switch { "completed" => "已完成", "failed" => "回答失败", "interrupted" => "回答已中断", _ => "保存时尚未完成" }, answer.Warning, answer.Error }.Where(s => !string.IsNullOrEmpty(s)));
    public string Sources => Event.Kind != SessionEventKind.Answer || Event.Answer is not { } answer ? "" :
        string.Join("\n\n", answer.Sources.Select(s => s.Label + "\n" + s.Excerpt));
    public bool HasSources => Sources.Length > 0;
}
