using System.Diagnostics;
using System.Runtime.InteropServices;
using LiveCopilot.Platform.Audio;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace LiveCopilot.Platform.Windows.Audio;

public sealed class WasapiAudioSourceFactory : IAudioSourceFactory
{
    public IAudioSource Create(AudioInput input) => new WasapiAudioSource(input);
}

/// A fresh source per session/recovery. WASAPI COM clients and events belong to one
/// MTA worker, including disposal. Synchronous emission provides natural backpressure.
public sealed class WasapiAudioSource(AudioInput input) : IAudioSource
{
    private readonly object sync = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CancellationTokenSource? cancellation;
    private Task? worker;
    private bool disposed;
    public PcmFormat Format { get; private set; }
    public string Description { get; private set; } = "WASAPI has not started.";
    public event Action<ReadOnlyMemory<byte>>? DataAvailable;
    public event Action<AudioSourceException>? Failed;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (worker is not null) return ready.Task;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            worker = Task.Factory.StartNew(() => Run(cancellation.Token), CancellationToken.None,
                TaskCreationOptions.LongRunning, TaskScheduler.Default);
            return ready.Task;
        }
    }

    private void Run(CancellationToken token)
    {
        var started = false;
        AudioClient? client = null;
        MMDevice? device = null;
        MMDeviceEnumerator? enumerator = null;
        using var signal = new AutoResetEvent(false);
        EndpointNotifications? notifications = null;
        try
        {
            token.ThrowIfCancellationRequested();
            enumerator = new MMDeviceEnumerator();
            var flow = input == AudioInput.Microphone ? DataFlow.Capture : DataFlow.Render;
            if (!enumerator.HasDefaultAudioEndpoint(flow, Role.Console))
                throw new AudioSourceException(AudioFailureKind.NoDevice, input == AudioInput.Microphone
                    ? "No microphone capture device is available. Connect or enable a microphone in Windows Sound settings."
                    : "No default audio output device is available. Connect or enable speakers/headphones in Windows Sound settings.");
            device = enumerator.GetDefaultAudioEndpoint(flow, Role.Console);
            notifications = new(flow, device.ID);
            enumerator.RegisterEndpointNotificationCallback(notifications);
            WaveFormat wave;
            string? fallback = null;
            if (input == AudioInput.System && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            {
                try
                {
                    client = ProcessLoopback.Activate(token);
                    wave = new WaveFormat(48000, 16, 2);
                    Initialize(client, wave, signal, processLoopback: true);
                    client.Start();
                    started = true;
                    Description = "WASAPI process loopback: excludes this process and its child processes; includes all render endpoints.";
                }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    client?.Dispose(); client = null;
                    fallback = $"Process exclusion unavailable ({e.Message}); capturing default render endpoint INCLUDING LiveCopilot audio.";
                }
            }
            else if (input == AudioInput.System)
                fallback = "Windows build is below 20348; capturing default render endpoint INCLUDING LiveCopilot audio (no process exclusion).";

            if (client is null)
            {
                client = device.AudioClient;
                wave = client.MixFormat;
                Initialize(client, wave, signal, processLoopback: false);
                client.Start();
                started = true;
                Description = input == AudioInput.System ? fallback! : "WASAPI shared-mode default microphone (Console role).";
            }
            else wave = new WaveFormat(48000, 16, 2);

            Format = Translate(wave);
            Format.Validate();
            var capture = client.AudioCaptureClient;
            ready.TrySetResult();
            var lastPacket = Stopwatch.GetTimestamp();
            var waits = new[] { token.WaitHandle, signal };
            while (!token.IsCancellationRequested)
            {
                if (notifications.Changed)
                    throw new AudioSourceException(AudioFailureKind.DeviceChanged, $"{input} audio device changed or disconnected.");
                while (capture.GetNextPacketSize() > 0 && !token.IsCancellationRequested)
                {
                    var pointer = capture.GetBuffer(out var frames, out var flags);
                    try
                    {
                        var data = new byte[checked(frames * Format.FrameBytes)];
                        if ((flags & AudioClientBufferFlags.Silent) == 0) Marshal.Copy(pointer, data, 0, data.Length);
                        // A discontinuity after startup means data was lost, not valid silence.
                        if ((flags & AudioClientBufferFlags.DataDiscontinuity) != 0 && lastPacket != 0 && receivedPacket)
                            throw new AudioSourceException(AudioFailureKind.StreamFailed, "WASAPI audio data was lost. Stop/start listening; keep audio callbacks short.");
                        receivedPacket = true;
                        lastPacket = Stopwatch.GetTimestamp();
                        DataAvailable?.Invoke(data);
                    }
                    finally { capture.ReleaseBuffer(frames); }
                }
                if (input == AudioInput.Microphone && Stopwatch.GetElapsedTime(lastPacket) > TimeSpan.FromSeconds(5))
                    throw new AudioSourceException(AudioFailureKind.DeviceChanged, "Microphone stopped delivering audio. Check the device and Windows microphone privacy settings.");
                WaitHandle.WaitAny(waits, 100);
            }
        }
        catch (OperationCanceledException) { ready.TrySetCanceled(token); }
        catch (Exception e)
        {
            var error = Friendly(e);
            if (!ready.TrySetException(error) && !token.IsCancellationRequested) Failed?.Invoke(error);
        }
        finally
        {
            try
            {
                if (notifications is not null) enumerator?.UnregisterEndpointNotificationCallback(notifications);
                if (started) client?.Stop();
            }
            catch (COMException) { /* A removed endpoint may reject Stop; still release all clients. */ }
            finally
            {
                try { client?.Dispose(); }
                finally { try { device?.Dispose(); } finally { enumerator?.Dispose(); } }
            }
            if (!ready.Task.IsCompleted) ready.TrySetCanceled(token);
        }
    }

    private bool receivedPacket;
    private void Initialize(AudioClient client, WaveFormat format, EventWaitHandle signal, bool processLoopback)
    {
        var flags = AudioClientStreamFlags.EventCallback;
        if (input == AudioInput.System) flags |= AudioClientStreamFlags.Loopback;
        if (processLoopback) flags |= AudioClientStreamFlags.AutoConvertPcm;
        client.Initialize(AudioClientShareMode.Shared, flags, processLoopback ? 0 : 1_000_000, 0, format, Guid.Empty);
        client.SetEventHandle(signal.SafeWaitHandle.DangerousGetHandle());
    }

    private static PcmFormat Translate(WaveFormat format)
    {
        var standard = format is WaveFormatExtensible extensible ? extensible.ToStandardWaveFormat() : format;
        var encoding = (standard.Encoding, standard.BitsPerSample) switch
        {
            (WaveFormatEncoding.IeeeFloat, 32) => PcmEncoding.Float32,
            (WaveFormatEncoding.Pcm, 16) => PcmEncoding.Int16,
            (WaveFormatEncoding.Pcm, 24) => PcmEncoding.Int24,
            (WaveFormatEncoding.Pcm, 32) => PcmEncoding.Int32,
            _ => throw new AudioSourceException(AudioFailureKind.StartFailed, $"Unsupported WASAPI format: {standard}.")
        };
        return new(standard.SampleRate, standard.Channels, encoding);
    }

    private AudioSourceException Friendly(Exception error)
    {
        if (error is AudioSourceException known) return known;
        if (error is UnauthorizedAccessException || error.HResult == unchecked((int)0x80070005))
            return new(AudioFailureKind.PermissionDenied, input == AudioInput.Microphone
                ? "Microphone privacy permission denied. Enable Microphone access and Let desktop apps access your microphone in Windows Settings → Privacy & security → Microphone."
                : "Windows denied system audio access. Check device permissions and Windows audio service.", error);
        if (error.HResult is unchecked((int)0x88890004) or unchecked((int)0x88890026))
            return new(AudioFailureKind.DeviceChanged, $"{input} audio device was invalidated. Check Windows Sound settings.", error);
        return new(AudioFailureKind.StartFailed, $"{input} WASAPI start/capture failed (0x{error.HResult:X8}): {error.Message}", error);
    }

    public async Task StopAsync()
    {
        Task? pending;
        lock (sync) { cancellation?.Cancel(); pending = worker; }
        if (pending is not null) await pending.ConfigureAwait(false);
    }
    public async ValueTask DisposeAsync()
    {
        lock (sync) { if (disposed) return; disposed = true; }
        try { await StopAsync().ConfigureAwait(false); }
        finally { lock (sync) { cancellation?.Dispose(); cancellation = null; } }
    }

    private sealed class EndpointNotifications(DataFlow flow, string deviceId) : IMMNotificationClient
    {
        private int changed;
        public bool Changed => Volatile.Read(ref changed) != 0;
        public void OnDefaultDeviceChanged(DataFlow newFlow, Role role, string defaultDeviceId)
        { if (newFlow == flow && role == Role.Console && defaultDeviceId != deviceId) Interlocked.Exchange(ref changed, 1); }
        public void OnDeviceStateChanged(string id, DeviceState state)
        { if (id == deviceId && state != DeviceState.Active) Interlocked.Exchange(ref changed, 1); }
        public void OnDeviceRemoved(string id) { if (id == deviceId) Interlocked.Exchange(ref changed, 1); }
        public void OnDeviceAdded(string id) { }
        public void OnPropertyValueChanged(string id, PropertyKey key) { }
    }
}
