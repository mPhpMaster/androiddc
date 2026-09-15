# The Tools page: both inner tabs fit the smallest window and scroll; the DNS line is read
# from the phone when the page opens; the root marks are read from the phone (getprop and
# id only), belong to one phone, are cleared when another phone is picked while hidden,
# read again when it is picked while shown, and never read again for the same phone; the
# unlock switch; and the jdwp / ps / DNS parsing on made-up input.
# Reads only: no root action, no pairing or connecting, no DNS, IME, hotspot or screen change.

$toolsTestPage = Get-Page -Key 'tools'
$harmless = (@('wait-for-device', 'keygen...', 'get-devpath') | Sort-Object) -join ','

function Get-ToolsTestReads {
    # how often the root page has read this phone: its log line per read
    param([string]$Serial)
    return @($script:logLines | Where-Object { $_.Text -like "$Serial : build=*" }).Count
}
function Get-ToolsTestEnabled {
    return (@($script:rootButtons | Where-Object { $_.Button.IsEnabled } | ForEach-Object { $_.Caption } | Sort-Object)) -join ','
}
function Invoke-ToolsTestOtherPhone {
    # another phone picked: Get-SelectedSerial answers a serial that is not the one read,
    # and the page is told a phone changed, as the shell's device timer does
    $real = ${function:Get-SelectedSerial}
    Set-Item -Path function:script:Get-SelectedSerial -Value { 'ANOTHER-PHONE' }
    try { & $toolsTestPage.OnDeviceChanged } finally { Set-Item -Path function:script:Get-SelectedSerial -Value $real }
    $null = Wait-Idle -Seconds 30
}

Say '== startup =='
$idle = Wait-Idle -Seconds 40
Say ("  idle after the first device read   {0}" -f (Mark $idle))
$phone = Get-SelectedSerial
$ready = [bool]($phone -and @($script:deviceRows | Where-Object { $_.Serial -eq $phone -and $_.State -eq 'device' }).Count -gt 0)
Say ("  a ready phone is attached: {0}" -f $ready)
Say ("  eleven root rows, each with a mark and a run button   {0}" -f (Mark ($script:rootButtons.Count -eq 11 -and
    @($script:rootButtons | Where-Object { $ui.ContainsKey($_.Name) -and $ui.ContainsKey("$($_.Name)Mark") }).Count -eq 11)))
Say ("  nothing enabled before a check   {0}" -f (Mark ((Get-ToolsTestEnabled) -eq '')))

Say ''
Say '== made-up input =='
$names = ConvertFrom-ToolsPsLines -Lines @('  PID NAME', '    1 init', '  742 com.example.debuggable', 'garbage line', ' 1203 system_server', '')
Say ("  ps: 3 names, 742 is com.example.debuggable   {0}" -f (Mark ($names.Count -eq 3 -and $names['742'] -eq 'com.example.debuggable' -and $names['1'] -eq 'init')))
$pids = @(ConvertFrom-ToolsJdwpText -Text "742`r`n1203`nnot-a-pid`n 99x`n")
Say ("  jdwp: ids 742 and 1203 only   {0}" -f (Mark ($pids.Count -eq 2 -and $pids[0] -eq '742' -and $pids[1] -eq '1203')))
$lines = @(Format-ToolsJdwpLines -Pids @('742', '5555') -Names $names)
Say ("  jdwp lines name each id, '?' for one ps did not list   {0}" -f
    (Mark ($lines.Count -eq 2 -and $lines[0] -match '^\s+742\s+com\.example\.debuggable$' -and $lines[1] -match '^\s+5555\s+\?$')))
