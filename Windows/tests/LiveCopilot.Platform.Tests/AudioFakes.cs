using System.Buffers.Binary;
using LiveCopilot.Platform.Audio;

namespace LiveCopilot.Platform.Tests;

internal sealed class FakeAudioSource : IAudioSource
{
    public PcmFormat Format { get; set; } = new(48000, 2, PcmEncoding.Float32);
    public string Description => "Injected PCM source; no hardware";
    public event Action<ReadOnlyMemory<byte>>? DataAvailable;
    public event Action<AudioSourceException>? Failed;
    public Exception? StartError { get; init; }
    public Exception? StopError { get; init; }
    public TaskCompletionSource? StartGate { get; init; }
    public int Starts { get; private set; }
    public int Stops { get; private set; }
    public int Disposals { get; private set; }
    public TaskCompletionSource DisposedSignal { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Action? DuringStart { get; set; }
    public async Task StartAsync(CancellationToken token)
    {
        Starts++;
        if (StartGate is not null) await StartGate.Task.WaitAsync(token);
        if (StartError is not null) throw StartError;
        DuringStart?.Invoke();
    }
    public Task StopAsync() { Stops++; return StopError is null ? Task.CompletedTask : Task.FromException(StopError); }
    public ValueTask DisposeAsync() { Disposals++; DisposedSignal.TrySetResult(); return ValueTask.CompletedTask; }
    public void Push(byte[] data) => DataAvailable?.Invoke(data);
    public Action<byte[]> SnapshotCallback() { var captured = DataAvailable; return data => captured?.Invoke(data); }
    public void Fail(AudioFailureKind kind = AudioFailureKind.DeviceChanged, string message = "Device changed") => Failed?.Invoke(new(kind, message));
}

internal sealed class FakeAudioFactory(params FakeAudioSource[] sources) : IAudioSourceFactory
{
    public Queue<FakeAudioSource> Sources { get; } = new(sources);
    public List<AudioInput> Requested { get; } = [];
    public IAudioSource Create(AudioInput input) { Requested.Add(input); return Sources.Dequeue(); }
}
internal sealed class FakeClock : ICaptureClock
{
    public double Seconds { get; set; }
    public int Delays { get; private set; }
    public TaskCompletionSource? Gate { get; set; }
    public TaskCompletionSource EnteredDelay { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async Task Delay(TimeSpan duration, CancellationToken token)
    {
        Assert.Equal(TimeSpan.FromMilliseconds(500), duration);
        Delays++;
        EnteredDelay.TrySetResult();
        if (Gate is not null) await Gate.Task.WaitAsync(token);
        token.ThrowIfCancellationRequested();
    }
}
internal static class Signals
{
    public static byte[] Float(int frames, int channels, Func<int, int, float> sample)
    {
        var data = new byte[frames * channels * 4];
        for (var i = 0; i < frames; i++)
            for (var c = 0; c < channels; c++) BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan((i * channels + c) * 4), BitConverter.SingleToInt32Bits(sample(i, c)));
        return data;
    }
    public static short[] Samples(IEnumerable<byte> data)
    {
        var bytes = data.ToArray();
        return Enumerable.Range(0, bytes.Length / 2).Select(i => BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(i * 2))).ToArray();
    }
    public static async Task<byte[]> Capture(byte[] input, PcmFormat format, int rate, int fragmentSize = int.MaxValue)
    {
        var source = new FakeAudioSource { Format = format };
        await using var manager = new AudioCaptureManager(new FakeAudioFactory(source), AudioInput.System);
        manager.Configure(rate);
        var output = new List<byte>();
        manager.Pcm16Available += data => output.AddRange(data.ToArray());
        await manager.StartAsync();
        for (var offset = 0; offset < input.Length;)
        {
            var length = Math.Min(fragmentSize, input.Length - offset);
            source.Push(input.AsSpan(offset, length).ToArray());
            offset += length;
        }
        Assert.Null(manager.LastError);
        await manager.StopAsync();
        return output.ToArray();
    }
}
