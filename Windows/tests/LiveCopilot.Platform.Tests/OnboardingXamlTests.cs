using System.Xml.Linq;
using LiveCopilot.Platform.Onboarding;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    [Fact]
    public void OnboardingContextMatchesConstructorAndAllSixPagesAreAudited()
    {
        var source = CSharpSyntaxTree.ParseText(ReadResource("AppSources/OnboardingWindow.xaml.cs")).GetRoot();
        var constructor = source.DescendantNodes().OfType<ConstructorDeclarationSyntax>().Single();
        Assert.Contains(constructor.ParameterList.Parameters, p => p.Type?.ToString() == nameof(OnboardingViewModel) && p.Identifier.Text == "viewModel");
        Assert.Contains(constructor.DescendantNodes().OfType<AssignmentExpressionSyntax>(), a => a.Left.ToString() == "DataContext" && a.Right.ToString() == "viewModel");
        var document = Load("XamlSources/LiveCopilot.App/OnboardingWindow.xaml");
        Assert.Empty(Inspect(document, "OnboardingWindow.xaml"));
        foreach (var step in new[] { "IsLanguage", "IsScenario", "IsModels", "IsAnalysis", "IsPermissions", "IsReady" })
            Assert.Contains(document.Descendants(), e => ((string?)e.Attribute("Visibility"))?.StartsWith("{Binding " + step + ",", StringComparison.Ordinal) == true);
        var question = document.Descendants(Presentation + "ComboBox").First();
        question.SetAttributeValue("SelectedValue", "{Binding Step}");
        Assert.Contains("OnboardingViewModel.Step is read-only", Assert.Single(Inspect(document, "OnboardingWindow.xaml")));
    }
}
