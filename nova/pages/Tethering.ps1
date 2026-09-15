# pages\Tethering.ps1 - internet sharing in both directions: the PC's internet
# on the phone through gnirehtet (relay here, client there), and the phone's
# data on the PC through USB tethering or a proxy app forwarded over adb.

$tetheringPage = Register-Page -Key 'tethering' -Title 'Tethering' -Glyph 'E774' -Section 'Connect' `
    -Xaml 'Tethering.xaml' -Refresh {
        if ($ui.TetheringTabs.SelectedIndex -eq 1) { $null = Show-TetherAdapters } else { Update-DeviceList }
    }

$script:relayProcess = $null
$script:activeSerials = @()
$script:wifiDisabled = @()     # the phones whose Wi-Fi sharing turned off
$script:outFile = $null
$script:errFile = $null
$script:outOffset = 0
$script:errOffset = 0
$script:sharingStarting = $false

$script:proxyPort = 0
$script:proxySerial = $null
$script:previousProxy = $null

$null = $ui.TetheringDns.Items.Add('8.8.8.8')
$null = $ui.TetheringDns.Items.Add('8.8.8.8,8.8.4.4')
$null = $ui.TetheringDns.Items.Add('1.1.1.1')
$null = $ui.TetheringDns.Items.Add('9.9.9.9')
$null = $ui.TetheringDns.Items.Add('208.67.222.222')
$ui.TetheringDns.Text = '8.8.8.8'

# ------------------------------------------------------------ gnirehtet ----

function Invoke-Gnirehtet {
    param([string[]]$CommandArguments)

    if (-not $script:gnirehtetPath) {
        return [PSCustomObject]@{ ExitCode = -1; Lines = @('gnirehtet.exe not found.'); Text = 'gnirehtet.exe not found.' }
    }
    $result = Invoke-OffThread -FilePath $script:gnirehtetPath -ArgumentList $CommandArguments
    return [PSCustomObject]@{
        ExitCode = $result.ExitCode
        Lines    = $result.Lines
        Text     = ($result.Lines -join "`n")
    }
}

function Get-PortOwner {
    param([int]$Port)

    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if (-not $connection) { return $null }

        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            ProcessId   = $connection.OwningProcess
            ProcessName = if ($process) { $process.ProcessName } else { 'unknown' }
        }
    } catch {
        # Get-NetTCPConnection is missing, or found nothing: a plain listener probe (no PID)
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if (@($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0) {
            return [PSCustomObject]@{ ProcessId = 0; ProcessName = 'unknown' }
        }
        return $null
    }
}

function Set-TetheringRunning {
    # what Set-Running did: the page's buttons, the All devices option, the pill
    param([bool]$IsRunning, [string]$Target = '')

    $ui.TetheringStart.IsEnabled = -not $IsRunning
    $ui.TetheringStop.IsEnabled = $IsRunning
    $ui.AllDevices.IsEnabled = -not $IsRunning

    if ($IsRunning) {
        $ui.TetheringState.Text = "Sharing: $Target"
        $ui.TetheringState.Foreground = Get-Resource 'Success'
        Set-SharingState -Target $Target
    } else {
        $ui.TetheringState.Text = 'Sharing: off'
        $ui.TetheringState.Foreground = Get-Resource 'MutedText'
        Set-SharingState -Target ''
    }
}

function Get-TetheringPort {
    return (Get-NumberValue -Box $ui.TetheringPort -Default 31416 -Minimum 1024 -Maximum 65535)
}

function Get-ExtraArguments {
    $dns = $ui.TetheringDns.Text.Trim()
    if (-not $dns) { $dns = '8.8.8.8' }

    $arguments = @('-d', $dns, '-p', "$(Get-TetheringPort)")
    if ($ui.TetheringRoutes.Text.Trim() -ne '') {
        $arguments += @('-r', $ui.TetheringRoutes.Text.Trim())
    }
    return $arguments
}

