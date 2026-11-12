namespace LiveCopilot.Core;

public enum OnboardingStep { Language, Introduction, Models, Analysis, Permissions, Ready }
public sealed record OnboardingState
{
    public const string DefaultsKey = "livecopilot.onboarding.v1";
    [JsonRequired] public int Version { get; set; } = 1;
    [JsonRequired] public OnboardingStep Step { get; set; } = OnboardingStep.Language;
    [JsonRequired] public OnboardingDisposition Disposition { get; set; } = OnboardingDisposition.InProgress;
    [JsonRequired] public bool PrefersTyping { get; set; }
    [JsonRequired] public bool WantsKnowledge { get; set; }
    // A fresh state starts false; a missing optional key in an older state remains null.
    public bool? LocalSetupReviewed { get; set; }
    public OnboardingSpeechScenario? SpeechScenario { get; set; }
    public bool? SpeechManuallySelected { get; set; }
    public bool? KnowledgeRequested { get; set; }
    [JsonIgnore] public bool ShouldPresent => Disposition == OnboardingDisposition.InProgress;
    public static OnboardingState Fresh() => new() { LocalSetupReviewed = false };
    public void Advance() => Step = Step < OnboardingStep.Ready ? Step + 1 : OnboardingStep.Ready;
    public void Back() => Step = Step > OnboardingStep.Language ? Step - 1 : OnboardingStep.Language;
    public void Reopen()
    { if (Disposition is OnboardingDisposition.Completed or OnboardingDisposition.ExistingUser) Step = OnboardingStep.Language; Disposition = OnboardingDisposition.InProgress; }
    public static OnboardingState Load(IPreferenceStore store, bool hasExistingData)
    {
        try
        {
            if (store.Get(DefaultsKey) is { } data)
            {
                var saved = CoreJson.Decode<OnboardingState>(Encoding.UTF8.GetString(data));
                if (saved.Version == 1 && Enum.IsDefined(saved.Step)) return saved;
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        var existing = store.Contains(AppSettings.DefaultsKey) || hasExistingData;
        return new() { Disposition = existing ? OnboardingDisposition.ExistingUser : OnboardingDisposition.InProgress, LocalSetupReviewed = existing };
    }
    public void Save(IPreferenceStore store) => store.Set(DefaultsKey, Encoding.UTF8.GetBytes(CoreJson.Encode(this)));
}
public static class AnalysisConnectionProbe
{
    public static AnswerRequest Request => new(RetrievalQuery.Formulate("Reply with OK to this connection test.", ""), "", ScenarioProfile.Meeting, []);
    public static async Task RunAsync(IReasoningProvider provider, CancellationToken cancellationToken = default, TimeSpan? timeout = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(30));
        async Task Run()
        {
            var received = false;
            await foreach (var delta in provider.Stream(Request, deadline.Token).WithCancellation(deadline.Token))
            { deadline.Token.ThrowIfCancellationRequested(); if (!string.IsNullOrWhiteSpace(delta)) received = true; }
            if (!received) throw new CopilotException("The service returned no text. Check the model and retry.");
        }
        try { await Run().WaitAsync(deadline.Token); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new CopilotException("Connection test timed out. Check the network and retry."); }
        finally { deadline.Cancel(); }
    }
}
