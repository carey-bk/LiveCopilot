using System.Text.Json;
using LiveCopilot.Core;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Overlay;

public sealed record OperationGuideState(int Step = 0, bool Completed = false);

/// Independent of the setup wizard: skipping tips never changes configured services.
public sealed class OperationGuideViewModel : ObservableObject
{
    public const string Key = "livecopilot.windows.operation-guide.v1";
    private readonly IPreferenceStore preferences;
    private OperationGuideState state;
    private bool visible;
    private string error = "";
    public OperationGuideViewModel(IPreferenceStore preferences)
    {
        this.preferences = preferences;
        state = Load();
        NextCommand = new(() => Move(Step == 3 ? state with { Completed = true } : state with { Step = Step + 1 }), () => visible);
        SkipCommand = new(() => Move(state with { Completed = true }), () => visible);
    }
    public RelayCommand NextCommand { get; }
    public RelayCommand SkipCommand { get; }
    public bool IsVisible => visible;
    public int Step => state.Step;
    public string StepLabel => $"{Step + 1} / 4";
    public string NextLabel => Step == 3 ? "知道了" : "下一条";
    public string Error => error;
    public bool HighlightStart => visible && Step == 0;
    public bool HighlightAnswer => visible && Step == 1;
    public bool HighlightPin => visible && Step == 2;
    public bool HighlightSettings => visible && Step == 3;
    public string Title => Step switch
    {
        0 => "准备好后，再开始监听", 1 => "按需生成回答", 2 => "随时唤出悬浮窗", _ => "在会议共享与录制中隐藏悬浮窗"
    };
    public string ReplyShortcut { get; private set; } = "Ctrl+Alt+Space";
    public string ToggleShortcut { get; private set; } = "Alt+H";
    public bool CaptureProtectionEnabled { get; private set; }
    public string Description => Step switch
    {
        0 => "播放按钮开始采集，停止按钮结束监听。麦克风按钮选择下次监听是否采集麦克风；重置会保存并结束当前会话。查看提示不会开始录音。",
        1 => $"{ReplyShortcut} 或“生成回答”根据当前对话请求建议；也可以直接输入问题。请求使用你配置的回答服务。",
        2 => $"{ToggleShortcut} 显示或隐藏窗口。图钉切换置顶；隐藏后也可双击系统托盘图标唤出。在通用设置中可以重看提示。",
        _ => "悬浮窗在本机保持可见，并从捕获画面中排除。设置和引导仍会出现在共享画面中。使用前请从另一参会端确认效果。当前" + (CaptureProtectionEnabled ? "已开启" : "未开启") + "，可在“设置 → 通用”中调整。"
    };
    public void Configure(string replyShortcut, string toggleShortcut, bool captureProtection)
    {
        ReplyShortcut = replyShortcut; ToggleShortcut = toggleShortcut; CaptureProtectionEnabled = captureProtection;
        Notify(nameof(Description));
    }
    public void Open(bool reopen = false)
    {
        if (!reopen && state.Completed) return;
        if (reopen) state = new();
        visible = true; error = ""; Refresh();
    }
    private OperationGuideState Load()
    {
        try
        {
            var value = preferences.Get(Key) is { } bytes ? JsonSerializer.Deserialize<OperationGuideState>(bytes) : null;
            return value is null ? new() : value with { Step = Math.Clamp(value.Step, 0, 3) };
        }
        catch (JsonException) { return new(); }
    }
    private void Move(OperationGuideState next)
    {
        try { preferences.Set(Key, JsonSerializer.SerializeToUtf8Bytes(next)); }
        catch (Exception) { error = "无法保存提示进度，请检查用户设置目录后重试。"; Notify(nameof(Error)); return; }
        state = next; visible = !next.Completed; error = ""; Refresh();
    }
    private void Refresh() { Notify(""); NextCommand.Refresh(); SkipCommand.Refresh(); }
}
