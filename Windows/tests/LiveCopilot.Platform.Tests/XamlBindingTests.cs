using System.IO;
using System.Reflection;
using System.Xml;
using System.Xml.Linq;
using LiveCopilot.Platform.Settings;
using LiveCopilot.Platform.Overlay;
using LiveCopilot.Platform.History;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace LiveCopilot.Platform.Tests;

public sealed partial class XamlBindingTests
{
    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
    private static readonly XNamespace Presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private const string SettingsXaml = "XamlSources/LiveCopilot.App/SettingsWindow.xaml";
    private static readonly Assembly Assembly = typeof(XamlBindingTests).Assembly;
    private static readonly IReadOnlyDictionary<string, bool> ModelProperties = SourceProperties(
        ReadResource("AppSources/ModelCardViewModel.cs"), "ModelCardViewModel");

    [Fact]
    public void AllSourceXamlWriteBackBindingsTargetWritableProperties()
    {
        var resources = Assembly.GetManifestResourceNames()
            .Where(name => Normalize(name).StartsWith("XamlSources/", StringComparison.Ordinal)).ToArray();
        Assert.NotEmpty(resources);
        Assert.Contains(resources, name => Normalize(name) == SettingsXaml);
        Assert.Empty(resources.SelectMany(name => Inspect(Load(name), Normalize(name))));
    }

    [Theory]
    [InlineData("")]
    [InlineData(", Mode=Default")]
    [InlineData(", Mode=TwoWay")]
    [InlineData(", Mode=OneWayToSource")]
    public void RealModelCardRegressionIsDetected(string mode)
    {
        var document = Load(SettingsXaml);
        var progress = document.Descendants(Presentation + "ProgressBar")
            .Single(element => element.Attribute("Value") is not null);
        progress.SetAttributeValue("Value", "{Binding Path=Progress" + mode + "}");
        var error = Assert.Single(Inspect(document, SettingsXaml));
        Assert.Contains("ProgressBar.Value", error);
        Assert.Contains("ModelCardViewModel.Progress is read-only", error);
    }

    [Theory]
    [InlineData("ProgressBar", "Value")]
    [InlineData("Slider", "Value")]
    [InlineData("ScrollBar", "Value")]
    [InlineData("TextBox", "Text")]
    [InlineData("CheckBox", "IsChecked")]
    [InlineData("ToggleButton", "IsChecked")]
    [InlineData("RadioButton", "IsChecked")]
    [InlineData("ComboBox", "SelectedItem")]
    [InlineData("ListBox", "SelectedValue")]
    [InlineData("ListView", "SelectedIndex")]
    [InlineData("TabControl", "SelectedIndex")]
    [InlineData("Selector", "SelectedItem")]
    [InlineData("PasswordBox", "PasswordHelper.BoundPassword")]
    public void DefaultTwoWayControlFamiliesRejectReadOnlySources(string control, string property)
    {
        var document = Fixture(new XElement(Presentation + control,
            new XAttribute(property, "{Binding ValidationSummary}")));
        Assert.Contains("SettingsViewModel.ValidationSummary is read-only", Assert.Single(Inspect(document, "fixture")));
    }

    [Theory]
    [InlineData("OneWay")]
    [InlineData("OneTime")]
    public void ReadOnlySourcesAcceptExplicitReadModes(string mode)
    {
        Assert.Empty(Inspect(Fixture(new XElement(Presentation + "TextBox",
            new XAttribute("Text", "{Binding Path=ValidationSummary, Mode=" + mode + "}"))), "fixture"));
    }

    [Fact]
    public void WritableSettingsAndOneWayTextBlocksAreAccepted()
    {
        Assert.Empty(Inspect(Fixture(new XElement(Presentation + "StackPanel",
            new XElement(Presentation + "TextBox", new XAttribute("Text", "{Binding AdditionalAnswerInstructions}")),
            new XElement(Presentation + "CheckBox", new XAttribute("IsChecked", "{Binding AutomaticSuggestions}")),
            new XElement(Presentation + "ComboBox", new XAttribute("SelectedValue", "{Binding Language, Mode=TwoWay}")),
            new XElement(Presentation + "TextBlock", new XAttribute("Text", "{Binding ValidationSummary}")))), "fixture"));
    }

