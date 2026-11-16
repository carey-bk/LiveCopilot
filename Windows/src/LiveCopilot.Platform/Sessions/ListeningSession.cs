using LiveCopilot.Core;
using LiveCopilot.Platform.Audio;

namespace LiveCopilot.Platform.Sessions;

/// Owns the injected stores exclusively until disposal. Provider events serialize store
/// access, while lifecycle operations serialize separately. No external call is made with
/// the state lock held (except the owned synchronous stores).
/// Changed may run on any worker thread: observers must return promptly, never synchronously
/// wait for lifecycle methods, and WPF hosts must use Dispatcher.BeginInvoke and read Snapshot.
public sealed partial class ListeningSession : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly IAudioSourceFactory audioFactory;
    private readonly Func<Speaker, ListeningService, ListeningProvider> providerFactory;
    private readonly Func<Speaker, AppSettings, ListeningProvider>? configuredProviderFactory;
    private readonly TranscriptStore transcript;
    private readonly SessionStore? sessions;
    private AppSettings settings;
    private readonly ICaptureClock? clock;
    private readonly Func<IReasoningProvider>? reasoningFactory;
    private readonly Func<AppSettings, IReasoningProvider>? configuredReasoningFactory;
    private readonly IKnowledgeRetriever? knowledge;
    private readonly Func<AppSettings, IEmbeddingProvider>? embeddingFactory;
    private readonly TimeSpan answerTimeout;
    private SuggestionRun? suggestion;
    private readonly List<SuggestionRun> pendingAnswers = [];
    private ListeningSnapshot snapshot = new();
    private Run? current;
    private bool disposed, resetting, archiveFailed;

    public event Action? Changed;
    public ListeningSnapshot Snapshot { get { lock (sync) return snapshot; } }

    public ListeningSession(IAudioSourceFactory audioFactory,
        Func<Speaker, ListeningService, ListeningProvider> providerFactory, AppSettings settings,
        TranscriptStore? transcript = null, SessionStore? sessions = null, ICaptureClock? clock = null,
        Func<IReasoningProvider>? reasoningFactory = null, TimeSpan? answerTimeout = null,
        IKnowledgeRetriever? knowledgeRetriever = null, Func<AppSettings, IEmbeddingProvider>? embeddingFactory = null,
        Func<AppSettings, IReasoningProvider>? configuredReasoningFactory = null,
        Func<Speaker, AppSettings, ListeningProvider>? configuredProviderFactory = null)
    {
        this.audioFactory = audioFactory;
        this.providerFactory = providerFactory;
        this.configuredProviderFactory = configuredProviderFactory;
        this.settings = settings with { };
        this.transcript = transcript ?? new();
        this.sessions = sessions;
        this.clock = clock;
        this.reasoningFactory = reasoningFactory;
        this.configuredReasoningFactory = configuredReasoningFactory;
        knowledge = knowledgeRetriever;
        this.embeddingFactory = embeddingFactory;
        this.answerTimeout = answerTimeout ?? TimeSpan.FromSeconds(90);
        if (this.answerTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(answerTimeout));
    }

    /// Future answers and listening runs take a copy. In-flight audio and answers retain theirs.
    public void Configure(AppSettings value)
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            settings = value with { };
        }
        Changed?.Invoke();
    }

    /// Applies to the next request; each active request retains its own selection.
    public void ConfigureKnowledge(AppSettings value)
    {
        lock (sync)
        {
            settings.KnowledgeMode = value.KnowledgeMode;
            settings.EmbeddingService = value.EmbeddingService;
            settings.EmbeddingModel = value.EmbeddingModel;
            settings.RetrievalCount = Math.Clamp(value.RetrievalCount, 1, 12);
        }
    }

    /// Idempotent while active. Cancellation cancels this start; StopAsync also interrupts
    /// model readiness/capture startup. Operational failures are exposed through Snapshot.
    public async Task StartAsync(CancellationToken cancellationToken = default, bool microphoneEnabled = true)
    {
        await lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Run run;
            SuggestionRun? previous;
            lock (sync)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (current is not null || resetting) return;
                previous = InterruptSuggestion();
                // A typed-only conversation must be archived before starting a new audio run.
                SaveStandaloneAnswers();
                if (archiveFailed)
                {
                    run = null!;
                }
                else if (!microphoneEnabled && settings.Mode == OperatingMode.InPerson)
                {
                    snapshot = snapshot with { State = ListeningState.Failed, Error = "现场交流需要麦克风，请开启麦克风后重试。" };
                    run = null!;
                }
                else if (settings.ListeningService is not (ListeningService.Zipformer or ListeningService.Paraformer or ListeningService.OpenAI))
                {
                    snapshot = snapshot with { State = ListeningState.Failed,
                        Error = "Windows 尚未接入 Apple 听写，请选择 Zipformer、Paraformer 或 OpenAI 云端。" };
                    run = null!;
                }
                else
                {
                    archiveFailed = false;
                    transcript.Clear();
                    run = new(audioFactory, clock, settings with { }, microphoneEnabled);
                    current = run;
                    snapshot = new() { State = ListeningState.Starting, SampleRate = settings.ListeningService.SampleRate() };
                }
            }
            CancelSuggestion(previous);
            Changed?.Invoke();
            if (run is null) return;
            using var registration = cancellationToken.Register(() => ScheduleStop(run));
            try
            {
                foreach (var path in run.ActivePaths)
                {
                    path.Capture.Configure(run.Settings.ListeningService.SampleRate());
                    Prepare(run, path);
                }
                foreach (var path in run.ActivePaths) Connect(run, path);
                await Task.WhenAll(run.ActivePaths.Select(path => path.Ready.Task))
                    .WaitAsync(run.StartCancellation.Token).ConfigureAwait(false);
                CheckStarting(run);
                foreach (var path in run.ActivePaths) await StartCaptureAsync(run, path).ConfigureAwait(false);
                lock (sync)
                {
                    if (run.StopRequested) throw new OperationCanceledException();
                    run.WasListening = true;
                    snapshot = snapshot with { State = ListeningState.Listening };
                }
                if (run.Settings.ListeningService == ListeningService.OpenAI) run.AutomaticWorker = Task.Run(() => AutomaticLoopAsync(run));
                Changed?.Invoke();
            }
            catch (OperationCanceledException) when (run.StopRequested || cancellationToken.IsCancellationRequested)
            { await TearDownAsync(run).ConfigureAwait(false); }
            catch (Exception e)
            {
                Fail(run, "无法开始聆听：" + e.Message);
                await TearDownAsync(run).ConfigureAwait(false);
            }
        }
        finally { lifecycle.Release(); }
    }

    private void Prepare(Run run, Path path)
    {
        CheckStarting(run);
        path.Live = configuredProviderFactory is null ? providerFactory(path.Speaker, run.Settings.ListeningService)
            : configuredProviderFactory(path.Speaker, run.Settings with { });
        path.Live.Provider.OnEvent = value => Receive(run, path, value);
        path.Capture.Error += message => Fail(run, message);
        // AudioCaptureManager owns the callback lifetime. SendAudio must promptly copy/queue
        // the borrowed PCM, as LocalLiveProvider does. No task/extra audio queue per buffer.
        path.Capture.Pcm16Available += pcm => path.Live.Provider.SendAudio(pcm);
        if (run.Settings.ListeningService == ListeningService.Zipformer)
        {
            if (path.Live.UpdateTerms is null) throw new InvalidOperationException("Zipformer 提供器未提供热词配置。");
            path.Live.UpdateTerms(run.Settings.ProfessionalTerms);
        }
    }

    private void Connect(Run run, Path path)
    {
        CheckStarting(run);
        path.Live!.Provider.Connect("");
        CheckStarting(run);
    }

    private void CheckStarting(Run run)
    {
        lock (sync) if (run.StopRequested) throw new OperationCanceledException();
    }

    private async Task StartCaptureAsync(Run run, Path path)
    {
        CheckStarting(run);
        await path.Capture.StartAsync(run.StartCancellation.Token).ConfigureAwait(false);
        CheckStarting(run);
        if (!path.Capture.IsCapturing)
            throw new InvalidOperationException(path.Capture.LastError ?? "音频采集未能启动。");
        var description = path.Capture.SourceDescription;
        lock (sync) SetPath(path, GetPath(path) with { Capturing = true, SourceDescription = description });
        Changed?.Invoke();
    }

    private ListeningPathSnapshot GetPath(Path path) => path.Speaker == Speaker.Them ? snapshot.System : snapshot.Microphone;
    private void SetPath(Path path, ListeningPathSnapshot value) => snapshot = path.Speaker == Speaker.Them
        ? snapshot with { System = value } : snapshot with { Microphone = value };

    private void Receive(Run run, Path path, LiveEvent value)
    {
        if (value is LiveEvent.Failed { WillRetry: false } failure) { Fail(run, failure.Message); return; }
        string? backend = null;
        if (value is LiveEvent.Ready)
        {
            try { backend = path.Live?.Backend?.Invoke(); }
            catch (Exception e) { Fail(run, "无法读取语音后端状态：" + e.Message); return; }
        }
        string? error = null;
        ILiveProvider? contextProvider = null;
        string? ownText = null;
        lock (sync)
        {
            if (current != run || !run.AcceptEvents) return;
            switch (value)
            {
                case LiveEvent.Ready:
                    SetPath(path, GetPath(path) with { Backend = backend, Status = null });
                    path.Ready.TrySetResult();
                    break;
                case LiveEvent.Failed retrying:
                    SetPath(path, GetPath(path) with { Status = retrying.Message });
                    break;
                case LiveEvent.Status status:
                    SetPath(path, GetPath(path) with { Status = status.Text });
                    break;
                case LiveEvent.Transcript final:
                    var fragment = final.Fragment with { Speaker = path.Speaker };
                    if (!run.Conversation.Append(fragment)) return;
                    transcript.Ingest(fragment);
                    if (path.Speaker == Speaker.You && run.Settings.ListeningService == ListeningService.OpenAI)
                    { contextProvider = run.System.Live?.Provider; ownText = "You said: " + fragment.Text; }
                    if (run.PendingAutomatic is not null) run.AutomaticAt = DateTimeOffset.UtcNow.AddMilliseconds(500);
                    transcript.ClearPartial(path.Speaker);
                    break;
                case LiveEvent.PartialTranscript partial:
                    transcript.SetPartial(partial.Text, path.Speaker);
                    break;
                case LiveEvent.Delegation delegation:
                    if (run.Settings.ListeningService != ListeningService.OpenAI || run.StopRequested ||
                        !settings.AutomaticSuggestions || path.Speaker == Speaker.You || !run.Delegations.Add(delegation.Id)) return;
                    if (run.Delegations.Count > 400) { run.Delegations.Clear(); run.Delegations.Add(delegation.Id); }
                    run.PendingAutomatic = new(path.Speaker, delegation.Id, DateTimeOffset.UtcNow.AddSeconds(25));
                    run.AutomaticAt = DateTimeOffset.UtcNow.AddMilliseconds(500);
                    break;
                case LiveEvent.SpeechActivity speech:
                    SetPath(path, GetPath(path) with { SpeechActive = speech.Active });
                    if (!speech.Active && settings.ContinuousQuestionPolicy == ContinuousQuestionPolicy.Complete) run.Questions.PostponeUntilQuiet();
                    break;
                case LiveEvent.Closed closed:
                    if (!run.Disconnecting) error = "语音连接意外关闭，请重新开始聆听。";
                    else if (!closed.Finalized && run.WasListening) error = run.Settings.ListeningService == ListeningService.OpenAI
                        ? "云端会话未确认完成，最后一段转写可能不完整。" : "本地听写未能完成最后一段转写。";
                    SetPath(path, GetPath(path) with { SpeechActive = false });
                    break;
                default: return;
            }
            RefreshTranscript();
        }
        if (contextProvider is not null && ownText is not null) contextProvider.AppendContext(ownText, null);
        if (error is not null) Fail(run, error);
        Changed?.Invoke();
    }

    private void RefreshTranscript() => snapshot = snapshot with
    { Lines = transcript.Lines, PartialThem = transcript.PartialThem, PartialYou = transcript.PartialYou };

    private void Fail(Run run, string message)
    {
        lock (sync)
        {
            if (current != run || !run.AcceptEvents) return;
            // The first failure is the actionable cause, even when both paths fail together.
            snapshot = snapshot with { Error = snapshot.Error ?? message };
        }
        ScheduleStop(run);
        Changed?.Invoke();
    }

    private void ScheduleStop(Run run)
    {
        SuggestionRun? previous;
        lock (sync)
        {
            if (current != run || run.StopRequested) return;
            run.StopRequested = true;
            previous = InterruptSuggestion();
            snapshot = snapshot with { IsStopping = true };
        }
        CancelSuggestion(previous);
        // Never stop/cancel captures inline from a PCM/provider callback: it may hold a
        // provider or capture lock, and StopAsync must wait for that callback to finish.
        _ = Task.Run(() => StopRunAsync(run));
    }

    public void Request(SuggestionMode mode) => Request(mode, null);

    /// Typed questions use the same retrieval, streaming, cancellation and history pipeline.
    public void Ask(string question)
    {
        if (!string.IsNullOrWhiteSpace(question)) Request(SuggestionMode.Reply, question.Trim());
    }

    private void Request(SuggestionMode mode, string? question, Run? automaticRun = null, QuestionCoordinator.Candidate? candidate = null)
    {
        SuggestionRun? previous;
        SuggestionRun? next = null;
        AnswerRequest? answer = null;
        lock (sync)
        {
            if (disposed || resetting || snapshot.IsStopping || !settings.IsEnabled(mode)) return;
            if (automaticRun is not null && (current != automaticRun || automaticRun.StopRequested || suggestion is not null || !settings.AutomaticSuggestions)) return;
            previous = InterruptSuggestion();
            var label = mode switch { SuggestionMode.Reply => "回答", SuggestionMode.Recap => "总结", _ => "追问" };
            snapshot = snapshot with { LastRequestedMode = mode, SuggestionText = "", SuggestionError = null,
                SuggestionIsLoading = false, Sources = [], Warning = null };
            if (reasoningFactory is null && configuredReasoningFactory is null)
                snapshot = snapshot with { SuggestionStatus = $"已请求{label}，推理服务尚未接入" };
            else
            {
                var context = candidate?.Context ?? transcript.RecentContext();
                var partial = transcript.PartialThem.Trim();
                if (partial.Length > 0) context = (context.Length > 0 ? context + "\n" : "") + "Them: " + partial;
                if (context.Length == 0 && question is null)
                    snapshot = snapshot with { SuggestionStatus = "还没有对话。先开始听写，或等有转写后再请求。" };
                else
                {
                    var latest = partial.Length > 0 ? partial : transcript.Lines.LastOrDefault(l => l.Speaker == Speaker.Them)?.Content;
                    var query = question ?? (mode switch
                    {
                        SuggestionMode.Reply => string.IsNullOrWhiteSpace(latest) ? "Help me answer the latest substantive question in this conversation." : latest.Trim(),
                        SuggestionMode.Recap => "Summarize the recent conversation, decisions and unresolved questions.",
                        _ => "Suggest one useful follow-up question based on this conversation."
                    });
                    // Exclude context from RetrievalQuery too: its semantic field can enter Input.
                    var conversation = settings.IncludeConversation ? context : "";
                    answer = new(RetrievalQuery.Formulate(query, conversation), conversation, settings.Scenario, [])
                    {
                        Mode = mode, KnowledgeMode = settings.KnowledgeMode, AnswerLanguage = settings.AnswerLanguage,
                        BilingualAnswers = settings.BilingualAnswers, AdditionalAnswerInstructions = settings.AdditionalAnswerInstructions,
                        LanguageQuestion = question ?? latest
                    };
                    next = new(settings with { }) { AutomaticRun = automaticRun, Candidate = candidate };
                    if (sessions is not null) pendingAnswers.Add(next);
                    next.Store.Begin(mode, query);
                    next.Store.Trace = new();
                    next.Store.Mark(PipelineStage.AnalysisDispatched);
                    suggestion = next;
                    PublishSuggestion(next, "正在等待回答…");
                }
            }
        }
        CancelSuggestion(previous);
        Changed?.Invoke();
        if (next is not null && answer is not null)
        {
            _ = WatchSuggestionAsync(next);
            _ = Task.Run(() => GenerateSuggestionAsync(next, answer));
        }
    }

    // Called only under sync. Identity guards protect against even non-cooperative providers.
    private SuggestionRun? InterruptSuggestion()
    {
        var previous = suggestion;
        if (previous is null) return null;
        suggestion = null;
        previous.Store.Mark(PipelineStage.Cancelled);
        previous.Store.Interrupt();
        previous.AutomaticRun?.Conversation.Finish(false, previous.Candidate!.Query);
        PublishSuggestion(previous, "回答已取消");
        return previous;
    }

    private static void CancelSuggestion(SuggestionRun? run)
    {
        if (run is not null) _ = CancelAsync(run);
        static async Task CancelAsync(SuggestionRun run)
        {
            try { await run.Cancellation.CancelAsync().ConfigureAwait(false); }
            catch (ObjectDisposedException) { }
            catch (AggregateException) { /* A provider cancellation callback must not break session teardown. */ }
        }
    }

    private void PublishSuggestion(SuggestionRun run, string status) => snapshot = snapshot with
    {
        SuggestionStatus = status, SuggestionText = run.Store.Text,
        SuggestionIsLoading = run.Store.IsLoading, SuggestionError = run.Store.Error,
        Sources = run.Store.Sources, Warning = run.Store.Warning
    };

    private async Task WatchSuggestionAsync(SuggestionRun run)
    {
        try { await Task.Delay(answerTimeout, run.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        lock (sync)
        {
            if (suggestion != run) return;
            suggestion = null;
            run.Store.Mark(PipelineStage.Failed);
            run.Store.Fail("回答超时，请手动重试。");
            run.AutomaticRun?.Conversation.Finish(false, run.Candidate!.Query);
            PublishSuggestion(run, run.Store.Error!);
        }
        CancelSuggestion(run);
        Changed?.Invoke();
    }

    private async Task GenerateSuggestionAsync(SuggestionRun run, AnswerRequest answer)
    {
        try
        {
            run.Token.ThrowIfCancellationRequested();
            answer = answer with { Sources = await RetrieveEvidenceAsync(run, answer).ConfigureAwait(false) };
            run.Token.ThrowIfCancellationRequested();
            lock (sync)
            {
                if (suggestion != run) return;
                run.Store.Sources = answer.Sources;
                run.Store.Mark(PipelineStage.RagComplete);
                PublishSuggestion(run, "正在等待回答…");
            }
            Changed?.Invoke();
            var missingEvidence = answer.KnowledgeMode == KnowledgeMode.KnowledgeBaseOnly && answer.Sources.Count == 0;
            if (missingEvidence)
            {
                var missing = answer.BilingualAnswers
                    ? AnswerLanguage.Chinese.MissingEvidence(answer.Query.Question) + "\n" + AnswerLanguage.English.MissingEvidence(answer.Query.Question)
                    : answer.AnswerLanguage.MissingEvidence(answer.LanguageQuestion ?? answer.Query.Question);
                lock (sync) { if (suggestion != run) return; run.Store.AppendDelta(missing); }
            }
            else
            {
                answer.OnStreamProgress = (stage, time) =>
                {
                    lock (sync)
                    {
                        if (suggestion != run) return Task.CompletedTask;
                        run.Store.Mark(stage, time);
                        if (stage == PipelineStage.ReasoningStarted && run.Store.Text.Length == 0) PublishSuggestion(run, "模型正在思考…");
                    }
                    Changed?.Invoke();
                    return Task.CompletedTask;
                };
                var provider = configuredReasoningFactory is null ? reasoningFactory!() : configuredReasoningFactory(run.Settings with { });
                run.Token.ThrowIfCancellationRequested();
                lock (sync) { if (suggestion != run) return; run.Store.Mark(PipelineStage.ModelRequest); }
                await foreach (var delta in provider.Stream(answer, run.Token).WithCancellation(run.Token).ConfigureAwait(false))
                {
                    run.Token.ThrowIfCancellationRequested();
                    if (delta.Length == 0) continue;
                    lock (sync)
                    {
                        if (suggestion != run) return;
                        if (run.Store.FirstTextMs is null)
                        {
                            run.Store.Mark(PipelineStage.FirstToken);
                            run.Store.FirstTextMs = run.Store.Trace!.Milliseconds(PipelineStage.FirstToken);
                        }
                        run.Store.AppendDelta(delta);
                        PublishSuggestion(run, "正在生成回答…");
                    }
                    Changed?.Invoke();
                }
            }
            ILiveProvider? completedProvider = null;
            lock (sync)
            {
                if (suggestion != run) return;
                run.Store.Mark(PipelineStage.AnswerComplete);
                run.Store.Finish();
                PublishSuggestion(run, missingEvidence ? "未找到知识库证据" : "回答已完成");
                if (run.AutomaticRun is { } live && current == live && !live.StopRequested && run.Candidate is { } candidate)
                {
                    live.Conversation.Finish(true, candidate.Query);
                    completedProvider = (candidate.Speaker == Speaker.Room ? live.Microphone : live.System).Live?.Provider;
                }
                suggestion = null;
            }
            completedProvider?.AppendContext(OpenAILiveProtocol.AssistanceSummary(run.Store.Text), run.Candidate?.DelegationId);
            Changed?.Invoke();
        }
        catch (Exception error)
        {
            lock (sync)
            {
                if (suggestion != run) return;
                var message = error.Message == ReasoningProviderFactory.MissingKeyMessage ? "请先配置分析服务 API 密钥"
                    : error is OperationCanceledException ? "回答超时，请手动重试。" : error.Message;
                run.Store.Mark(PipelineStage.Failed);
                run.Store.Fail(message);
                run.AutomaticRun?.Conversation.Finish(false, run.Candidate!.Query);
                PublishSuggestion(run, message == "请先配置分析服务 API 密钥" || error is OperationCanceledException ? message : "回答失败：" + message);
                suggestion = null;
            }
            Changed?.Invoke();
        }
        finally
        {
            // Cancel the deadline, without waiting for an uncooperative provider on Stop.
            try { await run.Cancellation.CancelAsync().ConfigureAwait(false); }
            catch (AggregateException) { }
            run.Cancellation.Dispose();
        }
    }

    private async Task<ValueList<RetrievedSource>> RetrieveEvidenceAsync(SuggestionRun run, AnswerRequest answer)
    {
        if (!answer.KnowledgeMode.UsesKnowledgeBase()) return [];
        var started = PipelineTrace.Uptime;
        try
        {
            if (knowledge is null) throw new CopilotException("Knowledge unavailable");
            var documents = knowledge.Documents();
            run.Token.ThrowIfCancellationRequested();
            if (!documents.Any(d => d.ChunkCount > 0)) return [];
            var identity = run.Settings.SelectedEmbeddingIdentity;
            IReadOnlyList<float>? vector = null;
            if (documents.Any(d => d.ChunkCount > 0 && d.EmbeddingModel == identity))
            {
                try
                {
                    lock (sync) { if (suggestion != run) return []; run.Store.Mark(PipelineStage.EmbeddingStart); }
                    var provider = embeddingFactory?.Invoke(run.Settings) ?? throw new CopilotException("Embedding unavailable");
                    if (provider.Model != identity) throw new CopilotException("Embedding identity mismatch");
                    var vectors = await provider.EmbedAsync([answer.Query.Semantic], run.Token).ConfigureAwait(false);
                    run.Token.ThrowIfCancellationRequested();
                    if (vectors.Count != 1 || vectors[0].Count == 0 || vectors[0].Any(v => !float.IsFinite(v)))
                        throw new CopilotException("Invalid query vector");
                    vector = vectors[0];
                    lock (sync) { if (suggestion != run) return []; run.Store.Mark(PipelineStage.EmbeddingComplete); }
                }
                catch (Exception)
                {
                    run.Token.ThrowIfCancellationRequested();
                    lock (sync) { if (suggestion != run) return []; run.Store.Warning = "语义检索不可用，已改用本地关键词检索"; }
                }
            }
            run.Token.ThrowIfCancellationRequested();
            lock (sync) { if (suggestion != run) return []; }
            var limit = Math.Clamp(run.Settings.RetrievalCount, 1, 12);
            return knowledge.Retrieve(answer.Query, vector, identity, limit).Take(limit).ToValueList();
        }
        catch (Exception)
        {
            run.Token.ThrowIfCancellationRequested();
            lock (sync)
            {
                if (suggestion != run) return [];
                run.Store.Warning = answer.KnowledgeMode == KnowledgeMode.Hybrid
                    ? "知识库不可用，将根据通用知识和对话继续回答。" : "知识库不可用，仅知识库模式无法在没有证据时回答。";
            }
            return [];
        }
        finally
        {
            lock (sync) { if (suggestion == run) run.Store.RetrievalMs = (int)((PipelineTrace.Uptime - started) * 1000); }
        }
    }

    /// Save/flush through the existing stop path before clearing the visible conversation.
    /// A failed save keeps the transcript available; stale provider callbacks remain fenced.
    public async Task<bool> ResetAsync()
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (resetting) return false;
            resetting = true;
        }
        try
        {
            await StopAsync().ConfigureAwait(false);
            await lifecycle.WaitAsync().ConfigureAwait(false);
            try
            {
                lock (sync)
                {
                    if (archiveFailed) return false;
                    transcript.Clear();
                    pendingAnswers.Clear();
                    snapshot = new();
                }
            }
            finally { lifecycle.Release(); }
            Changed?.Invoke();
            return true;
        }
        finally { lock (sync) resetting = false; }
    }

    public async Task StopAsync()
    {
        Run? run;
        SuggestionRun? previous;
        lock (sync)
        {
            previous = InterruptSuggestion();
            run = current;
            if (run is null)
            {
                SaveStandaloneAnswers();
                if (snapshot.State == ListeningState.Idle) snapshot = snapshot with { State = ListeningState.Stopped };
            }
            else { run.StopRequested = true; snapshot = snapshot with { IsStopping = true }; }
        }
        CancelSuggestion(previous);
        Changed?.Invoke();
        if (run is not null) await StopRunAsync(run).ConfigureAwait(false);
    }

    private async Task StopRunAsync(Run run)
    {
        try { await run.StartCancellation.CancelAsync().ConfigureAwait(false); }
        catch (ObjectDisposedException) { /* A serialized teardown already completed. */ }
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (sync) if (current != run) return;
            await TearDownAsync(run).ConfigureAwait(false);
        }
        finally { lifecycle.Release(); }
    }

    private async Task TearDownAsync(Run run)
    {
        lock (sync) { run.StopRequested = true; snapshot = snapshot with { IsStopping = true }; }
        await run.StartCancellation.CancelAsync().ConfigureAwait(false);
        if (run.AutomaticWorker is not null) await run.AutomaticWorker.ConfigureAwait(false);
        await Task.WhenAll(run.System.Capture.StopAsync(), run.Microphone.Capture.StopAsync()).ConfigureAwait(false);
        lock (sync)
        {
            run.Disconnecting = true;
            snapshot = snapshot with { System = snapshot.System with { Capturing = false },
                Microphone = snapshot.Microphone with { Capturing = false } };
        }
        // Handlers remain installed through both disconnects, including final ASR flush.
        await Task.WhenAll(DisconnectAsync(run, run.System), DisconnectAsync(run, run.Microphone)).ConfigureAwait(false);
        await run.System.Capture.DisposeAsync().ConfigureAwait(false);
        await run.Microphone.Capture.DisposeAsync().ConfigureAwait(false);
        TranscriptLine[] lines;
        ValueList<TranscriptFragment> fragments;
        bool hasContent;
        ValueList<SessionAnswer> answers;
        lock (sync)
        {
            run.AcceptEvents = false;
            lines = transcript.ArchivedLines.ToArray();
            fragments = transcript.FragmentRevisions.ToValueList();
            answers = pendingAnswers.Select(a => a.Snapshot()).ToValueList();
            hasContent = transcript.HasContent || answers.Count > 0;
        }
        if (run.System.Live is { } system) system.Provider.OnEvent = null;
        if (run.Microphone.Live is { } mic) mic.Provider.OnEvent = null;
        if (hasContent && sessions is not null)
        {
            try
            {
                var saved = sessions.SaveSnapshot(lines.Select(l => new SessionLine(l)).ToValueList(), run.StartedAt, answers,
                    DateTimeOffset.UtcNow, fragments, run.Settings.Scenario);
                if (saved is not null) { lock (sync) pendingAnswers.Clear(); }
                if (sessions.LastError is { } error) PersistenceError(error);
            }
            catch (Exception e) { PersistenceError(e.Message); }
        }
        lock (sync)
        {
            current = null;
            snapshot = snapshot with { State = snapshot.Error is null ? ListeningState.Stopped : ListeningState.Failed,
                IsStopping = false, System = snapshot.System with { SpeechActive = false },
                Microphone = snapshot.Microphone with { SpeechActive = false } };
            RefreshTranscript();
        }
        run.StartCancellation.Dispose();
        Changed?.Invoke();
    }

    // Called under sync, only when no audio run owns the transcript. Clearing on success
    // prevents duplicate archives on repeated Stop/Reset/Dispose and preserves failed saves.
    private void SaveStandaloneAnswers()
    {
        if (pendingAnswers.Count == 0 || sessions is null || archiveFailed) return;
        try
        {
            var first = pendingAnswers[0];
            var saved = sessions.SaveSnapshot([], first.CreatedAt, pendingAnswers.Select(a => a.Snapshot()).ToValueList(),
                DateTimeOffset.UtcNow, scenario: first.Settings.Scenario);
            if (saved is not null) pendingAnswers.Clear();
            if (sessions.LastError is { } error) PersistenceError(error);
        }
        catch (Exception e) { PersistenceError(e.Message); }
    }

    private async Task DisconnectAsync(Run run, Path path)
    {
        if (path.Live is null) return;
        try { await path.Live.Provider.DisconnectAsync().ConfigureAwait(false); }
        catch (Exception e) { Fail(run, "停止语音识别失败：" + e.Message); }
    }

    private void PersistenceError(string message)
    {
        lock (sync)
        {
            archiveFailed = true;
            snapshot = snapshot with { Error = (snapshot.Error is null ? "" : snapshot.Error + "\n") + "会话保存失败：" + message };
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (sync) disposed = true;
        await StopAsync().ConfigureAwait(false);
    }

    private sealed class Path(IAudioSourceFactory factory, AudioInput input, Speaker speaker, ICaptureClock? clock)
    {
        public AudioCaptureManager Capture { get; } = new(factory, input, clock);
        public Speaker Speaker { get; } = speaker;
        public ListeningProvider? Live { get; set; }
        public TaskCompletionSource Ready { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class SuggestionRun
    {
        public Guid Id { get; } = Guid.NewGuid();
        public Guid QuestionId { get; } = Guid.NewGuid();
        public DateTimeOffset CreatedAt { get; } = DateTimeOffset.UtcNow;
        public SessionAnswer Snapshot() => new(Id, QuestionId, Candidate is not null, CreatedAt, Store.AnsweredAt, Store.CompletedAt,
            Store.Question, Store.Text, Store.State.ToString().ToLowerInvariant(), Store.Warning, Store.Error,
            Store.CitedSources.Select(citation => new SessionCitation(citation.Index, citation.Source.Chunk.DocumentId,
                citation.Source.Chunk.DocumentName, citation.Source.Chunk.Page, citation.Source.Chunk.Ordinal, citation.Source.Chunk.Text)).ToValueList(), Candidate?.SourceId);
        public Run? AutomaticRun { get; init; }
        public QuestionCoordinator.Candidate? Candidate { get; init; }
        public AppSettings Settings { get; }
        public SuggestionStore Store { get; } = new();
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken Token { get; }
        public SuggestionRun(AppSettings settings) { Settings = settings; Token = Cancellation.Token; }
    }

    private sealed class Run(IAudioSourceFactory factory, ICaptureClock? clock, AppSettings settings, bool microphoneEnabled)
    {
        public ConversationState Conversation { get; } = new();
        public QuestionCoordinator Questions { get; } = new();
        public HashSet<string> Delegations { get; } = [];
        public PendingDelegation? PendingAutomatic { get; set; }
        public DateTimeOffset AutomaticAt { get; set; }
        public Task? AutomaticWorker { get; set; }
        public AppSettings Settings { get; } = settings;
        public Path System { get; } = new(factory, AudioInput.System, Speaker.Them, clock);
        public Path Microphone { get; } = new(factory, AudioInput.Microphone, settings.Mode == OperatingMode.InPerson ? Speaker.Room : Speaker.You, clock);
        public IEnumerable<Path> ActivePaths
        {
            get
            {
                if (Settings.Mode == OperatingMode.Remote) yield return System;
                if (microphoneEnabled) yield return Microphone;
            }
        }
        public CancellationTokenSource StartCancellation { get; } = new();
        public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
        public bool StopRequested { get; set; }
        public bool Disconnecting { get; set; }
        public bool WasListening { get; set; }
        public bool AcceptEvents { get; set; } = true;
    }
}
