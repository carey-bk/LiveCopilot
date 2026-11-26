namespace LiveCopilot.Platform.Lifecycle;

/// <summary>
/// Coordinates a window's asynchronous teardown on its UI thread. The caller must
/// cancel Closing until IsClosing is true and forward Closed to NotifyClosed.
/// post must enqueue (never invoke inline) on the same UI dispatcher. Awaited steps
/// retain that context; this class has no dependency on a particular window toolkit.
/// </summary>
public sealed class WindowShutdownCoordinator(
    IEnumerable<Func<Task>> cleanupSteps, Action<Action> post, Action close)
{
    private enum Phase { Open, Stopping, Queued, Closing, Closed }
    private readonly Func<Task>[] steps = cleanupSteps.ToArray();
    private readonly List<Exception> errors = [];
    private readonly TaskCompletionSource cleanup = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Phase phase;

    public bool IsRequested => phase != Phase.Open;
    public bool IsClosing => phase == Phase.Closing;
    public bool IsClosed => phase == Phase.Closed;
    public IReadOnlyList<Exception> Errors => errors.AsReadOnly();

    /// <summary>Completes after cleanup and queuing the final close, not after Closed.</summary>
    public Task RequestCloseAsync()
    {
        if (phase == Phase.Open)
        {
            phase = Phase.Stopping; // Before invoking any user code, including synchronous steps.
            _ = StopAndQueueCloseAsync();
        }
        return cleanup.Task;
    }

    public void NotifyClosed()
    {
        if (phase == Phase.Open) cleanup.TrySetResult();
        phase = Phase.Closed; // Invalidates both an in-flight stop and an already queued close.
    }

    private async Task StopAndQueueCloseAsync()
    {
        foreach (var step in steps)
        {
            try { await step(); }
            catch (Exception error) { errors.Add(error); }
        }
        if (phase == Phase.Stopping)
        {
            phase = Phase.Queued;
            // Even fully synchronous cleanup must leave the original Closing stack.
            // A dispatcher shutting down may reject the post; never close inline then.
            try { post(CloseOnce); }
            catch (Exception error) { errors.Add(error); }
        }
        cleanup.TrySetResult();
    }

    private void CloseOnce()
    {
        if (phase != Phase.Queued) return;
        phase = Phase.Closing; // Close raises Closing synchronously; allow that one pass.
        close();
    }
}
