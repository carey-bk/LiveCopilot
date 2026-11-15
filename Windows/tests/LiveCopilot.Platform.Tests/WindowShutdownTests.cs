using System.IO;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Lifecycle;

namespace LiveCopilot.Platform.Tests;

public sealed class WindowShutdownTests
{
    [Fact]
    public async Task SynchronousStopNeverClosesInsideTheOriginalClosingStack()
    {
        var dispatcher = new Queue<Action>();
        var inClosing = true;
        var stops = 0;
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => { stops++; return Task.CompletedTask; }], dispatcher.Enqueue,
            () => { Assert.False(inClosing); closes++; });

        await shutdown.RequestCloseAsync();
        Assert.True(shutdown.IsRequested);
        Assert.False(shutdown.IsClosing);
        Assert.Equal(1, stops);
        Assert.Equal(0, closes);
        inClosing = false;
        Assert.Single(dispatcher)();
        Assert.True(shutdown.IsClosing);
        Assert.Equal(1, closes);
    }

    [Fact]
    public async Task RepeatedRequestsStopAndQueueOnlyOnce()
    {
        var dispatcher = new Queue<Action>();
        var stops = 0;
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => { stops++; return Task.CompletedTask; }], dispatcher.Enqueue, () => closes++);
        var first = shutdown.RequestCloseAsync();
        for (var i = 0; i < 10; i++) Assert.Same(first, shutdown.RequestCloseAsync());
        await first;
        Assert.Equal(1, stops);
        Assert.Single(dispatcher)();
        await shutdown.RequestCloseAsync();
        Assert.Equal(1, closes);
        Assert.Single(dispatcher);
    }

    [Fact]
    public async Task AnotherRequestWhileStoppingWaitsForTheSameCleanup()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = new Queue<Action>();
        var stops = 0;
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => { stops++; return release.Task; }], dispatcher.Enqueue, () => closes++);

        var first = shutdown.RequestCloseAsync();
        var second = shutdown.RequestCloseAsync();
        Assert.Same(first, second);
        Assert.False(first.IsCompleted);
        Assert.False(shutdown.IsClosing);
        Assert.Empty(dispatcher);
        release.SetResult();
        await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, stops);
        Assert.Equal(0, closes);
        Assert.Single(dispatcher)();
        Assert.Equal(1, closes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StopFailureStillCleansUpOtherResourcesAndCloses(bool asynchronous)
    {
        var failure = new IOException("stop failed");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = new Queue<Action>();
        var order = new List<string>();
        var shutdown = new WindowShutdownCoordinator([
            () => { order.Add("stop"); if (asynchronous) return release.Task; throw failure; },
            () => { order.Add("dispose"); return Task.CompletedTask; }
        ], dispatcher.Enqueue, () => order.Add("close"));

        var pending = shutdown.RequestCloseAsync();
        if (asynchronous) release.SetException(failure);
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Same(failure, Assert.Single(shutdown.Errors));
        Assert.Equal(["stop", "dispose"], order);
        Assert.Single(dispatcher)();
        Assert.Equal(["stop", "dispose", "close"], order);
    }

    [Fact]
    public async Task CancelledStopStillCloses()
    {
        var dispatcher = new Queue<Action>();
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => Task.FromCanceled(new CancellationToken(true))], dispatcher.Enqueue, () => closes++);
        await shutdown.RequestCloseAsync();
        Assert.IsAssignableFrom<OperationCanceledException>(Assert.Single(shutdown.Errors));
        Assert.Single(dispatcher)();
        Assert.Equal(1, closes);
    }

    [Fact]
    public async Task EveryCleanupStepRunsInOrderDespiteMultipleFailures()
    {
        var dispatcher = new Queue<Action>();
        var calls = new List<int>();
        var shutdown = new WindowShutdownCoordinator(Enumerable.Range(0, 5).Select<int, Func<Task>>(i => () =>
        {
            calls.Add(i);
            if (i % 2 == 0) throw new IOException($"failure {i}");
            return Task.CompletedTask;
        }), dispatcher.Enqueue, () => calls.Add(5));

        await shutdown.RequestCloseAsync();
        Assert.Equal(Enumerable.Range(0, 5), calls);
        Assert.Equal(3, shutdown.Errors.Count);
        Assert.Single(dispatcher)();
        Assert.Equal(Enumerable.Range(0, 6), calls);
    }

    [Fact]
    public async Task SharedResourcesAreNotDisposedUntilChildCleanupFinishes()
    {
        var childStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var childDispatcher = new Queue<Action>();
        var parentDispatcher = new Queue<Action>();
        var sharedDisposed = false;
        var child = new WindowShutdownCoordinator([() => childStopped.Task], childDispatcher.Enqueue, () => { });
        var parent = new WindowShutdownCoordinator([
            child.RequestCloseAsync,
            () => { sharedDisposed = true; return Task.CompletedTask; }
        ], parentDispatcher.Enqueue, () => { });

        var pending = parent.RequestCloseAsync();
        Assert.False(sharedDisposed);
        Assert.Empty(parentDispatcher);
        childStopped.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(sharedDisposed);
        Assert.Single(childDispatcher);
        Assert.Single(parentDispatcher);
    }

    [Fact]
    public async Task AlreadyClosedWindowDoesNotStopOrQueueOrCloseAgain()
    {
        var shutdown = new WindowShutdownCoordinator(
            [() => throw new InvalidOperationException("must not stop")], _ => Assert.Fail("must not post"),
            () => Assert.Fail("must not close"));
        shutdown.NotifyClosed();
        await shutdown.RequestCloseAsync();
        shutdown.NotifyClosed();
        await shutdown.RequestCloseAsync();
        Assert.True(shutdown.IsClosed);
        Assert.True(shutdown.IsRequested);
        Assert.Empty(shutdown.Errors);
    }

    [Fact]
    public async Task ClosedDuringStopStillFinishesCleanupButNeverQueuesClose()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var disposed = false;
        var shutdown = new WindowShutdownCoordinator([
            () => release.Task,
            () => { disposed = true; return Task.CompletedTask; }
        ], _ => Assert.Fail("closed while stopping"), () => Assert.Fail("already closed"));
        var pending = shutdown.RequestCloseAsync();
        shutdown.NotifyClosed();
        Assert.Same(pending, shutdown.RequestCloseAsync());
        Assert.False(pending.IsCompleted);
        release.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(disposed);
        Assert.True(shutdown.IsClosed);
    }

    [Fact]
    public async Task ClosedInvalidatesAnAlreadyQueuedClose()
    {
        var dispatcher = new Queue<Action>();
        var shutdown = new WindowShutdownCoordinator([], dispatcher.Enqueue, () => Assert.Fail("already closed"));
        await shutdown.RequestCloseAsync();
        shutdown.NotifyClosed();
        Assert.Single(dispatcher)();
        await shutdown.RequestCloseAsync();
        Assert.True(shutdown.IsClosed);
    }

    [Fact]
    public async Task ClosingReentryAndDuplicateDeliveryCannotCallCloseAgain()
    {
        var dispatcher = new Queue<Action>();
        var closes = 0;
        WindowShutdownCoordinator? shutdown = null;
        shutdown = new([], dispatcher.Enqueue, () =>
        {
            Assert.True(shutdown!.IsClosing);
            closes++;
            _ = shutdown.RequestCloseAsync(); // Close synchronously raises Closing again.
            shutdown.NotifyClosed();
        });
        await shutdown.RequestCloseAsync();
        var close = Assert.Single(dispatcher);
        close();
        close();
        await shutdown.RequestCloseAsync();
        Assert.Equal(1, closes);
        Assert.True(shutdown.IsClosed);
    }

    [Fact]
    public async Task CleanupReentrySeesTheOriginalRequestTask()
    {
        Task? reentered = null;
        var dispatcher = new Queue<Action>();
        WindowShutdownCoordinator? shutdown = null;
        shutdown = new([() => { reentered = shutdown!.RequestCloseAsync(); return Task.CompletedTask; }],
            dispatcher.Enqueue, () => { });
        var pending = shutdown.RequestCloseAsync();
        Assert.Same(pending, reentered);
        await pending;
        Assert.Single(dispatcher);
    }

    [Fact]
    public async Task RejectedDispatcherPostNeverFallsBackToInlineClose()
    {
        var rejected = new InvalidOperationException("dispatcher is shutting down");
        var shutdown = new WindowShutdownCoordinator([], _ => throw rejected, () => Assert.Fail("inline close"));
        await shutdown.RequestCloseAsync();
        Assert.Same(rejected, Assert.Single(shutdown.Errors));
        shutdown.NotifyClosed();
        await shutdown.RequestCloseAsync();
    }

    [Fact]
    public async Task ShutdownUnregistersHotkeysBeforeWaitingForSessionStop()
    {
        var registrar = new FakeRegistrar();
        var store = new HotkeyStore(new MemoryPreferenceStore());
        using var hotkeys = new HotkeyManager(store, registrar,
            _ => Assert.Fail("late shortcut"), () => Assert.Fail("late overlay toggle"), Assert.Fail);
        var ids = registrar.Active.Keys.ToArray();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = new Queue<Action>();
        var shutdown = new WindowShutdownCoordinator([
            () => { hotkeys.Dispose(); return Task.CompletedTask; },
            () => release.Task
        ], dispatcher.Enqueue, () => { });
        var pending = shutdown.RequestCloseAsync();
        _ = shutdown.RequestCloseAsync();
        Assert.Empty(registrar.Active);
        Assert.Equal(1, registrar.Disposals);
        foreach (var id in ids) registrar.Press(id);
        release.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Single(dispatcher)();
    }

    [Fact]
    public async Task RepeatedWindowShutdownDrainsRealSessionCapturesAndProvidersOnce()
    {
        var system = new FakeAudioSource();
        var microphone = new FakeAudioSource();
        await using var fixture = new SessionFixture(null, system, microphone);
        await fixture.Session.StartAsync();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var provider in fixture.Providers) provider.OnDisconnect = () => release.Task;
        var dispatcher = new Queue<Action>();
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => fixture.Session.DisposeAsync().AsTask()], dispatcher.Enqueue, () => closes++);
        var pending = shutdown.RequestCloseAsync();
        Assert.Same(pending, shutdown.RequestCloseAsync());
        Assert.Empty(dispatcher);
        release.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, system.Stops);
        Assert.Equal(1, microphone.Stops);
        Assert.Equal(1, system.Disposals);
        Assert.Equal(1, microphone.Disposals);
        Assert.All(fixture.Providers, provider => Assert.Equal(1, provider.Disconnects));
        Assert.Single(dispatcher)();
        Assert.Equal(1, closes);
        Assert.Empty(shutdown.Errors);
    }

    [Fact]
    public async Task WindowShutdownWaitsForAnAlreadyRunningSessionStop()
    {
        var system = new FakeAudioSource();
        var microphone = new FakeAudioSource();
        await using var fixture = new SessionFixture(null, system, microphone);
        await fixture.Session.StartAsync();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var provider in fixture.Providers) provider.OnDisconnect = () => release.Task;
        var stop = fixture.Session.StopAsync(); // The user clicked Stop before closing the window.
        var dispatcher = new Queue<Action>();
        var closes = 0;
        var shutdown = new WindowShutdownCoordinator(
            [() => fixture.Session.DisposeAsync().AsTask()], dispatcher.Enqueue, () => closes++);

        var pending = shutdown.RequestCloseAsync();
        Assert.Same(pending, shutdown.RequestCloseAsync());
        Assert.False(pending.IsCompleted);
        Assert.False(stop.IsCompleted);
        Assert.Empty(dispatcher);
        release.SetResult();
        await Task.WhenAll(stop, pending).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, system.Stops);
        Assert.Equal(1, microphone.Stops);
        Assert.Equal(1, system.Disposals);
        Assert.Equal(1, microphone.Disposals);
        Assert.All(fixture.Providers, provider => Assert.Equal(1, provider.Disconnects));
        Assert.Single(dispatcher)();
        Assert.Equal(1, closes);
        Assert.Empty(shutdown.Errors);
    }
}
