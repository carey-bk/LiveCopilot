using SherpaOnnx;
using static LiveCopilot.LocalInference.SherpaNativeApi;

namespace LiveCopilot.LocalInference;

/// <summary>One serialized, mono PCM16/16 kHz speech session. Owns all native handles.</summary>
public sealed class SherpaSpeechEngine : ISpeechEngine
{
    private readonly SherpaNativeApi api;
    private readonly bool contextual;
    private IntPtr recognizer, vad, stream;
    private readonly List<float> pending = [], preRoll = [];
    private long processed, received, streamStart;
    private string nextHotwords = "";
    private bool flushed, disposed;
    public InferenceBackend Backend { get; private set; }
    public IReadOnlyList<BackendAttempt> BackendAttempts { get; private set; }

    public static async Task<ISpeechEngine> CreateAsync(string? root = null, bool contextual = false,
        InferenceOptions? options = null, CancellationToken cancellationToken = default)
    {
        var model = LocalModels.Get(contextual ? LocalModelKind.TerminologySpeech : LocalModelKind.StreamingSpeech);
        root ??= LocalModels.DefaultRoot;
        await model.RequireVerifiedAsync(root, cancellationToken).ConfigureAwait(false);
        return await Task.Run<ISpeechEngine>(() => new SherpaSpeechEngine(model.Location(root), contextual, options ?? new()), cancellationToken).ConfigureAwait(false);
    }

