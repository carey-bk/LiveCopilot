using System.Collections;
using System.ComponentModel;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using LiveCopilot.Core;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Updates;

namespace LiveCopilot.Platform.Settings;

/// UI-thread draft. Opening, editing and cancelling never persist anything or call a service.
public sealed partial class SettingsViewModel : ObservableObject, INotifyDataErrorInfo
{
    private readonly IPreferenceStore preferences;
    private readonly HotkeyStore hotkeys;
    private readonly Func<ListeningService, bool> speechInstalled;
    private readonly Func<bool> embeddingInstalled;
    private readonly Func<string?> speechUnavailable, embeddingUnavailable;
    private readonly IUpdateChecker updateChecker = new UnconfiguredUpdateChecker();
    private readonly Dictionary<string, string> errors = [];
    private AppSettings baseline, draft;
    private string status = "", shortcutError = "";
    private bool busy;
    private AnalysisThinking? thinkingChoice;
    public event EventHandler<DataErrorsChangedEventArgs>? ErrorsChanged;
    public event Action<AppSettings>? Saved;
    public event Action? Cancelled;
    public RelayCommand SaveCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand ResetShortcutsCommand { get; }
    public IReadOnlyList<ShortcutEditor> Shortcuts { get; }
    public CredentialEditor OpenAICredential { get; }
    public CredentialEditor SeparateOpenAICredential { get; }
    public CredentialEditor DeepSeekCredential { get; }
    public CredentialEditor CompatibleCredential { get; }
    public CredentialEditor PresetCredential { get; }
    public IReadOnlyList<CredentialEditor> Credentials { get; }
    public bool HasErrors => errors.Count > 0;
    public string ValidationSummary => string.Join("\n", errors.Values.Distinct());
    public string Status { get => status; private set { status = value; Notify(); } }
    public string ShortcutError { get => shortcutError; private set { shortcutError = value; Notify(); } }
    public bool IsBusy { get => busy; set { busy = value; Notify(); Notify(nameof(CanEdit)); SaveCommand.Refresh(); CancelCommand.Refresh(); } }
    public bool CanEdit => !IsBusy;
    public bool HasChanges => HasErrors || draft != baseline || Credentials.Any(c => c.HasPendingChange) || ShortcutsChanged;
    public string Version { get; }
    public string DisplayVersion { get; }
    public string RuntimeNotice { get; }
    public string UpdateNotice => "更新源尚未配置；此开关仅保存偏好，不会联网、下载或安装更新。";
    public async Task<UpdateCheckStatus> CheckUpdatesAsync(CancellationToken cancellationToken = default) =>
        await updateChecker.CheckAsync(CheckForUpdates, cancellationToken);
    public string ProjectUrl => "https://github.com/carey-bk/LiveCopilot";
    public string UnsignedNotice => "此 Windows 版本尚未签名。如果 SmartScreen 拦截，请先确认来自可信来源，再点击“更多信息”→“仍要运行”。";
    public string HistoryNotice => "即将推出";
    public string ListeningHint => ListeningService switch
    {
        ListeningService.Zipformer or ListeningService.Paraformer => speechUnavailable() ?? (speechInstalled(ListeningService)
            ? "本地听写模型已安装。更换引擎在下次开始聆听时生效。"
            : "本地听写模型尚未安装，请在上方模型卡片下载。安装或切换引擎后，重新开始聆听生效。"),
        ListeningService.Apple => "Windows 不支持 Apple 听写，请选择 Zipformer 或 Paraformer。",
        _ => "Windows 云端听写尚未接入，请选择 Zipformer 或 Paraformer。"
    };
    public string EmbeddingHint => (EmbeddingService == EmbeddingService.Local ? embeddingUnavailable() : null)
        ?? (EmbeddingService == EmbeddingService.Local && !embeddingInstalled()
            ? "本地 BGE-M3 尚未安装，请在上方模型卡片下载。安装后无需重启即可导入或重新索引；已有文档仍保留。"
            : "OpenAI 会发送文档分块与检索问题；本地 BGE-M3 在本机生成向量。命中的来源会随回答请求发送给分析服务。");
    public string SelectedEmbeddingIdentity => draft.SelectedEmbeddingIdentity;
    public bool KnowledgeRebuildRequired => draft.EmbeddingService != baseline.EmbeddingService || draft.SelectedEmbeddingIdentity != baseline.SelectedEmbeddingIdentity;
    public string KnowledgeRebuildHint => KnowledgeRebuildRequired
        ? "嵌入服务或模型已变更。保存后请重新索引已有文档，以使用新模型进行语义检索。" : "";
    public bool IsCompatible => ReasoningService == ReasoningService.Compatible;
    public bool IsPreset => ReasoningService.IsPreset();
    public bool IsCatalogService => !IsCompatible;
    public IReadOnlyList<AnalysisModel> Models => AnalysisModelCatalog.ModelsFor(ReasoningService);
    public IReadOnlyList<SettingChoice<AnalysisThinking>> ThinkingModes => ReasoningService.AvailableThinkingModes(AnalysisModel)
        .Select(v => new SettingChoice<AnalysisThinking>(v, ThinkingLabel(v))).ToArray();

