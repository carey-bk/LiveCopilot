using LiveCopilot.Core;

namespace LiveCopilot.LocalInference.Tests;

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "livecopilot-inference-" + Guid.NewGuid());
    public TemporaryDirectory() => Directory.CreateDirectory(Path);
    public void Dispose() => Directory.Delete(Path, recursive: true);
}

internal sealed class FakeEmbeddingEngine : ILocalEmbeddingEngine
{
    public InferenceBackend Backend => InferenceBackend.Cpu;
    public List<(string Text, int Capacity)> Calls { get; } = [];
    public int Tokens { get; set; } = 5;
    public bool Disposed { get; private set; }
    public Func<CancellationToken, Task<float[]>> Evaluate { get; set; } = _ => Task.FromResult(Vector());
    public static float[] Vector() { var result = new float[1024]; result[0] = 3; result[1] = 4; return result; }
    public int CountTokens(string text) => Tokens;
    public Task<float[]> EmbedAsync(string text, int capacity, CancellationToken cancellationToken)
    { Calls.Add((text, capacity)); return Evaluate(cancellationToken); }
    public void Dispose() => Disposed = true;
}

internal sealed class FakeSpeechEngine : ISpeechEngine
{
    public InferenceBackend Backend => InferenceBackend.DirectML;
    public List<byte[]> Audio { get; } = [];
    public List<string[]> Terms { get; } = [];
    public int Flushes { get; private set; }
    public bool Disposed { get; private set; }
    public Func<bool, SpeechResult> Respond { get; set; } = _ => new([], "", false);
    public void SetTerms(IReadOnlyList<string> terms) => Terms.Add(terms.ToArray());
    public SpeechResult Accept(ReadOnlyMemory<byte> pcm, bool flush = false)
    {
        if (flush) Flushes++; else Audio.Add(pcm.ToArray());
        return Respond(flush);
    }
    public void Dispose() => Disposed = true;
}

internal sealed class EventLog
{
    private readonly object gate = new();
    private readonly List<LiveEvent> events = [];
    private readonly Dictionary<Type, TaskCompletionSource<LiveEvent>> signals = [];
    public void Add(LiveEvent value)
    {
        lock (gate)
        {
            events.Add(value);
            if (signals.TryGetValue(value.GetType(), out var signal)) signal.TrySetResult(value);
        }
    }
    public IReadOnlyList<LiveEvent> Snapshot() { lock (gate) return events.ToArray(); }
    public async Task<T> Wait<T>() where T : LiveEvent
    {
        Task<LiveEvent> pending;
        lock (gate)
        {
            if (events.OfType<T>().FirstOrDefault() is { } existing) return existing;
            if (!signals.TryGetValue(typeof(T), out var signal))
                signals.Add(typeof(T), signal = new(TaskCreationOptions.RunContinuationsAsynchronously));
            pending = signal.Task;
        }
        return (T)await pending.WaitAsync(TimeSpan.FromSeconds(10));
    }
}
