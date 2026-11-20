namespace LiveCopilot.Core.Tests;

public sealed class ConversationStateTests
{
    [Fact]
    public void IncompleteQuestionIsHeldAndStableRevisionsAreValidated()
    {
        var state = new ConversationState();
        var first = Fixtures.Fragment("Why did you choose the", "a");
        Assert.True(state.Append(first));
        Assert.Equal(QuestionPhase.Forming, state.Phase);
        Assert.Null(state.Candidate(Speaker.Them, Fixtures.At, 0));
        Assert.True(state.Append(Fixtures.Fragment(" larger sample size?", "b", start: 500)));
        Assert.Equal("Why did you choose the larger sample size?", state.Candidate(Speaker.Them, Fixtures.At, 0));
        Assert.False(state.Append(first));
        Assert.False(state.Append(first with { Speaker = Speaker.You, Text = "invalid speaker change" }));
        Assert.False(state.Append(first with { EndMs = 100, Text = "invalid shorter revision" }));
        Assert.False(state.Append(first with { StartMs = 600, EndMs = 500 }));
        Assert.True(state.Append(first with { Text = "Why did you prefer the" }));
        Assert.Equal(2, state.Fragments.Count);
        Assert.Contains("prefer", state.Context());
    }

    [Fact]
    public void CompletedQuestionIsSuppressedWhileFollowupAndFailedRetryRemainAvailable()
    {
        var state = new ConversationState();
        state.Append(Fixtures.Fragment("Why choose method B?", "a"));
        var question = Assert.IsType<string>(state.Candidate(Speaker.Them, Fixtures.At, 0));
        state.Begin(question, Speaker.Them, Fixtures.At);
        Assert.Equal(QuestionPhase.Working, state.Phase);
        state.Finish(true, question);
        Assert.Null(state.Candidate(Speaker.Them, Fixtures.At.AddSeconds(10), 0));
        Assert.Equal(QuestionPhase.Duplicate, state.Phase);
        state.Append(Fixtures.Fragment("What about latency?", "b", start: 2500));
        var followup = Assert.IsType<string>(state.Candidate(Speaker.Them, Fixtures.At.AddSeconds(10), 0));
        Assert.Equal("What about latency?", followup);
        Assert.Equal(QuestionPhase.FollowUp, state.Phase);
        state.Begin(followup, Speaker.Them, Fixtures.At.AddSeconds(10));
        state.Finish(false, followup);
        Assert.Equal(followup, state.Candidate(Speaker.Them, Fixtures.At.AddSeconds(11), 7));
        state.Reset();
        Assert.Empty(state.Fragments);
        Assert.Null(state.PreviousQuestion);
        Assert.Equal(QuestionPhase.Listening, state.Phase);
    }

    [Fact]
    public void OwnAnswerSuppressesRemoteCandidateButManualOverrideAndRoomRemainAvailable()
    {
        var state = new ConversationState();
        state.Append(Fixtures.Fragment("What is the sample size?", "q"));
        state.Append(Fixtures.Fragment("128 samples.", "a", Speaker.You, at: Fixtures.At.AddSeconds(1)));
        Assert.Null(state.Candidate(Speaker.Them, Fixtures.At, 0));
        Assert.Equal(QuestionPhase.Answered, state.Phase);
        Assert.NotNull(state.Candidate(Speaker.Them, Fixtures.At, 0, force: true));
        state.Append(Fixtures.Fragment("Why not method A?", "r", Speaker.Room));
        Assert.Equal("Why not method A?", state.Candidate(Speaker.Room, Fixtures.At.AddSeconds(2), 0));
    }

    [Fact]
    public void QueueRevisionsRetainRequestIdentityAndDoNotRestartTakenWork()
    {
        var queue = new QuestionCoordinator();
        void Add(string query, DateTimeOffset at) => queue.Enqueue(query, "context", Speaker.Them, null, null, ContinuousQuestionPolicy.Fast, "asr-1", at);
        Add("Explain cach", Fixtures.At);
        var initial = Assert.Single(queue.Pending);
        Add("Explain caching", Fixtures.At.AddSeconds(1));
        var revised = Assert.Single(queue.Pending);
        Assert.Equal(initial.Id, revised.Id);
        Assert.Equal(initial.AnswerId, revised.AnswerId);
        Assert.Equal("Explain caching", revised.Query);
        Assert.Equal(revised, queue.Take(Fixtures.At.AddSeconds(1)));
        Add("Explain caching in detail", Fixtures.At.AddSeconds(2));
        Assert.Empty(queue.Pending);
    }

    [Fact]
    public void QueueMergesRelatedPendingWorkWaitsForQuietAndDropsExpiredWork()
    {
        var queue = new QuestionCoordinator();
        void Add(string query, int second) => queue.Enqueue(query, "", Speaker.Room, null, null, ContinuousQuestionPolicy.Complete, now: Fixtures.At.AddSeconds(second));
        Add("Explain caching", 0);
        Add("And how does it help?", 1);
        Assert.Equal("Explain caching\nAnd how does it help?", Assert.Single(queue.Pending).Query);
        Assert.Null(queue.Take(Fixtures.At.AddSeconds(2)));
        queue.PostponeUntilQuiet(Fixtures.At.AddSeconds(2));
        Assert.Null(queue.Take(Fixtures.At.AddSeconds(3)));
        Assert.NotNull(queue.Take(Fixtures.At.AddSeconds(3.2)));
        foreach (var query in new[] { "alpha", "beta", "gamma", "delta" }) Add(query, 10);
        Assert.Equal(3, queue.Pending.Count);
        Assert.Equal(1, queue.DroppedCount);
        Assert.Null(queue.Take(Fixtures.At.AddSeconds(36)));
        Assert.Equal(4, queue.DroppedCount);
        queue.Clear();
        Assert.Equal(0, queue.DroppedCount);
    }
}