    [Fact]
    public void PropertyElementBindingsAndStyleSettersAreInspected()
    {
        Assert.Equal(2, Inspect(Fixture(new XElement(Presentation + "StackPanel",
            new XElement(Presentation + "Slider", new XElement(Presentation + "Slider.Value",
                new XElement(Presentation + "Binding", new XAttribute("Path", "ValidationSummary")))),
            new XElement(Presentation + "Style", new XAttribute("TargetType", "TextBox"),
                new XElement(Presentation + "Setter", new XAttribute("Property", "Text"),
                    new XAttribute("Value", "{Binding Status}"))))), "fixture").Count);
    }

    [Theory]
    [InlineData("MissingProperty")]
    [InlineData("Status")]
    [InlineData("OpenAICredential.Status")]
    public void MissingPropertiesAndNonPublicSettersCannotSilentlyPass(string path)
    {
        Assert.Single(Inspect(Fixture(new XElement(Presentation + "TextBox",
            new XAttribute("Text", "{Binding " + path + "}"))), "fixture"));
    }

    [Fact]
    public void UnknownContextsRequireAnExplicitAuditMapping()
    {
        var document = Fixture(new XElement(Presentation + "DataTemplate", new XAttribute(Xaml + "Key", "NewTemplate"),
            new XElement(Presentation + "TextBox", new XAttribute("Text", "{Binding AdditionalAnswerInstructions}"))));
        Assert.Contains("Unmapped DataTemplate", Assert.Single(Inspect(document, "fixture")));
    }

    [Fact]
    public void SourceInspectionDistinguishesPublicSettersFromGetOnlyPrivateAndInitAccessors()
    {
        var properties = SourceProperties("""
            public class Sample {
                public double Expression => 0;
                public double Getter { get; }
                public double PrivateSetter { get; private set; }
                public double Initializer { get; init; }
                public double Writable { get; set; }
                public double ExpressionSetter { get => 0; set => Use(value); }
            }
            """, "Sample");
        Assert.Equal(["ExpressionSetter", "Writable"], properties.Where(pair => pair.Value).Select(pair => pair.Key).Order());
        Assert.False(ModelProperties["Progress"]);
    }

    [Fact]
    public void ContextMappingsMatchSettingsWindowCodeAndTemplateConsumers()
    {
        // These contexts are assigned in code, not declared as XAML DataType. Check the mapping
        // against the real constructor and each ContentControl to avoid stale test-only models.
        var source = CSharpSyntaxTree.ParseText(ReadResource("AppSources/SettingsWindow.xaml.cs")).GetRoot();
        var constructor = source.DescendantNodes().OfType<ConstructorDeclarationSyntax>().Single();
        Assert.Contains(constructor.ParameterList.Parameters, parameter =>
            parameter.Identifier.Text == "viewModel" && parameter.Type?.ToString() == nameof(SettingsViewModel));
        Assert.Contains(constructor.DescendantNodes().OfType<AssignmentExpressionSyntax>(), assignment =>
            assignment.Left.ToString() == "DataContext" && assignment.Right.ToString() == "viewModel");
        var document = Load(SettingsXaml);
        var consumers = document.Descendants(Presentation + "ContentControl")
            .Where(element => (string?)element.Attribute("ContentTemplate") == "{StaticResource ModelCardTemplate}").ToArray();
        Assert.Equal(3, consumers.Length);
        foreach (var consumer in consumers)
        {
            var binding = ParseBinding(consumer.Attribute("Content")!.Value);
            Assert.Equal("SettingsRoot", binding["ElementName"]);
            Assert.Contains(source.DescendantNodes().OfType<PropertyDeclarationSyntax>(), property =>
                property.Identifier.Text == binding["Path"] && property.Type.ToString() == "ModelCardViewModel");
        }
    }

    [Fact]
    public void OverlayDataContextMappingMatchesRealConstructor()
    {
        var source = CSharpSyntaxTree.ParseText(ReadResource("AppSources/MainWindow.xaml.cs")).GetRoot();
        Assert.Contains(source.DescendantNodes().OfType<ObjectCreationExpressionSyntax>(), creation =>
            creation.Type.ToString() == nameof(OverlayViewModel));
        Assert.Contains(source.DescendantNodes().OfType<AssignmentExpressionSyntax>(), assignment =>
            assignment.Left.ToString() == "DataContext" && assignment.Right.ToString() == "viewModel");
        Assert.Contains(Load("XamlSources/LiveCopilot.App/MainWindow.xaml").Descendants(), element =>
            (string?)element.Attribute("Text") == "{Binding Question, UpdateSourceTrigger=PropertyChanged}");
    }

