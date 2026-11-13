namespace LiveCopilot.Core;

[method: JsonConstructor]
public sealed record SessionLine([property: JsonRequired] Guid Id, [property: JsonRequired] Speaker Speaker,
    [property: JsonRequired] DateTimeOffset At, [property: JsonRequired] string Content,
    [property: JsonPropertyName("fragmentIDs")] ValueList<string>? FragmentIds = null)
{
    public SessionLine(TranscriptLine line, ValueList<string>? fragmentIds = null) : this(line.Id, line.Speaker, line.At, line.Content, fragmentIds ?? []) { }
    [JsonIgnore] public string Clock => At.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);
}
public sealed record SessionCitation([property: JsonRequired] int Index,
    [property: JsonPropertyName("documentID"), JsonRequired] string DocumentId, [property: JsonRequired] string DocumentName,
    int? Page, [property: JsonRequired] int Ordinal, [property: JsonRequired] string Excerpt)
{
    [JsonIgnore] public int Id => Index;
    [JsonIgnore] public string Label => $"[S{Index}] {DocumentName}" + (Page is { } page ? $" · p.{page}" : "") + $" · {Ordinal + 1}";
}
public sealed record SessionAnswer([property: JsonRequired] Guid Id, [property: JsonPropertyName("questionID"), JsonRequired] Guid QuestionId,
    [property: JsonRequired] bool Automatic, [property: JsonRequired] DateTimeOffset CreatedAt, DateTimeOffset? AnsweredAt, DateTimeOffset? CompletedAt,
    [property: JsonRequired] string Question, [property: JsonRequired] string Text, [property: JsonRequired] string State,
    string? Warning, string? Error, [property: JsonRequired] ValueList<SessionCitation> Sources,
    [property: JsonPropertyName("sourceFragmentID")] string? SourceFragmentId);

public sealed record SessionEvent(string Id, DateTimeOffset At, SessionEventKind Kind, string Content, SessionAnswer? Answer = null)
{
    public ValueList<string> SourceIds { get; init; } = [];
    public string Role(bool english) => Kind switch
    {
        SessionEventKind.Room => english ? "Room speech" : "现场语音",
        SessionEventKind.Nearby => english ? "Remote speech" : "附近语音",
        SessionEventKind.Own => english ? "Your speech" : "我的语音",
        SessionEventKind.Question => Answer?.Automatic == true ? english ? "Recognized question" : "识别的问题" : english ? "Manual question" : "手动提问",
        _ => english ? "AI answer" : "AI 回答"
    };
    public string Exported(bool markdown, bool english = false)
    {
        var heading = $"[{At.ToLocalTime().ToString("T", CultureInfo.CurrentCulture)}] {Role(english)}";
        var value = (markdown ? "### " : "") + heading + "\n\n" + Content;
        if (Kind == SessionEventKind.Answer && Answer is { } answer)
        {
            value += "\n\n" + (english ? "Status: " : "状态：") + answer.State;
            if (answer.Warning is not null) value += "\n" + answer.Warning;
            if (answer.Error is not null) value += "\n" + answer.Error;
            foreach (var source in answer.Sources) value += "\n\n" + source.Label + "\n" + source.Excerpt;
        }
        return value;
    }
}

