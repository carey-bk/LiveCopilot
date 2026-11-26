namespace LiveCopilot.Platform.Updates;

public enum UpdateCheckStatus { Disabled, SourceNotConfigured }

public interface IUpdateChecker
{
    Task<UpdateCheckStatus> CheckAsync(bool enabled, CancellationToken cancellationToken = default);
}

/// No source, client, timer or downloader. Enabling the preference cannot cause traffic.
public sealed class UnconfiguredUpdateChecker : IUpdateChecker
{
    public Task<UpdateCheckStatus> CheckAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(enabled ? UpdateCheckStatus.SourceNotConfigured : UpdateCheckStatus.Disabled);
    }
}
