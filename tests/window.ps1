# What the window says about itself, and the keys that work anywhere in it:
# the sharing label, the busy strip, the toggle marks, the device watch and
# the shortcuts. No phone needed - the phone's answers are made up. With one,
# the toggle marks are also read from it (settings get only; nothing is set).

Say '== the sharing label =='
Say ("  '{0}'   {1}" -f $lblStatus.Text, (Mark ($lblStatus.Text -eq 'Sharing: off')))

Say ''
Say '== the busy strip =='
# With a phone attached the window is really busy at first - the battery,
# signal and toggle reads take seconds - and the strip rightly shows it. The
# checks wait for that to end, and the device watch is paused so it starts
# nothing new; a strip that never hides fails here after 20 s.
$deviceWatchTimer.Stop()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while (($script:busy -gt 0 -or $prgBusy.Visible) -and $watch.Elapsed.TotalSeconds -lt 20) { Wait-Pumped -Milliseconds 200 }
Say ("  hidden once idle ({0:N1} s)   {1}" -f $watch.Elapsed.TotalSeconds, (Mark (-not $prgBusy.Visible -and $script:busy -eq 0)))
# counted up and down, never assigned: a real call running at the same time
# keeps its own count, and assigning 0 under it would corrupt the counter
$script:busy++
$script:busyWhat = 'adb shell settings get global wifi_on'
Wait-Pumped -Milliseconds 900
Say ("  shown while busy, says '{0}'   {1}" -f $lblBusy.Text,
    (Mark ($prgBusy.Visible -and $lblBusy.Visible -and $lblBusy.Text -eq 'adb shell settings get global wifi_on')))
$script:busy--
# a real call can start meanwhile, and then the strip rightly stays until it ends
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while ($prgBusy.Visible -and $watch.Elapsed.TotalSeconds -lt 20) { Wait-Pumped -Milliseconds 200 }
Say ("  hidden again after ({0:N1} s; busy {1}, last named '{2}')   {3}" -f $watch.Elapsed.TotalSeconds, $script:busy,
    $script:busyWhat, (Mark (-not $prgBusy.Visible -and -not $lblBusy.Visible)))
# what it names: no serial, and a command sent over base64 as the command
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('settings get global wifi_on'))
$named = Get-BusyText -FilePath 'C:\tools\adb.exe' -ArgumentList @('-s', 'SERIAL1', 'shell', "echo $encoded | base64 -d | sh")
Say ("  names '{0}'   {1}" -f $named, (Mark ($named -eq 'adb shell settings get global wifi_on')))

Say ''
Say '== the toggle marks, from a made-up answer =='
function Test-Lit {
    param($Button)
    return (-not $Button.UseVisualStyleBackColor -and $Button.BackColor.ToArgb() -eq $script:toggleLit.ToArgb())
}
$states = ConvertFrom-ToggleOutput "rotation=1`nlocation=false`nbluetooth=null`nwifi=0`nstayawake=3`nnot a state line"
Set-ToggleMarks $states
Say ("  auto-rotate on: the on button only   {0}" -f (Mark ((Test-Lit $btnRotationOn) -and -not (Test-Lit $btnRotationOff))))
Say ("  location false: the off button only   {0}" -f (Mark ((Test-Lit $btnLocationOff) -and -not (Test-Lit $btnLocationOn))))
Say ("  bluetooth null: neither   {0}" -f (Mark (-not (Test-Lit $btnBtOn) -and -not (Test-Lit $btnBtOff))))
Say ("  wifi 0: the off button only   {0}" -f (Mark ((Test-Lit $btnWifiOff) -and -not (Test-Lit $btnWifiOn))))
Say ("  stay awake 3 (AC and USB): on   {0}" -f (Mark ((Test-Lit $btnAwakeOn) -and -not (Test-Lit $btnAwakeOff))))
Say ("  battery saver not in the answer: neither   {0}" -f (Mark (-not (Test-Lit $btnSaverOn) -and -not (Test-Lit $btnSaverOff))))
Set-ToggleMarks $null
$still = @(@($btnRotationOn, $btnLocationOff, $btnWifiOff, $btnAwakeOn) | Where-Object { Test-Lit $_ }).Count
Say ("  cleared: none tinted   {0}" -f (Mark ($still -eq 0)))

