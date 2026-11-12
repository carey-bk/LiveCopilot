using System.Buffers.Binary;
using LiveCopilot.Core;
using SherpaOnnx;

namespace LiveCopilot.LocalInference;

public static class SpeechConfiguration
{
    public const int SampleRate = 16000;
    public const int FeatureDimension = 80;
    public const int BytesPerMillisecond = 32;
    public const int WindowSamples = 512;
    public const int PreRollSamples = 8000;
    public const int FinalPaddingSamples = 16000;
    public const int PumpBytes = 16000;
    public const int MaximumInputBytes = 16000 * 2 * 15;
    public const int MaximumBacklogBytes = RecognitionStats.MaximumBacklogMs * BytesPerMillisecond;
    public const float VadBufferSeconds = 30;

    public static OnlineRecognizerConfig Recognizer(string directory, bool contextual, InferenceBackend backend)
    {
        var config = new OnlineRecognizerConfig();
        config.FeatConfig.SampleRate = SampleRate;
        config.FeatConfig.FeatureDim = FeatureDimension;
        config.DecodingMethod = contextual ? "modified_beam_search" : "greedy_search";
        config.MaxActivePaths = 4;
        config.HotwordsScore = 3;
        config.ModelConfig.NumThreads = 2;
        config.ModelConfig.Provider = Provider(backend);
        config.ModelConfig.Tokens = Path.Combine(directory, "tokens.txt");
        if (contextual)
        {
            config.ModelConfig.Transducer.Encoder = Path.Combine(directory, "encoder.int8.onnx");
            config.ModelConfig.Transducer.Decoder = Path.Combine(directory, "decoder.onnx");
            config.ModelConfig.Transducer.Joiner = Path.Combine(directory, "joiner.int8.onnx");
            config.ModelConfig.ModelingUnit = "cjkchar+bpe";
            config.ModelConfig.BpeVocab = Path.Combine(directory, "bpe.vocab");
        }
        else
        {
            config.ModelConfig.Paraformer.Encoder = Path.Combine(directory, "encoder.int8.onnx");
            config.ModelConfig.Paraformer.Decoder = Path.Combine(directory, "decoder.int8.onnx");
        }
        return config;
    }
    public static VadModelConfig Vad(string directory)
    {
        var config = new VadModelConfig { SampleRate = SampleRate, NumThreads = 1, Provider = "cpu" };
        config.SileroVad.Model = Path.Combine(directory, "silero_vad.onnx");
        config.SileroVad.Threshold = 0.5f;
        config.SileroVad.MinSilenceDuration = 0.65f;
        config.SileroVad.MinSpeechDuration = 0.2f;
        config.SileroVad.MaxSpeechDuration = 12;
        config.SileroVad.WindowSize = WindowSamples;
        return config;
    }
    public static string Provider(InferenceBackend backend) => backend switch
    {
        InferenceBackend.Cpu => "cpu", InferenceBackend.Cuda => "cuda", InferenceBackend.DirectML => "directml",
        _ => throw new ArgumentOutOfRangeException(nameof(backend))
    };
    public static string Hotwords(IReadOnlyList<string> terms)
    {
        ArgumentNullException.ThrowIfNull(terms);
        if (terms.Count > 100 || terms.Any(x => x is null || x.Length > 100 || x.IndexOfAny(['/','\n','\r',':','#']) >= 0))
            throw new ArgumentException("Hotwords require at most 100 terms, each at most 100 UTF-16 characters, without /, newline, :, or #.", nameof(terms));
        return string.Join('\n', terms.Select(x => x.ToUpperInvariant()));
    }
    public static float[] DecodePcm(ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length % 2 != 0 || pcm.Length > MaximumInputBytes) throw new ArgumentException("Audio must be mono PCM16 little-endian at 16000 Hz, at most 15 seconds per call.", nameof(pcm));
        var samples = new float[pcm.Length / 2];
        for (var i = 0; i < samples.Length; i++) samples[i] = BinaryPrimitives.ReadInt16LittleEndian(pcm[(i * 2)..]) / 32768f;
        return samples;
    }
}

public sealed record SpeechSegmentResult(string Text, int StartMs, int EndMs);
public sealed record SpeechResult(IReadOnlyList<SpeechSegmentResult> Segments, string Partial, bool Speaking);
public interface ISpeechEngine : IDisposable
{
    InferenceBackend Backend { get; }
    IReadOnlyList<BackendAttempt> BackendAttempts => [];
    void SetTerms(IReadOnlyList<string> terms);
    SpeechResult Accept(ReadOnlyMemory<byte> pcm, bool flush = false);
}
