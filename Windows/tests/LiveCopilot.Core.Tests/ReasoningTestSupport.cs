using System.Runtime.CompilerServices;

namespace LiveCopilot.Core.Tests;

internal sealed class FakeHttpTransport(params string[] events) : IHttpTransport
{
    public int Calls { get; private set; }
    public Uri? Endpoint { get; private set; }
    public string? Method { get; private set; }
    public string? Scheme { get; private set; }
    public string? Key { get; private set; }
    public string? ContentType { get; private set; }
    public JsonElement Body { get; private set; }
    public Task<(byte[] Data, int Status)> DataAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new NotSupportedException();
    public async IAsyncEnumerable<string> LinesAsync(HttpRequestMessage request, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        Calls++;
        Endpoint = request.RequestUri; Method = request.Method.Method;
        Scheme = request.Headers.Authorization?.Scheme; Key = request.Headers.Authorization?.Parameter;
        ContentType = request.Content?.Headers.ContentType?.MediaType;
        using var document = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
        Body = document.RootElement.Clone();
        foreach (var payload in events)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return "data: " + payload;
            yield return "";
        }
    }
}

internal static class ReasoningFixtures
{
    public const string OpenAIText = """{"type":"response.output_text.delta","delta":"答案"}""";
    public const string OpenAIComplete = """{"type":"response.completed"}""";
    public const string ChatText = """{"choices":[{"index":0,"delta":{"content":"答案"}}]}""";
    public static AnswerRequest Answer() => new(RetrievalQuery.Formulate("怎么做？", "Them: 怎么做？"), "Them: 怎么做？", ScenarioProfile.Interview, []);
    public static async Task<string> Collect(IReasoningProvider provider, AnswerRequest? answer = null, CancellationToken token = default)
    {
        var result = "";
        await foreach (var delta in provider.Stream(answer ?? Answer(), token)) result += delta;
        return result;
    }
}
