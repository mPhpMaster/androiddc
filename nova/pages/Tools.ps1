# pages\Tools.ps1 - Advanced > Device tools and Root / recovery of androiddc.ps1 in one page
# with two inner tabs: connecting phones (pairing, mDNS, wireless adb, the adb server,
# reverse tunnels), this device, private DNS, keyboards, hotspot and tethering; and the
# eleven root / recovery commands, each marked against the phone that is selected.

$toolsPage = Register-Page -Key 'tools' -Title 'Tools' -Glyph 'E90F' -Section 'System' -Xaml 'Tools.xaml' `
    -OnShow { Update-ToolsShown } -OnDeviceChanged { Update-ToolsForDevice } -Refresh { Update-ToolsRefresh }

$script:rootCheckedSerial = $null   # the phone the Root page's marks were read from
$script:toolsDnsSerial = $null      # the phone the DNS line was read from
$script:toolsImeSerial = $null      # the phone the keyboard list was read from
$script:rootButtons = New-Object System.Collections.ArrayList

# ------------------------------------------------------------ inner pages ----

function Test-ToolsTabShown {
    # 'device' or 'root': the Tools page is on screen with that inner tab in front
    param([string]$Tab)

    if (-not (Test-PageShown -Key 'tools')) { return $false }
    $wanted = if ($Tab -eq 'root') { $ui.ToolsTabRoot } else { $ui.ToolsTabDevice }
    return [object]::ReferenceEquals($ui.ToolsTabs.SelectedItem, $wanted)
}

function Update-ToolsShown {
    # the page opened: the root page says what this phone allows, the tools page shows its DNS
    if (-not (Get-SelectedSerial)) {
        if (-not (Test-ToolsTabShown -Tab 'root')) { $ui.ToolsDnsState.Text = '' }
        return
    }
    if (Test-ToolsTabShown -Tab 'root') { Update-RootAvailability }
    else { $null = Show-DnsState -Quiet }
}

function Update-ToolsForDevice {
    # Another phone was picked. The DNS line and the root marks belong to one phone:
    # read again when their page is on screen, otherwise cleared, so they are never
    # shown later as the answer of a phone that was not asked. Only a different phone
    # counts - and "nothing selected" is not one: Update-DeviceList empties the list
    # and selects the same phone again, which must not read it again.
    $selected = Get-SelectedSerial
    if (-not $selected) { return }

    if ($selected -ne $script:toolsDnsSerial) {
        if (Test-ToolsTabShown -Tab 'device') { $null = Show-DnsState -Quiet }
        else { $ui.ToolsDnsState.Text = ''; $script:toolsDnsSerial = $null }
    }
    if ($selected -ne $script:rootCheckedSerial) {
        if (Test-ToolsTabShown -Tab 'root') { Update-RootAvailability } else { Reset-RootAvailability }
    }
    if ($script:toolsImeSerial -and $selected -ne $script:toolsImeSerial) {
        # another phone's keyboards are not this phone's
        $ui.ToolsIme.Items.Clear()
        $ui.ToolsIme.Text = ''
        $script:toolsImeSerial = $null
    }
}

function Update-ToolsRefresh {
    # F5
    if (Test-ToolsTabShown -Tab 'root') { Update-RootAvailability } else { $null = Show-DnsState }
}

function Invoke-ToolsPageCall {
    # a function another page owns; says so when that page is not loaded
    param([string]$Name, [string]$Page)

    if (Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue) { & $Name; return }
    Write-Log "$Name belongs to the $Page page, which is not loaded." $colorWarn
}

# ------------------------------------------------------------- connection ----

function Start-WirelessPairing {
    <#
        Android 11 and newer show a pairing code under
        Developer options > Wireless debugging > Pair device with pairing code.
        adb pair takes that host:port and the six digits.
    #>
    $answer = Show-InputDialog -Title 'Pair over Wi-Fi' -Fields @('IP address and port', 'Pairing code') -OkText 'Pair' `
        -Hint ("On the phone open Developer options > Wireless debugging > Pair device with pairing code. " +
            "Type the IP and port it shows (for example 192.168.1.20:37251) and the six digit code.")
    if ($null -eq $answer) { return }
    $target = "$($answer[0])".Trim()
    $code = "$($answer[1])".Trim()
    if (-not $target -or -not $code) { return }

    Write-Log "adb pair $target ..." $colorStep
    $result = Invoke-Adb -CommandArguments @('pair', $target, $code)
    $text = ($result.Lines | Where-Object { $_.Trim() }) -join ' '
    if ($text -match 'Successfully paired') {
        Write-Log $text.Trim() $colorGood

        # pairing and debugging use different ports, so ask for the second one
        $second = Show-InputDialog -Title 'Connect over Wi-Fi' -Fields @('IP address and port') -OkText 'Connect' `
            -Values @(($target -replace ':\d+$', ':5555')) `
            -Hint "Paired. The same screen shows a second IP and port under 'IP address and port'. Type it to connect now, or cancel."
        if ($null -ne $second -and "$($second[0])".Trim()) {
            $connect = Invoke-Adb -CommandArguments @('connect', "$($second[0])".Trim())
            Write-Log (($connect.Lines | Where-Object { $_.Trim() }) -join ' ') $colorInfo
            Update-DeviceList
        }
    } else {
        Write-Log ("pairing failed: " + $text.Trim()) $colorBad
        Write-Log 'The code expires quickly - open the pairing screen again and retry.' $colorInfo
    }
}

