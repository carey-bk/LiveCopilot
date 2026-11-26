using LiveCopilot.Core;
using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Sessions;

namespace LiveCopilot.Platform.Overlay;

/// The editable overlay preferences are committed before they affect future requests.
public sealed class OverlayViewModel : ObservableObject
{
    private AppSettings settings = new();
    private string question = "";
    private bool enabled = true, following = true, microphoneEnabled = true, resetting;
    private bool sessionControlsEnabled = true;
    private ListeningSnapshot session = new();
    private string sessionActionError = "";
    private readonly Func<AppSettings, bool> save;
    public OverlayViewModel(Func<AppSettings, bool> save, Action<string> ask, Func<Task<bool>>? reset = null, IPreferenceStore? preferences = null)
    {
        this.save = save;
        Guide = new(preferences ?? new MemoryPreferenceStore());
        ToggleMicrophoneCommand = new(() => { microphoneEnabled = !microphoneEnabled; Notify(nameof(MicrophoneEnabled)); Notify(nameof(MicrophoneGlyph)); Notify(nameof(MicrophoneHint)); Notify(nameof(MicrophoneChangeNotice)); }, () => sessionControlsEnabled && !resetting);
        ResetSessionCommand = new(async () =>
        {
            resetting = true; sessionActionError = ""; RefreshCommands(); Notify(nameof(IsResetting));
            try
            {
                if (await reset!()) Question = "";
                else sessionActionError = "会话未能完整保存，保留当前内容。请检查错误后重试。";
            }
            catch (Exception) { sessionActionError = "无法重置会话，当前内容已保留。"; }
            finally { resetting = false; RefreshCommands(); Notify(nameof(IsResetting)); Notify(nameof(SessionActionError)); }
        }, () => reset is not null && sessionControlsEnabled && !resetting && !session.IsStopping);
        AskCommand = new(() => { ask(Question.Trim()); }, () => enabled && !resetting && !string.IsNullOrWhiteSpace(Question));
    }
    public OperationGuideViewModel Guide { get; }
    public RelayCommand AskCommand { get; }
    public RelayCommand ToggleMicrophoneCommand { get; }
    public RelayCommand ResetSessionCommand { get; }
    public bool MicrophoneEnabled => microphoneEnabled;
    public string MicrophoneGlyph => microphoneEnabled ? "\uE720" : "\uEC54";
    public bool IsResetting => resetting;
    public string SessionActionError => sessionActionError;
    public string MicrophoneChangeNotice => session.State == ListeningState.Listening && microphoneEnabled != session.Microphone.Capturing
        ? "麦克风设置将在下次监听生效；当前" + (session.Microphone.Capturing ? "仍在采集。" : "未采集。") : "";
    public string MicrophoneHint => session.State is ListeningState.Starting or ListeningState.Listening
        ? $"下次监听：麦克风{(microphoneEnabled ? "开启" : "关闭")}；当前{(session.Microphone.Capturing ? "正在采集" : "未采集")}。切换后请停止并重新开始。"
        : $"麦克风{(microphoneEnabled ? "开启" : "关闭")} · 点击切换，下次开始监听时生效";
    public void UpdateSession(ListeningSnapshot value, bool controlsEnabled = true)
    {
        session = value; sessionControlsEnabled = controlsEnabled;
        Notify(nameof(MicrophoneHint)); Notify(nameof(MicrophoneChangeNotice)); RefreshCommands();
    }
    private void RefreshCommands() { AskCommand?.Refresh(); ToggleMicrophoneCommand.Refresh(); ResetSessionCommand.Refresh(); }
    public string Question { get => question; set { question = value; Notify(); AskCommand.Refresh(); } }
    public KnowledgeMode KnowledgeMode { get => settings.KnowledgeMode; set => Edit(s => s.KnowledgeMode = value); }
    public AnswerLanguage AnswerLanguage { get => settings.AnswerLanguage; set => Edit(s => s.AnswerLanguage = value); }
    public bool IncludeConversation { get => settings.IncludeConversation; set => Edit(s => s.IncludeConversation = value); }
    public bool FollowTranscript { get => following; set { following = value; Notify(); } }
    public IReadOnlyList<SettingChoice<KnowledgeMode>> KnowledgeModes { get; } = [new(KnowledgeMode.General, "通用知识"), new(KnowledgeMode.Hybrid, "混合知识"), new(KnowledgeMode.KnowledgeBaseOnly, "仅知识库")];
    public IReadOnlyList<SettingChoice<AnswerLanguage>> AnswerLanguages { get; } = [new(AnswerLanguage.Auto, "Auto"), new(AnswerLanguage.Chinese, "中文"), new(AnswerLanguage.English, "English")];
    public void Configure(AppSettings value) { settings = value with { }; Notify(""); }
    public void SetEnabled(bool value) { enabled = value; AskCommand.Refresh(); }
    private void Edit(Action<AppSettings> edit)
    {
        var next = settings with { }; edit(next);
        if (next == settings) return;
        try { if (save(next)) settings = next; }
        finally { Notify(""); }
    }
}
