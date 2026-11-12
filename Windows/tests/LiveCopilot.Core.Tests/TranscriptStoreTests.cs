namespace LiveCopilot.Core.Tests;

public sealed class TranscriptStoreTests
{
    [Fact]
    public void PartialsAreSpeakerScopedAndOnlyNonblankCommitsEnterHistory()
    {
        var store = new TranscriptStore();
        Assert.False(store.HasContent);
        store.SetPartial("remote", Speaker.Them);
        store.AppendDelta(" speech", Speaker.Room);
        store.SetPartial(" own speech ", Speaker.You);
        Assert.True(store.HasContent);
        Assert.Empty(store.ArchivedLines);
        store.CommitPartial(Speaker.Room, Fixtures.At);
        store.CommitPartial(Speaker.You, Fixtures.At.AddSeconds(1));
        store.Commit(" \n ", Speaker.Room);
        Assert.Equal(["remote speech", "own speech"], store.Lines.Select(l => l.Content));
        Assert.Equal([Speaker.Room, Speaker.You], store.Lines.Select(l => l.Speaker));
        Assert.Empty(store.PartialThem);
        Assert.Empty(store.PartialYou);
    }

    [Fact]
    public void RevisionsReplaceTheirOwnFragmentWithoutDuplicatingOrChangingLineIdentity()
    {
        var store = new TranscriptStore();
        var first = Fixtures.Fragment("Original", "f1");
        var next = Fixtures.Fragment(" continuation", "f2", start: 500);
        store.Ingest(first);
        var id = Assert.Single(store.Lines).Id;
        store.Ingest(next);
        store.Ingest(first with { Text = "Corrected" });
        store.Ingest(first with { Text = "Corrected" });
        var line = Assert.Single(store.Lines);
        Assert.Equal(id, line.Id);
        Assert.Equal(Fixtures.At, line.At);
        Assert.Equal("Corrected continuation", line.Content);
        Assert.Equal(3, store.FragmentRevisions.Count);
        Assert.Equal(["f1", "f2"], Assert.Single(store.ArchiveSnapshot(Fixtures.At)).FragmentIds);
    }

    [Theory]
    [InlineData(499, Speaker.Them, 2)]
    [InlineData(500, Speaker.Them, 1)]
    [InlineData(2099, Speaker.Them, 1)]
    [InlineData(2100, Speaker.Them, 2)]
    [InlineData(500, Speaker.You, 2)]
    public void MergeRespectsAudioGapAndSpeaker(int start, Speaker speaker, int lineCount)
    {
        var store = new TranscriptStore();
        store.Ingest(Fixtures.Fragment("first", "f1"));
        store.Ingest(Fixtures.Fragment("second", "f2", speaker, start));
        Assert.Equal(lineCount, store.Lines.Count);
    }

    [Fact]
    public void MergeLimitCountsGraphemesInsteadOfUtf16CodeUnits()
    {
        var store = new TranscriptStore();
        store.Ingest(Fixtures.Fragment(string.Concat(Enumerable.Repeat("🧑‍💻", 1799)), "f1"));
        store.Ingest(Fixtures.Fragment("中", "f2", start: 500));
        Assert.Single(store.Lines);
        store.Ingest(Fixtures.Fragment("new line", "f3", start: 1000));
        Assert.Equal(2, store.Lines.Count);
    }

    [Fact]
    public void LongArchiveRetainsOffscreenRevisionsAndSnapshotFiltersSessionStart()
    {
        var store = new TranscriptStore();
        for (var index = 0; index < 1200; index++)
            store.Ingest(Fixtures.Fragment("Original " + index, "f" + index, index % 2 == 0 ? Speaker.Room : Speaker.Them, index * 2000, Fixtures.At.AddSeconds(index)));
        var originalId = store.ArchivedLines[0].Id;
        store.Ingest(Fixtures.Fragment("Corrected first line", "f0", Speaker.Room));
        var saved = store.ArchiveSnapshot(Fixtures.At);
        Assert.Equal(AppPaths.TranscriptLineLimit, store.Lines.Count);
        Assert.Equal(1200, saved.Count);
        Assert.Equal(originalId, saved[0].Id);
        Assert.Equal("Corrected first line", saved[0].Content);
        Assert.Equal(["f0"], saved[0].FragmentIds);
        Assert.Equal(2, store.FragmentRevisions.Count(f => f.Id == "f0"));
        Assert.Equal(200, store.ArchiveSnapshot(Fixtures.At.AddSeconds(1000)).Count);
    }

    [Fact]
    public void PreservedOwnPreviewIsExtendedAndReconciledWithFinalAsr()
    {
        var store = new TranscriptStore();
        store.SetPartial("I think", Speaker.You);
        store.PreserveOwnPreview("I think", Fixtures.At);
        var id = Assert.Single(store.Lines).Id;
        store.PreserveOwnPreview("I think caching", Fixtures.At.AddSeconds(1));
        Assert.Empty(store.PartialYou);
        store.Ingest(Fixtures.Fragment("I think caching helps.", "own", Speaker.You, at: Fixtures.At.AddSeconds(2)));
        var line = Assert.Single(store.Lines);
        Assert.Equal(id, line.Id);
        Assert.Equal(Fixtures.At.AddSeconds(1), line.At); // Swift uses the last protected-preview timestamp.
        Assert.Equal("I think caching helps.", line.Content);
        Assert.Equal(["own"], Assert.Single(store.ArchiveSnapshot(Fixtures.At)).FragmentIds);
    }

    [Theory]
    [InlineData("different words", 1)]
    [InlineData("I think caching helps", 12)]
    public void UnrelatedOrExpiredFinalDoesNotOverwriteProtectedPreview(string final, int seconds)
    {
        var store = new TranscriptStore();
        store.PreserveOwnPreview("I think", Fixtures.At);
        store.Ingest(Fixtures.Fragment(final, speaker: Speaker.You, at: Fixtures.At.AddSeconds(seconds)));
        Assert.Equal(2, store.Lines.Count);
        Assert.Equal("I think", store.Lines[0].Content);
    }

    [Fact]
    public void RecentContextUsesWindowThenFallsBackToFourVisibleLines()
    {
        var store = new TranscriptStore();
        for (var i = 0; i < 6; i++) store.Commit("line " + i, Speaker.Them, Fixtures.At.AddSeconds(i * 30));
        Assert.Equal("Them: line 4\nThem: line 5", store.RecentContext(Fixtures.At.AddSeconds(210)));
        Assert.Equal("Them: line 2\nThem: line 3\nThem: line 4\nThem: line 5", store.RecentContext(Fixtures.At.AddHours(1)));
    }

    [Fact]
    public void ClearRemovesArchivePartialsAndFragmentMappings()
    {
        var store = new TranscriptStore();
        var fragment = Fixtures.Fragment("first");
        store.Ingest(fragment);
        var oldId = Assert.Single(store.Lines).Id;
        store.SetPartial("partial", Speaker.You);
        store.Clear();
        Assert.False(store.HasContent);
        Assert.Empty(store.Lines);
        Assert.Empty(store.ArchivedLines);
        Assert.Empty(store.FragmentRevisions);
        Assert.Empty(store.ArchiveSnapshot(Fixtures.At));
        store.Ingest(fragment);
        Assert.NotEqual(oldId, Assert.Single(store.Lines).Id);
        Assert.Single(store.FragmentRevisions);
    }
}