    public SettingsViewModel(IPreferenceStore preferences, ICredentialStore credentials, HotkeyStore hotkeys,
        Func<ListeningService, bool>? speechInstalled = null, Func<bool>? embeddingInstalled = null, Assembly? assembly = null,
        Func<string?>? speechUnavailable = null, Func<string?>? embeddingUnavailable = null, string runtimeNotice = "")
    {
        this.preferences = preferences; this.hotkeys = hotkeys;
        this.speechInstalled = speechInstalled ?? (_ => false); this.embeddingInstalled = embeddingInstalled ?? (() => false);
        this.speechUnavailable = speechUnavailable ?? (() => null); this.embeddingUnavailable = embeddingUnavailable ?? (() => null);
        RuntimeNotice = runtimeNotice;
        baseline = AppSettings.Load(preferences); draft = baseline with { };
        var versionAssembly = assembly ?? Assembly.GetEntryAssembly() ?? typeof(SettingsViewModel).Assembly;
        Version = versionAssembly.GetName().Version?.ToString() ?? "未知";
        DisplayVersion = versionAssembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? Version;
        SaveCommand = new(() => Save(), () => !HasErrors && !IsBusy);
        CancelCommand = new(Cancel, () => !IsBusy);
        OpenAICredential = new("共享 OpenAI（听写 / 知识库 / 共享推理）", credentials, CredentialReference.Live);
        SeparateOpenAICredential = new("独立 OpenAI 推理", credentials, CredentialReference.SeparateOpenAI);
        DeepSeekCredential = new("DeepSeek", credentials, CredentialReference.DeepSeek);
        CompatibleCredential = new("兼容接口（密钥按接口地址隔离）", credentials, CompatibleReference());
        PresetCredential = new("当前预设服务", credentials, PresetReference());
        Credentials = [OpenAICredential, SeparateOpenAICredential, DeepSeekCredential, CompatibleCredential, PresetCredential];
        foreach (var credential in Credentials) credential.Changed += () => Notify(nameof(HasChanges));
        Shortcuts = Enum.GetValues<SuggestionMode>().Select(mode => new ShortcutEditor(mode, hotkeys.Combo(mode), RecordShortcut))
            .Append(new(null, hotkeys.ToggleOverlay, RecordShortcut)).ToArray();
        ResetShortcutsCommand = new(() => { foreach (var shortcut in Shortcuts) shortcut.Assign(shortcut.Default); ShortcutError = ""; Updated(); });
        Validate();
    }

