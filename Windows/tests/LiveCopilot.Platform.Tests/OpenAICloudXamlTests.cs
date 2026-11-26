namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    [Theory]
    [InlineData("OpenAILivePrice")]
    [InlineData("OpenAILiveCard")]
    [InlineData("OpenAILiveAutomatic")]
    [InlineData("OpenAILiveKeyHint")]
    [InlineData("OpenAILiveLanguageHint")]
    [InlineData("OpenAILiveCloudTag")]
    [InlineData("OpenAILiveMultilingualTag")]
    [InlineData("OpenAILiveUsageTag")]
    [InlineData("ListeningServiceHint")]
    [InlineData("ContinuousQuestionPolicyChoice")]
    public void CloudControlsHaveUniqueStableAutomationIdsOutsideTemplates(string id)
    {
        var target = Assert.Single(Load(SettingsXaml).Descendants(), e => (string?)e.Attribute("AutomationProperties.AutomationId") == id);
        Assert.DoesNotContain(target.Ancestors(), e => e.Name.LocalName == "ControlTemplate");
    }
    [Fact]
    public void CloudPageKeepsLocalDownloadCardsOutOfFirstViewportAndBindsSharedAutomaticPreference()
    {
        var document = Load(SettingsXaml);
        Assert.Equal("980", document.Root!.Attribute("Width")!.Value);
        Assert.Equal("680", document.Root!.Attribute("Height")!.Value);
        foreach (var name in new[] { "ZipformerModel", "ParaformerModel" })
        {
            var card = document.Descendants(Presentation + "ContentControl").Single(e =>
                ((string?)e.Attribute("Content"))?.Contains(name, StringComparison.Ordinal) == true);
            Assert.Contains(card.Ancestors(), e => (string?)e.Attribute("Visibility") == "{Binding IsLocalListening, Converter={StaticResource Visible}}");
        }
        var automatic = document.Descendants().Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == "OpenAILiveAutomatic");
        Assert.Equal("{Binding AutomaticSuggestions}", automatic.Attribute("IsChecked")!.Value);
        Assert.DoesNotContain(automatic.Ancestors(), e => (string?)e.Attribute("IsEnabled") == "False");
        var price = document.Descendants().Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == "OpenAILivePrice");
        Assert.Equal("{Binding LivePrice}", price.Attribute("Text")!.Value);
        var onboarding = Load("XamlSources/LiveCopilot.App/OnboardingWindow.xaml");
        var choice = Assert.Single(onboarding.Descendants(), e => (string?)e.Attribute("AutomationProperties.AutomationId") == "OnboardingListeningServiceChoice");
        Assert.Equal("{Binding Settings.ListeningServices}", choice.Attribute("ItemsSource")!.Value);
        Assert.DoesNotContain(choice.Ancestors(), e => e.Name.LocalName == "ControlTemplate");
        Assert.Empty(Inspect(document, SettingsXaml));
    }
}
