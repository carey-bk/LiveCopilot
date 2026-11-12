using System.Text;
using LiveCopilot.Platform.Hotkeys;

namespace LiveCopilot.Platform.Tests;

public sealed class HotkeyTests
{
    private static readonly HotkeyCombo Custom = new(0x42, HotkeyModifiers.Control | HotkeyModifiers.Shift);
    [Fact] public void DefaultsMatchRequestedWindowsKeys()
    {
        var preferences = new MemoryPreferenceStore(); var store = new HotkeyStore(preferences);
        Assert.Equal(new(0x20, HotkeyModifiers.Control | HotkeyModifiers.Alt), store.Combo(SuggestionMode.Reply));
        Assert.Equal(new(0x53, HotkeyModifiers.Control | HotkeyModifiers.Alt), store.Combo(SuggestionMode.Recap));
        Assert.Equal(new(0x58, HotkeyModifiers.Control | HotkeyModifiers.Alt), store.Combo(SuggestionMode.FollowUp));
        Assert.Equal(new(0x48, HotkeyModifiers.Alt), store.ToggleOverlay);
        Assert.False(preferences.Contains(HotkeyStore.CombosKey)); Assert.False(preferences.Contains(HotkeyStore.OverlayKey));
    }
    [Fact] public void OriginalPreferenceKeysRoundTripAndNotify()
    {
        var preferences = new MemoryPreferenceStore(); var store = new HotkeyStore(preferences); var changes = 0;
        store.Changed += () => changes++;
        Assert.True(store.Set(SuggestionMode.Reply, Custom));
        Assert.True(store.SetToggleOverlay(new(0x51, HotkeyModifiers.Alt)));
        Assert.Equal(2, changes); Assert.True(preferences.Contains("hotkeyCombos.v1")); Assert.True(preferences.Contains("overlayHotkey.v1"));
        Assert.Contains("\"followUp\"", Encoding.UTF8.GetString(preferences.Get(HotkeyStore.CombosKey)!));
        var restored = new HotkeyStore(preferences);
        Assert.Equal(Custom, restored.Combo(SuggestionMode.Reply)); Assert.Equal(store.ToggleOverlay, restored.ToggleOverlay);
        Assert.True(restored.Reset(SuggestionMode.Reply)); Assert.True(restored.ResetToggleOverlay());
    }
    [Fact] public void UniquenessIncludesOverlayAndDisabledRoles()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore());
        Assert.False(store.Set(SuggestionMode.Reply, store.Combo(SuggestionMode.Recap)));
        Assert.False(store.Set(SuggestionMode.Reply, store.ToggleOverlay));
        Assert.False(store.SetToggleOverlay(store.Combo(SuggestionMode.FollowUp)));
        Assert.True(store.Set(SuggestionMode.Reply, Custom));
        Assert.False(store.Set(SuggestionMode.Recap, Custom));
    }
    [Fact] public void ResetRefusesDefaultsTakenByAnotherRole()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore());
        Assert.True(store.Set(SuggestionMode.Reply, Custom));
        Assert.True(store.SetToggleOverlay(HotkeyStore.Default(SuggestionMode.Reply)));
        Assert.False(store.Reset(SuggestionMode.Reply));
        Assert.True(store.Set(SuggestionMode.Recap, HotkeyStore.DefaultToggleOverlay));
        Assert.False(store.ResetToggleOverlay());
    }
    [Theory]
    [InlineData("bad-json")] [InlineData("null")]
    [InlineData("{\"reply\":{\"keyCode\":83,\"modifiers\":3}}")]
    [InlineData("{\"reply\":{\"keyCode\":72,\"modifiers\":1}}")]
    public void CorruptOrDuplicateSnapshotsLoadSafeDefaultsWithoutWrites(string saved)
    {
        var preferences = new MemoryPreferenceStore(); preferences.Set(HotkeyStore.CombosKey, Encoding.UTF8.GetBytes(saved));
        var store = new HotkeyStore(preferences);
        Assert.Equal(HotkeyStore.Default(SuggestionMode.Reply), store.Combo(SuggestionMode.Reply));
        Assert.Equal(saved, Encoding.UTF8.GetString(preferences.Get(HotkeyStore.CombosKey)!));
    }
    [Theory] [InlineData(0, 1)] [InlineData(16, 1)] [InlineData(66, 16384)]
    public void InvalidKeysOrFlagsCannotBeAssigned(uint key, uint flags)
    {
        var store = new HotkeyStore(new MemoryPreferenceStore());
        Assert.False(store.Set(SuggestionMode.Reply, new(key, (HotkeyModifiers)flags)));
        Assert.False(store.SetToggleOverlay(new(key, (HotkeyModifiers)flags)));
    }
    [Fact] public void RegistrarReceivesAllCombosWithNoRepeatAndDispatchesOnCallingThread()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore()); var registrar = new FakeRegistrar();
        var suggestions = new List<SuggestionMode>(); var toggles = 0; var thread = 0;
        using var manager = new HotkeyManager(store, registrar, mode => { suggestions.Add(mode); thread = Environment.CurrentManagedThreadId; }, () => toggles++, Assert.Fail);
        Assert.Equal(4, registrar.Active.Count); Assert.All(registrar.Requests, r => Assert.True(r.NoRepeat));
        foreach (var mode in Enum.GetValues<SuggestionMode>()) registrar.PressCombo(store.Combo(mode));
        registrar.PressCombo(store.ToggleOverlay);
        Assert.Equal(Enum.GetValues<SuggestionMode>(), suggestions); Assert.Equal(1, toggles); Assert.Equal(Environment.CurrentManagedThreadId, thread);
    }
    [Fact] public void StoreChangesRebuildAndStaleQueuedIdsCannotInvokeNewActions()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore()); var registrar = new FakeRegistrar(); var called = 0;
        using var manager = new HotkeyManager(store, registrar, _ => called++, () => called++, Assert.Fail);
        var oldIds = registrar.Active.Keys.ToArray();
        store.Set(SuggestionMode.Reply, Custom);
        Assert.Equal(4, registrar.Active.Count); Assert.Equal(4, registrar.Unregistered.Count);
        foreach (var id in oldIds) registrar.Press(id);
        Assert.Equal(0, called); registrar.PressCombo(Custom); Assert.Equal(1, called);
    }
    [Fact] public void RecordingUnregistersEverythingUntilRecordingEnds()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore()); var registrar = new FakeRegistrar();
        using var manager = new HotkeyManager(store, registrar, _ => Assert.Fail(), () => Assert.Fail(), Assert.Fail);
        manager.SetRecording(true); Assert.Empty(registrar.Active);
        store.Set(SuggestionMode.Reply, Custom); Assert.Empty(registrar.Active);
        manager.SetRecording(false); Assert.Equal(4, registrar.Active.Count); Assert.Contains(Custom, registrar.Active.Values);
    }
    [Fact] public void OverlayRemainsRegisteredWhenAllConversationModesAreDisabled()
    {
        var store = new HotkeyStore(new MemoryPreferenceStore()); var registrar = new FakeRegistrar(); var toggles = 0;
        using var manager = new HotkeyManager(store, registrar, _ => Assert.Fail(), () => toggles++, Assert.Fail);
        manager.SetEnabledModes([]); Assert.Equal(store.ToggleOverlay, Assert.Single(registrar.Active).Value);
        registrar.PressCombo(store.ToggleOverlay); Assert.Equal(1, toggles);
        manager.SetEnabledModes([SuggestionMode.Recap]); Assert.Equal(2, registrar.Active.Count);
        manager.SetRecording(true); Assert.Empty(registrar.Active);
    }
    [Theory] [InlineData(1)] [InlineData(2)] [InlineData(4)]
    public void RegistrationFailureRollsBackWholeSetAndReportsCombo(int failAt)
    {
        var registrar = new FakeRegistrar { FailAt = failAt }; var errors = new List<string>();
        using var manager = new HotkeyManager(new(new MemoryPreferenceStore()), registrar, _ => { }, () => { }, errors.Add);
        Assert.Empty(registrar.Active); Assert.Contains("already in use", Assert.Single(errors)); Assert.Contains("1409", errors[0]);
        registrar.FailAt = null; manager.Rebuild(); Assert.Equal(4, registrar.Active.Count);
    }
    [Fact] public void RegistrarExceptionRollsBackAndDisposeUnsubscribes()
    {
        var registrar = new FakeRegistrar { ThrowAt = 3 }; var errors = new List<string>(); var store = new HotkeyStore(new MemoryPreferenceStore());
        var manager = new HotkeyManager(store, registrar, _ => { }, () => { }, errors.Add);
        Assert.Empty(registrar.Active); Assert.Single(errors);
        registrar.ThrowAt = null; manager.Rebuild(); manager.Dispose(); manager.Dispose();
        Assert.Empty(registrar.Active); Assert.Equal(1, registrar.Disposals);
        var count = registrar.Requests.Count; store.Set(SuggestionMode.Reply, Custom); Assert.Equal(count, registrar.Requests.Count);
    }
}

internal sealed class FakeRegistrar : IHotkeyRegistrar
{
    public event Action<int>? Pressed;
    public Dictionary<int, HotkeyCombo> Active { get; } = [];
    public List<(int Id, HotkeyCombo Combo, bool NoRepeat)> Requests { get; } = [];
    public List<int> Unregistered { get; } = [];
    public int? FailAt { get; set; }
    public int? ThrowAt { get; set; }
    public int Disposals { get; private set; }
    public HotkeyRegistration Register(int id, HotkeyCombo combo, bool noRepeat)
    {
        Requests.Add((id, combo, noRepeat));
        if (Requests.Count == ThrowAt) throw new InvalidOperationException("Registrar unavailable");
        if (Requests.Count == FailAt) return new(false, 1409);
        Active.Add(id, combo); return new(true);
    }
    public void Unregister(int id) { Assert.True(Active.Remove(id)); Unregistered.Add(id); }
    public void Press(int id) => Pressed?.Invoke(id);
    public void PressCombo(HotkeyCombo combo) => Press(Active.Single(p => p.Value == combo).Key);
    public void Dispose() { Disposals++; Assert.Empty(Active); }
}