    private SherpaSpeechEngine(string directory, bool contextual, InferenceOptions options)
    {
        this.contextual = contextual;
        api = SherpaNativeApi.Load(options);
        Backend = options.ForceCpu ? InferenceBackend.Cpu : api.Backend;
        BackendAttempts = api.Attempts;
        try
        {
            var config = SpeechConfiguration.Recognizer(directory, contextual, Backend);
            using (var native = new Utf8NativeConfig<OnlineRecognizerConfig>(config))
                recognizer = api.Function<CreateRecognizer>("CreateOnlineRecognizer")(native.Pointer);
            if (recognizer == IntPtr.Zero && Backend != InferenceBackend.Cpu)
            {
                BackendAttempts = BackendAttempts.Append(new(Backend, "model_load_failed")).Append(new BackendAttempt(InferenceBackend.Cpu, "retry")).ToArray();
                Backend = InferenceBackend.Cpu;
                config = SpeechConfiguration.Recognizer(directory, contextual, Backend);
                using var native = new Utf8NativeConfig<OnlineRecognizerConfig>(config);
                recognizer = api.Function<CreateRecognizer>("CreateOnlineRecognizer")(native.Pointer);
            }
            if (recognizer == IntPtr.Zero) throw new InvalidOperationException("Local speech model could not load.");
            var vadConfig = SpeechConfiguration.Vad(directory);
            using (var native = new Utf8NativeConfig<VadModelConfig>(vadConfig))
                vad = api.Function<CreateVad>("CreateVoiceActivityDetector")(native.Pointer, SpeechConfiguration.VadBufferSeconds);
            if (vad == IntPtr.Zero) throw new InvalidOperationException("Local VAD model could not load.");
        }
        catch { Dispose(); throw; }
    }
    public void SetTerms(IReadOnlyList<string> terms)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!contextual) throw new InvalidOperationException("Hotwords require the terminology model.");
        nextHotwords = SpeechConfiguration.Hotwords(terms);
    }
    public SpeechResult Accept(ReadOnlyMemory<byte> pcm, bool flush = false)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (flushed) throw new InvalidOperationException("Speech session has been finalized.");
        var samples = SpeechConfiguration.DecodePcm(pcm.Span);
        received += samples.Length;
        pending.AddRange(samples);
        List<SpeechSegmentResult> segments = [];
        var consumed = 0;
        while (pending.Count - consumed >= SpeechConfiguration.WindowSamples)
        {
            Window(pending.GetRange(consumed, SpeechConfiguration.WindowSamples).ToArray(), segments);
            consumed += SpeechConfiguration.WindowSamples;
        }
        pending.RemoveRange(0, consumed);
        if (flush)
        {
            if (pending.Count > 0)
            {
                var last = new float[SpeechConfiguration.WindowSamples];
                pending.CopyTo(last); Window(last, segments); pending.Clear();
            }
            api.Function<One>("VoiceActivityDetectorFlush")(vad);
            Drain(segments); FinalizeStream(segments, received); flushed = true;
        }
        return new(segments, Text(), !flush && api.Function<Check>("VoiceActivityDetectorDetected")(vad) != 0);
    }
    private void Window(float[] samples, List<SpeechSegmentResult> segments)
    {
        processed += samples.Length;
        api.Function<VadWave>("VoiceActivityDetectorAcceptWaveform")(vad, samples, samples.Length);
        if (stream == IntPtr.Zero)
        {
            preRoll.AddRange(samples);
            if (preRoll.Count > SpeechConfiguration.PreRollSamples) preRoll.RemoveRange(0, preRoll.Count - SpeechConfiguration.PreRollSamples);
            if (api.Function<Check>("VoiceActivityDetectorDetected")(vad) != 0)
            {
                stream = contextual && nextHotwords.Length > 0
                    ? api.Function<CreateHotwordStream>("CreateOnlineStreamWithHotwords")(recognizer, nextHotwords)
                    : api.Function<CreateStream>("CreateOnlineStream")(recognizer);
                if (stream == IntPtr.Zero) throw new InvalidOperationException("Local speech stream could not start.");
                streamStart = processed - preRoll.Count;
                Wave(preRoll.ToArray()); preRoll.Clear();
            }
        }
        else Wave(samples);
        if (stream != IntPtr.Zero) DecodeStream();
        Drain(segments);
    }
    private void Wave(float[] samples) => api.Function<Wave>("OnlineStreamAcceptWaveform")(stream, SpeechConfiguration.SampleRate, samples, samples.Length);
    private void DecodeStream()
    {
        while (api.Function<Ready>("IsOnlineStreamReady")(recognizer, stream) != 0)
            api.Function<Decode>("DecodeOnlineStream")(recognizer, stream);
    }
    private string Text()
    {
        if (stream == IntPtr.Zero) return "";
        var result = api.Function<Result>("GetOnlineStreamResult")(recognizer, stream);
        if (result == IntPtr.Zero) throw new InvalidOperationException("Local speech result is invalid.");
        try { return new OnlineRecognizerResult(result).Text; }
        finally { api.Function<One>("DestroyOnlineRecognizerResult")(result); }
    }
    private void FinalizeStream(List<SpeechSegmentResult> segments, long end)
    {
        if (stream == IntPtr.Zero) return;
        Wave(new float[SpeechConfiguration.FinalPaddingSamples]);
        api.Function<Option>("OnlineStreamSetOption")(stream, "is_final", "1");
        api.Function<One>("OnlineStreamInputFinished")(stream);
        DecodeStream();
        var text = Text();
        end = Math.Max(streamStart, Math.Min(received, end));
        if (text.Length > 0) segments.Add(new(text, checked((int)(streamStart / 16)), checked((int)(end / 16))));
        api.Function<One>("DestroyOnlineStream")(stream); stream = IntPtr.Zero; preRoll.Clear();
    }
    private void Drain(List<SpeechSegmentResult> segments)
    {
        while (api.Function<Check>("VoiceActivityDetectorEmpty")(vad) == 0)
        {
            var pointer = api.Function<CreateStream>("VoiceActivityDetectorFront")(vad);
            if (pointer == IntPtr.Zero) throw new InvalidOperationException("Local VAD segment is invalid.");
            try
            {
                var segment = new SpeechSegment(pointer);
                FinalizeStream(segments, (long)segment.Start + segment.Samples.Length);
            }
            finally { api.Function<One>("DestroySpeechSegment")(pointer); }
            api.Function<One>("VoiceActivityDetectorPop")(vad);
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (stream != IntPtr.Zero) api.Function<One>("DestroyOnlineStream")(stream);
        if (vad != IntPtr.Zero) api.Function<One>("DestroyVoiceActivityDetector")(vad);
        if (recognizer != IntPtr.Zero) api.Function<One>("DestroyOnlineRecognizer")(recognizer);
        stream = vad = recognizer = IntPtr.Zero;
    }
}
