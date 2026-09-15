# pages\Mirroring.ps1 - scrcpy: the picture, the window, what the phone does while
# mirrored, what to mirror and record, keyboard / mouse / OTG, and on the second
# inner page every other scrcpy option. Builds the command line, starts one window
# per selected device, and closes the windows it started.

$mirroringPage = Register-Page -Key 'mirroring' -Title 'Mirroring' -Glyph 'EC15' -Section 'Workspace' `
    -Xaml 'Mirroring.xaml' -OnDeviceChanged { Clear-MirroringPhoneChoices } -Refresh { Update-VideoCodecList }

# every scrcpy this program started; Apps adds its "Own scrcpy window" here too
if (-not (Get-Variable -Name scrcpyProcesses -Scope Script -ErrorAction SilentlyContinue)) { $script:scrcpyProcesses = @() }
$script:mirroringFillingApps = $false
$script:mirroringAppsWarned = $false

# ------------------------------------------------------------- the choices ----

function Set-MirroringChoices {
    # a combo box's fixed choices, and the one shown at first
    param($Box, [string[]]$Items, [string]$Selected)

    $Box.Items.Clear()
    foreach ($item in $Items) { $null = $Box.Items.Add($item) }
    if ($Box.IsEditable) { $Box.Text = $Selected } else { $Box.SelectedItem = $Selected }
}

Set-MirroringChoices $ui.MirroringMaxSize @('0', '800', '1024', '1280', '1600', '1920') '1280'
Set-MirroringChoices $ui.MirroringBitrate @('2M', '4M', '8M', '16M', '32M') '8M'
Set-MirroringChoices $ui.MirroringFps @('0', '30', '60', '90', '120') '60'
Set-MirroringChoices $ui.MirroringCodec @('default', 'h264', 'h265', 'av1') 'default'
Set-MirroringChoices $ui.MirroringDisplay @('0') '0'
Set-MirroringChoices $ui.MirroringKeyboard @('default', 'sdk', 'uhid', 'aoa', 'disabled') 'default'
Set-MirroringChoices $ui.MirroringMouse @('default', 'sdk', 'uhid', 'aoa', 'disabled') 'default'
Set-MirroringChoices $ui.MirroringGamepad @('default', 'uhid', 'aoa', 'disabled') 'default'
Set-MirroringChoices $ui.MirroringRecordFormat @('from the name', 'mp4', 'mkv', 'm4a', 'mka', 'opus', 'aac', 'flac', 'wav') 'from the name'
Set-MirroringChoices $ui.MirroringRecordOrientation @('0', '90', '180', '270', 'flip0', 'flip90', 'flip180', 'flip270') '0'
Set-MirroringChoices $ui.MirroringOrientation @('as it comes', '0', '90', '180', '270', 'flip0', 'flip90', 'flip180', 'flip270') 'as it comes'
Set-MirroringChoices $ui.MirroringCaptureOrientation @('as it comes', '0', '90', '180', '270', '@0', '@90', '@180', '@270') 'as it comes'
Set-MirroringChoices $ui.MirroringImePolicy @('leave it alone', 'local', 'fallback-display', 'hide') 'leave it alone'
Set-MirroringChoices $ui.MirroringShortcutMod @('default (left Alt)', 'lalt', 'ralt', 'lctrl', 'rctrl', 'lsuper', 'rsuper') 'default (left Alt)'

function Clear-MirroringPhoneChoices {
    # the app names belong to the phone that was asked; what is typed stays
    $typed = $ui.MirroringStartApp.Text
    $ui.MirroringStartApp.Items.Clear()
    $ui.MirroringStartApp.Text = $typed
}

function Get-MirroringSharing {
    # the Tethering page's relay and the phones it serves, when that page is loaded
    $relay = Get-Variable -Name relayProcess -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $serials = @(Get-Variable -Name activeSerials -Scope Script -ValueOnly -ErrorAction SilentlyContinue | Where-Object { $_ })
    return [PSCustomObject]@{ Relay = $relay; Serials = $serials }
}

# ----------------------------------------------------------- the arguments ----

function Get-HidArguments {
    $arguments = @()
    foreach ($pair in @(
            [PSCustomObject]@{ Flag = '--keyboard'; Box = $ui.MirroringKeyboard },
            [PSCustomObject]@{ Flag = '--mouse'; Box = $ui.MirroringMouse },
            [PSCustomObject]@{ Flag = '--gamepad'; Box = $ui.MirroringGamepad })) {
        $value = "$($pair.Box.SelectedItem)"
        if ($value -and $value -ne 'default') { $arguments += "$($pair.Flag)=$value" }
    }
    return $arguments
}

function Get-ExtraScrcpyArguments {
    $extra = "$($ui.MirroringExtraArgs.Text)".Trim()
    if (-not $extra) { return @() }
    return @($extra -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)' | Where-Object { $_ -ne '' })
}

function Get-StartAppValue {
    <#
        What --start-app is given. A pick from the list reads "Name  (package)"
        and scrcpy wants the package, keeping a + typed in front of it
        (force-stop first). Anything typed by hand passes through unchanged,
        so "com.example", "+com.example" and "?Name" still work.
    #>
    $text = "$($ui.MirroringStartApp.Text)".Trim()
    if ($text -match '^(\+?).*\(([A-Za-z0-9_.]+)\)$') { return $Matches[1] + $Matches[2] }
    return $text
}

function Update-StartAppChoices {
    # the phone's apps by name, sorted; whatever is typed in the box is kept
    if ($script:mirroringFillingApps) { return }
    if (-not (Get-Command Get-AppLabels -ErrorAction SilentlyContinue)) {
        if (-not $script:mirroringAppsWarned) {
            Write-Log 'The app names come from the Apps page, which is not loaded; type a package instead.' $colorWarn
            $script:mirroringAppsWarned = $true
        }
        return
    }
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $script:mirroringFillingApps = $true
    try {
        $names = Get-AppLabels -Serial $serial
        $typed = $ui.MirroringStartApp.Text
        $ui.MirroringStartApp.Items.Clear()
        if ($names) {
            foreach ($entry in @($names.GetEnumerator() | Sort-Object -Property Value)) {
                $null = $ui.MirroringStartApp.Items.Add(('{0}  ({1})' -f $entry.Value, $entry.Key))
            }
        }
        $ui.MirroringStartApp.Text = $typed
    } finally {
        $script:mirroringFillingApps = $false
    }
}

function Get-ScrcpyArguments {
    param([string]$Serial)

    # OTG has no video pipeline at all: video/audio/record/display flags are
    # rejected, so build a separate, minimal command line for it.
    if ($ui.MirroringOtg.IsChecked) {
        $arguments = @('--otg')
        if ($Serial) { $arguments += @('-s', $Serial) }
        $arguments += @(Get-HidArguments)
        if ($ui.MirroringOnTop.IsChecked) { $arguments += '--always-on-top' }
        if ($ui.MirroringBorderless.IsChecked) { $arguments += '--window-borderless' }
        if ($ui.MirroringNoScreensaver.IsChecked) { $arguments += '--disable-screensaver' }
        $arguments += @(Get-ExtraScrcpyArguments)
        return $arguments
    }

    $arguments = @()
    if ($Serial) { $arguments += @('-s', $Serial) }

    $maxSize = "$($ui.MirroringMaxSize.Text)".Trim()
    if ($maxSize -and $maxSize -ne '0') { $arguments += @('-m', $maxSize) }

    $bitrate = "$($ui.MirroringBitrate.Text)".Trim()
    if ($bitrate) { $arguments += @('-b', $bitrate) }

    $fps = "$($ui.MirroringFps.Text)".Trim()
    if ($fps -and $fps -ne '0') { $arguments += "--max-fps=$fps" }

    if ($ui.MirroringCodec.SelectedItem -and "$($ui.MirroringCodec.SelectedItem)" -ne 'default') {
        $arguments += "--video-codec=$($ui.MirroringCodec.SelectedItem)"
    }

    $display = "$($ui.MirroringDisplay.Text)".Trim()
    if ($display -and $display -ne '0' -and -not $ui.MirroringNewDisplay.IsChecked) {
        $arguments += "--display-id=$display"
    }

    if ($ui.MirroringNewDisplay.IsChecked) {
        $size = "$($ui.MirroringNewDisplaySize.Text)".Trim()
        if ($size) { $arguments += "--new-display=$size" } else { $arguments += '--new-display' }
    }

    if ($ui.MirroringFullscreen.IsChecked) { $arguments += '-f' }
    if ($ui.MirroringBorderless.IsChecked) { $arguments += '--window-borderless' }
    if ($ui.MirroringOnTop.IsChecked) { $arguments += '--always-on-top' }
    if ($ui.MirroringScreenOff.IsChecked) { $arguments += '-S' }
    if ($ui.MirroringStayAwake.IsChecked) { $arguments += '-w' }
    if ($ui.MirroringNoAudio.IsChecked) { $arguments += '--no-audio' }
    if ($ui.MirroringViewOnly.IsChecked) { $arguments += '--no-control' }
    if ($ui.MirroringPowerOff.IsChecked) { $arguments += '--power-off-on-close' }
    if ($ui.MirroringNoScreensaver.IsChecked) { $arguments += '--disable-screensaver' }

    $startApp = Get-StartAppValue
    if ($startApp) { $arguments += "--start-app=$startApp" }

    if ($ui.MirroringRecord.IsChecked) {
        $file = "$($ui.MirroringRecordPath.Text)".Trim()
        if (-not $file) {
            $file = Join-Path ([Environment]::GetFolderPath('MyVideos')) ("scrcpy-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
            $ui.MirroringRecordPath.Text = $file
        }
        $arguments += "--record=$file"

        if ("$($ui.MirroringRecordFormat.SelectedItem)" -ne 'from the name') {
            $arguments += "--record-format=$($ui.MirroringRecordFormat.SelectedItem)"
        }
        if ("$($ui.MirroringRecordOrientation.SelectedItem)" -ne '0') {
            $arguments += "--record-orientation=$($ui.MirroringRecordOrientation.SelectedItem)"
        }
    }

    $arguments += @(Get-MoreScrcpyArguments)
    $arguments += @(Get-HidArguments)
    $arguments += @(Get-ExtraScrcpyArguments)

    return $arguments
}

function Get-MoreScrcpyArguments {
    # everything from the "More options" page, left out when untouched
    $arguments = @()

    if ("$($ui.MirroringOrientation.SelectedItem)" -ne 'as it comes') {
        $arguments += "--orientation=$($ui.MirroringOrientation.SelectedItem)"
    }
    if ("$($ui.MirroringCaptureOrientation.SelectedItem)" -ne 'as it comes') {
        $arguments += "--capture-orientation=$($ui.MirroringCaptureOrientation.SelectedItem)"
    }

    if ($ui.MirroringNewDisplay.IsChecked) {
        if ("$($ui.MirroringImePolicy.SelectedItem)" -ne 'leave it alone') {
            $arguments += "--display-ime-policy=$($ui.MirroringImePolicy.SelectedItem)"
        }
        if ($ui.MirroringNoDecorations.IsChecked) { $arguments += '--no-vd-system-decorations' }
        if ($ui.MirroringKeepContent.IsChecked) { $arguments += '--no-vd-destroy-content' }
    }

    foreach ($pair in @(
            [PSCustomObject]@{ Box = $ui.MirroringWindowX; Flag = '--window-x' },
            [PSCustomObject]@{ Box = $ui.MirroringWindowY; Flag = '--window-y' },
            [PSCustomObject]@{ Box = $ui.MirroringWindowW; Flag = '--window-width' },
            [PSCustomObject]@{ Box = $ui.MirroringWindowH; Flag = '--window-height' })) {
        $value = "$($pair.Box.Text)".Trim()
        if ($value -match '^-?\d+$') { $arguments += ($pair.Flag + '=' + $value) }
    }

    $timeout = "$($ui.MirroringScreenOffTimeout.Text)".Trim()
    if ($timeout -match '^\d+$' -and [int]$timeout -gt 0) { $arguments += "--screen-off-timeout=$timeout" }

    $limit = Get-NumberValue -Box $ui.MirroringTimeLimit -Default 0 -Minimum 0 -Maximum 86400
    if ($limit -gt 0) { $arguments += "--time-limit=$limit" }
    if ($ui.MirroringPrintFps.IsChecked) { $arguments += '--print-fps' }

    if ("$($ui.MirroringShortcutMod.SelectedItem)" -notlike 'default*') {
        $arguments += "--shortcut-mod=$($ui.MirroringShortcutMod.SelectedItem)"
    }
    $bind = "$($ui.MirroringMouseBind.Text)".Trim()
    if ($bind) { $arguments += "--mouse-bind=$bind" }

    if ($ui.MirroringPreferText.IsChecked) { $arguments += '--prefer-text' }
    if ($ui.MirroringRawKeys.IsChecked) { $arguments += '--raw-key-events' }
    if ($ui.MirroringNoKeyRepeat.IsChecked) { $arguments += '--no-key-repeat' }
    if ($ui.MirroringLegacyPaste.IsChecked) { $arguments += '--legacy-paste' }
    if ($ui.MirroringKillAdb.IsChecked) { $arguments += '--kill-adb-on-close' }
    if ($ui.MirroringNoCleanup.IsChecked) { $arguments += '--no-cleanup' }

    return $arguments
}

function ConvertTo-MirroringCommandLine {
    # Start-Process joins its arguments with bare spaces, so a record path or a
    # window title with a space would arrive as two words; quote those whole
    param([string[]]$Arguments)
    return (@($Arguments) | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '"') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
}

# ------------------------------------------------------------ the windows ----

function Start-Scrcpy {
    if (-not $script:scrcpyPath) {
        Write-Log 'scrcpy.exe was not found next to this script nor in PATH.' $colorBad
        return
    }

    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }
    $otg = [bool]$ui.MirroringOtg.IsChecked
    $sharing = Get-MirroringSharing

    if ($otg) {
        $usb = @($serials | Where-Object { $_ -notmatch ':\d+$' })
        if ($usb.Count -eq 0) {
            Write-Log 'OTG needs a USB connection - the selected devices are over TCP/IP.' $colorBad
            return
        }
        if ($usb.Count -lt $serials.Count) {
            Write-Log 'Skipping the TCP/IP devices: OTG is USB only.' $colorWarn
        }
        $serials = $usb
        if ($sharing.Relay) {
            # scrcpy --otg kills the adb server on startup, which tears down the
            # gnirehtet reverse tunnel. Rebuild it right after OTG comes up.
            $answer = Show-Confirm -Title 'OTG' -Yes 'Yes' -No 'No' -Text (
                'OTG kills the adb server, which drops the gnirehtet tunnel.' + [Environment]::NewLine +
                'The tunnel will be rebuilt automatically a few seconds after OTG starts. Continue?')
            if (-not $answer) { return }
        }

        Write-Log 'OTG: mirroring is disabled; LAlt / LSuper releases the mouse capture.' $colorWarn
    }

    # One window per device, cascaded so they do not land on top of each other.
    $index = 0
    foreach ($current in $serials) {
        $arguments = @(Get-ScrcpyArguments -Serial $current)
        if ($serials.Count -gt 1) {
            $arguments += "--window-title=$current"
            $arguments += "--window-x=$(60 + $index * 80)"
            $arguments += "--window-y=$(60 + $index * 60)"
        }

        Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

        $stdout = Join-Path $env:TEMP ("androiddc-nova-$PID.scrcpy-$index.out")
        $stderr = Join-Path $env:TEMP ("androiddc-nova-$PID.scrcpy-$index.err")
        try {
            $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList (ConvertTo-MirroringCommandLine $arguments) -PassThru `
                -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        } catch {
            Write-Log "scrcpy could not be started for ${current}: $($_.Exception.Message)" $colorBad
            $index++
            continue
        }
        $null = $process.Handle
        $script:scrcpyProcesses += $process

        # give it a moment: a bad option or a busy device makes it quit at once
        Wait-Pumped -Milliseconds 2500
        $process.Refresh()

        if ($process.HasExited) {
            $null = $process.WaitForExit(1000)
            $code = $null
            try { $code = $process.ExitCode } catch { }
            Write-Log "scrcpy quit immediately (exit $(if ($null -eq $code) { '?' } else { $code })) for $current." $colorBad
            foreach ($file in @($stdout, $stderr)) {
                if (Test-Path -LiteralPath $file) {
                    $text = (Get-Content -LiteralPath $file -Tail 8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
                    if ($text.Trim()) { Write-Log $text $colorWarn }
                }
            }
        } else {
            Write-Log "scrcpy started for $current (PID $($process.Id), window '$($process.MainWindowTitle)')." $colorGood
            if (-not $otg -and $ui.MirroringNewDisplay.IsChecked) { Test-MirroringNewDisplay -Serial $current -Process $process -Files @($stdout, $stderr) }
        }

        $index++
    }

    if ($otg -and $sharing.Relay -and $sharing.Serials.Count -gt 0) {
        Wait-Pumped -Milliseconds 4000
        Write-Log 'Rebuilding the gnirehtet tunnel that OTG tore down ...' $colorStep
        if (Get-Command Repair-Tunnel -ErrorAction SilentlyContinue) {
            foreach ($current in $sharing.Serials) { Repair-Tunnel -Serial $current }
        } else {
            Write-Log 'Repair-Tunnel is not loaded (Tethering page); stop and start the sharing again.' $colorBad
        }
    }
}

