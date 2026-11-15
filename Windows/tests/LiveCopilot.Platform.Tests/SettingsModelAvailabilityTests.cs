using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsModelAvailabilityTests
{
    [Fact]
    public void InstallationRefreshesHintsWithoutSavingOrDiscardingDraft()
    {
        var preferences = new MemoryPreferenceStore();
        var installed = false;
        var view = new SettingsViewModel(preferences, new MemoryCredentialStore(), new HotkeyStore(preferences),
            _ => installed, () => installed);
        view.ListeningService = ListeningService.Zipformer;
        view.EmbeddingService = EmbeddingService.Local;
        view.AdditionalAnswerInstructions = "保留尚未保存的草稿";
        Assert.Contains("模型卡片", view.ListeningHint);
        Assert.Contains("模型卡片", view.EmbeddingHint);
        var before = view.Snapshot();
        var changed = new List<string?>();
        view.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        installed = true;
        view.RefreshModelAvailability();
        Assert.Contains(nameof(view.ListeningHint), changed);
        Assert.Contains(nameof(view.EmbeddingHint), changed);
        Assert.Contains("已安装", view.ListeningHint);
        Assert.DoesNotContain("尚未安装", view.EmbeddingHint);
        Assert.Equal(before, view.Snapshot());
        Assert.True(view.HasChanges);
        Assert.False(preferences.Contains(AppSettings.DefaultsKey));
    }
}
