using System.IO;
using System.Text;
using LiveCopilot.Platform.Overlay;

namespace LiveCopilot.Platform.Tests;

public sealed class OperationGuideTests
{
    [Fact]
    public void FourTipsResumePersistCompleteAndCanBeReopened()
    {
        var store = new MemoryPreferenceStore();
        var guide = new OperationGuideViewModel(store);
        Assert.False(guide.IsVisible);
        guide.Open(); Assert.True(guide.HighlightStart);
        guide.NextCommand.Execute(null);
        Assert.True(guide.HighlightAnswer);
        var resumed = new OperationGuideViewModel(store); resumed.Open();
        Assert.Equal(1, resumed.Step);
        resumed.NextCommand.Execute(null); Assert.True(resumed.HighlightPin);
        resumed.NextCommand.Execute(null); Assert.True(resumed.HighlightSettings);
        Assert.Equal("知道了", resumed.NextLabel);
        resumed.NextCommand.Execute(null); Assert.False(resumed.IsVisible);
        var completed = new OperationGuideViewModel(store); completed.Open(); Assert.False(completed.IsVisible);
        completed.Open(true); Assert.True(completed.IsVisible); Assert.Equal(0, completed.Step);
    }
    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public void SkipFromAnyStepPersistsAndDisablesNavigation(int step)
    {
        var store = new MemoryPreferenceStore(); var guide = new OperationGuideViewModel(store); guide.Open();
        for (var i = 0; i < step; i++) guide.NextCommand.Execute(null);
        guide.SkipCommand.Execute(null);
        Assert.False(guide.IsVisible); Assert.False(guide.NextCommand.CanExecute(null));
        var next = new OperationGuideViewModel(store); next.Open(); Assert.False(next.IsVisible);
        Assert.Null(store.Get(AppSettings.DefaultsKey));
    }
    [Theory]
    [InlineData("invalid", 0)] [InlineData("null", 0)] [InlineData("{\"Step\":-2}", 0)] [InlineData("{\"Step\":99}", 3)]
    public void InvalidProgressRecovers(string value, int step)
    {
        var store = new MemoryPreferenceStore(); store.Set(OperationGuideViewModel.Key, Encoding.UTF8.GetBytes(value));
        var guide = new OperationGuideViewModel(store); guide.Open(); Assert.Equal(step, guide.Step);
    }
    [Fact]
    public void SaveFailureKeepsTipVisibleAndRetryWorks()
    {
        var store = new FailingStore(); var guide = new OperationGuideViewModel(store); guide.Open();
        guide.NextCommand.Execute(null); Assert.Equal(0, guide.Step); Assert.NotEmpty(guide.Error);
        guide.SkipCommand.Execute(null); Assert.True(guide.IsVisible);
        store.Fail = false; guide.SkipCommand.Execute(null); Assert.False(guide.IsVisible); Assert.Empty(guide.Error);
    }
    [Fact]
    public void TipsDescribeActualShortcutsAndProtection()
    {
        var guide = new OperationGuideViewModel(new MemoryPreferenceStore()); guide.Open();
        guide.Configure("Ctrl+F2", "Ctrl+F3", true);
        guide.NextCommand.Execute(null); Assert.Contains("Ctrl+F2", guide.Description);
        guide.NextCommand.Execute(null); Assert.Contains("Ctrl+F3", guide.Description);
        guide.NextCommand.Execute(null); Assert.Contains("已开启", guide.Description);
        guide.Configure("F2", "F3", false); Assert.Contains("未开启", guide.Description);
    }
    private sealed class FailingStore : IPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public bool Fail { get; set; } = true;
        public bool Contains(string key) => inner.Contains(key);
        public byte[]? Get(string key) => inner.Get(key);
        public void Set(string key, byte[] value) { if (Fail) throw new IOException(); inner.Set(key, value); }
    }
}
