<#
    AndroidDC - the clipboard shared between this PC and the phones.

    What Android allows was measured rather than assumed, on a Xiaomi running
    Android 15:

      cmd clipboard                "No shell command implementation" - that
                                   command is not in AOSP at all, so hardly any
                                   phone will have it
      dumpsys clipboard            prints nothing
      scrcpy                       its server is meant to watch the phone's
                                   clipboard and push it here, but on this
                                   phone that listener never fired once, for
                                   either user; and it can only send the other
                                   way as part of a paste into a focused window
      service call clipboard       works, both ways, and is what this uses

    The first attempt at this was built on the wrong user. The phone runs in
    its second space - user 10 - and every question was being put to user 0.
    Owner's clipboard is empty, and because Owner is not the user in front it
    cannot be read either, which looks exactly like a phone that refuses.
    Asked about the user actually in front, the same phone hands its clipboard
    over and takes a new one without complaint.

    So each phone is asked which route it can take, and the window says which
    one it got:

      binder    both ways, by asking the phone every second or two
      cmd       the same, on a ROM that does have the shell command
      scrcpy    only what the phone copies, and only if its listener fires

    Nothing is claimed that was not seen: every line in the monitor is
    something that really moved, with the time, the phone and which way it
    went. The text stays in memory - the activity log is told the length only,
    because a log can be saved to a file and a clipboard can hold a password.

    Dot-sourced by both windows. Nothing here touches a control: each window
    calls Invoke-ClipboardTick from its own timer and reads the list.
#>

# scrcpy's clipboard sync goes through SDL, and SDL's clipboard needs the
# video subsystem: with --no-window there is no "Renderer:" line in its log and
# nothing to hand the text to, while --no-video --no-audio alone does make a
# window. So one is made, off screen and one pixel tall, and hidden at once.
if (-not ('AndroidDcClipboardNative' -as [type])) {
    Add-Type -Namespace '' -Name 'AndroidDcClipboardNative' -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
'@
}

# serial -> @{ Route; Model; Process; Out; Err; Offset; LastPhone }
$script:clipShares = @{}
# serial -> 'binder' | 'cmd' | 'scrcpy' | 'none', so a phone is asked once
$script:clipRoutes = @{}
# serial -> the user in front, because the clipboard belongs to that user
$script:clipUsers = @{}
# serial -> the shape of this phone's ClipData parcel, learnt from one it wrote
$script:clipShapes = @{}
$script:clipEvents = New-Object System.Collections.Generic.List[object]
# what this PC's clipboard held when it was last looked at
$script:clipHere = $null
$script:clipSeeded = $false
# the list is for watching, not for keeping: the oldest go when it is full
$script:clipMax = 200

function Get-ClipboardHere {
    # what is on this PC's clipboard now, or $null. Another program can hold
    # the clipboard open for a moment, and that is a wait, not an error.
    try {
        $text = Get-Clipboard -Format Text -Raw -ErrorAction Stop
        if ($null -eq $text) { return $null }
        return [string]$text
    } catch {
        return $null
    }
}

function Set-ClipboardHere {
    param([string]$Text)

    try {
        Set-Clipboard -Value $Text -ErrorAction Stop
        return $true
    } catch {
        Write-Log ('This PC would not take the clipboard: ' + $_.Exception.Message) $colorWarn
        return $false
    }
}

function Add-ClipboardEvent {
    <#
        One line for the monitor. The text is kept here and nowhere else: the
        activity log is told how long it was, not what it said.
    #>
    param([string]$Phone, [string]$Way, [string]$Text, [string]$How = '')

    $one = [PSCustomObject]@{
        When  = (Get-Date)
        Time  = (Get-Date).ToString('h:mm:ss tt', [System.Globalization.CultureInfo]::InvariantCulture)
        Phone = $Phone
        Way   = $Way
        How   = $How
        Chars = "$Text".Length
        Text  = "$Text"
        Line  = (("$Text" -replace '\s+', ' ').Trim())
    }
    $null = $script:clipEvents.Add($one)
    while ($script:clipEvents.Count -gt $script:clipMax) { $script:clipEvents.RemoveAt(0) }
    return $one
}

function Get-ClipboardEvents {
    # newest first, which is the way a monitor is read
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = $script:clipEvents.Count - 1; $i -ge 0; $i--) { $null = $rows.Add($script:clipEvents[$i]) }
    return $rows.ToArray()
}

function Clear-ClipboardEvents {
    $script:clipEvents.Clear()
}

# ---------------------------------------------------------------------------
#   The clipboard through the phone's own binder service.
#
#   The clipboard service takes and gives a ClipData, and the service tool can
#   only write a parcel as a run of 32-bit words - so the parcel is built here
#   word by word. Its shape was read off the phone rather than guessed:
#
#     non-null         1
#     description      label: 1 (a plain label), then the text of the label
#                      one mime type: "text/plain"
#                      no extras: -1
#                      when it was copied: a long
#                      three more ints, whose meaning does not matter here
#     clip             no picture: 0
#                      one item: its text, no html version of it, and the
#                      slots for an intent, a link and the rest, all empty
#
#   The label and the item text are utf-8 - TextUtils writes a string8 - while
#   the mime type inside the array is utf-16. That differs between Android
#   versions, and so does the number of trailing ints, so a parcel read from
#   the phone teaches this the shape to write back, and a write is never
#   believed until it has been read again.
# ---------------------------------------------------------------------------

