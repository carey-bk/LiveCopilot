namespace LiveCopilot.Core;

public enum ListeningService
{
    [EnumMember(Value = "zipformer")] Zipformer,
    [EnumMember(Value = "paraformer")] Paraformer,
    [EnumMember(Value = "apple")] Apple,
    [EnumMember(Value = "openAI")] OpenAI,
}

public static class ListeningServiceExtensions
{
    public static int SampleRate(this ListeningService service) =>
        service is ListeningService.Zipformer or ListeningService.Paraformer ? 16000 : 24000;
}
