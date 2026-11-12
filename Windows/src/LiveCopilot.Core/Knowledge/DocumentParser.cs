namespace LiveCopilot.Core;

public sealed record DocumentSection(string Text, int? Page = null);
public interface IDocumentParser
{
    IReadOnlyList<DocumentSection> Extract(string path);
}

/// PDF/DOCX adapters are supplied by the host; text parsing has no native dependencies.
public sealed class TextDocumentParser : IDocumentParser
{
    public IReadOnlyList<DocumentSection> Extract(string path)
    {
        var file = new FileInfo(path);
        if (!file.Exists || (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || file.Length > 50_000_000)
            throw new CopilotException("Choose a regular document smaller than 50 MB.");
        if (file.Extension.ToLowerInvariant() is not ".md" and not ".markdown" and not ".txt")
            throw new CopilotException("This document requires an IDocumentParser adapter. Built-in parsing supports Markdown and TXT.");
        var data = File.ReadAllBytes(path);
        string text;
        try
        {
            if (data.AsSpan().StartsWith(new byte[] { 0xff, 0xfe })) text = new UnicodeEncoding(false, true, true).GetString(data, 2, data.Length - 2);
            else if (data.AsSpan().StartsWith(new byte[] { 0xfe, 0xff })) text = new UnicodeEncoding(true, true, true).GetString(data, 2, data.Length - 2);
            else
            {
                try { text = new UTF8Encoding(false, true).GetString(data).TrimStart('\ufeff'); }
                catch (DecoderFallbackException) { text = new UnicodeEncoding(true, false, true).GetString(data); }
            }
        }
        catch (DecoderFallbackException) { throw new CopilotException("Save this text document as UTF-8 or UTF-16 and retry."); }
        if (string.IsNullOrWhiteSpace(text)) throw new CopilotException("No extractable text. Scanned PDFs need OCR before import.");
        return [new(text)];
    }
}

public static class DocumentChunker
{
    public static ValueList<SourceChunk> Chunk(IReadOnlyList<DocumentSection> sections, string documentId, string name, int maxCharacters = 1600, int overlap = 180)
    {
        var size = Math.Max(128, maxCharacters); overlap = Math.Clamp(overlap, 0, size / 3);
        var result = new List<SourceChunk>();
        foreach (var section in sections)
        {
            var chars = TextElements.Split(section.Text.Replace("\r\n", "\n", StringComparison.Ordinal));
            var start = 0;
            while (start < chars.Length)
            {
                var end = Math.Min(start + size, chars.Length);
                if (end < chars.Length)
                    for (var i = end - 1; i >= start + size / 2; i--)
                        if ("\n。.!?！？ ".Contains(chars[i], StringComparison.Ordinal)) { end = i + 1; break; }
                var text = string.Concat(chars[start..end]).Trim();
                if (text.Length > 0) result.Add(new(CoreJson.Id(Guid.NewGuid()), documentId, name, result.Count, section.Page, text, [], ""));
                if (end == chars.Length) break;
                start = Math.Max(start + 1, end - overlap);
            }
        }
        return result.ToValueList();
    }
}

public static class LexicalTokenizer
{
    public static ValueList<string> Terms(string text)
    {
        var tokens = TextElements.Words(text).ToList();
        var run = new List<string>();
        void Flush()
        {
            if (run.Count == 1) tokens.Add(run[0]);
            for (var i = 0; i < run.Count - 1; i++) tokens.Add(run[i] + run[i + 1]);
            run.Clear();
        }
        foreach (var ch in TextElements.Split(text))
            if (ch.EnumerateRunes().Any(r => r.Value is >= 0x3400 and <= 0x9fff)) run.Add(ch); else Flush();
        Flush(); return tokens.ToValueList();
    }
    public static string IndexedText(string text) => string.Join(" ", Terms(text));
    private static readonly HashSet<string> Stop = ["the", "and", "what", "how", "you", "your", "them", "this", "that", "with", "about", "is", "a", "to", "of", "in", "it", "its", "are", "was", "were", "can", "could", "would", "please", "explain", "tell", "me", "do", "does", "why", "we", "did", "请问", "什么", "怎么", "如何", "为什么", "一下", "这个", "那个", "我们", "你们", "的是", "是否"];
    public static ValueList<string> RetrievalTerms(string text) => Terms(text).Where(t => !Stop.Contains(t) && TextElements.Count(t) >= 2).ToValueList();
    public static string MatchQuery(string text) => string.Join(" OR ", RetrievalTerms(text).Distinct().Take(70).Select(t => "\"" + t.Replace("\"", "\"\"") + "\""));
}

public static class VectorMath
{
    public static double Cosine(IReadOnlyList<float> a, IReadOnlyList<float> b)
    {
        if (a.Count != b.Count || a.Count == 0) return 0;
        double dot = 0, aa = 0, bb = 0;
        for (var i = 0; i < a.Count; i++)
        {
            var x = a[i]; var y = b[i]; if (!float.IsFinite(x) || !float.IsFinite(y)) return 0;
            dot += (double)x * y; aa += (double)x * x; bb += (double)y * y;
        }
        return aa > 0 && bb > 0 ? dot / Math.Sqrt(aa * bb) : 0;
    }
    public static ValueList<RetrievedSource> Fuse(IReadOnlyList<SourceChunk> lexical, IReadOnlyList<SourceChunk> semantic, int limit)
    {
        var scores = new Dictionary<string, double>(); var chunks = new Dictionary<string, SourceChunk>();
        foreach (var ranked in new[] { lexical, semantic })
            for (var i = 0; i < ranked.Count; i++) { var c = ranked[i]; scores[c.Id] = scores.GetValueOrDefault(c.Id) + 1.0 / (60 + i + 1); chunks[c.Id] = c; }
        return scores.Select(p => new RetrievedSource(chunks[p.Key], p.Value)).OrderByDescending(s => s.Score).ThenBy(s => s.Id, StringComparer.Ordinal).Take(Math.Clamp(limit, 1, 12)).ToValueList();
    }
}
