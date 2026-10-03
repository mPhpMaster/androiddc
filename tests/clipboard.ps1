# Advanced > Clipboard: which way a phone can share, reading and writing it,
# the monitor list, and one turn of the watch in each direction.
#
# adb is made up throughout, except for the last section: with a phone
# attached, that one shares with it for real, because a clipboard that is
# never carried on a real phone is how the first version of this shipped
# broken. It writes only the phone's clipboard, saves what was on it first and
# puts it back at the end. This PC's own clipboard is used throughout, because
# that is the thing being shared; what was on it is put back at the end too.

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
        if ($command -like $key) {
            $answer = $script:answers[$key]
            # a script block is asked: that is how the fake phone keeps a
            # clipboard, answering with whatever was last written to it
            $text = $(if ($answer -is [scriptblock]) { & $answer $command } else { $answer })
            break
        }
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
    (Get-ClipboardRouteWords -Route 'binder') -match 'both ways' -and
    (Get-ClipboardRouteWords -Route 'scrcpy') -match 'only what the phone copies' -and
    (Get-ClipboardRouteWords -Route 'none') -match 'no way in')))

Say ''
Say '== the phone''s own clipboard service =='
# The parcels below are built the way a phone builds them, and printed the way
# the service tool prints one, so the reader is read against the real thing
# rather than against the writer in the same file.
function Add-TestWord {
    param($List, [int]$Value)
    foreach ($byte in [BitConverter]::GetBytes($Value)) { $null = $List.Add($byte) }
}
function Add-TestText {
    param($List, [string]$Text, [int]$Width, [switch]$Nothing)
    if ($Nothing) { Add-TestWord $List -1; return }
    [byte[]]$raw = $(if ($Width -eq 16) {
        [System.Text.Encoding]::Unicode.GetBytes($Text)
    } else {
        [System.Text.Encoding]::UTF8.GetBytes($Text)
    })
    Add-TestWord $List $(if ($Width -eq 16) { $Text.Length } else { $raw.Length })
    foreach ($byte in $raw) { $null = $List.Add($byte) }
    $null = $List.Add(0)
    if ($Width -eq 16) { $null = $List.Add(0) }
    while ($List.Count % 4 -ne 0) { $null = $List.Add(0) }
}
function New-TestClipDump {
    param([string]$Text, [int]$Width = 8, [int]$Tail = 3, [int]$ItemTail = 5,
        [string[]]$Mimes = @('text/plain'), [switch]$Description, [switch]$WithLink)

    $bytes = New-Object System.Collections.Generic.List[byte]
    Add-TestWord $bytes 0                    # nothing was thrown
    Add-TestWord $bytes 1                    # there is a clip
    Add-TestWord $bytes 1                    # a plain label
    Add-TestText $bytes 'text' $Width
    Add-TestWord $bytes $Mimes.Count
    foreach ($mime in $Mimes) { Add-TestText $bytes $mime 16 }
    Add-TestWord $bytes -1                   # no extras
    Add-TestWord $bytes 0                    # when it was copied, as a long
    Add-TestWord $bytes 0
    for ($i = 0; $i -lt $Tail; $i++) { Add-TestWord $bytes 0 }
    if (-not $Description) {
        Add-TestWord $bytes 0                # no picture
        Add-TestWord $bytes 1                # one item
        Add-TestWord $bytes 1                # plain text
        Add-TestText $bytes $Text $Width
        Add-TestText $bytes '' $Width -Nothing
        for ($i = 0; $i -lt $ItemTail; $i++) {
            # a link in one of the slots is what a copied picture looks like
            if ($WithLink -and $i -eq 1) {
                Add-TestWord $bytes 1
                Add-TestWord $bytes 0
                Add-TestText $bytes 'content://media/external/images/media/42' $Width
            } else {
                Add-TestWord $bytes 0
            }
        }
    }
    $all = $bytes.ToArray()
    $lines = New-Object System.Collections.Generic.List[string]
    $null = $lines.Add('Result: Parcel(')
    for ($at = 0; $at -lt $all.Length; $at += 16) {
        $words = @()
        for ($spot = $at; $spot -lt [Math]::Min($at + 16, $all.Length); $spot += 4) {
            $words += ('{0:x8}' -f [BitConverter]::ToUInt32($all, $spot))
        }
        $null = $lines.Add(("0x{0:x8}: {1} '................'" -f $at, ($words -join ' ')))
    }
    return (($lines -join "`n") + ')')
}
function Get-TestClipWritten {
    # the text out of a parcel this program just wrote, read back with the
    # same reader the phone's answers go through
    param([string]$Command)

    $bytes = New-Object System.Collections.Generic.List[byte]
    Add-TestWord $bytes 0
    $parts = @("$Command" -split '\s+')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq 's16') { break }
        if ($parts[$i] -eq 'i32' -and $i + 1 -lt $parts.Count -and $parts[$i + 1] -match '^-?\d+$') {
            Add-TestWord $bytes ([int]$parts[$i + 1])
        }
    }
    foreach ($width in @(8, 16)) {
        foreach ($tail in @(3, 2, 1, 0, 4)) {
            foreach ($itemTail in @(5, 3, 4, 2, 6, 1, 0)) {
                $read = Read-ClipboardParcel -Bytes $bytes.ToArray() -Width $width -Tail $tail -ItemTail $itemTail
                if ($null -ne $read) { return $read.Text }
            }
        }
    }
    return $null
}

