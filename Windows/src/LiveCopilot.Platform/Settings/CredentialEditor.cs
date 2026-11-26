using LiveCopilot.Core;

namespace LiveCopilot.Platform.Settings;

/// Secrets never participate in binding, record printing, preferences or exception messages.
/// PasswordBox supplies a new value through Stage; only SettingsViewModel.Save commits it.
public sealed class CredentialEditor : ObservableObject
{
    private readonly ICredentialStore store;
    private CredentialReference? reference;
    private string? pending;
    private bool changed;
    private string status = "未保存";
    public string Label { get; }
    public string Status => status;
    public bool CanEdit => reference is not null;
    public bool HasPendingChange => changed;
    public RelayCommand ClearCommand { get; }
    public event Action? Changed;
    public event Action? InputResetRequested;

    internal CredentialEditor(string label, ICredentialStore store, CredentialReference? reference)
    {
        Label = label; this.store = store; this.reference = reference;
        ClearCommand = new(() => { pending = null; changed = true; SetStatus("待清除（保存后生效）"); InputResetRequested?.Invoke(); Changed?.Invoke(); }, () => CanEdit);
        Reload();
    }

    public void Stage(string value)
    {
        if (!CanEdit) return;
        pending = value.Trim();
        changed = pending.Length > 0;
        if (changed) SetStatus("待保存 · " + Mask(pending));
        else Reload();
        Changed?.Invoke();
    }

    internal void Retarget(CredentialReference? value)
    {
        if (reference == value) return;
        var discarded = changed;
        reference = value; Cancel();
        if (discarded && CanEdit) SetStatus(Status + "；地址已变更，请重新输入待保存密钥。");
        Notify(nameof(CanEdit)); ClearCommand.Refresh();
    }

    internal Action? PrepareRollback()
    {
        if (!changed || reference is null) return null;
        var target = reference;
        var original = store.Read(target);
        return () => { if (original is null) store.Clear(target); else store.Save(target, original); };
    }

    internal void Commit()
    {
        if (!changed || reference is null) return;
        if (pending is null) store.Clear(reference); else store.Save(reference, pending);
    }

    internal void Cancel() { pending = null; changed = false; Reload(); InputResetRequested?.Invoke(); }
    private void Reload()
    {
        if (reference is null) { SetStatus("请先填写有效的 HTTPS 地址和接口路径。"); return; }
        try
        {
            var value = store.Read(reference);
            SetStatus(string.IsNullOrWhiteSpace(value) ? "未保存" : "已保存 · " + Mask(value));
        }
        catch (Exception) { SetStatus("凭据读取失败，请检查 Windows 凭据管理器。"); }
    }
    private static string Mask(string value) => value.Length > 4 ? "末 4 位：" + value[^4..] : "••••";
    private void SetStatus(string value) { status = value; Notify(nameof(Status)); Notify(nameof(HasPendingChange)); }
    public override string ToString() => $"{Label}（密钥已隐藏）";
}
