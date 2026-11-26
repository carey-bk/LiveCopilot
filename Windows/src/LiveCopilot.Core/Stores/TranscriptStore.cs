namespace LiveCopilot.Core;

public sealed record TranscriptLine(Guid Id, Speaker Speaker, DateTimeOffset At, string Content)
{
    public TranscriptLine(Speaker speaker, DateTimeOffset at, string content) : this(Guid.NewGuid(), speaker, at, content) { }
    public string Clock => At.ToLocalTime().ToString("HH:mm", CultureInfo.CurrentCulture);
}
public sealed class TranscriptStore : ObservableStore
{
    private readonly List<TranscriptLine> archivedLines = [];
    private readonly List<TranscriptFragment> fragmentRevisions = [];
    private readonly Dictionary<Speaker, int> lastFragmentEnd = [];
    private readonly Dictionary<Guid, List<TranscriptFragment>> fragmentsByLine = [];
    private readonly Dictionary<string, Guid> fragmentLine = [];
    private (Guid Id, string Text, DateTimeOffset At)? protectedPreview;
    public ValueList<TranscriptLine> Lines { get; private set; } = [];
    public IReadOnlyList<TranscriptLine> ArchivedLines => archivedLines.AsReadOnly();
    public IReadOnlyList<TranscriptFragment> FragmentRevisions => fragmentRevisions.AsReadOnly();
    public string PartialThem { get; private set; } = "";
    public string PartialYou { get; private set; } = "";
    public bool HasContent => Lines.Count > 0 || PartialThem.Length > 0 || PartialYou.Length > 0;
    public ValueList<SessionLine> ArchiveSnapshot(DateTimeOffset since) => archivedLines.Where(l => l.At >= since)
        .Select(l => new SessionLine(l, fragmentsByLine.GetValueOrDefault(l.Id)?.Select(f => f.Id).ToValueList() ?? [])).ToValueList();
    public void SetPartial(string text, Speaker speaker) { if (speaker == Speaker.You) PartialYou = text; else PartialThem = text; Changed(); }
    public void AppendDelta(string delta, Speaker speaker) => SetPartial((speaker == Speaker.You ? PartialYou : PartialThem) + delta, speaker);
    public void ClearPartial(Speaker speaker) => SetPartial("", speaker);
    public void CommitPartial(Speaker speaker, DateTimeOffset? now = null)
    { var text = speaker == Speaker.You ? PartialYou : PartialThem; ClearPartial(speaker); Commit(text, speaker, now); }
    public void Commit(string line, Speaker speaker, DateTimeOffset? now = null)
    {
        var text = line.Trim(); if (text.Length == 0) return;
        archivedLines.Add(new(speaker, now ?? DateTimeOffset.UtcNow, text)); Refresh();
    }
    public void PreserveOwnPreview(string text, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow; var value = text.Trim(); if (value.Length == 0) return;
        if (protectedPreview is { } saved && (at - saved.At).TotalSeconds < 12 && value.StartsWith(saved.Text, StringComparison.Ordinal) && archivedLines.FindIndex(l => l.Id == saved.Id) is var index && index >= 0)
        {
            archivedLines[index] = new(saved.Id, Speaker.You, saved.At, value);
            protectedPreview = (saved.Id, value, at); Refresh(); ClearPartial(Speaker.You); return;
        }
        Commit(value, Speaker.You, at);
        protectedPreview = (archivedLines[^1].Id, value, at); ClearPartial(Speaker.You);
    }
    public string RecentContext(DateTimeOffset? now = null)
    {
        var cutoff = (now ?? DateTimeOffset.UtcNow).AddSeconds(-AppPaths.SuggestionContextWindowSeconds);
        var recent = Lines.Where(l => l.At >= cutoff).ToArray();
        return string.Join("\n", (recent.Length == 0 ? Lines.TakeLast(4) : recent).Select(l => l.Speaker.RawValue() + ": " + l.Content));
    }
    public void Ingest(TranscriptFragment fragment)
    {
        if (fragmentRevisions.LastOrDefault(f => f.Id == fragment.Id) != fragment) fragmentRevisions.Add(fragment);
        try
        {
            if (fragmentLine.TryGetValue(fragment.Id, out var lineId) && archivedLines.FindIndex(l => l.Id == lineId) is var index && index >= 0 && fragmentsByLine.TryGetValue(lineId, out var parts))
            {
                var part = parts.FindIndex(f => f.Id == fragment.Id);
                if (part >= 0) { parts[part] = fragment; archivedLines[index] = archivedLines[index] with { Content = string.Concat(parts.Select(f => f.Text)) }; return; }
            }
            if (fragment.Speaker == Speaker.You && protectedPreview is { } saved)
            {
                protectedPreview = null; var final = fragment.Text.Trim();
                var savedIndex = archivedLines.FindIndex(l => l.Id == saved.Id);
                if ((fragment.ReceivedAt - saved.At).TotalSeconds < 12 && final.StartsWith(saved.Text, StringComparison.Ordinal) && savedIndex >= 0)
                {
                    archivedLines[savedIndex] = new(saved.Id, Speaker.You, saved.At, final);
                    fragmentsByLine[saved.Id] = [fragment]; fragmentLine[fragment.Id] = saved.Id; lastFragmentEnd[Speaker.You] = fragment.EndMs; return;
                }
            }
            var last = archivedLines.LastOrDefault();
            if (last is not null && last.Speaker == fragment.Speaker && lastFragmentEnd.TryGetValue(fragment.Speaker, out var end) && fragment.StartMs >= end && fragment.StartMs - end < 1600 && TextElements.Count(last.Content) < 1800)
                archivedLines[^1] = last with { Content = last.Content + fragment.Text };
            else archivedLines.Add(new(fragment.Speaker, fragment.ReceivedAt, fragment.Text));
            var id = archivedLines[^1].Id;
            if (!fragmentsByLine.TryGetValue(id, out var list)) fragmentsByLine[id] = list = [];
            list.Add(fragment); fragmentLine[fragment.Id] = id; lastFragmentEnd[fragment.Speaker] = fragment.EndMs;
        }
        finally { Refresh(); }
    }
    private void Refresh() { Lines = archivedLines.TakeLast(AppPaths.TranscriptLineLimit).ToValueList(); Changed(); }
    public void Clear()
    {
        protectedPreview = null; fragmentsByLine.Clear(); fragmentLine.Clear(); lastFragmentEnd.Clear(); archivedLines.Clear(); fragmentRevisions.Clear();
        PartialThem = ""; PartialYou = ""; Refresh();
    }
}
