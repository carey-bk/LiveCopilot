param(
    [string]$AppPath = (Join-Path $PSScriptRoot '../artifacts/package/publish/win-x64/LiveCopilot.App.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/smoke')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { Write-Host 'SKIP: UI smoke requires Windows.'; exit 0 }
$driver = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../tests/LiveCopilot.App.Smoke/bin/Release/net8.0-windows/LiveCopilot.App.Smoke.exe'))
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path $OutputDirectory) { throw 'Smoke requires a fresh output directory.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$info = [Diagnostics.ProcessStartInfo]::new($driver)
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.ArgumentList.Add([IO.Path]::GetFullPath($AppPath))
$info.ArgumentList.Add($OutputDirectory)
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
try {
    # Independent watchdog also catches a hung UIAutomation/PrintWindow native call.
    if (-not $process.WaitForExit(150000)) {
        'Smoke exceeded the 150-second watchdog.' | Set-Content (Join-Path $OutputDirectory 'watchdog.txt') -Encoding utf8
        # Capture before killing the app, even when the driver's UIA thread is stuck.
        try {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $bounds = [Windows.Forms.SystemInformation]::VirtualScreen
            $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size) }
                finally { $graphics.Dispose() }
                $bitmap.Save((Join-Path $OutputDirectory 'watchdog-desktop.png'), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
        } catch {
            "Watchdog screenshot failed: $($_.Exception.GetType().FullName)" |
                Add-Content (Join-Path $OutputDirectory 'watchdog.txt') -Encoding utf8
        }
        $process.Kill($true)
        $process.WaitForExit(5000) | Out-Null
        throw 'Smoke exceeded the 150-second watchdog.'
    }
    if ($process.ExitCode -ne 0) { throw "Smoke driver failed with exit code $($process.ExitCode)." }
} finally {
    $stdout.GetAwaiter().GetResult() | Set-Content (Join-Path $OutputDirectory 'stdout.log') -Encoding utf8
    $stderr.GetAwaiter().GetResult() | Set-Content (Join-Path $OutputDirectory 'stderr.log') -Encoding utf8
    $process.Dispose()
}
Get-Content (Join-Path $OutputDirectory 'stdout.log')
