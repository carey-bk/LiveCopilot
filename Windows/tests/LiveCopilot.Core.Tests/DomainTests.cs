namespace LiveCopilot.Core.Tests;

public sealed class DomainTests
{
    [Fact] public void SwiftWireNamesDatesAndValueEqualityRoundTrip()
    {
        var chunk = Fixtures.Chunk();
        var json = CoreJson.Encode(chunk);
        Assert.Contains("\"documentID\"", json); Assert.DoesNotContain("sourceLabel", json);
        Assert.Equal(chunk, CoreJson.Decode<SourceChunk>(json));
        var fragment = Fixtures.Fragment("中文 🧪");
        json = CoreJson.Encode(fragment);
        Assert.Contains("\"startMS\"", json); Assert.Contains("\"endMS\"", json);
        Assert.Equal(fragment, CoreJson.Decode<TranscriptFragment>(json));
        Assert.Equal(0, CoreJson.Decode<double>(CoreJson.Encode(new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero))));
        Assert.Equal("\"Remote Meeting\"", CoreJson.Encode(OperatingMode.Remote));
        Assert.Equal(ListeningService.Zipformer, CoreJson.Decode<ListeningService>("\"local\""));
        Assert.Throws<JsonException>(() => CoreJson.Decode<SourceChunk>("{}"));
        Assert.Throws<JsonException>(() => CoreJson.Decode<AnswerLanguage>("\"unknown\""));
    }
    [Fact] public void SettingsDefaultsMigrationClampingAndIndependentChoices()
    {
        var defaults = CoreJson.Decode<AppSettings>("{}");
        Assert.Equal(ListeningService.Zipformer, defaults.ListeningService);
        Assert.Equal("gpt-6-sol", defaults.ReasoningModel); Assert.Equal("low", defaults.ReasoningEffort);
        Assert.Equal("deepseek-flash", defaults.DeepSeekModel); Assert.Equal("none", defaults.DeepSeekEffort);
        Assert.True(defaults.RecapEnabled && defaults.FollowUpEnabled && defaults.OverlayAutoHeight && defaults.ShowMenuBarIcon);
        Assert.False(defaults.OverlayEdgeHide); Assert.False(defaults.ExcludeOverlayFromCapture);
        Assert.Equal(new AppSettings(), defaults);
        var restored = CoreJson.Decode<AppSettings>("""{"listeningService":"local","reasoningModel":"my-model","reasoningEffort":"high","transcriptFontSize":-12,"answerFontSize":999,"retrievalCount":99,"layaThreshold":0.2,"professionalTerms":[" React ","react","","Vue"],"recapEnabled":false,"appleSpeechLanguage":"english"}""");
        Assert.Equal("my-model", restored.ReasoningModel); Assert.Equal("high", restored.ReasoningEffort);
        Assert.Equal(11, restored.TranscriptFontSize); Assert.Equal(28, restored.AnswerFontSize); Assert.Equal(8, restored.RetrievalCount); Assert.Equal(0.5, restored.LayaThreshold);
        Assert.Equal(["React", "Vue"], restored.ProfessionalTerms); Assert.Equal("english", restored.AppleSpeechLanguage);
        Assert.Equal([SuggestionMode.Reply, SuggestionMode.FollowUp], restored.EnabledSuggestionModes);
        Assert.Equal(restored, CoreJson.Decode<AppSettings>(CoreJson.Encode(restored)));
        Assert.Equal(defaults, CoreJson.Decode<AppSettings>("""{"language":null,"qwenConnection":null,"professionalTerms":null}"""));
        restored.ListeningService = ListeningService.Paraformer; restored.EmbeddingService = EmbeddingService.Local; restored.ReasoningService = ReasoningService.DeepSeek;
        Assert.False(restored.RequiresOpenAIKey); Assert.Equal(AppPaths.LocalEmbeddingIdentity, restored.SelectedEmbeddingIdentity);
    }
    [Fact] public void PreferenceBackendsKeepOriginalKeysAndDoNotWriteOnConstruction()
    {
        using var root = new TemporaryDirectory(false);
        var file = new FilePreferenceStore(root.Path);
        Assert.Equal(new AppSettings(), AppSettings.Load(file)); Assert.False(Directory.Exists(root.Path));
        var settings = new AppSettings { AnswerLanguage = AnswerLanguage.English, TranscriptFontSize = 21 };
        foreach (var store in new IPreferenceStore[] { file, new MemoryPreferenceStore() })
        {
            settings.Save(store); Assert.True(store.Contains("livecopilot.settings")); Assert.Equal(settings, AppSettings.Load(store));
            store.Set(AppSettings.DefaultsKey, Encoding.UTF8.GetBytes("damaged")); Assert.Equal(new AppSettings(), AppSettings.Load(store));
        }
    }
    [Theory]
    [InlineData("zh-Hant", true)] [InlineData("zh-TW", true)] [InlineData("zh-HK", true)] [InlineData("zh_MO", true)]
    [InlineData("en", false)] [InlineData("zh-CN", false)] [InlineData("zh-Hans-HK", false)]
    public void TraditionalLocaleClassification(string id, bool traditional) => Assert.Equal(traditional, AppLanguageExtensions.IsTraditional(id));
    [Fact] public void LocalizationPreservesUnknownContentAndFileNames()
    {
        Assert.Equal(407, L10n.Chinese.Count);
        Assert.Equal("歷史記錄", L10n.Text("History", AppLanguage.TraditionalChinese));
        Assert.Equal("設置", ServiceGuide.Text("Settings", "设置", AppLanguage.TraditionalChinese));
        Assert.Equal("我的简体文档和对话", L10n.Text("我的简体文档和对话", AppLanguage.TraditionalChinese));
        Assert.Equal("正在重建索引 简体文档.pdf", L10n.Text("Re-indexing 简体文档.pdf", AppLanguage.TraditionalChinese));
        Assert.Equal("API Key 已配置", L10n.Text("API key configured", AppLanguage.System, new TestLocale("zh-Hans")));
        Assert.Equal("API key configured", L10n.Text("API key configured", AppLanguage.System, new TestLocale("en-US")));
        Assert.Contains("第 2 頁", Fixtures.Chunk().DisplayLabel(AppLanguage.TraditionalChinese));
        Assert.Contains("性能报告", Fixtures.Chunk().DisplayLabel(AppLanguage.TraditionalChinese));
        Assert.Equal("zh-Hant", AppLanguage.System.Locale(new TestLocale("zh-TW")).Name);
        Assert.Contains("已就绪", L10n.Text("Listening · Zipformer ready", AppLanguage.SimplifiedChinese));
    }
    [Theory]
    [InlineData(429, "insufficient_quota", ServiceHTTPFailureKind.Billing)]
    [InlineData(400, "Arrearage", ServiceHTTPFailureKind.Billing)]
    [InlineData(429, "rate_limit_exceeded", ServiceHTTPFailureKind.RateLimit)]
    [InlineData(400, "expired_api_key", ServiceHTTPFailureKind.Authentication)]
    [InlineData(401, "insufficient_quota", ServiceHTTPFailureKind.Authentication)]
    [InlineData(400, "model_not_found", ServiceHTTPFailureKind.Model)]
    [InlineData(403, "unknown", ServiceHTTPFailureKind.Permission)]
    [InlineData(422, "unsupported_parameter", ServiceHTTPFailureKind.Parameters)]
    [InlineData(503, "server_error", ServiceHTTPFailureKind.Service)]
    public void HttpFailuresOnlyExposeSafeCategories(int status, string code, ServiceHTTPFailureKind kind)
    {
        var error = new ServiceHTTPFailure(status, Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { error = new { code, message = "private-secret-and-transcript" } })));
        Assert.Equal(kind, error.Kind); Assert.Equal(kind, ServiceHTTPFailure.KindFromSafeMessage(error.Message));
        Assert.DoesNotContain("private", error.Message); Assert.DoesNotContain("private", L10n.Text(error.Message, AppLanguage.SimplifiedChinese));
        Assert.Contains($"HTTP {status}", L10n.Text(error.Message, AppLanguage.SimplifiedChinese));
    }
    [Fact] public void HttpFailuresIgnoreArbitraryProseAndMalformedBodies()
    {
        Assert.Equal(ServiceHTTPFailureKind.Permission, new ServiceHTTPFailure(403, Encoding.UTF8.GetBytes("""{"error":{"message":"expired_api_key insufficient_quota"}}""")).Kind);
        Assert.Equal(ServiceHTTPFailureKind.Service, new ServiceHTTPFailure(500, Encoding.UTF8.GetBytes("not json")).Kind);
        Assert.Null(ServiceHTTPFailure.KindFromSafeMessage("insufficient_quota"));
    }
    [Fact] public void OnboardingNavigationAndLegacyOptionalFields()
    {
        var store = new MemoryPreferenceStore(); var state = OnboardingState.Load(store, false);
        Assert.True(state.ShouldPresent); Assert.False(state.LocalSetupReviewed);
        for (var i = 0; i < 10; i++) state.Advance(); Assert.Equal(OnboardingStep.Ready, state.Step);
        state.Disposition = OnboardingDisposition.Completed; state.Save(store);
        Assert.Equal(state, OnboardingState.Load(store, false)); state.Reopen(); Assert.Equal(OnboardingStep.Language, state.Step);
        state.Back(); Assert.Equal(OnboardingStep.Language, state.Step);
        var old = CoreJson.Decode<OnboardingState>("""{"version":1,"step":2,"disposition":"deferred","prefersTyping":false,"wantsKnowledge":true}""");
        Assert.Null(old.LocalSetupReviewed); Assert.Null(old.KnowledgeRequested); old.Reopen(); Assert.Equal(OnboardingStep.Models, old.Step);
        store.Set(OnboardingState.DefaultsKey, Encoding.UTF8.GetBytes("broken")); store.Set(AppSettings.DefaultsKey, []);
        Assert.Equal(OnboardingDisposition.ExistingUser, OnboardingState.Load(store, false).Disposition);
    }
    [Theory]
    [InlineData("v1.2", "v1.2.0")] [InlineData(" V2.3.4-rc.2+abc ", "v2.3.4")]
    public void ReleaseVersionParsesPublicIdentity(string input, string display)
    { var version = Assert.IsType<ReleaseVersion>(ReleaseVersion.Parse(input)); Assert.Equal(display, version.Display); Assert.Equal(version, CoreJson.Decode<ReleaseVersion>(CoreJson.Encode(version))); }
    [Theory] [InlineData("20261012.1")] [InlineData("1.02.3")] [InlineData("build-42")] [InlineData("1")] [InlineData("1.2.3.4")]
    public void ReleaseVersionRejectsBuildStamps(string input) => Assert.Null(ReleaseVersion.Parse(input));
    [Fact] public void ReleaseOrderingAndNotesSanitization()
    {
        Assert.True(ReleaseVersion.Parse("1.2.0-rc.9")! < ReleaseVersion.Parse("1.2.0-rc.10")!);
        Assert.True(ReleaseVersion.Parse("1.2-rc")! < ReleaseVersion.Parse("1.2")!);
        Assert.Equal("Hello & world\nNext", UpdateRelease.PlainNotes("<script>bad</script><p>Hello &amp; world</p><br/>Next"));
    }
    [Fact] public void RecognitionAndTraceContainOnlyTiming()
    {
        var stats = new RecognitionStats(); Assert.Null(stats.FinalLagMeanMs);
        stats.NoteBacklog(100); stats.NoteBacklog(50); stats.NoteFinal(1500, 1000); stats.NoteFinal(2000, 2100);
        Assert.Equal(100, stats.BacklogMaxMs); Assert.Equal(250, stats.FinalLagMeanMs); Assert.Equal(500, stats.FinalLagMaxMs);
        Assert.Equal(RecognitionFailure.SpeechBehind, RecognitionStats.OverflowFailure(true));
        var trace = new PipelineTrace(origin: 100); trace.Mark(PipelineStage.FirstToken, 101.5);
        Assert.Equal(1500, trace.Milliseconds(PipelineStage.FirstToken)); Assert.Contains("elapsed_ms=1500", trace.LogLine(PipelineStage.FirstToken));
        var copy = trace with { }; copy.Mark(PipelineStage.AnswerComplete, 102); Assert.Null(trace.Milliseconds(PipelineStage.AnswerComplete));
        var backlog = new AudioBacklog(); Assert.Equal(5, backlog.Add(5)); backlog.RemoveOldest(); backlog.RemoveOldest(); Assert.Equal(7, backlog.Add(7));
    }
    [Fact] public void PureLayoutFitsNegativeOriginDisplaysAndAllocatesPanes()
    {
        var visible = new LayoutRect(-1440, -200, 1440, 860); var frame = new LayoutRect(-510, 350, 480, 280);
        var fitted = OverlayLayout.Fitted(frame, 9999, visible, true);
        Assert.Equal(frame.MaxY, fitted.MaxY); Assert.Equal(visible.MaxX - 12, fitted.MaxX); Assert.True(fitted.Y >= visible.Y + 12);
        Assert.Equal((76d, 28d), OverlayLayout.Panes(104, 76, 28, true));
        foreach (var room in new[] { 0d, 20, 80, 400, 900 }) { var panes = OverlayLayout.Panes(room, 145, 2000, true); Assert.InRange(panes.Transcript + panes.Answer, 0, room); }
        var hover = new OverlayHoverState(); Assert.False(hover.ShouldReveal(true, 0)); Assert.True(hover.ShouldReveal(true, 0.2));
        Assert.False(hover.ShouldHide(false, true, 1)); Assert.False(hover.ShouldHide(false, false, 2)); Assert.True(hover.ShouldHide(false, false, 3));
    }
}
