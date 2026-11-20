namespace LiveCopilot.Core;

public sealed class SessionStore : ObservableStore
{
    private readonly string root;
    private readonly List<SessionRecord> sessions = [];
    private readonly Dictionary<Guid, string> loadedPaths = [];
    private readonly List<SessionLoadIssue> loadIssues = [];
    private readonly Action<SessionLoadIssue> logIssue;
    public IReadOnlyList<SessionLoadIssue> LoadIssues => loadIssues.AsReadOnly();
    public bool HasFiles { get; private set; }
    public IReadOnlyList<SessionRecord> Sessions => sessions.AsReadOnly();
    public string? LastError { get; private set; }
    public SessionStore(string? root = null, Action<SessionLoadIssue>? logIssue = null)
    {
        this.root = root ?? Path.Combine(AppPaths.DataDirectory, "sessions");
        this.logIssue = logIssue ?? (issue => System.Diagnostics.Trace.TraceWarning("Session history: {0}: {1}", issue.FileName, issue.Reason));
        Reload();
    }
    public SessionRecord? Save(IReadOnlyList<TranscriptLine> lines, DateTimeOffset startedAt, DateTimeOffset? endedAt = null, ValueList<TranscriptFragment>? fragments = null, ScenarioProfile? scenario = null) =>
        SaveSnapshot(lines.Select(l => new SessionLine(l)).ToValueList(), startedAt, [], endedAt, fragments, scenario);
    public SessionRecord? SaveSnapshot(ValueList<SessionLine> lines, DateTimeOffset startedAt, ValueList<SessionAnswer> answers, DateTimeOffset? endedAt = null, ValueList<TranscriptFragment>? fragments = null, ScenarioProfile? scenario = null)
    {
        if (lines.Count == 0 && answers.Count == 0) return null;
        var record = new SessionRecord(startedAt, endedAt ?? DateTimeOffset.UtcNow, lines) { Fragments = fragments ?? [], Answers = answers, SchemaVersion = 2, Scenario = scenario };
        if (!Persist(record)) return null;
        sessions.Add(record); Sort(); Changed(); return record;
    }
    public bool Update(Guid id, Func<SessionRecord, SessionRecord> change)
    {
        var index = sessions.FindIndex(s => s.Id == id); if (index < 0) return false;
        var record = change(sessions[index]);
        if (record.Id != id) throw new ArgumentException("A session update must retain its identity.", nameof(change));
        if (!Persist(record)) return false;
        sessions[index] = record; Sort(); Changed(); return true;
    }
    public bool Rename(Guid id, string title) => SessionNaming.Clean(title) is { } clean && Update(id, s => s with { GeneratedTitle = clean, NamingState = "manual" });
    public bool Delete(SessionRecord record)
    {
        LastError = null;
        var path = loadedPaths.GetValueOrDefault(record.Id, FileFor(record.Id));
        try { File.Delete(path); }
        catch (Exception e) when (DiskError(e))
        { LastError = "Could not delete session history. Check disk permissions."; Changed(); return false; }
        var deletedDraft = true;
        try { File.Delete(Path.ChangeExtension(path, ".txt")); }
        catch (Exception e) when (DiskError(e)) { LastError = "Could not delete transcript draft."; deletedDraft = false; }
        sessions.RemoveAll(s => s.Id == record.Id);
        loadedPaths.Remove(record.Id);
        UpdateHasFiles();
        Changed();
        return deletedDraft;
    }

    // The dedicated sessions directory also contains unreadable/future files and draft TXT
    // companions. Clear all means all of those, never external exports or other app data.
    public bool Clear()
    {
        string? error = null;
        try
        {
            if (Directory.Exists(root))
                foreach (var path in Directory.EnumerateFiles(root).Where(IsHistoryFile))
                    try { File.Delete(path); }
                    catch (Exception e) when (DiskError(e)) { error = "Could not clear all session history. Check disk permissions."; }
        }
        catch (Exception e) when (DiskError(e)) { error = "Could not read the session history directory."; }
        Reload();
        LastError = error ?? LastError;
        Changed();
        return LastError is null;
    }