$single = @(Format-ToolsJdwpLines -Pids @('1') -Names $names)
Say ("  one id stays one line   {0}" -f (Mark ($single.Count -eq 1 -and $single[0] -match 'init$')))
$dns = @(ConvertFrom-ToolsDnsAddresses -Text 'NetworkAgentInfo{network{100} ... DnsAddresses: [ /192.168.1.1,/fe80::1 ] Domains: null }')
Say ("  DNS addresses without their slashes   {0}" -f (Mark ($dns.Count -eq 2 -and $dns[0] -eq '192.168.1.1' -and $dns[1] -eq 'fe80::1')))
$firstList = @(ConvertFrom-ToolsDnsAddresses -First -Text 'DnsAddresses: [] x DnsAddresses: [/8.8.8.8] y DnsAddresses: [/1.1.1.1]')
Say ("  last resort takes the first list that has any   {0}" -f (Mark ($firstList.Count -eq 1 -and $firstList[0] -eq '8.8.8.8')))
$retailRows = @($script:rootButtons | Where-Object { Get-ToolsRootPossible -Needs $_.Needs -Rootable $false -AlreadyRoot $false } | ForEach-Object { $_.Caption } | Sort-Object) -join ','
Say ("  a retail build allows only the harmless three   {0}" -f (Mark ($retailRows -eq $harmless)))
$debugRows = @($script:rootButtons | Where-Object { Get-ToolsRootPossible -Needs $_.Needs -Rootable $true -AlreadyRoot $false }).Count
Say ("  a userdebug build adds root, remount and verity ({0})   {1}" -f $debugRows, (Mark ($debugRows -eq 7)))
$rootRows = @($script:rootButtons | Where-Object { Get-ToolsRootPossible -Needs $_.Needs -Rootable $false -AlreadyRoot $true }).Count
Say ("  an adbd already root adds unroot, remount and verity ({0})   {1}" -f $rootRows, (Mark ($rootRows -eq 7)))
$busyName = Get-BusyText -FilePath 'adb.exe' -ArgumentList @('-s', 'SERIAL1', 'bugreport', 'bugreport.zip')
Say ("  the busy strip names a bug report '{0}'   {1}" -f $busyName, (Mark ($busyName -eq 'adb bugreport bugreport.zip')))

Say ''
Say '== the device tools page reads the DNS by itself =='
$ui.ToolsTabs.SelectedItem = $ui.ToolsTabDevice
Show-Page -Page 'tools'
$null = Wait-Idle -Seconds 30
if ($ready) {
    $mode = (Invoke-DeviceShell -Serial $phone -CommandArguments @('settings', 'get', 'global', 'private_dns_mode')).Text.Trim()
    $expected = switch ($mode) { 'off' { 1 } 'hostname' { 2 } default { 0 } }
    Say ("  '{0}'" -f $ui.ToolsDnsState.Text)
    Say ("  the line and the mode box follow the phone ({0})   {1}" -f $mode, (Mark (
        $ui.ToolsDnsState.Text -match '^mode: .+   \|   resolvers in use: .+' -and
        $ui.ToolsDnsMode.SelectedIndex -eq $expected -and $script:toolsDnsSerial -eq $phone)))
    Say ("  the hostname box is only for custom   {0}" -f (Mark ($ui.ToolsDnsHost.IsEnabled -eq ($expected -eq 2))))

    Update-ImeList
    Say ("  keyboards listed: {0}, one picked   {1}" -f $ui.ToolsIme.Items.Count,
        (Mark ($ui.ToolsIme.Items.Count -gt 0 -and (Get-ImeId) -match '/' -and $script:toolsImeSerial -eq $phone)))
    $ip = Get-DeviceIp -Serial $phone
    Say ("  Wi-Fi address read: {0}" -f $(if ($ip) { 'yes' } else { 'none (not on Wi-Fi)' }))
} else {
    Say 'SKIPPED the DNS and keyboard reads - no ready phone'
}