function Get-TetheringRelayFiles {
    # a new pair of files for every start. Measured: sharing stopped and started
    # again a few seconds later failed with "being used by another process" -
    # something the stopped relay started still held the old pair open. The
    # window deletes androiddc-nova-<PID>.* when it closes.
    param([string]$Stamp = (Get-Date -Format 'HHmmssfff'))

    return [PSCustomObject]@{
        Out = Join-Path $env:TEMP ("androiddc-nova-$PID.relay-$Stamp.out")
        Err = Join-Path $env:TEMP ("androiddc-nova-$PID.relay-$Stamp.err")
    }
}

function Write-TetheringInstallHint {
    # measured on a Xiaomi phone: it refuses any adb install until allowed
    param([string]$Text)
    if ($Text -match 'INSTALL_FAILED_USER_RESTRICTED') {
        Write-Log ('The phone blocks installs over USB. On Xiaomi / Redmi / POCO turn on ' +
            'Developer options > Install via USB, then accept the prompt on the phone.') $colorWarn
    }
}

function Disable-TetheringWifi {
    # only a radio this turned off is turned back on at the end: a phone kept
    # on mobile data used to come back with Wi-Fi on
    param([string]$Serial)

    $wifiOn = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('settings', 'get', 'global', 'wifi_on')).Text.Trim()
    if ($wifiOn -eq '0') {
        Write-Log "Wi-Fi is already off on $Serial, and stays off afterwards." $colorInfo
        return
    }
    Write-Log "Turning Wi-Fi off on $Serial ..." $colorStep
    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('svc', 'wifi', 'disable')
    if ($script:wifiDisabled -notcontains $Serial) { $script:wifiDisabled += $Serial }
}

