using System.IO;
using System.IO.Compression;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using LiveCopilot.Platform.Knowledge;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Fonts.Standard14Fonts;
using UglyToad.PdfPig.Writer;

namespace LiveCopilot.Platform.Tests;

public sealed class DocumentParsingTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "livecopilot-documents-" + Guid.NewGuid());
    private readonly DocumentParser parser = new();
    public DocumentParsingTests() => Directory.CreateDirectory(root);
    private string FilePath(string name) => Path.Combine(root, name);
    public void Dispose() => Directory.Delete(root, true);

    [Theory]
    [InlineData("txt", "utf8")] [InlineData("md", "utf8")] [InlineData("markdown", "utf8bom")]
    [InlineData("TXT", "utf16le")] [InlineData("txt", "utf16be")]
    public void TextPreservesChineseAndUnicode(string extension, string encoding)
    {
        const string text = "# 中文知识库\n样本量128，延迟42毫秒。🧪\nEnglish text";
        var codec = encoding switch { "utf16le" => Encoding.Unicode, "utf16be" => Encoding.BigEndianUnicode,
            "utf8bom" => new UTF8Encoding(true), _ => new UTF8Encoding(false) };
        var path = FilePath("文档." + extension);
        File.WriteAllText(path, text, codec);
        var section = Assert.Single(parser.Extract(path));
        Assert.Equal(text, section.Text); Assert.Null(section.Page);
    }

    [Fact] public void PdfExtractsEachPageAndChunkerRetainsItsNumber()
    {
        var path = FilePath("study.pdf");
        using var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.Helvetica);
        builder.AddPage(400, 400).AddText("Page one evidence", 12, new PdfPoint(20, 350), font);
        builder.AddPage(400, 400); // Blank pages must not shift later page numbers.
        builder.AddPage(400, 400).AddText("Latency is 42 ms", 12, new PdfPoint(20, 350), font);
        File.WriteAllBytes(path, builder.Build());
        var sections = parser.Extract(path);
        Assert.Equal(new int?[] { 1, 2, 3 }, sections.Select(s => s.Page));
        Assert.Contains("Page one evidence", sections[0].Text); Assert.Contains("Latency is 42 ms", sections[2].Text);
        var chunks = DocumentChunker.Chunk(sections, "doc", "study.pdf");
        Assert.Equal(new int?[] { 1, 3 }, chunks.Select(c => c.Page));
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public void DocxExtractsChineseParagraphsTablesAndBreaks(bool strict)
    {
        var ns = strict ? "http://purl.oclc.org/ooxml/wordprocessingml/main" : "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        var path = WriteDocx($"""
            <w:document xmlns:w="{ns}"><w:body>
            <w:p><w:r><w:t>中文知识库</w:t><w:tab/><w:t>English</w:t><w:br/><w:t>第二行</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>样本量128</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            </w:body></w:document>
            """);
        var section = Assert.Single(parser.Extract(path));
        Assert.Equal("中文知识库\tEnglish\n第二行\n样本量128", section.Text); Assert.Null(section.Page);
    }

    [Fact] public void PdfUsesToUnicodeMapForChineseWithoutInstalledFonts()
    {
        using var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.Helvetica);
        builder.AddPage(400, 400).AddText("abcd", 12, new PdfPoint(20, 350), font);
        var bytes = builder.Build();
        // Add a standard ToUnicode CMap in an incremental update. No system font or binary fixture needed.
        var original = Encoding.Latin1.GetString(bytes);
        var size = int.Parse(Regex.Match(original, @"/Size\s+(\d+)").Groups[1].Value, CultureInfo.InvariantCulture);
        var rootRef = Regex.Match(original, @"/Root\s+(\d+\s+0\s+R)").Groups[1].Value;
        var previous = Regex.Match(original, @"startxref\s+(\d+)").Groups[1].Value;
        var fontObject = Regex.Matches(original, @"(?s)(\d+)\s+0\s+obj\b(.*?)\bendobj\b")
            .Single(m => m.Groups[2].Value.Contains("/BaseFont", StringComparison.Ordinal));
        var fontNumber = int.Parse(fontObject.Groups[1].Value, CultureInfo.InvariantCulture);
        const string cmap = """
            /CIDInit /ProcSet findresource begin
            12 dict begin begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /FixtureUnicode def /CMapType 2 def
            1 begincodespacerange <00> <FF> endcodespacerange
            4 beginbfchar <61> <4E2D> <62> <6587> <63> <77E5> <64> <8BC6> endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """;
        using var stream = new MemoryStream(); stream.Write(bytes);
        void Write(string text) => stream.Write(Encoding.ASCII.GetBytes(text));
        Write("\n"); var fontOffset = stream.Position;
        Write($"{fontNumber} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /FixtureFont /Encoding /WinAnsiEncoding /FirstChar 97 /LastChar 100 /Widths [500 500 500 500] /FontDescriptor << /Type /FontDescriptor /FontName /FixtureFont /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >> /ToUnicode {size} 0 R >>\nendobj\n");
        var mapOffset = stream.Position;
        Write($"{size} 0 obj\n<< /Length {Encoding.ASCII.GetByteCount(cmap)} >>\nstream\n{cmap}\nendstream\nendobj\n");
        var xref = stream.Position;
        Write($"xref\n{fontNumber} 1\n{fontOffset.ToString("D10", CultureInfo.InvariantCulture)} 00000 n \n{size} 1\n{mapOffset.ToString("D10", CultureInfo.InvariantCulture)} 00000 n \n");
        Write($"trailer\n<< /Size {size + 1} /Root {rootRef} /Prev {previous} >>\nstartxref\n{xref}\n%%EOF\n");
        var path = FilePath("中文.pdf"); File.WriteAllBytes(path, stream.ToArray());
        var section = Assert.Single(parser.Extract(path)); Assert.Equal("中文知识", section.Text); Assert.Equal(1, section.Page);
    }

    [Theory] [InlineData("txt")] [InlineData("md")] [InlineData("docx")] [InlineData("pdf")]
    public void RejectsDocumentsWithoutExtractableText(string extension)
    {
        var path = FilePath("empty." + extension);
        if (extension == "pdf")
        {
            using var builder = new PdfDocumentBuilder(); builder.AddPage(400, 400);
            File.WriteAllBytes(path, builder.Build());
        }
        else if (extension == "docx") path = WriteDocx("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body/></w:document>");
        else File.WriteAllText(path, " \r\n\t");
        Assert.Equal(DocumentParser.EmptyMessage, Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
    }

    [Theory] [InlineData("pdf")] [InlineData("docx")] [InlineData("txt")] [InlineData("md")]
    public void RejectsOverFiftyMegabytesBeforeParsing(string extension)
    {
        var path = FilePath("large." + extension);
        using (var stream = File.Create(path)) stream.SetLength(DocumentParser.MaximumBytes + 1);
        Assert.Contains("50 MB", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
    }

    [Fact] public void RejectsPasswordProtectedPdfWithSafeChineseError()
    {
        var path = FilePath("encrypted.pdf");
        File.WriteAllBytes(path, EncryptedPdfFixture.Create());
        // Prove the generated fixture is readable with its password, not merely corrupt.
        using (var pdf = PdfDocument.Open(path, new ParsingOptions { Password = "fixture-password" }))
        { Assert.True(pdf.IsEncrypted); Assert.Contains("secret evidence", pdf.GetPage(1).Text); }
        Assert.Contains("已加密", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
    }

    [Theory] [InlineData("pdf")] [InlineData("docx")]
    public void UnreadableContainersHaveSafeChineseErrors(string extension)
    {
        var path = FilePath("broken." + extension); File.WriteAllText(path, "sensitive-placeholder");
        var error = Assert.Throws<CopilotException>(() => parser.Extract(path));
        Assert.Contains("无法读取", error.Message); Assert.DoesNotContain("sensitive-placeholder", error.ToString()); Assert.Null(error.InnerException);
    }

    [Fact] public void InvalidTextEncodingIsRejected()
    {
        var path = FilePath("invalid.txt"); File.WriteAllBytes(path, [0xff, 0xfe, 0x01]);
        Assert.Contains("UTF-16", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
        File.WriteAllBytes(path, [0xff, 0xff, 0xff]);
        Assert.Contains("UTF-8", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
    }

    [Theory] [InlineData("<broken>")] [InlineData("<!DOCTYPE x [<!ENTITY leak SYSTEM 'file:///not-read'>]><x>&leak;</x>")]
    public void DocxRejectsMalformedXmlAndExternalEntities(string xml)
    {
        Assert.Contains("DOCX", Assert.Throws<CopilotException>(() => parser.Extract(WriteDocx(xml))).Message);
    }

    [Fact] public void DocxRequiresMainDocumentAndBoundsDecompressedXml()
    {
        var path = FilePath("missing.docx");
        using (var zip = ZipFile.Open(path, ZipArchiveMode.Create)) zip.CreateEntry("not-document.xml");
        Assert.Contains("DOCX", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
        path = FilePath("compressed.docx");
        using (var zip = ZipFile.Open(path, ZipArchiveMode.Create))
        using (var entry = zip.CreateEntry("word/document.xml", CompressionLevel.Optimal).Open())
        {
            var spaces = Enumerable.Repeat((byte)' ', 100_000).ToArray();
            for (var i = 0; i <= 500; i++) entry.Write(spaces);
        }
        Assert.True(new FileInfo(path).Length < DocumentParser.MaximumBytes);
        Assert.Contains("50 MB", Assert.Throws<CopilotException>(() => parser.Extract(path)).Message);
    }

    [Fact] public void ValidatePreservesOrderAndDeduplicatesCanonicalLocalPathsAndUris()
    {
        var a = FilePath("中文.MD"); var b = FilePath("b.txt"); File.WriteAllText(a, "a"); File.WriteAllText(b, "b");
        Assert.Equal(new[] { b, a }, DocumentImport.Validate([b, a, Path.Combine(root, ".", "b.txt"), new Uri(a).AbsoluteUri]));
        Assert.Empty(DocumentImport.Validate([]));
    }

    [Theory]
    [InlineData("")] [InlineData("https://example.invalid/a.pdf")] [InlineData("file://server/share/a.txt")]
    [InlineData("\\\\server\\share\\a.txt")] [InlineData("//server/share/a.txt")]
    [InlineData("missing.txt")] [InlineData("folder.pdf")] [InlineData("unsupported.csv")]
    public void ValidateRejectsNonlocalMissingDirectoryAndUnsupportedInputs(string input)
    {
        Directory.CreateDirectory(FilePath("folder.pdf")); File.WriteAllText(FilePath("unsupported.csv"), "data");
        var path = input is "missing.txt" or "folder.pdf" or "unsupported.csv" ? FilePath(input) : input;
        Assert.Equal(DocumentImport.InvalidFileMessage, Assert.Throws<CopilotException>(() => DocumentImport.Validate([path])).Message);
    }

    [Fact] public void ValidateRejectsSymbolicLinksOnUnix()
    {
        if (OperatingSystem.IsWindows()) return; // Creating Windows symlinks needs optional developer privileges.
        var target = FilePath("target.txt"); File.WriteAllText(target, "text");
        var link = FilePath("link.txt"); File.CreateSymbolicLink(link, target);
        Assert.Throws<CopilotException>(() => DocumentImport.Validate([link]));
    }

    private string WriteDocx(string xml)
    {
        var path = FilePath(Guid.NewGuid() + ".docx");
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        using var writer = new StreamWriter(zip.CreateEntry("word/document.xml").Open(), new UTF8Encoding(false));
        writer.Write(xml); return path;
    }
}
