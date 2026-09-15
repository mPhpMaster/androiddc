# pages\Radios.ps1 - Wi-Fi, Bluetooth and NFC, one inner page each: what the
# phone is doing, the radio on and off, the Wi-Fi networks it sees and has
# saved, the Bluetooth devices it has paired, and the NFC service's state.
# Opening a radio page reads it at once, as the original's Update-ShownRadio did.

$radiosPage = Register-Page -Key 'radios' -Title 'Radios' -Glyph 'E701' -Section 'Connect' `
    -Xaml 'Radios.xaml' -OnShow { Update-ShownRadio } -OnDeviceChanged {
        # what was read belongs to the phone it came from
        Clear-RadiosPage
        if (Test-PageShown -Key 'radios') { Update-ShownRadio }
    } -Refresh {
        if ($ui.RadiosTabs.SelectedItem -eq $ui.RadiosTabBluetooth) { Update-BluetoothList }
        elseif ($ui.RadiosTabs.SelectedItem -eq $ui.RadiosTabNfc) { Update-NfcState }
        else { Update-WifiList -Saved }
    }

$script:radiosFeatures = @{}
$script:radiosWifiRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:radiosBtRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$ui.RadiosWifiList.ItemsSource = $script:radiosWifiRows
$ui.RadiosBtList.ItemsSource = $script:radiosBtRows

function Clear-RadiosPage {
    $script:radiosWifiRows.Clear()
    $script:radiosBtRows.Clear()
    $ui.RadiosWifiState.Text = 'Wi-Fi: unknown'
    $ui.RadiosBtState.Text = 'Bluetooth: unknown'
    $ui.RadiosNfcState.Text = 'NFC: unknown'
    $ui.RadiosNfcInfo.Text = ''
}

function Update-ShownRadio {
    # a freshly opened radio page should already say what the phone is doing
    if ($script:busy -gt 0 -or -not (Get-SelectedSerial)) { return }
    $tab = $ui.RadiosTabs.SelectedItem
    if ($tab -eq $ui.RadiosTabWifi -and $script:radiosWifiRows.Count -eq 0) { Update-WifiList -Saved }
    elseif ($tab -eq $ui.RadiosTabBluetooth -and $script:radiosBtRows.Count -eq 0) { Update-BluetoothList }
    elseif ($tab -eq $ui.RadiosTabNfc) { Update-NfcState }
}

function Get-RadioFeature {
    # what the hardware actually has, so a missing radio is reported honestly
    param([string]$Serial)

    if (-not $script:radiosFeatures.ContainsKey($Serial)) {
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'features')).Text
        $script:radiosFeatures[$Serial] = $text
    }
    return $script:radiosFeatures[$Serial]
}

function Open-RadiosSettings {
    # the phone's own settings screen, through the Users page
    param([string]$Action)

    if (Get-Command Open-DeviceSettingsScreen -ErrorAction SilentlyContinue) {
        Open-DeviceSettingsScreen -Action $Action
    } else {
        Write-Log "The Users page is not loaded, so $Action cannot be opened from here." $colorWarn
    }
}

# ------------------------------------------------------------------- Wi-Fi ----

function Get-WifiConnection {
    # which network the phone is actually on, not just what it can see
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('cmd', 'wifi', 'status')).Text
    $state = [PSCustomObject]@{ Enabled = $false; Ssid = ''; Rssi = ''; Speed = ''; Frequency = '' }

    if ($text -match 'Wifi is enabled') { $state.Enabled = $true }
    if ($text -match 'Wifi is connected to "([^"]*)"') { $state.Ssid = $Matches[1] }
    # the dump is one long comma separated line, so stop at the comma
    if ($text -match 'RSSI:\s*(-?\d+)') { $state.Rssi = $Matches[1] }
    if ($text -match 'Link speed:\s*([^,]+)') { $state.Speed = $Matches[1].Trim() }
    if ($text -match 'Frequency:\s*([^,]+)') { $state.Frequency = $Matches[1].Trim() }
    return $state
}

function Get-SignalStrength {
    # what the list sorts by, strongest first: the number, not the text -
    # as text "-60 dBm" came before "-45 dBm", since 6 > 4. A saved network
    # that is out of range ("saved") goes last.
    param([string]$Signal)

    if ($Signal -match '^(-?\d+)') { return [int]$Matches[1] }
    return -1000
}

function Get-RadiosWifiRows {
    <#
        The rows of the Wi-Fi list from what the phone printed: the scan
        results (unless -Saved), with the saved networks' ids put on them.
        Saved networks get rows of their own with -Saved, or when nothing
        was scanned. Strongest first.
    #>
    param([string]$ScanText, [string]$SavedText, [switch]$Saved)

    $rows = @()
    if (-not $Saved) {
        foreach ($line in ("$ScanText" -split "`r?`n")) {
            # BSSID Frequency RSSI Age(sec) SSID Flags
            if ($line -match '^\s*([0-9a-fA-F:]{17})\s+(\d+)\s+(-?\d+)\s+\S+\s+(.*?)\s{2,}(.*)$') {
                $rows += [PSCustomObject]@{
                    Ssid     = $Matches[4].Trim()
                    Security = $Matches[5].Trim()
                    Signal   = "$($Matches[3]) dBm"
                    Bssid    = $Matches[1]
                    SavedId  = ''
                }
            }
        }
    }

    # saved networks, so Connect and Forget have something to work with.
    # "nothing scanned" is decided before the first saved row is added: the
    # original tested the growing list, so only one saved network was shown.
    $scanned = $rows.Count
    foreach ($line in ("$SavedText" -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+(.*?)\s{2,}(\S+)\s*$') {
            $id = $Matches[1]
            $ssid = $Matches[2].Trim()
            $security = $Matches[3].Trim()
            # Android 15 prints a network once per security type it accepts,
            # with the same id ("wpa2-psk", then "wpa3-sae^"): one row per id
            if (@($rows | Where-Object { $_.SavedId -eq $id }).Count -gt 0) { continue }
            # case-sensitive, and only a scanned row not yet given an id: "KAIF 5G"
            # and "Kaif 5G" are two saved networks, and -eq made them one row
            $known = @($rows | Where-Object { $_.Ssid -ceq $ssid -and -not $_.SavedId })
            if ($known.Count -gt 0) {
                foreach ($entry in $known) { $entry.SavedId = $id }
            } elseif ($Saved -or $scanned -eq 0) {
                $rows += [PSCustomObject]@{
                    Ssid = $ssid; Security = $security; Signal = 'saved'
                    Bssid = ''; SavedId = $id
                }
            }
        }
    }

    return @($rows | Sort-Object -Property @{ Expression = { Get-SignalStrength $_.Signal } } -Descending)
}

function Show-RadiosWifiRows {
    # the rows into the list, the network the phone is on marked
    param($Rows, $Link)

    $script:radiosWifiRows.Clear()
    foreach ($row in @($Rows)) {
        $joined = [bool]($Link -and $Link.Ssid -and $row.Ssid -ceq $Link.Ssid)
        $signal = if ($joined -and $Link.Rssi) { "$($Link.Rssi) dBm" } else { $row.Signal }
        $script:radiosWifiRows.Add([PSCustomObject]@{
            Shown       = $(if ($joined) { $row.Ssid + '   <- connected' } else { $row.Ssid })
            Ssid        = $row.Ssid
            Security    = $row.Security
            Signal      = $row.Signal
            SignalShown = $signal
            Strength    = (Get-SignalStrength $row.Signal)
            Bssid       = $row.Bssid
            SavedId     = $row.SavedId
            Connected   = $joined
        })
    }
}

function Get-RadiosWifiStateLine {
    param($Link)

    if (-not $Link.Enabled) { return 'Wi-Fi: off' }
    if ($Link.Ssid) {
        $extra = @()
        if ($Link.Rssi) { $extra += "$($Link.Rssi) dBm" }
        if ($Link.Speed) { $extra += $Link.Speed }
        if ($Link.Frequency) { $extra += $Link.Frequency }
        return "Wi-Fi: connected to $($Link.Ssid)" + $(if ($extra.Count -gt 0) { '   (' + ($extra -join ', ') + ')' } else { '' })
    }
    return 'Wi-Fi: on, not connected to any network'
}

function Update-WifiList {
    param([switch]$Scan, [switch]$Saved)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $link = Get-WifiConnection -Serial $serial
    $ui.RadiosWifiState.Text = Get-RadiosWifiStateLine -Link $link

    if ($Scan) {
        Write-Log 'Asking the phone to scan ...' $colorStep
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'start-scan')
        Wait-Pumped -Milliseconds 3000
    }

    $scanText = ''
    if (-not $Saved) {
        $scanText = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'list-scan-results')).Text
    }
    $savedText = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'list-networks')).Text

    $rows = @(Get-RadiosWifiRows -ScanText $scanText -SavedText $savedText -Saved:$Saved)
    Show-RadiosWifiRows -Rows $rows -Link $link
    Write-Log "$($rows.Count) network(s) listed." $colorInfo
}

function Set-WifiRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'wifi', 'set-wifi-enabled', $(if ($On) { 'enabled' } else { 'disabled' }))
    Wait-Pumped -Milliseconds 1200
    Write-Log ("Wi-Fi turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-WifiList
}

function Get-RadiosWifiPassword {
    if ($ui.RadiosWifiShowPass.IsChecked) { return $ui.RadiosWifiPassShown.Text }
    return $ui.RadiosWifiPass.Password
}

function Get-RadiosSecurityType {
    # what cmd wifi connect-network calls the kind of network a row shows
    param([string]$Security)

    if ($Security -match 'wpa3|sae') { return 'wpa3' }
    if ($Security -match 'wpa2|psk|wpa') { return 'wpa2' }
    if ($Security -match 'wep') { return 'wep' }
    if ($Security -match 'owe') { return 'owe' }
    return 'open'
}

function Connect-WifiNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $row = $ui.RadiosWifiList.SelectedItem
    if ($null -eq $row) { Write-Log 'Pick a network first.' $colorWarn; return }

    $security = Get-RadiosSecurityType -Security $row.Security
    $arguments = @('cmd', 'wifi', 'connect-network', $row.Ssid, $security)
    $password = Get-RadiosWifiPassword
    if ($security -ne 'open' -and $security -ne 'owe') {
        if (-not $password) {
            Write-Log "$($row.Ssid) needs a password - type it in the box first." $colorWarn
            return
        }
        $arguments += $password
    }

    Write-Log "Joining $($row.Ssid) ($security) ..." $colorStep
    # a network called "My Home", or a password with a space or a $ in it
    $result = Invoke-DeviceCommand -Serial $serial -Arguments $arguments
    if ($result.Text -match 'Failed|Error|error') {
        Write-Log $result.Text.Trim() $colorBad
    } else {
        Write-Log "Connect requested for $($row.Ssid)." $colorGood
    }
    Wait-Pumped -Milliseconds 2500
    Update-WifiList
}

function Remove-WifiNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $row = $ui.RadiosWifiList.SelectedItem
    if ($null -eq $row) { Write-Log 'Pick a saved network first.' $colorWarn; return }
    if (-not $row.SavedId) { Write-Log "$($row.Ssid) is not saved on the phone." $colorWarn; return }

    $sure = Show-Confirm -Title 'Forget network' -Text "Forget $($row.Ssid) on the phone?" -Yes 'Forget' -Danger
    if (-not $sure) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'forget-network', $row.SavedId)
    Write-Log "Forgot $($row.Ssid)." $colorGood
    Update-WifiList -Saved
}

function Show-WifiStatus {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'status')).Text
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim()) { Write-Log "  $($line.Trim())" $colorInfo }
    }
}

# --------------------------------------------------------------- Bluetooth ----

function Get-BluetoothConnections {
    # the addresses the dump reports as connected, whatever section they sit in
    param([string]$Dump)

    $addresses = @()
    $inConnected = $false
    foreach ($line in ($Dump -split "`r?`n")) {
        if ($line -match '(?i)connected devices:') { $inConnected = $true; continue }
        if ($inConnected) {
            if ($line -match '([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})') { $addresses += $Matches[1].ToUpper() }
            elseif (-not $line.Trim()) { $inConnected = $false }
            continue
        }
        # per profile lines such as "mCurrentDevice: XX:.." or "ActiveDevice: XX:.."
        if ($line -match '(?i)(current|active|connected)\w*\s*(device)?\s*[:=]\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})') {
            $addresses += $Matches[3].ToUpper()
        }
    }
    return @($addresses | Sort-Object -Unique)
}

function Get-RadiosBluetoothRows {
    # the paired devices in a dumpsys bluetooth_manager dump, connected ones marked
    param([string]$Dump)

    $connected = @(Get-BluetoothConnections -Dump $Dump)
    $rows = @()
    $inBonded = $false
    foreach ($line in ("$Dump" -split "`r?`n")) {
        if ($line -match 'Bonded devices:') { $inBonded = $true; continue }
        if ($inBonded) {
            if ($line -match '^\s*([0-9A-Fa-f:]{17})\s*\[([^\]]*)\]\s*(.*)$') {
                $address = $Matches[1].ToUpper()
                $name = $Matches[3].Trim()
                $live = $connected -contains $address
                $rows += [PSCustomObject]@{
                    Shown     = $(if ($live) { $name + '   <- connected' } else { $name })
                    Name      = $name
                    Address   = $Matches[1]
                    Bond      = $(if ($live) { 'connected' } else { 'paired' })
                    Connected = $live
                }
            } elseif (-not $line.Trim()) {
                $inBonded = $false
            }
        }
    }
    return $rows
}

function Update-BluetoothList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if ((Get-RadioFeature -Serial $serial) -notmatch 'android\.hardware\.bluetooth') {
        $ui.RadiosBtState.Text = 'Bluetooth: this device reports no Bluetooth hardware'
        return
    }

    $dump = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'bluetooth_manager')).Text
    $enabled = if ($dump -match '(?m)^\s*enabled:\s*(\S+)') { $Matches[1] } else { 'unknown' }
    $rows = @(Get-RadiosBluetoothRows -Dump $dump)

    $script:radiosBtRows.Clear()
    foreach ($row in $rows) { $script:radiosBtRows.Add($row) }

    $live = @($rows | Where-Object { $_.Bond -eq 'connected' })
    if ($enabled -ne 'true') {
        $ui.RadiosBtState.Text = 'Bluetooth: off'
    } elseif ($live.Count -gt 0) {
        $ui.RadiosBtState.Text = "Bluetooth: on   |   connected to " + (($live | ForEach-Object { $_.Name }) -join ', ')
    } else {
        $ui.RadiosBtState.Text = "Bluetooth: on   |   $($rows.Count) paired, none connected"
    }
    Write-Log "$($rows.Count) paired device(s), $($live.Count) connected." $colorInfo
}

function Set-BluetoothRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'bluetooth_manager', $(if ($On) { 'enable' } else { 'disable' }))
    Wait-Pumped -Milliseconds 1500
    Write-Log ("Bluetooth turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-BluetoothList
}

function Copy-RadiosBluetoothAddress {
    $rows = @($ui.RadiosBtList.SelectedItems)
    if ($rows.Count -eq 0) { Write-Log 'Nothing selected.' $colorWarn; return }
    $lines = foreach ($row in $rows) { "$($row.Name)`t$($row.Address)" }
    [System.Windows.Clipboard]::SetText((@($lines) -join [Environment]::NewLine))
    Write-Log "Copied $($rows.Count) row(s) to the clipboard." $colorInfo
}