    public IEnumerable GetErrors(string? propertyName) => string.IsNullOrEmpty(propertyName) ? errors.Values.ToArray()
        : errors.TryGetValue(propertyName, out var error) ? new[] { error } : Array.Empty<string>();
    public AppSettings Snapshot() => draft with { };
    public void RefreshModelAvailability() { Notify(nameof(ListeningHint)); Notify(nameof(EmbeddingHint)); }
    public override string ToString() => "LiveCopilot 设置草稿（不包含凭据）";
    private bool ShortcutsChanged => Shortcuts.Any(s => s.Combo != (s.Mode is { } mode ? hotkeys.Combo(mode) : hotkeys.ToggleOverlay));

    private void Edit(Action change, [CallerMemberName] string? property = null)
    { change(); Notify(property); Updated(); }
    private void Updated()
    {
        Status = ""; Validate(); Notify(nameof(HasChanges));
        Notify(nameof(KnowledgeRebuildRequired)); Notify(nameof(KnowledgeRebuildHint));
        Notify(nameof(SelectedEmbeddingIdentity)); Notify(nameof(EmbeddingHint));
    }
    private void RefreshService()
    {
        Notify(nameof(Models)); Notify(nameof(AnalysisModel)); Notify(nameof(ThinkingModes)); Notify(nameof(AnalysisThinking));
        Notify(nameof(IsCompatible)); Notify(nameof(IsCatalogService)); Notify(nameof(IsPreset));
        PresetCredential.Retarget(PresetReference());
    }
    private CredentialReference? CompatibleReference()
    {
        if (!ValidCompatibleBase() || !ValidCompatiblePath()) return null;
        try { return new("LiveCopilot-Reasoning-Compatible", "|" + draft.CompatibleEndpoint().AbsoluteUri); }
        catch (Exception) { return null; }
    }
    private CredentialReference? PresetReference()
    {
        if (!IsPreset) return null;
        try { return draft.AnalysisCredentialReference(); } catch (Exception) { return null; }
    }

    public void RecordShortcut(ShortcutEditor shortcut, HotkeyCombo combo)
    {
        if (!Shortcuts.Contains(shortcut)) return;
        var error = ShortcutValidation.Error(combo);
        if (error is not null) { ShortcutError = error; return; }
        if (Shortcuts.Any(other => other != shortcut && other.Combo == combo))
        { ShortcutError = "该快捷键已绑定其他动作，请先更换冲突动作的绑定。"; return; }
        shortcut.Assign(combo); ShortcutError = ""; Updated();
    }

    public bool Save()
    {
        Validate();
        if (IsBusy || HasErrors) { Status = "请先修正设置错误，并等待文档操作结束。"; return false; }
        byte[]? previous = null;
        var wrotePreferences = false;
        var undo = new Stack<Action>();
        try
        {
            previous = preferences.Get(AppSettings.DefaultsKey);
            // Read every rollback value before the first write. No secret leaves ICredentialStore.
            foreach (var credential in Credentials)
                if (credential.PrepareRollback() is { } rollback) undo.Push(rollback);
            foreach (var credential in Credentials) credential.Commit();
            wrotePreferences = true; draft.Save(preferences);
            if (ShortcutsChanged && !hotkeys.ApplySnapshot(Shortcuts.Where(s => s.Mode.HasValue).ToDictionary(s => s.Mode!.Value, s => s.Combo), Shortcuts.Single(s => s.Mode is null).Combo))
                throw new InvalidOperationException();
        }
        catch (Exception error)
        {
            var restored = error is not HotkeyPersistenceException { Restored: false };
            if (wrotePreferences)
            {
                try { if (previous is not null) preferences.Set(AppSettings.DefaultsKey, previous); else baseline.Save(preferences); }
                catch (Exception) { restored = false; }
            }
            while (undo.TryPop(out var rollback)) { try { rollback(); } catch (Exception) { restored = false; } }
            Status = restored ? "保存失败，请检查凭据管理器和本地目录权限后重试。" : "保存失败，部分设置可能已写入。请检查存储权限并重新打开设置核对。";
            return false;
        }
        var rebuild = KnowledgeRebuildRequired;
        baseline = draft with { };
        foreach (var credential in Credentials) credential.Cancel();
        Notify(nameof(HasChanges)); Notify(nameof(KnowledgeRebuildRequired)); Notify(nameof(KnowledgeRebuildHint));
        Status = hotkeys.NotificationFailed ? "设置已保存，但快捷键刷新失败，请重新启动应用。"
            : rebuild ? "设置已保存；请重新索引已有文档。" : "设置已保存。听写引擎在下次开始时生效。";
        // Persistence is complete. Give every consumer its own snapshot even if another
        // consumer fails, so the session and password inputs still receive the update.
        if (Saved is { } handlers)
            foreach (Action<AppSettings> handler in handlers.GetInvocationList())
                try { handler(draft with { }); }
                catch (Exception) { Status = "设置已保存，但运行中界面刷新失败；请重新启动应用。"; }
        return true;
    }