function Show-MdnsDevices {
    Write-Log 'Looking for phones advertising wireless debugging ...' $colorStep

    $check = Invoke-Adb -CommandArguments @('mdns', 'check')
    Write-Log ((($check.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()) $colorInfo

    $result = Invoke-Adb -CommandArguments @('mdns', 'services')
    $lines = @($result.Lines | Where-Object { $_.Trim() })
    if ($lines.Count -le 1) {
        Write-Log 'Nothing is advertising. Wireless debugging must be on, and the phone on this network.' $colorWarn
        return
    }
    foreach ($line in $lines) { Write-Log ("  " + $line.Trim()) $colorInfo }
}

function Invoke-Reconnect {
    $serial = Get-SelectedSerial
    $arguments = if ($serial) { @('-s', $serial, 'reconnect') } else { @('reconnect') }
    $result = Invoke-Adb -CommandArguments $arguments
    Write-Log ((($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()) $colorInfo
    Wait-Pumped -Milliseconds 1500
    Update-DeviceList
}

function Save-BugReport {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $path = Select-SaveFile -Filter 'Bug report (*.zip)|*.zip' `
        -FileName ("bugreport-$serial-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    if (-not $path) { return }

    Write-Log "Collecting a bug report from $serial. This takes a few minutes ..." $colorStep
    # the busy strip names it while it runs (adb bugreport <file>)
    $result = Invoke-OffThread -FilePath $script:adbPath `
        -ArgumentList @('-s', $serial, 'bugreport', $path) -TimeoutMs 900000

    if (Test-Path -LiteralPath $path) {
        $size = (Get-Item -LiteralPath $path).Length
        Write-Log ("Saved " + $path + " (" + (Format-FileSize -Bytes $size) + ").") $colorGood
    } else {
        foreach ($line in @($result.Lines | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
            Write-Log ("  " + $line) $colorBad
        }
        Write-Log 'No file arrived. Older phones need "adb bugreport" without a path.' $colorWarn
    }
}

function Get-DeviceIp {
    param([string]$Serial)

    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ip', '-f', 'inet', 'addr', 'show', 'wlan0')
    if ($result.Text -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    # Older/locked-down ROMs answer nothing to 'ip route', so try the other sources.
    $route = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ip', 'route')
    if ($route.Text -match 'wlan0.+src\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($route.Text -match 'src\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    $prop = Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'dhcp.wlan0.ipaddress')
    if ($prop.Text -match '(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    $ifconfig = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ifconfig', 'wlan0')
    if ($ifconfig.Text -match 'inet\s+addr:?\s*(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    return $null
}

function Enable-WirelessAdb {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $ip = Get-DeviceIp -Serial $serial
    if (-not $ip) {
        Write-Log 'Could not read the device Wi-Fi address. Connect the phone to Wi-Fi first.' $colorBad
        return
    }

    Write-Log "Device IP: $ip - switching adb to TCP/IP ..." $colorStep
    $null = Invoke-Adb -CommandArguments @('-s', $serial, 'tcpip', '5555')
    Wait-Pumped -Milliseconds 2000

    $connect = Invoke-Adb -CommandArguments @('connect', "${ip}:5555")
    Write-Log $connect.Text $colorInfo
    $ui.ToolsConnect.Text = "${ip}:5555"

    if ($connect.Text -match 'connected') {
        Write-Log 'Wireless ADB ready - you can unplug the cable now.' $colorGood
    } else {
        Write-Log 'Connection failed. Same Wi-Fi network on both sides?' $colorBad
    }
    Update-DeviceList
}

function Connect-Wireless {
    $target = $ui.ToolsConnect.Text.Trim()
    if (-not $target) { Write-Log 'Enter ip:port first.' $colorWarn; return }
    if ($target -notmatch ':\d+$') { $target = "${target}:5555" }

    $result = Invoke-Adb -CommandArguments @('connect', $target)
    Write-Log $result.Text $(if ($result.Text -match 'connected') { $colorGood } else { $colorBad })
    Update-DeviceList
}

function Disconnect-Wireless {
    $result = Invoke-Adb -CommandArguments @('disconnect')
    Write-Log $result.Text $colorInfo
    Update-DeviceList
}

function Restart-AdbServer {
    Write-Log 'Restarting the adb server ...' $colorStep
    $null = Invoke-Adb -CommandArguments @('kill-server')
    Wait-Pumped -Milliseconds 500
    $null = Invoke-Adb -CommandArguments @('start-server')
    Update-DeviceList
    Write-Log 'ADB server restarted.' $colorGood
}

# ------------------------------------------------------------ this device ----

function Get-DeviceScreenshot {
    foreach ($serial in @(Get-SelectedSerials)) { Get-OneScreenshot -Serial $serial }
}

function Get-OneScreenshot {
    param([string]$Serial)

    $serial = $Serial
    $target = Join-Path ([Environment]::GetFolderPath('MyPictures')) ("android-$serial-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    Write-Log 'Taking a screenshot ...' $colorStep
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('screencap', '-p', '/sdcard/_gui_shot.png')
    $null = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', '/sdcard/_gui_shot.png', $target)
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('rm', '/sdcard/_gui_shot.png')

    if (Test-Path -LiteralPath $target) {
        Write-Log "Saved to $target" $colorGood
        if (Get-Command Show-CaptureFile -CommandType Function -ErrorAction SilentlyContinue) {
            try { Show-CaptureFile -Path $target -Serial $serial } catch { }
        }
    } else {
        Write-Log 'Screenshot failed.' $colorBad
    }
}

function Switch-Screen {
    foreach ($serial in @(Get-SelectedSerials)) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '26')
        Write-Log "Sent the power key to $serial (screen on/off)." $colorInfo
    }
}

function Set-DeviceWifi {
    param([bool]$Enabled)

    $action = if ($Enabled) { 'enable' } else { 'disable' }
    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'wifi', $action)
        if ($result.Text.Trim()) { Write-Log $result.Text $colorWarn }
        Write-Log "Wi-Fi $action requested on $serial." $colorInfo
    }
}

function Restart-Device {
    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    $sure = Show-Confirm -Title 'Reboot' -Text ("Reboot these devices?" + [Environment]::NewLine +
        ($serials -join [Environment]::NewLine)) -Yes 'Reboot' -Danger
    if (-not $sure) { return }

    foreach ($serial in $serials) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'reboot')
        Write-Log "Reboot sent to $serial." $colorWarn
    }
}

function Show-DeviceInfo {
    foreach ($serial in @(Get-SelectedSerials)) { Show-OneDeviceInfo -Serial $serial }
}

function Show-OneDeviceInfo {
    param([string]$Serial)

    $serial = $Serial
    $props = @{
        'Model'   = 'ro.product.model'
        'Brand'   = 'ro.product.brand'
        'Android' = 'ro.build.version.release'
        'SDK'     = 'ro.build.version.sdk'
        'ABI'     = 'ro.product.cpu.abi'
    }

    Write-Log "--- $serial ---" $colorStep
    foreach ($key in @('Model', 'Brand', 'Android', 'SDK', 'ABI')) {
        $value = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', $props[$key])).Text.Trim()
        Write-Log ("{0,-8}: {1}" -f $key, $value) $colorInfo
    }

    $size = (Invoke-DeviceShell -Serial $serial -CommandArguments @('wm', 'size')).Text.Trim()
    $density = (Invoke-DeviceShell -Serial $serial -CommandArguments @('wm', 'density')).Text.Trim()
    Write-Log ("Screen  : $size / $density" -replace "`n", ' ') $colorInfo

    $ip = Get-DeviceIp -Serial $serial
    Write-Log ("Wi-Fi IP: " + $(if ($ip) { $ip } else { 'none' })) $colorInfo
}

function Show-BatteryAndNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $battery = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'battery')).Text
    foreach ($key in @('level', 'status', 'temperature')) {
        if ($battery -match "(?m)^\s*$key\s*:\s*(.+)$") {
            Write-Log ("Battery {0,-12}: {1}" -f $key, $Matches[1].Trim()) $colorInfo
        }
    }

    $network = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'connectivity', '--short')).Text
    if (-not $network.Trim()) {
        $network = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ip', 'route')).Text
    }
    Write-Log $network $colorInfo
}