function Get-ClipboardUser {
    <#
        The user in front. The clipboard belongs to it: on a phone in its
        second space, Owner's clipboard is empty and cannot be read either,
        and asking about Owner is how this went wrong the first time.
    #>
    param([string]$Serial, [switch]$Again)

    if (-not $Again -and $script:clipUsers.ContainsKey($Serial)) { return $script:clipUsers[$Serial] }
    $said = "$((Invoke-DeviceShell -Serial $Serial -CommandArguments @('am', 'get-current-user')).Text)".Trim()
    $user = 0
    if ($said -match '(\d+)') { $user = [int]$Matches[1] }
    $script:clipUsers[$Serial] = $user
    return $user
}

function Convert-ClipboardDump {
    # the service tool prints a parcel as an address, four words and a column
    # of its printable bytes; only the words are wanted
    param([string]$Text)

    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($line in ("$Text" -split "`r?`n")) {
        $body = $line -replace '^\s*0x[0-9a-f]{8}:', ''
        $body = $body -replace "'.*$", ''
        $body = $body -replace '^.*Parcel\(', ''
        $body = $body -replace '\)\s*$', ''
        foreach ($found in [regex]::Matches($body, '\b([0-9a-f]{8})\b')) {
            $word = [Convert]::ToUInt32($found.Groups[1].Value, 16)
            $null = $bytes.Add([byte]($word -band 0xFF))
            $null = $bytes.Add([byte](($word -shr 8) -band 0xFF))
            $null = $bytes.Add([byte](($word -shr 16) -band 0xFF))
            $null = $bytes.Add([byte](($word -shr 24) -band 0xFF))
        }
    }
    # the comma matters: an empty array unrolls to nothing on the way out of a
    # function, and then the caller asks a $null for its Length
    return ,$bytes.ToArray()
}

function Read-ClipboardParcelText {
    <#
        One string out of a parcel: its length, its bytes, a closing zero and
        padding up to the next word. A width of 8 is utf-8, 16 is utf-16. Ok
        is false when the length could not be a length, which is how a wrong
        shape is caught.
    #>
    param([byte[]]$Bytes, [ref]$At, [int]$Width = 8)

    # not $at for the walk: a parameter's name is the same name whatever its
    # case, so $at would be $At itself - the reference, not the number in it
    $spot = [int]$At.Value
    if ($spot -lt 0 -or $spot + 4 -gt $Bytes.Length) { return [PSCustomObject]@{ Ok = $false; Text = $null } }
    $count = [BitConverter]::ToInt32($Bytes, $spot)
    $spot += 4
    if ($count -eq -1) { $At.Value = $spot; return [PSCustomObject]@{ Ok = $true; Text = $null } }
    if ($count -lt 0 -or $count -gt 8000000) { return [PSCustomObject]@{ Ok = $false; Text = $null } }
    $size = $(if ($Width -eq 16) { ($count + 1) * 2 } else { $count + 1 })
    if ($spot + $size -gt $Bytes.Length) { return [PSCustomObject]@{ Ok = $false; Text = $null } }
    $text = $(if ($Width -eq 16) {
        [System.Text.Encoding]::Unicode.GetString($Bytes, $spot, $count * 2)
    } else {
        [System.Text.Encoding]::UTF8.GetString($Bytes, $spot, $count)
    })
    $spot += $size
    while ($spot % 4 -ne 0) { $spot++ }
    $At.Value = $spot
    return [PSCustomObject]@{ Ok = $true; Text = $text }
}

function Read-ClipboardDescription {
    <#
        A ClipDescription parcel - what getPrimaryClipDescription answers.
        There are no items in it, so it is the cheap way to learn both the
        width of a string and how many trailing ints this Android adds.
        $null when the shape does not fit, which is how the right one is
        found: it is the shape that ends exactly where the parcel ends.
    #>
    param([byte[]]$Bytes, [int]$Width = 8, [int]$Tail = 3, [switch]$Loose)

    if ($null -eq $Bytes -or $Bytes.Length -lt 12) { return $null }
    if ([BitConverter]::ToInt32($Bytes, 0) -ne 0) { return $null }
    if ([BitConverter]::ToInt32($Bytes, 4) -ne 1) { return $null }
    $at = 8
    if ([BitConverter]::ToInt32($Bytes, $at) -ne 1) { return $null }
    $at += 4
    $label = Read-ClipboardParcelText -Bytes $Bytes -At ([ref]$at) -Width $Width
    if (-not $label.Ok) { return $null }
    if ($at + 4 -gt $Bytes.Length) { return $null }
    $many = [BitConverter]::ToInt32($Bytes, $at)
    $at += 4
    if ($many -lt 0 -or $many -gt 32) { return $null }
    $mimes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $many; $i++) {
        $one = Read-ClipboardParcelText -Bytes $Bytes -At ([ref]$at) -Width 16
        if (-not $one.Ok) { return $null }
        $null = $mimes.Add("$($one.Text)")
    }
    if ($at + 4 -gt $Bytes.Length) { return $null }
    $extras = [BitConverter]::ToInt32($Bytes, $at)
    $at += 4
    if ($extras -lt -1) { return $null }
    if ($extras -gt 0) {
        # a bundle: its length, then the word that marks it, then its contents
        $at += 4 + $extras
        while ($at % 4 -ne 0) { $at++ }
    }
    $at += 8
    $at += 4 * $Tail
    if ($at -gt $Bytes.Length) { return $null }
    if (-not $Loose -and $at -ne $Bytes.Length) { return $null }
    return [PSCustomObject]@{
        Label = $label.Text; Mimes = $mimes.ToArray(); Width = $Width; Tail = $Tail; At = $at
    }
}