function Restore-TetheringWifi {
    # Wi-Fi back on for every phone this turned it off on - and only those
    param([string[]]$Serials = @(), [switch]$Quiet)

    $all = @(@($Serials) + @($script:wifiDisabled) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($current in $all) {
        if ($script:wifiDisabled -notcontains $current) { continue }
        $null = Invoke-DeviceShell -Serial $current -CommandArguments @('svc', 'wifi', 'enable')
        if (-not $Quiet) { Write-Log "Wi-Fi re-enabled on $current." $colorInfo }
    }
    $script:wifiDisabled = @()
}

function Start-Sharing {
    if (-not $script:gnirehtetPath) { Write-Log 'gnirehtet.exe not found.' $colorBad; return }
    if ($script:relayProcess -and -not $script:relayProcess.HasExited) {
        Write-Log 'Sharing is already running; stop it first.' $colorWarn
        return
    }

    $useAll = [bool]$ui.AllDevices.IsChecked
    $serial = $null

    # A relay left over from a previous run (or from gnirehtet-run.cmd) holds the
    # port and would make the new one die with 'os error 10048'.
    $port = Get-TetheringPort
    $owner = Get-PortOwner -Port $port
    if ($owner) {
        if ($owner.ProcessName -eq 'gnirehtet') {
            $stop = Show-Confirm -Title 'Gnirehtet' -Yes 'Stop it' -No 'Cancel' -Text (
                "Another gnirehtet relay (PID $($owner.ProcessId)) is already listening on port $port." +
                [Environment]::NewLine + 'Stop it and continue?')
            if (-not $stop) {
                Write-Log "Cancelled: port $port is still used by PID $($owner.ProcessId)." $colorWarn
                return
            }

            Stop-Process -Id $owner.ProcessId -Force -ErrorAction SilentlyContinue
            Wait-Pumped -Milliseconds 800
            if (Get-PortOwner -Port $port) {
                Write-Log "Port $port is still busy. Pick another port." $colorBad
                return
            }
            Write-Log "Stopped the old relay (PID $($owner.ProcessId))." $colorInfo
        } else {
            Write-Log "Port $port is used by $($owner.ProcessName) (PID $($owner.ProcessId)). Pick another port." $colorBad
            return
        }
    }

    $script:sharingStarting = $true
    try {
        $serials = @()
        if (-not $useAll) {
            $serials = @(Get-SelectedSerials)
            if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }
            $serial = $serials[0]

            foreach ($row in @($ui.DeviceList.SelectedItems)) {
                if ($row.State -ne 'device') { continue }
                $current = $row.Serial

                if ($ui.TetheringReinstall.IsChecked) {
                    Write-Log "Reinstalling the client on $current ..." $colorStep
                    $result = Invoke-Gnirehtet -CommandArguments @('reinstall', $current)
                    Write-Log $result.Text $colorInfo
                    if ($result.ExitCode -ne 0) {
                        Write-Log 'Reinstall failed.' $colorBad
                        Write-TetheringInstallHint -Text $result.Text
                        Restore-TetheringWifi
                        return
                    }
                } elseif ($row.Client -ne 'yes') {
                    Write-Log "Installing the client on $current ..." $colorStep
                    $result = Invoke-Gnirehtet -CommandArguments @('install', $current)
                    Write-Log $result.Text $colorInfo
                    if ($result.ExitCode -ne 0) {
                        Write-Log 'Install failed.' $colorBad
                        Write-TetheringInstallHint -Text $result.Text
                        # a phone earlier in the list may already be off Wi-Fi
                        Restore-TetheringWifi
                        return
                    }
                }

                if ($ui.TetheringWifiOff.IsChecked) { Disable-TetheringWifi -Serial $current }
            }
        }

        $files = Get-TetheringRelayFiles
        $script:outFile = $files.Out
        $script:errFile = $files.Err
        foreach ($file in @($script:outFile, $script:errFile)) {
            Set-Content -LiteralPath $file -Value '' -Encoding UTF8
        }
        $script:outOffset = 0
        $script:errOffset = 0

        # One relay serves every client, so several phones share the same server:
        #   1 device  -> 'run'    (relay + client + cleanup on exit)
        #   n devices -> 'relay'  then one 'start' per device
        #   all       -> 'autorun' (or 'autostart')
        if ($useAll) {
            $arguments = @($(if ($ui.TetheringAutostart.IsChecked) { 'autostart' } else { 'autorun' })) + (Get-ExtraArguments)
        } elseif ($serials.Count -gt 1) {
            $arguments = @('relay', '-p', "$port")
        } else {
            $arguments = @('run', $serial) + (Get-ExtraArguments)
        }
        Write-Log ('gnirehtet ' + ($arguments -join ' ')) $colorStep

        try {
            $script:relayProcess = Start-Process -FilePath $script:gnirehtetPath -ArgumentList $arguments `
                -NoNewWindow -PassThru -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
            $null = $script:relayProcess.Handle
        } catch {
            Write-Log "gnirehtet did not start: $($_.Exception.Message)" $colorBad
            $script:relayProcess = $null
            Restore-TetheringWifi -Serials $serials
            return
        }
        $script:activeSerials = $serials

        if ($serials.Count -gt 1) {
            Wait-Pumped -Milliseconds 2000
            foreach ($current in $serials) {
                Write-Log "Starting the client on $current ..." $colorStep
                $result = Invoke-Gnirehtet -CommandArguments (@('start', $current) + (Get-ExtraArguments))
                if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }
            }
        }

        $target = if ($useAll) { 'all devices' } elseif ($serials.Count -gt 1) { "$($serials.Count) devices" } else { $serial }
        Set-TetheringRunning -IsRunning $true -Target $target
        Write-Log 'Accept the VPN connection request on each phone if it shows up.' $colorWarn
        $script:relayTimer.Start()
    } finally {
        $script:sharingStarting = $false
    }

    if ($serials.Count -gt 0 -and $ui.TetheringAutoTest.IsChecked) {
        Wait-Pumped -Milliseconds 3000
        foreach ($current in $serials) { Test-Connectivity -Serial $current }
    }

    if ($serials.Count -gt 0 -and $ui.TetheringScrcpyAfter.IsChecked) {
        if (Get-Command Start-Scrcpy -ErrorAction SilentlyContinue) {
            Start-Scrcpy
        } else {
            Write-Log 'The Mirroring page is not loaded, so scrcpy was not opened.' $colorWarn
        }
    }
}

function Stop-Sharing {
    param([switch]$Quiet)

    $script:relayTimer.Stop()

    if ($script:relayProcess) {
        try {
            if (-not $script:relayProcess.HasExited) {
                $script:relayProcess.Kill()
                $null = $script:relayProcess.WaitForExit(5000)
            }
        } catch {
            if (-not $Quiet) { Write-Log "Could not kill the relay: $($_.Exception.Message)" $colorWarn }
        }
        $script:relayProcess = $null
    }

    foreach ($current in @($script:activeSerials)) {
        $null = Invoke-Gnirehtet -CommandArguments @('stop', $current)
        $null = Invoke-Adb -CommandArguments @('-s', $current, 'reverse', '--remove', 'localabstract:gnirehtet')
    }
    Restore-TetheringWifi -Serials @($script:activeSerials) -Quiet:$Quiet

    $script:activeSerials = @()

    if (-not $Quiet) {
        Write-Log 'Reverse tethering stopped.' $colorWarn
        Set-TetheringRunning -IsRunning $false
    }
}

function Restart-Sharing {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "gnirehtet restart $serial ..." $colorStep
    $result = Invoke-Gnirehtet -CommandArguments (@('restart', $serial) + (Get-ExtraArguments))
    Write-Log ((@($result.Lines | Where-Object { "$_".Trim() }) -join ' ').Trim()) $colorInfo
}

function Read-NewOutput {
    param([string]$Path, [ref]$Offset)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0 }
        $null = $stream.Seek($Offset.Value, 'Begin')
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } finally {
        $stream.Dispose()
    }
}

function Test-Connectivity {
    param([string]$Serial)

    $serial = $Serial
    if (-not $serial) {
        $serial = if (@($script:activeSerials).Count -gt 0) { @($script:activeSerials)[0] } else { Get-SelectedSerial }
    }
    if (-not $serial) { Write-Log 'Select a device first.' $colorWarn; return }

    # gnirehtet relays TCP and UDP only: ICMP is dropped, so ping ALWAYS fails
    # through the tunnel even when it works perfectly. Never test with ping.
    Write-Log "Checking internet on $serial over TCP (ping/ICMP is not relayed by gnirehtet) ..." $colorStep

    # 1. curl, when the ROM ships it: gives a real HTTP status code.
    if ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'curl')).Text.Trim()) {
        $code = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'curl', '-s', '-m', '8', '-o', '/dev/null', '-w', '%{http_code}',
            'http://connectivitycheck.gstatic.com/generate_204')).Text.Trim()

        if ($code -match '^(204|200)$') {
            Write-Log "HTTP $code from the device - the internet works through the PC." $colorGood
            return
        }
        Write-Log "curl returned '$code'." $colorWarn
    }

    # 2. netcat: plain TCP handshake to a DNS server through the tunnel.
    $netcat = $null
    if ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'nc')).Text.Trim()) {
        $netcat = 'nc'
    } elseif ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'toybox')).Text.Trim()) {
        $netcat = 'toybox nc'
    }

    if ($netcat) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            "$netcat -w 6 8.8.8.8 53 </dev/null; echo rc=" + '$?')

        if ($result.Text -match 'rc=0') {
            Write-Log 'TCP 8.8.8.8:53 reached through the tunnel - the connection works.' $colorGood
            return
        }
        Write-Log ('netcat said: ' + $result.Text.Trim()) $colorWarn
    }

    # 3. Last resort: Android's own verdict on the VPN network.
    $dump = Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'connectivity')
    foreach ($line in ($dump.Text -split "`r?`n")) {
        if ($line -match 'Transports:\s*VPN' -and $line -match 'VALIDATED') {
            Write-Log 'Android reports the VPN network as VALIDATED (it checked the internet itself).' $colorGood
            return
        }
    }

    Write-Log 'Could not confirm connectivity. Open a browser on the phone to check.' $colorBad
    Write-Log 'Remember: a failing ping proves nothing here - gnirehtet does not carry ICMP.' $colorWarn
}

function Repair-Tunnel {
    param([string]$Serial)

    if (-not $Serial) { $Serial = Get-SelectedSerial }
    if (-not $Serial) { Write-Log 'Select a device first.' $colorWarn; return }

    # re-creates the adb reverse tunnel without restarting the relay: the fix
    # after an adb server kill or an unplug/replug. 'gnirehtet tunnel' can hang
    # after an adb server kill; adb reverse is instant.
    $null = Invoke-Adb -CommandArguments @('start-server')
    $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'reverse', 'localabstract:gnirehtet', "tcp:$(Get-TetheringPort)")
    if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }

    $check = Invoke-Adb -CommandArguments @('-s', $Serial, 'reverse', '--list')
    if ($check.Text -match 'gnirehtet') {
        Write-Log 'Reverse tunnel is in place again.' $colorGood
    } else {
        Write-Log 'Tunnel not restored - stop and start the sharing again.' $colorBad
    }
}

function Show-ReverseTunnels {
    $serial = Get-SelectedSerial
    $arguments = if ($serial) { @('-s', $serial, 'reverse', '--list') } else { @('reverse', '--list') }
    $result = Invoke-Adb -CommandArguments $arguments
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorInfo
    } else {
        Write-Log 'No reverse tunnel.' $colorInfo
    }
}

function Stop-StrayRelays {
    $mine = if ($script:relayProcess) { $script:relayProcess.Id } else { -1 }
    $processes = @(Get-Process gnirehtet -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $mine })

    if ($processes.Count -eq 0) {
        Write-Log 'No stray gnirehtet process.' $colorInfo
        return
    }

    $list = ($processes | ForEach-Object { "PID $($_.Id)" }) -join ', '
    if (-not (Show-Confirm -Title 'Gnirehtet' -Text ("Kill these gnirehtet processes?" + [Environment]::NewLine + $list) `
            -Yes 'Kill' -No 'Cancel' -Danger)) { return }

    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Write-Log "Killed PID $($process.Id)." $colorInfo
    }
}

