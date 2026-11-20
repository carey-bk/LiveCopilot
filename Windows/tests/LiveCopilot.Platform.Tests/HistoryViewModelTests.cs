using System.IO;
using LiveCopilot.Platform.History;

namespace LiveCopilot.Platform.Tests;

public sealed class HistoryViewModelTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "history-vm-" + Guid.NewGuid());
    private static readonly DateTimeOffset At = new(2026, 11, 16, 1, 0, 0, TimeSpan.Zero);
    private SessionStore Store => new(root);
    private static SessionRecord Seed(SessionStore store, int day = 0) => store.SaveSnapshot(
        [new(new TranscriptLine(Speaker.Room, At.AddDays(day), "虚构转写"))], At.AddDays(day),
        [new(Guid.NewGuid(), Guid.NewGuid(), false, At.AddDays(day).AddSeconds(1), At.AddDays(day).AddSeconds(2), At.AddDays(day).AddSeconds(3),
            "虚构问题", "Synthetic ANSWER [S1]", "completed", null, null, [new(1, "fixture", "虚构参考.txt", 2, 0, "演示证据")], null)],
        At.AddDays(day).AddSeconds(65), scenario: ScenarioProfile.Meeting)!;

    [Fact]
    public void ListShowsNewestFirstTitleFallbackMetadataAndChronologicalDetail()
    {
        var store = Store; var old = Seed(store); var recent = Seed(store, 2); Seed(store, 1);
        store.Rename(recent.Id, "虚构会话标题");
        var model = new HistoryViewModel(store, new Dialogs(), new Dialogs());
        Assert.Equal([recent.Id, store.Sessions[1].Id, old.Id], model.Sessions.Select(r => r.Record.Id));
        Assert.Equal("虚构会话标题", model.Selected!.Title); Assert.Equal("3 条会话", model.CountLabel);
        Assert.Contains("2026-11-18", model.Selected.Metadata); Assert.Contains("1 分 5 秒", model.Selected.Metadata); Assert.Contains("会议", model.Selected.Metadata);
        Assert.Equal([SessionEventKind.Room, SessionEventKind.Question, SessionEventKind.Answer], model.Timeline.Select(e => e.Event.Kind));
        model.OpenCommand.Execute(null); Assert.True(model.ShowDetail); Assert.False(model.ShowList);
        Assert.Contains("[S1] 虚构参考.txt", model.Timeline[^1].Sources); Assert.Contains("演示证据", model.Timeline[^1].Sources);
        Assert.Equal("已完成", model.Timeline[^1].Status); Assert.Empty(model.AnswerNotice);
        model.BackCommand.Execute(null); Assert.True(model.ShowList);
    }

    [Theory]
    [InlineData("标题")] [InlineData("转写")] [InlineData("问题")] [InlineData("answer")]
    [InlineData("参考.txt")] [InlineData("演示证据")]
    public void SearchFiltersEveryHistoryContentField(string query)
    {
        var store = Store; var record = Seed(store); store.Rename(record.Id, "合成标题");
        store.SaveSnapshot([new(new TranscriptLine(Speaker.You, At, "unrelated"))], At, [], At);
        var model = new HistoryViewModel(store, new Dialogs(), new Dialogs()) { Query = query };
        Assert.Equal(record.Id, Assert.Single(model.Sessions).Record.Id);
        model.OpenCommand.Execute(null); model.Query = "no match";
        Assert.True(model.IsEmpty); Assert.Null(model.Selected); Assert.Empty(model.Timeline); Assert.True(model.ShowList);
        Assert.False(model.DeleteCommand.CanExecute(null)); Assert.False(model.ExportMarkdownCommand.CanExecute(null));
        Assert.Contains("没有找到", model.EmptyMessage); Assert.True(model.ClearCommand.CanExecute(null));
        model.Query = " "; Assert.Equal(2, model.Sessions.Count);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void DeleteRequiresConfirmationAndOnlyRemovesSelectedRecord(bool approved)
    {
        var store = Store; var kept = Seed(store); var selected = Seed(store, 1);
        var dialogs = new Dialogs { Approved = approved }; var model = new HistoryViewModel(store, dialogs, dialogs);
        model.OpenCommand.Execute(null); model.DeleteCommand.Execute(null);
        Assert.Contains(selected.Title, Assert.Single(dialogs.Confirmations).Message);
        Assert.Contains("删除", dialogs.Confirmations[0].Title);
        Assert.Equal(approved ? 1 : 2, Store.Sessions.Count);
        Assert.Contains(Store.Sessions, r => r.Id == kept.Id);
        Assert.Equal(!approved, model.ShowDetail);
        if (approved) Assert.Equal(kept.Id, model.Selected!.Record.Id);
        Assert.Empty(dialogs.Exports);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void ClearConfirmsAllRecordsEvenWhenSearchHasNoMatches(bool approved)
    {
        var store = Store; Seed(store); Seed(store, 1);
        File.WriteAllText(Path.Combine(root, "damaged.json"), "{");
        var dialogs = new Dialogs { Approved = approved }; var model = new HistoryViewModel(store, dialogs, dialogs) { Query = "no match" };
        model.ClearCommand.Execute(null);
        Assert.Contains("全部", Assert.Single(dialogs.Confirmations).Message);
        Assert.Equal(approved ? 0 : 2, Store.Sessions.Count);
        Assert.Equal(!approved, File.Exists(Path.Combine(root, "damaged.json")));
        Assert.Equal(!approved, model.ClearCommand.CanExecute(null));
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void ExportUsesInjectedPickerAndExplicitFormatWithoutMutatingHistory(bool markdown)
    {
        var store = Store; var original = Seed(store);
        var dialogs = new Dialogs { Path = Path.Combine(root, "export.chosen") }; var model = new HistoryViewModel(store, dialogs, dialogs);
        (markdown ? model.ExportMarkdownCommand : model.ExportTextCommand).Execute(null);
        var request = Assert.Single(dialogs.Exports);
        Assert.Equal(markdown, request.Markdown); Assert.EndsWith(markdown ? ".md" : ".txt", request.SuggestedFileName);
        Assert.Equal(original.Export(markdown), File.ReadAllText(dialogs.Path)); Assert.Contains("已导出", model.Status);
        Assert.Equal(original, Assert.Single(Store.Sessions)); Assert.Empty(dialogs.Confirmations);
    }

    [Fact]
    public void CancelledExportCreatesNoFileAndFailedExportReportsUsefulStatus()
    {
        var store = Store; Seed(store); var before = Directory.GetFiles(root).Length;
        var dialogs = new Dialogs(); var model = new HistoryViewModel(store, dialogs, dialogs);
        model.ExportMarkdownCommand.Execute(null);
        Assert.Equal(before, Directory.GetFiles(root).Length); Assert.Empty(model.Status);
        dialogs.Path = root; // A directory cannot be replaced by an export file.
        model.ExportTextCommand.Execute(null);
        Assert.Contains("导出失败", model.Status); Assert.Single(Store.Sessions);
    }

    [Fact]
    public void FailedDeleteKeepsSelectionAndReportsFailure()
    {
        var store = Store; var record = Seed(store);
        var path = Path.Combine(root, CoreJson.Id(record.Id) + ".json"); File.Delete(path); Directory.CreateDirectory(path);
        var dialogs = new Dialogs { Approved = true }; var model = new HistoryViewModel(store, dialogs, dialogs);
        model.DeleteCommand.Execute(null);
        Assert.Equal(record.Id, model.Selected!.Record.Id); Assert.Contains("未能", model.Status);
    }

    [Fact]
    public void RefreshReadsOtherWriterAndKeepsSelectionAndClearsStaleDetails()
    {
        var writer = Store; var first = Seed(writer); var reader = Store;
        var model = new HistoryViewModel(reader, new Dialogs(), new Dialogs()); model.OpenCommand.Execute(null);
        var second = Seed(writer, 1); model.RefreshCommand.Execute(null);
        Assert.Equal(2, model.Sessions.Count); Assert.Equal(first.Id, model.Selected!.Record.Id); Assert.True(model.ShowDetail);
        writer.Delete(first); writer.Delete(second); model.Refresh();
        Assert.True(model.IsEmpty); Assert.False(model.ShowDetail); Assert.Empty(model.Timeline);
    }

    [Fact]
    public void EmptyAndDamagedOnlyDirectoriesKeepSafeCommandStatesAndLoadNotice()
    {
        var dialogs = new Dialogs(); var model = new HistoryViewModel(Store, dialogs, dialogs);
        Assert.True(model.IsEmpty); Assert.Contains("还没有", model.EmptyMessage);
        Assert.False(model.OpenCommand.CanExecute(null)); Assert.False(model.ClearCommand.CanExecute(null));
        Assert.False(model.ExportTextCommand.CanExecute(null));
        Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "bad.json"), "{"); model.Refresh();
        Assert.True(model.IsEmpty); Assert.Contains("已跳过 1", model.LoadNotice); Assert.True(model.ClearCommand.CanExecute(null));
    }

    [Fact]
    public void LegacyDetailExplainsAbsentAnswersAndScenarioAndIdsAreStable()
    {
        var record = new SessionRecord(At, At.AddSeconds(20), [new(new TranscriptLine(Speaker.You, At, "首句预览"))]);
        Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "legacy.json"), CoreJson.Encode(record, session: true));
        var model = new HistoryViewModel(Store, new Dialogs(), new Dialogs());
        Assert.Equal("首句预览", model.Selected!.Title); Assert.Contains("未记录场景", model.Selected.Metadata);
        Assert.Contains("没有保存问答", model.AnswerNotice); Assert.Single(model.Timeline);
        var rowId = model.Selected.AutomationId; var eventId = model.Timeline[0].ContentId;
        model.Refresh(); Assert.Equal(rowId, model.Selected!.AutomationId); Assert.Equal(eventId, model.Timeline[0].ContentId);
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }

    private sealed class Dialogs : IHistoryConfirmationService, IHistoryFileDialogService
    {
        public bool Approved { get; init; }
        public string? Path { get; set; }
        public List<HistoryConfirmation> Confirmations { get; } = [];
        public List<HistoryExportRequest> Exports { get; } = [];
        public bool Confirm(HistoryConfirmation confirmation) { Confirmations.Add(confirmation); return Approved; }
        public string? SaveFile(HistoryExportRequest request) { Exports.Add(request); return Path; }
    }
}