# ------------------------------------------------------------ private DNS ----

function ConvertFrom-ToolsDnsAddresses {
    # every address in "DnsAddresses: [/8.8.8.8,/2001:4860::8888]" lists; -First stops after the first list with any
    param([string]$Text, [switch]$First)

    $servers = @()
    foreach ($match in [regex]::Matches($Text, 'DnsAddresses:\s*\[([^\]]*)\]')) {
        foreach ($entry in ($match.Groups[1].Value -split ',')) {
            $entry = $entry.Trim().TrimStart('/')
            if ($entry) { $servers += $entry }
        }
        if ($First -and $servers.Count -gt 0) { break }
    }
    return $servers
}

function Get-DnsState {
    param([string]$Serial)

    $mode = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'settings', 'get', 'global', 'private_dns_mode')).Text.Trim()
    $host1 = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'settings', 'get', 'global', 'private_dns_specifier')).Text.Trim()

    # the resolvers of the network that actually carries traffic
    $active = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "dumpsys connectivity | grep -m1 'Active default network'")).Text
    $servers = @()
    # dumpsys often appends a 'Broken pipe' line, so anchoring to the end of the
    # text loses the network id: match the label itself instead
    if ($active -match 'Active default network:\s*(\d+)') {
        $id = $Matches[1]
        $line = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "dumpsys connectivity | grep -m1 'network{$id}'")).Text
        $servers = @(ConvertFrom-ToolsDnsAddresses -Text $line)
    }

    if ($servers.Count -eq 0) {
        # last resort: the first non-empty resolver list in the whole dump
        $any = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "dumpsys connectivity | grep -oE 'DnsAddresses: \[[^]]+\]' | head -3")).Text
        $servers = @(ConvertFrom-ToolsDnsAddresses -Text $any -First)
    }

    if (-not $mode -or $mode -eq 'null') { $mode = 'opportunistic' }
    return [PSCustomObject]@{
        Mode     = $mode
        Hostname = $(if ($host1 -and $host1 -ne 'null') { $host1 } else { '' })
        Servers  = $servers
    }
}

function Show-DnsState {
    param([switch]$Quiet)

    $serial = Get-TargetSerial
    if (-not $serial) { $ui.ToolsDnsState.Text = ''; $script:toolsDnsSerial = $null; return }

    $state = Get-DnsState -Serial $serial
    $label = switch ($state.Mode) {
        'off'           { 'off' }
        'hostname'      { "custom ($($state.Hostname))" }
        'opportunistic' { 'automatic' }
        default         { $state.Mode }
    }

    $ipv4 = @($state.Servers | Where-Object { $_ -notmatch ':' })
    $shown = if ($ipv4.Count -gt 0) { $ipv4 -join ', ' } elseif ($state.Servers.Count -gt 0) { $state.Servers[0] } else { 'none reported' }
    $ui.ToolsDnsState.Text = "mode: $label   |   resolvers in use: $shown"
    $script:toolsDnsSerial = $serial

    # keep the controls in step with the phone
    $ui.ToolsDnsMode.SelectedIndex = switch ($state.Mode) {
        'off'      { 1 }
        'hostname' { 2 }
        default    { 0 }
    }
    if ($state.Hostname) { $ui.ToolsDnsHost.Text = $state.Hostname }

    if (-not $Quiet) {
        Write-Log "$serial DNS: $label" $colorInfo
        if ($state.Servers.Count -gt 0) {
            Write-Log ('  resolvers: ' + ($state.Servers -join ', ')) $colorInfo
        }
    }
    return $state
}

function Set-DnsMode {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $choice = "$($ui.ToolsDnsMode.SelectedItem)"
    $mode = switch -Wildcard ($choice) {
        'off*'    { 'off' }
        'custom*' { 'hostname' }
        default   { 'opportunistic' }
    }

    if ($mode -eq 'hostname') {
        $name = $ui.ToolsDnsHost.Text.Trim()
        if (-not $name) { Write-Log 'Type the provider hostname first (e.g. dns.google).' $colorWarn; return }
        # a typed name: every character arrives as typed
        $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
            'settings', 'put', 'global', 'private_dns_specifier', $name)
        if ($result.Text -match 'Exception|denied') { Write-Log $result.Text $colorBad; return }
    }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'put', 'global', 'private_dns_mode', $mode)
    if ($result.Text -match 'Exception|denied') { Write-Log $result.Text $colorBad; return }

    # the resolver takes a moment to switch over
    Wait-Pumped -Milliseconds 1500
    $state = Get-DnsState -Serial $serial
    if ($state.Mode -eq $mode) {
        Write-Log "DNS set to $choice on $serial." $colorGood
    } else {
        Write-Log "The phone kept DNS on '$($state.Mode)'." $colorBad
    }
    $null = Show-DnsState
}

# ---------------------------------------------------------------- hotspot ----

function Test-DeviceLocked {
    param([string]$Serial)

    # a multi-user phone prints one line per profile; only (current) matters
    $trust = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys trust | grep deviceLocked')).Text

    $lines = @($trust -split "`r?`n")
    $current = @($lines | Where-Object { $_ -match '\(current\)' })
    if ($current.Count -gt 0) { return ($current[0] -match 'deviceLocked=1') }

    return ($trust -match 'deviceLocked=1')
}

function Get-TetheringState {
    param([string]$Serial, [string]$Kind = 'WIFI')

    # 'cmd wifi is-softap-enabled' is denied to the shell user, and the access
    # point interface is named differently on every chipset. The tethering
    # service, however, lists what is actually being shared right now.
    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "dumpsys tethering 2>/dev/null | grep -c 'Type: TETHERING_$Kind'")).Text
    if ($dump -match '(\d+)') { return ([int]$Matches[1] -gt 0) }
    return $false
}

function Get-HotspotState {
    param([string]$Serial)

    return Get-TetheringState -Serial $Serial -Kind 'WIFI'
}

