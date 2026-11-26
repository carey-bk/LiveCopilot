using System.Diagnostics;
using System.IO;
using System.Text;
using LiveCopilot.Core;

namespace LiveCopilot.App;

// Only smoke runs opt in. Never serialize exception messages, Data, credentials or settings.
internal static class SmokeDiagnostics
{
    private static readonly object Gate = new();
    private static string? directory;

    public static void Initialize()
    {
        if (!AppRuntime.IsSmoke) return;
        directory = Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE_LOG_DIRECTORY");
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            Exception("AppDomain.UnhandledException", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) =>
            Exception("TaskScheduler.UnobservedTaskException", args.Exception);
        Event("app starting");
    }

    public static void Event(string stage) => Write("app-events.log", stage);

    public static void Exception(string stage, Exception? error)
    {
        if (!AppRuntime.IsSmoke) return;
        var diagnostic = stage + Environment.NewLine + DescribeException(error);
        Write("app-exceptions.log", diagnostic);
        // The driver redirects this to app-stderr.log, separately from its own stderr.
        try { Console.Error.WriteLine(diagnostic); }
        catch (IOException) { }
    }

    internal static string DescribeException(Exception? error)
    {
        var text = new StringBuilder();
        Append(error, 0);
        return text.ToString();

        void Append(Exception? current, int depth)
        {
            if (current is null || depth >= 8) return;
            text.AppendLine($"{current.GetType().FullName} (HRESULT 0x{current.HResult:X8})");
            // Method metadata and source line numbers are enough to locate the failure;
            // Exception.ToString()/Message may contain service URLs or API keys.
            foreach (var frame in new StackTrace(current, true).GetFrames())
            {
                var method = frame.GetMethod();
                text.AppendLine($"  at {method?.DeclaringType?.FullName}.{method?.Name} (line {frame.GetFileLineNumber()})");
            }
            if (current is AggregateException aggregate)
                foreach (var inner in aggregate.InnerExceptions) Append(inner, depth + 1);
            else Append(current.InnerException, depth + 1);
        }
    }

    private static void Write(string file, string text)
    {
        if (!AppRuntime.IsSmoke || string.IsNullOrWhiteSpace(directory)) return;
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, file), $"{DateTimeOffset.UtcNow:O} {text}{Environment.NewLine}");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            // Diagnostics must not replace the original exception or change crash behavior.
        }
    }
}
