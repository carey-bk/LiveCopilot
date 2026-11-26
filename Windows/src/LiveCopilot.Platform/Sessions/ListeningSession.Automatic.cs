using LiveCopilot.Core;

namespace LiveCopilot.Platform.Sessions;

public sealed partial class ListeningSession
{
    private sealed record PendingDelegation(Speaker Speaker, string Id, DateTimeOffset Deadline);

    // The Mac coordinator waits 500 ms for transcript revisions, expires pending requests
    // after 25 s, then queues through the same question policy as manual answer generation.
    private async Task AutomaticLoopAsync(Run run)
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(50));
            while (await timer.WaitForNextTickAsync(run.StartCancellation.Token).ConfigureAwait(false))
            {
                QuestionCoordinator.Candidate? next = null;
                lock (sync)
                {
                    if (current != run || run.StopRequested) return;
                    if (!settings.AutomaticSuggestions) { run.PendingAutomatic = null; run.Questions.Clear(); continue; }
                    var now = DateTimeOffset.UtcNow;
                    if (run.PendingAutomatic is { } pending && now >= run.AutomaticAt)
                    {
                        var path = pending.Speaker == Speaker.Room ? run.Microphone : run.System;
                        if (now > pending.Deadline) run.PendingAutomatic = null;
                        else if (!GetPath(path).SpeechActive)
                        {
                            var question = run.Conversation.Candidate(pending.Speaker, now, cooldown: 0);
                            if (question is not null)
                            {
                                run.Questions.Enqueue(question, run.Conversation.Context(), pending.Speaker, pending.Id, null,
                                    settings.ContinuousQuestionPolicy, run.Conversation.LatestFragmentId(pending.Speaker), now);
                                run.Conversation.Begin(question, pending.Speaker, now);
                                run.PendingAutomatic = null;
                            }
                            else if (run.Conversation.Phase is QuestionPhase.Duplicate or QuestionPhase.Answered) run.PendingAutomatic = null;
                            else run.AutomaticAt = now.AddMilliseconds(500);
                        }
                    }
                    if (suggestion is null && !snapshot.System.SpeechActive && !snapshot.Microphone.SpeechActive)
                        next = run.Questions.Take(now);
                }
                if (next is not null) Request(SuggestionMode.Reply, next.Query, run, next);
            }
        }
        catch (OperationCanceledException) when (run.StartCancellation.IsCancellationRequested) { }
    }
}