function Test-MirroringNewDisplay {
    # still alive is not the same as working: read what scrcpy said about the display
    param([string]$Serial, $Process, [string[]]$Files)

    $said = ''
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $stream = New-Object System.IO.FileStream($file, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object System.IO.StreamReader($stream)
            $said += $reader.ReadToEnd()
            $reader.Dispose()
        } catch { }
    }
    if ($said -match 'New display: \S+ \(id=(\d+)\)') {
        $display = $Matches[1]
        if (-not (Get-StartAppValue) -or $said -match 'Starting app') {
            Write-Log "$Serial mirrors its own virtual display $display (PID $($Process.Id))." $colorGood
        } else {
            Write-Log "Display $display opened but the app has not started on it yet." $colorWarn
            Write-Log 'Unlock the phone: some ROMs refuse to launch an app on a new display while locked.' $colorInfo
        }
    } else {
        Write-Log "scrcpy is running (PID $($Process.Id)) but has not reported a new display yet." $colorWarn
        Write-Log 'A virtual display needs Android 11 or newer, and the phone unlocked.' $colorInfo
    }
}

function Close-Scrcpy {
    $closed = 0
    foreach ($process in @($script:scrcpyProcesses)) {
        try {
            if (-not $process.HasExited) { $process.Kill(); $closed++ }
        } catch { }
    }
    $script:scrcpyProcesses = @()
    Write-Log "Closed $closed scrcpy window(s)." $colorInfo
}

