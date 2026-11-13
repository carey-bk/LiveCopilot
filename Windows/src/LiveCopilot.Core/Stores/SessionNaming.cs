namespace LiveCopilot.Core;

public static class SessionNaming
{
    public static AnswerRequest Request(SessionRecord session) => new(RetrievalQuery.Formulate("Name this session", ""), "", ScenarioProfile.Meeting, []) { SessionTitleInput = session.NamingInput };
    public static string? Clean(string text)
    {
        var value = text.Trim().Trim('"', '\'', '“', '”', '#', '`', ' ');
        return value.Length == 0 || value.Contains('\n') || TextElements.Count(value) > 80 ? null : value;
    }
    public static async Task<string> GenerateAsync(SessionRecord session, IReasoningProvider provider, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(30));
        async Task<string> Generate()
        {
            var text = "";
            await foreach (var delta in provider.Stream(Request(session), deadline.Token).WithCancellation(deadline.Token))
            {
                deadline.Token.ThrowIfCancellationRequested(); text += delta;
                if (TextElements.Count(text) > 400) throw new CopilotException("Invalid session title.");
            }
            return Clean(text) ?? throw new CopilotException("Invalid session title.");
        }
        try { return await Generate().WaitAsync(deadline.Token); }
        finally { deadline.Cancel(); }
    }
}
