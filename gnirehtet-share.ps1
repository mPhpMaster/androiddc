#Requires -Version 5.1

<#
.SYNOPSIS
    Share the Windows internet connection with an Android device over ADB
    (reverse tethering) using gnirehtet.

.DESCRIPTION
    Picks an ADB device (interactively when several are connected), installs
    the gnirehtet client if it is missing, opens the adb reverse tunnel and
    runs the relay server. Press Ctrl+C to stop: the client is stopped and the
    tunnel removed before the script exits.

    gnirehtet.exe, gnirehtet.apk and adb.exe are taken from the script folder
    when present, otherwise from PATH.

.PARAMETER Serial
    Device serial to use. Skips the interactive picker.

.PARAMETER Dns
    DNS server(s) pushed to the device, comma separated. Default 8.8.8.8.

.PARAMETER Port
    TCP port of the relay server. Default 31416.

.PARAMETER Routes
    Only tunnel these routes, comma separated (e.g. 192.168.0.0/24).
    Default: the whole traffic (0.0.0.0/0).

.PARAMETER All
    Serve every connected device (gnirehtet autorun) instead of a single one.

.PARAMETER Reinstall
    Force uninstall + install of the client APK before starting.

.PARAMETER StopOnly
    Stop the client on the device, remove the tunnel and exit.

.PARAMETER ListDevices
    Print the connected devices and exit.

.PARAMETER DisableWifi
    Turn Wi-Fi off on the device while tethering (restored on exit).
    Silently ignored when the device does not allow it.

.PARAMETER PauseOnError
    Keep the window open when the script fails.

.EXAMPLE
    .\gnirehtet-share.ps1

.EXAMPLE
    .\gnirehtet-share.ps1 -Serial ABC123DEF456 -Dns 1.1.1.1 -DisableWifi

.EXAMPLE
    .\gnirehtet-share.ps1 -All
#>

[CmdletBinding()]
param(
    [string]$Serial,

    [string]$Dns = '8.8.8.8',

    [ValidateRange(1024, 65535)]
    [int]$Port = 31416,

    [string]$Routes,

    [switch]$All,

    [switch]$Reinstall,

    [switch]$StopOnly,

    [switch]$ListDevices,

    [switch]$DisableWifi,

    [switch]$PauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:adbPath = $null
$script:gnirehtetPath = $null
$script:selectedSerial = $null
$script:wifiDisabled = $false
$script:relayProcess = $null
$script:cleanupDone = $false
$scriptFailed = $false

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageName = 'com.genymobile.gnirehtet'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )

    $local = Join-Path $scriptRoot $FileName
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        return (Resolve-Path -LiteralPath $local).Path
    }

    $command = Get-Command $FileName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    throw "$FriendlyName ($FileName) was not found next to this script nor in PATH."
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandArguments,
        [switch]$IgnoreFailure
    )

    # 'Stop' would turn any stderr line of a native command into a terminating error.
    $ErrorActionPreference = 'Continue'
    $output = @(& $script:adbPath @CommandArguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $IgnoreFailure) {
        throw ("adb " + ($CommandArguments -join ' ') + " failed (exit $exitCode): " + ($output -join ' '))
    }

    return ($output | ForEach-Object { "$_" })
}

function Invoke-AdbShell {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandArguments,
        [switch]$IgnoreFailure
    )

    $prefix = @('-s', $script:selectedSerial, 'shell')
    return Invoke-Adb -CommandArguments ($prefix + $CommandArguments) -IgnoreFailure:$IgnoreFailure
}

function Get-AdbDevices {
    $lines = Invoke-Adb -CommandArguments @('devices', '-l')

    $devices = @()
    foreach ($line in $lines) {
        $text = "$line".Trim()
        if ($text -eq '' -or $text -like 'List of devices*' -or $text -like '*daemon*') {
            continue
        }

        $parts = $text -split '\s+'
        if ($parts.Count -lt 2) { continue }

        $model = ($parts | Where-Object { $_ -like 'model:*' } | Select-Object -First 1)
        if ($model) { $model = $model.Substring(6) } else { $model = 'unknown' }

        $devices += [PSCustomObject]@{
            Serial = $parts[0]
            State  = $parts[1]
            Model  = $model
            IsUsb  = ($parts[0] -notmatch ':\d+$')
        }
    }

    return $devices
}

