using LiveCopilot.Core;

namespace LiveCopilot.Platform.Knowledge;

public static class DocumentImport
{
    public const string InvalidFileMessage = "请选择本地 PDF、Markdown、TXT 或 DOCX 常规文件；不支持文件夹、链接或网络文件。";
    public static IReadOnlyList<string> Validate(IEnumerable<string> paths)
    {
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var input in paths)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(input) || input.StartsWith("\\\\", StringComparison.Ordinal) || input.StartsWith("//", StringComparison.Ordinal))
                    throw new CopilotException(InvalidFileMessage);
                var path = input;
                if (Uri.TryCreate(input, UriKind.Absolute, out var uri))
                {
                    if (!uri.IsFile || uri.IsUnc || !string.IsNullOrEmpty(uri.Host)) throw new CopilotException(InvalidFileMessage);
                    path = uri.LocalPath;
                }
                path = Path.GetFullPath(path);
                var file = new FileInfo(path);
                if (!DocumentParser.Supports(file.Extension) || !file.Exists ||
                    (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0 ||
                    (OperatingSystem.IsWindows() && new DriveInfo(Path.GetPathRoot(path)!).DriveType == DriveType.Network))
                    throw new CopilotException(InvalidFileMessage);
                if (seen.Add(path)) result.Add(path);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            { throw new CopilotException(InvalidFileMessage); }
        }
        return result;
    }
}