function Read-ClipboardParcel {
    <#
        A whole ClipData parcel, as far as the first item that has text in it.
        $null when the shape does not fit.
    #>
    param([byte[]]$Bytes, [int]$Width = 8, [int]$Tail = 3, [int]$ItemTail = 5)

    $head = Read-ClipboardDescription -Bytes $Bytes -Width $Width -Tail $Tail -Loose
    if ($null -eq $head) { return $null }
    $at = $head.At
    if ($at + 8 -gt $Bytes.Length) { return $null }
    if ([BitConverter]::ToInt32($Bytes, $at) -ne 0) { return $null }    # a picture of its own
    $at += 4
    $many = [BitConverter]::ToInt32($Bytes, $at)
    $at += 4
    if ($many -lt 0 -or $many -gt 64) { return $null }
    $text = $null
    for ($i = 0; $i -lt $many; $i++) {
        if ($at + 4 -gt $Bytes.Length) { return $null }
        if ([BitConverter]::ToInt32($Bytes, $at) -ne 1) { return $null }
        $at += 4
        $item = Read-ClipboardParcelText -Bytes $Bytes -At ([ref]$at) -Width $Width
        if (-not $item.Ok) { return $null }
        if ($null -eq $text -and $null -ne $item.Text) { $text = $item.Text }
        $html = Read-ClipboardParcelText -Bytes $Bytes -At ([ref]$at) -Width $Width
        if (-not $html.Ok) { return $null }
        for ($slot = 0; $slot -lt $ItemTail; $slot++) {
            if ($at + 4 -gt $Bytes.Length) { return $null }
            # a slot that is not empty holds an intent or a link, and what
            # follows it is not read here: the shape is reported as not fitting
            if ([BitConverter]::ToInt32($Bytes, $at) -ne 0) { return $null }
            $at += 4
        }
    }
    if ($at -ne $Bytes.Length) { return $null }
    return [PSCustomObject]@{
        Text = $text; Label = $head.Label; Mimes = $head.Mimes
        Width = $Width; Tail = $Tail; ItemTail = $ItemTail
    }
}

function Get-ClipboardShape {
    # the shape last known to fit this phone's parcels, or what Android 15 uses
    param([string]$Serial)

    if ($script:clipShapes.ContainsKey($Serial)) { return $script:clipShapes[$Serial] }
    return [PSCustomObject]@{ Width = 8; Tail = 3; ItemTail = 5 }
}

function Get-ClipboardShapeTries {
    # the remembered shape first, then every shape worth trying
    param([string]$Serial)

    $tries = New-Object System.Collections.Generic.List[object]
    $null = $tries.Add((Get-ClipboardShape -Serial $Serial))
    foreach ($width in @(8, 16)) {
        foreach ($tail in @(3, 2, 1, 0, 4)) {
            foreach ($itemTail in @(5, 3, 4, 2, 6, 1, 0)) {
                $null = $tries.Add([PSCustomObject]@{ Width = $width; Tail = $tail; ItemTail = $itemTail })
            }
        }
    }
    return $tries.ToArray()
}

function Invoke-ClipboardLongShell {
    <#
        One shell line too long to be a command line. Windows stops at 32767
        characters all told, and a clipboard of a few thousand characters
        becomes a parcel of a few thousand words - "The filename or extension
        is too long", which is Windows talking about the whole line.

        adb's own shell reads from its input instead, where there is no such
        limit: eighty thousand characters went through in testing. This is the
        only place that runs adb itself rather than going through the window's
        own helper, and it is here because there is nowhere else to put it.
    #>
    param([string]$Serial, [string]$Line)

    $answer = [PSCustomObject]@{ Text = ''; ExitCode = -1 }
    if (-not $script:adbPath -or -not (Test-Path -LiteralPath $script:adbPath)) { return $answer }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial shell"
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.WriteLine($Line)
        $process.StandardInput.WriteLine('exit')
        $process.StandardInput.Close()
        $said = $process.StandardOutput.ReadToEnd()
        $also = $process.StandardError.ReadToEnd()
        $null = $process.WaitForExit(30000)
        $answer.Text = "$said$also"
        $answer.ExitCode = $process.ExitCode
    } catch {
        $answer.Text = $_.Exception.Message
    }
    return $answer
}

function Invoke-ClipboardService {
    # one call on the phone's clipboard service, with its answer as bytes
    param([string]$Serial, [int]$Code, [string[]]$Words = @())

    $user = Get-ClipboardUser -Serial $Serial
    $line = @('service', 'call', 'clipboard', "$Code")
    foreach ($word in $Words) { $line += @('i32', $word) }
    $line += @('s16', 'com.android.shell', 's16', 'null', 'i32', "$user", 'i32', '0')
    $flat = $line -join ' '
    $said = $(if ($flat.Length -gt 8000) {
        (Invoke-ClipboardLongShell -Serial $Serial -Line $flat).Text
    } else {
        (Invoke-DeviceShell -Serial $Serial -CommandArguments $line).Text
    })
    return [PSCustomObject]@{ Text = "$said"; Bytes = (Convert-ClipboardDump -Text "$said") }
}

