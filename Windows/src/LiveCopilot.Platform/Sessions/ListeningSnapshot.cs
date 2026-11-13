using LiveCopilot.Core;

namespace LiveCopilot.Platform.Sessions;

public enum ListeningState { Idle, Starting, Listening, Failed, Stopped }

/// Host-supplied capabilities keep Platform independent of the inference implementation.
/// UpdateTerms is required for Zipformer. Backend must describe an observed backend only.
public sealed record ListeningProvider(ILiveProvider Provider,
    Action<IReadOnlyList<string>>? UpdateTerms = null, Func<string?>? Backend = null);

public sealed record ListeningPathSnapshot(bool Capturing = false, string? SourceDescription = null,
    string? Backend = null, bool SpeechActive = false);

public sealed record ListeningSnapshot
{
    public ListeningState State { get; init; }
    public bool IsStopping { get; init; }
    public string? Error { get; init; }
    public int SampleRate { get; init; }
    public ListeningPathSnapshot System { get; init; } = new();
    public ListeningPathSnapshot Microphone { get; init; } = new();
    public ValueList<TranscriptLine> Lines { get; init; } = [];
    public string PartialThem { get; init; } = "";
    public string PartialYou { get; init; } = "";
    public SuggestionMode? LastRequestedMode { get; init; }
    public string? SuggestionStatus { get; init; }
    public string SuggestionText { get; init; } = "";
    public bool SuggestionIsLoading { get; init; }
    public string? SuggestionError { get; init; }
    public ValueList<RetrievedSource> Sources { get; init; } = [];
    public string? Warning { get; init; }
    public string Status => IsStopping ? "正在停止并保存…" : State switch
    {
        ListeningState.Idle => "未开始聆听",
        ListeningState.Starting => "正在加载本地语音并启动采集…",
        ListeningState.Listening => "正在聆听",
        ListeningState.Failed => "聆听失败",
        _ => "已停止聆听"
    };
}
