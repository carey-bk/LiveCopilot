using System.Text.Json.Nodes;

namespace LiveCopilot.Core.Tests;

public sealed class HistoryStorageTests
{
    [Theory]
    [InlineData(ScenarioProfile.Interview)]
    [InlineData(ScenarioProfile.Meeting)]
    [InlineData(ScenarioProfile.Defense)]
    public void ScenarioRoundTripsUsingExistingV2WireFormat(ScenarioProfile scenario)
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var saved = store.SaveSnapshot([new(new TranscriptLine(Speaker.Room, Fixtures.At, "虚构转写"))], Fixtures.At,
            [Fixtures.Answer()], Fixtures.At.AddSeconds(65), [Fixtures.Fragment("虚构转写")], scenario)!;
        Assert.Equal(saved, Assert.Single(new SessionStore(root.Path).Sessions));
        var json = JsonNode.Parse(File.ReadAllText(Path.Combine(root.Path, CoreJson.Id(saved.Id) + ".json")))!;
        Assert.Equal(2, json["schemaVersion"]!.GetValue<int>());
        Assert.Equal(CoreJson.Iso8601(Fixtures.At), json["startedAt"]!.GetValue<string>());
        Assert.NotNull(json["scenario"]);
        Assert.NotNull(json["answers"]![0]!["questionID"]);
        Assert.NotNull(json["answers"]![0]!["sources"]![0]!["documentID"]);
    }

    [Theory]
    [InlineData(null)] [InlineData(1)] [InlineData(2)]
    public void ExistingVersionsLoadWithoutRewritingOrInventingScenario(int? version)
    {
        using var root = new TemporaryDirectory();
        var record = new SessionRecord(Fixtures.At, Fixtures.At, []) { SchemaVersion = version };
        var path = Path.Combine(root.Path, "existing.json");
        var original = CoreJson.Encode(record, session: true);
        File.WriteAllText(path, original);
        var loaded = Assert.Single(new SessionStore(root.Path).Sessions);
        Assert.Equal(record, loaded); Assert.Null(loaded.Scenario); Assert.Null(loaded.Answers);
        Assert.Equal(original, File.ReadAllText(path));
        Assert.Single(Directory.GetFiles(root.Path));
    }

    [Fact]
    public void SaveAndReloadSortNewestFirstAndRefreshExternalWritesAndDeletes()
    {
        using var root = new TemporaryDirectory();
        var writer = new SessionStore(root.Path);
        var old = writer.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()], Fixtures.At)!;
        var reader = new SessionStore(root.Path);
        var newest = writer.SaveSnapshot([], Fixtures.At.AddDays(2), [Fixtures.Answer()], Fixtures.At.AddDays(2))!;
        var middle = writer.SaveSnapshot([], Fixtures.At.AddDays(1), [Fixtures.Answer()], Fixtures.At.AddDays(1))!;
        Assert.Equal([newest.Id, middle.Id, old.Id], writer.Sessions.Select(r => r.Id));
        Assert.Single(reader.Sessions);
        reader.Reload();
        Assert.Equal(writer.Sessions, reader.Sessions);
        Assert.True(writer.Delete(middle));
        reader.Reload();
        Assert.Equal([newest.Id, old.Id], reader.Sessions.Select(r => r.Id));
    }

    [Theory]
    [InlineData("标题", true)] [InlineData("虚构转写", true)] [InlineData("LATENCY", true)]
    [InlineData("caching", true)] [InlineData("性能报告 42", true)] [InlineData("标题 latency", true)]
    [InlineData("  \t", true)] [InlineData("标题 不存在", false)]
    public void SearchIncludesTitleSpeechQuestionsAnswersAndCitations(string query, bool expected)
    {
        var record = new SessionRecord(Fixtures.At, Fixtures.At, [new(new TranscriptLine(Speaker.Room, Fixtures.At, "虚构转写"))])
            { GeneratedTitle = "测试标题", Answers = [Fixtures.Answer()] };
        Assert.Equal(expected, record.Matches(query));
    }

    [Theory]
    [InlineData(true)] [InlineData(false)]
    public void ExportsContainChronologicalRolesStatusAndEvidenceWithoutChangingRecord(bool markdown)
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(Path.Combine(root.Path, "sessions"));
        var answer = Fixtures.Answer(Fixtures.At.AddSeconds(2), "合成答案") with { Warning = "合成提示", Error = "合成错误", State = "failed" };
        var record = store.SaveSnapshot([new(new TranscriptLine(Speaker.Room, Fixtures.At, "合成语音"))], Fixtures.At,
            [answer], Fixtures.At.AddMinutes(2))!;
        var path = Path.Combine(root.Path, "chosen-by-dialog.unusual");
        store.Export(record, path, markdown);
        var text = File.ReadAllText(path);
        Assert.Equal(record.Export(markdown), text);
        Assert.Equal(markdown, text.StartsWith("# ", StringComparison.Ordinal));
        Assert.Equal(markdown, text.Contains("### [", StringComparison.Ordinal));
        foreach (var value in new[] { "2026-", "2 min", "现场语音", "手动提问", "AI 回答", "状态：failed", "合成提示", "合成错误", "[S1]", "性能报告", "42 ms" })
            Assert.Contains(value, text);
        Assert.True(text.IndexOf("合成语音", StringComparison.Ordinal) < text.IndexOf("合成答案", StringComparison.Ordinal));
        Assert.Equal(record, Assert.Single(new SessionStore(Path.Combine(root.Path, "sessions")).Sessions));
    }

    [Theory]
    [InlineData("broken")]
    [InlineData("root-null")]
    [InlineData("missing-fields")]
    [InlineData("future-version")]
    [InlineData("negative-version")]
    [InlineData("null-lines")]
    [InlineData("null-line")]
    [InlineData("null-content")]
    [InlineData("null-answer")]
    [InlineData("null-sources")]
    [InlineData("null-source")]
    [InlineData("unknown-speaker")]
    public void DamagedAndUnknownFilesAreSkippedAndLoggedWithoutContentOrRewrite(string damage)
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var valid = store.SaveSnapshot([new(new TranscriptLine(Speaker.Room, Fixtures.At, "synthetic-secret-marker"))], Fixtures.At, [Fixtures.Answer()])!;
        var json = JsonNode.Parse(CoreJson.Encode(valid with { Id = Guid.NewGuid() }, session: true))!;
        switch (damage)
        {
            case "future-version": json["schemaVersion"] = 99; break;
            case "negative-version": json["schemaVersion"] = -1; break;
            case "null-lines": json["lines"] = null; break;
            case "null-line": json["lines"]![0] = null; break;
            case "null-content": json["lines"]![0]!["content"] = null; break;
            case "null-answer": json["answers"]![0] = null; break;
            case "null-sources": json["answers"]![0]!["sources"] = null; break;
            case "null-source": json["answers"]![0]!["sources"]![0] = null; break;
            case "unknown-speaker": json["lines"]![0]!["speaker"] = "future-speaker"; break;
        }
        var bytes = damage switch { "broken" => "{", "root-null" => "null", "missing-fields" => "{}", _ => json.ToJsonString() };
        var path = Path.Combine(root.Path, "damaged.json"); File.WriteAllText(path, bytes);
        var logged = new List<SessionLoadIssue>();
        var loaded = new SessionStore(root.Path, logged.Add);
        Assert.Equal(valid.Id, Assert.Single(loaded.Sessions).Id);
        Assert.Equal("damaged.json", Assert.Single(logged).FileName);
        Assert.Equal(logged, loaded.LoadIssues);
        Assert.DoesNotContain("synthetic-secret-marker", logged[0].Reason);
        Assert.DoesNotContain(root.Path, logged[0].ToString());
        Assert.Equal(bytes, File.ReadAllText(path));
    }

    [Fact]
    public void DeleteUsesLoadedPathAndRemovesOnlySelectedJsonAndDraft()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var deleted = store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()])!;
        var kept = store.SaveSnapshot([], Fixtures.At.AddDays(1), [Fixtures.Answer()])!;
        File.Move(Path.Combine(root.Path, CoreJson.Id(deleted.Id) + ".json"), Path.Combine(root.Path, "imported.json"));
        File.Move(Path.Combine(root.Path, CoreJson.Id(deleted.Id) + ".txt"), Path.Combine(root.Path, "imported.txt"));
        store.Reload();
        Assert.True(store.Rename(deleted.Id, "导入记录"));
        Assert.Equal(2, Directory.GetFiles(root.Path, "*.json").Length);
        Assert.True(store.Delete(deleted));
        Assert.False(File.Exists(Path.Combine(root.Path, "imported.txt")));
        Assert.Equal(kept.Id, Assert.Single(new SessionStore(root.Path).Sessions).Id);
        Assert.True(store.HasFiles);
    }

    [Fact]
    public void DeleteFailureKeepsRecordVisibleAndReportsError()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path);
        var record = store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()])!;
        var path = Path.Combine(root.Path, CoreJson.Id(record.Id) + ".json");
        File.Delete(path); Directory.CreateDirectory(path);
        Assert.False(store.Delete(record));
        Assert.Equal(record, Assert.Single(store.Sessions)); Assert.NotNull(store.LastError);
    }

    [Fact]
    public void ClearRemovesHistoryIncludingUnreadableFilesButPreservesExternalExportsAndOtherData()
    {
        using var root = new TemporaryDirectory();
        var history = Path.Combine(root.Path, "sessions");
        var store = new SessionStore(history);
        var record = store.SaveSnapshot([], Fixtures.At, [Fixtures.Answer()])!;
        store.Export(record, Path.Combine(root.Path, "external.txt"));
        File.WriteAllText(Path.Combine(history, "broken.json"), "{");
        File.WriteAllText(Path.Combine(history, "orphan.txt"), "synthetic draft");
        File.WriteAllText(Path.Combine(history, "keep.bin"), "unrelated data");
        Assert.True(store.Clear()); Assert.Empty(store.Sessions); Assert.Empty(store.LoadIssues); Assert.False(store.HasFiles);
        Assert.Empty(new SessionStore(history).Sessions);
        Assert.Equal(["keep.bin"], Directory.GetFiles(history).Select(Path.GetFileName));
        Assert.True(File.Exists(Path.Combine(root.Path, "external.txt")));
        Assert.False(store.Update(record.Id, r => r));
        Assert.True(store.Clear());
    }
}