    [Fact]
    public void HistoryContextsAndAllBindingPathsMatchRealModelsAndWindow()
    {
        var document = Load(SettingsXaml);
        var history = document.Descendants().Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == "HistoryContent");
        Assert.Equal("{Binding History, ElementName=SettingsRoot}", (string?)history.Attribute("DataContext"));
        var source = CSharpSyntaxTree.ParseText(ReadResource("AppSources/SettingsWindow.xaml.cs")).GetRoot();
        Assert.Contains(source.DescendantNodes().OfType<PropertyDeclarationSyntax>(), p =>
            p.Identifier.Text == "History" && p.Type.ToString() == nameof(HistoryViewModel));
        Assert.Contains(source.DescendantNodes().OfType<AssignmentExpressionSyntax>(), a =>
            a.Left.ToString() == "History" && a.Right.ToString().Contains("historyDialogs", StringComparison.Ordinal));
        foreach (var element in history.DescendantsAndSelf())
            foreach (var attribute in element.Attributes().Where(a => a.Value.StartsWith("{Binding", StringComparison.Ordinal) && a.Name.LocalName != "DataContext"))
            {
                var path = ParseBinding(attribute.Value)["Path"];
                var type = ContextFor(element) switch
                {
                    nameof(HistorySessionRow) => typeof(HistorySessionRow),
                    nameof(HistoryEventRow) => typeof(HistoryEventRow),
                    nameof(HistoryViewModel) => typeof(HistoryViewModel),
                    var context => throw new InvalidOperationException("Unexpected history context: " + context)
                };
                foreach (var segment in path.Split('.'))
                    type = (type.GetProperty(segment) ?? throw new InvalidOperationException(type.Name + "." + segment)).PropertyType;
            }
    }

    [Fact]
    public void HistoryDetailTextCannotWriteBackToReadOnlyTimelineRows()
    {
        var document = Load(SettingsXaml);
        var content = document.Descendants(Presentation + "TextBox")
            .Single(e => (string?)e.Attribute("AutomationProperties.AutomationId") == "{Binding ContentId}");
        content.SetAttributeValue("Text", "{Binding Content}");
        Assert.Contains("HistoryEventRow.Content is read-only", Assert.Single(Inspect(document, SettingsXaml)));
    }

    private static List<string> Inspect(XDocument document, string file)
    {
        var errors = new List<string>();
        foreach (var element in document.Descendants())
        {
            foreach (var attribute in element.Attributes().Where(attribute => attribute.Value.StartsWith("{Binding", StringComparison.Ordinal)))
                Check(element, attribute.Name.LocalName, () => ParseBinding(attribute.Value));
            foreach (var property in element.Elements().Where(child => child.Name.LocalName.Contains('.')))
                foreach (var binding in property.Elements(Presentation + "Binding"))
                    Check(element, property.Name.LocalName, () => binding.Attributes().ToDictionary(a => a.Name.LocalName, a => a.Value));
        }
        return errors;

        void Check(XElement element, string property, Func<Dictionary<string, string>> readBinding)
        {
            var control = element.Name.LocalName;
            if (control == "Setter")
            {
                property = (string?)element.Attribute("Property") ?? "";
                control = (string?)element.Ancestors(Presentation + "Style").FirstOrDefault()?.Attribute("TargetType") ?? "";
                control = control.Replace("{x:Type ", "", StringComparison.Ordinal).TrimEnd('}');
            }
            property = property.Split('.').Last();
            var target = control + "." + property;
            try
            {
                var binding = readBinding();
                var mode = binding.GetValueOrDefault("Mode", "Default");
                if (mode is "OneWay" or "OneTime") return;
                if (mode == "Default" && !DefaultsToTwoWay(control, property)) return;
                if (mode is not ("Default" or "TwoWay" or "OneWayToSource")) throw new InvalidOperationException("Unknown binding mode: " + mode);
                // The ComboBox template writes its own public IsDropDownOpen DP, not a view model.
                if (control == "ToggleButton" && property == "IsChecked" &&
                    binding.GetValueOrDefault("RelativeSource") == "{RelativeSource TemplatedParent}" &&
                    binding.GetValueOrDefault("Path") == "IsDropDownOpen" &&
                    (string?)element.Ancestors(Presentation + "ControlTemplate").FirstOrDefault()?.Attribute("TargetType") == "ComboBox") return;
                if (binding.Keys.Any(key => key is "Source" or "RelativeSource" or "ElementName"))
                    throw new InvalidOperationException("Map the explicit binding source before using write-back");
                var context = ContextFor(element);
                var path = binding.GetValueOrDefault("Path", "");
                var writable = context == "ModelCardViewModel"
                    ? ModelProperties.TryGetValue(path, out var value) ? value : throw new InvalidOperationException("Unknown ModelCardViewModel property: " + path)
                    : IsWritable(context, path);
                if (!writable) throw new InvalidOperationException(context + "." + path + " is read-only; use Mode=OneWay/OneTime");
            }
            catch (InvalidOperationException exception)
            {
                errors.Add($"{file}:{((IXmlLineInfo)element).LineNumber} {target}: {exception.Message}");
            }
        }
    }

    private static bool DefaultsToTwoWay(string control, string property) => property switch
    {
        "Value" => control is "ProgressBar" or "Slider" or "ScrollBar" or "RangeBase",
        "Text" => control is "TextBox" or "ComboBox",
        "IsChecked" => control is "CheckBox" or "ToggleButton" or "RadioButton",
        "SelectedItem" or "SelectedValue" or "SelectedIndex" => control is "Selector" or "ComboBox" or "ListBox" or "ListView" or "TabControl" or "DataGrid",
        "IsSelected" => control is "ListBoxItem" or "ListViewItem" or "TabItem",
        "SelectedDate" => control is "DatePicker" or "Calendar",
        // Password itself is not a dependency property. Include attached password helpers so
        // adding one cannot introduce an unchecked write-back path; current inputs use events.
        _ => control == "PasswordBox" && property.Contains("Password", StringComparison.Ordinal)
    };

    private static string ContextFor(XElement element)
    {
        foreach (var ancestor in element.AncestorsAndSelf())
        {
            if (ancestor.Name.LocalName == "ListBox.ItemContainerStyle")
                return (string?)ancestor.Parent?.Attribute("ItemsSource") switch
                {
                    "{Binding Sessions}" => nameof(HistorySessionRow),
                    "{Binding Timeline}" => nameof(HistoryEventRow),
                    _ => throw new InvalidOperationException("Unmapped item container DataContext")
                };
            if ((string?)ancestor.Attribute("DataContext") == "{Binding History, ElementName=SettingsRoot}" &&
                (string?)ancestor.Attribute("AutomationProperties.AutomationId") == "HistoryContent") return nameof(HistoryViewModel);
            if (ancestor.Attribute("DataContext") is not null || ancestor.Elements().Any(child => child.Name.LocalName.EndsWith(".DataContext", StringComparison.Ordinal)))
                throw new InvalidOperationException("Map the local DataContext before using write-back");
            if (ancestor.Name.LocalName == "DataTemplate")
                return (string?)ancestor.Attribute(Xaml + "Key") switch
                {
                    "ModelCardTemplate" => "ModelCardViewModel",
                    "CredentialTemplate" => nameof(CredentialEditor),
                    null when (string?)ancestor.Parent?.Parent?.Attribute("ItemsSource") == "{Binding Shortcuts}" => nameof(ShortcutEditor),
                    null when (string?)ancestor.Parent?.Parent?.Attribute("ItemsSource") == "{Binding Sessions}" => nameof(HistorySessionRow),
                    null when (string?)ancestor.Parent?.Parent?.Attribute("ItemsSource") == "{Binding Timeline}" => nameof(HistoryEventRow),
                    _ => throw new InvalidOperationException("Unmapped DataTemplate DataContext")
                };
        }
        return (string?)element.Document?.Root?.Attribute(Xaml + "Class") switch
        {
            "LiveCopilot.App.SettingsWindow" => nameof(SettingsViewModel),
            "LiveCopilot.App.MainWindow" => nameof(OverlayViewModel),
            "LiveCopilot.App.OnboardingWindow" => "OnboardingViewModel",
            _ => throw new InvalidOperationException("Unmapped window DataContext")
        };
    }

    private static bool IsWritable(string context, string path)
    {
        var type = context switch
        {
            nameof(SettingsViewModel) => typeof(SettingsViewModel),
            nameof(OverlayViewModel) => typeof(OverlayViewModel),
            nameof(HistoryViewModel) => typeof(HistoryViewModel),
            nameof(HistorySessionRow) => typeof(HistorySessionRow),
            nameof(HistoryEventRow) => typeof(HistoryEventRow),
            "OnboardingViewModel" => typeof(SettingsViewModel).Assembly.GetType("LiveCopilot.Platform.Onboarding.OnboardingViewModel")
                ?? throw new InvalidOperationException("Missing onboarding view model"),
            nameof(CredentialEditor) => typeof(CredentialEditor),
            nameof(ShortcutEditor) => typeof(ShortcutEditor),
            _ => throw new InvalidOperationException("Unmapped source type: " + context)
        };
        PropertyInfo? property = null;
        foreach (var segment in path.Split('.'))
        {
            property = type.GetProperty(segment, BindingFlags.Public | BindingFlags.Instance)
                ?? throw new InvalidOperationException("Unknown property: " + type.Name + "." + segment);
            type = property.PropertyType;
        }
        return property?.SetMethod is { IsPublic: true } setter &&
            !setter.ReturnParameter.GetRequiredCustomModifiers().Contains(typeof(System.Runtime.CompilerServices.IsExternalInit));
    }

    private static IReadOnlyDictionary<string, bool> SourceProperties(string source, string className) =>
        CSharpSyntaxTree.ParseText(source).GetRoot().DescendantNodes().OfType<ClassDeclarationSyntax>()
            .Single(type => type.Identifier.Text == className).Members.OfType<PropertyDeclarationSyntax>()
            .Where(property => property.Modifiers.Any(modifier => modifier.IsKind(SyntaxKind.PublicKeyword)))
            .ToDictionary(property => property.Identifier.Text, property => property.AccessorList?.Accessors.Any(accessor =>
                accessor.IsKind(SyntaxKind.SetAccessorDeclaration) && accessor.Modifiers.Count == 0) == true);

    private static Dictionary<string, string> ParseBinding(string text)
    {
        if (text == "{Binding}") return new() { ["Path"] = "" };
        if (!text.StartsWith("{Binding ", StringComparison.Ordinal) || !text.EndsWith('}'))
            throw new InvalidOperationException("Unsupported binding syntax: " + text);
        var result = new Dictionary<string, string>();
        // Split only top-level commas (converters and formats can contain nested braces/quotes).
        var start = 9;
        var depth = 0;
        var quote = '\0';
        for (var i = start; i < text.Length; i++)
        {
            var character = text[i];
            if (quote != '\0') { if (character == quote) quote = '\0'; continue; }
            if (character is '\'' or '"') { quote = character; continue; }
            if (character == '{') depth++;
            if (i != text.Length - 1 && (character != ',' || depth != 0))
            {
                if (character == '}') depth--;
                continue;
            }
            var part = text[start..i].Trim();
            var equal = part.IndexOf('=');
            result.Add(equal < 0 ? "Path" : part[..equal].Trim(), (equal < 0 ? part : part[(equal + 1)..]).Trim().Trim('\'', '"'));
            start = i + 1;
        }
        return result;
    }

    private static XDocument Fixture(XElement child) => new(new XElement(Presentation + "Window",
        new XAttribute(Xaml + "Class", "LiveCopilot.App.SettingsWindow"), child));
    private static string Normalize(string name) => name.Replace('\\', '/');
    private static XDocument Load(string name) => XDocument.Parse(ReadResource(name), LoadOptions.SetLineInfo);
    private static string ReadResource(string name)
    {
        var actual = Assembly.GetManifestResourceNames().Single(resource => Normalize(resource) == Normalize(name));
        using var reader = new StreamReader(Assembly.GetManifestResourceStream(actual)!);
        return reader.ReadToEnd();
    }
}