# ------------------------------------------------------- read from the phone ----

function Show-ScrcpyDisplays {
    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $serial, '--list-displays') -TimeoutMs 60000
    $output = @($result.Lines | ForEach-Object { "$_" })
    Write-Log ($output -join "`n") $colorInfo

    $typed = $ui.MirroringDisplay.Text
    $ui.MirroringDisplay.Items.Clear()
    foreach ($line in $output) {
        if ($line -match '--display-id=(\d+)') { $null = $ui.MirroringDisplay.Items.Add($Matches[1]) }
    }
    if ($ui.MirroringDisplay.Items.Count -eq 0) { $null = $ui.MirroringDisplay.Items.Add('0') }
    $ui.MirroringDisplay.Text = $typed
}

function Update-VideoCodecList {
    # the video half of the original Update-EncoderList: the codecs this phone can encode
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (Get-Command Get-DeviceCapabilityList -ErrorAction SilentlyContinue) {
        $lines = @(Get-DeviceCapabilityList -Serial $serial -Switch '--list-encoders')
    } else {
        if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }
        Write-Log 'scrcpy --list-encoders ...' $colorStep
        $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $serial, '--list-encoders') -TimeoutMs 60000
        $lines = @($result.Lines | Where-Object { $_ -and $_.Trim() })
    }

    # scrcpy prints one line per encoder, in the shape
    #     --video-codec=h264 --video-encoder=c2.mtk.avc.encoder   (hw) [vendor]
    $video = @()
    foreach ($line in $lines) {
        if ($line -match '--video-codec=(\S+)') { $video += $Matches[1] }
    }
    $video = @($video | Sort-Object -Unique)

    if ($video.Count -gt 0) {
        $keep = "$($ui.MirroringCodec.SelectedItem)"
        $ui.MirroringCodec.Items.Clear()
        $null = $ui.MirroringCodec.Items.Add('default')
        foreach ($codec in $video) { $null = $ui.MirroringCodec.Items.Add($codec) }
        $ui.MirroringCodec.SelectedIndex = [Math]::Max(0, $ui.MirroringCodec.Items.IndexOf($keep))
        Write-Log ("video codecs on this phone: " + ($video -join ', ')) $colorGood
    } else {
        Write-Log 'scrcpy listed no video encoders; the fixed choices are still there.' $colorWarn
        foreach ($line in ($lines | Select-Object -Last 3)) { Write-Log ("  " + $line) $colorInfo }
    }
}

