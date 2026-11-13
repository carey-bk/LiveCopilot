namespace LiveCopilot.Core;


public static class AppPaths
{
    public static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LiveCopilot");
    public const string LocalEmbeddingIdentity = "local:bge-m3:q8_0:950f4a8e5e19:cls:l2:v1";
    public const int TranscriptLineLimit = 400;
    public const int SuggestionContextWindowSeconds = 90;
}
