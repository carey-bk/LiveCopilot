using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using LiveCopilot.Core;
using LiveCopilot.LocalInference;
using LiveCopilot.Platform.Lifecycle;
using LiveCopilot.Platform.Onboarding;
using LiveCopilot.Platform.Settings;

namespace LiveCopilot.App;

public partial class OnboardingWindow : Window
{
    private readonly OnboardingViewModel viewModel;
    private readonly LocalModelManager models = new();
    private readonly WindowShutdownCoordinator shutdown;
    private readonly HashSet<PasswordBox> passwords = [];
    private readonly Dictionary<CredentialEditor, Action> resetHandlers = [];
    private bool clearing;
    public ModelCardViewModel ZipformerModel { get; }
    public ModelCardViewModel ParaformerModel { get; }
    public ModelCardViewModel EmbeddingModelCard { get; }
    public OnboardingWindow(OnboardingViewModel viewModel)
    {
        this.viewModel = viewModel;
        ZipformerModel = new(LocalModelKind.TerminologySpeech, models);
        ParaformerModel = new(LocalModelKind.StreamingSpeech, models);
        EmbeddingModelCard = new(LocalModelKind.Embedding, models);
        InitializeComponent();
        DataContext = viewModel;
        shutdown = new([
            () => { IsEnabled = false; viewModel.Stop(); ClearPasswords(); return Task.CompletedTask; },
            () => models.DisposeAsync().AsTask()
        ], action => Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, action), Close);
        viewModel.Finished += Close;
        viewModel.Settings.PropertyChanged += SettingsChanged;
        viewModel.PropertyChanged += GuideChanged;
        foreach (var credential in viewModel.Settings.Credentials)
        {
            Action reset = () => ClearPasswords(credential);
            resetHandlers.Add(credential, reset);
            credential.InputResetRequested += reset;
        }
        models.Changed += ModelChanged;
        Closing += (_, e) =>
        {
            if (shutdown.IsClosing || shutdown.IsClosed) return;
            e.Cancel = true; _ = PrepareForShutdownAsync();
        };
        Closed += (_, _) =>
        {
            _ = PrepareForShutdownAsync(); shutdown.NotifyClosed();
            viewModel.Finished -= Close;
            viewModel.Settings.PropertyChanged -= SettingsChanged;
            viewModel.PropertyChanged -= GuideChanged;
            models.Changed -= ModelChanged;
            foreach (var (credential, handler) in resetHandlers) credential.InputResetRequested -= handler;
            resetHandlers.Clear(); passwords.Clear();
        };
        Loaded += (_, _) => RefreshStatus();
        RefreshCredential();
        ShortcutHint.Text = string.Join("\n", viewModel.Settings.Shortcuts.Select(s => $"{s.Display}  {s.Label}"));
    }
    public Task PrepareForShutdownAsync() => shutdown.RequestCloseAsync();
    private void SettingsChanged(object? sender, PropertyChangedEventArgs e) { RefreshCredential(); RefreshStatus(); }
    private void GuideChanged(object? sender, PropertyChangedEventArgs e) { if (e.PropertyName is "" or nameof(OnboardingViewModel.Step)) RefreshStatus(); }
    private void RefreshCredential()
    {
        var settings = viewModel.Settings;
        SelectedCredential.Content = settings.ReasoningService switch
        {
            ReasoningService.SharedOpenAI => settings.OpenAICredential,
            ReasoningService.SeparateOpenAI => settings.SeparateOpenAICredential,
            ReasoningService.DeepSeek => settings.DeepSeekCredential,
            ReasoningService.Compatible => settings.CompatibleCredential,
            _ => settings.PresetCredential
        };
    }
    private void RefreshStatus()
    {
        var settings = viewModel.Settings;
        ReadySpeech.Text = NativeRuntimeSupport.SpeechUnavailable ?? (settings.ListeningService switch
        {
            ListeningService.Zipformer => ZipformerModel.Status,
            ListeningService.Paraformer => ParaformerModel.Status,
            _ => "当前引擎在 Windows 尚不可用，请选择本地语音引擎。"
        });
        ReadyAnalysis.Text = (SelectedCredential.Content as CredentialEditor)?.Status + " · 连接尚未测试";
        ReadyEmbedding.Text = settings.EmbeddingService == EmbeddingService.Local
            ? NativeRuntimeSupport.EmbeddingUnavailable ?? EmbeddingModelCard.Status : "OpenAI · 导入时验证密钥与服务";
    }
    private void ModelChanged(LocalModelKind _)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (shutdown.IsRequested) return;
            ZipformerModel.Refresh(); ParaformerModel.Refresh(); EmbeddingModelCard.Refresh(); RefreshStatus();
        });
    }
    private async void DownloadModel(object sender, RoutedEventArgs e)
    {
        if (!shutdown.IsRequested && sender is Button { DataContext: ModelCardViewModel card } && card.CanDownload) await models.RetryAsync(card.Kind);
    }
    private void CancelModel(object sender, RoutedEventArgs e)
    {
        if (!shutdown.IsRequested && sender is Button { DataContext: ModelCardViewModel card }) models.Cancel(card.Kind);
    }
    private async void VerifyModel(object sender, RoutedEventArgs e)
    {
        if (!shutdown.IsRequested && sender is Button { DataContext: ModelCardViewModel card } && card.CanVerify) await models.VerifyAsync(card.Kind);
    }
    private async void DeleteModel(object sender, RoutedEventArgs e)
    {
        if (!shutdown.IsRequested && sender is Button { DataContext: ModelCardViewModel card } && card.CanDelete) await models.DeleteAsync(card.Kind);
    }
    private void CredentialLoaded(object sender, RoutedEventArgs e) { if (sender is PasswordBox box) passwords.Add(box); }
    private void CredentialChanged(object sender, RoutedEventArgs e)
    {
        if (!clearing && sender is PasswordBox { DataContext: CredentialEditor credential } box) credential.Stage(box.Password);
    }
    private void ClearPasswords(CredentialEditor? credential = null)
    {
        clearing = true;
        try { foreach (var box in passwords) if (credential is null || ReferenceEquals(box.DataContext, credential)) box.Clear(); }
        finally { clearing = false; }
    }
    private void OpenMicrophonePrivacy(object sender, RoutedEventArgs e)
    {
        if (AppRuntime.IsSmoke) { PermissionMessage.Text = "冒烟模式：不打开外部系统设置。"; return; }
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch (Exception) { PermissionMessage.Text = "无法打开设置，请手动打开 Windows 设置 → 隐私 → 麦克风。"; }
    }
}
