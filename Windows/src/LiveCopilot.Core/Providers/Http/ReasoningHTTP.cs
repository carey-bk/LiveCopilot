using System.Net.Http.Headers;
using System.Runtime.CompilerServices;

namespace LiveCopilot.Core;

internal static class ReasoningHTTP
{
    public const string IncompleteStream = "Reasoning stream ended without a complete answer. Check the network and retry.";
    public static CopilotException Malformed() => new("Malformed reasoning stream. Retry this question.");
    public static void Validate(string? key, string model)
    {
        if (string.IsNullOrWhiteSpace(key)) throw new CopilotException(ReasoningProviderFactory.MissingKeyMessage);
        if (key.Trim().Any(char.IsControl)) throw new CopilotException("The analysis API key contains invalid characters. Save a valid key in Services.");
        if (string.IsNullOrWhiteSpace(model)) throw new CopilotException("Enter an analysis model name in Services.");
    }
    public static HttpRequestMessage Request(Uri endpoint, string key, Dictionary<string, object> body)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key.Trim());
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        return request;
    }
    public static JsonDocument Parse(string payload)
    {
        try
        {
            var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind == JsonValueKind.Object) return document;
            document.Dispose();
        }
        catch (JsonException) { }
        throw Malformed();
    }
    public static JsonElement Property(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) ? value : default;
    public static string? Text(this JsonElement element) => element.ValueKind == JsonValueKind.String ? element.GetString() : null;
    public static ServiceHTTPFailure Failure(JsonElement error) => new(0, Encoding.UTF8.GetBytes(error.GetRawText()));
    public static async IAsyncEnumerable<string> Events(IHttpTransport transport, HttpRequestMessage request,
        [EnumeratorCancellation] CancellationToken token)
    {
        var parser = new ServerSentEvents();
        await foreach (var line in transport.LinesAsync(request, token).WithCancellation(token).ConfigureAwait(false))
        {
            token.ThrowIfCancellationRequested();
            if (parser.Consume(line) is { } payload) yield return payload;
        }
        token.ThrowIfCancellationRequested();
        if (parser.Finish() is { } last) yield return last;
    }
}
