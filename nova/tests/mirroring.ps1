# The Mirroring page: both inner pages fit the default and the smallest window,
# the actions stay reachable, and the scrcpy command line is the one the
# original built for the same settings. Reads from the phone only
# (--list-encoders, --list-displays); never starts scrcpy, OTG or sharing.

function Reset-MirroringTestControls {
    # the page as a fresh install shows it
    $ui.MirroringMaxSize.Text = '1280'; $ui.MirroringBitrate.Text = '8M'; $ui.MirroringFps.Text = '60'
    $ui.MirroringCodec.SelectedItem = 'default'
    $ui.MirroringDisplay.Text = '0'
    foreach ($name in @('MirroringFullscreen', 'MirroringBorderless', 'MirroringOnTop', 'MirroringNoScreensaver',
            'MirroringScreenOff', 'MirroringNoAudio', 'MirroringViewOnly', 'MirroringPowerOff', 'MirroringNewDisplay',
            'MirroringRecord', 'MirroringOtg', 'MirroringNoDecorations', 'MirroringKeepContent', 'MirroringPrintFps',
            'MirroringPreferText', 'MirroringRawKeys', 'MirroringNoKeyRepeat', 'MirroringLegacyPaste',
            'MirroringKillAdb', 'MirroringNoCleanup')) { $ui[$name].IsChecked = $false }
    $ui.MirroringStayAwake.IsChecked = $true
    $ui.MirroringNewDisplaySize.Text = '1920x1080/240'
    $ui.MirroringStartApp.Text = ''
    $ui.MirroringRecordPath.Text = ''
    $ui.MirroringExtraArgs.Text = ''
    foreach ($name in @('MirroringKeyboard', 'MirroringMouse', 'MirroringGamepad')) { $ui[$name].SelectedItem = 'default' }
    $ui.MirroringRecordFormat.SelectedItem = 'from the name'
    $ui.MirroringRecordOrientation.SelectedItem = '0'
    $ui.MirroringTimeLimit.Text = '0'
    $ui.MirroringOrientation.SelectedItem = 'as it comes'
    $ui.MirroringCaptureOrientation.SelectedItem = 'as it comes'
    $ui.MirroringImePolicy.SelectedItem = 'leave it alone'
    foreach ($name in @('MirroringWindowX', 'MirroringWindowY', 'MirroringWindowW', 'MirroringWindowH',
            'MirroringScreenOffTimeout', 'MirroringMouseBind')) { $ui[$name].Text = '' }
    $ui.MirroringShortcutMod.SelectedItem = 'default (left Alt)'
}

function Test-MirroringArguments {
    param([string]$Title, [string[]]$Actual, [string[]]$Expected)
    $same = (@($Actual).Count -eq @($Expected).Count) -and ((@($Actual) -join "`n") -ceq (@($Expected) -join "`n"))
    Say ("  {0}   {1}" -f $Title, (Mark $same))
    if (-not $same) {
        Say ("    got:      " + (@($Actual) -join ' '))
        Say ("    expected: " + (@($Expected) -join ' '))
    }
}

Say '== the page =='
$null = Wait-Idle -Seconds 30
$page = Get-Page -Key 'mirroring'
Say ("  registered under Workspace   {0}" -f (Mark ($null -ne $page -and $page.Section -eq 'Workspace')))
Show-Page -Page 'mirroring'
$null = Wait-Idle -Seconds 30
Say ("  shown, two inner pages   {0}" -f (Mark ((Test-PageShown -Key 'mirroring') -and $ui.MirroringTabs.Items.Count -eq 2)))
Reset-MirroringTestControls