    public void Export(SessionRecord record, string path) => Export(record, path, Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase));
    public void Export(SessionRecord record, string path, bool markdown) => AtomicFile.Write(path, Encoding.UTF8.GetBytes(record.Export(markdown)));
    private string FileFor(Guid id) => Path.Combine(root, CoreJson.Id(id) + ".json");
    private bool Persist(SessionRecord record)
    {
        try
        {
            var path = loadedPaths.GetValueOrDefault(record.Id, FileFor(record.Id));
            AtomicFile.Write(path, Encoding.UTF8.GetBytes(CoreJson.Encode(record, session: true)));
            LastError = null;
            HasFiles = true;
            loadedPaths[record.Id] = path;
            try { Export(record, Path.ChangeExtension(path, ".txt")); }
            catch (Exception e) when (DiskError(e)) { LastError = "Session saved; transcript draft could not be written. You can export it from History."; }
            return true;
        }
        catch (Exception e) when (DiskError(e) || e is JsonException) { LastError = "Session history could not be saved. Check available disk space and permissions."; Changed(); return false; }
    }
    private static bool DiskError(Exception e) => e is IOException or UnauthorizedAccessException;
    public void Reload()
    {
        sessions.Clear(); loadedPaths.Clear(); loadIssues.Clear(); LastError = null;
        UpdateHasFiles();
        if (!Directory.Exists(root)) { Changed(); return; }
        try
        {
            foreach (var path in Directory.EnumerateFiles(root, "*.json"))
            {
                try
                {
                    var record = CoreJson.Decode<SessionRecord>(File.ReadAllText(path), session: true);
                    if (record.SchemaVersion is not (null or 1 or 2))
                    { RecordIssue(path, "Unsupported schema version."); continue; }
                    Validate(record);
                    if (!loadedPaths.TryAdd(record.Id, path))
                    { RecordIssue(path, "Duplicate session identity."); continue; }
                    if (record.NamingState == "pending") record = record with { NamingState = "failed" };
                    sessions.Add(record);
                }
                catch (Exception e) when (DiskError(e) || e is JsonException)
                { RecordIssue(path, e is JsonException ? "Invalid session data." : "Session file could not be read."); }
            }
        }
        catch (Exception e) when (DiskError(e))
        { LastError = "Could not read the session history directory."; RecordIssue(root, "Directory could not be read."); }
        Sort(); Changed();
    }

    private void Sort()
    {
        var ordered = sessions.OrderByDescending(s => s.StartedAt).ThenBy(s => s.Id).ToArray();
        sessions.Clear(); sessions.AddRange(ordered);
    }

    private void RecordIssue(string path, string reason)
    {
        // Never log transcript, answer, exception text, or full personal directory paths.
        var issue = new SessionLoadIssue(Path.GetFileName(path), reason);
        loadIssues.Add(issue); logIssue(issue);
    }
    private static bool IsHistoryFile(string path) => Path.GetExtension(path).ToLowerInvariant() is ".json" or ".txt";
    private void UpdateHasFiles()
    {
        try { HasFiles = Directory.Exists(root) && Directory.EnumerateFiles(root).Any(IsHistoryFile); }
        catch (Exception e) when (DiskError(e)) { HasFiles = true; LastError = "Could not read the session history directory."; }
    }
    private static void Validate(SessionRecord record)
    {
        if (record.Id == Guid.Empty || record.Lines is null ||
            record.Lines.Any(l => l is null || l.Content is null) ||
            (record.Answers?.Any(a => a is null || a.Question is null || a.Text is null || a.State is null ||
                a.Sources is null || a.Sources.Any(s => s is null || s.DocumentId is null || s.DocumentName is null || s.Excerpt is null)) ?? false))
            throw new JsonException("Invalid required session values.");
    }
}

public sealed record SessionLoadIssue(string FileName, string Reason);