function Get-PhoneClipParcel {
    <#
        What the phone holds, with the shape worked out as it goes: the shape
        that fits is remembered, and the next read starts with it.

        Empty is true when there is nothing on the clipboard - or when this
        user is not allowed to see it, because the phone answers both the same
        way. Text is $null with a mime type in Mimes when there is something
        there that is not plain text.
    #>
    param([string]$Serial)

    $reply = Invoke-ClipboardService -Serial $Serial -Code 4
    $bytes = $reply.Bytes
    if ($null -eq $bytes -or $bytes.Length -lt 8) { return $null }
    if ([BitConverter]::ToInt32($bytes, 0) -ne 0) { return $null }      # the call threw
    if ($bytes.Length -lt 12 -or [BitConverter]::ToInt32($bytes, 4) -ne 1) {
        return [PSCustomObject]@{ Empty = $true; Text = $null; Mimes = @() }
    }
    foreach ($shape in @(Get-ClipboardShapeTries -Serial $Serial)) {
        $read = Read-ClipboardParcel -Bytes $bytes -Width $shape.Width -Tail $shape.Tail -ItemTail $shape.ItemTail
        if ($null -ne $read) {
            $script:clipShapes[$Serial] = [PSCustomObject]@{
                Width = $read.Width; Tail = $read.Tail; ItemTail = $read.ItemTail
            }
            return [PSCustomObject]@{ Empty = $false; Text = $read.Text; Mimes = $read.Mimes }
        }
    }
    # there is a clip and it is not made of plain text: say which kind it is,
    # from the description, which has no items in it to trip over
    $kinds = @()
    $head = Invoke-ClipboardService -Serial $Serial -Code 5
    foreach ($width in @(8, 16)) {
        foreach ($tail in @(3, 2, 1, 0, 4)) {
            $read = Read-ClipboardDescription -Bytes $head.Bytes -Width $width -Tail $tail
            if ($null -ne $read) { $kinds = $read.Mimes; break }
        }
        if ($kinds.Count -gt 0) { break }
    }
    return [PSCustomObject]@{ Empty = $false; Text = $null; Mimes = $kinds }
}

function Get-ClipboardStringWords {
    # one string as the words a parcel holds it in
    param([string]$Text, [int]$Width = 8)

    # the cast is not for show: a byte[] out of an if-expression comes back
    # as an object[], which AddRange will not take
    [byte[]]$raw = $(if ($Width -eq 16) {
        [System.Text.Encoding]::Unicode.GetBytes($Text)
    } else {
        [System.Text.Encoding]::UTF8.GetBytes($Text)
    })
    $count = $(if ($Width -eq 16) { $Text.Length } else { $raw.Length })
    $all = New-Object System.Collections.Generic.List[byte]
    $all.AddRange($raw)
    $null = $all.Add(0)
    if ($Width -eq 16) { $null = $all.Add(0) }
    while ($all.Count % 4 -ne 0) { $null = $all.Add(0) }
    $bytes = $all.ToArray()
    $words = New-Object System.Collections.Generic.List[string]
    $null = $words.Add([string]$count)
    for ($i = 0; $i -lt $bytes.Length; $i += 4) {
        $null = $words.Add([string][BitConverter]::ToInt32($bytes, $i))
    }
    return $words.ToArray()
}

function New-ClipboardParcelWords {
    # a plain-text ClipData, in the shape this phone reads
    param([string]$Text, [int]$Width = 8, [int]$Tail = 3, [int]$ItemTail = 5)

    $words = New-Object System.Collections.Generic.List[string]
    $null = $words.Add('1')                      # there is a clip
    $null = $words.Add('1')                      # a plain label, not a styled one
    foreach ($word in @(Get-ClipboardStringWords -Text 'text' -Width $Width)) { $null = $words.Add($word) }
    $null = $words.Add('1')                      # one kind of content
    foreach ($word in @(Get-ClipboardStringWords -Text 'text/plain' -Width 16)) { $null = $words.Add($word) }
    $null = $words.Add('-1')                     # nothing extra
    $null = $words.Add('0')                      # when it was copied: left at
    $null = $words.Add('0')                      #   nothing, so the phone dates it
    for ($i = 0; $i -lt $Tail; $i++) { $null = $words.Add('0') }
    $null = $words.Add('0')                      # no picture
    $null = $words.Add('1')                      # one item
    $null = $words.Add('1')                      # plain text
    foreach ($word in @(Get-ClipboardStringWords -Text $Text -Width $Width)) { $null = $words.Add($word) }
    $null = $words.Add('-1')                     # no html version of it
    for ($i = 0; $i -lt $ItemTail; $i++) { $null = $words.Add('0') }
    return $words.ToArray()
}

