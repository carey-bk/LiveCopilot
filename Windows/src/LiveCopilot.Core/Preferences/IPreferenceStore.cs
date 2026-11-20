namespace LiveCopilot.Core;

/// Stores opaque JSON bytes under the original UserDefaults keys, never credentials.
public interface IPreferenceStore
{
    bool Contains(string key);
    byte[]? Get(string key);
    void Set(string key, byte[] value);
}

public sealed class MemoryPreferenceStore : IPreferenceStore
{
    private readonly Dictionary<string, byte[]> values = [];
    public bool Contains(string key) => values.ContainsKey(key);
    public byte[]? Get(string key) => values.TryGetValue(key, out var value) ? value.ToArray() : null;
    public void Set(string key, byte[] value) => values[key] = value.ToArray();
}

/// Construction and reads do not create directories. Each key is committed atomically.
public sealed class FilePreferenceStore(string? root = null) : IPreferenceStore
{
    private readonly string root = root ?? Path.Combine(AppPaths.DataDirectory, "preferences");
    private string FileFor(string key) => Path.Combine(root, Convert.ToHexString(Encoding.UTF8.GetBytes(key)) + ".json");
    public bool Contains(string key) => File.Exists(FileFor(key));
    public byte[]? Get(string key) => Contains(key) ? File.ReadAllBytes(FileFor(key)) : null;
    public void Set(string key, byte[] value) => AtomicFile.Write(FileFor(key), value);
}
