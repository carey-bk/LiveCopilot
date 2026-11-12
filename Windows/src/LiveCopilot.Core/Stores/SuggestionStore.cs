namespace LiveCopilot.Core;

public sealed class SuggestionStore : ObservableStore
{
    public AnswerState State { get; private set; } = AnswerState.Queued;
    public DateTimeOffset? AnsweredAt { get; private set; }
    public DateTimeOffset? CompletedAt { get; private set; }
    private string rawText = "";
    public string Text { get; private set; } = "";
    public string Question { get; private set; } = "";
    public bool IsLoading { get; private set; }
    public string? Error { get; private set; }
    public SuggestionMode Mode { get; private set; } = SuggestionMode.Reply;
    private ValueList<RetrievedSource> sources = [];
    public ValueList<RetrievedSource> Sources { get => sources; set { sources = value; Changed(); } }
    private string? warning;
    public string? Warning { get => warning; set { warning = value; Changed(); } }
    private int retrievalMs;
    public int RetrievalMs { get => retrievalMs; set { retrievalMs = value; Changed(); } }
    private int? firstTextMs;
    public int? FirstTextMs { get => firstTextMs; set { firstTextMs = value; Changed(); } }
    private PipelineTrace? trace;
    public PipelineTrace? Trace { get => trace; set { trace = value; Changed(); } }
    public string WaitingMessage => Trace?.Milliseconds(PipelineStage.ReasoningStarted) is not null ? "The model is thinking…" : Trace?.Milliseconds(PipelineStage.ModelRequest) is null ? "Retrieving evidence…" : "Waiting for the model's answer…";
    public void Mark(PipelineStage stage, double? at = null) { Trace?.Mark(stage, at); Changed(); }
    public ValueList<(int Index, RetrievedSource Source)> CitedSources => SuggestionParser.CitedIndices(Text, Sources.Count).Select(i => (i, Sources[i - 1])).ToValueList();
    public void Begin(SuggestionMode mode = SuggestionMode.Reply, string question = "")
    {
        Reset(); State = AnswerState.Generating; Mode = mode; Question = question; IsLoading = true; Changed();
    }
    public void AppendDelta(string delta, DateTimeOffset? now = null)
    { if (AnsweredAt is null && delta.Length > 0) AnsweredAt = now ?? DateTimeOffset.UtcNow; rawText += delta; Text = CitationPolicy.Sanitized(rawText, Sources.Count); Changed(); }
    public void Finish(DateTimeOffset? now = null) { CompletedAt = now ?? DateTimeOffset.UtcNow; IsLoading = false; if (State == AnswerState.Generating) State = AnswerState.Completed; Changed(); }
    public void Interrupt(string? message = null, DateTimeOffset? now = null) { CompletedAt = now ?? DateTimeOffset.UtcNow; IsLoading = false; State = AnswerState.Interrupted; warning = message; Changed(); }
    public void Prepare(string question) { Question = question; State = AnswerState.Queued; Changed(); }
    public void Fail(string message, DateTimeOffset? now = null) { CompletedAt = now ?? DateTimeOffset.UtcNow; IsLoading = false; State = AnswerState.Failed; Error = message; Changed(); }
    public void CopyFrom(SuggestionStore other)
    {
        AnsweredAt = other.AnsweredAt; CompletedAt = other.CompletedAt; State = other.State; rawText = other.rawText; Text = other.Text;
        Question = other.Question; IsLoading = other.IsLoading; Error = other.Error; Mode = other.Mode; sources = other.sources; warning = other.warning;
        retrievalMs = other.retrievalMs; firstTextMs = other.firstTextMs; trace = other.trace is null ? null : other.trace with { }; Changed();
    }
    public void Reset()
    {
        AnsweredAt = null; CompletedAt = null; State = AnswerState.Queued; rawText = ""; Text = ""; Question = ""; IsLoading = false; Error = null;
        sources = []; warning = null; Mode = SuggestionMode.Reply; retrievalMs = 0; firstTextMs = null; trace = null; Changed();
    }
}