function Show-Devices {
    param([object[]]$Devices)

    $index = 1
    foreach ($device in $Devices) {
        $link = if ($device.IsUsb) { 'usb' } else { 'tcp' }
        Write-Host ("  [{0}] {1,-24} {2,-5} {3,-16} {4}" -f $index, $device.Serial, $link, $device.Model, $device.State)
        $index++
    }
}

function Select-Device {
    $devices = @(Get-AdbDevices)

    if ($devices.Count -eq 0) {
        throw 'No device detected. Plug the phone in, enable USB debugging and accept the RSA prompt.'
    }

    foreach ($device in @($devices | Where-Object { $_.State -ne 'device' })) {
        Write-Warning "Device $($device.Serial) is '$($device.State)' and cannot be used."
    }

    $usable = @($devices | Where-Object { $_.State -eq 'device' })
    if ($usable.Count -eq 0) {
        throw 'No usable device (all of them are unauthorized or offline).'
    }

    if ($Serial) {
        $match = $usable | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if (-not $match) {
            throw "Device '$Serial' is not connected or not ready."
        }
        return $match.Serial
    }

    if ($usable.Count -eq 1) {
        Write-Note "Using the only connected device: $($usable[0].Serial) ($($usable[0].Model))"
        return $usable[0].Serial
    }

    Write-Host ''
    Write-Host 'Several devices are connected:' -ForegroundColor Yellow
    Show-Devices -Devices $usable
    Write-Host ''

    while ($true) {
        $answer = Read-Host "Pick a device [1-$($usable.Count)]"
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $usable.Count) {
            return $usable[$number - 1].Serial
        }
        Write-Host 'Invalid choice.' -ForegroundColor Red
    }
}

function Test-ClientInstalled {
    $output = Invoke-AdbShell -CommandArguments @('pm', 'list', 'packages', $packageName) -IgnoreFailure
    return [bool](($output -join "`n") -match [regex]::Escape("package:$packageName"))
}

function Invoke-Gnirehtet {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandArguments,
        [switch]$IgnoreFailure
    )

    $ErrorActionPreference = 'Continue'
    & $script:gnirehtetPath @CommandArguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $IgnoreFailure) {
        throw ("gnirehtet " + ($CommandArguments -join ' ') + " failed (exit $exitCode).")
    }
}

function Stop-Tethering {
    # Called from the StopOnly branch and from finally: only do the work once.
    if ($script:cleanupDone) { return }
    $script:cleanupDone = $true

    if ($script:relayProcess -and -not $script:relayProcess.HasExited) {
        Write-Step 'Stopping the relay server'
        try {
            $script:relayProcess.Kill()
            $null = $script:relayProcess.WaitForExit(5000)
        } catch {
            Write-Note "Could not kill the relay: $($_.Exception.Message)"
        }
    }

    if ($script:selectedSerial) {
        Write-Step 'Stopping the client on the device'
        try {
            Invoke-Gnirehtet -CommandArguments @('stop', $script:selectedSerial) -IgnoreFailure
        } catch {
            Write-Note "stop failed: $($_.Exception.Message)"
        }

        Invoke-Adb -CommandArguments @('-s', $script:selectedSerial, 'reverse', '--remove', 'localabstract:gnirehtet') -IgnoreFailure | Out-Null
    }

    if ($script:wifiDisabled) {
        Write-Step 'Re-enabling Wi-Fi on the device'
        Invoke-AdbShell -CommandArguments @('svc', 'wifi', 'enable') -IgnoreFailure | Out-Null
        $script:wifiDisabled = $false
    }
}

