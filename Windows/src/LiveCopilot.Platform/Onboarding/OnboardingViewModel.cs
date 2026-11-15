using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Onboarding;

public sealed class OnboardingViewModel : ObservableObject
{
    private readonly OnboardingStateStore store;
    private OnboardingState state;
    private bool closed;
    private string error = "";
    public SettingsViewModel Settings { get; }
    public OnboardingViewModel(OnboardingStateStore store, SettingsViewModel settings, bool reopen = false)
    {
        this.store = store; Settings = settings;
        state = store.Load();
        if (reopen) state = state with { Step = 0 };
        NextCommand = new(Next, () => !closed && !Settings.IsBusy);
        BackCommand = new(() => Move(state with { Step = Step - 1 }), () => !closed && Step > 0 && !Settings.IsBusy);
        SkipCommand = new(() => { if (Move(state with { Completed = true, Skipped = true })) Finish(); }, () => !closed && !Settings.IsBusy);
        Settings.PropertyChanged += (_, _) => { NextCommand.Refresh(); BackCommand.Refresh(); SkipCommand.Refresh(); };
    }
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
        0 => "准备一下，\n从容开口。", 1 => "专注对话，\n让思路跟上。", 2 => "本地能力配置",
        3 => "连接你的回答服务", 4 => "选择让助手\n听到什么。", _ => "开始你的\n第一次体验。"
    };
    public string Subtitle => Step switch
    {
        0 => "选择界面语言，之后随时可以在设置中更改。",
        1 => "实时看懂对话，查找相关资料，获得可以说出口的回答建议。",
        2 => "配置本地语音与资料检索。按需下载，也可以稍后在设置中完成。",
        3 => "由你选择的 AI 服务生成回答，配置 API Key 后即可使用。",
        4 => "打开 Windows 隐私设置检查麦克风访问。仅输入问题，无需音频权限。",
        _ => "查看当前准备情况，然后前往悬浮窗开始。以后可以从设置重新打开引导。"
    };
    private void Next()
    {
        if (!Settings.Save()) { error = Settings.Status; Notify(nameof(Error)); return; }
        if (IsReady) { if (Move(state with { Completed = true, Skipped = false })) Finish(); }
        else Move(state with { Step = Step + 1 });
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