    public void Cancel()
    {
        if (IsBusy) return;
        draft = baseline with { }; thinkingChoice = null;
        transcriptText = answerText = retrievalText = null;
        foreach (var credential in Credentials) credential.Cancel();
        CompatibleCredential.Retarget(CompatibleReference()); RefreshService();
        foreach (var shortcut in Shortcuts) shortcut.Assign(shortcut.Mode is { } mode ? hotkeys.Combo(mode) : hotkeys.ToggleOverlay);
        ShortcutError = ""; Status = "已丢弃未保存修改。"; Validate(); Notify(""); Cancelled?.Invoke();
    }

    private bool ValidCompatibleBase() => Uri.TryCreate(CompatibleBaseURL.Trim(), UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.Host.Length > 0
        && uri.UserInfo.Length == 0 && !CompatibleBaseURL.Any(c => c is '?' or '#' or '@' or '\\' || char.IsWhiteSpace(c));
    private bool ValidCompatiblePath()
    {
        var decoded = Uri.UnescapeDataString(CompatiblePath);
        return !string.IsNullOrWhiteSpace(decoded) && decoded.Trim('/') != "" && !decoded.Contains(':')
            && !decoded.Any(c => c is '?' or '#' or '\\' || char.IsWhiteSpace(c)) && !decoded.Split('/').Any(p => p is ".." or ".");
    }

    private void Validate()
    {
        var next = new Dictionary<string, string>();
        void Require(bool valid, string property, string message) { if (!valid) next[property] = message; }
        Require(double.IsFinite(TranscriptFontSize) && TranscriptFontSize >= OverlayTypography.Minimum && TranscriptFontSize <= OverlayTypography.Maximum,
            nameof(TranscriptFontSize), "转写字体大小须为 11–28。" );
        Require(double.IsFinite(AnswerFontSize) && AnswerFontSize >= OverlayTypography.Minimum && AnswerFontSize <= OverlayTypography.Maximum,
            nameof(AnswerFontSize), "回答字体大小须为 11–28。" );
        Require(RetrievalCount is >= 3 and <= 8, nameof(RetrievalCount), "检索数量须为 3–8 的整数。" );
        Require(AdditionalAnswerInstructions.Length <= 4000, nameof(AdditionalAnswerInstructions), "附加回答指令不能超过 4000 个 UTF-16 单元。" );
        Require(EmbeddingService == EmbeddingService.Local || !string.IsNullOrWhiteSpace(EmbeddingModel), nameof(EmbeddingModel), "请输入嵌入模型名称。" );
        Require(Enum.IsDefined(AnalysisThinking) && ThinkingModes.Any(mode => mode.Value == AnalysisThinking), nameof(AnalysisThinking), "请选择当前模型支持的推理强度。");
        Require(IsCompatible || AnalysisModelCatalog.Model(AnalysisModel, ReasoningService) is not null, nameof(AnalysisModel), "请选择当前推理服务支持的模型。" );
        if (IsCompatible || CompatibleBaseURL.Length > 0 || CompatibleModel.Length > 0)
        {
            Require(ValidCompatibleBase(), nameof(CompatibleBaseURL), "兼容接口 BaseURL 必须是 HTTPS 地址，不能含凭据、空白、查询参数或片段。" );
            Require(ValidCompatiblePath(), nameof(CompatiblePath), "请输入有效的相对接口路径（如 chat/completions），不能含查询参数或路径跳转。" );
            Require(!string.IsNullOrWhiteSpace(CompatibleModel), nameof(CompatibleModel), "请输入兼容接口模型名称。" );
        }
        foreach (var property in new[] { nameof(Background), nameof(Language), nameof(AnswerLanguage), nameof(Scenario), nameof(ContinuousQuestionPolicy), nameof(ListeningService), nameof(LiveSpeechLanguage), nameof(ReasoningService), nameof(KnowledgeMode), nameof(EmbeddingService) })
        {
            var value = typeof(SettingsViewModel).GetProperty(property)!.GetValue(this)!;
            Require(Enum.IsDefined(value.GetType(), value), property, "请选择有效的设置选项。" );
        }
        foreach (var shortcut in Shortcuts)
            if (ShortcutValidation.Error(shortcut.Combo) is { } error) next[nameof(Shortcuts)] = error;
        if (Shortcuts.Select(s => s.Combo).Distinct().Count() != Shortcuts.Count) next[nameof(Shortcuts)] = "快捷键绑定重复。";
        foreach (var pair in new[] { (nameof(TranscriptFontSize), nameof(TranscriptFontSizeText)), (nameof(AnswerFontSize), nameof(AnswerFontSizeText)), (nameof(RetrievalCount), nameof(RetrievalCountText)) })
            if (next.TryGetValue(pair.Item1, out var message)) next[pair.Item2] = message;
        var changed = errors.Keys.Union(next.Keys).Where(k => errors.GetValueOrDefault(k) != next.GetValueOrDefault(k)).ToArray();
        errors.Clear(); foreach (var pair in next) errors.Add(pair.Key, pair.Value);
        foreach (var property in changed) ErrorsChanged?.Invoke(this, new(property));
        Notify(nameof(HasErrors)); Notify(nameof(ValidationSummary)); SaveCommand.Refresh();
    }
    public AppBackground Background { get => draft.Background; set => Edit(() => draft.Background = value); }
    public double LayaThreshold { get => draft.LayaThreshold; set => Edit(() => draft.LayaThreshold = value); }
    public bool RecapEnabled { get => draft.RecapEnabled; set => Edit(() => draft.RecapEnabled = value); }
    public bool FollowUpEnabled { get => draft.FollowUpEnabled; set => Edit(() => draft.FollowUpEnabled = value); }
    public AppLanguage Language { get => draft.Language; set => Edit(() => draft.Language = value); }
    public AnswerLanguage AnswerLanguage { get => draft.AnswerLanguage; set => Edit(() => draft.AnswerLanguage = value); }
    public ScenarioProfile Scenario { get => draft.Scenario; set => Edit(() => draft.Scenario = value); }
    public bool AutomaticSuggestions { get => draft.AutomaticSuggestions; set => Edit(() => draft.AutomaticSuggestions = value); }
    public bool CheckForUpdates { get => draft.CheckForUpdates; set => Edit(() => draft.CheckForUpdates = value); }
    public ContinuousQuestionPolicy ContinuousQuestionPolicy { get => draft.ContinuousQuestionPolicy; set => Edit(() => draft.ContinuousQuestionPolicy = value); }
    public bool BilingualAnswers { get => draft.BilingualAnswers; set => Edit(() => draft.BilingualAnswers = value); }
    public string AdditionalAnswerInstructions { get => draft.AdditionalAnswerInstructions; set => Edit(() => draft.AdditionalAnswerInstructions = value ?? ""); }
    public bool OverlayAutoHeight { get => draft.OverlayAutoHeight; set => Edit(() => draft.OverlayAutoHeight = value); }
    public bool ExcludeOverlayFromCapture { get => draft.ExcludeOverlayFromCapture; set => Edit(() => draft.ExcludeOverlayFromCapture = value); }
    public LiveSpeechLanguage LiveSpeechLanguage { get => draft.LiveSpeechLanguage; set => Edit(() => draft.LiveSpeechLanguage = value); }
    public KnowledgeMode KnowledgeMode { get => draft.KnowledgeMode; set => Edit(() => draft.KnowledgeMode = value); }
    public EmbeddingService EmbeddingService { get => draft.EmbeddingService; set => Edit(() => draft.EmbeddingService = value); }
    public string EmbeddingModel { get => draft.EmbeddingModel; set => Edit(() => draft.EmbeddingModel = value ?? ""); }
    public ListeningService ListeningService { get => draft.ListeningService; set { Edit(() => draft.ListeningService = value); Notify(nameof(ListeningHint)); } }
    public ReasoningService ReasoningService { get => draft.ReasoningService; set { Edit(() => { draft.SelectAnalysisService(value); thinkingChoice = null; }); RefreshService(); } }
    public string AnalysisModel { get => draft.AnalysisModel; set { if (value is null) return; Edit(() => { draft.SelectAnalysisModel(value); thinkingChoice = null; }); RefreshService(); } }
    public AnalysisThinking AnalysisThinking { get => thinkingChoice ?? draft.AnalysisThinking; set => Edit(() =>
    { thinkingChoice = value; if (ThinkingModes.Any(mode => mode.Value == value)) draft.AnalysisThinking = value; }); }
    public string CompatibleBaseURL { get => draft.CompatibleBaseURL; set { Edit(() => draft.CompatibleBaseURL = value ?? ""); CompatibleCredential.Retarget(CompatibleReference()); } }
    public string CompatiblePath { get => draft.CompatiblePath; set { Edit(() => draft.CompatiblePath = value ?? ""); CompatibleCredential.Retarget(CompatibleReference()); } }
    public string CompatibleModel { get => draft.CompatibleModel; set { Edit(() => draft.CompatibleModel = value ?? ""); Notify(nameof(AnalysisModel)); } }
    private string? transcriptText, answerText, retrievalText;
    public double TranscriptFontSize { get => draft.TranscriptFontSize; set { transcriptText = null; Edit(() => draft.TranscriptFontSize = value); Notify(nameof(TranscriptFontSizeText)); } }
    public double AnswerFontSize { get => draft.AnswerFontSize; set { answerText = null; Edit(() => draft.AnswerFontSize = value); Notify(nameof(AnswerFontSizeText)); } }
    public int RetrievalCount { get => draft.RetrievalCount; set { retrievalText = null; Edit(() => draft.RetrievalCount = value); Notify(nameof(RetrievalCountText)); } }
    public string TranscriptFontSizeText { get => transcriptText ?? TranscriptFontSize.ToString(CultureInfo.CurrentCulture); set { transcriptText = value; Edit(() => draft.TranscriptFontSize = double.TryParse(value, out var v) ? v : double.NaN); Notify(nameof(TranscriptFontSize)); } }
    public string AnswerFontSizeText { get => answerText ?? AnswerFontSize.ToString(CultureInfo.CurrentCulture); set { answerText = value; Edit(() => draft.AnswerFontSize = double.TryParse(value, out var v) ? v : double.NaN); Notify(nameof(AnswerFontSize)); } }
    public string RetrievalCountText { get => retrievalText ?? RetrievalCount.ToString(CultureInfo.CurrentCulture); set { retrievalText = value; Edit(() => draft.RetrievalCount = int.TryParse(value, out var v) ? v : int.MinValue); Notify(nameof(RetrievalCount)); } }
}
