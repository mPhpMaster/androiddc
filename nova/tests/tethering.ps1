# The Tethering page: both inner pages fit the smallest window, and the parts
# that decide what happens to a phone work on made-up input - which phones get
# Wi-Fi back, the relay's log file names, the relay output reader, the port
# check, the button states. Reads only: nothing here starts sharing, touches
# USB tethering, the Windows proxy or an adb forward.

Say '== the page =='
Show-Page -Page 'tethering'
$null = Wait-Idle -Seconds 30
Say ("  page shown   {0}" -f (Mark (Test-PageShown -Key 'tethering')))

foreach ($tab in @(0, 1)) {
    $ui.TetheringTabs.SelectedIndex = $tab
    foreach ($size in @('default', 'min')) {
        Set-WindowSize $size
        $null = Wait-Idle -Seconds 10
        $path = Save-WindowPicture "tethering-tab$tab-$size"
        Say ("  tab {0} {1}: {2}" -f $tab, $size, $path)
        $outside = @(Get-OutsideElements -Root $tetheringPage.Root)
        Say ("  tab {0} {1}: nothing sticks out on the right {2}  {3}" -f $tab, $size, ($outside -join '; '), (Mark ($outside.Count -eq 0)))
    }
}
$ui.TetheringTabs.SelectedIndex = 0
Set-WindowSize 'default'

Say ''
Say '== tunnel arguments =='
$ui.TetheringDns.Text = ''
$ui.TetheringPort.Text = '99999'
$ui.TetheringRoutes.Text = ' 10.0.0.0/8 '
$joined = (Get-ExtraArguments) -join ' '
Say ("  empty DNS is 8.8.8.8, port capped, routes trimmed: '{0}'   {1}" -f $joined, (Mark ($joined -eq '-d 8.8.8.8 -p 65535 -r 10.0.0.0/8')))
$ui.TetheringPort.Text = '80'
Say ("  a port below 1024 becomes 1024   {0}" -f (Mark ((Get-TetheringPort) -eq 1024)))
$ui.TetheringDns.Text = '8.8.8.8'
$ui.TetheringPort.Text = '31416'
$ui.TetheringRoutes.Text = ''
$joined = (Get-ExtraArguments) -join ' '
Say ("  defaults: '{0}'   {1}" -f $joined, (Mark ($joined -eq '-d 8.8.8.8 -p 31416')))
Say ("  DNS presets: {0}   {1}" -f (@($ui.TetheringDns.Items) -join ' | '), (Mark ($ui.TetheringDns.Items.Count -eq 5 -and $ui.TetheringDns.IsEditable)))

Say ''
Say '== relay log files =='
$files = Get-TetheringRelayFiles -Stamp '120000123'
$outName = Split-Path -Leaf $files.Out
$errName = Split-Path -Leaf $files.Err
Say ("  named per process and start: {0}, {1}   {2}" -f ($outName -replace '\d{3,}', '<n>'), ($errName -replace '\d{3,}', '<n>'),
    (Mark ($outName -eq "androiddc-nova-$PID.relay-120000123.out" -and $errName -eq "androiddc-nova-$PID.relay-120000123.err")))
Say ("  under TEMP, where the window deletes androiddc-nova-PID.* at exit   {0}" -f (Mark (
    (Split-Path -Parent $files.Out) -eq $env:TEMP -and $outName -like "androiddc-nova-$PID.*" -and $errName -like "androiddc-nova-$PID.*")))
$first = Get-TetheringRelayFiles
Start-Sleep -Milliseconds 15
$second = Get-TetheringRelayFiles
Say ("  a second start gets a new pair   {0}" -f (Mark ($first.Out -ne $second.Out -and $first.Err -ne $second.Err)))