Say ''
Say '== the pictures =='
$tabNames = @('mirroring', 'more')
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    for ($tab = 0; $tab -lt 2; $tab++) {
        $ui.MirroringTabs.SelectedIndex = $tab
        Wait-Pumped -Milliseconds 400
        $scroller = $ui.MirroringTabs.Items[$tab].Content
        $scroller.ScrollToTop()
        Wait-Pumped -Milliseconds 200
        Say ("  {0} / {1}: {2}" -f $size, $tabNames[$tab], (Save-WindowPicture "mirroring-$($tabNames[$tab])-$size"))
        $outside = @(Get-OutsideElements -Root $page.Root)
        Say ("  {0} / {1}: nothing sticks out on the right   {2}" -f $size, $tabNames[$tab], (Mark ($outside.Count -eq 0)))
        foreach ($line in $outside) { Say "    $line" }

        # the actions: inside the page area, whatever the inner page
        $button = $ui.MirroringShowCommand
        $point = $button.TransformToAncestor($ui.PageHost).Transform((New-Object System.Windows.Point(0, 0)))
        $bottom = $point.Y + $button.ActualHeight
        Say ("  {0} / {1}: the action bar ends at {2:N0} of {3:N0}   {4}" -f $size, $tabNames[$tab], $bottom, $ui.PageHost.ActualHeight,
            (Mark ($button.IsVisible -and $bottom -le $ui.PageHost.ActualHeight + 1)))

        if ($size -eq 'min') {
            $scroller.ScrollToEnd()
            Wait-Pumped -Milliseconds 300
            Say ("  {0} / {1} scrolled ({2:N0} px can scroll): {3}" -f $size, $tabNames[$tab], $scroller.ScrollableHeight,
                (Save-WindowPicture "mirroring-$($tabNames[$tab])-$size-end"))
            $scroller.ScrollToTop()
        }
    }
}
Set-WindowSize 'default'
$ui.MirroringTabs.SelectedIndex = 0

Say ''
Say '== the command line, as the original built it =='
Reset-MirroringTestControls
Test-MirroringArguments 'untouched settings' @(Get-ScrcpyArguments -Serial 'SERIAL1') @(
    '-s', 'SERIAL1', '-m', '1280', '-b', '8M', '--max-fps=60', '-w')
Test-MirroringArguments 'untouched More options add nothing' @(Get-MoreScrcpyArguments) @()

Reset-MirroringTestControls
$ui.MirroringMaxSize.Text = '0'; $ui.MirroringBitrate.Text = ''; $ui.MirroringFps.Text = '0'
$ui.MirroringCodec.SelectedItem = 'h265'
$ui.MirroringDisplay.Text = '2'
foreach ($name in @('MirroringFullscreen', 'MirroringBorderless', 'MirroringOnTop', 'MirroringScreenOff', 'MirroringNoAudio',
        'MirroringViewOnly', 'MirroringPowerOff', 'MirroringNoScreensaver')) { $ui[$name].IsChecked = $true }
$ui.MirroringStayAwake.IsChecked = $false
$ui.MirroringStartApp.Text = 'Example (beta)  (com.example.beta)'
Test-MirroringArguments 'window and phone switches, a display, an app picked by name, no serial' @(Get-ScrcpyArguments -Serial '') @(
    '--video-codec=h265', '--display-id=2', '-f', '--window-borderless', '--always-on-top', '-S', '--no-audio',
    '--no-control', '--power-off-on-close', '--disable-screensaver', '--start-app=com.example.beta')

$record = Join-Path $env:TEMP 'mirroring test.mkv'
Reset-MirroringTestControls
$ui.MirroringDisplay.Text = '2'
$ui.MirroringNewDisplay.IsChecked = $true
$ui.MirroringNewDisplaySize.Text = '1280x720/160'
$ui.MirroringImePolicy.SelectedItem = 'local'
$ui.MirroringNoDecorations.IsChecked = $true
$ui.MirroringKeepContent.IsChecked = $true
$ui.MirroringRecord.IsChecked = $true
$ui.MirroringRecordPath.Text = $record
$ui.MirroringRecordFormat.SelectedItem = 'mkv'
$ui.MirroringRecordOrientation.SelectedItem = '90'
$ui.MirroringTimeLimit.Text = '30'
$ui.MirroringOrientation.SelectedItem = 'flip90'
$ui.MirroringCaptureOrientation.SelectedItem = '@90'
$ui.MirroringWindowX.Text = '10'; $ui.MirroringWindowY.Text = '-20'; $ui.MirroringWindowW.Text = 'abc'; $ui.MirroringWindowH.Text = '600'
$ui.MirroringScreenOffTimeout.Text = '300'
$ui.MirroringPrintFps.IsChecked = $true
$ui.MirroringShortcutMod.SelectedItem = 'rctrl'
$ui.MirroringMouseBind.Text = 'bhsn'
foreach ($name in @('MirroringPreferText', 'MirroringRawKeys', 'MirroringNoKeyRepeat', 'MirroringLegacyPaste',
        'MirroringKillAdb', 'MirroringNoCleanup')) { $ui[$name].IsChecked = $true }