function Show-HotspotState {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wifi = Get-TetheringState -Serial $serial -Kind 'WIFI'
    $usb = Get-TetheringState -Serial $serial -Kind 'USB'
    Write-Log ("$serial : Wi-Fi hotspot " + $(if ($wifi) { 'ON' } else { 'off' }) +
        ' | USB tethering ' + $(if ($usb) { 'ON' } else { 'off' })) `
        $(if ($wifi -or $usb) { $colorGood } else { $colorInfo })
    return $wifi
}

function Open-HotspotPage {
    param([string]$Serial, [switch]$WifiPage)

    # the dedicated Wi-Fi hotspot page carries the switch and the credentials;
    # the generic tethering page is the fallback for ROMs without it
    $targets = @()
    if ($WifiPage) {
        $targets += "am start -n 'com.android.settings/.Settings`$WifiTetherSettingsActivity'"
    }
    $targets += 'am start -a android.settings.TETHER_SETTINGS'

    foreach ($command in $targets) {
        $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @($command)
        Wait-Pumped -Milliseconds 2500
        $foreground = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'dumpsys activity activities | grep -m1 ResumedActivity')).Text
        if ($foreground -match 'TetherSettings|WifiTether|Hotspot') { return $true }
    }
    return $false
}

function Update-ToolsCapture {
    # the Screen page's picture follows what was done on the phone, when that page is there
    if (Get-Command Update-Capture -CommandType Function -ErrorAction SilentlyContinue) {
        try { Update-Capture -Quiet } catch { }
    }
}

function Show-HotspotCredentials {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'Unlock the phone first: the settings page cannot open behind the lock screen.' $colorBad
        return
    }

    if (-not (Open-HotspotPage -Serial $serial -WifiPage)) {
        Write-Log 'Could not open the Wi-Fi hotspot page.' $colorBad
        return
    }

    $xml = Get-UiDump -Serial $serial
    $texts = @([regex]::Matches($xml, 'text="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

    # the page lists label then value, so read the entry after each label
    function Get-Following {
        param([string[]]$Items, [string]$Label)
        for ($i = 0; $i -lt $Items.Count - 1; $i++) {
            if ($Items[$i] -like "*$Label*") { return $Items[$i + 1] }
        }
        return $null
    }

    $name = Get-Following -Items $texts -Label 'name'
    $security = Get-Following -Items $texts -Label 'Security'
    $password = Get-Following -Items $texts -Label 'password'

    Write-Log "Hotspot name    : $(if ($name) { $name } else { 'not shown' })" $colorGood
    Write-Log "Security        : $(if ($security) { $security } else { 'not shown' })" $colorInfo
    # U+2022 is the bullet a masked password is drawn with
    if ($password -and $password -notmatch ('^[' + [char]0x2022 + '*.]+$')) {
        Write-Log "Password        : $password" $colorGood
    } else {
        Write-Log 'Password        : hidden by the phone (tap the password row on the screen to reveal it)' $colorWarn
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-ToolsCapture
}

function Get-UiDump {
    param([string]$Serial)

    return (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'uiautomator dump /sdcard/_hub_ui.xml >/dev/null 2>&1; cat /sdcard/_hub_ui.xml')).Text
}

function Set-Hotspot {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wanted = if ($On) { 'ON' } else { 'off' }
    if ((Get-HotspotState -Serial $serial) -eq $On) {
        Write-Log "The Wi-Fi hotspot is already $wanted." $colorInfo
        return
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 600
    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'The phone is locked - unlock it first, the settings page cannot open behind the lock screen.' $colorBad
        return
    }

    Write-Log "Opening the Wi-Fi hotspot page on $serial ..." $colorStep
    if (-not (Open-HotspotPage -Serial $serial -WifiPage)) {
        Write-Log 'The hotspot page did not come up.' $colorBad
        return
    }

    $xml = Get-UiDump -Serial $serial
    $switch = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*checkable="true"[^>]*>')) {
        $node = $match.Value
        if ($node -notmatch 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') { continue }

        # read the coordinates out of $Matches first: the next -match would
        # overwrite them and the tap would land on 0,0
        $left = [int]$Matches[1]; $top = [int]$Matches[2]
        $right = [int]$Matches[3]; $bottom = [int]$Matches[4]

        $switch = [PSCustomObject]@{
            Checked = ($node -match 'checked="true"')
            X       = [int](($left + $right) / 2)
            Y       = [int](($top + $bottom) / 2)
        }
        break
    }

    if (-not $switch) {
        Write-Log 'That page has no hotspot switch to press. What it shows:' $colorBad
        foreach ($text in [regex]::Matches($xml, 'text="([^"]+)"')) {
            Write-Log ('  ' + $text.Groups[1].Value) $colorWarn
        }
        Write-Log 'On phones with a second space, tethering can only be changed in the first space.' $colorWarn
        return
    }

    if ($switch.Checked -ne $On) {
        Write-Log "Tapping the hotspot switch at $($switch.X),$($switch.Y) ..." $colorStep
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($switch.X)", "$($switch.Y)")
        Wait-Pumped -Milliseconds 4000
    }

    if ((Get-HotspotState -Serial $serial) -eq $On) {
        Write-Log "Wi-Fi hotspot is now $wanted." $colorGood
    } else {
        Write-Log "The hotspot did not turn $wanted - check the phone screen." $colorBad
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-ToolsCapture
}

function Set-UsbTethering {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wanted = if ($On) { 'ON' } else { 'off' }
    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is already $wanted." $colorInfo
        return
    }

    # the adb switch works on some ROMs, so try it before touching the UI
    if ($On) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions', 'rndis')
    } else {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions')
    }
    Wait-Pumped -Milliseconds 3000

    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is now $wanted (set through adb)." $colorGood
        return
    }

    Write-Log 'The phone refused the adb switch, using its settings page instead ...' $colorWarn
    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'The phone is locked - unlock it first.' $colorBad
        return
    }
    if (-not (Open-HotspotPage -Serial $serial)) {
        Write-Log 'The tethering page did not come up.' $colorBad
        return
    }

    # find the row labelled USB and press the switch that sits on its line
    $xml = Get-UiDump -Serial $serial
    $rowY = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*text="([^"]*USB[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
        $rowY = [int](([int]$match.Groups[3].Value + [int]$match.Groups[5].Value) / 2)
        break
    }

    $target = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*checkable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
        $top = [int]$match.Groups[2].Value
        $bottom = [int]$match.Groups[4].Value
        $checked = ($match.Value -match 'checked="true"')
        if ($null -eq $rowY -or ($rowY -ge ($top - 40) -and $rowY -le ($bottom + 40))) {
            $target = [PSCustomObject]@{
                Checked = $checked
                X       = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
                Y       = [int](($top + $bottom) / 2)
            }
            break
        }
    }

    if (-not $target) {
        Write-Log 'No USB tethering switch on that page (a second space cannot change it).' $colorBad
        return
    }

    if ($target.Checked -ne $On) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($target.X)", "$($target.Y)")
        Wait-Pumped -Milliseconds 4000
    }

    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is now $wanted." $colorGood
    } else {
        Write-Log "USB tethering did not turn $wanted - check the phone screen." $colorBad
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-ToolsCapture
}

