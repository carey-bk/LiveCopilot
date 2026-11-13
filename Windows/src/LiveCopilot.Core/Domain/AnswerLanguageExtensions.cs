namespace LiveCopilot.Core;


public static class AnswerLanguageExtensions
{
    public static string Label(this AnswerLanguage value) => value switch { AnswerLanguage.Chinese => "中文", AnswerLanguage.English => "English", _ => "Auto" };
    public static string Instructions(this AnswerLanguage value) => PromptText.Get("answerLanguage." + value.RawValue());
    public static bool LocalFallbackIsChinese(this AnswerLanguage value, string question, ITextLanguageDetector? detector = null)
    {
        if (value != AnswerLanguage.Auto) return value == AnswerLanguage.Chinese;
        var lower = question.ToLowerInvariant();
        if (Regex.IsMatch(lower, @"(?:answer|respond|reply|explain)\s+(?:only\s+)?in\s+english|(?:用|以)英语(?:回答|解释)|(?:用|以)英文(?:回答|解释)")) return false;
        if (Regex.IsMatch(lower, @"(?:answer|respond|reply|explain)\s+(?:only\s+)?in\s+(?:chinese|mandarin)|(?:用|以)中文(?:回答|解释)")) return true;
        return (detector ?? new TextLanguageDetector()).IsChinese(question);
    }
    public static string MissingEvidence(this AnswerLanguage value, string question, ITextLanguageDetector? detector = null) => value.LocalFallbackIsChinese(question, detector)
        ? "## 回答建议\n当前为仅知识库模式，未找到足以回答这个问题的相关资料。请补充资料，或切换到混合知识模式。"
        : "## Suggested answer\nKnowledge Base Only is enabled. No relevant document evidence was found for this question. Add supporting material or switch to Hybrid Knowledge.";
}