$script:fakeClip = 'copied on the phone'
$script:answers = @{
    'cmd clipboard get-primary-clip' = 'No shell command implementation.'
    'service check clipboard'        = 'Service clipboard: found'
    'am get-current-user'            = '10'
    'service call clipboard 4*'      = { New-TestClipDump -Text $script:fakeClip }
    'service call clipboard 1*'      = {
        param($command)
        $written = Get-TestClipWritten -Command $command
        if ($null -ne $written) { $script:fakeClip = $written }
        "Result: Parcel(`t00000000    '....')"
    }
}
$script:asked.Clear()
$viaBinder = Invoke-WithFakePhone { Get-ClipboardRoute -Serial 'C' -Again }
Say ("  a phone with no shell command but a service that answers: {0}   {1}" -f $viaBinder,
    (Mark ($viaBinder -eq 'binder')))
Say ("  and it asks about the user in front, not Owner   {0}" -f (Mark (
    (Get-Asked -Like '*get-current-user*').Count -ge 1 -and
    (Get-Asked -Like 'service call clipboard 4*i32 10 i32 0').Count -ge 1)))
Say ("  what it holds: '{0}'   {1}" -f (Invoke-WithFakePhone { Get-PhoneClipboard -Serial 'C' }),
    (Mark ((Invoke-WithFakePhone { Get-PhoneClipboard -Serial 'C' }) -eq 'copied on the phone')))

# the shape of a parcel is not the same on every Android, so it is learnt
$script:answers['service call clipboard 4*'] = { New-TestClipDump -Text 'an older phone' -Width 16 -Tail 1 -ItemTail 3 }
$older = Invoke-WithFakePhone { Get-PhoneClipboard -Serial 'D' }
$shape = Get-ClipboardShape -Serial 'D'
Say ("  a parcel in another shape is still read: '{0}' (utf-{1}, {2} and {3} trailing)   {4}" -f $older,
    $shape.Width, $shape.Tail, $shape.ItemTail, (Mark (
    $older -eq 'an older phone' -and $shape.Width -eq 16 -and $shape.Tail -eq 1 -and $shape.ItemTail -eq 3)))
$script:answers['service call clipboard 4*'] = { New-TestClipDump -Text $script:fakeClip }

$script:asked.Clear()
$put = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'C' -Text 'sent from this PC' }
Say ("  sending builds a parcel the phone keeps: '{0}'   {1}" -f $script:fakeClip, (Mark (
    $put.Ok -and $put.How -eq 'binder' -and $script:fakeClip -eq 'sent from this PC')))
Say ("  and it was one call, not a hunt   {0}" -f (Mark (
    (Get-Asked -Like 'service call clipboard 1*').Count -eq 1)))

$hard = "two lines`nand a 'quote' and an & and `$x"
$null = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'C' -Text $hard }
Say ("  text with quotes, an ampersand and a newline crosses whole   {0}" -f (Mark ($script:fakeClip -eq $hard)))

$script:answers['service call clipboard 1*'] = "Result: Parcel(`t fffffffe 00000038   '....')"
$refused = Invoke-WithFakePhone { Set-PhoneClipboard -Serial 'C' -Text 'nope' }
Say ("  a phone that throws is not said to have taken it   {0}" -f (Mark (-not $refused.Ok)))
$script:answers['service call clipboard 1*'] = {
    param($command)
    $written = Get-TestClipWritten -Command $command
    if ($null -ne $written) { $script:fakeClip = $written }
    "Result: Parcel(`t00000000    '....')"
}