function Open-ToolsTetherSettings {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.TETHER_SETTINGS')).Text $colorInfo
    Wait-Pumped -Milliseconds 1200
    Update-ToolsCapture
}

# ---------------------------------------------------------- input methods ----

function Get-ImeId {
    # The box shows "<id>   (default, enabled)" for each entry.
    $value = "$($ui.ToolsIme.Text)".Trim()
    if (-not $value) { return $null }
    return ($value -split '\s+')[0]
}

function Update-ImeList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $all = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'list', '-a', '-s')).Text
    $enabled = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'list', '-s')).Text
    $default = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'get', 'secure', 'default_input_method')).Text.Trim()

    $ui.ToolsIme.Items.Clear()
    $script:toolsImeSerial = $serial
    foreach ($line in ($all -split "`r?`n")) {
        $id = $line.Trim()
        if (-not $id -or $id -notmatch '/') { continue }

        $tags = @()
        if ($id -eq $default) { $tags += 'default' }
        if ($enabled -match [regex]::Escape($id)) { $tags += 'enabled' } else { $tags += 'disabled' }
        $null = $ui.ToolsIme.Items.Add("$id   ($($tags -join ', '))")
    }

    if ($ui.ToolsIme.Items.Count -eq 0) {
        Write-Log "No input method reported by $serial." $colorWarn
        return
    }

    $ui.ToolsIme.SelectedIndex = 0
    foreach ($item in @($ui.ToolsIme.Items)) {
        if ($default -and "$item" -like "$default*") { $ui.ToolsIme.SelectedItem = $item }
    }
    Write-Log "$($ui.ToolsIme.Items.Count) input methods on $serial (default: $default)." $colorInfo
}

