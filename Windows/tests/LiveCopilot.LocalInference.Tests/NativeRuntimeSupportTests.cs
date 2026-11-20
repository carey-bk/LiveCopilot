using LiveCopilot.Core;

namespace LiveCopilot.LocalInference.Tests;

public sealed class NativeRuntimeSupportTests
{
    [Fact]
    public void Arm64AvailabilityRequiresEveryNativeDependencyInPublishedLayout()
    {
        var root = Path.Combine(Path.GetTempPath(), "line9-native-" + Guid.NewGuid().ToString("N"));
        var native = Path.Combine(root, "runtimes", "win-arm64", "native");
        Directory.CreateDirectory(native);
        try
        {
            Assert.False(NativeRuntimeSupport.HasArm64Speech(root));
            Assert.False(NativeRuntimeSupport.HasArm64Embedding(root));
            foreach (var name in new[] { "sherpa-onnx-c-api.dll", "onnxruntime.dll" }) File.WriteAllText(Path.Combine(root, name), "fixture");
            foreach (var name in new[] { "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll" }) File.WriteAllText(Path.Combine(native, name), "fixture");
            Assert.True(NativeRuntimeSupport.HasArm64Speech(root));
            Assert.True(NativeRuntimeSupport.HasArm64Embedding(root));
            File.Delete(Path.Combine(root, "onnxruntime.dll"));
            File.Delete(Path.Combine(native, "ggml-base.dll"));
            Assert.False(NativeRuntimeSupport.HasArm64Speech(root));
            Assert.False(NativeRuntimeSupport.HasArm64Embedding(root));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task UnsupportedSpeechIsAChineseFailureEventAndCanCloseNormally()
    {
        await using var provider = new LocalLiveProvider(_ => throw new CopilotException(NativeRuntimeSupport.SpeechMessage));
        var failure = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        provider.OnEvent = value => { if (value is LiveEvent.Failed failed) failure.TrySetResult(failed.Message); };
        provider.Connect("");
        Assert.Equal(NativeRuntimeSupport.SpeechMessage, await failure.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        await provider.DisconnectAsync();
    }
}
