using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using LiveCopilot.Core;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace LiveCopilot.Platform.Knowledge;

/// Pure managed parsing; no Office, OCR engine or platform UI is required.
public sealed class DocumentParser : IDocumentParser
{
    public const long MaximumBytes = 50_000_000;
    public const string EmptyMessage = "文档没有可提取的文本；扫描版 PDF 需先 OCR 后再导入。";
    public static bool Supports(string extension) => extension.ToLowerInvariant() is ".pdf" or ".md" or ".markdown" or ".txt" or ".docx";

    public IReadOnlyList<DocumentSection> Extract(string path)
    {
        path = DocumentImport.Validate([path])[0];
        try
        {
            if (new FileInfo(path).Length > MaximumBytes) throw new CopilotException("请选择不超过 50 MB 的本地常规文档。");
            var sections = Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".pdf" => Pdf(path),
                ".docx" => Docx(path),
                _ => Text(path)
            };
            if (!sections.Any(s => !string.IsNullOrWhiteSpace(s.Text))) throw new CopilotException(EmptyMessage);
            return sections;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new CopilotException("无法读取文档，请检查文件和访问权限后重试。"); }
    }

    private static IReadOnlyList<DocumentSection> Pdf(string path)
    {
        try
        {
            using var pdf = PdfDocument.Open(path);
            if (pdf.IsEncrypted) throw new CopilotException("PDF 无法读取或已加密，请先解密后重试。");
            return pdf.GetPages().Select(p => new DocumentSection(ContentOrderTextExtractor.GetText(p), p.Number)).ToArray();
        }
        catch (Exception) { throw new CopilotException("PDF 无法读取或已加密，请先解密后重试。"); }
    }

    private static IReadOnlyList<DocumentSection> Docx(string path)
    {
        try
        {
            using var zip = ZipFile.OpenRead(path);
            var entry = zip.GetEntry("word/document.xml") ?? throw new InvalidDataException();
            // Bound decompressed XML as well as the container; prohibit entities and external access.
            if (entry.Length > MaximumBytes) throw new CopilotException("DOCX 解压后的正文超过 50 MB，请拆分文档。");
            using var stream = entry.Open();
            using var reader = XmlReader.Create(stream, new() { DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null, MaxCharactersInDocument = MaximumBytes });
            var xml = XDocument.Load(reader);
            XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
            XNamespace strict = "http://purl.oclc.org/ooxml/wordprocessingml/main";
            bool Word(XElement e, string name) => (e.Name.Namespace == w || e.Name.Namespace == strict) && e.Name.LocalName == name;
            var paragraphs = xml.Descendants().Where(e => Word(e, "p")).Select(p =>
                string.Concat(p.Descendants().Select(e => Word(e, "t") ? e.Value : Word(e, "tab") ? "\t" : Word(e, "br") || Word(e, "cr") ? "\n" : "")));
            return [new(string.Join("\n", paragraphs))];
        }
        catch (CopilotException) { throw; }
        catch (Exception) { throw new CopilotException("DOCX 无法读取、已加密或正文损坏，请另存为 DOCX 后重试。"); }
    }

    private static IReadOnlyList<DocumentSection> Text(string path)
    {
        var data = File.ReadAllBytes(path);
        try
        {
            var text = data.AsSpan().StartsWith(new byte[] { 0xff, 0xfe }) ? new UnicodeEncoding(false, true, true).GetString(data, 2, data.Length - 2)
                : data.AsSpan().StartsWith(new byte[] { 0xfe, 0xff }) ? new UnicodeEncoding(true, true, true).GetString(data, 2, data.Length - 2)
                : new UTF8Encoding(false, true).GetString(data).TrimStart('\ufeff');
            return [new(text)];
        }
        catch (DecoderFallbackException) { throw new CopilotException("请将文本另存为 UTF-8 或带 BOM 的 UTF-16 后重试。"); }
    }
}