function Set-PhoneClipParcel {
    <#
        This PC's text onto the phone's clipboard, and then read back, because
        the service takes a parcel it cannot use without complaining. The
        shape that works is remembered; only the first send to a phone whose
        shape is not known yet costs more than one try.
    #>
    param([string]$Serial, [string]$Text)

    # the parcel is four words for every three characters of Arabic, and each
    # word is up to twelve characters of command; past this the phone's own
    # shell starts refusing the line, so it is said rather than half done
    $size = [System.Text.Encoding]::UTF8.GetByteCount($Text)
    if ($size -gt 65536) {
        return [PSCustomObject]@{ Ok = $false; How = 'binder'
            Text = "that is $size bytes of text - too much to push through a shell command" }
    }
    $said = ''
    $tried = 0
    $known = $script:clipShapes.ContainsKey($Serial)
    foreach ($shape in @(Get-ClipboardShapeTries -Serial $Serial)) {
        $tried++
        # a phone whose shape is already known is not worth hunting through:
        # something else is wrong, and the hunt would cost a call each time
        if ($known -and $tried -gt 2) { break }
        if ($tried -gt 36) { break }
        $words = New-ClipboardParcelWords -Text $Text -Width $shape.Width -Tail $shape.Tail -ItemTail $shape.ItemTail
        $reply = Invoke-ClipboardService -Serial $Serial -Code 1 -Words $words
        $first = ("$($reply.Text)" -split "`r?`n")[0].Trim()
        if ($first) { $said = $first }
        if ($reply.Bytes.Length -ge 4 -and [BitConverter]::ToInt32($reply.Bytes, 0) -ne 0) { continue }
        # it took the parcel without throwing; whether it kept it is another
        # question, and the only honest way to answer that one is to ask
        $back = Get-PhoneClipParcel -Serial $Serial
        if ($null -ne $back -and "$($back.Text)" -eq "$Text") {
            $script:clipShapes[$Serial] = [PSCustomObject]@{
                Width = $shape.Width; Tail = $shape.Tail; ItemTail = $shape.ItemTail
            }
            return [PSCustomObject]@{ Ok = $true; How = 'binder'; Text = '' }
        }
    }
    return [PSCustomObject]@{ Ok = $false; How = 'binder'
        Text = $(if ($said) { "the phone would not keep it - $said" } else { 'the phone would not keep it' }) }
}

function Test-ClipboardBinderRoute {
    <#
        Whether the phone answers its clipboard service at all. A phone with
        an empty clipboard and a phone that refuses answer the same way, so
        this only rules out the service being missing or throwing: what the
        route can really do is proved by the first thing that crosses.
    #>
    param([string]$Serial)

    $found = "$((Invoke-DeviceShell -Serial $Serial -CommandArguments @('service', 'check', 'clipboard')).Text)"
    if ($found -notmatch 'found') { return $false }
    $reply = Invoke-ClipboardService -Serial $Serial -Code 4
    if ($reply.Bytes.Length -lt 4) { return $false }
    return ([BitConverter]::ToInt32($reply.Bytes, 0) -eq 0)
}

function Test-ClipboardAdbRoute {
    # the routes that can both ask the phone and tell it, over adb alone
    param([string]$Route)

    return ($Route -eq 'cmd' -or $Route -eq 'binder')
}

function Test-ClipboardShellRoute {
    <#
        Whether this phone's own shell can read and write the clipboard. AOSP
        has "cmd clipboard"; the phone this was written against answers "No
        shell command implementation", and then scrcpy is the way.
    #>
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('cmd', 'clipboard', 'get-primary-clip')).Text
    if ("$text" -match 'No shell command implementation|Unknown command|not found|Exception|Permission Denial') { return $false }
    return $true
}

function Get-ClipboardRoute {
    # which way this phone can share, asked once and remembered
    param([string]$Serial, [switch]$Again)

    if (-not $Again -and $script:clipRoutes.ContainsKey($Serial)) { return $script:clipRoutes[$Serial] }
    $route = 'none'
    $null = Get-ClipboardUser -Serial $Serial -Again
    if (Test-ClipboardShellRoute -Serial $Serial) {
        $route = 'cmd'
    } elseif (Test-ClipboardBinderRoute -Serial $Serial) {
        $route = 'binder'
    } elseif ($script:scrcpyPath -and (Test-Path -LiteralPath $script:scrcpyPath)) {
        $route = 'scrcpy'
    }
    $script:clipRoutes[$Serial] = $route
    return $route
}

function Get-ClipboardRouteWords {
    param([string]$Route)

    switch ($Route) {
        'cmd'    { return 'both ways over adb (this phone has cmd clipboard)' }
        'binder' { return "both ways over adb, through the phone's own clipboard service" }
        'scrcpy' { return 'only what the phone copies, and only if its scrcpy listener fires' }
        default  { return 'no way in: this phone will not let adb near its clipboard' }
    }
}

function Get-ClipboardRouteShort {
    # for the line that says who is being shared with: the long words are for
    # the page itself, and "binder" is not a word anybody wants there
    param([string]$Route)

    switch ($Route) {
        'cmd'    { return 'adb' }
        'binder' { return 'adb' }
        'scrcpy' { return 'scrcpy' }
        default  { return 'no way in' }
    }
}

function Get-PhoneClipboard {
    # what the phone has, where the phone lets its shell say
    param([string]$Serial)

    $route = Get-ClipboardRoute -Serial $Serial
    if ($route -eq 'binder') {
        $held = Get-PhoneClipParcel -Serial $Serial
        if ($null -eq $held) { return $null }
        return $held.Text
    }
    if ($route -ne 'cmd') { return $null }
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('cmd', 'clipboard', 'get-primary-clip')
    $text = "$($result.Text)"
    if ($text -match 'No shell command implementation|Exception|Permission Denial') { return $null }
    # the command prints the clip and nothing else; a trailing newline is the
    # shell's, not the clipboard's
    return ($text -replace '\r?\n$', '')
}

