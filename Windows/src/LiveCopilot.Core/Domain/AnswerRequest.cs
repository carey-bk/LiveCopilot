namespace LiveCopilot.Core;


public sealed record AnswerRequest(RetrievalQuery Query, string Conversation, ScenarioProfile Scenario, ValueList<RetrievedSource> Sources)
{
    public string? TranslationText { get; set; }
    public string TranslationTarget { get; set; } = "English";
    public string? SessionTitleInput { get; set; }
    public SuggestionMode Mode { get; set; } = SuggestionMode.Reply;
    public KnowledgeMode KnowledgeMode { get; set; } = KnowledgeMode.Hybrid;
    public AnswerLanguage AnswerLanguage { get; set; } = AnswerLanguage.Auto;
    public bool BilingualAnswers { get; set; }
    public string AdditionalAnswerInstructions { get; set; } = "";
    public string? LanguageQuestion { get; set; }
    public Func<PipelineStage, double, Task>? OnStreamProgress { get; set; }
    public string AnswerStyleInstructions
    {
        get
        {
            var extra = TextElements.Prefix(AdditionalAnswerInstructions, 4000).Trim();
            var result = extra.Length > 0 ? PromptText.Get("stylePrefix") + extra + "\nEnd of user style preferences.\n" : "";
            return result + (BilingualAnswers ? PromptText.Get("bilingual") : "");
        }
    }
    public string Instructions
    {
        get
        {
            if (TranslationText is not null) return PromptText.Get("translation").Replace("{target}", TranslationTarget, StringComparison.Ordinal);
            if (SessionTitleInput is not null) return PromptText.Get("sessionTitle");
            // Single-pass replacement: user style text must never be interpreted as a template.
            var parts = new Dictionary<string, string> { ["language"] = AnswerLanguage.Instructions(), ["scenario"] = Scenario.Instructions(),
                ["task"] = PromptText.Get("task." + Mode.RawValue()), ["style"] = AnswerStyleInstructions, ["knowledge"] = KnowledgeMode.Instructions() };
            return Regex.Replace(PromptText.Get("answer"), @"\{(language|scenario|task|style|knowledge)\}", m => parts[m.Groups[1].Value]);
        }
    }
    public string Input
    {
        get
        {
            if (TranslationText is not null) return TranslationText;
            if (SessionTitleInput is not null) return "Conversation excerpts for naming only:\n" + SessionTitleInput;
            var evidence = KnowledgeMode.UsesKnowledgeBase() ? string.Join("\n\n", Sources.Select((s, i) => $"[S{i + 1}] {s.Chunk.SourceLabel} (retrieval candidate: {s.Relevance})\n{s.Chunk.Text}")) : "";
            var sections = new List<string> { "Question: " + Query.Question };
            if (LanguageQuestion is not null && LanguageQuestion != Query.Question) sections.Add("Current substantive language target: " + LanguageQuestion);
            if (QuestionScope.NeedsContext(Query.Question)) sections.Add("Retrieval intent: " + Query.Semantic);
            if (Conversation.Length > 0) sections.Add("Conversation (includes what You already said):\n" + Conversation);
            sections.Add("Knowledge evidence:\n" + (evidence.Length == 0 ? "No local evidence retrieved." : evidence));
            return string.Join("\n", sections);
        }
    }
}
