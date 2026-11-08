<#
    AndroidDC - the phone camera as a Windows camera ("AndroidDC Camera").

    Windows 11 lets a program add a camera of its own (Media Foundation
    virtual cameras). windows\vcam holds the two pieces, written in C#:

      AndroidDC.VirtualCamera.comhost.dll  the camera itself. Windows' camera
                                           service loads it; it is registered
                                           once with regsvr32, as administrator
      AndroidDC.VCamHost.exe               turns the camera on, runs scrcpy's
                                           server on the phone with the camera
                                           as the source, decodes the picture
                                           and hands it to the camera

    While the host runs, any app that uses a camera (Teams, Zoom, Meet in a
    browser, the Camera app, OBS) can pick "AndroidDC Camera". With no phone
    picture yet it shows grey bars.

    Measured on a Redmi (Android 15), Windows 11: listed as a camera in about
    5 s, the phone's picture 1.7-2.2 s after the start, 30 fps in and out.

    Needs Windows 11 and the .NET 8 runtime (or newer). Nothing here runs as
    administrator except the one regsvr32.

    Dot-sourced by both windows.
#>

$script:vcamProcess = $null
$script:vcamLines = New-Object System.Collections.Generic.List[string]
$script:vcamPending = $null
# the camera the host feeds now: Id, Facing, Size (for a switch that fails)
$script:vcamCamera = $null

function Get-VCamFolder {
    # the shipped binaries; built from windows\vcam\src when they are missing
    # and this PC has the .NET SDK
    $root = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows\vcam'
    $bin = Join-Path $root 'bin'
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'AndroidDC.VCamHost.exe'))) {
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build.ps1') 2>&1 | Out-Null } catch { }
        }
    }
    return $bin
}

function Test-VCamRuntime {
    # the .NET 8 runtime or newer, where the host and the camera service look for it
    $shared = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.NETCore.App'
    if (-not (Test-Path -LiteralPath $shared)) { return $false }
    foreach ($dir in Get-ChildItem -LiteralPath $shared -Directory -ErrorAction SilentlyContinue) {
        $major = 0
        if ([int]::TryParse(($dir.Name -split '\.')[0], [ref]$major) -and $major -ge 8) { return $true }
    }
    return $false
}

function Get-VCamState {
    <#
        What stands between the user and the camera. Returns Ready (bool),
        Need ('' | 'windows' | 'runtime' | 'files' | 'register'), Message,
        Folder, Dll and Running.
    #>
    $folder = Get-VCamFolder
    $state = [ordered]@{
        Ready = $false; Need = ''; Message = ''; Folder = $folder
        Dll = (Join-Path $folder 'AndroidDC.VirtualCamera.comhost.dll'); Running = (Test-VCamRunning)
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        $state.Need = 'windows'; $state.Message = 'The virtual camera needs Windows 11 (this is build ' + $build + ').'
        return [pscustomobject]$state
    }
    if (-not (Test-VCamRuntime)) {
        $state.Need = 'runtime'; $state.Message = 'The virtual camera needs the free .NET 8 runtime (or newer): https://dotnet.microsoft.com/download/dotnet/8.0'
        return [pscustomobject]$state
    }
    if (-not (Test-Path -LiteralPath (Join-Path $folder 'AndroidDC.VCamHost.exe')) -or -not (Test-Path -LiteralPath $state.Dll)) {
        $state.Need = 'files'; $state.Message = 'The virtual camera files are missing from windows\vcam\bin.'
        return [pscustomobject]$state
    }
    $registered = ''
    try {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('CLSID\{B6F9266A-DE52-4660-AFB9-AC513027B060}\InprocServer32')
        if ($key) { $registered = "$($key.GetValue(''))"; $key.Close() }
    } catch { }
    if (-not $registered -or -not [string]::Equals($registered, $state.Dll, [StringComparison]::OrdinalIgnoreCase)) {
        $state.Need = 'register'
        $state.Message = if ($registered) { 'The camera is registered from another folder; it has to be registered from this one (one administrator prompt).' }
                         else { 'The camera has to be registered with Windows once (one administrator prompt).' }
        return [pscustomobject]$state
    }
    $state.Ready = $true
    return [pscustomobject]$state
}

