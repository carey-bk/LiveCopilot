namespace LiveCopilot.Core;


public static class WireEnum
{
    public static string RawValue<T>(this T value) where T : struct, Enum =>
        typeof(T).GetField(value.ToString())?.GetCustomAttributes(typeof(EnumMemberAttribute), false).Cast<EnumMemberAttribute>().FirstOrDefault()?.Value ?? value.ToString();
    public static T? Parse<T>(string value) where T : struct, Enum => Enum.GetValues<T>().Cast<T?>().FirstOrDefault(x => x!.Value.RawValue() == value);
}
internal sealed class WireEnumConverter : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) => typeToConvert.IsEnum && typeToConvert != typeof(OnboardingStep);
    public override JsonConverter CreateConverter(Type type, JsonSerializerOptions options) => (JsonConverter)Activator.CreateInstance(typeof(Converter<>).MakeGenericType(type))!;
    private sealed class Converter<T> : JsonConverter<T> where T : struct, Enum
    {
        public override T Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            var raw = reader.GetString();
            if (typeof(T) == typeof(ListeningService) && raw == "local") raw = "zipformer";
            return WireEnum.Parse<T>(raw ?? "") ?? throw new JsonException($"Unknown {typeof(T).Name} value.");
        }
        public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) => writer.WriteStringValue(value.RawValue());
    }
}
