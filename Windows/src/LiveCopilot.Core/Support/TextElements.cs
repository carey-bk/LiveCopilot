namespace LiveCopilot.Core;


/// Swift String limits count extended grapheme clusters, not UTF-16 code units.
internal static class TextElements
{
    public static string[] Split(string value)
    {
        var result = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(value);
        while (e.MoveNext()) result.Add(e.GetTextElement());
        return result.ToArray();
    }
    public static int Count(string value) => new StringInfo(value).LengthInTextElements;
    public static string Prefix(string value, int count) => string.Concat(Split(value).Take(Math.Max(0, count)));
    public static string Suffix(string value, int count) => string.Concat(Split(value).TakeLast(Math.Max(0, count)));
    public static string NormalizeWhitespace(string value) => Regex.Replace(value.Trim(), @"\s+", " ");
    public static string AlphanumericKey(string value) => string.Concat(value.ToLowerInvariant().EnumerateRunes().Where(Rune.IsLetterOrDigit));
    public static string[] Words(string value) => Regex.Split(value.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(x => x.Length > 0).ToArray();
    public static string TrimPunctuation(string value) => Regex.Replace(value, @"^\p{P}+|\p{P}+$", "");
}