$ui.MirroringKeyboard.SelectedItem = 'uhid'; $ui.MirroringMouse.SelectedItem = 'aoa'; $ui.MirroringGamepad.SelectedItem = 'disabled'
$ui.MirroringExtraArgs.Text = ' --crop=1080:1920:0:0   --window-title="My Phone" '
$moreWithDisplay = @('--orientation=flip90', '--capture-orientation=@90', '--display-ime-policy=local',
    '--no-vd-system-decorations', '--no-vd-destroy-content', '--window-x=10', '--window-y=-20', '--window-height=600',
    '--screen-off-timeout=300', '--time-limit=30', '--print-fps', '--shortcut-mod=rctrl', '--mouse-bind=bhsn',
    '--prefer-text', '--raw-key-events', '--no-key-repeat', '--legacy-paste', '--kill-adb-on-close', '--no-cleanup')
Test-MirroringArguments 'virtual display, recording, every More option, HID modes, quoted extra args' @(Get-ScrcpyArguments -Serial 'SERIAL1') (@(
    '-s', 'SERIAL1', '-m', '1280', '-b', '8M', '--max-fps=60', '--new-display=1280x720/160', '-w',
    "--record=$record", '--record-format=mkv', '--record-orientation=90') + $moreWithDisplay + @(
    '--keyboard=uhid', '--mouse=aoa', '--gamepad=disabled', '--crop=1080:1920:0:0', '--window-title="My Phone"'))

$ui.MirroringNewDisplay.IsChecked = $false
$ui.MirroringRecord.IsChecked = $false
Test-MirroringArguments 'without the virtual display, its three options are left out' @(Get-MoreScrcpyArguments) @(
    $moreWithDisplay | Where-Object { $_ -notmatch 'ime-policy|vd-' })
Test-MirroringArguments 'and the display id counts again, the recording flags go' @(Get-ScrcpyArguments -Serial 'SERIAL1') (@(
    '-s', 'SERIAL1', '-m', '1280', '-b', '8M', '--max-fps=60', '--display-id=2', '-w') +
    @($moreWithDisplay | Where-Object { $_ -notmatch 'ime-policy|vd-' }) + @(
    '--keyboard=uhid', '--mouse=aoa', '--gamepad=disabled', '--crop=1080:1920:0:0', '--window-title="My Phone"'))

$ui.MirroringNewDisplay.IsChecked = $true
$ui.MirroringNewDisplaySize.Text = ''
$ui.MirroringTimeLimit.Text = '999999'
$args5 = @(Get-ScrcpyArguments -Serial '')
Say ("  a blank size gives a bare --new-display, the time limit keeps its maximum   {0}" -f
    (Mark (($args5 -ccontains '--new-display') -and ($args5 -ccontains '--time-limit=86400') -and $ui.MirroringTimeLimit.Text -eq '86400')))

Reset-MirroringTestControls
$ui.MirroringOtg.IsChecked = $true
$ui.MirroringBorderless.IsChecked = $true; $ui.MirroringOnTop.IsChecked = $true; $ui.MirroringNoScreensaver.IsChecked = $true
$ui.MirroringFullscreen.IsChecked = $true; $ui.MirroringRecord.IsChecked = $true; $ui.MirroringRecordPath.Text = $record
$ui.MirroringKeyboard.SelectedItem = 'aoa'; $ui.MirroringMouse.SelectedItem = 'aoa'
$ui.MirroringOrientation.SelectedItem = '90'
$ui.MirroringExtraArgs.Text = '--no-mouse-hover'
Test-MirroringArguments 'OTG: its own short command, no picture or recording flags' @(Get-ScrcpyArguments -Serial 'SERIAL1') @(
    '--otg', '-s', 'SERIAL1', '--keyboard=aoa', '--mouse=aoa', '--always-on-top', '--window-borderless',
    '--disable-screensaver', '--no-mouse-hover')

Reset-MirroringTestControls
$ui.MirroringRecord.IsChecked = $true
$recordArgs = @(Get-ScrcpyArguments -Serial '' | Where-Object { $_ -like '--record=*' })
Say ("  Record with no file names one in Videos and writes it in the box   {0}" -f
    (Mark ($recordArgs.Count -eq 1 -and $recordArgs[0] -match 'scrcpy-\d{8}-\d{6}\.mp4$' -and $recordArgs[0] -eq "--record=$($ui.MirroringRecordPath.Text)")))
Reset-MirroringTestControls

$quoted = ConvertTo-MirroringCommandLine @('-s', 'S1', "--record=C:\a b\c.mp4", '--window-title="My Phone"')
Say ("  a word with a space reaches scrcpy whole   {0}" -f (Mark ($quoted -ceq '-s S1 "--record=C:\a b\c.mp4" --window-title="My Phone"')))

