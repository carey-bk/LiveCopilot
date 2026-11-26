using LiveCopilot.Platform.Settings;
using LiveCopilot.Core;

namespace LiveCopilot.Platform.Onboarding;

public enum OnboardingUsage { RemoteMeeting, InPerson, Typing }
public sealed record OnboardingUsageChoice(OnboardingUsage Value, string Label, string Description, string Icon);
public sealed record OnboardingProgressSegment(bool Reached, bool Current);

public sealed class OnboardingViewModel : ObservableObject
{
    private readonly OnboardingStateStore store;
    private OnboardingState state;
    private bool closed;
    private OnboardingUsage usage;
    private string error = "";
    public SettingsViewModel Settings { get; }
    public OnboardingViewModel(OnboardingStateStore store, SettingsViewModel settings, bool reopen = false)
    {
        this.store = store; Settings = settings;
        state = store.Load();
        usage = state.PrefersTyping ? OnboardingUsage.Typing : Settings.Mode == OperatingMode.InPerson ? OnboardingUsage.InPerson : OnboardingUsage.RemoteMeeting;
        if (!reopen && state.Step == 0 && !state.Completed && Settings.Language == AppLanguage.System)
            Settings.Language = AppLanguage.SimplifiedChinese;
        if (reopen) state = state with { Step = 0 };
        NextCommand = new(Next, () => !closed && !Settings.IsBusy);
        BackCommand = new(() => Move(state with { Step = Step - 1 }), () => !closed && Step > 0 && !Settings.IsBusy);
        SkipCommand = new(() => { if (Move(state with { Completed = true, Skipped = true })) Finish(); }, () => !closed && !Settings.IsBusy);
        Settings.PropertyChanged += (_, _) => { NextCommand.Refresh(); BackCommand.Refresh(); SkipCommand.Refresh(); };
    }
    public IReadOnlyList<OnboardingUsageChoice> UsageChoices { get; } =
    [
        new(OnboardingUsage.RemoteMeeting, "远程会议", "系统声音与麦克风", "\uE95B"),
        new(OnboardingUsage.InPerson, "现场交流", "仅麦克风，不区分具体说话人", "\uE716"),
        new(OnboardingUsage.Typing, "先输入问题", "无需开启监听", "\uE765")
    ];
    public OnboardingUsage Usage
    {
        get => usage;
        set
        {
            if (!Enum.IsDefined(value)) return;
            usage = value;
            if (value != OnboardingUsage.Typing) Settings.Mode = value == OnboardingUsage.InPerson ? OperatingMode.InPerson : OperatingMode.Remote;
            Notify();
        }
    }
    public IReadOnlyList<OnboardingProgressSegment> Segments => Enumerable.Range(0, 6).Select(i => new OnboardingProgressSegment(i <= Step, i == Step)).ToArray();
    public event Action? Finished;
    public RelayCommand NextCommand { get; }
    public RelayCommand BackCommand { get; }
    public RelayCommand SkipCommand { get; }
    public int Step => state.Step;
    public int Progress => Step + 1;
    public string StepLabel => $"第 {Progress} 步，共 6 步";
    public string NextLabel => IsReady ? "进入 LiveCopilot" : "继续";
    public string Error => error;
    public bool IsLanguage => Step == 0;
    public bool IsScenario => Step == 1;
    public bool IsModels => Step == 2;
    public bool IsAnalysis => Step == 3;
    public bool IsPermissions => Step == 4;
    public bool IsReady => Step == 5;
    public string Title => Step switch
    {
        0 => "准备一下，\n从容开口。", 1 => "专注对话，\n让思路跟上。", 2 => "语音与检索配置",
        3 => "连接你的回答服务", 4 => "选择让助手\n听到什么。", _ => "开始你的\n第一次体验。"
    };
    public string Subtitle => Step switch
    {
        0 => "选择界面语言，之后随时可以在设置中更改。",
        1 => "看懂对话，查找资料，获得回答建议。",
        2 => "选择本地或 OpenAI 云端语音，以及资料检索服务；也可稍后在设置中完成。",
        3 => "由你选择的 AI 服务生成回答，配置 API Key 后即可使用。",
        4 => "打开 Windows 隐私设置检查麦克风访问。仅输入问题，无需音频权限。",
        _ => "查看当前准备情况，然后前往悬浮窗开始。以后可以从设置重新打开引导。"
    };
    private void Next()
    {
        if (!Settings.Save()) { error = Settings.Status; Notify(nameof(Error)); return; }
        if (IsReady) { if (Move(state with { Completed = true, Skipped = false, PrefersTyping = Usage == OnboardingUsage.Typing })) Finish(); }
        else Move(state with { Step = Step + 1, PrefersTyping = Usage == OnboardingUsage.Typing });
    }
    private bool Move(OnboardingState next)
    {
        try { store.Save(next); }
        catch (Exception) { error = "无法保存引导进度，请检查本地目录权限后重试。"; Notify(nameof(Error)); return false; }
        state = next; error = ""; Notify(""); BackCommand.Refresh(); NextCommand.Refresh();
        return true;
    }
    public void Stop()
    {
        closed = true; NextCommand.Refresh(); BackCommand.Refresh(); SkipCommand.Refresh();
        Settings.Cancel();
    }
    private void Finish() { Stop(); Finished?.Invoke(); }
}
