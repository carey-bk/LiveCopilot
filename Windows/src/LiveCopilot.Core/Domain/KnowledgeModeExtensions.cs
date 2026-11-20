namespace LiveCopilot.Core;


public static class KnowledgeModeExtensions
{
    public static bool UsesKnowledgeBase(this KnowledgeMode value) => value != KnowledgeMode.General;
    public static string Label(this KnowledgeMode value) => value switch { KnowledgeMode.General => "General Knowledge", KnowledgeMode.Hybrid => "Hybrid Knowledge", _ => "Knowledge Base Only" };
    public static string CompactLabel(this KnowledgeMode value) => value switch { KnowledgeMode.General => "General Knowledge", KnowledgeMode.Hybrid => "Hybrid", _ => "KB Only" };
    public static string Instructions(this KnowledgeMode value) => PromptText.Get("knowledge." + value.RawValue());
}
