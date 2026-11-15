param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot '../artifacts/package'),
    [string]$RunNumber = $env:GITHUB_RUN_NUMBER
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Velopack installer packaging must run on Windows.' }
$env:DOTNET_NOLOGO = '1'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$project = Join-Path $PSScriptRoot '../src/LiveCopilot.App/LiveCopilot.App.csproj'
$properties = dotnet msbuild $project '-getProperty:Version,VelopackVersion'
if ($LASTEXITCODE -ne 0) { throw 'Could not read package versions.' }
$properties = ($properties | Out-String | ConvertFrom-Json).Properties
$version = $properties.Version
if ($RunNumber) {
    if ($RunNumber -notmatch '^[1-9][0-9]*$') { throw 'RunNumber must be a positive integer.' }
    $version = "$version-ci.$RunNumber"
}
if (Test-Path $OutputRoot) { throw "Output directory already exists; use a fresh directory: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$toolDirectory = Join-Path $OutputRoot 'tools'
dotnet tool install vpk --version $properties.VelopackVersion --tool-path $toolDirectory
if ($LASTEXITCODE -ne 0) { throw 'vpk installation failed.' }
foreach ($rid in @('win-x64', 'win-arm64')) {
    $publish = Join-Path $OutputRoot "publish/$rid"
    $release = Join-Path $OutputRoot "releases/$rid"
    dotnet publish $project -c Release -r $rid --self-contained true -o $publish "-p:Version=$version" '-p:PublishSingleFile=false' '-p:PublishTrimmed=false'
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $rid" }
    # Native CPU files must be in the deliverable, not merely present in the NuGet cache.
    $cpu = if ($rid -eq 'win-x64') { 'noavx/' } else { '' }
    foreach ($file in @('LiveCopilot.App.exe', 'coreclr.dll', 'PresentationFramework.dll', 'e_sqlite3.dll', 'sherpa-onnx-c-api.dll', 'onnxruntime.dll', "runtimes/$rid/native/${cpu}llama.dll", "runtimes/$rid/native/${cpu}ggml.dll", "runtimes/$rid/native/${cpu}ggml-base.dll", "runtimes/$rid/native/${cpu}ggml-cpu.dll")) {
        if (-not (Test-Path (Join-Path $publish $file) -PathType Leaf)) { throw "Missing $rid publish asset: $file" }
    }
    $foreignRuntimes = @(Get-ChildItem (Join-Path $publish 'runtimes') -Directory | Where-Object Name -ne $rid)
    if ($foreignRuntimes.Count -ne 0) { throw "Unexpected foreign runtime directories in $rid package." }
    # Fail before packing if a dependency accidentally brings GPU backends back.
    $gpuAssets = @(Get-ChildItem $publish -Recurse -File | Where-Object { $_.FullName.Substring($publish.Length) -match '(?i)cuda|vulkan|cublas|cudart' })
    if ($gpuAssets.Count -ne 0) { throw "Unexpected GPU assets in CPU-only $rid package: $($gpuAssets.Name -join ', ')" }
    # pack emits Setup.exe and Portable.zip by default. No signing, update feed or runtime download.
    # Keep Velopack's installation root separate from %LOCALAPPDATA%/LiveCopilot user data.
    & (Join-Path $toolDirectory 'vpk.exe') pack --packId LiveCopilot.Windows --packTitle 'LiveCopilot Windows' --packAuthors LiveCopilot --packVersion $version --packDir $publish --mainExe LiveCopilot.App.exe --runtime $rid --channel $rid --outputDir $release --delta None
    if ($LASTEXITCODE -ne 0) { throw "vpk pack failed: $rid" }
    foreach ($pattern in @('*Setup.exe', '*Portable.zip')) {
        if (@(Get-ChildItem $release -Filter $pattern).Count -ne 1) { throw "Expected one $pattern for $rid" }
    }
    Get-ChildItem $release -File | Get-FileHash -Algorithm SHA256 |
        ForEach-Object { "$($_.Hash)  $([IO.Path]::GetFileName($_.Path))" } |
        Set-Content (Join-Path $release 'SHA256SUMS.txt') -Encoding utf8
}
Write-Host "Packaged unsigned LiveCopilot $version (win-x64 and win-arm64) at $OutputRoot"
