using System.Runtime.CompilerServices;

namespace LiveCopilot.Core;

/// Displays only final content; reasoning_content is a progress signal.
public sealed class ChatCompletionsProvider : IReasoningProvider
{
    private readonly string key, model;
    private readonly Uri endpoint;
    private readonly IHttpTransport transport;
    private readonly ReasoningService service;
    private readonly AnalysisThinking thinking;
    private readonly string? deepSeekEffort;

    public ChatCompletionsProvider(string key, string model, Uri endpoint, IHttpTransport transport,
        ReasoningService service = ReasoningService.Compatible, AnalysisThinking thinking = AnalysisThinking.ModelDefault,
        string? deepSeekEffort = null)
    {
        ReasoningHTTP.Validate(key, model);
        this.key = key; this.model = model; this.endpoint = endpoint; this.transport = transport;
        this.service = service; this.thinking = thinking; this.deepSeekEffort = deepSeekEffort;
    }

    public async IAsyncEnumerable<string> Stream(AnswerRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var body = new Dictionary<string, object>
        {
            ["model"] = model, ["stream"] = true, ["max_tokens"] = request.SessionTitleInput is null ? 4096 : 512,
            ["messages"] = new[] { new { role = "system", content = request.Instructions }, new { role = "user", content = request.Input } }
        };
        if (deepSeekEffort is not null)
        {
            var mode = AnalysisModelCatalog.Normalized(deepSeekEffort, model, ReasoningService.DeepSeek);
            if (mode != AnalysisThinking.ModelDefault)
            {
                body["thinking"] = new { type = mode == AnalysisThinking.Disabled ? "disabled" : "enabled" };
                if (mode.Effort() is { } effort) body["reasoning_effort"] = effort;
            }
        }
        var normalized = service.NormalizedThinking(thinking, model);
        if (normalized != AnalysisThinking.ModelDefault)
        {
            switch (service)
            {
                case ReasoningService.Qwen: body["enable_thinking"] = normalized != AnalysisThinking.Disabled; break;
                case ReasoningService.Glm:
                case ReasoningService.Kimi when !model.Trim().Equals("kimi-k3", StringComparison.OrdinalIgnoreCase):
                    body["thinking"] = new { type = normalized == AnalysisThinking.Disabled ? "disabled" : "enabled" }; break;
            }
            if (service.IsPreset() && normalized.Effort() is { } effort) body["reasoning_effort"] = effort;
        }
        using var http = ReasoningHTTP.Request(endpoint, key, body);
        var completed = false; var hadText = false; var reportedService = false; var reportedReasoning = false;
        await foreach (var payload in ReasoningHTTP.Events(transport, http, cancellationToken).ConfigureAwait(false))
        {
            if (payload == "[DONE]") { completed = true; break; }
            using var document = ReasoningHTTP.Parse(payload);
            var obj = document.RootElement;
            if (obj.Property("error").ValueKind != JsonValueKind.Undefined) throw ReasoningHTTP.Failure(obj);
            var choices = obj.Property("choices");
            if (choices.ValueKind != JsonValueKind.Array) throw ReasoningHTTP.Malformed();
            if (!reportedService)
            {
                reportedService = true;
                if (request.OnStreamProgress is { } progress) await progress(PipelineStage.FirstServiceEvent, PipelineTrace.Uptime).ConfigureAwait(false);
            }
            foreach (var choice in choices.EnumerateArray())
            {
                var index = choice.Property("index");
                if (index.ValueKind == JsonValueKind.Number && index.TryGetInt32(out var number) && number != 0) continue;
                var delta = choice.Property("delta");
                if (!reportedReasoning && delta.Property("reasoning_content").Text() is { Length: > 0 })
                {
                    reportedReasoning = true;
                    if (request.OnStreamProgress is { } progress) await progress(PipelineStage.ReasoningStarted, PipelineTrace.Uptime).ConfigureAwait(false);
                }
                if (delta.Property("content").Text() is { Length: > 0 } content) { hadText = true; yield return content; }
                if (choice.Property("finish_reason").Text() is { } reason)
                {
                    if (reason != "stop") throw new CopilotException("The analysis answer was interrupted or exceeded its limit. Partial text is retained; retry.");
                    completed = true;
                }
            }
            if (completed) break;
        }
        if (!completed || !hadText) throw new CopilotException(ReasoningHTTP.IncompleteStream);
    }
}
