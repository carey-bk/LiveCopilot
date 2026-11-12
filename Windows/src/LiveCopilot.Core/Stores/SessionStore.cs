namespace LiveCopilot.Core;

public sealed class SessionStore : ObservableStore
{
    private readonly string root;
    private readonly List<SessionRecord> sessions = [];
    public IReadOnlyList<SessionRecord> Sessions => sessions.AsReadOnly();
    public string? LastError { get; private set; }
    public SessionStore(string? root = null) { this.root = root ?? Path.Combine(AppPaths.DataDirectory, "sessions"); LoadAll(); }
    public SessionRecord? Save(IReadOnlyList<TranscriptLine> lines, DateTimeOffset startedAt, DateTimeOffset? endedAt = null, ValueList<TranscriptFragment>? fragments = null) =>
        SaveSnapshot(lines.Select(l => new SessionLine(l)).ToValueList(), startedAt, [], endedAt, fragments);
    public SessionRecord? SaveSnapshot(ValueList<SessionLine> lines, DateTimeOffset startedAt, ValueList<SessionAnswer> answers, DateTimeOffset? endedAt = null, ValueList<TranscriptFragment>? fragments = null)
    {
        if (lines.Count == 0 && answers.Count == 0) return null;
        var record = new SessionRecord(startedAt, endedAt ?? DateTimeOffset.UtcNow, lines) { Fragments = fragments ?? [], Answers = answers, SchemaVersion = 2 };
        if (!Persist(record)) return null;
        sessions.Insert(0, record); var ordered = sessions.OrderByDescending(s => s.StartedAt).ToArray(); sessions.Clear(); sessions.AddRange(ordered); Changed(); return record;
    }
    public bool Update(Guid id, Func<SessionRecord, SessionRecord> change)
    {
        var index = sessions.FindIndex(s => s.Id == id); if (index < 0) return false;
        var record = change(sessions[index]);
        if (record.Id != id) throw new ArgumentException("A session update must retain its identity.", nameof(change));
        if (!Persist(record)) return false;
        sessions[index] = record; Changed(); return true;
    }
    public bool Rename(Guid id, string title) => SessionNaming.Clean(title) is { } clean && Update(id, s => s with { GeneratedTitle = clean, NamingState = "manual" });
    public void Delete(SessionRecord record)
    {
        try
        {
            var path = FileFor(record.Id);
            if (!File.Exists(path)) throw new FileNotFoundException();
            File.Delete(path);
        }
        catch (Exception e) when (DiskError(e)) { LastError = "Could not delete session history. Check disk permissions."; Changed(); return; }
        try { File.Delete(Path.ChangeExtension(FileFor(record.Id), ".txt")); }
        catch (Exception e) when (DiskError(e)) { LastError = "Could not delete transcript draft."; }
        sessions.RemoveAll(s => s.Id == record.Id); Changed();
    }
    public void Export(SessionRecord record, string path) => AtomicFile.Write(path, Encoding.UTF8.GetBytes(record.Export(Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase))));
    private string FileFor(Guid id) => Path.Combine(root, CoreJson.Id(id) + ".json");
    private bool Persist(SessionRecord record)
    {
        try
        {
            AtomicFile.Write(FileFor(record.Id), Encoding.UTF8.GetBytes(CoreJson.Encode(record, session: true)));
            LastError = null;
            try { Export(record, Path.ChangeExtension(FileFor(record.Id), ".txt")); }
            catch (Exception e) when (DiskError(e)) { LastError = "Session saved; transcript draft could not be written. You can export it from History."; }
            return true;
        }
        catch (Exception e) when (DiskError(e) || e is JsonException) { LastError = "Session history could not be saved. Check available disk space and permissions."; Changed(); return false; }
    }
    private static bool DiskError(Exception e) => e is IOException or UnauthorizedAccessException;
    private void LoadAll()
    {
        if (!Directory.Exists(root)) return;
        try
        {
            foreach (var path in Directory.EnumerateFiles(root, "*.json"))
            {
                try
                {
                    var record = CoreJson.Decode<SessionRecord>(File.ReadAllText(path), session: true);
                    if (record.NamingState == "pending") record = record with { NamingState = "failed" };
                    sessions.Add(record);
                }
                catch (Exception e) when (DiskError(e) || e is JsonException) { }
            }
        }
        catch (Exception e) when (DiskError(e)) { return; }
        var ordered = sessions.OrderByDescending(s => s.StartedAt).ToArray(); sessions.Clear(); sessions.AddRange(ordered);
    }
}
