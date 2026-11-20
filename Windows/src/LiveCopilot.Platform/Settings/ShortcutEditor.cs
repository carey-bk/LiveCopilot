using LiveCopilot.Core;
using LiveCopilot.Platform.Hotkeys;

namespace LiveCopilot.Platform.Settings;

public sealed class ShortcutEditor : ObservableObject
{
    private HotkeyCombo combo;
    public SuggestionMode? Mode { get; }
    public string Label { get; }
    public HotkeyCombo Combo => combo;
    public string Display => combo.ToString();
    public RelayCommand ResetCommand { get; }
    internal ShortcutEditor(SuggestionMode? mode, HotkeyCombo combo, Action<ShortcutEditor, HotkeyCombo> set)
    {
        Mode = mode; this.combo = combo;
        Label = mode switch { SuggestionMode.Reply => "回答", SuggestionMode.Recap => "总结", SuggestionMode.FollowUp => "追问", _ => "显示 / 隐藏浮窗" };
        ResetCommand = new(() => set(this, Default));
    }
    internal HotkeyCombo Default => Mode is { } mode ? HotkeyStore.Default(mode) : HotkeyStore.DefaultToggleOverlay;
    internal void Assign(HotkeyCombo value) { combo = value; Notify(nameof(Combo)); Notify(nameof(Display)); }
}

public static class ShortcutValidation
{
    public static string? Error(HotkeyCombo combo)
    {
        if (!combo.IsValid || combo.KeyCode is >= 0xA0 and <= 0xA5)
            return "请按有效的字母、数字或功能键，并同时按住修饰键。";
        var mods = combo.Modifiers;
        if (mods == HotkeyModifiers.None || mods == HotkeyModifiers.Shift)
            return "快捷键至少需要 Ctrl 或 Alt；不能只使用普通键或 Shift。";
        // Win combinations belong to the shell; F12 is reserved for the debugger.
        if (mods.HasFlag(HotkeyModifiers.Windows) || combo.KeyCode == 0x7B ||
            (mods.HasFlag(HotkeyModifiers.Alt) && combo.KeyCode is 0x09 or 0x1B or 0x73) ||
            (mods.HasFlag(HotkeyModifiers.Alt) && !mods.HasFlag(HotkeyModifiers.Control) && combo.KeyCode == 0x20) ||
            (mods.HasFlag(HotkeyModifiers.Alt) && combo.KeyCode == 0x2C) ||
            (mods.HasFlag(HotkeyModifiers.Control) && combo.KeyCode == 0x1B) ||
            (mods.HasFlag(HotkeyModifiers.Control) && mods.HasFlag(HotkeyModifiers.Alt) && combo.KeyCode == 0x2E))
            return "该组合由 Windows 系统保留，请选择其他快捷键。";
        return null;
    }
}
