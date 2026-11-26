using System.Net.Sockets;

namespace LiveCopilot.Core;

/// Wire contract copied from the Mac LiveProtocol, not the Realtime API.
public static class OpenAILiveProtocol
{
    public static Uri Endpoint { get; } = new("wss://api.openai.com/v1/live/sessions");
    public const string StartupTimeoutMessage = "Live startup timed out. Check network and model access.";
    public const string ConnectionFailureMessage = "Live connection failed. Check your network.";
    public const string UploadTooSlowMessage = "Live upload is too slow. Reconnecting; buffered audio was discarded.";

    public static string AssistanceSummary(string answer) =>
        "Assistance completed in the text overlay for the question. Brief result: " + TextElements.Prefix(answer, 900);

    public static string TransportFailure(Exception error)
    {
        for (Exception? cause = error; cause is not null; cause = cause.InnerException)
        {
            if (cause is SocketException { SocketErrorCode: SocketError.TimedOut }) return StartupTimeoutMessage;
            if (cause is SocketException { SocketErrorCode: SocketError.NetworkDown or SocketError.NetworkUnreachable or SocketError.HostUnreachable })
                return "No internet connection. Reconnect and try the speech service again.";
        }
        return ConnectionFailureMessage;
    }

    public static byte[] Start(string model, Speaker speaker, ScenarioProfile scenario, LiveSpeechLanguage language, string context)
    {
        var role = speaker == Speaker.You
            ? "This input is the copilot user's own microphone (You). Listen and transcribe; do not delegate requests for assistance."
            : speaker == Speaker.Room
                ? "This input is a shared room microphone. Speaker identity is uncertain. Detect substantive questions directed to the presenter."
                : "This input is remote participants (Them). Detect substantive questions directed to the copilot user.";
        var preference = language switch
        {
            LiveSpeechLanguage.Chinese => "Expect primarily Mandarin Chinese. Write spoken Mandarin in Simplified Chinese. Preserve English names and technical terms only when actually spoken. Do not translate or invent words to fit this preference.",
            LiveSpeechLanguage.English => "Expect primarily English, including accented English. Write spoken English in English. Preserve Mandarin only when it is clearly spoken. Do not translate or invent words to fit this preference.",
            LiveSpeechLanguage.Mixed => "Expect Mandarin Chinese and English, possibly alternating within one sentence. Write each spoken span in its original language: Simplified Chinese for Mandarin and English for English. Keep actually spoken English names and technical terms. Do not translate.",
            _ => null
        };
        var languageGuidance = preference is null ? "" : "Transcribe the words actually spoken, in their original language and script. " + preference +
            "\nDo not use Korean or Japanese script for Mandarin or English speech unless those languages are clearly spoken.";
        var instructions = $"""
            You are the conversation understanding layer of a private text copilot. {role}
            {scenario.Instructions()}
            {languageGuidance}
            Stay silent; the application has no voice output. Listen continuously, including interruptions and corrections.
            Delegate to the client only when a meaningful question or request is sufficiently complete. Do not delegate on
            each pause, fragments, rhetorical questions, backchannels, or a question already answered by You.
            Recognize follow-ups and delegate a new follow-up once. The client retrieves documents and generates the
            answer in a separate text overlay while you keep listening. Wait for completion and don't repeat delegations.
            """;
        var session = new Dictionary<string, object>
        {
            ["model"] = model, ["instructions"] = instructions,
            ["audio"] = new { format = new { type = "audio/pcm", rate = 24000 }, output = new { voice = "marin" } },
            ["delegation"] = new { type = "client" }, ["store"] = false
        };
        if (context.Length > 0) session["input"] = new[] { new { type = "message", role = "user",
            content = new[] { new { type = "input_text", text = "Prior conversation (reference only):\n" + TextElements.Suffix(context, 6000) } } } };
        return JsonSerializer.SerializeToUtf8Bytes(new { type = "session.start", event_id = Guid.NewGuid().ToString(), session });
    }

    public static string ContextExcerpt(string text)
    {
        var result = new StringBuilder();
        var bytes = 0;
        foreach (var element in TextElements.Split(text))
        {
            bytes += Encoding.UTF8.GetByteCount(element);
            if (bytes > 450) break;
            result.Append(element);
        }
        return result.ToString();
    }

    public static LiveEvent? Parse(ReadOnlyMemory<byte> data, Speaker speaker)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            var obj = document.RootElement;
            switch (String(obj, "type"))
            {
                case "session.started": return new LiveEvent.Ready();
                case "session.input_transcript.delta":
                case "session.input_transcript.completed":
                    // Mac emits transcript revisions on delta; accept completed revisions too.
                    var text = String(obj, "delta") ?? String(obj, "transcript") ?? String(obj, "text");
                    if (text is null || String(obj, "event_id") is not { } id ||
                        !Integer(obj, "start_ms", out var start) || !Integer(obj, "end_ms", out var end)) return null;
                    return new LiveEvent.Transcript(new(id, speaker, text, start, end, DateTimeOffset.UtcNow));
                case "session.delegation.created":
                    if (!obj.TryGetProperty("delegation", out var delegation) || String(delegation, "target") != "client" ||
                        String(delegation, "id") is not { } delegationId) return null;
                    Integer(obj, "offset_ms", out var offset);
                    return new LiveEvent.Delegation(delegationId, offset);
                case "session.closed": return new LiveEvent.Closed(true);
                case "error": return new LiveEvent.Failed(new ServiceHTTPFailure(0, data.ToArray()).Message);
                default: return null; // Includes all output audio: never played.
            }
        }
        catch (JsonException) { return null; }
    }
    private static string? String(JsonElement obj, string name) => obj.ValueKind == JsonValueKind.Object &&
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static bool Integer(JsonElement obj, string name, out int number)
    {
        number = 0;
        return obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) &&
            value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out number);
    }
}
