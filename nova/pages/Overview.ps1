# pages\Overview.ps1 - the home page, ported from the original Device tab: how
# the phone is doing (battery, temperature, memory), its details, the quick
# toggles showing what the phone reports, torch, buzz, developer options, and
# the phone number box for calls, SMS and USSD.

$script:overviewSerial = $null
$script:toggleSerial = $null

$overviewPage = Register-Page -Key 'overview' -Title 'Overview' -Glyph 'E80F' -Section 'Workspace' -Xaml 'Overview.xaml' `
    -OnShow {
        Update-OverviewMetrics
        if ((Get-SelectedSerial) -ne $script:toggleSerial) { Show-ToggleStates -Quiet }
    } `
    -OnDeviceChanged {
        # what is on this page belongs to one phone: read the new one if the page
        # is open, otherwise clear it so it is never shown as another phone's
        if (Test-PageShown -Key 'overview') {
            Update-OverviewMetrics
            if ((Get-SelectedSerial) -ne $script:toggleSerial) { Show-ToggleStates -Quiet }
        } elseif ((Get-SelectedSerial) -ne $script:overviewSerial) {
            Clear-OverviewDevice
        }
    } `
    -Refresh { Show-DeviceTab }

function Update-OverviewCapture {
    # the Screen page takes the picture; without it loaded, nothing to refresh
    if (Get-Command Update-Capture -ErrorAction SilentlyContinue) { Update-Capture -Quiet }
}

# ---------------------------------------------------------------- metrics ----

function Clear-OverviewDevice {
    foreach ($name in @('Battery', 'Temp', 'Memory')) {
        $ui["Overview${name}Value"].Text = '--'
        $ui["Overview${name}Note"].Text = ''
        $ui["Overview${name}Bar"].Value = 0
    }
    $ui.OverviewDetails.Text = ''
    $ui.OverviewDetailsHint.Visibility = 'Visible'
    Set-ToggleMarks $null
    $script:toggleSerial = $null
    $script:overviewSerial = $null
}

function Update-OverviewMetrics {
    # the three cards; read again only for another phone, unless -Force
    param([switch]$Force)

    $first = (Get-SelectedDevice)
    if ($null -eq $first -or $first.State -ne 'device') { Clear-OverviewDevice; return }
    $serial = $first.Serial
    if (-not $Force -and $serial -eq $script:overviewSerial) { return }

    # the header has just read the battery for this phone; no second trip for it
    if (-not $Force -and $script:statusSerial -eq $serial -and $script:lastBattery) {
        $battery = $script:lastBattery
    } else {
        $battery = Get-BatteryInfo -Serial $serial
    }
    $memory = Get-MemoryInfo -Serial $serial
    # another phone may have been picked while those were read
    if ((Get-SelectedSerial) -ne $serial) { return }
    $script:overviewSerial = $serial

    if ($null -ne $battery.Level) {
        $ui.OverviewBatteryValue.Text = "$($battery.Level)%"
        $ui.OverviewBatteryBar.Value = $battery.Level
        $low = $battery.Level -le 15 -and $battery.Status -ne 'charging'
        $ui.OverviewBatteryBar.Foreground = Get-Resource $(if ($low) { 'Warning' } else { 'Success' })
    } else {
        $ui.OverviewBatteryValue.Text = '?'
        $ui.OverviewBatteryBar.Value = 0
    }
    $ui.OverviewBatteryNote.Text = $battery.Status

    if ($null -ne $battery.Temperature) {
        # the degree sign from its code point: this file stays ASCII
        $ui.OverviewTempValue.Text = ('{0:N1}' -f $battery.Temperature) + ' ' + [char]0x00B0 + 'C'
        $ui.OverviewTempNote.Text = if ($battery.Temperature -ge 45) { 'hot' } elseif ($battery.Temperature -ge 40) { 'warm' } else { 'normal' }
        # 20 C empty, 50 C full
        $ui.OverviewTempBar.Value = [Math]::Max(0, [Math]::Min(100, ($battery.Temperature - 20) / 30 * 100))
        $ui.OverviewTempBar.Foreground = Get-Resource $(if ($battery.Temperature -ge 40) { 'Warning' } else { 'Brand' })
    } else {
        $ui.OverviewTempValue.Text = '?'
        $ui.OverviewTempNote.Text = ''
        $ui.OverviewTempBar.Value = 0
    }

    if ($memory) {
        $ui.OverviewMemoryValue.Text = ('{0:N1} GB' -f ($memory.Used / 1GB))
        $ui.OverviewMemoryNote.Text = ('of {0:N0} GB' -f ($memory.Total / 1GB))
        $ui.OverviewMemoryBar.Value = [Math]::Round($memory.Used / $memory.Total * 100)
    } else {
        $ui.OverviewMemoryValue.Text = '?'
        $ui.OverviewMemoryNote.Text = ''
        $ui.OverviewMemoryBar.Value = 0
    }
}

# ---------------------------------------------------------------- details ----

function Get-DeviceReport {
    param([string]$Serial)

    $lines = @("Device : $Serial")
    $props = [ordered]@{
        'Model'    = 'ro.product.model'
        'Brand'    = 'ro.product.brand'
        'Name'     = 'ro.product.name'
        'Android'  = 'ro.build.version.release'
        'SDK'      = 'ro.build.version.sdk'
        'Build'    = 'ro.build.display.id'
        'ABI'      = 'ro.product.cpu.abi'
        'Serialno' = 'ro.serialno'
    }
    foreach ($key in $props.Keys) {
        $value = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', $props[$key])).Text.Trim()
        $lines += ('{0,-9}: {1}' -f $key, $value)
    }

    $size = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('wm', 'size')).Text.Trim() -replace "`r?`n", ' / '
    $density = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('wm', 'density')).Text.Trim() -replace "`r?`n", ' / '
    $lines += ('{0,-9}: {1}  |  {2}' -f 'Screen', $size, $density)

    $lines += ('{0,-9}: {1}' -f 'Battery', (Get-BatteryInfo -Serial $Serial).Line)
    $lines += ('{0,-9}: {1}' -f 'Network', (Get-SignalInfo -Serial $Serial).Line)

    $ip = $null
    if (Get-Command Get-DeviceIp -ErrorAction SilentlyContinue) { $ip = Get-DeviceIp -Serial $Serial }
    $lines += ('{0,-9}: {1}' -f 'Wi-Fi IP', $(if ($ip) { $ip } else { 'none' }))

    $storage = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('df -h /data | tail -1')).Text.Trim()
    if ($storage) { $lines += ('{0,-9}: {1}' -f 'Storage', $storage) }

    $uptime = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('uptime')).Text.Trim()
    if ($uptime) { $lines += ('{0,-9}: {1}' -f 'Uptime', $uptime) }

    $client = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'packages', $script:packageName)).Text
    $lines += ('{0,-9}: {1}' -f 'gnirehtet', $(if ($client -match 'package:') { 'client installed' } else { 'client not installed' }))

    return ($lines -join [Environment]::NewLine)
}

function Show-DeviceTab {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (-not (Test-PageShown -Key 'overview')) { Show-Page -Page 'overview' }
    $ui.OverviewDetailsHint.Visibility = 'Collapsed'
    $ui.OverviewDetails.Text = "reading $serial ..."

    $report = Get-DeviceReport -Serial $serial
    if ((Get-SelectedSerial) -ne $serial) { return }
    $ui.OverviewDetails.Text = $report
    Write-Log "Loaded details for $serial." $colorInfo
    Update-OverviewMetrics -Force
    Show-ToggleStates -Quiet
    Update-OverviewCapture
}

function Show-Notifications {
    $serial = if ((Get-Variable -Name captureSerial -Scope Script -ErrorAction SilentlyContinue) -and $script:captureSerial) {
        $script:captureSerial
    } else { Get-TargetSerial }
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'statusbar', 'expand-notifications')
    Write-Log "opened the notification panel on $serial" $colorInfo
    Wait-Pumped -Milliseconds 700
    Update-OverviewCapture
}

# ---------------------------------------------------------------- toggles ----

# what each toggle reads, in the order the log names them, with its caption
$script:toggleReads = [ordered]@{
    rotation  = 'settings get system accelerometer_rotation'
    location  = 'cmd location is-location-enabled'
    bluetooth = 'settings get global bluetooth_on'
    wifi      = 'settings get global wifi_on'
    saver     = 'settings get global low_power'
    ringvibe  = 'settings get system vibrate_when_ringing'
    haptics   = 'settings get system haptic_feedback_enabled'
    showtaps  = 'settings get system show_touches'
    stayawake = 'settings get global stay_on_while_plugged_in'
    devopts   = 'settings get global development_settings_enabled'
}
$script:toggleCaptions = [ordered]@{
    rotation = 'Auto-rotate'; location = 'Location'; bluetooth = 'Bluetooth'; wifi = 'Wi-Fi'
    saver = 'Battery saver'; ringvibe = 'Vibrate on ring'; haptics = 'Touch haptics'
    showtaps = 'Show taps'; stayawake = 'Stay awake'; devopts = 'Developer options'
}
$script:toggleButtons = @{}

function New-OverviewToggleRows {
    # one row per toggle: its name, and an On | Off pair on a grey track
    foreach ($key in $script:toggleCaptions.Keys) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
        $caption = New-Object System.Windows.Controls.TextBlock
        $caption.Text = $script:toggleCaptions[$key]
        $caption.VerticalAlignment = 'Center'
        $null = $row.Children.Add($caption)

        $track = New-Object System.Windows.Controls.Border
        $track.Background = Get-Resource 'Surface'
        $track.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $track.Padding = New-Object System.Windows.Thickness(2)
        $track.HorizontalAlignment = 'Right'
        $pair = New-Object System.Windows.Controls.StackPanel
        $pair.Orientation = 'Horizontal'
        $track.Child = $pair

        $buttons = @()
        foreach ($enabled in @($true, $false)) {
            $button = New-Object System.Windows.Controls.Button
            $button.Content = if ($enabled) { 'On' } else { 'Off' }
            $button.MinHeight = 26
            $button.MinWidth = 46
            $button.Padding = New-Object System.Windows.Thickness(10, 0, 10, 0)
            $button.FontSize = 12
            $button.Background = [System.Windows.Media.Brushes]::Transparent
            $button.Foreground = Get-Resource 'MutedText'
            $button.ToolTip = "Turn $($script:toggleCaptions[$key].ToLowerInvariant()) $($button.Content.ToLowerInvariant()) on every selected device"
            $button.Tag = [PSCustomObject]@{ Feature = $key; Enabled = $enabled }
            $button.Add_Click({ param($sender, $eventArgs) Set-DeviceToggle -Feature $sender.Tag.Feature -Enabled $sender.Tag.Enabled })
            $null = $pair.Children.Add($button)
            $buttons += $button
        }
        $script:toggleButtons[$key] = $buttons
        [System.Windows.Controls.Grid]::SetColumn($track, 0)
        $null = $row.Children.Add($track)
        $null = $ui.OverviewToggleHost.Children.Add($row)
    }
}

function ConvertFrom-ToggleOutput {
    # "name=value" lines into on / off / unknown ($null) per toggle
    param([string]$Text)

    $states = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^(\w+)=(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        $state = $null
        if ($key -eq 'stayawake') {
            # a bit mask of chargers: AC, USB, wireless; any of them means on
            if ($value -match '^\d+$') { $state = ([int]$value -ne 0) }
        } elseif ($value -eq '1' -or $value -eq 'true') {
            $state = $true
        } elseif ($value -eq '0' -or $value -eq 'false') {
            $state = $false
        }
        $states[$key] = $state
    }
    return $states
}

function Set-ToggleMarks {
    # the side matching the phone is lifted onto a white chip; a state the
    # phone does not report lifts neither
    param($States)

    foreach ($key in @($script:toggleButtons.Keys)) {
        $state = $null
        if ($States -and $States.ContainsKey($key)) { $state = $States[$key] }
        for ($i = 0; $i -lt 2; $i++) {
            $button = $script:toggleButtons[$key][$i]
            $lit = ($null -ne $state -and $state -eq ($i -eq 0))
            if ($lit) {
                $button.Background = Get-Resource 'Card'
                $button.Foreground = Get-Resource 'Brand'
                $button.FontWeight = 'SemiBold'
            } else {
                $button.Background = [System.Windows.Media.Brushes]::Transparent
                $button.Foreground = Get-Resource 'MutedText'
                $button.FontWeight = 'Normal'
            }
        }
    }
}

function Test-ToggleLit {
    param($Button)
    return ($Button.FontWeight -eq [System.Windows.FontWeights]::SemiBold)
}

function Show-ToggleStates {
    # -Quiet: for the marks only, as the page opens or the phone changes
    param([switch]$Quiet)

    $serial = if ($Quiet) { Get-SelectedSerial } else { Get-TargetSerial }
    $first = (Get-SelectedDevice)
    if (-not $serial -or $null -eq $first -or $first.State -ne 'device') {
        Set-ToggleMarks $null
        $script:toggleSerial = $null
        return
    }

    # one trip to the phone instead of ten
    $command = @($script:toggleReads.GetEnumerator() | ForEach-Object {
        'echo {0}=$({1} 2>/dev/null)' -f $_.Key, $_.Value }) -join '; '
    $states = ConvertFrom-ToggleOutput (Invoke-DeviceShellText -Serial $serial -Command $command).Text
    if ((Get-SelectedSerial) -ne $serial) { return }
    Set-ToggleMarks $states
    $script:toggleSerial = $serial
    if ($Quiet) { return }

    $torch = Get-TorchState -Serial $serial
    $words = @($script:toggleReads.Keys | ForEach-Object {
        $value = if ($null -eq $states[$_]) { '?' } elseif ($states[$_]) { 'on' } else { 'off' }
        "$_=$value" })
    Write-Log ("$serial : " + ($words -join '  ') + "  torch=$torch") $colorInfo
}

function Set-DeviceToggle {
    param(
        [ValidateSet('rotation', 'location', 'bluetooth', 'wifi', 'saver', 'ringvibe', 'haptics',
                     'devopts', 'showtaps', 'stayawake')]
        [string]$Feature,
        [bool]$Enabled
    )

    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    foreach ($serial in $serials) {
        switch ($Feature) {
            'rotation'  { $command = @('settings', 'put', 'system', 'accelerometer_rotation', $(if ($Enabled) { '1' } else { '0' })) }
            'location'  { $command = @('cmd', 'location', 'set-location-enabled', $(if ($Enabled) { 'true' } else { 'false' })) }
            'bluetooth' { $command = @('svc', 'bluetooth', $(if ($Enabled) { 'enable' } else { 'disable' })) }
            'wifi'      { $command = @('svc', 'wifi', $(if ($Enabled) { 'enable' } else { 'disable' })) }
            'saver'     { $command = @('settings', 'put', 'global', 'low_power', $(if ($Enabled) { '1' } else { '0' })) }
            'ringvibe'  { $command = @('settings', 'put', 'system', 'vibrate_when_ringing', $(if ($Enabled) { '1' } else { '0' })) }
            'haptics'   { $command = @('settings', 'put', 'system', 'haptic_feedback_enabled', $(if ($Enabled) { '1' } else { '0' })) }
            'devopts'   { $command = @('settings', 'put', 'global', 'development_settings_enabled', $(if ($Enabled) { '1' } else { '0' })) }
            'showtaps'  { $command = @('settings', 'put', 'system', 'show_touches', $(if ($Enabled) { '1' } else { '0' })) }
            # 3 = keep the screen on while charging over AC or USB
            'stayawake' { $command = @('settings', 'put', 'global', 'stay_on_while_plugged_in', $(if ($Enabled) { '3' } else { '0' })) }
        }

        $result = Invoke-DeviceShell -Serial $serial -CommandArguments $command
        $text = $result.Text.Trim()
        $failed = ($result.ExitCode -ne 0 -or $text -match 'Exception|Error|denied|Unknown command')
        Write-Log ("$serial : " + ($command -join ' ') + $(if ($text) { "  ->  $text" } else { '' })) `
            $(if ($failed) { $colorBad } else { $colorGood })
    }

    Show-ToggleStates
}

