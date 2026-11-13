namespace LiveCopilot.Core;

/// Uses the shared OpenAI credential. KnowledgeIndex owns batching (24 chunks).
public sealed class OpenAIEmbeddingProvider(string key, string model, IHttpTransport transport) : IEmbeddingProvider
{
    public string Model { get; } = model;
    public const string MissingKeyMessage = "请先配置共享 OpenAI API 密钥，或设置 OPENAI_API_KEY。";
    public const string InvalidResponseMessage = "OpenAI returned missing or incompatible embedding vectors.";

    public static OpenAIEmbeddingProvider FromCredentials(AppSettings settings, ICredentialStore credentials,
        IHttpTransport transport, Func<string, string?>? environment = null)
    {
        var key = credentials.Read(CredentialReference.Live);
        if (string.IsNullOrWhiteSpace(key)) key = (environment ?? Environment.GetEnvironmentVariable)("OPENAI_API_KEY");
        return new(key ?? "", settings.EmbeddingModel, transport);
    }

    public async Task<IReadOnlyList<ValueList<float>>> EmbedAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (texts.Count == 0) return [];
        if (string.IsNullOrWhiteSpace(key)) throw new CopilotException(MissingKeyMessage);
        if (key.Trim().Any(char.IsControl)) throw new CopilotException("OpenAI API 密钥含无效字符，请重新保存。");
        if (string.IsNullOrWhiteSpace(Model)) throw new CopilotException("请填写 OpenAI embedding 模型名称。");
        using var request = ReasoningHTTP.Request(new("https://api.openai.com/v1/embeddings"), key,
            new() { ["model"] = Model, ["input"] = texts, ["encoding_format"] = "float" });
        byte[] data;
        int status;
        try { (data, status) = await transport.DataAsync(request, cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (ServiceHTTPFailure) { throw; }
        // Never retain a transport exception: URLs, headers or response bodies can contain secrets.
        catch (Exception) { throw new CopilotException("无法连接 OpenAI embedding 服务，请检查网络后重试。"); }
        cancellationToken.ThrowIfCancellationRequested();
        if (status is < 200 or >= 300) throw new ServiceHTTPFailure(status, data);
        try
        {
            using var json = JsonDocument.Parse(data);
            var rows = json.RootElement.GetProperty("data");
            if (rows.GetArrayLength() != texts.Count) throw new CopilotException(InvalidResponseMessage);
            var vectors = new ValueList<float>?[texts.Count];
            var dimension = 0;
            foreach (var row in rows.EnumerateArray())
            {
                var index = row.GetProperty("index").GetInt32();
                if (index < 0 || index >= vectors.Length || vectors[index] is not null) throw new CopilotException(InvalidResponseMessage);
                var vector = row.GetProperty("embedding").EnumerateArray().Select(v => v.GetSingle()).ToValueList();
                if (dimension == 0) dimension = vector.Count;
                if (dimension == 0 || vector.Count != dimension || vector.Any(v => !float.IsFinite(v)))
                    throw new CopilotException(InvalidResponseMessage);
                vectors[index] = vector;
            }
            return vectors.Select(v => v ?? throw new CopilotException(InvalidResponseMessage)).ToArray();
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        { throw new CopilotException("OpenAI returned malformed embeddings."); }
    }
}
