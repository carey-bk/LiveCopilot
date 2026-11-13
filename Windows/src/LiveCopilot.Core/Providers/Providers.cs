namespace LiveCopilot.Core;

public interface IEmbeddingProvider
{
    string Model { get; }
    Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default);
    async Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, Func<int, Task> progress, CancellationToken cancellationToken = default)
    {
        var vectors = await EmbedAsync(texts, cancellationToken);
        await progress(vectors.Count);
        return vectors;
    }
}
public interface ILocalEmbeddingPreparing : IEmbeddingProvider
{
    bool IsPrepared { get; }
    Task PrepareAsync(CancellationToken cancellationToken = default);
}
public interface IReasoningProvider
{
    IAsyncEnumerable<string> Stream(AnswerRequest request, CancellationToken cancellationToken = default);
}
public abstract record LiveEvent
{
    private LiveEvent() { }
    public sealed record Ready : LiveEvent;
    public sealed record Transcript(TranscriptFragment Fragment) : LiveEvent;
    public sealed record PartialTranscript(string Text) : LiveEvent;
    public sealed record Delegation(string Id, int OffsetMs) : LiveEvent;
    public sealed record SpeechActivity(bool Active) : LiveEvent;
    public sealed record Status(string Text) : LiveEvent;
    public sealed record Failed(string Message) : LiveEvent;
    public sealed record Closed(bool Finalized) : LiveEvent;
}
/// Hosts serialize callbacks on their UI context, matching the Swift MainActor contract.
public interface ILiveProvider
{
    Action<LiveEvent>? OnEvent { get; set; }
    void Connect(string context);
    void SendAudio(ReadOnlyMemory<byte> data);
    void AppendContext(string text, string? delegationId);
    Task DisconnectAsync();
}
public sealed record ServiceVerification
{
    private ServiceVerification(string state, string message) { State = state; Message = message; }
    public string State { get; }
    public string Message { get; }
    public bool IsReady => State == "ready";
    public bool IsChecking => State == "checking";
    public static ServiceVerification Idle { get; } = new("idle", "Awaiting verification");
    public static ServiceVerification Checking { get; } = new("checking", "Verifying with a test input…");
    public static ServiceVerification Ready { get; } = new("ready", "Verified · ready");
    public static ServiceVerification Failed(string message) => new("failed", message);
}
