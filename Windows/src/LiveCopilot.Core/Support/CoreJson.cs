namespace LiveCopilot.Core;


/// Sessions use ISO 8601 seconds; Swift's default Codable Date uses seconds since 2001-01-01.
public static class CoreJson
{
    public static JsonSerializerOptions Default { get; } = Create(false);
    public static JsonSerializerOptions Sessions { get; } = Create(true);
    private static JsonSerializerOptions Create(bool sessions)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = sessions,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        options.Converters.Add(new WireEnumConverter());
        options.Converters.Add(new SwiftDateConverter(sessions));
        options.Converters.Add(new UppercaseGuidConverter());
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }
    public static T Decode<T>(string json, bool session = false) => JsonSerializer.Deserialize<T>(json, session ? Sessions : Default) ?? throw new JsonException("Null root.");
    public static string Encode<T>(T value, bool session = false) => JsonSerializer.Serialize(value, session ? Sessions : Default);
    public static string Iso8601(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    public static string Id(Guid value) => value.ToString("D").ToUpperInvariant();
    private sealed class UppercaseGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => r.GetGuid();
        public override void Write(Utf8JsonWriter w, Guid v, JsonSerializerOptions o) => w.WriteStringValue(Id(v));
    }
    private sealed class SwiftDateConverter(bool iso) : JsonConverter<DateTimeOffset>
    {
        private static readonly DateTimeOffset Epoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
        {
            if (iso)
                return r.TokenType == JsonTokenType.String && r.TryGetDateTimeOffset(out var date)
                    ? date : throw new JsonException("Invalid ISO 8601 session date.");
            try { return Epoch.AddSeconds(r.GetDouble()); }
            catch (ArgumentOutOfRangeException e) { throw new JsonException("Invalid Swift reference date.", e); }
        }
        public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o)
        { if (iso) w.WriteStringValue(Iso8601(v)); else w.WriteNumberValue((v - Epoch).TotalSeconds); }
    }
}
