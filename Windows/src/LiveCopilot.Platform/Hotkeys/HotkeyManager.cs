using LiveCopilot.Core;

namespace LiveCopilot.Platform.Hotkeys;

public readonly record struct HotkeyRegistration(bool Success, int ErrorCode = 0);
public interface IHotkeyRegistrar : IDisposable
{
    event Action<int>? Pressed;
    HotkeyRegistration Register(int id, HotkeyCombo combo, bool noRepeat);
    void Unregister(int id);
}

/// All methods, store changes, and registrar events run on the same UI/message thread.
/// Each rebuild is all-or-nothing. A failed set leaves no active registrations.
public sealed class HotkeyManager : IDisposable
{
    private readonly HotkeyStore store;
    private readonly IHotkeyRegistrar registrar;
    private readonly Action<SuggestionMode> onSuggest;
    private readonly Action onToggleOverlay;
    private readonly Action<string> onError;
    private readonly Dictionary<int, Action> actions = [];
    private HashSet<SuggestionMode> enabled = Enum.GetValues<SuggestionMode>().ToHashSet();
    private bool recording, disposed;
    private int nextId = 1;

    public HotkeyManager(HotkeyStore store, IHotkeyRegistrar registrar, Action<SuggestionMode> onSuggest,
        Action onToggleOverlay, Action<string> onError)
    {
        this.store = store; this.registrar = registrar; this.onSuggest = onSuggest;
        this.onToggleOverlay = onToggleOverlay; this.onError = onError;
        registrar.Pressed += Dispatch;
        store.Changed += Rebuild;
        Rebuild();
    }
    public void SetRecording(bool value) { ObjectDisposedException.ThrowIf(disposed, this); if (recording == value) return; recording = value; Rebuild(); }
    public void SetEnabledModes(IEnumerable<SuggestionMode> modes)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var next = modes.ToHashSet();
        if (next.Any(mode => !Enum.IsDefined(mode))) throw new ArgumentException("Unknown suggestion mode.", nameof(modes));
        if (enabled.SetEquals(next)) return;
        enabled = next; Rebuild();
    }
    public void Rebuild()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        UnregisterAll();
        if (recording) return;
        var requested = Enum.GetValues<SuggestionMode>().Where(enabled.Contains)
            .Select(mode => (Combo: store.Combo(mode), Action: (Action)(() => onSuggest(mode))))
            .Append((store.ToggleOverlay, onToggleOverlay));
        foreach (var (combo, action) in requested)
        {
            // Do not reuse IDs: stale WM_HOTKEY queued before a rebuild must be ignored.
            if (nextId > 0xBFFF) { UnregisterAll(); onError("Global shortcut ID space exhausted. Restart LiveCopilot."); return; }
            var id = nextId++;
            HotkeyRegistration result;
            try { result = registrar.Register(id, combo, noRepeat: true); }
            catch (Exception e) { UnregisterAll(); onError("Global shortcut registration failed: " + e.Message); return; }
            if (!result.Success)
            {
                UnregisterAll();
                onError($"Global shortcut {combo} is already in use or unavailable (Win32 {result.ErrorCode}). Choose another shortcut.");
                return;
            }
            actions.Add(id, action);
        }
    }
    private void Dispatch(int id) { if (!disposed && actions.TryGetValue(id, out var action)) action(); }
    private void UnregisterAll() { foreach (var id in actions.Keys) registrar.Unregister(id); actions.Clear(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        store.Changed -= Rebuild;
        registrar.Pressed -= Dispatch;
        UnregisterAll();
        registrar.Dispose();
    }
}
