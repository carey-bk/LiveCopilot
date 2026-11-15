namespace LiveCopilot.Core.Tests;

public sealed class SettingsDefaultsTests
{
    [Fact] public void GeneralAndOverlayDefaultsMatchExistingPreferences()
    {
        var value = new AppSettings();
        Assert.Equal(AppLanguage.System, value.Language); Assert.Equal(AnswerLanguage.Auto, value.AnswerLanguage);
        Assert.Equal(ScenarioProfile.Interview, value.Scenario); Assert.True(value.AutomaticSuggestions);
        Assert.Equal(ContinuousQuestionPolicy.Smart, value.ContinuousQuestionPolicy); Assert.False(value.BilingualAnswers);
        Assert.Equal("", value.AdditionalAnswerInstructions); Assert.Equal(12, value.TranscriptFontSize); Assert.Equal(14, value.AnswerFontSize);
        Assert.True(value.OverlayAutoHeight); Assert.False(value.ExcludeOverlayFromCapture);
    }
    [Fact] public void ServiceAndKnowledgeDefaultsRemainCompatible()
    {
        var value = new AppSettings();
        Assert.Equal(ListeningService.Zipformer, value.ListeningService); Assert.Equal(LiveSpeechLanguage.Mixed, value.LiveSpeechLanguage);
        Assert.Equal(ReasoningService.SharedOpenAI, value.ReasoningService); Assert.Equal(AppSettings.DefaultReasoningModel, value.AnalysisModel);
        Assert.Equal(AnalysisThinking.Low, value.AnalysisThinking); Assert.Equal(KnowledgeMode.Hybrid, value.KnowledgeMode);
        Assert.Equal(EmbeddingService.OpenAI, value.EmbeddingService); Assert.Equal("text-embedding-3-small", value.EmbeddingModel);
        Assert.Equal(5, value.RetrievalCount); Assert.Equal("", value.CompatibleBaseURL); Assert.Equal("chat/completions", value.CompatiblePath);
    }
    [Theory] [InlineData(1, 99, 1, 11, 28, 3)] [InlineData(99, 1, 99, 28, 11, 8)] [InlineData(11, 28, 5, 11, 28, 5)]
    public void LoadingOlderOutOfRangePreferencesNormalizesOnceWithoutWriting(int transcript, int answer, int retrieval, int expectedTranscript, int expectedAnswer, int expectedRetrieval)
    {
        var preferences = new MemoryPreferenceStore(); var initial = new AppSettings { TranscriptFontSize = transcript, AnswerFontSize = answer, RetrievalCount = retrieval };
        initial.Save(preferences); var bytes = preferences.Get(AppSettings.DefaultsKey);
        var loaded = AppSettings.Load(preferences);
        Assert.Equal(expectedTranscript, loaded.TranscriptFontSize); Assert.Equal(expectedAnswer, loaded.AnswerFontSize); Assert.Equal(expectedRetrieval, loaded.RetrievalCount);
        Assert.Equal(bytes, preferences.Get(AppSettings.DefaultsKey));
    }
    [Fact] public void MissingPreferenceUsesDefaultsWithoutCreatingFile()
    { var preferences = new MemoryPreferenceStore(); Assert.Equal(new AppSettings(), AppSettings.Load(preferences)); Assert.False(preferences.Contains(AppSettings.DefaultsKey)); }
}
