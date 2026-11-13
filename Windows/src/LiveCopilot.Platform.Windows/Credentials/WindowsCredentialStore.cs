using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using LiveCopilot.Core;

namespace LiveCopilot.Platform.Windows.Credentials;

/// Generic credentials persist for the current Windows user. No plaintext file fallback.
public sealed class WindowsCredentialStore : ICredentialStore
{
    private const uint Generic = 1, LocalMachine = 2;
    private const int NotFound = 1168, MaximumBlobBytes = 2560;
    private static string Account(CredentialReference reference) => reference.Service + "|" + reference.Account;
    private static string Target(CredentialReference reference) => "LiveCopilot-Credentials-v1/" + Account(reference);

    public string? Read(CredentialReference reference)
    {
        if (!CredRead(Target(reference), Generic, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == NotFound) return null;
            throw Failure("read", error);
        }
        try
        {
            var value = Marshal.PtrToStructure<Credential>(pointer);
            if (value.BlobSize > MaximumBlobBytes || value.BlobSize % 2 != 0)
                throw new CopilotException("Windows Credential Manager returned an invalid credential.");
            var key = Marshal.PtrToStringUni(value.Blob, (int)value.BlobSize / 2);
            return string.IsNullOrWhiteSpace(key) ? null : key;
        }
        finally { CredFree(pointer); }
    }

    public void Save(CredentialReference reference, string key)
    {
        if (string.IsNullOrWhiteSpace(key)) { Clear(reference); return; }
        var bytes = Encoding.Unicode.GetBytes(key.Trim());
        nint blob = 0;
        try
        {
            if (bytes.Length > MaximumBlobBytes) throw new CopilotException("The API key exceeds Windows Credential Manager's size limit.");
            blob = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = Generic, TargetName = Target(reference), UserName = Account(reference),
                BlobSize = (uint)bytes.Length, Blob = blob, Persist = LocalMachine
            };
            if (!CredWrite(ref credential, 0)) throw Failure("save", Marshal.GetLastWin32Error());
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            if (blob != 0) { Marshal.Copy(bytes, 0, blob, bytes.Length); Marshal.FreeHGlobal(blob); }
        }
    }

    public void Clear(CredentialReference reference)
    {
        if (CredDelete(Target(reference), Generic, 0)) return;
        var error = Marshal.GetLastWin32Error();
        if (error != NotFound) throw Failure("clear", error);
    }

    private static CopilotException Failure(string operation, int error) =>
        new($"Could not {operation} the API key in Windows Credential Manager (Win32 {error}).");

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags, Type;
        public string? TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint BlobSize;
        public nint Blob;
        public uint Persist, AttributeCount;
        public nint Attributes;
        public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, uint type, uint flags, out nint credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(nint credential);
}