Say ''
Say '== opened on the root tab, it reads the phone by itself =='
if ($ready) {
    $retail = (Invoke-DeviceShell -Serial $phone -CommandArguments @('getprop', 'ro.build.type')).Text.Trim() -eq 'user'
    Say ("  retail build: {0}" -f $retail)
    Reset-RootAvailability
    $before = Get-ToolsTestReads -Serial $phone
    $ui.ToolsTabs.SelectedItem = $ui.ToolsTabRoot
    $null = Wait-Idle -Seconds 30
    Say ("  '{0}'" -f $ui.ToolsRootState.Text)
    Say ("  read once, the marks belong to this phone   {0}" -f
        (Mark (((Get-ToolsTestReads -Serial $phone) - $before) -eq 1 -and $script:rootCheckedSerial -eq $phone)))
    if ($retail) {
        Say ("  only the harmless three are enabled and marked   {0}" -f (Mark ((Get-ToolsTestEnabled) -eq $harmless -and
            (@($script:rootButtons | Where-Object { $_.Possible } | ForEach-Object { $_.Caption } | Sort-Object) -join ',') -eq $harmless -and
            @($script:rootButtons | Where-Object { $_.Possible -and $_.Mark.Text -ne [string][char]0xE73E }).Count -eq 0)))
    }

    Say ''
    Say '== the same phone again, or the list read again: nothing read again =='
    $before = Get-ToolsTestReads -Serial $phone
    & $toolsTestPage.OnDeviceChanged
    Update-DeviceList
    Wait-Pumped -Milliseconds 1500
    $null = Wait-Idle -Seconds 30
    Say ("  no new read   {0}" -f (Mark (((Get-ToolsTestReads -Serial $phone) - $before) -eq 0)))

    Say ''
    Say '== another phone while the root tab is hidden: the marks are cleared =='
    $ui.ToolsTabs.SelectedItem = $ui.ToolsTabDevice
    $null = Wait-Idle -Seconds 30
    $before = Get-ToolsTestReads -Serial $phone
    Invoke-ToolsTestOtherPhone
    $still = @($script:rootButtons | Where-Object { $_.Button.IsEnabled -or $_.Possible })
    Say ("  cleared, not read   {0}" -f (Mark ($ui.ToolsRootState.Text -eq 'not checked yet' -and $still.Count -eq 0 -and
        $null -eq $script:rootCheckedSerial -and ((Get-ToolsTestReads -Serial $phone) - $before) -eq 0)))

    Say ''
    Say '== another phone while the root tab is on screen: read again =='
    $ui.ToolsTabs.SelectedItem = $ui.ToolsTabRoot
    $null = Wait-Idle -Seconds 30
    $before = Get-ToolsTestReads -Serial $phone
    Invoke-ToolsTestOtherPhone
    Say ("  read again, the marks belong to the phone asked   {0}" -f
        (Mark (((Get-ToolsTestReads -Serial $phone) - $before) -eq 1 -and $script:rootCheckedSerial -eq $phone)))
    $before = Get-ToolsTestReads -Serial $phone
    & $toolsTestPage.OnDeviceChanged
    $null = Wait-Idle -Seconds 30
    Say ("  and the same phone after it reads nothing   {0}" -f (Mark (((Get-ToolsTestReads -Serial $phone) - $before) -eq 0)))

    Say ''
    Say '== unlocked =='
    $ui.ToolsRootUnlock.IsChecked = $true
    Wait-Pumped -Milliseconds 200
    Say ("  everything enabled, and the log says the phone still decides   {0}" -f (Mark (
        @($script:rootButtons | Where-Object { -not $_.Button.IsEnabled }).Count -eq 0 -and
        @($script:logLines)[-1].Text -like 'Root actions unlocked*')))
    $ui.ToolsRootUnlock.IsChecked = $false
    Wait-Pumped -Milliseconds 200
    if ($retail) { Say ("  locked again: only the harmless three   {0}" -f (Mark ((Get-ToolsTestEnabled) -eq $harmless))) }
} else {
    Say 'SKIPPED the root marks - no ready phone'
    $ui.ToolsRootUnlock.IsChecked = $true
    Wait-Pumped -Milliseconds 200
    Say ("  unlocked: everything enabled   {0}" -f (Mark (@($script:rootButtons | Where-Object { -not $_.Button.IsEnabled }).Count -eq 0)))
    $ui.ToolsRootUnlock.IsChecked = $false
    Wait-Pumped -Milliseconds 200
    Say ("  locked: nothing enabled   {0}" -f (Mark ((Get-ToolsTestEnabled) -eq '')))
}

Say ''
Say '== the pictures =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    foreach ($tab in @('device', 'root')) {
        if ($tab -eq 'root') { $ui.ToolsTabs.SelectedItem = $ui.ToolsTabRoot; $scroll = $ui.ToolsRootScroll }
        else { $ui.ToolsTabs.SelectedItem = $ui.ToolsTabDevice; $scroll = $ui.ToolsDeviceScroll }
        $null = Wait-Idle -Seconds 30
        $scroll.ScrollToHome()
        $picture = Save-WindowPicture "tools-$tab-$size"
        Say ("  {0}" -f (Split-Path -Leaf $picture))
        $outside = @(Get-OutsideElements -Root $toolsTestPage.Root)
        Say ("  {0} {1}: nothing sticks out on the right{2}   {3}" -f $tab, $size,
            $(if ($outside.Count) { ' - ' + ($outside -join '; ') } else { '' }), (Mark ($outside.Count -eq 0)))
        if ($size -eq 'min') {
            Say ("  {0} min: the cards scroll ({1:N0} px more)   {2}" -f $tab, $scroll.ScrollableHeight, (Mark ($scroll.ScrollableHeight -gt 0)))
            $scroll.ScrollToEnd()
            $picture = Save-WindowPicture "tools-$tab-$size-end"
            Say ("  {0}" -f (Split-Path -Leaf $picture))
            $outside = @(Get-OutsideElements -Root $toolsTestPage.Root)
            Say ("  {0} min, scrolled to the end: nothing sticks out   {1}" -f $tab, (Mark ($outside.Count -eq 0)))
            $scroll.ScrollToHome()
        }
    }
}
Set-WindowSize 'default'