function Register-VCam {
    # one UAC prompt: regsvr32 the camera so Windows' camera service can load it
    param([string]$Dll)
    try {
        $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\regsvr32.exe') -ArgumentList @('/s', ('"' + $Dll + '"')) `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return ($process.ExitCode -eq 0)
    } catch {
        return $false   # the prompt was refused
    }
}

function Test-VCamRunning {
    if (-not $script:vcamProcess) { return $false }
    try { if (-not $script:vcamProcess.HasExited) { return $true } } catch { }
    return $false
}

function Read-VCamLines {
    # collects whatever the host printed since the last look, without waiting
    if (-not $script:vcamProcess) { return }
    while ($true) {
        if (-not $script:vcamPending) {
            try { $script:vcamPending = $script:vcamProcess.StandardOutput.ReadLineAsync() } catch { return }
        }
        if (-not $script:vcamPending.IsCompleted) { return }
        $line = $null
        try { $line = $script:vcamPending.Result } catch { }
        $script:vcamPending = $null
        if ($null -eq $line) { return }   # the host ended
        $script:vcamLines.Add($line)
    }
}

function Get-VCamArguments {
    # the host's command line: which phone, which camera
    param([string]$Serial, [string]$CameraId, [string]$Facing, [string]$Size, [switch]$Mirror)
    $root = Split-Path $PSScriptRoot -Parent
    $arguments = @('run', '-s', $Serial, '--adb', (Join-Path $root 'adb.exe'), '--server', (Join-Path $root 'scrcpy-server'))
    if ($CameraId) { $arguments += @('--camera-id', $CameraId) }
    elseif ($Facing) { $arguments += @('--camera-facing', $Facing) }
    if ($Size) { $arguments += @('--camera-size', $Size) }
    if ($Mirror) { $arguments += '--mirror' }
    return $arguments
}

