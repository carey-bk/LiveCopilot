namespace LiveCopilot.Core.Tests;

public sealed class SessionStoreTests
{
    [Fact]
    public void ConstructionAndEmptySaveDoNotCreateStorage()
    {
        using var root = new TemporaryDirectory(false);
        var store = new SessionStore(root.Path);
        Assert.Empty(store.Sessions);
        Assert.Null(store.Save([], Fixtures.At));
        Assert.Null(store.SaveSnapshot([], Fixtures.At, []));
        Assert.False(Directory.Exists(root.Path));
    }

    [Fact]
    public void LegacyLoadDoesNotRewriteOrInventAnswers()
    {
        using var root = new TemporaryDirectory();
        var id = Guid.NewGuid();
        var json = $$"""
            {"id":"{{id}}","startedAt":"2026-10-16T10:00:00Z","endedAt":"2026-10-16T10:01:00Z","lines":[{"id":"{{Guid.NewGuid()}}","speaker":"Room","at":"2026-10-16T10:00:01Z","content":"旧版转写"}]}
            """;
        var path = Path.Combine(root.Path, CoreJson.Id(id) + ".json");
        File.WriteAllText(path, json);
        var before = File.ReadAllBytes(path);
        var modified = File.GetLastWriteTimeUtc(path);

        var record = Assert.Single(new SessionStore(root.Path).Sessions);

        Assert.True(record.IsLegacy);
        Assert.Null(record.Answers);
        Assert.Null(record.SchemaVersion);
        Assert.Equal(SessionEventKind.Room, Assert.Single(record.Timeline).Kind);
        Assert.DoesNotContain("AI 回答", record.Export(true));
        Assert.Equal(before, File.ReadAllBytes(path));
        Assert.Equal(modified, File.GetLastWriteTimeUtc(path));
        Assert.Single(Directory.GetFileSystemEntries(root.Path));
    }

    [Fact]
    public void PendingNamingIsRecoveredInMemoryAndRecordsAreSortedWithoutWrites()
    {
        using var root = new TemporaryDirectory();
        var old = new SessionRecord(Fixtures.At, Fixtures.At, []) { NamingState = "pending", Answers = [] };
        var recent = new SessionRecord(Fixtures.At.AddDays(1), Fixtures.At.AddDays(1), []);
        var path = Path.Combine(root.Path, CoreJson.Id(old.Id) + ".json");
        var json = CoreJson.Encode(old, session: true);
        File.WriteAllText(path, json);
        File.WriteAllText(Path.Combine(root.Path, CoreJson.Id(recent.Id) + ".json"), CoreJson.Encode(recent, session: true));
        File.WriteAllText(Path.Combine(root.Path, "broken.json"), "{");

        var store = new SessionStore(root.Path);

        Assert.Equal([recent.Id, old.Id], store.Sessions.Select(s => s.Id));
        Assert.Equal("failed", store.Sessions[1].NamingState);
        Assert.Equal(json, File.ReadAllText(path));
        Assert.Equal(3, Directory.GetFileSystemEntries(root.Path).Length);
    }

    [Theory]
    [InlineData("not a date")]
    [InlineData("2026-99-99T00:00:00Z")]
    public void MalformedSessionDatesAreSkippedAlongsideMissingRequiredFields(string date)
    {
        using var root = new TemporaryDirectory();
        File.WriteAllText(Path.Combine(root.Path, "date.json"), $$"""
            {"id":"{{Guid.NewGuid()}}","startedAt":"{{date}}","endedAt":"2026-10-16T10:01:00Z","lines":[]}
            """);
        File.WriteAllText(Path.Combine(root.Path, "missing.json"), "{}");
        Assert.Empty(new SessionStore(root.Path).Sessions);
        Assert.Equal(2, Directory.GetFiles(root.Path).Length);
    }

    [Fact]
    public void SnapshotRoundTripsTimelineFragmentsSearchAndBothExports()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var line = new SessionLine(Guid.NewGuid(), Speaker.Them, Fixtures.At, "缓存的讨论", ["f1"]);
        var record = Assert.IsType<SessionRecord>(store.SaveSnapshot([line], Fixtures.At,
            [Fixtures.Answer(Fixtures.At.AddSeconds(2)), Fixtures.Answer(Fixtures.At.AddSeconds(5), "Second independent answer")],
            Fixtures.At.AddSeconds(62), [Fixtures.Fragment(line.Content)]));

