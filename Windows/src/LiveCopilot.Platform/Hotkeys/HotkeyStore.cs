using System.Text.Json;
using LiveCopilot.Core;

namespace LiveCopilot.Platform.Hotkeys;

[Flags]
public enum HotkeyModifiers : uint { None = 0, Alt = 1, Control = 2, Shift = 4, Windows = 8 }
public readonly record struct HotkeyCombo(uint KeyCode, HotkeyModifiers Modifiers)
{
    // Windows VK values, NOT Carbon key codes. Persistence keeps the Mac key names.
    public bool IsValid => KeyCode is >= 0x08 and <= 0xFE && KeyCode is not (0x10 or 0x11 or 0x12 or 0x5B or 0x5C)
        && (Modifiers & ~(HotkeyModifiers)15) == 0;
    public override string ToString() => $"{Modifiers}+{(KeyCode == 32 ? "Space" : KeyCode is >= 65 and <= 90 ? ((char)KeyCode).ToString() : $"VK 0x{KeyCode:X2}")}";
}

/// UI/message-thread store, like Mac MainActor. Changes are synchronous; no native APIs.
public sealed class HotkeyStore
{
    public const string CombosKey = "hotkeyCombos.v1", OverlayKey = "overlayHotkey.v1";
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly IPreferenceStore preferences;
    private readonly Dictionary<SuggestionMode, HotkeyCombo> combos = [];
    public event Action? Changed;
    public HotkeyCombo ToggleOverlay { get; private set; } = DefaultToggleOverlay;
    public static HotkeyCombo DefaultToggleOverlay => new(0x48, HotkeyModifiers.Alt);
    public static HotkeyCombo Default(SuggestionMode mode) => new(mode switch
    {
        SuggestionMode.Reply => 0x20, SuggestionMode.Recap => 0x53, SuggestionMode.FollowUp => 0x58,
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    }, HotkeyModifiers.Control | HotkeyModifiers.Alt);

    public HotkeyStore(IPreferenceStore preferences)
    {
        this.preferences = preferences;
        foreach (var mode in Enum.GetValues<SuggestionMode>()) combos[mode] = Default(mode);
        var saved = Read<Dictionary<string, HotkeyCombo>>(CombosKey);
        var overlay = Read<HotkeyCombo?>(OverlayKey);
        var candidate = combos.ToDictionary(pair => pair.Key, pair => pair.Value);
        if (saved is not null)
            foreach (var mode in candidate.Keys)
                if (saved.TryGetValue(mode.RawValue(), out var combo) && combo.IsValid) candidate[mode] = combo;
        var candidateOverlay = overlay is { IsValid: true } ? overlay.Value : DefaultToggleOverlay;
        // A corrupt/conflicting snapshot is rejected as a whole, with no writes on load.
        if (candidate.Values.Append(candidateOverlay).Distinct().Count() == 4)
        { combos = candidate; ToggleOverlay = candidateOverlay; }
    }

    private T? Read<T>(string key)
    {
        try { return preferences.Get(key) is { } bytes ? JsonSerializer.Deserialize<T>(bytes, Json) : default; }
        catch (JsonException) { return default; }
    }
    public HotkeyCombo Combo(SuggestionMode mode) => combos[mode];
    public bool Set(SuggestionMode mode, HotkeyCombo combo)
    {
        if (!combos.ContainsKey(mode) || !combo.IsValid || combo == ToggleOverlay || combos.Any(p => p.Key != mode && p.Value == combo)) return false;
        if (combos[mode] == combo) return true;
        var next = combos.ToDictionary(p => p.Key, p => p.Value);
        next[mode] = combo;
        preferences.Set(CombosKey, JsonSerializer.SerializeToUtf8Bytes(next.ToDictionary(p => p.Key.RawValue(), p => p.Value), Json));
        combos[mode] = combo;
        Changed?.Invoke();
        return true;
    }
    public bool Reset(SuggestionMode mode) => Set(mode, Default(mode));
    public bool SetToggleOverlay(HotkeyCombo combo)
    {
        if (!combo.IsValid || combos.Values.Contains(combo)) return false;
        if (ToggleOverlay == combo) return true;
        preferences.Set(OverlayKey, JsonSerializer.SerializeToUtf8Bytes(combo, Json));
        ToggleOverlay = combo;
        Changed?.Invoke();
        return true;
    }
    public bool ResetToggleOverlay() => SetToggleOverlay(DefaultToggleOverlay);
}