function Set-ImeState {
    param([ValidateSet('enable', 'disable')][string]$Action)

    $id = Get-ImeId
    if (-not $id) { Write-Log 'Pick an input method first (press List).' $colorWarn; return }

    foreach ($serial in @(Get-SelectedSerials)) {
        $default = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'settings', 'get', 'secure', 'default_input_method')).Text.Trim()

        if ($Action -eq 'disable' -and $id -eq $default) {
            Write-Log "$id is the active keyboard on $serial - Android may refuse to disable it." $colorWarn
        }

        # the box can be typed in: the id goes through as one word
        $result = Invoke-DeviceCommand -Serial $serial -Arguments @('ime', $Action, $id)
        $text = $result.Text.Trim()
        $good = ($result.ExitCode -eq 0 -and $text -notmatch 'Error|Unknown|Exception')
        Write-Log ("$serial : " + $(if ($text) { $text } else { "ime $Action $id" })) `
            $(if ($good) { $colorGood } else { $colorBad })
    }
}

function Set-ImeDefault {
    $id = Get-ImeId
    if (-not $id) { Write-Log 'Pick an input method first (press List).' $colorWarn; return }

    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceCommand -Serial $serial -Arguments @('ime', 'set', $id)
        Write-Log ("$serial : " + $(if ($result.Text.Trim()) { $result.Text.Trim() } else { "ime set $id" })) $colorInfo
    }
    Update-ImeList
}

function Reset-ImeList {
    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'reset')
        Write-Log ("$serial : " + $(if ($result.Text.Trim()) { $result.Text.Trim() } else { 'ime reset' })) $colorGood
    }
    Update-ImeList
}

# -------------------------------------------------------- root / recovery ----
# These exist in adb but cannot run on an ordinary retail phone. They are shown
# rather than hidden, marked with a sign, explained by their tooltip, and
# checked against the device that is actually selected. One switch unlocks
# them for somebody on a rooted or userdebug build.

function New-RootAction {
    # one row: mark, command, what it does and needs, run button
    param([string]$Name, [string]$Caption, [string]$Command, [string]$Why, [string]$Needs, $Parent,
        [string]$RunText = 'Run', [switch]$Danger)

    $row = New-Object System.Windows.Controls.Border
    $row.Padding = New-Object System.Windows.Thickness(0, 9, 0, 9)
    $row.BorderBrush = Get-Resource 'Border'
    $top = if ($Parent.Children.Count -gt 0) { 1 } else { 0 }
    $row.BorderThickness = New-Object System.Windows.Thickness(0, $top, 0, 0)
    $row.Background = [System.Windows.Media.Brushes]::Transparent

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($width in @(30, 150, -1, -2)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        if ($width -eq -1) { $column.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        elseif ($width -eq -2) { $column.Width = [System.Windows.GridLength]::Auto }
        else { $column.Width = New-Object System.Windows.GridLength($width) }
        $grid.ColumnDefinitions.Add($column)
    }

    $mark = New-Object System.Windows.Controls.TextBlock
    $mark.Style = Get-Resource 'Glyph'
    $mark.FontSize = 15
    $null = $grid.Children.Add($mark)

    $commandText = New-Object System.Windows.Controls.TextBlock
    $commandText.Text = $Command
    $commandText.FontFamily = Get-Resource 'MonoFont'
    $commandText.FontSize = 12.5
    $commandText.FontWeight = 'SemiBold'
    $commandText.VerticalAlignment = 'Center'
    $commandText.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($commandText, 1)
    $null = $grid.Children.Add($commandText)

    $words = New-Object System.Windows.Controls.StackPanel
    $words.VerticalAlignment = 'Center'
    $words.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $whyText = New-Object System.Windows.Controls.TextBlock
    $whyText.Text = $Why
    $whyText.TextWrapping = 'Wrap'
    $null = $words.Children.Add($whyText)
    $needsText = New-Object System.Windows.Controls.TextBlock
    $needsText.Style = Get-Resource 'MutedLine'
    $needsText.Text = "Needs: $Needs"
    $needsText.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
    $null = $words.Children.Add($needsText)
    [System.Windows.Controls.Grid]::SetColumn($words, 2)
    $null = $grid.Children.Add($words)

    $button = New-Object System.Windows.Controls.Button
    $button.Content = $RunText
    $button.MinWidth = 108
    $button.VerticalAlignment = 'Center'
    $button.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)
    if ($Danger) { $button.Style = Get-Resource 'DangerButton' }
    $button.IsEnabled = $false
    $button.ToolTip = "$Why  Needs: $Needs"
    [System.Windows.Controls.Grid]::SetColumn($button, 3)
    $null = $grid.Children.Add($button)

    $row.Child = $grid
    $row.ToolTip = "$Why  Needs: $Needs"
    $null = $Parent.Children.Add($row)

    $entry = [PSCustomObject]@{ Name = $Name; Caption = $Caption; Needs = $Needs; Button = $button; Mark = $mark; Possible = $false }
    Set-ToolsRootMark -Entry $entry -Possible $false
    $ui[$Name] = $button
    $ui["${Name}Mark"] = $mark
    $null = $script:rootButtons.Add($entry)
    return $entry
}

function Set-ToolsRootMark {
    # a check for what this phone would allow, a blocked sign for the rest
    param($Entry, [bool]$Possible)

    $Entry.Possible = $Possible
    if ($Possible) {
        $Entry.Mark.Text = [string][char]0xE73E
        $Entry.Mark.Foreground = Get-Resource 'Success'
        $Entry.Mark.ToolTip = 'available on this device'
    } else {
        $Entry.Mark.Text = [string][char]0xE733
        $Entry.Mark.Foreground = Get-Resource 'Danger'
        $Entry.Mark.ToolTip = 'not available on this device (or not checked yet)'
    }
}

function Get-ToolsRootPossible {
    # what one row's needs come to on a phone with this build and this shell uid
    param([string]$Needs, [bool]$Rootable, [bool]$AlreadyRoot)

    if ($Needs -like 'nothing*') { return $true }
    if ($Needs -like '*rooted adbd*') { return $AlreadyRoot }
    if ($Needs -like '*userdebug*') { return $Rootable }
    if ($Needs -like '*root*') { return ($Rootable -or $AlreadyRoot) }
    return $false
}

function Reset-RootAvailability {
    # marks read from one phone must not be read later as another phone's answer
    $script:rootCheckedSerial = $null
    if ($ui.ToolsRootState.Text -eq 'not checked yet') { return }
    $ui.ToolsRootState.Text = 'not checked yet'
    $ui.ToolsRootState.Foreground = Get-Resource 'MutedText'
    foreach ($entry in $script:rootButtons) {
        Set-ToolsRootMark -Entry $entry -Possible $false
        $entry.Button.IsEnabled = [bool]$ui.ToolsRootUnlock.IsChecked
    }
}

function ConvertFrom-ToolsJdwpText {
    # the process ids adb jdwp printed, one per line; anything else is not an id
    param([string]$Text)
    return @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
}

function ConvertFrom-ToolsPsLines {
    # pid -> process name, from the lines of "ps -A -o PID,NAME"
    param([string[]]$Lines)

    $names = @{}
    foreach ($line in @($Lines)) {
        if ("$line" -match '^\s*(\d+)\s+(\S+)') { $names[$Matches[1]] = $Matches[2] }
    }
    return $names
}

function Format-ToolsJdwpLines {
    # one log line per debuggable process: its id and its name, '?' for an id ps did not list
    param([string[]]$Pids, [hashtable]$Names)

    return @(foreach ($id in @($Pids)) {
        $name = if ($Names.ContainsKey($id)) { $Names[$id] } else { '?' }
        ("  {0,-7} {1}" -f $id, $name)
    })
}

function Get-JdwpProcesses {
    <#
        adb jdwp prints the ids of processes that accept a Java debugger, and
        then keeps running, adding ids as apps start, until it is stopped.
        Measured on the test phone: still running, with nothing printed, when a
        10 s limit ended it. Through Invoke-Adb the button therefore blocked for
        three minutes and then threw the output away. It now gets a few seconds
        and is stopped, and what it printed by then is the answer. The process
        stopped is the adb client for this one command, never the adb server.
    #>
    param([string]$Serial, [int]$Milliseconds = 3000)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial jdwp"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return $null }

    $buffer = New-Object System.IO.MemoryStream
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
    $errorText = ''
    if ($script:busy -eq 0) { $script:busyWhat = 'adb jdwp (3 s)' }
    $script:busy++
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -and $watch.ElapsedMilliseconds -lt $Milliseconds) {
            Invoke-Pump
            Start-Sleep -Milliseconds 20
        }
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        $null = $process.WaitForExit(2000)
        try { $null = $copy.Wait(1000) } catch { }
        try { $errorText = $process.StandardError.ReadToEnd().Trim() } catch { }
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $process.Dispose()
    }

    $text = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
    return [PSCustomObject]@{
        Pids  = @(ConvertFrom-ToolsJdwpText -Text $text)
        Error = $errorText
    }
}

function Get-DeviceProcessNames {
    # pid -> process name, from one ps on the phone; a bare pid tells nobody anything
    param([string]$Serial)

    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ps', '-A', '-o', 'PID,NAME')
    return (ConvertFrom-ToolsPsLines -Lines @($result.Lines))
}

function Show-JdwpProcesses {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "adb -s $serial jdwp  (for 3 s - it never stops by itself)" $colorStep
    $result = Get-JdwpProcesses -Serial $serial
    if (-not $result) { Write-Log '  adb did not start.' $colorBad; return }
    if ($result.Error) { Write-Log ("  " + $result.Error) $colorBad; return }
    if (@($result.Pids).Count -eq 0) {
        Write-Log ('  no process accepts a debugger. Only apps built as debuggable do, ' +
            'and a retail phone rarely runs one.') $colorInfo
        return
    }

    $names = Get-DeviceProcessNames -Serial $serial
    foreach ($line in (Format-ToolsJdwpLines -Pids $result.Pids -Names $names)) { Write-Log $line $colorGood }
}

function Update-RootAvailability {
    <#
        Marks each action against the device that is selected, rather than
        guessing. A retail phone answers "user" and everything stays off.
    #>
    $serial = Get-TargetSerial
    if (-not $serial) { $ui.ToolsRootState.Text = 'select a device first'; return }

    $buildType = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.build.type')).Text.Trim()
    $debuggable = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.debuggable')).Text.Trim()
    $secure = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.secure')).Text.Trim()
    $uid = (Invoke-DeviceShell -Serial $serial -CommandArguments @('id', '-u')).Text.Trim()

    $rootable = ($buildType -eq 'userdebug') -or ($buildType -eq 'eng') -or ($debuggable -eq '1')
    $alreadyRoot = ($uid -eq '0')

    $text = "build=$buildType  debuggable=$debuggable  secure=$secure  shell uid=$uid"
    if ($alreadyRoot) {
        $ui.ToolsRootState.Foreground = Get-Resource 'Success'
        $text += '   -> adb is already root'
    } elseif ($rootable) {
        $ui.ToolsRootState.Foreground = Get-Resource 'Success'
        $text += '   -> this build allows adb root'
    } else {
        $ui.ToolsRootState.Foreground = Get-Resource 'Warning'
        $text += '   -> a retail build: none of this can work here'
    }
    $ui.ToolsRootState.Text = $text

    foreach ($entry in $script:rootButtons) {
        $possible = Get-ToolsRootPossible -Needs $entry.Needs -Rootable $rootable -AlreadyRoot $alreadyRoot
        Set-ToolsRootMark -Entry $entry -Possible $possible
        $entry.Button.IsEnabled = $possible -or [bool]$ui.ToolsRootUnlock.IsChecked
    }

    $script:rootCheckedSerial = $serial
    Write-Log "$serial : build=$buildType debuggable=$debuggable, shell uid=$uid" $colorInfo
}

function Set-RootUnlock {
    $unlocked = [bool]$ui.ToolsRootUnlock.IsChecked
    foreach ($entry in $script:rootButtons) {
        $entry.Button.IsEnabled = $unlocked -or $entry.Possible
    }
    if ($unlocked) {
        Write-Log 'Root actions unlocked. A retail phone still refuses them, and that refusal is the phone talking.' $colorWarn
    }
}

function Invoke-RootAction {
    param([string[]]$Arguments)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log ("adb -s $serial " + ($Arguments -join ' ')) $colorStep
    $result = Invoke-Adb -CommandArguments (@('-s', $serial) + $Arguments)
    $text = (($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()
    if (-not $text) {
        $text = "(no output, exit $($result.ExitCode))"
        # measured: adb emu on a phone fails with exit 1 and prints nothing at all
        if ($Arguments[0] -eq 'emu' -and $result.ExitCode -ne 0) { $text += ' - a phone has no emulator console' }
    }

    $bad = ($result.ExitCode -ne 0) -or ($text -match 'cannot run as root|not permitted|closed|error')
    Write-Log ("  " + $text) $(if ($bad) { $colorBad } else { $colorGood })
    if ($bad -and $text -match 'production builds') {
        Write-Log '  that is the phone refusing, exactly as this page warned.' $colorInfo
    }
    Wait-Pumped -Milliseconds 800
    Update-DeviceList
    # root and unroot restart adbd on the same phone: the serial stays, the
    # answer can change. Wait for adbd to come back, then read it again.
    if ($Arguments[0] -in 'root', 'unroot') {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'wait-for-device') -TimeoutMs 15000
        Update-RootAvailability
    }
}

function Save-AdbKeygen {
    $path = Select-SaveFile -Filter 'adb key (*.key)|*.key|All files (*.*)|*.*' -FileName 'adbkey'
    if (-not $path) { return }

    $result = Invoke-Adb -CommandArguments @('keygen', $path)
    Write-Log ("keygen: " + ((($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim())) $colorInfo
    if (Test-Path -LiteralPath $path) {
        Write-Log "Wrote $path. Nothing was installed; adb still uses its own key." $colorWarn
    }
}

function Send-Sideload {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $chosen = @(Select-OpenFiles -Filter 'Update package (*.zip)|*.zip')
    if ($chosen.Count -eq 0) { return }
    $package = $chosen[0]

    $sure = Show-Confirm -Title 'Sideload - the phone must already be in recovery' -Yes 'Sideload' -Danger `
        -Text ("Sideload this package to $serial ?" + [Environment]::NewLine + $package + [Environment]::NewLine + [Environment]::NewLine +
            'This writes a system update. A phone that is not in recovery simply refuses; one that is ' +
            'must not be unplugged until it finishes.')
    if (-not $sure) { return }

    Invoke-RootAction -Arguments @('sideload', $package)
}

