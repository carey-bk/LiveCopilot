using System.Runtime.InteropServices;
using LiveCopilot.Core;

namespace LiveCopilot.LocalInference;

public static class NativeRuntimeSupport
{
    public static bool RequiresCpu => OperatingSystem.IsWindows() && RuntimeInformation.ProcessArchitecture == Architecture.Arm64;
    public const string SpeechMessage = "本地听写 CPU 运行库缺失或不兼容，请重新安装对应架构的完整 Windows 包。";
    public const string EmbeddingMessage = "本地嵌入 CPU 运行库缺失或不兼容，请重新安装对应架构的完整 Windows 包。";
    public static string Notice => OperatingSystem.IsWindows()
        ? "Windows 安装包的本地听写与嵌入默认使用 CPU，无需额外安装 GPU 运行库。" : "";
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