function Start-VCam {
    <#
        Turns the camera on and feeds it from the phone. Waits (pumping the
        window) until the phone's picture flows or a reason it cannot.
        Returns Ok, Message and Lines.
    #>
    param([string]$Serial, [string]$CameraId, [string]$Facing, [string]$Size = '1280x720', [switch]$Mirror,
        [int]$TimeoutMs = 30000)

    if (Test-VCamRunning) { Stop-VCam | Out-Null }
    $folder = Get-VCamFolder
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $folder 'AndroidDC.VCamHost.exe'
    # one quoted string: Windows PowerShell 5.1 has no ArgumentList here
    $info.Arguments = (@(Get-VCamArguments -Serial $Serial -CameraId $CameraId -Facing $Facing -Size $Size -Mirror:$Mirror |
        ForEach-Object { if ("$_" -match '[\s"]') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # stdin stays open while this program lives: when it ends, the camera ends too
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $script:vcamLines.Clear()
    $script:vcamPending = $null
    $script:vcamProcess = [System.Diagnostics.Process]::Start($info)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        Wait-Pumped -Milliseconds 100
        Read-VCamLines
        $last = if ($script:vcamLines.Count) { $script:vcamLines[$script:vcamLines.Count - 1] } else { '' }
        if ($last -like 'FEEDING*') {
            $script:vcamCamera = @{ Id = $CameraId; Facing = $Facing; Size = $Size }
            return [pscustomobject]@{ Ok = $true; Message = 'AndroidDC Camera is on, showing the phone camera.'; Lines = @($script:vcamLines) }
        }
        foreach ($line in $script:vcamLines) {
            if ($line -like 'FEED-ERROR *' -or $line -like 'ERROR *' -or $line -like 'ALREADY *') {
                $reason = $line -replace '^(FEED-ERROR|ERROR|ALREADY) ', ''
                Stop-VCam | Out-Null
                return [pscustomobject]@{ Ok = $false; Message = $reason; Lines = @($script:vcamLines) }
            }
        }
        if ($script:vcamProcess.HasExited) {
            Read-VCamLines
            $code = $script:vcamProcess.ExitCode
            $script:vcamProcess = $null
            return [pscustomobject]@{ Ok = $false; Message = "The camera host ended (exit $code)."; Lines = @($script:vcamLines) }
        }
    }
    Stop-VCam | Out-Null
    return [pscustomobject]@{ Ok = $false; Message = 'No picture from the phone camera in time.'; Lines = @($script:vcamLines) }
}

function Send-VCamSwitch {
    # one "switch" to the host; waits (pumping the window) for the new camera's picture
    param([string]$CameraId, [string]$Facing, [string]$Size, [int]$TimeoutMs = 20000)
    Read-VCamLines
    $from = $script:vcamLines.Count
    $which = if ($CameraId) { 'id ' + $CameraId } else { $Facing }
    try { $script:vcamProcess.StandardInput.WriteLine("switch $which $Size"); $script:vcamProcess.StandardInput.Flush() }
    catch { return [pscustomobject]@{ Ok = $false; Message = 'The camera host is not listening.' } }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        Wait-Pumped -Milliseconds 100
        Read-VCamLines
        for ($i = $from; $i -lt $script:vcamLines.Count; $i++) {
            $line = $script:vcamLines[$i]
            if ($line -like 'FEEDING*') { return [pscustomobject]@{ Ok = $true; Message = '' } }
            if ($line -like 'FEED-ERROR *' -or $line -like 'SWITCH-ERROR *') {
                return [pscustomobject]@{ Ok = $false; Message = ($line -replace '^(FEED-ERROR|SWITCH-ERROR) ', '') }
            }
        }
        if (-not (Test-VCamRunning)) { return [pscustomobject]@{ Ok = $false; Message = 'The camera host ended.' } }
    }
    return [pscustomobject]@{ Ok = $false; Message = 'No picture from that camera in time.' }
}

function Switch-VCam {
    <#
        Changes the phone camera while AndroidDC Camera is on (front, back, or
        an id). The Windows camera stays on, so an app using it keeps it; the
        picture shows grey bars for the second or two the phone takes. A
        camera without 1280x720 is tried again at the size the phone picks;
        one that does not start at all puts the camera that worked back.
        Returns Ok and Message.
    #>
    param([string]$CameraId, [string]$Facing)
    if (-not (Test-VCamRunning)) { return [pscustomobject]@{ Ok = $false; Message = 'AndroidDC Camera is not on.' } }
    $previous = $script:vcamCamera
    $result = Send-VCamSwitch -CameraId $CameraId -Facing $Facing -Size '1280x720'
    $size = '1280x720'
    if (-not $result.Ok -and $result.Message -match 'size' -and (Test-VCamRunning)) {
        $size = 'auto'
        $result = Send-VCamSwitch -CameraId $CameraId -Facing $Facing -Size 'auto'
    }
    if ($result.Ok) {
        $script:vcamCamera = @{ Id = $CameraId; Facing = $Facing; Size = $size }
        $which = if ($CameraId) { "camera $CameraId" } else { "the $Facing camera" }
        return [pscustomobject]@{ Ok = $true; Message = "AndroidDC Camera now shows $which." }
    }
    if ($previous -and (Test-VCamRunning)) {
        $back = Send-VCamSwitch -CameraId $previous.Id -Facing $previous.Facing -Size $previous.Size
        if ($back.Ok) { return [pscustomobject]@{ Ok = $false; Message = $result.Message + ' - kept the camera it showed before.' } }
    }
    return [pscustomobject]@{ Ok = $false; Message = $result.Message }
}

function Stop-VCam {
    # asks the host to stop (it removes the camera itself); returns whether one was running
    if (-not $script:vcamProcess) { return $false }
    $process = $script:vcamProcess
    $script:vcamProcess = $null
    $script:vcamPending = $null
    $was = $false
    try {
        if (-not $process.HasExited) {
            $was = $true
            try { $process.StandardInput.WriteLine('stop'); $process.StandardInput.Close() } catch { }
            if (-not $process.WaitForExit(8000)) { try { $process.Kill() } catch { } }
        }
    } catch { }
    try { $process.Dispose() } catch { }
    return $was
}