# ------------------------------------------------------------------ events ----

$ui.MirroringLaunch.Add_Click({ Start-Scrcpy })
$ui.HeaderMirror.Add_Click({ Start-Scrcpy })
$ui.MirroringShare.Add_Click({
    if (-not (Get-MirroringSharing).Relay) {
        if (Get-Command Start-Sharing -ErrorAction SilentlyContinue) { Start-Sharing }
        else { Write-Log 'Internet sharing is on the Tethering page, which is not loaded; starting scrcpy alone.' $colorWarn }
    }
    Start-Scrcpy
})
$ui.MirroringLaunchOtg.Add_Click({
    $ui.MirroringOtg.IsChecked = $true
    Start-Scrcpy
})
$ui.MirroringKeyboardLayout.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.HARD_KEYBOARD_SETTINGS')).Text $colorInfo
    Write-Log 'Set the physical keyboard layout there (needed once for uhid/aoa).' $colorWarn
})
$ui.MirroringCloseAll.Add_Click({ Close-Scrcpy })
$ui.MirroringListDisplays.Add_Click({ Show-ScrcpyDisplays })
$ui.MirroringCodecs.Add_Click({ Update-VideoCodecList })
$ui.MirroringShowCommand.Add_Click({
    $serial = Get-SelectedSerial
    Write-Log ('scrcpy ' + (@(Get-ScrcpyArguments -Serial $serial) -join ' ')) $colorStep
})
$ui.MirroringBrowseRecord.Add_Click({
    $file = Select-SaveFile -Filter 'MP4 (*.mp4)|*.mp4|Matroska (*.mkv)|*.mkv' `
        -FileName ('scrcpy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
    if ($file) {
        $ui.MirroringRecordPath.Text = $file
        $ui.MirroringRecord.IsChecked = $true
    }
})
$ui.MirroringStartApp.Add_DropDownOpened({ Update-StartAppChoices })

# ---------------------------------------------------------------- settings ----

# the switches, under the names the original kept them by
foreach ($entry in @(
        @('Fullscreen', 'MirroringFullscreen'), @('Borderless', 'MirroringBorderless'), @('OnTop', 'MirroringOnTop'),
        @('ScreenOff', 'MirroringScreenOff'), @('StayAwake', 'MirroringStayAwake'), @('NoAudio', 'MirroringNoAudio'),
        @('NoDecorations', 'MirroringNoDecorations'), @('KeepContent', 'MirroringKeepContent'),
        @('PrintFps', 'MirroringPrintFps'), @('PreferText', 'MirroringPreferText'), @('ViewOnly', 'MirroringViewOnly'),
        @('PowerOff', 'MirroringPowerOff'), @('NoScreensaver', 'MirroringNoScreensaver'),
        @('NewDisplay', 'MirroringNewDisplay'), @('Otg', 'MirroringOtg'))) {
    $box = $ui[$entry[1]]
    Register-Setting -Name ('Mirroring.' + $entry[0]) -Get { [bool]$box.IsChecked }.GetNewClosure() `
        -Set { param($v) if ($null -ne $v) { $box.IsChecked = [bool]$v } }.GetNewClosure()
}

# the lists with fixed choices: only a value that is still one of them
foreach ($entry in @(
        @('Codec', 'MirroringCodec'), @('RecordFormat', 'MirroringRecordFormat'),
        @('RecordRotate', 'MirroringRecordOrientation'), @('Orientation', 'MirroringOrientation'),
        @('CaptureTurn', 'MirroringCaptureOrientation'), @('ImePolicy', 'MirroringImePolicy'),
        @('ShortcutMod', 'MirroringShortcutMod'), @('Keyboard', 'MirroringKeyboard'),
        @('Mouse', 'MirroringMouse'), @('Gamepad', 'MirroringGamepad'))) {
    $box = $ui[$entry[1]]
    Register-Setting -Name ('Mirroring.' + $entry[0]) -Get { "$($box.SelectedItem)" }.GetNewClosure() `
        -Set { param($v) if ($v -and $box.Items.Contains("$v")) { $box.SelectedItem = "$v" } }.GetNewClosure()
}

# typed text; an empty value is put back only where the original did so
foreach ($entry in @(
        @('MaxSize', 'MirroringMaxSize', $false), @('Bitrate', 'MirroringBitrate', $false), @('Fps', 'MirroringFps', $false),
        @('NewDisplaySize', 'MirroringNewDisplaySize', $false),
        @('StartApp', 'MirroringStartApp', $true), @('ExtraArgs', 'MirroringExtraArgs', $true))) {
    $box = $ui[$entry[1]]
    $emptyToo = $entry[2]
    Register-Setting -Name ('Mirroring.' + $entry[0]) -Get { "$($box.Text)" }.GetNewClosure() `
        -Set { param($v) if ($v -or ($emptyToo -and $null -ne $v)) { $box.Text = "$v" } }.GetNewClosure()
}

Register-Setting -Name 'Mirroring.TimeLimit' -Get { Get-NumberValue -Box $ui.MirroringTimeLimit -Default 0 -Minimum 0 -Maximum 86400 } `
    -Set { param($v) if ($null -ne $v) { try { $ui.MirroringTimeLimit.Text = "$([Math]::Max(0, [Math]::Min(86400, [int]$v)))" } catch { } } }

# The original left scrcpy windows open when it closed, and so does this page:
# a mirror someone is using outlives the control window. Only the handles go.
Register-Cleanup {
    foreach ($process in @($script:scrcpyProcesses)) { try { $process.Dispose() } catch { } }
}