function Install-TetheringClient {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log "Installing the gnirehtet client on $serial ..." $colorStep
    $result = Invoke-Gnirehtet -CommandArguments @('install', $serial)
    Write-Log $result.Text $colorInfo
    if ($result.ExitCode -ne 0) { Write-TetheringInstallHint -Text $result.Text }
    Update-DeviceList
}

function Uninstall-TetheringClient {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-Gnirehtet -CommandArguments @('uninstall', $serial)).Text $colorInfo
    Update-DeviceList
}

# -------------------------------------------------- USB tethering (phone -> PC) ----

function Get-TetherAdapters {
    # Windows names the tethered phone 'Remote NDIS based Internet Sharing Device'
    # (note the space), so match NDIS rather than RNDIS.
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.InterfaceDescription -match 'NDIS|Android|Tether|Internet Sharing'
        })
    } catch {
        return @()
    }
}

function Get-AdapterAddress {
    param($Adapter)

    try {
        $address = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -First 1
        if ($address) { return $address.IPAddress }
    } catch { }
    return $null
}

function Show-TetherAdapters {
    $adapters = @(Get-TetherAdapters)
    if ($adapters.Count -eq 0) {
        $ui.TetheringUsbStatus.Text = 'PC side: no USB tethering adapter found.'
        $ui.TetheringUsbStatus.Foreground = Get-Resource 'Danger'
        Write-Log 'No RNDIS/Android tethering adapter on the PC yet.' $colorWarn
        return $null
    }

    foreach ($adapter in $adapters) {
        $address = Get-AdapterAddress -Adapter $adapter
        Write-Log ("PC adapter: {0} | {1} | {2} | {3}" -f $adapter.Name, $adapter.InterfaceDescription,
            $adapter.Status, $(if ($address) { $address } else { 'no IPv4' })) $colorInfo
    }

    $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -gt 0) {
        $address = Get-AdapterAddress -Adapter $up[0]
        $ui.TetheringUsbStatus.Text = "PC side: $($up[0].Name) is up ($($up[0].InterfaceDescription))" +
            $(if ($address) { " - $address" } else { '' })
        $ui.TetheringUsbStatus.Foreground = Get-Resource 'Success'
        return $up[0]
    }

    $ui.TetheringUsbStatus.Text = "PC side: $($adapters[0].Name) present but $($adapters[0].Status)."
    $ui.TetheringUsbStatus.Foreground = Get-Resource 'Warning'
    return $null
}

