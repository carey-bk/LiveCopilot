namespace LiveCopilot.Core;

public sealed record RetrievalQuery(string Question, string Semantic, string Lexical)
{
    public static RetrievalQuery Formulate(string question, string context, string? previousQuestion = null)
    {
        var normalized = TextElements.NormalizeWhitespace(question);
        var followUp = QuestionScope.NeedsContext(normalized);
        var recent = followUp ? TextElements.Suffix(context, 1800) : "";
        var prior = followUp ? previousQuestion : null;
        var reference = prior is null ? "" : $"Previous question: {prior}\n";
        return new(normalized, $"Current question: {normalized}\n{reference}Relevant conversation: {recent}",
            normalized + " " + (prior ?? "") + " " + TextElements.Suffix(recent, 600));
    }
}
