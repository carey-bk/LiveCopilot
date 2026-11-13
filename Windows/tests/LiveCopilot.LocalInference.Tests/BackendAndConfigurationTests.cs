using System.Runtime.InteropServices;
using LiveCopilot.Core;
using LLama.Native;
using SherpaOnnx;

namespace LiveCopilot.LocalInference.Tests;

public sealed class BackendAndConfigurationTests
{
    [Fact]
    public void NvidiaPrefersCudaThenDirectMLOrVulkanThenCpu()
    {
        var hardware = new HardwareCapabilities(true, true, true, true);
        Assert.Equal([InferenceBackend.Cuda, InferenceBackend.DirectML, InferenceBackend.Cpu], BackendSelection.Speech(hardware));
        Assert.Equal([InferenceBackend.Cuda, InferenceBackend.Vulkan, InferenceBackend.Cpu], BackendSelection.Embedding(hardware));
    }

    [Fact]
    public void DirectMLOnlyAndCpuOnlyAreSelectableWithoutGpu()
    {
        var options = new InferenceOptions { ForceCpu = false, HardwareProbe = new Probe(new(true, false, true, false)) };
        Assert.Equal([InferenceBackend.DirectML, InferenceBackend.Cpu], BackendSelection.Speech(options.HardwareProbe.Detect(), options.ForceCpu));
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Embedding(options.HardwareProbe.Detect()));
        var cpu = new HardwareCapabilities(false, false, false, false);
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Speech(cpu));
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Embedding(cpu));
    }

    [Fact]
    public void ForcedCpuOverridesAllDetectedAccelerators()
    {
        var hardware = new HardwareCapabilities(true, true, true, true);
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Speech(hardware, forceCpu: true));
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Embedding(hardware, forceCpu: true));
        Assert.Equal([InferenceBackend.Cpu], BackendSelection.Speech(new(false, false, true, false)));
    }

    [Fact]
    public void OrtProbeReadsPackagedRuntimeAndRejectsUnavailableProvidersWithoutWeights()
    {
        var library = NativeLibrary.Load("onnxruntime", typeof(OnlineRecognizerConfig).Assembly, null);
        try
        {
            var probe = new OrtProviderProbe(library);
            Assert.Contains("CPUExecutionProvider", probe.AvailableProviders());
            probe.Require(InferenceBackend.Cpu);
            foreach (var (backend, name) in new[] { (InferenceBackend.Cuda, "CUDAExecutionProvider"), (InferenceBackend.DirectML, "DmlExecutionProvider") })
                if (!probe.AvailableProviders().Contains(name)) Assert.Throws<InvalidOperationException>(() => probe.Require(backend));
        }
        finally { NativeLibrary.Free(library); }
    }

    private sealed record Probe(HardwareCapabilities Hardware) : IHardwareProbe
    { public HardwareCapabilities Detect() => Hardware; }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void NativeConfigurationPreservesUtf8PathsAndAbiLayout(bool contextual)
    {
        var config = SpeechConfiguration.Recognizer("模型/张三", contextual, InferenceBackend.Cpu);
        using var native = new Utf8NativeConfig<OnlineRecognizerConfig>(config);
        var modelAddress = native.Pointer + (int)Marshal.OffsetOf<OnlineRecognizerConfig>(nameof(config.ModelConfig));
        var tokenAddress = modelAddress + (int)Marshal.OffsetOf<OnlineModelConfig>(nameof(config.ModelConfig.Tokens));
        Assert.Equal(config.ModelConfig.Tokens, Marshal.PtrToStringUTF8(Marshal.ReadIntPtr(tokenAddress)));
        var featureAddress = native.Pointer + (int)Marshal.OffsetOf<OnlineRecognizerConfig>(nameof(config.FeatConfig));
        Assert.Equal(16000, Marshal.ReadInt32(featureAddress + (int)Marshal.OffsetOf<FeatureConfig>(nameof(config.FeatConfig.SampleRate))));
        using var vad = new Utf8NativeConfig<VadModelConfig>(SpeechConfiguration.Vad("模型"));
        var sileroAddress = vad.Pointer + (int)Marshal.OffsetOf<VadModelConfig>(nameof(VadModelConfig.SileroVad));
        var vadModelAddress = sileroAddress + (int)Marshal.OffsetOf<SileroVadModelConfig>(nameof(SileroVadModelConfig.Model));
        Assert.Equal(System.IO.Path.Combine("模型", "silero_vad.onnx"), Marshal.PtrToStringUTF8(Marshal.ReadIntPtr(vadModelAddress)));
    }

    [Fact]
    public void SherpaCpuAdapterLoadsMatchingPackagedRuntimeWithoutWeights()
    {
        var api = SherpaNativeApi.Load(new() { ForceCpu = true });
        Assert.Equal(InferenceBackend.Cpu, api.Backend);
        Assert.Contains(api.Attempts, x => x.Backend == InferenceBackend.Cpu && x.Outcome == "loaded");
        Assert.NotNull(api.Function<SherpaNativeApi.CreateRecognizer>("CreateOnlineRecognizer"));
        Assert.NotNull(api.Function<SherpaNativeApi.CreateHotwordStream>("CreateOnlineStreamWithHotwords"));
    }

    [Fact]
    public void VadPinsMatchMacNativeConfiguration()
    {
        var v = SpeechConfiguration.Vad("models");
        Assert.Equal(16000, v.SampleRate);
        Assert.Equal(1, v.NumThreads);
        Assert.Equal("cpu", v.Provider);
        Assert.Equal(System.IO.Path.Combine("models", "silero_vad.onnx"), v.SileroVad.Model);
        Assert.Equal(0.5f, v.SileroVad.Threshold);
        Assert.Equal(0.65f, v.SileroVad.MinSilenceDuration);
        Assert.Equal(0.2f, v.SileroVad.MinSpeechDuration);
        Assert.Equal(12f, v.SileroVad.MaxSpeechDuration);
        Assert.Equal(512, v.SileroVad.WindowSize);
        Assert.Equal(30f, SpeechConfiguration.VadBufferSeconds);
        Assert.Equal(8000, SpeechConfiguration.PreRollSamples);
        Assert.Equal(16000, SpeechConfiguration.FinalPaddingSamples);
    }

    [Theory]
    [InlineData(false, InferenceBackend.Cpu, "cpu")]
    [InlineData(false, InferenceBackend.Cuda, "cuda")]
    [InlineData(true, InferenceBackend.DirectML, "directml")]
    public void RecognizerPinsMatchMacAndSelectedProvider(bool terms, InferenceBackend backend, string provider)
    {
        var c = SpeechConfiguration.Recognizer("models", terms, backend);
        Assert.Equal(16000, c.FeatConfig.SampleRate);
        Assert.Equal(80, c.FeatConfig.FeatureDim);
        Assert.Equal(2, c.ModelConfig.NumThreads);
        Assert.Equal(provider, c.ModelConfig.Provider);
        Assert.Equal(0, c.EnableEndpoint); // Silero owns finalization
        Assert.Equal(4, c.MaxActivePaths);
        Assert.Equal(3f, c.HotwordsScore);
        Assert.Equal(System.IO.Path.Combine("models", "tokens.txt"), c.ModelConfig.Tokens);
        if (terms)
        {
            Assert.Equal("modified_beam_search", c.DecodingMethod);
            Assert.EndsWith("encoder.int8.onnx", c.ModelConfig.Transducer.Encoder);
            Assert.EndsWith("decoder.onnx", c.ModelConfig.Transducer.Decoder);
            Assert.EndsWith("joiner.int8.onnx", c.ModelConfig.Transducer.Joiner);
            Assert.EndsWith("bpe.vocab", c.ModelConfig.BpeVocab);
            Assert.Equal("cjkchar+bpe", c.ModelConfig.ModelingUnit);
        }
        else
        {
            Assert.Equal("greedy_search", c.DecodingMethod);
            Assert.EndsWith("encoder.int8.onnx", c.ModelConfig.Paraformer.Encoder);
            Assert.EndsWith("decoder.int8.onnx", c.ModelConfig.Paraformer.Decoder);
        }
    }

    [Fact]
    public void AudioIsLittleEndianPcm16AndBacklogIsTwelveSeconds()
    {
        Assert.Equal(new float[] { 0, -1, 32767f / 32768, 1f / 32768 }, SpeechConfiguration.DecodePcm([0, 0, 0, 128, 255, 127, 1, 0]));
        Assert.Equal(16, SpeechConfiguration.DecodePcm(new byte[32]).Length);
        Assert.Equal(32, SpeechConfiguration.BytesPerMillisecond);
        Assert.Equal(12000, RecognitionStats.MaximumBacklogMs);
        Assert.Equal(384000, SpeechConfiguration.MaximumBacklogBytes);
        Assert.Throws<ArgumentException>(() => SpeechConfiguration.DecodePcm([0]));
        Assert.Throws<ArgumentException>(() => SpeechConfiguration.DecodePcm(new byte[480002]));
        Assert.Empty(SpeechConfiguration.DecodePcm([]));
    }

    [Fact]
    public void HotwordCapsAndEscapingMatchMac()
    {
        Assert.Equal("GPU\n启衡", SpeechConfiguration.Hotwords(["gpu", "启衡"]));
        Assert.Equal("", SpeechConfiguration.Hotwords([]));
        SpeechConfiguration.Hotwords(Enumerable.Repeat(new string('a', 100), 100).ToArray());
        Assert.Throws<ArgumentException>(() => SpeechConfiguration.Hotwords(new string[101]));
        Assert.Throws<ArgumentException>(() => SpeechConfiguration.Hotwords([new string('a', 101)]));
        foreach (var invalid in new[] { "a/b", "a\nb", "a\rb", "a:b", "a#b" })
            Assert.Throws<ArgumentException>(() => SpeechConfiguration.Hotwords([invalid]));
    }

    [Theory]
    [InlineData(true, 0)]
    [InlineData(false, 99)]
    public void EmbeddingParametersPinClsAndSingleMicrobatch(bool cpu, int layers)
    {
        var p = EmbeddingContract.Parameters("bge.gguf", 8192, cpu);
        Assert.Equal(8192u, p.ContextSize);
        Assert.Equal(8192u, p.BatchSize);
        Assert.Equal(p.BatchSize, p.UBatchSize);
        Assert.Equal(LLamaPoolingType.CLS, p.PoolingType);
        Assert.Equal(layers, p.GpuLayerCount);
        Assert.True(p.Embeddings);
        Assert.Equal(cpu, p.NoKqvOffload);
        Assert.Equal(!cpu, p.OpOffload);
    }
}