$script:asked.Clear()
$huge = Invoke-WithFakePhone { Set-PhoneClipParcel -Serial 'C' -Text ('x' * 70000) }
Say ("  a clipboard too big for a shell line is refused, not half sent: '{0}'   {1}" -f $huge.Text, (Mark (
    -not $huge.Ok -and $huge.Text -match 'too much' -and (Get-Asked -Like 'service call*').Count -eq 0)))

# a copied picture: the clipboard holds a link to it, which means nothing here
$script:answers['service call clipboard 4*'] = { New-TestClipDump -Text 'x' -Mimes @('image/png') -WithLink }
$script:answers['service call clipboard 5*'] = { New-TestClipDump -Text '' -Mimes @('image/png') -Description }
$picture = Invoke-WithFakePhone { Get-PhoneClipParcel -Serial 'C' }
Say ("  a copied picture is seen for what it is: {0}   {1}" -f ($picture.Mimes -join ', '), (Mark (
    -not $picture.Empty -and $null -eq $picture.Text -and (@($picture.Mimes) -join ',') -eq 'image/png')))
$script:answers['service call clipboard 4*'] = { New-TestClipDump -Text $script:fakeClip }
$null = $script:answers.Remove('service call clipboard 5*')

# nothing on it at all, which is also what a refusal looks like
$script:answers['service call clipboard 4*'] = "Result: Parcel(`t00000000 00000000   '....')"
$nothing = Invoke-WithFakePhone { Get-PhoneClipParcel -Serial 'C' }
Say ("  an empty clipboard is empty, not an error   {0}" -f (Mark ($nothing.Empty -and $null -eq $nothing.Text)))
# back to the phone the sections below were written against
$script:answers = @{ 'cmd clipboard get-primary-clip' = 'on the phone' }

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
    $lblClipState.Text -match 'Test phone \(adb\)' -and -not $btnClipStart.Enabled -and $btnClipStop.Enabled)))
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
    Say ("  which is one of the four ways   {0}" -f (Mark (
        @('cmd', 'binder', 'scrcpy', 'none') -contains $route)))
    Say ("  and nothing was shared with it yet   {0}" -f (Mark (-not (Test-ClipboardSharing -Serial $TestSerial))))

    Say ''
    Say '== and now something really carried, on that phone =='
    if (-not (Test-ClipboardAdbRoute -Route $route)) {
        Say '  SKIPPED - this phone has no two-way route'
    } else {
        Say ("  whose clipboard it is: user {0}" -f (Get-ClipboardUser -Serial $TestSerial))
        $wasOnPhone = Get-PhoneClipboard -Serial $TestSerial
        $null = Start-ClipboardShare -Serial $TestSerial -Model 'the phone attached'
        $null = Invoke-ClipboardTick -Quiet          # the first turn only learns

        $mine = 'ADC-pc-' + (Get-Random -Maximum 99999)
        $null = Set-Clipboard -Value $mine
        $out = @(Invoke-ClipboardTick -Quiet)
        Say ("  what this PC copied is on the phone   {0}" -f (Mark (
            (Get-PhoneClipboard -Serial $TestSerial) -eq $mine -and
            @($out | Where-Object { $_.Way -eq 'PC -> phone' }).Count -eq 1)))

        # written straight onto the phone's clipboard, which is what copying
        # something there does
        $theirs = 'ADC-phone-' + (Get-Random -Maximum 99999)
        $null = Set-PhoneClipboard -Serial $TestSerial -Text $theirs
        $back = @(Invoke-ClipboardTick -Quiet)
        Say ("  what the phone copied is on this PC   {0}" -f (Mark (
            (Get-ClipboardHere) -eq $theirs -and
            @($back | Where-Object { $_.Way -eq 'phone -> PC' }).Count -eq 1)))
        Say ("  and neither is sent back again   {0}" -f (Mark (
            @(Invoke-ClipboardTick -Quiet).Count -eq 0)))

        $null = Stop-ClipboardShare -Serial $TestSerial
        if ($null -ne $wasOnPhone -and "$wasOnPhone") {
            $null = Set-PhoneClipboard -Serial $TestSerial -Text $wasOnPhone
            Say ("  the phone's own clipboard went back, {0} characters   {1}" -f $wasOnPhone.Length, (Mark (
                (Get-PhoneClipboard -Serial $TestSerial) -eq $wasOnPhone)))
        } else {
            Say '  the phone had no text of its own to put back, so it keeps the test line'
        }
    }
}

Reset-TestClipboard
