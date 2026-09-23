param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'out'))
$ErrorActionPreference = 'Stop'
$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$buildTools = Get-ChildItem (Join-Path $sdkRoot 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$androidJar = Join-Path $sdkRoot 'platforms\android-35\android.jar'
if (-not (Test-Path $androidJar)) { throw 'Android SDK platform 35 is required.' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$classes = Join-Path $OutputDirectory 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
& javac -encoding UTF-8 -source 8 -target 8 -classpath $androidJar -d $classes (Join-Path $PSScriptRoot 'src\com\androiddc\ftpcontrol\FtpControlService.java')
if ($LASTEXITCODE -ne 0) { throw 'Companion Java compilation failed.' }
$classJar = Join-Path $OutputDirectory 'companion-classes.jar'
Push-Location $classes
try { & jar cf $classJar . } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'Companion JAR creation failed.' }
& (Join-Path $buildTools.FullName 'd8.bat') --min-api 26 --output $OutputDirectory $classJar
if ($LASTEXITCODE -ne 0) { throw 'Companion DEX creation failed.' }
$unsigned = Join-Path $OutputDirectory 'companion-unsigned.apk'
& (Join-Path $buildTools.FullName 'aapt.exe') package -f -M (Join-Path $PSScriptRoot 'AndroidManifest.xml') -I $androidJar -F $unsigned
if ($LASTEXITCODE -ne 0) { throw 'Companion package creation failed.' }
Push-Location $OutputDirectory
try { & (Join-Path $buildTools.FullName 'aapt.exe') add $unsigned 'classes.dex' }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'Companion DEX packaging failed.' }
$key = Join-Path $OutputDirectory 'debug.keystore'
if (-not (Test-Path $key)) {
    & keytool -genkeypair -noprompt -keystore $key -storepass android -keypass android -alias androiddc-debug -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=AndroidDC FTP Debug' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Companion signing key creation failed.' }
}
$signed = Join-Path $OutputDirectory 'androiddc-ftp-control.apk'
& (Join-Path $buildTools.FullName 'zipalign.exe') -f 4 $unsigned $signed
if ($LASTEXITCODE -ne 0) { throw 'Companion alignment failed.' }
& (Join-Path $buildTools.FullName 'apksigner.bat') sign --ks $key --ks-key-alias androiddc-debug --ks-pass pass:android --key-pass pass:android $signed
if ($LASTEXITCODE -ne 0) { throw 'Companion signing failed.' }
Write-Output $signed