function Start-ToolsEmuCommand {
    $answer = Show-InputDialog -Title 'emu' -Fields @('Emulator console command') -Values @('help') -OkText 'Send' `
        -Hint 'An emulator only; a phone refuses.'
    if ($null -eq $answer -or -not "$($answer[0])".Trim()) { return }
    Invoke-RootAction -Arguments @('emu', "$($answer[0])".Trim())
}

# the rows, in the original's groups
$btnRootOn = New-RootAction -Name 'ToolsRootOn' -Parent $ui.ToolsRootAdbRows -Caption 'adb root' -Command 'adb root' -Danger `
    -Why 'Restarts adbd with root rights.' -Needs 'userdebug or eng build'
$btnRootOff = New-RootAction -Name 'ToolsRootOff' -Parent $ui.ToolsRootAdbRows -Caption 'adb unroot' -Command 'adb unroot' -Danger `
    -Why 'Puts adbd back to the ordinary shell user.' -Needs 'a rooted adbd'
$btnRootRemount = New-RootAction -Name 'ToolsRootRemount' -Parent $ui.ToolsRootAdbRows -Caption 'remount' -Command 'adb remount' -Danger `
    -Why 'Makes /system writable.' -Needs 'root, and verity off'
$btnRootWaitDevice = New-RootAction -Name 'ToolsRootWaitDevice' -Parent $ui.ToolsRootAdbRows -Caption 'wait-for-device' -Command 'adb wait-for-device' `
    -Why 'Blocks until a device answers. Harmless, and useful after a reboot.' -Needs 'nothing'

$btnRootVerityOff = New-RootAction -Name 'ToolsRootVerityOff' -Parent $ui.ToolsRootImageRows -Caption 'disable-verity' -Command 'adb disable-verity' -Danger `
    -Why 'Turns off verified boot checking on the system image.' -Needs 'root, changes verified boot'
$btnRootVerityOn = New-RootAction -Name 'ToolsRootVerityOn' -Parent $ui.ToolsRootImageRows -Caption 'enable-verity' -Command 'adb enable-verity' -Danger `
    -Why 'Turns verified boot checking back on.' -Needs 'root'

$btnRootSideload = New-RootAction -Name 'ToolsRootSideload' -Parent $ui.ToolsRootOtherRows -Caption 'sideload a zip...' -Command 'adb sideload' -Danger `
    -RunText 'Choose zip...' -Why 'Flashes an OTA package.' -Needs 'the phone in recovery, not in Android'
$btnRootEmu = New-RootAction -Name 'ToolsRootEmu' -Parent $ui.ToolsRootOtherRows -Caption 'emu console...' -Command 'adb emu' `
    -RunText 'Command...' -Why 'Talks to the emulator console.' -Needs 'an emulator, not a phone'
$btnRootJdwp = New-RootAction -Name 'ToolsRootJdwp' -Parent $ui.ToolsRootOtherRows -Caption 'jdwp' -Command 'adb jdwp' `
    -Why 'Lists the processes that accept a Java debugger. adb jdwp never stops by itself, so it is given three seconds.' -Needs 'a debuggable app running'
$btnRootKeygen = New-RootAction -Name 'ToolsRootKeygen' -Parent $ui.ToolsRootOtherRows -Caption 'keygen...' -Command 'adb keygen' `
    -RunText 'Save key...' -Why 'Writes a new adb key pair to a file.' -Needs 'nothing, though it re-pairs nothing by itself'
$btnRootDevPath = New-RootAction -Name 'ToolsRootDevPath' -Parent $ui.ToolsRootOtherRows -Caption 'get-devpath' -Command 'adb get-devpath' `
    -Why 'Prints the USB device path.' -Needs 'nothing'

# ------------------------------------------------------------------ events ----

foreach ($choice in @('automatic (opportunistic)', 'off', 'custom hostname')) { $null = $ui.ToolsDnsMode.Items.Add($choice) }
$ui.ToolsDnsMode.SelectedIndex = 0
$ui.ToolsDnsHost.IsEnabled = $false

# SelectionChanged bubbles up from the combo boxes inside the tabs: only the tab control's own counts
$ui.ToolsTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if (-not [object]::ReferenceEquals($eventArgs.OriginalSource, $sender)) { return }
    if (-not (Test-PageShown -Key 'tools') -or $script:busy -gt 0 -or -not (Get-SelectedSerial)) { return }
    # the root page says what this phone allows as soon as it is opened, from either tab
    if (Test-ToolsTabShown -Tab 'root') { Update-RootAvailability } else { $null = Show-DnsState -Quiet }
})