function Open-MeteredSettings {
    param($Adapter)

    # Windows has no supported API to flip 'metered' on an Ethernet/RNDIS link,
    # so open the page where the toggle lives instead of pretending it is done.
    Write-Log "Open '$($Adapter.Name)' and turn on 'Metered connection' so Windows stops downloading updates over the phone data." $colorWarn
    Start-Process 'ms-settings:network-ethernet'
}

function Enable-UsbTethering {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Enabling USB tethering on $serial ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions', 'rndis')
    if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }

    Wait-Pumped -Milliseconds 4000
    $adapter = Show-TetherAdapters

    if (-not $adapter) {
        Write-Log 'The phone refused the adb switch (usual without root). Opening the tethering settings instead.' $colorWarn
        Open-TetherSettings
        return
    }

    Write-Log 'USB tethering is up. The PC now uses the phone data connection.' $colorGood
    if ($ui.TetheringMetered.IsChecked) { Open-MeteredSettings -Adapter $adapter }
}

function Disable-UsbTethering {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Disabling USB tethering on $serial ..." $colorStep
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions')
    Wait-Pumped -Milliseconds 2000
    $null = Show-TetherAdapters
    Write-Log 'USB functions reset to charging.' $colorInfo
}

function Open-TetherSettings {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-a', 'android.settings.TETHER_SETTINGS')
    Write-Log $result.Text $colorInfo

    if ($result.Text -match 'Error|does not exist') {
        $fallback = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-n', 'com.android.settings/.TetherSettings')
        Write-Log $fallback.Text $colorInfo
    }

    Write-Log 'Tap "USB tethering" on the phone, then press "Check PC adapters".' $colorWarn
}