        Assert.Equal(record, Assert.Single(new SessionStore(root.Path).Sessions));
        Assert.Equal(2, record.SchemaVersion);
        Assert.False(record.IsLegacy);
        Assert.Equal("1 min", record.DurationLabel);
        Assert.Equal(5, record.MessageCount);
        Assert.Equal([SessionEventKind.Nearby, SessionEventKind.Question, SessionEventKind.Answer, SessionEventKind.Question, SessionEventKind.Answer], record.Timeline.Select(e => e.Kind));
        Assert.Equal(["f1"], record.Timeline[0].SourceIds);
        foreach (var search in new[] { "CACHING latency", "性能报告", "42 ms", "" }) Assert.True(record.Matches(search));
        Assert.False(record.Matches("absent term"));
        foreach (var extension in new[] { "md", "txt" })
        {
            var path = Path.Combine(root.Path, "export." + extension);
            store.Export(record, path);
            var text = File.ReadAllText(path);
            foreach (var value in new[] { "附近语音", "手动提问", "AI 回答", "[S1]", "性能报告", "42 ms", "Second independent answer", "2026-" })
                Assert.Contains(value, text);
            Assert.Equal(extension == "md", text.StartsWith("# ", StringComparison.Ordinal));
        }
        Assert.True(File.Exists(Path.Combine(root.Path, CoreJson.Id(record.Id) + ".txt")));
        Assert.Null(store.LastError);
    }

    [Fact]
    public void TiedTimelineEventsRemainStableAndAnswerWithoutTokensUsesQuestionTime()
    {
        var answer = Fixtures.Answer() with { AnsweredAt = null, CompletedAt = null, State = "interrupted", Warning = "Stopped", Automatic = true };
        var record = new SessionRecord(Fixtures.At, Fixtures.At.AddSeconds(-1), [new(new TranscriptLine(Speaker.You, Fixtures.At, "own speech"))]) { Answers = [answer] };
        Assert.Equal([SessionEventKind.Own, SessionEventKind.Question, SessionEventKind.Answer], record.Timeline.Select(e => e.Kind));
        Assert.Equal(0, record.Duration);
        Assert.Contains("识别的问题", record.Export(false));
        Assert.Contains("Stopped", record.Export(false));
    }

    [Fact]
    public async Task DeletedSessionCannotBeResurrectedByLateNamingOrAnswer()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var record = Assert.IsType<SessionRecord>(store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()], Fixtures.At));
        var provider = new ControlledReasoningProvider();
        var naming = SessionNaming.GenerateAsync(record, provider);
        var call = await provider.NextAsync();
        store.Delete(record);
        call.Complete("late title");
        var title = await naming.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.False(store.Update(record.Id, s => s with { GeneratedTitle = title, Answers = [Fixtures.Answer(text: "late answer")] }));
        Assert.Empty(store.Sessions);
        Assert.Empty(new SessionStore(root.Path).Sessions);
        Assert.Empty(Directory.GetFileSystemEntries(root.Path));
    }

    [Fact]
    public void ManualRenamePersistsAndRejectsInvalidTitlesAndIdentityChanges()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var record = Assert.IsType<SessionRecord>(store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()], Fixtures.At));
        Assert.True(store.Rename(record.Id, "  手动修正标题  "));
        foreach (var invalid in new[] { " ", new string('字', 81), "line one\nline two" }) Assert.False(store.Rename(record.Id, invalid));
        Assert.Throws<ArgumentException>(() => store.Update(record.Id, s => s with { Id = Guid.NewGuid() }));
        var restored = Assert.Single(new SessionStore(root.Path).Sessions);
        Assert.Equal("手动修正标题", restored.Title);
        Assert.Equal("manual", restored.NamingState);
        Assert.Equal(record.Answers, restored.Answers);
        store.Delete(restored);
        Assert.False(store.Rename(record.Id, "不能恢复删除记录"));
    }

    [Fact]
    public void FailedSaveDoesNotPublishRecordAndFailedUpdateKeepsMemorySnapshot()
    {
        using var root = new TemporaryDirectory();
        var blocked = Path.Combine(root.Path, "file-not-directory");
        File.WriteAllText(blocked, "fixture");
        var failedStore = new SessionStore(blocked);
        Assert.Null(failedStore.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()]));
        Assert.Empty(failedStore.Sessions);
        Assert.NotNull(failedStore.LastError);

        var store = new SessionStore(root.Path);
        var record = Assert.IsType<SessionRecord>(store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()], Fixtures.At));
        var path = Path.Combine(root.Path, CoreJson.Id(record.Id) + ".json");
        File.Delete(path);
        Directory.CreateDirectory(path); // A deterministic write failure, including privileged Linux runners.
        Assert.False(store.Rename(record.Id, "cannot persist"));
        Assert.Equal(record, Assert.Single(store.Sessions));
        Assert.NotNull(store.LastError);
        Assert.Empty(Directory.GetFiles(root.Path, ".*.tmp"));
    }

    [Fact]
    public void DraftFailureDoesNotDiscardSuccessfullySavedJson()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var record = Assert.IsType<SessionRecord>(store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()], Fixtures.At));
        var draft = Path.Combine(root.Path, CoreJson.Id(record.Id) + ".txt");
        File.Delete(draft);
        Directory.CreateDirectory(draft);
        Assert.True(store.Rename(record.Id, "saved title"));
        Assert.Contains("Session saved", store.LastError);
        Assert.Equal("saved title", Assert.Single(new SessionStore(root.Path).Sessions).Title);
    }

    [Fact]
    public async Task NamingBoundsInputPreservesPairsAndValidatesOutput()
    {
        var paired = Fixtures.Answer() with { SourceFragmentId = "paired" };
        var lines = Enumerable.Range(0, 100).Select(i => new SessionLine(Guid.NewGuid(), Speaker.Room, Fixtures.At.AddSeconds(i), new string('字', 2000), ["f" + i])).ToList();
        lines.Add(new(Guid.NewGuid(), Speaker.Room, Fixtures.At, "already paired question", ["paired"]));
        var record = new SessionRecord(Fixtures.At, Fixtures.At, lines.ToValueList()) { Answers = [paired] };
        var request = SessionNaming.Request(record);
        using var payload = JsonDocument.Parse(record.NamingInput);
        Assert.Equal(8, payload.RootElement.GetProperty("otherSpeech").GetArrayLength());
        Assert.Equal(paired.Text, payload.RootElement.GetProperty("turns")[0].GetProperty("answer").GetString());
        Assert.InRange(record.NamingInput.Length, 1, 45000);
        Assert.DoesNotContain("already paired question", record.NamingInput);
        Assert.Contains("Synthetic cache hit", request.Input);
        Assert.Empty(request.Sources);
        Assert.Contains("untrusted", request.Instructions);
        Assert.Contains("TITLE ONLY", request.Instructions);
        Assert.DoesNotContain("spoken interview", request.Instructions);
        Assert.Equal("缓存优化讨论", await SessionNaming.GenerateAsync(record, new TextProvider("  “缓存优化讨论”  ")));
        Assert.Equal(string.Concat(Enumerable.Repeat("🧑‍💻", 80)), SessionNaming.Clean(string.Concat(Enumerable.Repeat("🧑‍💻", 80))));
        foreach (var output in new[] { " ", "line one\nline two", new string('字', 81), new string('a', 401) })
            await Assert.ThrowsAsync<CopilotException>(() => SessionNaming.GenerateAsync(record, new TextProvider(output)));
    }

    [Fact]
    public async Task NamingHonorsTimeoutAndCallerCancellationEvenWhenProviderIgnoresToken()
    {
        var record = new SessionRecord(Fixtures.At, Fixtures.At, []);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SessionNaming.GenerateAsync(record,
            new TextProvider("too late", TimeSpan.FromSeconds(10)), TimeSpan.FromMilliseconds(50)).WaitAsync(TimeSpan.FromSeconds(5)));

        var provider = new ControlledReasoningProvider();
        using var cancellation = new CancellationTokenSource();
        var operation = SessionNaming.GenerateAsync(record, provider, cancellationToken: cancellation.Token);
        var call = await provider.NextAsync();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operation.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.True(call.CancellationToken.IsCancellationRequested);
        call.Complete("discard this title");
        await call.Finished.WaitAsync(TimeSpan.FromSeconds(5));
    }
}
