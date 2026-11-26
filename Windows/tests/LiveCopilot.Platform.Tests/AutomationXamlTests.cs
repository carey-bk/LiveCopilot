using System.Xml.Linq;

namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    [Theory]
    [InlineData("HistoryRefresh", "RefreshCommand")]
    [InlineData("HistoryOpen", "OpenCommand")]
    [InlineData("HistoryBack", "BackCommand")]
    [InlineData("HistoryDelete", "DeleteCommand")]
    [InlineData("HistoryDetailDelete", "DeleteCommand")]
    [InlineData("HistoryClearAll", "ClearCommand")]
    [InlineData("HistoryExportMarkdown", "ExportMarkdownCommand")]
    [InlineData("HistoryDetailExportMarkdown", "ExportMarkdownCommand")]
    [InlineData("HistoryExportText", "ExportTextCommand")]
    [InlineData("HistoryDetailExportText", "ExportTextCommand")]
    public void HistoryActionsHaveStableIdsAndUseHistoryContext(string id, string command)
    {
        var button = Load(SettingsXaml).Descendants(Presentation + "Button")
            .Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == id);
        Assert.Equal(command, ParseBinding(button.Attribute("Command")!.Value)["Path"]);
        Assert.Equal("HistoryViewModel", ContextFor(button));
        Assert.DoesNotContain(button.Ancestors(), e => e.Name.LocalName == "ControlTemplate");
    }

    [Fact]
    public void HistoryInputsAndTimelineHaveAutomationTargetsAndOneWayReadOnlyText()
    {
        var document = Load(SettingsXaml);
        var history = document.Descendants().Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == "HistoryContent");
        foreach (var control in history.Descendants().Where(e => e.Name.LocalName is "Button" or "TextBox" or "ListBox" or "TextBlock"))
            Assert.NotNull(control.Attribute("AutomationProperties.AutomationId"));
        foreach (var id in new[] { "HistorySearch", "HistoryList", "HistoryTimeline", "HistoryDetailTitle", "HistoryLoadNotice", "HistoryStatus" })
            Assert.Single(history.Descendants(), e => (string?)e.Attribute("AutomationProperties.AutomationId") == id);
        foreach (var id in new[] { "ContentId", "SourcesId" })
        {
            var text = history.Descendants(Presentation + "TextBox").Single(e =>
                (string?)e.Attribute("AutomationProperties.AutomationId") == "{Binding " + id + "}");
            Assert.Equal("OneWay", ParseBinding(text.Attribute("Text")!.Value)["Mode"]);
        }
        var itemIds = history.Descendants(Presentation + "Setter").Where(e => (string?)e.Attribute("Property") == "AutomationProperties.AutomationId");
        Assert.Equal(2, itemIds.Count());
        Assert.All(itemIds, e => Assert.Equal("{Binding AutomationId}", (string?)e.Attribute("Value")));
    }

    [Fact]
    public void AutomationIdsAreNotHiddenInControlTemplateChrome()
    {
        var resources = Assembly.GetManifestResourceNames()
            .Where(name => Normalize(name).StartsWith("XamlSources/", StringComparison.Ordinal)).ToArray();
        Assert.NotEmpty(resources);
        // Cover all IDs, including bindings used by model cards and credentials,
        // so new smoke targets cannot silently bypass a hand-maintained allowlist.
        foreach (var resource in resources)
            Assert.Empty(TemplateAutomationIds(Load(resource)));
    }

    [Theory]
    [InlineData("SaveSettings", "SaveCommand")]
    [InlineData("CancelSettings", "CancelCommand")]
    public void SettingsActionsAreWindowContentOutsideTabsAndScrolling(string id, string command)
    {
        var document = Load(SettingsXaml);
        var button = document.Descendants(Presentation + "Button")
            .Single(element => (string?)element.Attribute("AutomationProperties.AutomationId") == id);
        Assert.Equal(command, ParseBinding(button.Attribute("Command")!.Value)["Path"]);
        Assert.DoesNotContain(button.Ancestors(), element =>
            element.Name == Presentation + "ControlTemplate" ||
            element.Name == Presentation + "TabControl" ||
            element.Name == Presentation + "ScrollViewer");
        Assert.Contains(button.Ancestors(Presentation + "Grid"), grid => grid.Parent == document.Root);
    }

    [Theory]
    [InlineData("SaveSettings")]
    [InlineData("CancelSettings")]
    public void MovingSettingsActionBackIntoTabTemplateIsDetected(string id)
    {
        var document = Load(SettingsXaml);
        var button = document.Descendants(Presentation + "Button")
            .Single(element => (string?)element.Attribute("AutomationProperties.AutomationId") == id);
        button.Remove();
        var template = document.Descendants(Presentation + "TabControl")
            .Single(element => (string?)element.Attribute(Xaml + "Name") == "Pages")
            .Element(Presentation + "TabControl.Template")!.Element(Presentation + "ControlTemplate")!;
        template.Element(Presentation + "Grid")!.Add(button);
        Assert.Equal(id, Assert.Single(TemplateAutomationIds(document)));
    }

    private static IEnumerable<string> TemplateAutomationIds(XDocument document) =>
        document.Descendants().Where(element => element.Ancestors(Presentation + "ControlTemplate").Any())
            .SelectMany(element => element.Attributes()
                .Where(attribute => attribute.Name.LocalName == "AutomationProperties.AutomationId")
                .Select(attribute => attribute.Value));
}
