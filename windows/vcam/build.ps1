# Builds the AndroidDC virtual camera (the media source DLL and its host)
# into windows\vcam\out. Needs the .NET 8 SDK or newer; the result runs on
# the .NET 8 runtime or newer.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here 'out'
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'dotnet was not found: install the .NET 8 SDK or newer.' }

foreach ($project in 'VirtualCamera\VirtualCamera.csproj', 'VCamHost\VCamHost.csproj') {
    & $dotnet.Source build (Join-Path $here "src\$project") -c Release -o $out --nologo -v quiet -p:UseAppHost=true
    if ($LASTEXITCODE -ne 0) { throw "build failed: $project" }
}
Get-ChildItem $out -Filter 'AndroidDC.*' | Select-Object Name, Length
