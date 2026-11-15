using LiveCopilot.Core;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Overlay;

/// The editable overlay preferences are committed before they affect future requests.
public sealed class OverlayViewModel : ObservableObject
{
    private AppSettings settings = new();
    private string question = "";
    private bool enabled = true, following = true;
    private readonly Func<AppSettings, bool> save;
    public OverlayViewModel(Func<AppSettings, bool> save, Action<string> ask)
    {
        this.save = save;
        AskCommand = new(() => { ask(Question.Trim()); }, () => enabled && !string.IsNullOrWhiteSpace(Question));
    }
    public RelayCommand AskCommand { get; }
    public string Question { get => question; set { question = value; Notify(); AskCommand.Refresh(); } }
    public KnowledgeMode KnowledgeMode { get => settings.KnowledgeMode; set => Edit(s => s.KnowledgeMode = value); }
    public AnswerLanguage AnswerLanguage { get => settings.AnswerLanguage; set => Edit(s => s.AnswerLanguage = value); }
    public bool IncludeConversation { get => settings.IncludeConversation; set => Edit(s => s.IncludeConversation = value); }
    public bool FollowTranscript { get => following; set { following = value; Notify(); } }
    public IReadOnlyList<SettingChoice<KnowledgeMode>> KnowledgeModes { get; } = [new(KnowledgeMode.General, "通用知识"), new(KnowledgeMode.Hybrid, "混合知识"), new(KnowledgeMode.KnowledgeBaseOnly, "仅知识库")];
    public IReadOnlyList<SettingChoice<AnswerLanguage>> AnswerLanguages { get; } = [new(AnswerLanguage.Auto, "◎ Auto"), new(AnswerLanguage.Chinese, "中文"), new(AnswerLanguage.English, "English")];
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