[method: JsonConstructor]
public sealed record SessionRecord([property: JsonRequired] Guid Id, [property: JsonRequired] DateTimeOffset StartedAt,
    [property: JsonRequired] DateTimeOffset EndedAt, [property: JsonRequired] ValueList<SessionLine> Lines)
{
    public SessionRecord(DateTimeOffset startedAt, DateTimeOffset endedAt, ValueList<SessionLine> lines) : this(Guid.NewGuid(), startedAt, endedAt, lines) { }
    public ValueList<TranscriptFragment>? Fragments { get; init; }
    public int? SchemaVersion { get; init; }
    public ValueList<SessionAnswer>? Answers { get; init; }
    public string? GeneratedTitle { get; init; }
    public string? NamingState { get; init; }
    [JsonIgnore] public string Title => GeneratedTitle ?? Preview;
    [JsonIgnore] public string Preview => TextElements.Prefix(TextElements.NormalizeWhitespace(
        Answers?.FirstOrDefault(a => !string.IsNullOrWhiteSpace(a.Question))?.Question ?? Lines.FirstOrDefault(l => !string.IsNullOrWhiteSpace(l.Content))?.Content ?? StartedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)), 72);
    [JsonIgnore] public double Duration => Math.Max(0, (EndedAt - StartedAt).TotalSeconds);
    [JsonIgnore] public string DurationLabel => (long)Duration >= 60 ? $"{(long)Duration / 60} min" : $"{(long)Duration} sec";
    [JsonIgnore] public int LineCount => Lines.Count;
    [JsonIgnore] public int MessageCount => Lines.Count + (Answers?.Count ?? 0) * 2;
    [JsonIgnore] public bool IsLegacy => Answers is null;
    [JsonIgnore] public ValueList<SessionEvent> Timeline
    {
        get
        {
            var events = Lines.Select(l => new SessionEvent("speech-" + CoreJson.Id(l.Id), l.At,
                l.Speaker == Speaker.Room ? SessionEventKind.Room : l.Speaker == Speaker.Them ? SessionEventKind.Nearby : SessionEventKind.Own, l.Content) { SourceIds = l.FragmentIds ?? [] }).ToList();
            foreach (var answer in Answers ?? [])
            {
                events.Add(new("question-" + CoreJson.Id(answer.Id), answer.CreatedAt, SessionEventKind.Question, answer.Question, answer));
                events.Add(new("answer-" + CoreJson.Id(answer.Id), answer.AnsweredAt ?? answer.CreatedAt, SessionEventKind.Answer, answer.Text, answer));
            }
            return events.OrderBy(e => e.At).ToValueList(); // LINQ OrderBy is stable for tied timestamps.
        }
    }
    public bool Matches(string search)
    {
        var terms = Regex.Split(search.Trim(), @"\s+").Where(t => t.Length > 0);
        var content = string.Join("\n", new[] { Title }.Concat(Lines.Select(l => l.Content)).Concat((Answers ?? []).SelectMany(a => new[] { a.Question, a.Text }.Concat(a.Sources.Select(s => s.DocumentName + " " + s.Excerpt)))));
        return terms.All(t => CultureInfo.CurrentCulture.CompareInfo.IndexOf(content, t, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth) >= 0);
    }
    public string Export(bool markdown) => (markdown ? "# " : "") + Title + "\n" + CoreJson.Iso8601(StartedAt) + " — " + CoreJson.Iso8601(EndedAt) +
        $"\n{DurationLabel} · {MessageCount} messages\n\n" + string.Join("\n\n", Timeline.Select(e => e.Exported(markdown))) + "\n";
    [JsonIgnore] public string TranscriptDocument => Export(false);
    [JsonIgnore] public string PlainText => string.Join("\n\n", Timeline.Select(e => e.Exported(false)));
    [JsonIgnore] public string ExportFilename => "LiveCopilot-" + StartedAt.ToLocalTime().ToString("yyyy-MM-dd-HHmmss", CultureInfo.InvariantCulture) + ".txt";
    [JsonIgnore] public string NamingInput
    {
        get
        {
            static IEnumerable<T> Sample<T>(IReadOnlyList<T> values, int limit) => values.Count <= limit ? values : Enumerable.Range(0, limit).Select(i => values[i * (values.Count - 1) / (limit - 1)]);
            static string Clipped(string value, int limit) => TextElements.Count(value) <= limit ? value : TextElements.Prefix(value, limit) + " [truncated]";
            var turns = (Answers ?? []).OrderBy(a => a.CreatedAt).ToArray();
            var paired = turns.Where(a => a.SourceFragmentId is not null).Select(a => a.SourceFragmentId!).ToHashSet();
            var unpaired = Lines.Where(l => !(l.FragmentIds ?? []).Any(paired.Contains)).ToArray();
            if (turns.Length == 0 && unpaired.Length == 0) return "";
            // Sorted object keys match the Swift payload; no local paths or vectors are included.
            return CoreJson.Encode(new
            {
                otherSpeech = Sample(unpaired, 8).Select(l => Clipped(l.Content, 400)).ToArray(),
                turns = Sample(turns, 8).Select(a => new
                {
                    answer = Clipped(a.Text, 2400),
                    citedEvidence = a.Sources.Take(2).Select(s => new { document = Clipped(s.DocumentName, 160), excerpt = Clipped(s.Excerpt, 600), reference = "S" + s.Index }).ToArray(),
                    question = Clipped(a.Question, 600), state = a.State
                }).ToArray()
            });
        }
    }
}