# --------------------------------------------------------------------- NFC ----

function Get-RadiosNfcLines {
    # the lines of dumpsys nfc that say what the service is doing, at most 14
    param([string]$Dump)

    $lines = @()
    foreach ($line in ("$Dump" -split "`r?`n")) {
        if ($line -match 'mState=|mIsSecureNfcEnabled|mScreenState|NfcService|mPollingDisableDeathRecipients|SecureNfc') {
            $lines += $line.Trim()
        }
        if ($lines.Count -ge 14) { break }
    }
    return $lines
}

function Update-NfcState {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if ((Get-RadioFeature -Serial $serial) -notmatch 'android\.hardware\.nfc') {
        $ui.RadiosNfcState.Text = 'NFC: not present on this device'
        $ui.RadiosNfcInfo.Text = 'pm list features reports no android.hardware.nfc on this phone.'
        return
    }

    $dump = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'nfc')).Text
    $state = if ($dump -match 'mState=(\S+)') { $Matches[1] } else { 'unknown' }
    $ui.RadiosNfcState.Text = "NFC: $state"
    $ui.RadiosNfcInfo.Text = (@(Get-RadiosNfcLines -Dump $dump) -join "`r`n")
}

function Set-NfcRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'svc', 'nfc', $(if ($On) { 'enable' } else { 'disable' }))
    if ($result.Text -match 'Killed|denied|Exception') { Write-Log $result.Text.Trim() $colorBad }
    Wait-Pumped -Milliseconds 1500
    Write-Log ("NFC turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-NfcState
}

