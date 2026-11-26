global using Xunit;
global using LiveCopilot.Core;
global using System.Text;
global using System.Text.Json;

namespace LiveCopilot.Core.Tests;

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "livecopilot-tests-" + Guid.NewGuid().ToString("N"));
    public TemporaryDirectory(bool create = true) { if (create) Directory.CreateDirectory(Path); }
    public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true); }
}
internal sealed class TestLocale(params string[] languages) : ILocaleProvider
{
    public IReadOnlyList<string> PreferredLanguages => languages;
}
internal static class Fixtures
{
    public static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
    public static TranscriptFragment Fragment(string text, string id = "f1", Speaker speaker = Speaker.Them, int start = 0, DateTimeOffset? at = null) => new(id, speaker, text, start, start + 500, at ?? At);
    public static SourceChunk Chunk(string id = "c1", string text = "Synthetic cache hit: 42 ms", ValueList<float>? vector = null) => new(id, "fixture", "性能报告", 0, 2, text, vector ?? [1, 0], "test-embedding");
    public static SessionAnswer Answer(DateTimeOffset? at = null, string text = "Use **caching**. 42 ms [S1]") => new(Guid.NewGuid(), Guid.NewGuid(), false, at ?? At, (at ?? At).AddSeconds(1), (at ?? At).AddSeconds(2), "How can we reduce latency?", text, "completed", null, null, [new(1, "fixture", "性能报告", 2, 0, "Synthetic cache hit: 42 ms")], null);
}
internal sealed class TextProvider(string text, TimeSpan? delay = null) : IReasoningProvider
{
    public List<AnswerRequest> Requests { get; } = [];
    public async IAsyncEnumerable<string> Stream(AnswerRequest request, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        if (delay is { } duration) await Task.Delay(duration, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested(); yield return text;
    }
}

// Deliberately ignores cancellation, so tests can release obsolete results after a new
// generation has finished. Signals avoid sleeps and timing-dependent interleavings.
internal sealed class ControlledReasoningProvider : IReasoningProvider
{
    internal sealed class Call(AnswerRequest request, CancellationToken cancellationToken)
    {
        private readonly TaskCompletionSource<string> output = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public AnswerRequest Request { get; } = request;
        public CancellationToken CancellationToken { get; } = cancellationToken;
        public Task Finished => finished.Task;
        public Task<string> Output => output.Task;
        public void Complete(string text) => output.TrySetResult(text);
        public void Fail(Exception error) => output.TrySetException(error);
        public void Finish() => finished.TrySetResult();
    }
    private readonly System.Threading.Channels.Channel<Call> calls = System.Threading.Channels.Channel.CreateUnbounded<Call>();
    public Task<Call> NextAsync() => calls.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    public async IAsyncEnumerable<string> Stream(AnswerRequest request,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var call = new Call(request, cancellationToken);
        calls.Writer.TryWrite(call);
        try { yield return await call.Output; }
        finally { call.Finish(); }
    }
}
