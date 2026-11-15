using System.ComponentModel;
using System.IO;
using System.Text;
using System.Text.Json;
using LiveCopilot.Platform.Hotkeys;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed class SettingsViewModelTests
{
    private const string Secret = "test-only-private-credential-9274";
    private static SettingsViewModel Create(IPreferenceStore? preferences = null, ICredentialStore? credentials = null)
    {
        preferences ??= new MemoryPreferenceStore();
        return new(preferences, credentials ?? new MemoryCredentialStore(), new(preferences));
    }

    [Fact] public void OpeningDefaultsIsReadOnlyAndDetached()
    {
        var preferences = new RecordingPreferences(); var vm = Create(preferences);
        Assert.Equal(new AppSettings(), vm.Snapshot()); Assert.False(vm.HasChanges); Assert.False(vm.HasErrors);
        Assert.Empty(preferences.Writes); Assert.True(vm.SaveCommand.CanExecute(null));
        var detached = vm.Snapshot(); detached.AnswerFontSize = 27;
        Assert.Equal(14, vm.AnswerFontSize);
        Assert.Equal(4, vm.Shortcuts.Count); Assert.Contains("尚未安装", vm.ListeningHint);
    }

    [Fact] public void SavingAllPagesRoundTripsAndNotifiesWithDetachedCopy()
    {
        var preferences = new RecordingPreferences(); var vm = Create(preferences); AppSettings? saved = null;
        vm.Saved += value => saved = value;
        vm.Language = AppLanguage.English; vm.AnswerLanguage = AnswerLanguage.Chinese;
        vm.Scenario = ScenarioProfile.Meeting; vm.AutomaticSuggestions = false;
        vm.ContinuousQuestionPolicy = ContinuousQuestionPolicy.Complete; vm.BilingualAnswers = true;
        vm.AdditionalAnswerInstructions = "先给结论"; vm.TranscriptFontSize = 18; vm.AnswerFontSize = 24;
        vm.OverlayAutoHeight = false; vm.ExcludeOverlayFromCapture = true;
        vm.ListeningService = ListeningService.Paraformer; vm.LiveSpeechLanguage = LiveSpeechLanguage.English;
        vm.ReasoningService = ReasoningService.DeepSeek; vm.AnalysisThinking = AnalysisThinking.High;
        vm.KnowledgeMode = KnowledgeMode.KnowledgeBaseOnly; vm.EmbeddingModel = "text-embedding-3-large"; vm.RetrievalCount = 8;
        Assert.Empty(preferences.Writes); Assert.True(vm.HasChanges); Assert.True(vm.Save());
        Assert.Equal(vm.Snapshot(), AppSettings.Load(preferences)); Assert.Equal(vm.Snapshot(), saved);
        saved!.AnswerFontSize = 11; Assert.Equal(24, vm.AnswerFontSize); Assert.False(vm.HasChanges);
    }

    [Fact] public void CancelDiscardsSettingsCredentialsAndShortcutDraftsWithoutWrites()
    {
        var preferences = new RecordingPreferences(); var credentials = new MemoryCredentialStore();
        credentials.Save(CredentialReference.Live, Secret); var vm = Create(preferences, credentials);
        var initial = vm.Snapshot(); var cancelled = 0; vm.Cancelled += () => cancelled++;
        vm.AnswerFontSizeText = "invalid"; vm.OpenAICredential.Stage("replacement-test-key");
        vm.RecordShortcut(vm.Shortcuts[0], new(0x42, HotkeyModifiers.Control));
        vm.Cancel(); Assert.Equal(initial, vm.Snapshot()); Assert.False(vm.HasChanges); Assert.False(vm.HasErrors);
        Assert.Equal(Secret, credentials.Read(CredentialReference.Live)); Assert.Equal(1, cancelled); Assert.Empty(preferences.Writes);
        Assert.Equal(HotkeyStore.Default(SuggestionMode.Reply), vm.Shortcuts[0].Combo);
    }

    [Theory] [InlineData(10)] [InlineData(29)] [InlineData(double.NaN)] [InlineData(double.PositiveInfinity)] [InlineData(double.NegativeInfinity)]
    public void InvalidFontsDisableSaveWithoutClamping(double value)
    {
        var preferences = new RecordingPreferences(); var vm = Create(preferences); var notifications = new List<string?>();
        vm.ErrorsChanged += (_, args) => notifications.Add(args.PropertyName);
        vm.TranscriptFontSize = value; vm.AnswerFontSize = value;
        Assert.True(vm.HasErrors); Assert.False(vm.SaveCommand.CanExecute(null)); Assert.False(vm.Save());
        Assert.NotEmpty(vm.GetErrors(nameof(vm.TranscriptFontSize)).Cast<string>());
        Assert.NotEmpty(vm.GetErrors(nameof(vm.AnswerFontSize)).Cast<string>());
        Assert.Contains(nameof(vm.TranscriptFontSize), notifications); Assert.Empty(preferences.Writes);
        vm.TranscriptFontSize = 11; vm.AnswerFontSize = 28; Assert.False(vm.HasErrors); Assert.True(vm.Save());
    }

    [Theory] [InlineData("abc")] [InlineData("")] [InlineData("1e999")]
    public void NumericTextErrorsStayVisibleUntilCorrected(string text)
    {
        var vm = Create(); vm.AnswerFontSizeText = text; vm.RetrievalCountText = text;
        Assert.Equal(text, vm.AnswerFontSizeText); Assert.Equal(text, vm.RetrievalCountText); Assert.True(vm.HasErrors);
        Assert.NotEmpty(vm.GetErrors(nameof(vm.AnswerFontSizeText)).Cast<string>());
        vm.AnswerFontSizeText = "16"; vm.RetrievalCountText = "5"; Assert.False(vm.HasErrors);
    }

    [Theory] [InlineData(2)] [InlineData(9)] [InlineData(0)] [InlineData(int.MaxValue)]
    public void RetrievalCountRejectsOutsideThreeToEight(int value)
    { var vm = Create(); vm.RetrievalCount = value; Assert.False(vm.Save()); Assert.Contains("3–8", vm.ValidationSummary); }

    [Theory] [InlineData(3)] [InlineData(8)]
    public void RetrievalCountAcceptsBothBoundaries(int value)
    { var preferences = new MemoryPreferenceStore(); var vm = Create(preferences); vm.RetrievalCount = value; Assert.True(vm.Save()); Assert.Equal(value, AppSettings.Load(preferences).RetrievalCount); }

    [Fact] public void InstructionsRejectOversizeWithoutTruncatingDraft()
    { var vm = Create(); vm.AdditionalAnswerInstructions = new('字', 4001); Assert.False(vm.Save()); Assert.Equal(4001, vm.AdditionalAnswerInstructions.Length); vm.AdditionalAnswerInstructions = new('字', 4000); Assert.True(vm.Save()); }

    [Theory] [InlineData(ReasoningService.SharedOpenAI)] [InlineData(ReasoningService.SeparateOpenAI)] [InlineData(ReasoningService.DeepSeek)]
    [InlineData(ReasoningService.Qwen)] [InlineData(ReasoningService.Glm)] [InlineData(ReasoningService.Kimi)]
    public void ServiceSelectionUsesCatalogModelsAndSupportedThinking(ReasoningService service)
    {
        var vm = Create(); vm.ReasoningService = service;
        Assert.Equal(AnalysisModelCatalog.ModelsFor(service), vm.Models);
        foreach (var model in vm.Models)
        {
            vm.AnalysisModel = model.Id;
            foreach (var mode in model.Modes) { vm.AnalysisThinking = mode; Assert.False(vm.HasErrors); Assert.Equal(mode, vm.Snapshot().AnalysisThinking); }
        }
        vm.AnalysisThinking = (AnalysisThinking)999; Assert.True(vm.HasErrors); Assert.False(vm.Save());
        vm.AnalysisModel = vm.Models[0].Id; Assert.False(vm.HasErrors);
    }

    [Fact] public void UnsupportedThinkingIsRejectedInsteadOfSilentlyNormalizing()
    { var vm = Create(); vm.ReasoningService = ReasoningService.DeepSeek; vm.AnalysisThinking = AnalysisThinking.Medium; Assert.True(vm.HasErrors); Assert.Contains("推理强度", vm.ValidationSummary); }

    [Theory] [InlineData("http://example.invalid/v1")] [InlineData("")] [InlineData("https://user:password@example.invalid")]
    [InlineData("https://example.invalid?key=value")] [InlineData("https://example.invalid#fragment")] [InlineData("https://example.invalid /v1")]
    public void CompatibleRejectsUnsafeBaseUrls(string url)
    {
        var vm = Create(); vm.ReasoningService = ReasoningService.Compatible; vm.CompatibleBaseURL = url; vm.CompatibleModel = "custom-model";
        Assert.False(vm.Save()); Assert.Contains("BaseURL", vm.ValidationSummary); Assert.False(vm.CompatibleCredential.CanEdit);
    }

    [Theory] [InlineData("")] [InlineData("/")] [InlineData("../chat")] [InlineData("%2e%2e/chat")]
    [InlineData("chat?api_key=value")] [InlineData("https://other.invalid/chat")] [InlineData("chat\\completions")] [InlineData("chat%5ccompletions")] [InlineData("chat completions")]
    public void CompatibleRejectsUnsafePaths(string path)
    {
        var vm = Create(); vm.ReasoningService = ReasoningService.Compatible; vm.CompatibleBaseURL = "https://example.invalid/v1";
        vm.CompatiblePath = path; vm.CompatibleModel = "custom-model";
        Assert.False(vm.Save()); Assert.Contains("接口路径", vm.ValidationSummary); Assert.False(vm.CompatibleCredential.CanEdit);
    }

    [Fact] public void CompatibleModelIsRequiredAndCredentialsAreEndpointScoped()
    {
        var preferences = new MemoryPreferenceStore(); var credentials = new MemoryCredentialStore(); var vm = Create(preferences, credentials);
        vm.ReasoningService = ReasoningService.Compatible; vm.CompatibleBaseURL = "https://example.invalid/v1";
        Assert.False(vm.Save()); vm.CompatibleModel = "custom-model";
        vm.CompatibleCredential.Stage(Secret); Assert.True(vm.Save());
        var reference = vm.Snapshot().AnalysisCredentialReference(); Assert.Equal(Secret, credentials.Read(reference));
        vm.CompatibleBaseURL = "https://different.invalid/v1"; Assert.Equal("未保存", vm.CompatibleCredential.Status);
        vm.CompatibleCredential.Stage("different-test-key"); vm.CompatiblePath = "responses";
        Assert.False(vm.CompatibleCredential.HasPendingChange); Assert.Contains("重新输入", vm.CompatibleCredential.Status);
        Assert.Equal(Secret, credentials.Read(reference));
    }

    [Fact] public void CredentialsRemainOutOfBindingsPreferencesSerializationAndDiagnosticText()
    {
        var preferences = new MemoryPreferenceStore(); var credentials = new MemoryCredentialStore(); credentials.Save(CredentialReference.Live, Secret);
        var vm = Create(preferences, credentials);
        Assert.Equal("已保存 · 末 4 位：9274", vm.OpenAICredential.Status);
        vm.DeepSeekCredential.Stage(Secret); Assert.True(vm.Save()); Assert.Equal(Secret, credentials.Read(CredentialReference.DeepSeek));
        foreach (var text in new[] { vm.ToString(), vm.DeepSeekCredential.ToString(), JsonSerializer.Serialize(vm.Credentials), CoreJson.Encode(vm.Snapshot()),
            Encoding.UTF8.GetString(preferences.Get(AppSettings.DefaultsKey)!), vm.Status, vm.ValidationSummary }) Assert.DoesNotContain(Secret, text);
        Assert.DoesNotContain(typeof(CredentialEditor).GetProperties(), property => property.Name is "Value" or "Password" or "Key" or "Pending");
    }

    [Fact] public void ClearingCredentialIsStagedAndShortSecretsAreNeverShownInFull()
    {
        var credentials = new MemoryCredentialStore(); credentials.Save(CredentialReference.Live, "abcd"); var vm = Create(credentials: credentials);
        Assert.DoesNotContain("abcd", vm.OpenAICredential.Status); var resets = 0; vm.OpenAICredential.InputResetRequested += () => resets++;
        vm.OpenAICredential.ClearCommand.Execute(null); Assert.Equal("abcd", credentials.Read(CredentialReference.Live)); Assert.Equal(1, resets);
        vm.Cancel(); Assert.Equal("abcd", credentials.Read(CredentialReference.Live));
        vm.OpenAICredential.ClearCommand.Execute(null); Assert.True(vm.Save()); Assert.Null(credentials.Read(CredentialReference.Live));
    }

    [Fact] public void SharedSeparateAndPresetCredentialsUseIndependentReferences()
    {
        var credentials = new MemoryCredentialStore(); var vm = Create(credentials: credentials);
        vm.OpenAICredential.Stage("test-shared"); vm.SeparateOpenAICredential.Stage("test-separate");
        vm.ReasoningService = ReasoningService.Qwen; vm.PresetCredential.Stage("test-qwen"); var reference = vm.Snapshot().AnalysisCredentialReference();
        Assert.True(vm.Save()); Assert.Equal("test-shared", credentials.Read(CredentialReference.Live));
        Assert.Equal("test-separate", credentials.Read(CredentialReference.SeparateOpenAI)); Assert.Equal("test-qwen", credentials.Read(reference));
        vm.ReasoningService = ReasoningService.Glm; Assert.Equal("未保存", vm.PresetCredential.Status);
    }

    [Fact] public void PreferenceFailureRollsBackCredentialsAndDoesNotNotifyOrLeakException()
    {
        var preferences = new RecordingPreferences { FailKey = AppSettings.DefaultsKey }; var credentials = new MemoryCredentialStore();
        credentials.Save(CredentialReference.Live, "test-old-key"); var vm = Create(preferences, credentials); var saved = 0; vm.Saved += _ => saved++;
        vm.OpenAICredential.Stage(Secret); vm.Language = AppLanguage.English;
        Assert.False(vm.Save()); Assert.Equal("test-old-key", credentials.Read(CredentialReference.Live)); Assert.Equal(0, saved);
        Assert.DoesNotContain(Secret, vm.Status); Assert.Contains("保存失败", vm.Status); Assert.True(vm.HasChanges);
    }

    [Fact] public void CredentialFailureRollsBackEarlierCredentialAndDoesNotSavePreferences()
    {
        var preferences = new RecordingPreferences(); var credentials = new FailingCredentials(); credentials.Inner.Save(CredentialReference.Live, "test-old");
        var vm = Create(preferences, credentials); vm.OpenAICredential.Stage(Secret); vm.DeepSeekCredential.Stage(Secret);
        Assert.False(vm.Save()); Assert.Equal("test-old", credentials.Read(CredentialReference.Live)); Assert.Empty(preferences.Writes);
        Assert.DoesNotContain(Secret, vm.Status);
    }

    [Fact] public void KnowledgeIdentityChangePromptsRebuildButModeOrCountDoesNot()
    {
        var vm = Create(); vm.KnowledgeMode = KnowledgeMode.General; vm.RetrievalCount = 3; Assert.False(vm.KnowledgeRebuildRequired);
        vm.EmbeddingModel = "text-embedding-3-large"; Assert.True(vm.KnowledgeRebuildRequired); Assert.Contains("重新索引", vm.KnowledgeRebuildHint);
        vm.Cancel(); Assert.False(vm.KnowledgeRebuildRequired); vm.EmbeddingService = EmbeddingService.Local;
        Assert.True(vm.KnowledgeRebuildRequired); Assert.Contains("尚未安装", vm.EmbeddingHint); Assert.True(vm.Save()); Assert.Contains("重新索引", vm.Status);
        vm.EmbeddingModel = "unused-remote-model"; Assert.False(vm.KnowledgeRebuildRequired); Assert.Equal(AppPaths.LocalEmbeddingIdentity, vm.SelectedEmbeddingIdentity);
    }

    [Fact] public void EmptyCloudEmbeddingModelIsInvalidButLocalIdentityRemainsFixed()
    { var vm = Create(); vm.EmbeddingModel = " "; Assert.False(vm.Save()); vm.EmbeddingService = EmbeddingService.Local; Assert.True(vm.Save()); }

    [Fact] public void BusyDocumentOperationsDisableSaveAndCancelWithoutLosingDraft()
    {
        var vm = Create(); vm.AnswerFontSize = 20; vm.IsBusy = true; Assert.False(vm.CanEdit);
        Assert.False(vm.SaveCommand.CanExecute(null)); Assert.False(vm.CancelCommand.CanExecute(null)); Assert.False(vm.Save());
        vm.Cancel(); Assert.Equal(20, vm.AnswerFontSize); vm.IsBusy = false; vm.Cancel(); Assert.Equal(14, vm.AnswerFontSize);
    }

    [Theory] [InlineData(ListeningService.Zipformer)] [InlineData(ListeningService.Paraformer)] [InlineData(ListeningService.Apple)] [InlineData(ListeningService.OpenAI)]
    public void ListeningChoicesAreDataOnlyAndReportAvailability(ListeningService service)
    {
        var preferences = new MemoryPreferenceStore(); var vm = new SettingsViewModel(preferences, new MemoryCredentialStore(), new(preferences), _ => true);
        vm.ListeningService = service; Assert.True(vm.Save());
        Assert.Contains(service is ListeningService.Zipformer or ListeningService.Paraformer ? "已安装" : service == ListeningService.Apple ? "不支持" : "尚未接入", vm.ListeningHint);
    }

    [Fact] public void AboutUsesProvidedAssemblyAndRequiredNotices()
    {
        var preferences = new MemoryPreferenceStore(); var assembly = typeof(SettingsViewModelTests).Assembly;
        var vm = new SettingsViewModel(preferences, new MemoryCredentialStore(), new(preferences), assembly: assembly);
        Assert.Equal(assembly.GetName().Version!.ToString(), vm.Version); Assert.Equal("https://github.com/carey-bk/LiveCopilot", vm.ProjectUrl);
        Assert.Contains("SmartScreen", vm.UnsignedNotice); Assert.Contains("仍要运行", vm.UnsignedNotice); Assert.Equal("即将推出", vm.HistoryNotice);
    }

    [Fact] public void SavedObserversReceiveIndependentSnapshotsEvenWhenEarlierObserverFails()
    {
        var preferences = new MemoryPreferenceStore(); var vm = Create(preferences); AppSettings? observed = null;
        vm.Saved += value => { value.AnswerFontSize = 11; throw new InvalidOperationException(Secret); };
        vm.Saved += value => observed = value;
        vm.AnswerFontSize = 24; Assert.True(vm.Save());
        Assert.Equal(24, observed!.AnswerFontSize); Assert.Equal(24, AppSettings.Load(preferences).AnswerFontSize);
        Assert.False(vm.HasChanges); Assert.Contains("刷新失败", vm.Status); Assert.DoesNotContain(Secret, vm.Status);
    }

    [Fact] public void FilePreferencesSurviveReopeningWithoutCredentialOrCancelledDraft()
    {
        var root = Path.Combine(Path.GetTempPath(), "settings-test-" + Guid.NewGuid());
        try
        {
            var preferences = new FilePreferenceStore(root); var credentials = new MemoryCredentialStore();
            var vm = Create(preferences, credentials); Assert.False(Directory.Exists(root));
            vm.AnswerFontSize = 23; vm.Language = AppLanguage.TraditionalChinese; vm.DeepSeekCredential.Stage(Secret);
            vm.RecordShortcut(vm.Shortcuts[0], new(0x42, HotkeyModifiers.Control)); Assert.True(vm.Save());
            vm.AnswerFontSize = 27; vm.DeepSeekCredential.ClearCommand.Execute(null); vm.Cancel();
            var reopened = Create(new FilePreferenceStore(root), credentials);
            Assert.Equal(23, reopened.AnswerFontSize); Assert.Equal(AppLanguage.TraditionalChinese, reopened.Language);
            Assert.Equal(new(0x42, HotkeyModifiers.Control), reopened.Shortcuts[0].Combo);
            Assert.Equal("已保存 · 末 4 位：9274", reopened.DeepSeekCredential.Status);
            foreach (var file in Directory.GetFiles(root)) Assert.DoesNotContain(Secret, File.ReadAllText(file));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private sealed class RecordingPreferences : IPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public List<string> Writes { get; } = [];
        public string? FailKey { get; set; }
        public bool Contains(string key) => inner.Contains(key);
        public byte[]? Get(string key) => inner.Get(key);
        public void Set(string key, byte[] value)
        { if (key == FailKey) { FailKey = null; throw new IOException(Secret); } Writes.Add(key); inner.Set(key, value); }
    }
    private sealed class FailingCredentials : ICredentialStore
    {
        public MemoryCredentialStore Inner { get; } = new();
        public string? Read(CredentialReference reference) => Inner.Read(reference);
        public void Save(CredentialReference reference, string key)
        { if (reference == CredentialReference.DeepSeek) throw new IOException(Secret); Inner.Save(reference, key); }
        public void Clear(CredentialReference reference) => Inner.Clear(reference);
    }
}
