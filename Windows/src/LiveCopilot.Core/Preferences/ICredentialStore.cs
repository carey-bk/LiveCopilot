namespace LiveCopilot.Core;

public interface ICredentialStore
{
    string? Read(CredentialReference reference);
    void Save(CredentialReference reference, string key);
    void Clear(CredentialReference reference);
}

/// Linux-safe, process-local storage. Hosts choose persistence explicitly.
public sealed class MemoryCredentialStore : ICredentialStore
{
    private readonly object sync = new();
    private readonly Dictionary<CredentialReference, string> keys = [];
    public string? Read(CredentialReference reference) { lock (sync) return keys.GetValueOrDefault(reference); }
    public void Save(CredentialReference reference, string key)
    {
        lock (sync)
        {
            if (string.IsNullOrWhiteSpace(key)) keys.Remove(reference);
            else keys[reference] = key.Trim();
        }
    }
    public void Clear(CredentialReference reference) { lock (sync) keys.Remove(reference); }
}