# ------------------------------------------------------ torch, buzz, dev ----

function Get-TorchState {
    param([string]$Serial)

    # the camera service logs every torch change; the newest line wins
    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys media.camera | grep -m1 Torch')).Text
    if ($dump -match 'turned (on|off)') { return $Matches[1] }
    return 'unknown'
}

function Switch-Torch {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $before = Get-TorchState -Serial $serial
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'statusbar', 'click-tile', 'com.android.systemui/.qs.tiles.FlashlightTile')
    Wait-Pumped -Milliseconds 1200
    $after = Get-TorchState -Serial $serial

    if ($after -ne $before -and $after -ne 'unknown') {
        Write-Log "Torch is now $after on $serial." $colorGood
        Show-Toast "Torch is now $after"
        return
    }

    # 'flashlight' is a built-in tile, not a TileService, so click-tile is a
    # no-op on many ROMs. Fall back to the panel the user can tap on the Screen page.
    Write-Log "The ROM ignored the torch command (torch stays $before)." $colorWarn
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 600
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'statusbar', 'expand-settings')
    Wait-Pumped -Milliseconds 800
    Update-OverviewCapture
    Write-Log 'Opened quick settings - tap the Flashlight tile on the Screen page.' $colorWarn
}

function Send-Buzz {
    foreach ($serial in @(Get-SelectedSerials)) {
        $before = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys vibrator_manager | grep -c finished')).Text.Trim()
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'vibrator_manager', 'synced', 'oneshot', '400')
        Wait-Pumped -Milliseconds 900
        $after = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys vibrator_manager | grep -c finished')).Text.Trim()

        if ($after -ne $before) {
            Write-Log "$serial buzzed." $colorGood
        } else {
            Write-Log "$serial : the ROM ignored the shell vibrate command." $colorWarn
        }
    }
}

