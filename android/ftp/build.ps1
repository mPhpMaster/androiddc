param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'out'))
$ErrorActionPreference = 'Stop'
$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$buildTools = Get-ChildItem (Join-Path $sdkRoot 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $buildTools) { throw 'Android SDK build-tools were not found.' }
$androidJar = Join-Path $sdkRoot 'platforms\android-35\android.jar'
if (-not (Test-Path $androidJar)) { $androidJar = Get-ChildItem (Join-Path $sdkRoot 'platforms') -Filter android.jar -Recurse | Select-Object -Last 1 -ExpandProperty FullName }
if (-not $androidJar) { throw 'Android SDK android.jar was not found.' }
$classes = Join-Path $OutputDirectory 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
& javac -encoding UTF-8 -source 8 -target 8 -classpath $androidJar -d $classes (Get-ChildItem (Join-Path $PSScriptRoot 'src\com\androiddc') -Filter '*.java' | Select-Object -ExpandProperty FullName)
if ($LASTEXITCODE -ne 0) { throw 'javac failed.' }
$classJar = Join-Path $OutputDirectory 'rawftp-classes.jar'
Push-Location $classes
try { & jar cf $classJar . } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'jar failed.' }
& (Join-Path $buildTools.FullName 'd8.bat') --min-api 26 --output $OutputDirectory $classJar
if ($LASTEXITCODE -ne 0) { throw 'd8 failed.' }
Write-Output (Join-Path $OutputDirectory 'classes.dex')
