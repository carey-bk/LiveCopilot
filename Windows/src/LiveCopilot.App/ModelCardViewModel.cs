using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.App;

// Dispatcher-owned presentation; the manager owns all filesystem/network work.
public sealed class ModelCardViewModel(LocalModelKind kind, LocalModelManager manager) : ObservableObject
{
    private LocalModelSnapshot snapshot = manager.Snapshot(kind);
    public LocalModelKind Kind { get; } = kind;
    public string Name => Kind switch
    {
        LocalModelKind.TerminologySpeech => "Zipformer 中英听写（含 VAD，支持术语）",
        LocalModelKind.StreamingSpeech => "Paraformer 中英听写（含 VAD）",
        _ => "BGE-M3 本地嵌入（Q8 GGUF）"
    };
    public string AutomationId => Kind switch
    {
        LocalModelKind.TerminologySpeech => "ModelCardZipformer",
        LocalModelKind.StreamingSpeech => "ModelCardParaformer",
        _ => "ModelCardEmbedding"
    };
    public string DownloadId => AutomationId + "Download";
    public string Size => LocalModels.Get(Kind).DownloadSize;
    public string Status => snapshot.State == LocalModelState.Failed ? "失败：" + snapshot.Message : snapshot.Message;
    public double Progress => snapshot.Progress;
    public bool IsVerifying => snapshot.State is LocalModelState.Verifying or LocalModelState.Deleting;
    private string? Unavailable => Kind == LocalModelKind.Embedding ? NativeRuntimeSupport.EmbeddingUnavailable : NativeRuntimeSupport.SpeechUnavailable;
    // The shared CPU notice is shown once per page, outside the individual cards.
    public string Hint => Unavailable ?? (AppRuntime.IsSmoke ? "冒烟模式：仅展示模型状态，下载已禁用。"
        : Kind == LocalModelKind.Embedding ? "安装后即可导入或重新索引，无需重启。" : "安装或切换引擎后，重新开始聆听生效。");
    public string Transfer => $"{Bytes(snapshot.DownloadedBytes)} / {Size}" +
        (snapshot.State == LocalModelState.Downloading ? $" · {Bytes((long)snapshot.BytesPerSecond)}/s" : "");
    public string DownloadLabel => snapshot.State == LocalModelState.Failed ? "重试下载" : snapshot.DownloadedBytes > 0 && !snapshot.IsInstalled ? "继续下载" : "下载";
    public bool CanDownload => !snapshot.IsBusy && (!snapshot.IsInstalled || snapshot.State == LocalModelState.Failed) && Unavailable is null && !AppRuntime.IsSmoke;
    public bool CanCancel => snapshot.IsBusy && snapshot.State != LocalModelState.Deleting;
    public bool CanVerify => !snapshot.IsBusy && snapshot.IsInstalled && !AppRuntime.IsSmoke;
    public bool CanDelete => !snapshot.IsBusy && snapshot.HasFiles && !AppRuntime.IsSmoke;
    public void Refresh() { snapshot = manager.Snapshot(Kind); Notify(""); }
    private static string Bytes(long value) => value >= 1_000_000 ? $"{value / 1_000_000d:F1} MB" : value >= 1000 ? $"{value / 1000d:F1} KB" : $"{value} B";
}
