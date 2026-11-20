using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Updates;

namespace LiveCopilot.Platform.Tests;

public sealed class UpdateSettingsTests
{
    [Fact]
    public async Task UpdatePreferenceIsOffByDefaultAndOnlyPersistsOnSave()
    {
        var preferences = new MemoryPreferenceStore();
        var vm = new SettingsViewModel(preferences, new MemoryCredentialStore(), new(preferences));
        Assert.False(vm.CheckForUpdates);
        Assert.Equal(UpdateCheckStatus.Disabled, await vm.CheckUpdatesAsync());
        vm.CheckForUpdates = true;
        Assert.False(AppSettings.Load(preferences).CheckForUpdates);
        Assert.Equal(UpdateCheckStatus.SourceNotConfigured, await vm.CheckUpdatesAsync());
        Assert.True(vm.Save());
        Assert.True(AppSettings.Load(preferences).CheckForUpdates);
        Assert.Contains("不会联网", vm.UpdateNotice);
    }

    [Fact]
    public void CancelUpdatePreferenceDoesNotPersist()
    {
        var preferences = new MemoryPreferenceStore();
        var vm = new SettingsViewModel(preferences, new MemoryCredentialStore(), new(preferences));
        vm.CheckForUpdates = true;
        vm.Cancel();
        Assert.False(vm.CheckForUpdates);
        Assert.False(AppSettings.Load(preferences).CheckForUpdates);
    }

    [Fact]
    public async Task UnconfiguredCheckerHonorsCancellationEvenWhenEnabled()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        IUpdateChecker checker = new UnconfiguredUpdateChecker();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => checker.CheckAsync(true, cancellation.Token));
    }

    [Fact]
    public void ArchitectureHintsTakePriorityOverModelPresenceOnlyForLocalServices()
    {
        var preferences = new MemoryPreferenceStore();
        var vm = new SettingsViewModel(preferences, new MemoryCredentialStore(), new(preferences), _ => true, () => true,
            speechUnavailable: () => "此架构暂不支持本地听写，请用 x64 版或云端服务",
            embeddingUnavailable: () => "此架构暂不支持本地嵌入，请用 x64 版或云端服务");
        vm.ListeningService = ListeningService.Paraformer;
        vm.EmbeddingService = EmbeddingService.Local;
        Assert.Contains("此架构暂不支持", vm.ListeningHint);
        Assert.Contains("此架构暂不支持", vm.EmbeddingHint);
        vm.EmbeddingService = EmbeddingService.OpenAI;
        Assert.DoesNotContain("此架构暂不支持", vm.EmbeddingHint);
    }
}
