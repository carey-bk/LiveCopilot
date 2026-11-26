namespace LiveCopilot.Core;

public static class TranslationLanguageExtensions
{
    public static string Prompt(this TranslationLanguage value) => value switch
    {
        TranslationLanguage.Simplified => "Simplified Chinese", TranslationLanguage.Traditional => "Traditional Chinese",
        TranslationLanguage.English => "English", TranslationLanguage.Japanese => "Japanese", TranslationLanguage.Korean => "Korean",
        TranslationLanguage.French => "French", TranslationLanguage.German => "German", _ => "Spanish"
    };
}

/// Serializes queue state internally, including hosts without a UI SynchronizationContext.
/// PropertyChanged may originate on a worker; UI adapters marshal notifications to their dispatcher.
public sealed class TranscriptTranslationStore : ObservableStore, IDisposable
{
    public sealed record Translation(string Source, string Text);
    private readonly object gate = new();
    private readonly TimeSpan previewDelay, confirmedDelay, timeout;
    private readonly Dictionary<Guid, Translation> values = [];
    private readonly Dictionary<Guid, string> completed = [];
    private readonly Dictionary<Speaker, TranscriptLine> previews = [];
    private readonly Dictionary<string, string> cache = [];
    private IReadOnlyList<TranscriptLine> confirmed = [];
    private List<TranscriptLine> lines = [];
    private IReasoningProvider? provider;
    private TranscriptLine? activeLine;
    private CancellationTokenSource? operation;
    private long generation;
    private bool enabled, busy, failed;
    private TranslationLanguage target = TranslationLanguage.Simplified;
    private TaskCompletionSource idle = CompletedSignal();
    public TranscriptTranslationStore(TimeSpan? previewDelay = null, TimeSpan? confirmedDelay = null, TimeSpan? timeout = null)
    { this.previewDelay = previewDelay ?? TimeSpan.FromMilliseconds(900); this.confirmedDelay = confirmedDelay ?? TimeSpan.FromMilliseconds(100); this.timeout = timeout ?? TimeSpan.FromSeconds(20); }
    public bool Enabled { get { lock (gate) return enabled; } }
    public bool Busy { get { lock (gate) return busy; } }
    public bool Failed { get { lock (gate) return failed; } }
    public TranslationLanguage Target { get { lock (gate) return target; } }
    public IReadOnlyDictionary<Guid, Translation> Values { get { lock (gate) return new Dictionary<Guid, Translation>(values); } }
    public Task WhenIdleAsync(CancellationToken cancellationToken = default) { lock (gate) return idle.Task.WaitAsync(cancellationToken); }
    private static TaskCompletionSource CompletedSignal() { var signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); signal.SetResult(); return signal; }
    public string? Text(TranscriptLine line) { lock (gate) return values.TryGetValue(line.Id, out var value) && value.Source == line.Content ? value.Text : null; }
    public string? PreviewText(string source, Speaker speaker)
    { lock (gate) return previews.TryGetValue(speaker, out var line) && line.Content == source ? Text(line) : null; }
    public void UpdatePreview(string source, Speaker speaker)
    {
        lock (gate)
        {
            if (!enabled) return;
            if (source.Length == 0) previews.Remove(speaker);
            else if (!previews.TryGetValue(speaker, out var old) || old.Content != source)
                previews[speaker] = new(old?.Id ?? Guid.NewGuid(), speaker, DateTimeOffset.UtcNow, source);
            Refresh();
        }
    }
    public void Start(TranslationLanguage target, IReasoningProvider provider, IReadOnlyList<TranscriptLine> lines)
    {
        lock (gate)
        {
            Stop(); this.target = target; this.provider = provider; enabled = true;
            foreach (var line in lines.SkipLast(1)) completed[line.Id] = line.Content;
            Update(lines);
        }
    }
    public void Stop()
    {
        lock (gate)
        {
            CancelCurrent(); provider = null; enabled = false; failed = false; values.Clear(); completed.Clear();
            lines.Clear(); confirmed = []; previews.Clear(); cache.Clear(); idle.TrySetResult(); Changed();
        }
    }
    public void ResetSession()
    { lock (gate) { var active = enabled; var saved = provider; var language = target; Stop(); if (active && saved is not null) Start(language, saved, []); } }
    public void Update(IReadOnlyList<TranscriptLine> lines)
    { lock (gate) { if (!enabled) return; confirmed = lines.ToArray(); Refresh(); } }
    private void CancelCurrent()
    { generation++; operation?.Cancel(); operation = null; activeLine = null; busy = false; }
    private void Refresh()
    {
        lines = confirmed.TakeLast(20).Concat(previews.Values.OrderBy(l => l.At)).ToList();
        var ids = lines.Select(l => l.Id).ToHashSet();
        foreach (var id in values.Keys.Where(id => !ids.Contains(id)).ToArray()) values.Remove(id);
        foreach (var id in completed.Keys.Where(id => !ids.Contains(id)).ToArray()) completed.Remove(id);
        foreach (var line in lines.Where(l => completed.GetValueOrDefault(l.Id) != l.Content))
            if (cache.TryGetValue(line.Content, out var text)) { values[line.Id] = new(line.Content, text); completed[line.Id] = line.Content; }
        if (activeLine is { } active && !IsCurrentLine(active)) CancelCurrent();
        Pump(); Changed();
    }
    private bool IsCurrentLine(TranscriptLine line) => lines.Any(l => l.Id == line.Id && l.Content == line.Content);
    private void Pump()
    {
        if (operation is not null || !enabled || provider is null) return;
        var line = lines.LastOrDefault(l => completed.GetValueOrDefault(l.Id) != l.Content);
        if (line is null) { idle.TrySetResult(); return; }
        if (idle.Task.IsCompleted) idle = new(TaskCreationOptions.RunContinuationsAsynchronously);
        busy = true; activeLine = line;
        var source = new CancellationTokenSource(); operation = source;
        var token = generation;
        var delay = previews.Values.Any(p => p.Id == line.Id) ? previewDelay : confirmedDelay;
        _ = RunAsync(line, provider, target, delay, source, token);
    }
    private async Task RunAsync(TranscriptLine line, IReasoningProvider selectedProvider, TranslationLanguage language, TimeSpan delay, CancellationTokenSource source, long token)
    {
        await Task.Yield();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(source.Token);
        deadline.CancelAfter(timeout);
        bool Current() => token == generation && ReferenceEquals(operation, source);
        async Task<string> Translate()
        {
            await Task.Delay(delay, deadline.Token);
            var request = new AnswerRequest(new("", "", ""), "", ScenarioProfile.Interview, []) { TranslationText = line.Content, TranslationTarget = language.Prompt() };
            var output = "";
            await foreach (var delta in selectedProvider.Stream(request, deadline.Token).WithCancellation(deadline.Token))
            {
                deadline.Token.ThrowIfCancellationRequested(); output += delta;
                if (TextElements.Count(output) > 16000) throw new CopilotException("Translation too long");
                lock (gate)
                {
                    if (!Current()) throw new OperationCanceledException();
                    if (IsCurrentLine(line)) { values[line.Id] = new(line.Content, output); Changed(); }
                }
            }
            deadline.Token.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(output)) throw new CopilotException("Empty translation");
            return output.Trim();
        }
        try
        {
            var output = await Translate().WaitAsync(deadline.Token);
            lock (gate)
            {
                if (!Current()) return;
                if (IsCurrentLine(line)) values[line.Id] = new(line.Content, output);
                if (cache.Count >= 80) cache.Clear(); cache[line.Content] = output; failed = false;
            }
        }
        catch (Exception)
        {
            lock (gate) { if (!Current()) return; values.Remove(line.Id); failed = true; }
        }
        finally
        {
            deadline.Cancel();
            lock (gate)
            {
                if (Current())
                {
                    completed[line.Id] = line.Content; operation = null; activeLine = null; busy = false; Pump(); Changed();
                }
            }
            source.Dispose();
        }
    }
    public void Dispose() => Stop();
}
