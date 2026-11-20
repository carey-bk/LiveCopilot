using LiveCopilot.Platform.Overlay;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    [Fact]
    public void AllGuideBindingsResolveThroughTheRealOverlayDataContext()
    {
        var document = Load("XamlSources/LiveCopilot.App/MainWindow.xaml");
        var guide = document.Descendants(Presentation + "GroupBox").Single(e => (string?)e.Attribute(Xaml + "Name") == "OperationGuide");
        Assert.NotNull(typeof(OverlayViewModel).GetProperty("Guide"));
        var bindings = guide.DescendantsAndSelf().SelectMany(e => e.Attributes()).Where(a => a.Value.StartsWith("{Binding Guide.", StringComparison.Ordinal)).ToArray();
        Assert.True(bindings.Length >= 8);
        foreach (var binding in bindings)
        {
            var path = ParseBinding(binding.Value)["Path"].Split('.')[1];
            Assert.NotNull(typeof(OperationGuideViewModel).GetProperty(path));
        }
        Assert.Empty(Inspect(document, "MainWindow.xaml"));
        var source = CSharpSyntaxTree.ParseText(ReadResource("AppSources/MainWindow.xaml.cs")).GetRoot();
        var creation = source.DescendantNodes().OfType<ObjectCreationExpressionSyntax>().Single(e => e.Type.ToString() == nameof(OverlayViewModel));
        Assert.Contains(creation.ArgumentList!.Arguments, a => a.ToString() == "preferences");
    }
    [Fact]
    public void SessionButtonsAndIconsUseAuditedBindingsAndFontFallback()
    {
        var document = Load("XamlSources/LiveCopilot.App/MainWindow.xaml");
        foreach (var id in new[] { "ResetSession", "ToggleMicrophone" })
        {
            var button = document.Descendants(Presentation + "Button").Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == id);
            Assert.NotNull(typeof(OverlayViewModel).GetProperty(ParseBinding(button.Attribute("Command")!.Value)["Path"]));
        }
        var theme = Load("XamlSources/LiveCopilot.App/Resources/LightTheme.xaml");
        Assert.Equal("Segoe Fluent Icons, Segoe MDL2 Assets", theme.Descendants(Presentation + "FontFamily").Single(e => (string?)e.Attribute(Xaml + "Key") == "IconFont").Value);
    }
}
