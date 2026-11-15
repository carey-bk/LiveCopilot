using LiveCopilot.Core;

namespace LiveCopilot.Platform.Settings;

public sealed record SettingChoice<T>(T Value, string Label, bool IsAvailable = true);

public sealed partial class SettingsViewModel
{
    public IReadOnlyList<SettingChoice<AppLanguage>> Languages { get; } = [new(AppLanguage.System, "跟随系统"), new(AppLanguage.SimplifiedChinese, "简体中文"), new(AppLanguage.TraditionalChinese, "繁體中文"), new(AppLanguage.English, "English")];
    public IReadOnlyList<SettingChoice<AnswerLanguage>> AnswerLanguages { get; } = [new(AnswerLanguage.Auto, "自动"), new(AnswerLanguage.Chinese, "中文"), new(AnswerLanguage.English, "英文")];
    public IReadOnlyList<SettingChoice<ScenarioProfile>> Scenarios { get; } = [new(ScenarioProfile.Interview, "面试"), new(ScenarioProfile.Meeting, "会议"), new(ScenarioProfile.Defense, "学术答辩")];
    public IReadOnlyList<SettingChoice<ContinuousQuestionPolicy>> QuestionPolicies { get; } = [new(ContinuousQuestionPolicy.Fast, "快速响应"), new(ContinuousQuestionPolicy.Smart, "智能合并"), new(ContinuousQuestionPolicy.Complete, "等待完整问题")];
    public IReadOnlyList<SettingChoice<ListeningService>> ListeningServices { get; } = [new(ListeningService.Zipformer, "Zipformer · 本地 / 术语增强"), new(ListeningService.Paraformer, "Paraformer · 本地"), new(ListeningService.OpenAI, "OpenAI 云端 · 即将推出", false)];
    public IReadOnlyList<SettingChoice<LiveSpeechLanguage>> SpeechLanguages { get; } = [new(LiveSpeechLanguage.Mixed, "中英混合"), new(LiveSpeechLanguage.Chinese, "中文"), new(LiveSpeechLanguage.English, "英文"), new(LiveSpeechLanguage.Unrestricted, "不限语言")];
    public IReadOnlyList<SettingChoice<ReasoningService>> ReasoningServices { get; } = [new(ReasoningService.SharedOpenAI, "OpenAI · 共享密钥"), new(ReasoningService.SeparateOpenAI, "OpenAI · 独立推理密钥"), new(ReasoningService.DeepSeek, "DeepSeek"), new(ReasoningService.Qwen, "通义千问 Qwen"), new(ReasoningService.Glm, "智谱 GLM"), new(ReasoningService.Kimi, "月之暗面 Kimi"), new(ReasoningService.Compatible, "OpenAI 兼容接口")];
    public IReadOnlyList<SettingChoice<KnowledgeMode>> KnowledgeModes { get; } = [new(KnowledgeMode.General, "通用"), new(KnowledgeMode.Hybrid, "混合"), new(KnowledgeMode.KnowledgeBaseOnly, "仅知识库")];
    public IReadOnlyList<SettingChoice<EmbeddingService>> EmbeddingServices { get; } = [new(EmbeddingService.OpenAI, "OpenAI"), new(EmbeddingService.Local, "本地 BGE-M3")];
    public IReadOnlyList<SettingChoice<AppBackground>> Backgrounds { get; } = [new(AppBackground.Glass, "半透明毛玻璃"), new(AppBackground.Frosted, "微透磨砂"), new(AppBackground.White, "纯白底色")];
    private static string ThinkingLabel(AnalysisThinking value) => value switch
    {
        AnalysisThinking.ModelDefault => "模型默认", AnalysisThinking.Disabled => "关闭思考", AnalysisThinking.Enabled => "开启思考",
        AnalysisThinking.Low => "低", AnalysisThinking.Medium => "中", AnalysisThinking.High => "高", AnalysisThinking.Xhigh => "更高", AnalysisThinking.Max => "最高", _ => value.ToString()
    };
}
