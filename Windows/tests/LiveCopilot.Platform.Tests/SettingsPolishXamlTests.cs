using LiveCopilot.Platform.Onboarding;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    [Fact]
    public void ServiceHeaderSelectionCannotTurnPageContentWhite()
    {
        var theme = Load("XamlSources/LiveCopilot.App/Resources/LightTheme.xaml");
        var tab = theme.Descendants(Presentation + "Style").Single(e => (string?)e.Attribute(Xaml + "Key") == "SegmentTab");
        Assert.DoesNotContain(tab.Descendants(Presentation + "Setter"), e => (string?)e.Attribute("Property") == "Foreground" && (string?)e.Attribute("Value") == "White");
        Assert.Contains(tab.Descendants(Presentation + "Setter"), e => (string?)e.Attribute("TargetName") == "HeaderContent" && (string?)e.Attribute("Property") == "TextElement.Foreground");
        var settings = Load(SettingsXaml);
        foreach (var service in new[] { "Speech", "Trigger", "Knowledge", "Analysis" })
            Assert.Contains(settings.Descendants(Presentation + "ScrollViewer"), e => (string?)e.Attribute("AutomationProperties.AutomationId") == service + "ServiceScroll" && (string?)e.Attribute("VerticalScrollBarVisibility") == "Auto");
    }
    [Fact]
    public void SegmentedBackgroundAndNewOnboardingSelectionsHaveWritableContexts()
    {
        var settings = Load(SettingsXaml);
        var background = settings.Descendants(Presentation + "ListBox").Single(e => (string?)e.Attribute("ItemsSource") == "{Binding Backgrounds}");
        Assert.True(IsWritable(nameof(SettingsViewModel), ParseBinding(background.Attribute("SelectedValue")!.Value)["Path"]));
        var onboarding = Load("XamlSources/LiveCopilot.App/OnboardingWindow.xaml");
        var usage = onboarding.Descendants(Presentation + "ListBox").Single(e => (string?)e.Attribute("ItemsSource") == "{Binding UsageChoices}");
        Assert.True(IsWritable(nameof(OnboardingViewModel), ParseBinding(usage.Attribute("SelectedValue")!.Value)["Path"]));
        var progress = onboarding.Descendants(Presentation + "ItemsControl").Single(e => (string?)e.Attribute("ItemsSource") == "{Binding Segments}");
        foreach (var trigger in progress.Descendants(Presentation + "DataTrigger"))
            Assert.NotNull(typeof(OnboardingProgressSegment).GetProperty(ParseBinding(trigger.Attribute("Binding")!.Value)["Path"]));
        foreach (var text in usage.Descendants(Presentation + "TextBlock"))
            Assert.NotNull(typeof(OnboardingUsageChoice).GetProperty(ParseBinding(text.Attribute("Text")!.Value)["Path"]));
        Assert.Empty(Inspect(onboarding, "OnboardingWindow.xaml"));
    }
}