# ------------------------------------ phone proxy over adb forward (phone data on the PC) ----

if (-not ('AndroidDcNova.WinInet' -as [type])) {
    Add-Type -Namespace AndroidDcNova -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
}

function Update-WinInet {
    # Tell WinINET (Edge, Chrome, Office, most Windows apps) to reload the settings.
    [void][AndroidDcNova.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][AndroidDcNova.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Set-WindowsProxy {
    param([string]$Server)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = Get-ItemProperty -Path $key

    $names = @($current.PSObject.Properties.Name)
    $script:previousProxy = [PSCustomObject]@{
        Enable   = if ($names -contains 'ProxyEnable') { $current.ProxyEnable } else { 0 }
        Server   = if ($names -contains 'ProxyServer') { $current.ProxyServer } else { '' }
        Override = if ($names -contains 'ProxyOverride') { $current.ProxyOverride } else { '' }
    }

    Set-ItemProperty -Path $key -Name ProxyServer -Value $Server
    Set-ItemProperty -Path $key -Name ProxyOverride -Value '<local>'
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 1
    Update-WinInet
}

function Restore-WindowsProxy {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    if ($script:previousProxy) {
        Set-ItemProperty -Path $key -Name ProxyServer -Value $script:previousProxy.Server
        Set-ItemProperty -Path $key -Name ProxyOverride -Value $script:previousProxy.Override
        Set-ItemProperty -Path $key -Name ProxyEnable -Value $script:previousProxy.Enable
        $script:previousProxy = $null
    } else {
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 0
    }
    Update-WinInet
}

function Test-PhoneProxy {
    param([int]$Port)

    $proxy = "http://127.0.0.1:$Port"
    try {
        $response = Invoke-WebRequest -Uri 'http://connectivitycheck.gstatic.com/generate_204' `
            -Proxy $proxy -UseBasicParsing -TimeoutSec 8
        Write-Log "Proxy answered: HTTP $($response.StatusCode) - the PC can browse through the phone." $colorGood
        return $true
    } catch {
        Write-Log "Proxy test failed: $($_.Exception.Message)" $colorBad
        Write-Log 'Is the proxy app running on the phone and listening on that port?' $colorWarn
        return $false
    }
}

function Get-TetheringProxyPort {
    return (Get-NumberValue -Box $ui.TetheringProxyPort -Default 8080 -Minimum 1 -Maximum 65535)
}

function Start-PhoneProxy {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($script:proxyPort -gt 0) { Write-Log 'The phone proxy is already in use; stop it first.' $colorWarn; return }

    $port = Get-TetheringProxyPort
    Write-Log "adb forward tcp:$port -> phone tcp:$port ..." $colorStep
    $forward = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', "tcp:$port", "tcp:$port")
    if ($forward.ExitCode -ne 0) {
        Write-Log $forward.Text $colorBad
        return
    }

    if (-not (Test-PhoneProxy -Port $port)) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', '--remove', "tcp:$port")
        Write-Log 'Forward removed again; the Windows proxy was left untouched.' $colorWarn
        return
    }

    try {
        Set-WindowsProxy -Server "127.0.0.1:$port"
    } catch {
        Write-Log "The Windows proxy could not be set: $($_.Exception.Message)" $colorBad
        try { Restore-WindowsProxy } catch { }
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', '--remove', "tcp:$port")
        return
    }
    $script:proxyPort = $port
    $script:proxySerial = $serial
    $ui.TetheringProxyOff.IsEnabled = $true
    $ui.TetheringProxyOn.IsEnabled = $false
    Write-Log "Windows now browses through the phone (127.0.0.1:$port)." $colorGood
    Write-Log 'Apps that ignore the system proxy (some games, torrents) still use the normal connection.' $colorWarn
}

function Stop-PhoneProxy {
    param([switch]$Quiet)

    if ($script:proxyPort -le 0) { return }

    try { Restore-WindowsProxy } catch { if (-not $Quiet) { Write-Log "Restoring the Windows proxy failed: $($_.Exception.Message)" $colorBad } }
    # the phone the forward was made on, not whichever is picked now
    $serial = $script:proxySerial
    if (-not $serial) { $serial = if (@($script:activeSerials).Count -gt 0) { @($script:activeSerials)[0] } else { Get-SelectedSerial } }
    if ($serial) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', '--remove', "tcp:$($script:proxyPort)")
    }

    $script:proxyPort = 0
    $script:proxySerial = $null
    $ui.TetheringProxyOff.IsEnabled = $false
    $ui.TetheringProxyOn.IsEnabled = $true
    if (-not $Quiet) {
        Write-Log 'Phone proxy stopped, Windows proxy settings restored.' $colorWarn
    }
}

# ------------------------------------------ the relay output timer ----

# pumps the relay's output into the log and notices an unexpected exit
$script:relayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:relayTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:relayTimer.Add_Tick({
    # reading the files never runs adb, so it goes on while something else is busy
    $out = Read-NewOutput -Path $script:outFile -Offset ([ref]$script:outOffset)
    if ($out) { Write-Log $out $colorInfo }

    $err = Read-NewOutput -Path $script:errFile -Offset ([ref]$script:errOffset)
    if ($err) { Write-Log $err $colorWarn }

    # stopping does run adb: not on top of another call, nor in the middle of a start
    if ($script:busy -gt 0 -or $script:sharingStarting) { return }
    if ($script:relayProcess -and $script:relayProcess.HasExited) {
        # ExitCode is only readable once the process object has been fully waited on.
        $null = $script:relayProcess.WaitForExit(1000)
        $code = $null
        try { $code = $script:relayProcess.ExitCode } catch { }
        $codeText = if ($null -eq $code) { 'unknown' } else { "$code" }
        Write-Log "gnirehtet exited (code $codeText)." $(if ($code -eq 0) { $colorWarn } else { $colorBad })
        Stop-Sharing
    }
})

# ------------------------------------------------------------ events ----

$ui.TetheringStart.Add_Click({ Start-Sharing })
$ui.TetheringStop.Add_Click({ Stop-Sharing })
$ui.TetheringTest.Add_Click({ Test-Connectivity })
$ui.TetheringRestart.Add_Click({ Restart-Sharing })
$ui.TetheringInstallClient.Add_Click({ Install-TetheringClient })
$ui.TetheringUninstallClient.Add_Click({ Uninstall-TetheringClient })

$ui.TetheringUsbOn.Add_Click({ Enable-UsbTethering })
$ui.TetheringUsbOff.Add_Click({ Disable-UsbTethering })
$ui.TetheringUsbSettings.Add_Click({ Open-TetherSettings })
$ui.TetheringAdapters.Add_Click({ $null = Show-TetherAdapters })
$ui.TetheringProxyOn.Add_Click({ Start-PhoneProxy })
$ui.TetheringProxyOff.Add_Click({ Stop-PhoneProxy })
$ui.TetheringProxyTest.Add_Click({ $null = Test-PhoneProxy -Port (Get-TetheringProxyPort) })

Register-Setting -Name 'Tethering.Dns' -Get { $ui.TetheringDns.Text } -Set { param($v) if ("$v") { $ui.TetheringDns.Text = "$v" } }
Register-Setting -Name 'Tethering.Port' -Get { Get-TetheringPort } -Set { param($v) if ("$v") { $ui.TetheringPort.Text = "$v"; $null = Get-TetheringPort } }
Register-Setting -Name 'Tethering.Routes' -Get { $ui.TetheringRoutes.Text } -Set { param($v) $ui.TetheringRoutes.Text = "$v" }
Register-Setting -Name 'Tethering.WifiOff' -Get { [bool]$ui.TetheringWifiOff.IsChecked } -Set { param($v) $ui.TetheringWifiOff.IsChecked = [bool]$v }
Register-Setting -Name 'Tethering.AutoTest' -Get { [bool]$ui.TetheringAutoTest.IsChecked } -Set { param($v) $ui.TetheringAutoTest.IsChecked = [bool]$v }
Register-Setting -Name 'Tethering.ScrcpyAfter' -Get { [bool]$ui.TetheringScrcpyAfter.IsChecked } -Set { param($v) $ui.TetheringScrcpyAfter.IsChecked = [bool]$v }
Register-Setting -Name 'Tethering.Metered' -Get { [bool]$ui.TetheringMetered.IsChecked } -Set { param($v) $ui.TetheringMetered.IsChecked = [bool]$v }
Register-Setting -Name 'Tethering.ProxyPort' -Get { Get-TetheringProxyPort } -Set { param($v) if ("$v") { $ui.TetheringProxyPort.Text = "$v"; $null = Get-TetheringProxyPort } }

Register-Cleanup {
    # never leave the machine pointing at a proxy that dies with this window
    Stop-PhoneProxy -Quiet
    if ($script:relayProcess -or @($script:activeSerials).Count -gt 0 -or @($script:wifiDisabled).Count -gt 0) { Stop-Sharing -Quiet }
    $script:relayTimer.Stop()
}
