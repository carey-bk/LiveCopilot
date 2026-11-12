namespace LiveCopilot.Core.Tests;

public sealed class AnswerPolicyTests
{
    [Theory]
    [InlineData("请用英文回答什么是缓存？", false)]
    [InlineData("Please answer in Chinese: what is caching?", true)]
    [InlineData("这个 API 的缓存怎么设计？", true)]
    [InlineData("What does “缓存优化” mean?", false)]
    [InlineData("How do you implement caching?", false)]
    public void AutomaticFallbackHonorsLanguageRequestAndMainClause(string question, bool chinese) => Assert.Equal(chinese, AnswerLanguage.Auto.LocalFallbackIsChinese(question));
    [Fact] public void ExplicitLanguageOverridesQuestionAndSupportsInjectedDetector()
    {
        Assert.True(AnswerLanguage.Chinese.LocalFallbackIsChinese("Please answer in English"));
        Assert.False(AnswerLanguage.English.LocalFallbackIsChinese("请用中文回答"));
        Assert.Contains("未找到", AnswerLanguage.Auto.MissingEvidence("这个 API 是什么？"));
        Assert.Contains("No relevant", AnswerLanguage.English.MissingEvidence("这个 API 是什么？"));
        Assert.True(AnswerLanguage.Auto.LocalFallbackIsChinese("ambiguous", new ChineseDetector()));
    }
    private sealed class ChineseDetector : ITextLanguageDetector { public bool IsChinese(string text) => true; }
    [Theory] [InlineData("Why?", true)] [InlineData("What about latency?", true)] [InlineData("那这个呢？", true)]
    [InlineData("Explain database indexing", false)] [InlineData("What is dependency injection?", false)]
    public void FollowupScopeDoesNotContaminateIndependentQuestions(string question, bool context)
    {
        Assert.Equal(context, QuestionScope.NeedsContext(question));
        var query = RetrievalQuery.Formulate(question, "method B with 128 samples", "Why choose method B?");
        Assert.Equal(context, query.Semantic.Contains("128")); Assert.Equal(context, query.Semantic.Contains("Previous question:"));
    }
    [Fact] public void CitationStreamingWithholdsPartialAndUnknownIds()
    {
        Assert.Equal("answer [S1] ", CitationPolicy.Sanitized("answer [S1] [S", 2));
        Assert.Equal("[S2]   ", CitationPolicy.Sanitized("[S2] [S99] [S0] [S999999999999999999999]", 2));
        Assert.Equal([1, 2], SuggestionParser.CitedIndices("[S2] [S1] [S2] [S0] [S99]", 2));
        var sections = SuggestionParser.Sections("## Suggested answer\nUse B.\n\n## Evidence & notes\n42 ms [S1]");
        Assert.Equal(2, sections.Count); Assert.Equal("Use B.", sections[0].Content);
        Assert.Equal("Plain partial answer", Assert.Single(SuggestionParser.Sections("Plain partial answer")).Content);
    }
    [Fact] public void AnswerModesKeepTaskLanguageStyleAndEvidenceBoundaries()
    {
        var request = new AnswerRequest(RetrievalQuery.Formulate("What is caching?", "old meeting"), "You: prior conversation", ScenarioProfile.Interview, [new(Fixtures.Chunk(), 1)]);
        Assert.Contains("HYBRID", request.Instructions); Assert.Contains("personal", request.Instructions); Assert.Contains("[S1]", request.Input);
        Assert.DoesNotContain("Retrieval intent:", request.Input);
        request.KnowledgeMode = KnowledgeMode.General; Assert.DoesNotContain("Synthetic cache hit", request.Input);
        request.KnowledgeMode = KnowledgeMode.KnowledgeBaseOnly; Assert.Contains("KNOWLEDGE BASE ONLY", request.Instructions);
        request.AnswerLanguage = AnswerLanguage.English; Assert.Contains("Response language override: English", request.Instructions);
        request.BilingualAnswers = true; request.AdditionalAnswerInstructions = "literal {knowledge} and {language}";
        Assert.Contains("literal {knowledge} and {language}", request.Instructions);
        var reply = request.Instructions; request.Mode = SuggestionMode.Recap; Assert.NotEqual(reply, request.Instructions);
        var recap = request.Instructions; request.Mode = SuggestionMode.FollowUp; Assert.NotEqual(recap, request.Instructions);
        request.TranslationText = "你好"; request.TranslationTarget = "English";
        Assert.Equal("你好", request.Input); Assert.DoesNotContain("You: prior conversation", request.Input);
        Assert.DoesNotContain("literal", request.Instructions);
    }
    [Fact] public void StyleLimitsCountGraphemesAndCasingRestoresTerms()
    {
        var request = new AnswerRequest(new("q", "s", "l"), "", ScenarioProfile.Interview, []) { AdditionalAnswerInstructions = string.Concat(Enumerable.Repeat("🧑‍💻", 4001)) };
        Assert.DoesNotContain(string.Concat(Enumerable.Repeat("🧑‍💻", 4001)), request.AnswerStyleInstructions);
        Assert.Equal("I use Python and the API. What about GitHub?", TranscriptCasing.Format("I USE PYTHON AND THE API. WHAT ABOUT GITHUB?"));
        Assert.Equal("Use Next.js with TypeScript", TranscriptCasing.Format("Use NEXT JS with TYPE SCRIPT", ["Next.js", "TypeScript"]));
    }
}
