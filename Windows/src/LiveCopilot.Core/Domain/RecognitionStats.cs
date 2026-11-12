namespace LiveCopilot.Core;

public sealed record RecognitionStats
{
    public const int MaximumBacklogMs = 12_000;
    public int? ReadyMs { get; set; }
    public int BacklogMaxMs { get; private set; }
    public int FinalLagCount { get; private set; }
    public long FinalLagSumMs { get; private set; }
    public int FinalLagMaxMs { get; private set; }
    public RecognitionFailure? Failure { get; set; }
    public long? FinalLagMeanMs => FinalLagCount == 0 ? null : FinalLagSumMs / FinalLagCount;
    public void NoteBacklog(int ms) => BacklogMaxMs = Math.Max(BacklogMaxMs, ms);
    public void NoteFinal(int capturedMs, int endMs)
    { var lag = Math.Max(0, capturedMs - endMs); FinalLagCount++; FinalLagSumMs += lag; FinalLagMaxMs = Math.Max(FinalLagMaxMs, lag); }
    public static RecognitionFailure OverflowFailure(bool ready) => ready ? RecognitionFailure.SpeechBehind : RecognitionFailure.SpeechLoadSlow;
}
public interface IRecognitionStatsReporting { RecognitionStats RecognitionStats { get; } }
public sealed class AudioBacklog
{
    private readonly object gate = new();
    private readonly Queue<double> items = [];
    private double outstandingMs;
    public double Add(double ms) { lock (gate) { items.Enqueue(ms); return outstandingMs += ms; } }
    public void RemoveOldest() { lock (gate) { if (items.TryDequeue(out var ms)) outstandingMs = Math.Max(0, outstandingMs - ms); } }
}
