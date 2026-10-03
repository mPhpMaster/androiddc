# Advanced > Clipboard: which way a phone can share, reading and writing it,
# the monitor list, and one turn of the watch in each direction.
#
# adb is made up throughout - no phone is written to. This PC's own clipboard
# is used, because that is the thing being shared; what was on it is put back
# at the end.

$before = $null
try { $before = Get-Clipboard -Format Text -Raw -ErrorAction Stop } catch { }
function Reset-TestClipboard {
    if ($null -ne $before -and "$before") { $null = Set-Clipboard -Value $before }
    else { [System.Windows.Forms.Clipboard]::Clear() }
}

$script:asked = New-Object System.Collections.Generic.List[string]
$script:answers = @{}
# the longest pattern that fits wins, so a general one never hides a particular
$fakeShell = {
    param($Serial, $CommandArguments)
    $command = (@($CommandArguments) -join ' ')
    $null = $script:asked.Add($command)
    $text = ''
    foreach ($key in @($script:answers.Keys | Sort-Object -Property Length -Descending)) {
        if ($command -like $key) { $text = $script:answers[$key]; break }
    }
    return [PSCustomObject]@{ Lines = @("$text" -split "`n"); Text = $text; ExitCode = 0 }
}
function Get-Asked { param([string]$Like) return ,@($script:asked | Where-Object { $_ -like $Like }) }
function Invoke-WithFakePhone {
    # the shared file's calls, answered from $script:answers
    param([scriptblock]$Body)
    & {
        function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
        function Invoke-DeviceCommand { param($Serial, $Arguments) & $fakeShell $Serial $Arguments }
        & $Body
    }
}

Say '== which way a phone can share =='
Stop-AllClipboardShares
Clear-ClipboardEvents
$script:answers = @{ 'cmd clipboard get-primary-clip' = 'No shell command implementation.' }
$noWay = Invoke-WithFakePhone { $saved = $script:scrcpyPath; $script:scrcpyPath = $null
    $route = Get-ClipboardRoute -Serial 'A' -Again; $script:scrcpyPath = $saved; $route }
Say ("  a phone with no cmd clipboard, and no scrcpy here: {0}   {1}" -f $noWay, (Mark ($noWay -eq 'none')))
$viaScrcpy = Invoke-WithFakePhone { Get-ClipboardRoute -Serial 'A' -Again }
Say ("  with scrcpy here: {0}   {1}" -f $viaScrcpy, (Mark ($viaScrcpy -eq 'scrcpy')))
$script:answers = @{ 'cmd clipboard get-primary-clip' = 'on the phone' }
$viaCmd = Invoke-WithFakePhone { Get-ClipboardRoute -Serial 'B' -Again }
Say ("  a phone whose own shell can: {0}   {1}" -f $viaCmd, (Mark ($viaCmd -eq 'cmd')))
Say ("  and each one has words for it   {0}" -f (Mark (
    (Get-ClipboardRouteWords -Route 'cmd') -match 'both ways' -and
    (Get-ClipboardRouteWords -Route 'scrcpy') -match 'arrives by itself' -and
    (Get-ClipboardRouteWords -Route 'none') -match 'no way in')))

Say ''
Say '== reading and writing one =='
Say ("  what it holds: '{0}'   {1}" -f (Invoke-WithFakePhone { Get-PhoneClipboard -Serial 'B' }),
    (Mark ((Invoke-WithFakePhone { Get-PhoneClipboard -Serial 'B' }) -eq 'on the phone')))
$script:asked.Clear()
$sent = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'B' -Text 'from the PC' }
Say ("  sending runs: {0}   {1}" -f ((Get-Asked -Like 'cmd clipboard set-primary-clip*') -join ''), (Mark (
    $sent.Ok -and $sent.How -eq 'cmd' -and (Get-Asked -Like 'cmd clipboard set-primary-clip*').Count -eq 1)))
$script:answers['cmd clipboard set-primary-clip*'] = 'java.lang.SecurityException: Permission Denial'
Say ("  a refusal stays a refusal   {0}" -f (Mark (
    -not (Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'B' -Text 'x' }).Ok)))
$null = $script:answers.Remove('cmd clipboard set-primary-clip*')

$shut = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'A' -Text 'from the PC' }
Say ("  a phone that cannot be set: '{0}'   {1}" -f $shut.Text, (Mark (
    -not $shut.Ok -and $shut.Text -match 'typed instead')))
$script:asked.Clear()
$typed = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'A' -Text 'from the PC' -TypeWhenShut }
Say ("  with typing allowed it types it, and says so: {0}   {1}" -f $typed.How, (Mark (
    $typed.Ok -and $typed.How -eq 'typed' -and (Get-Asked -Like 'input text*').Count -eq 1)))

Say ''
Say '== the monitor =='
Clear-ClipboardEvents
$null = Add-ClipboardEvent -Phone 'B' -Way 'phone -> PC' -Text ("one`r`ntwo") -How 'cmd'
$null = Add-ClipboardEvent -Phone 'B' -Way 'PC -> phone' -Text 'later' -How 'cmd'
$events = @(Get-ClipboardEvents)
Say ("  newest first: {0}   {1}" -f ((@($events | ForEach-Object { $_.Way })) -join ' | '),
    (Mark ($events.Count -eq 2 -and $events[0].Way -eq 'PC -> phone')))