$ui.ToolsPair.Add_Click({ Start-WirelessPairing })
$ui.ToolsMdns.Add_Click({ Show-MdnsDevices })
$ui.ToolsReconnect.Add_Click({ Invoke-Reconnect })
$ui.ToolsBugReport.Add_Click({ Save-BugReport })
$ui.ToolsTcpip.Add_Click({ Enable-WirelessAdb })
$ui.ToolsConnectButton.Add_Click({ Connect-Wireless })
$ui.ToolsConnect.Add_KeyDown({ param($sender, $eventArgs) if ($eventArgs.Key -eq 'Return') { Connect-Wireless } })
$ui.ToolsDisconnect.Add_Click({ Disconnect-Wireless })
$ui.ToolsRestartServer.Add_Click({ Restart-AdbServer })
$ui.ToolsReverseList.Add_Click({ Invoke-ToolsPageCall -Name 'Show-ReverseTunnels' -Page 'Tethering' })
$ui.ToolsKillRelays.Add_Click({ Invoke-ToolsPageCall -Name 'Stop-StrayRelays' -Page 'Tethering' })
$ui.ToolsRepairTunnel.Add_Click({ Invoke-ToolsPageCall -Name 'Repair-Tunnel' -Page 'Tethering' })

$ui.ToolsInstallApk.Add_Click({ Invoke-ToolsPageCall -Name 'Install-Apk' -Page 'Apps' })
$ui.ToolsScreenshot.Add_Click({ Get-DeviceScreenshot })
$ui.ToolsScreenToggle.Add_Click({ Switch-Screen })
$ui.ToolsReboot.Add_Click({ Restart-Device })
$ui.ToolsBattery.Add_Click({ Show-BatteryAndNetwork })
$ui.ToolsDeviceInfo.Add_Click({ Show-DeviceInfo })

$ui.ToolsDnsRead.Add_Click({ $null = Show-DnsState })
$ui.ToolsDnsAdGuard.Add_Click({
    $ui.ToolsDnsMode.SelectedIndex = 2          # custom hostname
    $ui.ToolsDnsHost.Text = 'dns.adguard.com'
    $ui.ToolsDnsHost.IsEnabled = $true
    Write-Log 'AdGuard selected - press Apply to set it on the phone.' $colorInfo
})
$ui.ToolsDnsApply.Add_Click({ Set-DnsMode })
$ui.ToolsDnsMode.Add_SelectionChanged({ $ui.ToolsDnsHost.IsEnabled = ("$($ui.ToolsDnsMode.SelectedItem)" -like 'custom*') })

$ui.ToolsImeList.Add_Click({ Update-ImeList })
$ui.ToolsImeEnable.Add_Click({ Set-ImeState -Action 'enable' })
$ui.ToolsImeDisable.Add_Click({ Set-ImeState -Action 'disable' })
$ui.ToolsImeDefault.Add_Click({ Set-ImeDefault })
$ui.ToolsImeReset.Add_Click({ Reset-ImeList })

$ui.ToolsHotspotOn.Add_Click({ Set-Hotspot -On $true })
$ui.ToolsHotspotOff.Add_Click({ Set-Hotspot -On $false })
$ui.ToolsHotspotState.Add_Click({ $null = Show-HotspotState })
$ui.ToolsHotspotInfo.Add_Click({ Show-HotspotCredentials })
$ui.ToolsHotspotSettings.Add_Click({ Open-ToolsTetherSettings })
$ui.ToolsUsbTetherOn.Add_Click({ Set-UsbTethering -On $true })
$ui.ToolsUsbTetherOff.Add_Click({ Set-UsbTethering -On $false })

$ui.ToolsRootCheck.Add_Click({ Update-RootAvailability })
$ui.ToolsRootUnlock.Add_Checked({ Set-RootUnlock })
$ui.ToolsRootUnlock.Add_Unchecked({ Set-RootUnlock })
$btnRootOn.Button.Add_Click({ Invoke-RootAction -Arguments @('root') })
$btnRootOff.Button.Add_Click({ Invoke-RootAction -Arguments @('unroot') })
$btnRootRemount.Button.Add_Click({ Invoke-RootAction -Arguments @('remount') })
$btnRootWaitDevice.Button.Add_Click({ Invoke-RootAction -Arguments @('wait-for-device') })
$btnRootVerityOff.Button.Add_Click({ Invoke-RootAction -Arguments @('disable-verity') })
$btnRootVerityOn.Button.Add_Click({ Invoke-RootAction -Arguments @('enable-verity') })
$btnRootSideload.Button.Add_Click({ Send-Sideload })
$btnRootEmu.Button.Add_Click({ Start-ToolsEmuCommand })
$btnRootJdwp.Button.Add_Click({ Show-JdwpProcesses })
$btnRootKeygen.Button.Add_Click({ Save-AdbKeygen })
$btnRootDevPath.Button.Add_Click({ Invoke-RootAction -Arguments @('get-devpath') })

Register-Setting -Name 'Tools.Connect' -Get { $ui.ToolsConnect.Text } -Set { param($v) $ui.ToolsConnect.Text = "$v" }