Say ''
Say '== the device watch, against a made-up adb =='
# the real watch is paused so it cannot read the made-up list itself
$deviceWatchTimer.Stop()
$kept = $script:deviceSignature
$script:deviceSignature = Get-DeviceSignature -Devices @([PSCustomObject]@{ Serial = 'A1'; State = 'device' })
$same = & {
    function Get-AdbDevices { @([PSCustomObject]@{ Serial = 'A1'; State = 'device'; Model = 'm'; Link = 'usb' }) }
    Test-DeviceListChanged
}
$added = & {
    function Get-AdbDevices { @([PSCustomObject]@{ Serial = 'A1'; State = 'device'; Model = 'm'; Link = 'usb' },
        [PSCustomObject]@{ Serial = 'B2'; State = 'unauthorized'; Model = 'm'; Link = 'usb' }) }
    Test-DeviceListChanged
}
$accepted = & {
    function Get-AdbDevices { @([PSCustomObject]@{ Serial = 'A1'; State = 'unauthorized'; Model = 'm'; Link = 'usb' }) }
    Test-DeviceListChanged
}
Say ("  the same phones: no change   {0}" -f (Mark (-not $same)))
Say ("  one more phone: a change   {0}" -f (Mark $added))
Say ("  the same phone in another state: a change   {0}" -f (Mark $accepted))
$script:deviceSignature = $kept
$deviceWatchTimer.Start()

Say ''
Say '== the keys =='
$keys = [System.Windows.Forms.Keys]
$used = Invoke-WindowKey -KeyData ($keys::Control -bor $keys::D3)
Say ("  Ctrl+3 opens '{0}'   {1}" -f $tabs.SelectedTab.Text, (Mark ($used -and $tabs.SelectedTab -eq $tabAdvanced)))
$null = Invoke-WindowKey -KeyData ($keys::Control -bor $keys::D8)
Wait-Pumped -Milliseconds 200
Say ("  Ctrl+8 opens '{0}', where F5 means Go   {1}" -f $tabs.SelectedTab.Text,
    (Mark ($tabs.SelectedTab -eq $tabFiles -and (Get-PageRefreshButton) -eq $btnFileGo)))
$tabs.SelectedTab = $tabRadios
$tabsRadios.SelectedTab = $tabNfc
Wait-Pumped -Milliseconds 200
Say ("  on Radios > NFC, F5 means refresh NFC   {0}" -f (Mark ((Get-PageRefreshButton) -eq $btnNfcRefresh)))
$tabs.SelectedTab = $tabShellHost
Wait-Pumped -Milliseconds 200
Say ("  on Shell, F5 means the device list   {0}" -f (Mark ((Get-PageRefreshButton) -eq $btnRefresh)))
Write-Log 'a line for Ctrl+L to clear'
$used = Invoke-WindowKey -KeyData ($keys::Control -bor $keys::L)
Say ("  Ctrl+L empties the log   {0}" -f (Mark ($used -and $txtLog.TextLength -eq 0)))
$used = Invoke-WindowKey -KeyData $keys::A
Say ("  a plain A is left to the control   {0}" -f (Mark (-not $used)))
$tabs.SelectedTab = $tabDevice
Wait-Pumped -Milliseconds 300

Say ''
Say '== the toggle marks, from a phone =='
# no "return" here: it would skip the end marker the harness waits for
if (-not $TestSerial) {
    Say 'SKIPPED - no phone given'
} else {
    Select-TestPhone
    Show-ToggleStates -Quiet
    $pairs = @(@($btnRotationOn, $btnRotationOff), @($btnLocationOn, $btnLocationOff), @($btnBtOn, $btnBtOff),
        @($btnWifiOn, $btnWifiOff), @($btnSaverOn, $btnSaverOff), @($btnRingVibeOn, $btnRingVibeOff),
        @($btnHapticsOn, $btnHapticsOff), @($btnDevOn, $btnDevOff), @($btnTapsOn, $btnTapsOff),
        @($btnAwakeOn, $btnAwakeOff))
    $known = @($pairs | Where-Object { (Test-Lit $_[0]) -or (Test-Lit $_[1]) }).Count
    $both = @($pairs | Where-Object { (Test-Lit $_[0]) -and (Test-Lit $_[1]) }).Count
    Say ("  {0} of 10 known, none with both tinted   {1}" -f $known, (Mark ($known -ge 1 -and $both -eq 0)))
    Say ("  the marks are this phone's   {0}" -f (Mark ($script:toggleSerial -eq $TestSerial)))
}