Say ("  many lines are shown as one: '{0}', {1} characters   {2}" -f $events[1].Line, $events[1].Chars,
    (Mark ($events[1].Line -eq 'one two' -and $events[1].Chars -eq 8)))
Say ("  the time is read the way a clock is: {0}   {1}" -f $events[0].Time,
    (Mark ($events[0].Time -match '^\d{1,2}:\d\d:\d\d (AM|PM)$')))
for ($i = 0; $i -lt 250; $i++) { $null = Add-ClipboardEvent -Phone 'B' -Way 'PC -> phone' -Text "$i" }
Say ("  the list keeps the last 200   {0}" -f (Mark (@(Get-ClipboardEvents).Count -eq 200)))
Clear-ClipboardEvents
Say ("  and it can be emptied   {0}" -f (Mark (@(Get-ClipboardEvents).Count -eq 0)))

Say ''
Say '== one turn of the watch =='
$script:answers = @{ 'cmd clipboard get-primary-clip' = '' }
$share = Invoke-WithFakePhone { Start-ClipboardShare -Serial 'B' -Model 'Test phone' }
Say ("  sharing with {0} the {1} way, and nothing was started for it   {2}" -f $share.Serial, $share.Route, (Mark (
    (Test-ClipboardSharing -Serial 'B') -and $share.Route -eq 'cmd' -and $null -eq $share.Process)))

$null = Set-Clipboard -Value 'here before sharing'
$first = @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet })
Say ("  the first turn only learns what is already here   {0}" -f (Mark ($first.Count -eq 0)))
$null = Set-Clipboard -Value 'copied on this PC'
$second = @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet })
Say ("  then this PC's goes over: {0}   {1}" -f ((@($second | ForEach-Object { "$($_.Way) $($_.Chars)" })) -join ', '),
    (Mark ($second.Count -eq 1 -and $second[0].Way -eq 'PC -> phone' -and $second[0].Text -eq 'copied on this PC')))
Say ("  the same text is not sent twice   {0}" -f (Mark (
    @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet }).Count -eq 0)))

$script:answers['cmd clipboard get-primary-clip'] = 'copied on the phone'
$third = @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet })
Say ("  what the phone copies comes here: {0}   {1}" -f ((@($third | ForEach-Object { $_.Way })) -join ', '),
    (Mark ($third.Count -eq 1 -and $third[0].Way -eq 'phone -> PC' -and (Get-ClipboardHere) -eq 'copied on the phone')))
Say ("  and it is not sent straight back   {0}" -f (Mark (
    @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet }).Count -eq 0)))

Say ''
Say '== the page =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabClipboard
Wait-Pumped -Milliseconds 200
Update-ClipboardUi
Say ("  it says who it is sharing with: '{0}'   {1}" -f $lblClipState.Text, (Mark (
    $lblClipState.Text -match 'Test phone \(cmd\)' -and -not $btnClipStart.Enabled -and $btnClipStop.Enabled)))
Update-ClipboardList
Say ("  the list shows what moved: {0} line(s)   {1}" -f $lstClipboard.Items.Count, (Mark (
    $lstClipboard.Items.Count -eq @(Get-ClipboardEvents).Count -and $lstClipboard.Items.Count -gt 0)))
Say ("  newest at the top, with the phone and the way   {0}" -f (Mark (
    $lstClipboard.Items[0].SubItems[1].Text -eq 'B' -and $lstClipboard.Items[0].SubItems[2].Text -match 'phone|PC')))
$lstClipboard.Items[0].Selected = $true
Copy-ClipboardRow
Say ("  a line can be put back on this PC   {0}" -f (Mark ((Get-ClipboardHere) -eq 'copied on the phone')))

# the log is told the length, never the text: a log can be saved to a file
$secret = 'hunter2-not-in-any-log'
$null = Add-ClipboardEvent -Phone 'B' -Way 'PC -> phone' -Text $secret
Say ("  what was copied is kept in the window, not written to the log   {0}" -f (Mark (
    $txtLog.Text -notmatch 'hunter2')))

Stop-ClipboardSharing
Say ("  stopping leaves nothing sharing   {0}" -f (Mark (
    -not (Test-ClipboardSharing) -and $btnClipStart.Enabled -and -not $btnClipStop.Enabled)))
Clear-ClipboardEvents
Update-ClipboardList
Say ("  and the list can be emptied   {0}" -f (Mark ($lstClipboard.Items.Count -eq 0)))

Say ''
Say '== the phone that is plugged in, asked which way it can go =='
if (-not $TestSerial) {
    Say '  SKIPPED - no phone attached right now'
} else {
    Select-TestPhone
    # read-only: it asks the phone's shell for its clipboard, and on a phone
    # without that command the answer is the refusal, not anyone's text
    $route = Get-ClipboardRoute -Serial $TestSerial -Again
    Say ("  this phone: {0} - {1}" -f $route, (Get-ClipboardRouteWords -Route $route))
    Say ("  which is one of the three ways   {0}" -f (Mark (@('cmd', 'scrcpy', 'none') -contains $route)))
    Say ("  and nothing was shared with it   {0}" -f (Mark (-not (Test-ClipboardSharing -Serial $TestSerial))))
}

Reset-TestClipboard