Say ''
Say '== start app =='
$ui.MirroringStartApp.Text = 'Example (beta)  (com.example.beta)'
Say ("  a pick gives its package   {0}" -f (Mark ((Get-StartAppValue) -eq 'com.example.beta')))
$ui.MirroringStartApp.Text = '+Example (beta)  (com.example.beta)'
Say ("  a + in front is kept   {0}" -f (Mark ((Get-StartAppValue) -eq '+com.example.beta')))
foreach ($typed in @('com.example.app', '+com.example.app', '?Example')) {
    $ui.MirroringStartApp.Text = $typed
    Say ("  typed '{0}' passes through   {1}" -f $typed, (Mark ((Get-StartAppValue) -eq $typed)))
}
$null = $ui.MirroringStartApp.Items.Add('Example  (com.example)')
$ui.MirroringStartApp.Text = 'kept'
Clear-MirroringPhoneChoices
Say ("  another phone empties the names and keeps the typed text   {0}" -f
    (Mark ($ui.MirroringStartApp.Items.Count -eq 0 -and $ui.MirroringStartApp.Text -eq 'kept')))
$ui.MirroringStartApp.Text = ''

Say ''
Say '== show command and close =='
$before = $script:logLines.Count
Invoke-ButtonClick -Button $ui.MirroringShowCommand
$last = @($script:logLines)[-1].Text
$shownSerial = Get-SelectedSerial
# the phone's serial is not written into the test output
$printed = if ($shownSerial) { $last.Replace($shownSerial, '<serial>') } else { $last }
Say ("  Show command logs '{0}'   {1}" -f $printed, (Mark ($script:logLines.Count -gt $before -and $last -like 'scrcpy *')))
Invoke-ButtonClick -Button $ui.MirroringCloseAll
Say ("  Close all with nothing started: '{0}'   {1}" -f @($script:logLines)[-1].Text,
    (Mark (@($script:logLines)[-1].Text -eq 'Closed 0 scrcpy window(s).')))

Say ''
Say '== settings =='
$ui.MirroringMaxSize.Text = '1600'; $ui.MirroringCodec.SelectedItem = 'av1'; $ui.MirroringOtg.IsChecked = $false
$ui.MirroringNoAudio.IsChecked = $true; $ui.MirroringStartApp.Text = '+com.example.app'; $ui.MirroringTimeLimit.Text = '120'
$ui.MirroringCaptureOrientation.SelectedItem = '@270'; $ui.MirroringExtraArgs.Text = '--no-mipmaps'
Save-Settings
Reset-MirroringTestControls
$ui.MirroringExtraArgs.Text = 'changed'
Restore-Settings
Say ("  remembered: max size, codec, no audio, start app, time limit, capture, extra args   {0}" -f
    (Mark ($ui.MirroringMaxSize.Text -eq '1600' -and "$($ui.MirroringCodec.SelectedItem)" -eq 'av1' -and $ui.MirroringNoAudio.IsChecked -and
        $ui.MirroringStartApp.Text -eq '+com.example.app' -and $ui.MirroringTimeLimit.Text -eq '120' -and
        "$($ui.MirroringCaptureOrientation.SelectedItem)" -eq '@270' -and $ui.MirroringExtraArgs.Text -eq '--no-mipmaps')))
$saved = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
$keys = @($saved.PSObject.Properties.Name | Where-Object { $_ -like 'Mirroring.*' })
Say ("  {0} Mirroring.* keys in the file   {1}" -f $keys.Count, (Mark ($keys.Count -eq 32)))
Reset-MirroringTestControls

Say ''
Say '== read from the phone =='
$serial = Get-SelectedSerial
if (-not $serial -or @($ui.DeviceList.SelectedItems)[0].State -ne 'device') {
    Say '  SKIPPED - no ready phone attached'
} else {
    Update-VideoCodecList
    $codecs = @($ui.MirroringCodec.Items | ForEach-Object { "$_" })
    Say ("  codecs from the phone: {0}   {1}" -f ($codecs -join ', '), (Mark ($codecs.Count -gt 1 -and $codecs[0] -eq 'default' -and "$($ui.MirroringCodec.SelectedItem)" -eq 'default')))
    $ui.MirroringDisplay.Text = '0'
    Show-ScrcpyDisplays
    $displays = @($ui.MirroringDisplay.Items | ForEach-Object { "$_" })
    Say ("  displays from the phone: {0}   {1}" -f ($displays -join ', '), (Mark ($displays -contains '0' -and $ui.MirroringDisplay.Text -eq '0')))
}
Say ("  no scrcpy was started by this test   {0}" -f (Mark (@($script:scrcpyProcesses).Count -eq 0)))