# ------------------------------------------------------------------- events ----

$ui.RadiosTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    # the lists inside raise SelectionChanged too, and it bubbles up to here
    if (-not [object]::ReferenceEquals($eventArgs.OriginalSource, $ui.RadiosTabs)) { return }
    # the first selection happens while WPF lays the page out, where adb
    # (which lets the window draw meanwhile) is not allowed; OnShow reads then
    if ($eventArgs.RemovedItems.Count -eq 0) { return }
    if (Test-PageShown -Key 'radios') { Update-ShownRadio }
})

$ui.RadiosWifiOn.Add_Click({ Set-WifiRadio -On $true })
$ui.RadiosWifiOff.Add_Click({ Set-WifiRadio -On $false })
$ui.RadiosWifiScan.Add_Click({ Update-WifiList -Scan })
$ui.RadiosWifiSaved.Add_Click({ Update-WifiList -Saved })
$ui.RadiosWifiConnect.Add_Click({ Connect-WifiNetwork })
$ui.RadiosWifiForget.Add_Click({ Remove-WifiNetwork })
$ui.RadiosWifiStatus.Add_Click({ Show-WifiStatus })
$ui.RadiosWifiSettings.Add_Click({ Open-RadiosSettings -Action 'android.settings.WIFI_SETTINGS' })
$ui.RadiosWifiShowPass.Add_Checked({
    $ui.RadiosWifiPassShown.Text = $ui.RadiosWifiPass.Password
    $ui.RadiosWifiPass.Visibility = 'Collapsed'
    $ui.RadiosWifiPassShown.Visibility = 'Visible'
})
$ui.RadiosWifiShowPass.Add_Unchecked({
    $ui.RadiosWifiPass.Password = $ui.RadiosWifiPassShown.Text
    $ui.RadiosWifiPassShown.Visibility = 'Collapsed'
    $ui.RadiosWifiPass.Visibility = 'Visible'
})
$ui.RadiosWifiList.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    # a row, not the header or the empty space under the rows
    if ([System.Windows.Controls.ItemsControl]::ContainerFromElement($sender, $eventArgs.OriginalSource) -is [System.Windows.Controls.ListViewItem]) {
        Connect-WifiNetwork
    }
})

