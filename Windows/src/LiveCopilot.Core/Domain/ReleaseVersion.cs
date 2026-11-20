namespace LiveCopilot.Core;

public sealed record ReleaseVersion(long Major, long Minor, long Patch, string? Prerelease = null) : IComparable<ReleaseVersion>
{
    public static ReleaseVersion? Parse(string value)
    {
        var text = value.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        var match = Regex.Match(text, @"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:-([0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*))?(?:\+[0-9A-Za-z.-]+)?$");
        if (!match.Success || !long.TryParse(match.Groups[1].Value, out var major) || major >= 10_000 ||
            !long.TryParse(match.Groups[2].Value, out var minor) || !long.TryParse(match.Groups[3].Success ? match.Groups[3].Value : "0", out var patch)) return null;
        return new(major, minor, patch, match.Groups[4].Success ? match.Groups[4].Value : null);
    }
    public override string ToString() => $"{Major}.{Minor}.{Patch}";
    [JsonIgnore] public string Display => "v" + this;
    [JsonIgnore] public bool IsStable => Prerelease is null;
    public int CompareTo(ReleaseVersion? other)
    {
        if (other is null) return 1;
        foreach (var (a, b) in new[] { (Major, other.Major), (Minor, other.Minor), (Patch, other.Patch) }) if (a != b) return a.CompareTo(b);
        if (Prerelease is null) return other.Prerelease is null ? 0 : 1;
        if (other.Prerelease is null) return -1;
        var left = Prerelease.Split('.'); var right = other.Prerelease.Split('.');
        foreach (var (a, b) in left.Zip(right))
        {
            if (a == b) continue;
            var an = long.TryParse(a, out var av); var bn = long.TryParse(b, out var bv);
            if (an && bn) return av.CompareTo(bv);
            if (an) return -1;
            if (bn) return 1;
            return string.CompareOrdinal(a, b);
        }
        return left.Length.CompareTo(right.Length);
    }
    public static bool operator <(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) >= 0;
}
public sealed record UpdateRelease(ReleaseVersion Version, string Notes, bool SupportsInAppInstall)
{
    [JsonIgnore] public string Display => Version.Display;
    public static Uri OfficialPage { get; } = new("https://github.com/carey-bk/LiveCopilot/releases");
    public static string PlainNotes(string? html)
    {
        if (html is null) return "查看本次更新的功能改进与问题修复。";
        var text = Regex.Replace(TextElements.Prefix(html, 32000), @"(?is)<(script|style)\b[^>]*>.*?</\1>", "");
        text = Regex.Replace(text, @"(?i)</(?:p|li|h[1-6])\s*>|<br\s*/?>", "\n");
        text = Regex.Replace(text, @"<[^>]+>", "").Replace("&nbsp;", " ").Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"");
        return TextElements.Prefix(string.Join("\n", text.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0)), 8000);
    }
}
