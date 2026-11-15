using System.IO;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsShortcutTests
{
    private static (SettingsViewModel View, HotkeyStore Store) Create(IPreferenceStore? preferences = null)
    {
        preferences ??= new MemoryPreferenceStore(); var store = new HotkeyStore(preferences);
        return (new(preferences, new MemoryCredentialStore(), store), store);
    }

    [Theory] [InlineData(0x09, HotkeyModifiers.Alt)] [InlineData(0x73, HotkeyModifiers.Alt)]
    [InlineData(0x1B, HotkeyModifiers.Control)] [InlineData(0x2E, HotkeyModifiers.Control | HotkeyModifiers.Alt)]
    [InlineData(0x4C, HotkeyModifiers.Windows)] [InlineData(0x7B, HotkeyModifiers.Control)] [InlineData(0x20, HotkeyModifiers.Alt)]
    public void ReservedShortcutsAreRejectedWithChineseError(uint key, HotkeyModifiers modifiers)
    {
        var (vm, store) = Create(); var initial = vm.Shortcuts[0].Combo;
        vm.RecordShortcut(vm.Shortcuts[0], new(key, modifiers));
        Assert.Equal(initial, vm.Shortcuts[0].Combo); Assert.Equal(initial, store.Combo(SuggestionMode.Reply));
        Assert.Contains("系统保留", vm.ShortcutError);
    }

    [Theory] [InlineData(0x42, HotkeyModifiers.None)] [InlineData(0x42, HotkeyModifiers.Shift)]
    [InlineData(0, HotkeyModifiers.Control)] [InlineData(0x11, HotkeyModifiers.Control)] [InlineData(0xA2, HotkeyModifiers.Control)]
    public void InvalidOrUnmodifiedShortcutsCannotEnterDraft(uint key, HotkeyModifiers modifiers)
    {
        var (vm, _) = Create(); var initial = vm.Shortcuts[0].Combo;
        vm.RecordShortcut(vm.Shortcuts[0], new(key, modifiers)); Assert.Equal(initial, vm.Shortcuts[0].Combo); Assert.NotEmpty(vm.ShortcutError);
    }

    [Fact] public void DuplicateCheckIncludesEveryActionAndOverlay()
    {
        var (vm, _) = Create();
        foreach (var source in vm.Shortcuts)
            foreach (var target in vm.Shortcuts.Where(target => target != source))
            { var original = source.Combo; vm.RecordShortcut(source, target.Combo); Assert.Equal(original, source.Combo); Assert.Contains("其他动作", vm.ShortcutError); }
    }

    [Fact] public void RecordingAndResetStayDraftUntilSaveThenRebuildManagerOnce()
    {
        var (vm, store) = Create(); var registrar = new FakeRegistrar(); var count = 0;
        using var manager = new HotkeyManager(store, registrar, _ => count++, () => { }, Assert.Fail);
        var custom = new HotkeyCombo(0x42, HotkeyModifiers.Control | HotkeyModifiers.Shift);
        vm.RecordShortcut(vm.Shortcuts[0], custom); Assert.DoesNotContain(custom, registrar.Active.Values);
        Assert.True(vm.Save()); Assert.Contains(custom, registrar.Active.Values); Assert.Equal(8, registrar.Requests.Count);
        registrar.PressCombo(custom); Assert.Equal(1, count);
        vm.Shortcuts[0].ResetCommand.Execute(null); Assert.Equal(custom, store.Combo(SuggestionMode.Reply));
        vm.Cancel(); Assert.Equal(custom, vm.Shortcuts[0].Combo);
    }

    [Fact] public void ResetAllCanResolveSwappedDefaultsWithoutIntermediateConflicts()
    {
        var (vm, store) = Create(); var reply = vm.Shortcuts[0]; var recap = vm.Shortcuts[1];
        vm.RecordShortcut(reply, new(0x42, HotkeyModifiers.Control)); vm.RecordShortcut(recap, HotkeyStore.Default(SuggestionMode.Reply));
        vm.RecordShortcut(reply, HotkeyStore.Default(SuggestionMode.Recap)); Assert.True(vm.Save());
        Assert.Equal(HotkeyStore.Default(SuggestionMode.Recap), store.Combo(SuggestionMode.Reply));
        vm.ResetShortcutsCommand.Execute(null); Assert.True(vm.Save());
        foreach (var mode in Enum.GetValues<SuggestionMode>()) Assert.Equal(HotkeyStore.Default(mode), store.Combo(mode));
    }

    [Fact] public void SingleResetRejectsAnotherActionsOccupiedDefault()
    {
        var (vm, _) = Create(); vm.RecordShortcut(vm.Shortcuts[0], new(0x42, HotkeyModifiers.Control));
        vm.RecordShortcut(vm.Shortcuts[1], HotkeyStore.Default(SuggestionMode.Reply));
        vm.Shortcuts[0].ResetCommand.Execute(null); Assert.Contains("其他动作", vm.ShortcutError);
    }

    [Fact] public void ObserverFailureDoesNotRollBackPersistedSettingsOrSkipRemainingObservers()
    {
        var preferences = new MemoryPreferenceStore(); var (vm, store) = Create(preferences); var calls = 0;
        store.Changed += () => throw new InvalidOperationException("test-private-value"); store.Changed += () => calls++;
        vm.AnswerFontSize = 20; vm.RecordShortcut(vm.Shortcuts[0], new(0x42, HotkeyModifiers.Control));
        Assert.True(vm.Save()); Assert.Equal(20, AppSettings.Load(preferences).AnswerFontSize); Assert.Equal(1, calls);
        Assert.Equal(vm.Shortcuts[0].Combo, new HotkeyStore(preferences).Combo(SuggestionMode.Reply));
        Assert.Contains("刷新失败", vm.Status); Assert.DoesNotContain("test-private-value", vm.Status);
    }

    [Fact] public void HotkeyWriteFailureRestoresEarlierSettingsAndBothShortcutKeys()
    {
        var preferences = new OnceFailingPreferences(); var (vm, store) = Create(preferences);
        var original = vm.Snapshot(); original.Save(preferences); var calls = 0; vm.Saved += _ => calls++;
        vm.AnswerFontSize = 20; vm.RecordShortcut(vm.Shortcuts[0], new(0x42, HotkeyModifiers.Control));
        preferences.FailOverlay = true; Assert.False(vm.Save());
        Assert.Equal(original, AppSettings.Load(preferences)); Assert.Equal(0, calls);
        Assert.Equal(HotkeyStore.Default(SuggestionMode.Reply), store.Combo(SuggestionMode.Reply));
        Assert.Equal(store.Combo(SuggestionMode.Reply), new HotkeyStore(preferences).Combo(SuggestionMode.Reply));
        Assert.True(vm.Save()); Assert.Equal(20, AppSettings.Load(preferences).AnswerFontSize);
    }

    [Fact] public void SnapshotRejectsIncompleteAndDuplicateSetsWithoutWriting()
    {
        var preferences = new MemoryPreferenceStore(); var store = new HotkeyStore(preferences);
        Assert.False(store.ApplySnapshot(new Dictionary<SuggestionMode, HotkeyCombo>(), store.ToggleOverlay));
        Assert.False(store.ApplySnapshot(Enum.GetValues<SuggestionMode>().ToDictionary(mode => mode, _ => store.ToggleOverlay), store.ToggleOverlay));
        Assert.False(preferences.Contains(HotkeyStore.CombosKey));
    }

    [Fact] public void AltShiftLettersAreRecordableButShellMenuAndScreenshotRemainReserved()
    {
        var (vm, _) = Create(); var combination = new HotkeyCombo(0x42, HotkeyModifiers.Alt | HotkeyModifiers.Shift);
        vm.RecordShortcut(vm.Shortcuts[0], combination); Assert.Equal(combination, vm.Shortcuts[0].Combo); Assert.True(vm.Save());
        vm.RecordShortcut(vm.Shortcuts[0], new(0x20, HotkeyModifiers.Alt | HotkeyModifiers.Shift));
        Assert.Equal(combination, vm.Shortcuts[0].Combo); Assert.Contains("系统保留", vm.ShortcutError);
        vm.RecordShortcut(vm.Shortcuts[0], new(0x2C, HotkeyModifiers.Alt));
        Assert.Equal(combination, vm.Shortcuts[0].Combo); Assert.Contains("系统保留", vm.ShortcutError);
    }

    private sealed class OnceFailingPreferences : IPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public bool FailOverlay { get; set; }
        public bool Contains(string key) => inner.Contains(key);
        public byte[]? Get(string key) => inner.Get(key);
        public void Set(string key, byte[] value)
        {
            if (FailOverlay && key == HotkeyStore.OverlayKey) { FailOverlay = false; throw new IOException("test failure"); }
            inner.Set(key, value);
        }
    }
}
