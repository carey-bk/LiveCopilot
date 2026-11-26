using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using LiveCopilot.Core;

namespace LiveCopilot.App.Smoke;

/// Synthetic history only. Uses the production writer in a fresh, isolated smoke directory.
internal static class HistoryFixtures
{
    public static IReadOnlyList<SessionRecord> Seed(string directory)
    {
        var store = new SessionStore(Path.Combine(directory, "sessions"));
        var at = new DateTimeOffset(2026, 11, 16, 1, 0, 0, TimeSpan.Zero);
        var answer = new SessionAnswer(Guid.NewGuid(), Guid.NewGuid(), false, at.AddSeconds(5), at.AddSeconds(6), at.AddSeconds(8),
            "演示花园应先验证什么？", "先验证浇水提醒，再收集试用反馈。[S1]", "completed", null, null,
            [new(1, "synthetic-garden", "虚构花园方案.txt", 1, 0, "演示数据：先试用提醒，再评估反馈。")], null);
        var newest = store.SaveSnapshot([new(new TranscriptLine(Speaker.Room, at, "这是虚构花园项目的演示讨论。"))],
            at, [answer], at.AddSeconds(125), scenario: ScenarioProfile.Meeting)!;
        store.Rename(newest.Id, "虚构花园 · 方案讨论");
        store.SaveSnapshot([new(new TranscriptLine(Speaker.You, at.AddDays(-1), "演示问题：介绍一个虚构的书架项目。"))],
            at.AddDays(-1), [], at.AddDays(-1).AddSeconds(48), scenario: ScenarioProfile.Interview);
        var longStart = at.AddDays(-2);
        store.SaveSnapshot(Enumerable.Range(0, 80).Select(i => new SessionLine(new TranscriptLine(Speaker.Room,
            longStart.AddSeconds(i * 10), $"虚构实验记录 {i + 1}：检查演示样本并讨论下一步。"))).ToValueList(),
            longStart, [], longStart.AddMinutes(14), scenario: ScenarioProfile.Defense);
        if (store.LastError is not null || store.Sessions.Count != 3) throw new IOException("Cannot seed isolated smoke history.");
        return store.Sessions.ToArray();
    }
}
