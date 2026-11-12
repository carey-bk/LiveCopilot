namespace LiveCopilot.Core;

public sealed class QuestionCoordinator
{
    public sealed record Candidate(Guid Id, Guid AnswerId, string? SourceId, string Utterance, string? BaseQuery,
        string Query, string Context, Speaker? Speaker, string? DelegationId, PipelineTrace? Trace, DateTimeOffset ReceivedAt, DateTimeOffset ReadyAt);
    private readonly List<Candidate> pending = [], recent = [];
    public IReadOnlyList<Candidate> Pending => pending.AsReadOnly();
    public int DroppedCount { get; private set; }
    public void Clear() { pending.Clear(); recent.Clear(); DroppedCount = 0; }
    public void Enqueue(string query, string context, Speaker? speaker, string? delegationId, PipelineTrace? trace,
        ContinuousQuestionPolicy policy, string? sourceId = null, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        recent.RemoveAll(c => (at - c.ReceivedAt).TotalSeconds > 25);
        if (recent.Any(c => c.Speaker == speaker && Key(c.Utterance) == Key(query))) return;
        var prior = sourceId is null ? null : recent.LastOrDefault(c => c.SourceId == sourceId && c.Speaker == speaker);
        if (prior is not null)
        {
            var index = pending.FindIndex(c => c.Id == prior.Id);
            if (index >= 0)
            {
                pending[index] = pending[index] with { Query = prior.BaseQuery is { } previous ? previous + "\n" + query : query, Utterance = query, Context = context };
                recent[recent.FindIndex(c => c.Id == prior.Id)] = pending[index];
            }
            return;
        }
        var item = new Candidate(Guid.NewGuid(), Guid.NewGuid(), sourceId, query, null, query, context, speaker, delegationId, trace is null ? null : trace with { }, at, at.AddSeconds(policy == ContinuousQuestionPolicy.Complete ? 1.2 : 0));
        if (policy != ContinuousQuestionPolicy.Fast && recent.LastOrDefault() is { } last && last.Speaker == speaker &&
            (at - last.ReceivedAt).TotalSeconds <= (policy == ContinuousQuestionPolicy.Complete ? 5 : 3) && Related(last.Query, query))
        {
            item = item with { BaseQuery = last.Query, Query = TextElements.Suffix(last.Query + "\n" + query, 6000) };
            pending.RemoveAll(c => c.Id == last.Id);
        }
        recent.Add(item);
        if (pending.Count == 3) { pending.RemoveAt(0); DroppedCount++; }
        pending.Add(item);
    }
    public void PostponeUntilQuiet(DateTimeOffset? now = null)
    { var at = (now ?? DateTimeOffset.UtcNow).AddSeconds(1.2); for (var i = 0; i < pending.Count; i++) pending[i] = pending[i] with { ReadyAt = at }; }
    public Candidate? Take(DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        DroppedCount += pending.RemoveAll(c => (at - c.ReceivedAt).TotalSeconds > 25);
        if (pending.Count == 0 || pending[0].ReadyAt > at) return null;
        var first = pending[0]; pending.RemoveAt(0); return first;
    }
    public static string Key(string text) => TextElements.AlphanumericKey(text);
    public static bool Related(string previous, string next)
    {
        var b = next.ToLowerInvariant().Trim();
        string[] cues = ["相比", "那它", "它的", "其中", "具体来说", "进一步", "那这个", "为什么这样", "what about its", "how does it", "why is that", "compared to", "and how", "and why"];
        if (cues.Any(c => b.StartsWith(c, StringComparison.Ordinal))) return true;
        string[] stop = ["what", "how", "why", "does", "the", "you", "your", "could", "would", "explain", "please", "with", "that", "this", "which", "have", "about"];
        HashSet<string> Words(string s) => TextElements.Words(s).Where(w => TextElements.Count(w) > 2 && !stop.Contains(w)).ToHashSet();
        return Words(previous).Overlaps(Words(next));
    }
}
