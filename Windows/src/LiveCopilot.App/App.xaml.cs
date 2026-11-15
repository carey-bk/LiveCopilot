using System.IO;
using LiveCopilot.Core;
using Velopack;

namespace LiveCopilot.App;

public partial class App : System.Windows.Application
{
    [STAThread]
    private static int Main()
    {
        // Installer lifecycle commands must run before any WPF window or service exists.
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        var app = new App();
        app.InitializeComponent();
        var exitCode = app.Run();
        if (AppRuntime.IsSmoke && Directory.Exists(AppPaths.DataDirectory))
            Directory.Delete(AppPaths.DataDirectory, recursive: true);
        return exitCode;
    }
}