function Open-DeveloperOptions {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('settings', 'put', 'global', 'development_settings_enabled', '1')
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-a', 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS')
    Write-Log $result.Text $colorInfo
    Wait-Pumped -Milliseconds 900
    Update-OverviewCapture
}

# ----------------------------------------------------------- phone number ----

function Start-QuickCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $ui.OverviewNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }
    if (-not (Show-Confirm -Title 'Call' -Text "Call $number from $serial ?" -Yes 'Call')) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$number")
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text.Trim() $colorBad; return }
    Write-Log "Calling $number from $serial." $colorGood
    Wait-Pumped -Milliseconds 1500
    Update-OverviewCapture
}

function Stop-OverviewCall {
    # the Contacts page owns Stop-PhoneCall; the same key when it is not loaded
    if (Get-Command Stop-PhoneCall -ErrorAction SilentlyContinue) { Stop-PhoneCall; return }
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    # KEYCODE_ENDCALL
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '6')
    Write-Log 'Sent the end-call key.' $colorInfo
    Wait-Pumped -Milliseconds 800
    Update-OverviewCapture
}

function Open-QuickDialer {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $ui.OverviewNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }

    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('am', 'start', '-a', 'android.intent.action.DIAL', '-d', "tel:$number")
    Write-Log "Put $number in the dialer without calling." $colorInfo
    Wait-Pumped -Milliseconds 1200
    Update-OverviewCapture
}