function Set-PhoneClipboard {
    <#
        This PC's clipboard onto the phone. Where the phone's shell can set it,
        that is a clipboard; where it cannot, the text is typed into whatever
        has the cursor, which is not the same thing and is said to be what it
        is.
    #>
    param([string]$Serial, [string]$Text, [switch]$TypeWhenShut)

    if (-not "$Text") { return [PSCustomObject]@{ Ok = $false; How = ''; Text = 'there is nothing on this PC to send' } }
    $route = Get-ClipboardRoute -Serial $Serial
    if ($route -eq 'binder') {
        $sent = Set-PhoneClipParcel -Serial $Serial -Text $Text
        if ($sent.Ok -or -not $TypeWhenShut) { return $sent }
        # the service would not keep it, so typing is all that is left - and
        # that is not the same thing, which is what 'typed' says
        $result = Invoke-DeviceCommand -Serial $Serial -Arguments @('input', 'text', $Text)
        $said = "$($result.Text)".Trim()
        if ($said -match 'Exception|Error|Killed') {
            return [PSCustomObject]@{ Ok = $false; How = 'typed'; Text = $said }
        }
        return [PSCustomObject]@{ Ok = $true; How = 'typed'; Text = $said }
    }
    if ($route -eq 'cmd') {
        $result = Invoke-DeviceCommand -Serial $Serial -Arguments @('cmd', 'clipboard', 'set-primary-clip', '--text', $Text)
        $said = "$($result.Text)".Trim()
        if ($said -match 'Exception|Permission Denial|Error') {
            return [PSCustomObject]@{ Ok = $false; How = 'cmd'; Text = $said }
        }
        return [PSCustomObject]@{ Ok = $true; How = 'cmd'; Text = $said }
    }

    if (-not $TypeWhenShut) {
        return [PSCustomObject]@{ Ok = $false; How = ''
            Text = 'this phone does not let adb set the clipboard; it can be typed instead' }
    }
    $result = Invoke-DeviceCommand -Serial $Serial -Arguments @('input', 'text', $Text)
    $said = "$($result.Text)".Trim()
    if ($said -match 'Exception|Error|Killed') {
        return [PSCustomObject]@{ Ok = $false; How = 'typed'; Text = $said }
    }
    return [PSCustomObject]@{ Ok = $true; How = 'typed'; Text = $said }
}

function Hide-ClipboardWindow {
    # scrcpy's window, out of sight as soon as SDL has made it. Waiting for it
    # is a few hundred milliseconds; the window pumps while it waits, so the
    # program does not go grey over it.
    param($Process, [int]$WaitMs = 4000)

    $waited = 0
    while ($waited -lt $WaitMs) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { return $false }
            $handle = $Process.MainWindowHandle
            if ($handle -and $handle -ne [IntPtr]::Zero) {
                $null = [AndroidDcClipboardNative]::ShowWindow($handle, 0)
                return (-not [AndroidDcClipboardNative]::IsWindowVisible($handle))
            }
        } catch { return $false }
        Start-Sleep -Milliseconds 150
        $waited += 150
        if (Get-Command Invoke-BackupPump -ErrorAction SilentlyContinue) { Invoke-BackupPump }
    }
    return $false
}

