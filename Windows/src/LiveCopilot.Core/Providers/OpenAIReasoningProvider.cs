using System.Runtime.CompilerServices;

namespace LiveCopilot.Core;

public sealed class OpenAIReasoningProvider : IReasoningProvider
{
    private readonly string key, model, effort;
    private readonly AnalysisProcessing processing;
    private readonly IHttpTransport transport;

    public OpenAIReasoningProvider(string key, string model, IHttpTransport transport,
        string effort = "low", AnalysisProcessing processing = AnalysisProcessing.Standard)
    {
        ReasoningHTTP.Validate(key, model);
        this.key = key; this.model = model; this.transport = transport;
        this.effort = effort; this.processing = processing;
    }

    public async IAsyncEnumerable<string> Stream(AnswerRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var body = new Dictionary<string, object>
        {
            ["model"] = model, ["instructions"] = request.Instructions, ["input"] = request.Input,
            ["stream"] = true, ["store"] = false, ["max_output_tokens"] = request.SessionTitleInput is null ? 2800 : 512,
            ["service_tier"] = processing.WireValue()
        };
        var mode = AnalysisModelCatalog.Normalized(effort, model, ReasoningService.SeparateOpenAI);
        if (mode != AnalysisThinking.ModelDefault) body["reasoning"] = new { effort = mode.ReferenceKey() };
        using var http = ReasoningHTTP.Request(new("https://api.openai.com/v1/responses"), key, body);
        var completed = false; var hadText = false; var reportedService = false; var reportedReasoning = false;
        await foreach (var payload in ReasoningHTTP.Events(transport, http, cancellationToken).ConfigureAwait(false))
        {
            if (payload == "[DONE]") continue;
            using var document = ReasoningHTTP.Parse(payload);
            var obj = document.RootElement;
            var type = obj.Property("type").Text();
            if (type is null && obj.Property("error").ValueKind == JsonValueKind.Undefined) throw ReasoningHTTP.Malformed();
            if (!reportedService)
            {
                reportedService = true;
                if (request.OnStreamProgress is { } progress) await progress(PipelineStage.FirstServiceEvent, PipelineTrace.Uptime).ConfigureAwait(false);
            }
            if (!reportedReasoning && type == "response.output_item.added" && obj.Property("item").Property("type").Text() == "reasoning")
            {
                reportedReasoning = true;
                if (request.OnStreamProgress is { } progress) await progress(PipelineStage.ReasoningStarted, PipelineTrace.Uptime).ConfigureAwait(false);
            }
            if (obj.Property("error").ValueKind != JsonValueKind.Undefined) throw ReasoningHTTP.Failure(obj);
            switch (type)
            {
                case "response.output_text.delta": case "response.refusal.delta":
                    if (obj.Property("delta").Text() is { } delta) { hadText |= delta.Length > 0; yield return delta; }
                    break;
                case "response.completed": completed = true; break;
                case "response.failed": case "error":
                    var failure = obj.Property("response").Property("error");
                    throw ReasoningHTTP.Failure(failure.ValueKind == JsonValueKind.Object ? failure : obj);
                case "response.incomplete":
                    throw new CopilotException("The answer was cut short. Partial text is retained; retry or choose a lower reasoning effort.");
            }
        }
        if (!completed || !hadText) throw new CopilotException(ReasoningHTTP.IncompleteStream);
    }
}
