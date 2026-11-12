namespace LiveCopilot.Core;

public sealed class ConversationState
{
    private readonly List<TranscriptFragment> fragments = [];
    private readonly List<(string Text, DateTimeOffset At)> handled = [];
    private string? lastQuestionFragmentId;
    private DateTimeOffset? lastTriggerAt;
    public IReadOnlyList<TranscriptFragment> Fragments => fragments.AsReadOnly();
    public QuestionPhase Phase { get; private set; } = QuestionPhase.Listening;
    public string? PreviousQuestion { get; private set; }
    public bool Append(TranscriptFragment fragment)
    {
        if (fragment.EndMs < fragment.StartMs) return false;
        var index = fragments.FindIndex(f => f.Id == fragment.Id);
        if (index >= 0)
        {
            var old = fragments[index];
            if (old.Speaker != fragment.Speaker || old.StartMs != fragment.StartMs || fragment.EndMs < old.EndMs || old.Text == fragment.Text) return false;
            fragments[index] = fragment;
            return true;
        }
        fragments.Add(fragment);
        if (fragments.Count > 2400) fragments.RemoveRange(0, fragments.Count - 2400);
        if (fragment.Speaker != Speaker.You) Phase = QuestionPhase.Forming;
        return true;
    }
    public string? LatestFragmentId(Speaker? speaker) => fragments.LastOrDefault(f => f.Speaker == speaker)?.Id;
    public string Context(int limit = 7000)
    {
        var rows = new List<(Speaker Speaker, string Text)>();
        foreach (var fragment in WithoutAdjacentRepeats(fragments.TakeLast(100)))
        {
            if (rows.Count > 0 && rows[^1].Speaker == fragment.Speaker) rows[^1] = (fragment.Speaker, rows[^1].Text + fragment.Text);
            else rows.Add((fragment.Speaker, fragment.Text));
        }
        return TextElements.Suffix(string.Join("\n", rows.Select(r => r.Speaker.RawValue() + ": " + r.Text)), limit);
    }
    public string? Candidate(Speaker speaker, DateTimeOffset now, double cooldown, bool force = false, bool semanticDetection = false)
    {
        var last = fragments.LastOrDefault(f => f.Speaker == speaker);
        if (last is null) { Phase = QuestionPhase.Waiting; return null; }
        if (!force && speaker == Speaker.Them && fragments.LastOrDefault(f => f.Speaker == Speaker.You) is { } you && you.ReceivedAt > last.ReceivedAt)
        { Phase = QuestionPhase.Answered; return null; }
        var eligibleIds = CandidateFragments(speaker, now, force).Select(f => f.Id).ToHashSet();
        var turns = fragments.Where(f => f.Speaker != speaker || eligibleIds.Contains(f.Id));
        var question = TextElements.Suffix(string.Concat(WithoutAdjacentRepeats(turns).Where(f => f.Speaker == speaker).Select(f => f.Text)), 2200).Trim();
        if (TextElements.Count(question) < (semanticDetection ? 1 : 5)) { Phase = QuestionPhase.Waiting; return null; }
        var lower = TextElements.TrimPunctuation(question.ToLowerInvariant());
        string[] incomplete = [" and", " or", " because", " if", " but", " the", " of", " with", "以及", "因为", "如果"];
        if (!force && !semanticDetection && incomplete.Any(x => lower.EndsWith(x, StringComparison.Ordinal))) { Phase = QuestionPhase.Waiting; return null; }
        handled.RemoveAll(h => (now - h.At).TotalSeconds > 180);
        if (!force && handled.Any(h => Similar(h.Text, question))) { Phase = QuestionPhase.Duplicate; return null; }
        if (!force && lastTriggerAt is { } at && (now - at).TotalSeconds < cooldown) { Phase = QuestionPhase.Waiting; return null; }
        Phase = PreviousQuestion is null ? QuestionPhase.Complete : QuestionPhase.FollowUp;
        return question;
    }
    private List<TranscriptFragment> CandidateFragments(Speaker speaker, DateTimeOffset now, bool force)
    {
        var eligible = fragments.Where(f => f.Speaker == speaker).ToList();
        var index = lastQuestionFragmentId is null ? -1 : eligible.FindIndex(f => f.Id == lastQuestionFragmentId);
        if (index >= 0 && index + 1 < eligible.Count) eligible = eligible.Skip(index + 1).ToList();
        var start = Math.Max(0, eligible.Count - 12);
        for (var i = eligible.Count - 1; i >= Math.Max(1, start); i--)
            if (eligible[i].StartMs - eligible[i - 1].EndMs > 1600) { start = i; break; }
        eligible = eligible.Skip(start).ToList();
        if (!force)
        {
            var answered = handled.Where(h => (now - h.At).TotalSeconds <= 180).Select(h => CaptionKey(h.Text)).ToHashSet();
            while (eligible.Count > 1 && answered.Contains(CaptionKey(eligible[0].Text))) eligible.RemoveAt(0);
        }
        return eligible;
    }
    // The provider-specific layaContext adapter is intentionally outside this port's scope.
    public void Begin(string question, Speaker? speaker, DateTimeOffset now)
    {
        handled.Add((question, now)); PreviousQuestion = question; lastTriggerAt = now;
        if (speaker is not null) lastQuestionFragmentId = LatestFragmentId(speaker);
        Phase = QuestionPhase.Working;
    }
    public void Finish(bool success, string question)
    { if (!success) { handled.RemoveAll(h => h.Text == question); lastTriggerAt = null; } Phase = QuestionPhase.Listening; }
    public void Reset() { fragments.Clear(); handled.Clear(); Phase = QuestionPhase.Listening; PreviousQuestion = null; lastQuestionFragmentId = null; lastTriggerAt = null; }
    private static IReadOnlyList<TranscriptFragment> WithoutAdjacentRepeats(IEnumerable<TranscriptFragment> input)
    {
        var result = new List<TranscriptFragment>();
        foreach (var fragment in input)
        {
            var key = CaptionKey(fragment.Text);
            if (TextElements.Count(key) >= 5 && result.Count > 0 && result[^1].Speaker == fragment.Speaker && CaptionKey(result[^1].Text) == key) continue;
            result.Add(fragment);
        }
        return result;
    }
    private static string CaptionKey(string text) => TextElements.NormalizeWhitespace(FoldWidth(text).ToLowerInvariant()).Trim('.', '!', '?', '。', '！', '？', '…', ' ');
    private static string FoldWidth(string text) => string.Concat(text.EnumerateRunes().Select(r => r.Value is >= 0xff00 and <= 0xffef || r.Value == 0x3000 ? r.ToString().Normalize(NormalizationForm.FormKC) : r.ToString()));
    public static bool Similar(string lhs, string rhs)
    {
        var a = TextElements.AlphanumericKey(lhs); var b = TextElements.AlphanumericKey(rhs);
        if (a == b) return true;
        if (Math.Min(TextElements.Count(a), TextElements.Count(b)) <= 20) return false;
        var aa = TextElements.Words(lhs).ToHashSet(); var bb = TextElements.Words(rhs).ToHashSet();
        return aa.Count > 4 && (double)aa.Intersect(bb).Count() / Math.Max(1, aa.Union(bb).Count()) > 0.88;
    }
}
