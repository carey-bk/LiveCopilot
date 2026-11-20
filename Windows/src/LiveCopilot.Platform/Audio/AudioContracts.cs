namespace LiveCopilot.Platform.Audio;

public enum AudioInput { System, Microphone }
public enum PcmEncoding { Int16, Int24, Int32, Float32 }
public readonly record struct PcmFormat(int SampleRate, int Channels, PcmEncoding Encoding)
{
    public int BytesPerSample => Encoding switch { PcmEncoding.Int16 => 2, PcmEncoding.Int24 => 3, _ => 4 };
    public int FrameBytes => Channels * BytesPerSample;
    public void Validate()
    {
        if (SampleRate is < 8000 or > 384000 || Channels is < 1 or > 32 || !Enum.IsDefined(Encoding))
            throw new ArgumentException("Unsupported audio format: expected 8–384 kHz, 1–32 channels, PCM16/24/32 or float32.");
    }
}

public enum AudioFailureKind { PermissionDenied, NoDevice, DeviceChanged, StartFailed, StreamFailed }
public sealed class AudioSourceException(AudioFailureKind kind, string message, Exception? inner = null) : Exception(message, inner)
{
    public AudioFailureKind Kind { get; } = kind;
}

/// Buffers are borrowed until the synchronous callback returns. Implementations must not
/// queue audio for consumers. StopAsync must finish callbacks and release native resources.
public interface IAudioSource : IAsyncDisposable
{
    PcmFormat Format { get; }
    string Description { get; }
    event Action<ReadOnlyMemory<byte>>? DataAvailable;
    event Action<AudioSourceException>? Failed;
    Task StartAsync(CancellationToken cancellationToken);
    Task StopAsync();
}

public interface IAudioSourceFactory
{
    IAudioSource Create(AudioInput input);
}

public interface ICaptureClock
{
    double Seconds { get; }
    Task Delay(TimeSpan duration, CancellationToken cancellationToken);
}

public sealed class CaptureClock : ICaptureClock
{
    public double Seconds => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency;
    public Task Delay(TimeSpan duration, CancellationToken cancellationToken) => Task.Delay(duration, cancellationToken);
}