$sample = Join-Path $TestOut 'relay-reader.txt'
[IO.File]::WriteAllText($sample, "one`n")
$script:testOffset = 0
$read1 = Read-NewOutput -Path $sample -Offset ([ref]$script:testOffset)
[IO.File]::AppendAllText($sample, "two`n")
$read2 = Read-NewOutput -Path $sample -Offset ([ref]$script:testOffset)
$read3 = Read-NewOutput -Path $sample -Offset ([ref]$script:testOffset)
[IO.File]::WriteAllText($sample, "x`n")
$read4 = Read-NewOutput -Path $sample -Offset ([ref]$script:testOffset)
Say ("  the output reader returns only what is new, and starts over on a shorter file   {0}" -f (Mark (
    $read1 -eq "one`n" -and $read2 -eq "two`n" -and $read3 -eq '' -and $read4 -eq "x`n")))
Say ("  no file, no text   {0}" -f (Mark ((Read-NewOutput -Path (Join-Path $TestOut 'missing.txt') -Offset ([ref]$script:testOffset)) -eq '')))
Remove-Item -LiteralPath $sample -Force

Say ''
Say '== Wi-Fi comes back only where sharing turned it off (adb mocked) =='
$savedShell = ${function:Invoke-DeviceShell}
$script:mockCalls = New-Object System.Collections.ArrayList
$script:mockWifi = @{ 'FAKE-ON' = '1'; 'FAKE-OFF' = '0' }
Set-Item -Path function:script:Invoke-DeviceShell -Value {
    param([string]$Serial, [string[]]$CommandArguments)
    $command = $CommandArguments -join ' '
    $null = $script:mockCalls.Add("$Serial $command")
    $text = if ($command -eq 'settings get global wifi_on') { $script:mockWifi[$Serial] } else { '' }
    [PSCustomObject]@{ ExitCode = 0; Lines = @($text); Text = $text }
}
try {
    $script:wifiDisabled = @()
    Disable-TetheringWifi -Serial 'FAKE-ON'
    Disable-TetheringWifi -Serial 'FAKE-OFF'
    Disable-TetheringWifi -Serial 'FAKE-ON'
    $disables = @($script:mockCalls | Where-Object { $_ -like '* svc wifi disable' })
    Say ("  wifi_on is read first on each phone   {0}" -f (Mark (@($script:mockCalls | Where-Object { $_ -like '* settings get global wifi_on' }).Count -eq 3)))
    Say ("  only the phone with Wi-Fi on is turned off   {0}" -f (Mark ($disables.Count -eq 2 -and @($disables | Where-Object { $_ -notlike 'FAKE-ON *' }).Count -eq 0)))
    Say ("  and it is remembered once: [{0}]   {1}" -f ($script:wifiDisabled -join ','), (Mark ((@($script:wifiDisabled) -join ',') -eq 'FAKE-ON')))

    $script:mockCalls.Clear()
    Restore-TetheringWifi -Serials @('FAKE-ON', 'FAKE-OFF') -Quiet
    $enables = @($script:mockCalls | Where-Object { $_ -like '* svc wifi enable' })
    Say ("  stopping turns Wi-Fi on for that phone only   {0}" -f (Mark ($enables.Count -eq 1 -and $enables[0] -eq 'FAKE-ON svc wifi enable')))
    Say ("  and forgets it   {0}" -f (Mark (@($script:wifiDisabled).Count -eq 0)))

    $script:mockCalls.Clear()
    Restore-TetheringWifi -Serials @('FAKE-ON') -Quiet
    Say ("  a second stop turns nothing on   {0}" -f (Mark ($script:mockCalls.Count -eq 0)))

    # a start that failed half way: the phone is off Wi-Fi but never became active
    $script:wifiDisabled = @('FAKE-ON')
    $script:mockCalls.Clear()
    Restore-TetheringWifi -Quiet
    Say ("  a phone left off Wi-Fi by a failed start still gets it back   {0}" -f (Mark (
        $script:mockCalls.Count -eq 1 -and $script:mockCalls[0] -eq 'FAKE-ON svc wifi enable' -and @($script:wifiDisabled).Count -eq 0)))
} finally {
    Set-Item -Path function:script:Invoke-DeviceShell -Value $savedShell
    $script:wifiDisabled = @()
}
Say ("  the real Invoke-DeviceShell is back   {0}" -f (Mark ("${function:Invoke-DeviceShell}" -eq "$savedShell")))