function Start-ClipboardShare {
    <#
        Share with one phone. On the scrcpy route that means a control-only
        session - no window, no video, no audio - whose server pushes the
        phone's clipboard here whenever it changes. On the cmd route there is
        nothing to start: the phone is asked on the tick.
    #>
    param([string]$Serial, [string]$Model = '')

    if ($script:clipShares.ContainsKey($Serial)) { return $script:clipShares[$Serial] }
    # a fresh run of sharing: what either side was holding beforehand is not
    # news, and the seeding below is what makes that true of the phone too
    if ($script:clipShares.Count -eq 0) { $script:clipSeeded = $false }
    $route = Get-ClipboardRoute -Serial $Serial -Again
    $share = [PSCustomObject]@{
        Serial    = $Serial
        Model     = $Model
        Route     = $route
        Process   = $null
        Out       = ''
        Err       = ''
        Offset    = [long]0
        LastPhone = $null
        Said      = ''
        Since     = (Get-Date)
    }

    if ($route -eq 'none') {
        Write-Log "Clipboard: $Serial has no way to share - no cmd clipboard on the phone, and no scrcpy here." $colorWarn
        return $null
    }
    if ($route -eq 'scrcpy') {
        $stem = Join-Path $env:TEMP ("androiddc-$PID.clipboard-" + ($Serial -replace '[^A-Za-z0-9]', '_'))
        $share.Out = "$stem.out"
        $share.Err = "$stem.err"
        foreach ($file in @($share.Out, $share.Err)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
        # no video and no audio - a control connection and nothing else - but a
        # window all the same, because that is what gives SDL a clipboard. It
        # is made 200x1 off the left of every screen and hidden as soon as it
        # exists, so nothing of it is ever seen.
        $arguments = @('-s', $Serial, '--no-video', '--no-audio',
            "--window-title=AndroidDC-clipboard-$Serial", '--window-width=200', '--window-height=1',
            '--window-x=-3000', '--window-y=-3000')
        try {
            $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -PassThru `
                -NoNewWindow -RedirectStandardOutput $share.Out -RedirectStandardError $share.Err
            $null = $process.Handle
            $share.Process = $process
        } catch {
            Write-Log ("Clipboard: scrcpy would not start - " + $_.Exception.Message) $colorBad
            return $null
        }
        if (-not (Hide-ClipboardWindow -Process $process)) {
            # it may simply be slow; the sharing still works, and a window
            # nobody asked for is worth saying out loud
            Write-Log 'Clipboard: the connection window could not be hidden; it sits off screen.' $colorWarn
        }
    }

    $script:clipShares[$Serial] = $share
    if (Test-ClipboardAdbRoute -Route $route) {
        # what the phone is already holding, so that turning sharing on does
        # not reach over and take this PC's clipboard away for it
        $share.LastPhone = Get-PhoneClipboard -Serial $Serial
    }
    $who = $(if ("$Model") { "$Model ($Serial)" } else { $Serial })
    Write-Log "Clipboard: sharing with $who - $(Get-ClipboardRouteWords -Route $route)" $colorGood
    return $share
}

function Stop-ClipboardShare {
    param([string]$Serial)

    if (-not $script:clipShares.ContainsKey($Serial)) { return $false }
    $share = $script:clipShares[$Serial]
    if ($share.Process) {
        try {
            $share.Process.Refresh()
            if (-not $share.Process.HasExited) {
                # scrcpy with no window has no window to close: ending the
                # process is how it is stopped, and it leaves nothing behind
                $share.Process.Kill()
                $null = $share.Process.WaitForExit(2000)
            }
        } catch { }
    }
    $null = $script:clipShares.Remove($Serial)
    Write-Log "Clipboard: stopped sharing with $Serial." $colorInfo
    return $true
}

function Stop-AllClipboardShares {
    foreach ($serial in @($script:clipShares.Keys)) { $null = Stop-ClipboardShare -Serial $serial }
}

function Get-ClipboardShares {
    return @($script:clipShares.Values)
}

function Test-ClipboardSharing {
    param([string]$Serial)

    if ("$Serial") { return $script:clipShares.ContainsKey($Serial) }
    return ($script:clipShares.Count -gt 0)
}

function Read-ClipboardShareLines {
    # whatever scrcpy has said since the last look, without holding its file
    param($Share)

    if (-not $Share -or -not "$($Share.Err)") { return @() }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($Share.Err, $Share.Out)) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            try {
                if ($file -eq $Share.Err) {
                    if ($stream.Length -lt $Share.Offset) { $Share.Offset = [long]0 }
                    $null = $stream.Seek($Share.Offset, [System.IO.SeekOrigin]::Begin)
                    $reader = New-Object System.IO.StreamReader($stream)
                    $text = $reader.ReadToEnd()
                    $Share.Offset = $stream.Length
                    foreach ($line in ("$text" -split "`r?`n")) { if ("$line".Trim()) { $null = $lines.Add($line.Trim()) } }
                }
            } finally { $stream.Dispose() }
        } catch { }
    }
    return $lines.ToArray()
}

function Test-ClipboardShareAlive {
    # scrcpy quitting on its own - an unplugged phone, a refused connection -
    # is noticed and said once, rather than looking like a quiet clipboard
    param($Share)

    if (-not $Share.Process) { return $true }
    try {
        $Share.Process.Refresh()
        return (-not $Share.Process.HasExited)
    } catch { return $false }
}

function Invoke-ClipboardTick {
    <#
        One turn of the watch, called from each window's own timer:

          * what scrcpy has said since the last turn - "Device clipboard
            copied" means the phone's clipboard has just landed on this PC;
          * on the cmd route, what the phone holds now;
          * what this PC holds now, and whether it should go to the phones.

        Returns the events it added, so the window can fill its list without
        reading the whole history again.
    #>
    param([switch]$Quiet)

    $added = New-Object System.Collections.Generic.List[object]
    if ($script:clipShares.Count -eq 0) { return $added.ToArray() }

    $here = Get-ClipboardHere
    # the first turn only learns what is already there: what was copied before
    # sharing was turned on is not news, and must not be pushed to a phone
    if (-not $script:clipSeeded) {
        $script:clipHere = $here
        $script:clipSeeded = $true
    }

    foreach ($serial in @($script:clipShares.Keys)) {
        $share = $script:clipShares[$serial]
        if (-not (Test-ClipboardShareAlive -Share $share)) {
            Write-Log "Clipboard: the connection to $serial ended, so sharing with it has stopped." $colorWarn
            $null = Stop-ClipboardShare -Serial $serial
            continue
        }

        if ($share.Route -eq 'scrcpy') {
            foreach ($line in @(Read-ClipboardShareLines -Share $share)) {
                # a phone that refuses to hand its clipboard over says so in
                # scrcpy's own words; without this the page would simply sit
                # there looking as though nothing had been copied
                if ($line -match 'ERROR|Exception|refused|denied') {
                    if ("$line" -ne "$($share.Said)") {
                        $share.Said = "$line"
                        Write-Log ("Clipboard: $serial - " + $line) $colorWarn
                    }
                    continue
                }
                if ($line -notmatch 'clipboard') { continue }
                if ($line -match 'Device clipboard copied') {
                    $now = Get-ClipboardHere
                    if ("$now" -and "$now" -ne "$here") {
                        $null = $added.Add((Add-ClipboardEvent -Phone $serial -Way 'phone -> PC' -Text $now -How 'scrcpy'))
                        $here = $now
                        $script:clipHere = $now
                    } else {
                        # scrcpy saw it, this PC's clipboard did not change:
                        # say so rather than showing a line that is not true
                        Write-Log "Clipboard: $serial copied something, but it did not reach this PC's clipboard." $colorWarn
                    }
                } elseif ($line -match 'Computer clipboard unchanged') {
                    # scrcpy's own words for "it was already here"
                    continue
                }
            }
        } elseif (Test-ClipboardAdbRoute -Route $share.Route) {
            $phoneText = $null
            $kinds = @()
            if ($share.Route -eq 'binder') {
                $held = Get-PhoneClipParcel -Serial $serial
                if ($null -ne $held) { $phoneText = $held.Text; $kinds = @($held.Mimes) }
            } else {
                $phoneText = Get-PhoneClipboard -Serial $serial
            }
            if ($null -eq $phoneText -and $kinds.Count -gt 0) {
                # something was copied on the phone that is not text: a
                # picture, or a file handed over as a link that means nothing
                # outside the phone. Said once, rather than looking idle.
                $what = ($kinds -join ', ')
                if ("$what" -ne "$($share.Said)") {
                    $share.Said = "$what"
                    Write-Log ("Clipboard: $serial copied $what, which only text can carry - " +
                        'use the file pages for a file or a picture.') $colorWarn
                }
            }
            if ($null -ne $phoneText -and "$phoneText" -ne "$($share.LastPhone)") {
                $share.LastPhone = $phoneText
                if ("$phoneText" -and "$phoneText" -ne "$here") {
                    if (Set-ClipboardHere -Text $phoneText) {
                        $null = $added.Add((Add-ClipboardEvent -Phone $serial -Way 'phone -> PC' -Text $phoneText -How 'cmd'))
                        $here = $phoneText
                        $script:clipHere = $phoneText
                    }
                }
            }
        }
    }

    # this PC copied something new: it goes to every phone being shared with
    if ("$here" -and "$here" -ne "$($script:clipHere)") {
        $script:clipHere = $here
        foreach ($serial in @($script:clipShares.Keys)) {
            $share = $script:clipShares[$serial]
            if (-not (Test-ClipboardAdbRoute -Route $share.Route)) { continue }
            $sent = Set-PhoneClipboard -Serial $serial -Text $here
            if ($sent.Ok) {
                $share.LastPhone = $here
                $null = $added.Add((Add-ClipboardEvent -Phone $serial -Way 'PC -> phone' -Text $here -How $sent.How))
            } elseif (-not $Quiet) {
                Write-Log ("Clipboard: $serial would not take it - " + $sent.Text) $colorWarn
            }
        }
    }

    foreach ($one in $added) {
        if ($Quiet) { break }
        Write-Log ("Clipboard: $($one.Way) ($($one.Phone)), $($one.Chars) character(s)") $colorInfo
    }
    return $added.ToArray()
}

function Send-ClipboardToPhone {
    # the button: what is on this PC now, onto the phone, saying how it got there
    param([string]$Serial, [switch]$TypeWhenShut)

    $here = Get-ClipboardHere
    if (-not "$here") { Write-Log 'There is nothing on this PC to send.' $colorWarn; return $null }
    $sent = Set-PhoneClipboard -Serial $Serial -Text $here -TypeWhenShut:$TypeWhenShut
    if (-not $sent.Ok) {
        Write-Log ("Clipboard: $Serial would not take it - " + $sent.Text) $colorWarn
        return $null
    }
    if ($script:clipShares.ContainsKey($Serial)) { $script:clipShares[$Serial].LastPhone = $here }
    $script:clipHere = $here
    $one = Add-ClipboardEvent -Phone $Serial -Way 'PC -> phone' -Text $here -How $sent.How
    if ($sent.How -eq 'typed') {
        Write-Log "Clipboard: typed $($one.Chars) character(s) on $Serial - it went where the cursor was, not onto its clipboard." $colorGood
    } else {
        Write-Log "Clipboard: sent $($one.Chars) character(s) to $Serial." $colorGood
    }
    return $one
}

function Receive-ClipboardFromPhone {
    # the other button: what the phone has now, onto this PC
    param([string]$Serial)

    $route = Get-ClipboardRoute -Serial $Serial
    if (-not (Test-ClipboardAdbRoute -Route $route)) {
        Write-Log "Clipboard: this phone does not let adb read its clipboard, so it cannot be fetched on demand." $colorWarn
        Write-Log '  With sharing on, whatever is copied on the phone arrives here by itself.' $colorInfo
        return $null
    }
    $text = Get-PhoneClipboard -Serial $Serial
    if (-not "$text") { Write-Log "Clipboard: $Serial has nothing on its clipboard." $colorWarn; return $null }
    if (-not (Set-ClipboardHere -Text $text)) { return $null }
    $script:clipHere = $text
    if ($script:clipShares.ContainsKey($Serial)) { $script:clipShares[$Serial].LastPhone = $text }
    $one = Add-ClipboardEvent -Phone $Serial -Way 'phone -> PC' -Text $text -How 'cmd'
    Write-Log "Clipboard: took $($one.Chars) character(s) from $Serial." $colorGood
    return $one
}