function Send-QuickSms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $ui.OverviewNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }

    $command = Get-Command Send-Sms -ErrorAction SilentlyContinue
    if (-not $command) { Write-Log 'The Messages page is not loaded, so there is nothing to compose the SMS with.' $colorWarn; return }

    $answer = Show-InputDialog -Title 'Send SMS' -Fields @('Message') -Multiline @('Message') -OkText 'Compose' `
        -Hint "For $number. It is composed in the phone's own SMS app, which sends it."
    if (-not $answer -or -not $answer[0].Trim()) { return }

    if ($command.Parameters.ContainsKey('Body')) {
        Send-Sms -Number $number -Body $answer[0]
    } else {
        Write-Log 'The Messages page cannot take a number and a body from here yet.' $colorWarn
    }
}

function Send-Ussd {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $code = $ui.OverviewNumber.Text.Trim()
    if (-not $code) { Write-Log 'Type the code first, for example *111#.' $colorWarn; return }
    if ($code -notmatch '^[\d\*\#\+]+$') {
        Write-Log 'A USSD code is digits with * and #, such as *111# or *100*1#.' $colorWarn
        return
    }

    $sure = Show-Confirm -Title 'Send USSD' -Danger -Yes 'Send' -Text (
        "Send $code from $serial ?`r`n`r`nThe operator answers on the phone screen. Some codes cost money or change your plan.")
    if (-not $sure) { return }

    # a # ends the tel: URI unless it is encoded
    $encoded = $code -replace '#', '%23'
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$encoded")
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text.Trim() $colorBad; return }

    Write-Log "Sent $code. Watch the phone screen for the answer." $colorGood
    Wait-Pumped -Milliseconds 3000
    Update-OverviewCapture
}

# ----------------------------------------------------------------- events ----

New-OverviewToggleRows

$ui.OverviewLoad.Add_Click({ Show-DeviceTab })
$ui.OverviewCopy.Add_Click({
    if ($ui.OverviewDetails.Text.Trim()) {
        [System.Windows.Clipboard]::SetText($ui.OverviewDetails.Text)
        Write-Log 'Device details copied to the clipboard.' $colorInfo
        Show-Toast 'Details copied'
    }
})
$ui.OverviewDetails.Add_TextChanged({
    $ui.OverviewDetailsHint.Visibility = if ($ui.OverviewDetails.Text) { 'Collapsed' } else { 'Visible' }
})
$ui.OverviewOpenScreen.Add_Click({
    if (-not (Get-Page -Key 'screen')) { Write-Log 'The Screen page is not loaded.' $colorWarn; return }
    Show-Page -Page 'screen'
    if (Get-Command Update-Capture -ErrorAction SilentlyContinue) { Update-Capture }
})
$ui.OverviewMirror.Add_Click({
    if (Get-Command Start-Scrcpy -ErrorAction SilentlyContinue) { Start-Scrcpy }
    else { Write-Log 'The Mirroring page is not loaded, so scrcpy cannot be started from here.' $colorWarn }
})
$ui.OverviewTorch.Add_Click({ Switch-Torch })
$ui.OverviewBuzz.Add_Click({ Send-Buzz })
$ui.OverviewReadStates.Add_Click({ Show-ToggleStates })
$ui.OverviewDevScreen.Add_Click({ Open-DeveloperOptions })

$ui.OverviewCall.Add_Click({ Start-QuickCall })
$ui.OverviewHangUp.Add_Click({ Stop-OverviewCall })
$ui.OverviewSms.Add_Click({ Send-QuickSms })
$ui.OverviewUssd.Add_Click({ Send-Ussd })
$ui.OverviewDialer.Add_Click({ Open-QuickDialer })
$ui.OverviewNumber.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Start-QuickCall }
})

# the device picker: a double click loads this page's details, as the original list did
$ui.DeviceList.Add_MouseDoubleClick({ Show-DeviceTab })