$ui.RadiosBtOn.Add_Click({ Set-BluetoothRadio -On $true })
$ui.RadiosBtOff.Add_Click({ Set-BluetoothRadio -On $false })
$ui.RadiosBtRefresh.Add_Click({ Update-BluetoothList })
$ui.RadiosBtSettings.Add_Click({ Open-RadiosSettings -Action 'android.settings.BLUETOOTH_SETTINGS' })
$ui.RadiosBtCopy.Add_Click({ Copy-RadiosBluetoothAddress })

$ui.RadiosNfcOn.Add_Click({ Set-NfcRadio -On $true })
$ui.RadiosNfcOff.Add_Click({ Set-NfcRadio -On $false })
$ui.RadiosNfcRefresh.Add_Click({ Update-NfcState })
$ui.RadiosNfcSettings.Add_Click({ Open-RadiosSettings -Action 'android.settings.NFC_SETTINGS' })

Set-ListColumnsSortable -List $ui.RadiosWifiList
Set-ListColumnsSortable -List $ui.RadiosBtList
Add-ListContextMenu -List $ui.RadiosWifiList -Buttons @($ui.RadiosWifiConnect, $ui.RadiosWifiForget, $null, $ui.RadiosWifiStatus)
Add-ListContextMenu -List $ui.RadiosBtList -Buttons @($ui.RadiosBtCopy, $ui.RadiosBtSettings)
Register-Setting -Name 'Radios.Tab' -Get { [int]$ui.RadiosTabs.SelectedIndex } -Set { param($v) $ui.RadiosTabs.SelectedIndex = [int]$v }