Say ''
Say '== the port check =='
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$busyPort = $listener.LocalEndpoint.Port
$owner = Get-PortOwner -Port $busyPort
Say ("  a port this process listens on is reported with its owner   {0}" -f (Mark ($owner -and ($owner.ProcessId -eq $PID -or $owner.ProcessId -eq 0))))
$listener.Stop()
Wait-Pumped -Milliseconds 300
Say ("  a free port has no owner   {0}" -f (Mark ($null -eq (Get-PortOwner -Port $busyPort))))

Say ''
Say '== button states and the sharing pill =='
Set-TetheringRunning -IsRunning $true -Target 'test target'
Say ("  running: Start off, Stop on, All devices locked, pill '{0}'   {1}" -f $ui.SharingText.Text, (Mark (
    -not $ui.TetheringStart.IsEnabled -and $ui.TetheringStop.IsEnabled -and -not $ui.AllDevices.IsEnabled -and
    $ui.SharingText.Text -eq 'Sharing: test target' -and $ui.SideSharing.Text -eq 'On' -and $ui.TetheringState.Text -eq 'Sharing: test target')))
Set-TetheringRunning -IsRunning $false
Say ("  stopped: back as it was, pill '{0}'   {1}" -f $ui.SharingText.Text, (Mark (
    $ui.TetheringStart.IsEnabled -and -not $ui.TetheringStop.IsEnabled -and $ui.AllDevices.IsEnabled -and
    $ui.SharingText.Text -eq 'Sharing: off' -and $ui.SideSharing.Text -eq 'Off')))
Say ("  the relay timer is not running and there is no relay   {0}" -f (Mark (-not $script:relayTimer.IsEnabled -and $null -eq $script:relayProcess)))

Say ''
Say '== phone -> PC, read-only parts =='
$ui.TetheringTabs.SelectedIndex = 1
$adapter = Show-TetherAdapters
Say ("  the PC-side line is filled in   {0}" -f (Mark ($ui.TetheringUsbStatus.Text -like 'PC side:*')))
Say ("  WinInet is loaded for the proxy refresh   {0}" -f (Mark ([bool]('AndroidDcNova.WinInet' -as [type]))))

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$before = Get-ItemProperty -Path $key
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$freePort = $probe.LocalEndpoint.Port
$probe.Stop()
$answered = Test-PhoneProxy -Port $freePort
Say ("  a proxy test on a port nobody listens on fails   {0}" -f (Mark (-not $answered)))
Stop-PhoneProxy -Quiet
$after = Get-ItemProperty -Path $key
$names = @($before.PSObject.Properties.Name)
$same = $true
foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride')) {
    if ($names -contains $name) { if ("$($before.$name)" -ne "$($after.$name)") { $same = $false } }
}
Say ("  the Windows proxy was not touched, and no proxy is in use   {0}" -f (Mark ($same -and $script:proxyPort -eq 0 -and $ui.TetheringProxyOn.IsEnabled -and -not $ui.TetheringProxyOff.IsEnabled)))
$ui.TetheringProxyPort.Text = '0'
Say ("  the proxy port box keeps its limits   {0}" -f (Mark ((Get-TetheringProxyPort) -eq 1)))
$ui.TetheringProxyPort.Text = '8080'
$ui.TetheringTabs.SelectedIndex = 0

Say ''
Say ("  nothing for the cleanup to undo on the phone   {0}" -f (Mark (
    $null -eq $script:relayProcess -and @($script:activeSerials).Count -eq 0 -and @($script:wifiDisabled).Count -eq 0 -and $script:proxyPort -eq 0)))
