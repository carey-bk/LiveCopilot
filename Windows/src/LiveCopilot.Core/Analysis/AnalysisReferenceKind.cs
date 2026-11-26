namespace LiveCopilot.Core;

public enum AnalysisReferenceKind
{
    [EnumMember(Value = "publicSnapshot")] PublicSnapshot,
    [EnumMember(Value = "community")] Community,
    [EnumMember(Value = "estimate")] Estimate,
}
