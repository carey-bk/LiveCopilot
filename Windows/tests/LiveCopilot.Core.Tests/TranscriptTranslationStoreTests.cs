namespace LiveCopilot.Core.Tests;

public sealed class TranscriptTranslationStoreTests
{
    private static TranscriptTranslationStore Store(TimeSpan? timeout = null) =>
        new(previewDelay: TimeSpan.Zero, confirmedDelay: TimeSpan.Zero, timeout: timeout ?? TimeSpan.FromSeconds(10));
    private static Task Idle(TranscriptTranslationStore store) => store.WhenIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));

    [Fact]
    public async Task EnablingTranslatesOnlyLatestUtteranceAndReusesCacheForNewIdentity()
    {
        using var store = Store();
        var old = new TranscriptLine(Speaker.Room, Fixtures.At, "old private meeting");
        var latest = new TranscriptLine(Speaker.Them, Fixtures.At.AddSeconds(1), "latest words");
        var provider = new TextProvider("  最新发言  ");
        store.Start(TranslationLanguage.Simplified, provider, [old, latest]);
        await Idle(store);
        var request = Assert.Single(provider.Requests);
        Assert.Equal(latest.Content, request.TranslationText);
        Assert.Equal("Simplified Chinese", request.TranslationTarget);
        Assert.Empty(request.Conversation);
        Assert.Null(store.Text(old));
        Assert.Equal("最新发言", store.Text(latest));
        var repeated = latest with { Id = Guid.NewGuid() };
        store.Update([old, latest, repeated]);
        await Idle(store);
        Assert.Single(provider.Requests);
        Assert.Equal("最新发言", store.Text(repeated));
        Assert.False(store.Busy);
        Assert.False(store.Failed);
    }

    [Fact]
    public async Task RevisedLineDiscardsOldResultEvenAfterReplacementCompletes()
    {
        using var store = Store();
        var provider = new ControlledReasoningProvider();
        var line = new TranscriptLine(Speaker.Them, Fixtures.At, "old source");
        store.Start(TranslationLanguage.English, provider, [line]);
        var obsolete = await provider.NextAsync();
        var revised = line with { Content = "corrected source" };
        store.Update([revised]);
        var current = await provider.NextAsync();
        Assert.True(obsolete.CancellationToken.IsCancellationRequested);
        Assert.Equal(revised.Content, current.Request.Input);
        current.Complete("correct translation");
        await Idle(store);

        obsolete.Complete("obsolete translation");
        await obsolete.Finished.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal("correct translation", store.Text(revised));
        Assert.Null(store.Text(line));
        Assert.False(store.Failed);
        Assert.False(store.Busy);
        Assert.Single(store.Values);
    }

    [Fact]
    public async Task StopRejectsLateSuccessAndLateFailureWithoutPublishingState()
    {
        foreach (var fail in new[] { false, true })
        {
            using var store = Store();
            var provider = new ControlledReasoningProvider();
            store.Start(TranslationLanguage.English, provider, [new(Speaker.Room, Fixtures.At, "words")]);
            var obsolete = await provider.NextAsync();
            store.Stop();
            await Idle(store);
            if (fail) obsolete.Fail(new InvalidOperationException("late failure"));
            else obsolete.Complete("late success");
            await obsolete.Finished.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(store.Enabled);
            Assert.False(store.Busy);
            Assert.False(store.Failed);
            Assert.Empty(store.Values);
            Assert.True(obsolete.CancellationToken.IsCancellationRequested);
        }
    }

    [Fact]
    public async Task ChangingTargetClearsCacheAndRejectsPreviousLanguage()
    {
        using var store = Store();
        var provider = new ControlledReasoningProvider();
        var line = new TranscriptLine(Speaker.Room, Fixtures.At, "same source");
        store.Start(TranslationLanguage.English, provider, [line]);
        var obsolete = await provider.NextAsync();
        store.Start(TranslationLanguage.Japanese, provider, [line]);
        var current = await provider.NextAsync();
        Assert.Equal("Japanese", current.Request.TranslationTarget);
        current.Complete("日本語");
        await Idle(store);
        obsolete.Complete("English");
        await obsolete.Finished.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TranslationLanguage.Japanese, store.Target);
        Assert.Equal("日本語", store.Text(line));
        Assert.False(store.Failed);
    }

    [Fact]
    public async Task PreviewRevisionAndRemovalDoNotLeakObsoleteTranslation()
    {
        using var store = Store();
        var provider = new ControlledReasoningProvider();
        store.Start(TranslationLanguage.English, provider, []);
        store.UpdatePreview("unfinished", Speaker.You);
        var obsolete = await provider.NextAsync();
        store.UpdatePreview("finished sentence", Speaker.You);
        var current = await provider.NextAsync();
        current.Complete("current preview");
        await Idle(store);
        obsolete.Complete("obsolete preview");
        await obsolete.Finished.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Null(store.PreviewText("unfinished", Speaker.You));
        Assert.Equal("current preview", store.PreviewText("finished sentence", Speaker.You));
        store.UpdatePreview("", Speaker.You);
        await Idle(store);
        Assert.Empty(store.Values);
        Assert.Null(store.PreviewText("finished sentence", Speaker.You));
    }

    [Fact]
    public async Task ResetSessionKeepsEnabledTargetButClearsValuesAndCache()
    {
        using var store = Store();
        var provider = new TextProvider("translated");
        var line = new TranscriptLine(Speaker.You, Fixtures.At, "same words");
        store.Start(TranslationLanguage.French, provider, [line]);
        await Idle(store);
        store.ResetSession();
        Assert.True(store.Enabled);
        Assert.Equal(TranslationLanguage.French, store.Target);
        Assert.Empty(store.Values);
        store.Update([line]);
        await Idle(store);
        Assert.Equal(2, provider.Requests.Count);
        store.Stop();
        store.ResetSession();
        Assert.False(store.Enabled);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(16001)]
    public async Task EmptyOrOversizedOutputFailsOnceAndNextLineCanRecover(int length)
    {
        using var store = Store();
        var provider = new ControlledReasoningProvider();
        var line = new TranscriptLine(Speaker.Room, Fixtures.At, "first");
        store.Start(TranslationLanguage.English, provider, [line]);
        var first = await provider.NextAsync();
        first.Complete(length == 0 ? " \n " : new string('a', length));
        await Idle(store);
        Assert.True(store.Failed);
        Assert.Empty(store.Values);
        Assert.False(store.Busy);
        var next = new TranscriptLine(Speaker.Room, Fixtures.At.AddSeconds(1), "second");
        store.Update([line, next]);
        var second = await provider.NextAsync();
        Assert.Equal("second", second.Request.Input);
        second.Complete("recovered");
        await Idle(store);
        Assert.False(store.Failed);
        Assert.Equal("recovered", store.Text(next));
    }

    [Fact]
    public async Task TimeoutReleasesQueueAndLateOutputCannotOverwriteNextLine()
    {
        using var store = Store(TimeSpan.FromSeconds(1));
        var provider = new ControlledReasoningProvider();
        var line = new TranscriptLine(Speaker.Them, Fixtures.At, "stalled source");
        store.Start(TranslationLanguage.English, provider, [line]);
        var stalled = await provider.NextAsync();
        await Idle(store);
        Assert.True(store.Failed);
        Assert.False(store.Busy);
        Assert.Empty(store.Values);
        Assert.True(stalled.CancellationToken.IsCancellationRequested);
        var next = new TranscriptLine(Speaker.Them, Fixtures.At.AddSeconds(1), "next source");
        store.Update([line, next]);
        var current = await provider.NextAsync();
        current.Complete("next translation");
        await Idle(store);
        stalled.Complete("late translation");
        await stalled.Finished.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(store.Failed);
        Assert.Null(store.Text(line));
        Assert.Equal("next translation", store.Text(next));
    }
}
