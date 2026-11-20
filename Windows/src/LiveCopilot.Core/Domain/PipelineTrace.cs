namespace LiveCopilot.Core;

public sealed record PipelineTrace
{
    public Guid Id { get; init; }
    public double Origin { get; init; }
    private Dictionary<PipelineStage, double> times = [];
    public IReadOnlyDictionary<PipelineStage, double> Times => new System.Collections.ObjectModel.ReadOnlyDictionary<PipelineStage, double>(times);
    public static double Uptime => (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    public PipelineTrace(Guid? id = null, double? origin = null) { Id = id ?? Guid.NewGuid(); Origin = origin ?? Uptime; }
    private PipelineTrace(PipelineTrace original) { Id = original.Id; Origin = original.Origin; times = new(original.times); }
    public void Mark(PipelineStage stage, double? at = null) => times[stage] = at ?? Uptime;
    public int? Milliseconds(PipelineStage stage) => times.TryGetValue(stage, out var at) ? (int)((at - Origin) * 1000) : null;
    public string LogLine(PipelineStage stage) => $"pipeline trace={CoreJson.Id(Id)} stage={stage.RawValue()} elapsed_ms={Milliseconds(stage) ?? -1} uptime_ms={(long)(times.GetValueOrDefault(stage, Origin) * 1000)}";
    public bool Equals(PipelineTrace? other) => other is not null && Id == other.Id && Origin == other.Origin && times.Count == other.times.Count && times.All(p => other.times.TryGetValue(p.Key, out var value) && value == p.Value);
    public override int GetHashCode() { var hash = new HashCode(); hash.Add(Id); hash.Add(Origin); foreach (var pair in times.OrderBy(p => p.Key)) hash.Add(pair); return hash.ToHashCode(); }
}
