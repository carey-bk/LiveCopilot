using System.Runtime.InteropServices;
using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

public static class NativeRuntimeSupport
{
    public static bool RequiresCpu => OperatingSystem.IsWindows() && RuntimeInformation.ProcessArchitecture == Architecture.Arm64;
    public const string SpeechMessage = "此架构暂不支持本地听写，请用 x64 版或云端服务";
    public const string EmbeddingMessage = "此架构暂不支持本地嵌入，请用 x64 版或云端服务";
    public static string Notice => RequiresCpu
        ? "此架构暂不支持本地 GPU 加速，请用 x64 版或云端服务。当前 ARM64 包的本地听写与嵌入使用 CPU。" : "";
    public static string? SpeechUnavailable => RequiresCpu && !HasArm64Speech(AppContext.BaseDirectory) ? SpeechMessage : null;
    public static string? EmbeddingUnavailable => RequiresCpu && !HasArm64Embedding(AppContext.BaseDirectory) ? EmbeddingMessage : null;

    // Check files without loading native libraries or probing devices during window startup.
    internal static bool HasArm64Speech(string root) => new[] { "sherpa-onnx-c-api.dll", "onnxruntime.dll" }
        .All(file => File.Exists(Path.Combine(root, file)) || File.Exists(Path.Combine(root, "runtimes", "win-arm64", "native", file)));
    internal static bool HasArm64Embedding(string root) => new[] { "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll" }
        .All(file => File.Exists(Path.Combine(root, "runtimes", "win-arm64", "native", file)));

    public static void RequireSpeech()
    {
        AppRuntime.RequireInteractive("本地推理");
        if (SpeechUnavailable is { } message) throw new CopilotException(message);
    }
    public static void RequireEmbedding()
    {
        AppRuntime.RequireInteractive("本地推理");
        if (EmbeddingUnavailable is { } message) throw new CopilotException(message);
    }
}