try {
    $script:adbPath = Resolve-Tool -FileName 'adb.exe' -FriendlyName 'ADB'
    $script:gnirehtetPath = Resolve-Tool -FileName 'gnirehtet.exe' -FriendlyName 'gnirehtet'

    # gnirehtet spawns adb itself; point it at the same binary and APK.
    $env:ADB = $script:adbPath
    $localApk = Join-Path $scriptRoot 'gnirehtet.apk'
    if (Test-Path -LiteralPath $localApk -PathType Leaf) {
        $env:GNIREHTET_APK = (Resolve-Path -LiteralPath $localApk).Path
    }

    Write-Note "adb:       $($script:adbPath)"
    Write-Note "gnirehtet: $($script:gnirehtetPath)"

    Invoke-Adb -CommandArguments @('start-server') -IgnoreFailure | Out-Null

    if ($ListDevices) {
        $devices = @(Get-AdbDevices)
        if ($devices.Count -eq 0) {
            Write-Host 'No device detected.' -ForegroundColor Yellow
        } else {
            Show-Devices -Devices $devices
        }
        return
    }

    $extraArguments = @('-d', $Dns, '-p', "$Port")
    if ($Routes) {
        $extraArguments += @('-r', $Routes)
    }

    if ($All) {
        Write-Step "Reverse tethering every connected device (DNS $Dns, port $Port)"
        Write-Note 'Press Ctrl+C to stop.'
        Invoke-Gnirehtet -CommandArguments (@('autorun') + $extraArguments)
        return
    }

    $script:selectedSerial = Select-Device
    Write-Step "Device: $($script:selectedSerial)"

    if ($StopOnly) {
        Stop-Tethering
        Write-Host 'Reverse tethering stopped.' -ForegroundColor Green
        return
    }

    if ($Reinstall) {
        Write-Step 'Reinstalling the gnirehtet client'
        Invoke-Gnirehtet -CommandArguments @('reinstall', $script:selectedSerial)
    } elseif (-not (Test-ClientInstalled)) {
        Write-Step 'Installing the gnirehtet client on the device'
        Invoke-Gnirehtet -CommandArguments @('install', $script:selectedSerial)
    } else {
        Write-Note 'Client already installed.'
    }

    if ($DisableWifi) {
        # only a radio this turned off is turned back on at exit
        $wifiOn = ((Invoke-AdbShell -CommandArguments @('settings', 'get', 'global', 'wifi_on') -IgnoreFailure) -join '').Trim()
        if ($wifiOn -eq '0') {
            Write-Note 'Wi-Fi is already off on the device, and stays off afterwards.'
        } else {
            Write-Step 'Turning Wi-Fi off on the device'
            Invoke-AdbShell -CommandArguments @('svc', 'wifi', 'disable') -IgnoreFailure | Out-Null
            $script:wifiDisabled = $true
        }
    }

    Write-Step "Starting reverse tethering (DNS $Dns, port $Port)"
    Write-Note 'Accept the VPN connection request on the phone if it shows up.'

    $relayArguments = @('run', $script:selectedSerial) + $extraArguments
    $script:relayProcess = Start-Process -FilePath $script:gnirehtetPath -ArgumentList $relayArguments -NoNewWindow -PassThru

    Start-Sleep -Seconds 3
    if ($script:relayProcess.HasExited) {
        throw "gnirehtet exited immediately (code $($script:relayProcess.ExitCode)). Port $Port may already be in use."
    }

    $ping = Invoke-AdbShell -CommandArguments @('ping', '-c', '2', '-W', '3', '8.8.8.8') -IgnoreFailure
    if (($ping -join "`n") -match '[1-9]\d* (?:packets )?received') {
        Write-Host 'Connectivity check: the device reaches the internet through the PC.' -ForegroundColor Green
    } else {
        Write-Note 'Connectivity check inconclusive - check the VPN prompt on the phone.'
    }

    Write-Host ''
    Write-Host 'Reverse tethering is running. Press Ctrl+C to stop.' -ForegroundColor Green
    Write-Host ''

    $canReadKeys = $false
    try {
        [Console]::TreatControlCAsInput = $true
        $canReadKeys = $true
    } catch {
        Write-Note 'This host does not support key capture; Ctrl+C will still stop the script.'
    }

    while (-not $script:relayProcess.HasExited) {
        if ($canReadKeys -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                Write-Host ''
                Write-Step 'Ctrl+C received'
                break
            }
        }
        Start-Sleep -Milliseconds 200
    }
} catch {
    $scriptFailed = $true
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    try { [Console]::TreatControlCAsInput = $false } catch { }

    if (-not $ListDevices) {
        Stop-Tethering
    }

    if ($scriptFailed) {
        if ($PauseOnError) {
            Read-Host 'Press Enter to close'
        }
        exit 1
    }
}
