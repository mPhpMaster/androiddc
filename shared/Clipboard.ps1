<#
    AndroidDC - the clipboard shared between this PC and the phones.

    What Android allows was measured rather than assumed, on a Xiaomi running
    Android 15:

      cmd clipboard                "No shell command implementation" - so this
                                   phone has no adb route at all, while a ROM
                                   that does implement it (it is in AOSP) gives
                                   both directions over adb alone
      service call clipboard       answers null whether the clipboard is empty
                                   or the caller is refused; nothing to build on
      dumpsys clipboard            prints nothing
      scrcpy                       its server pushes the phone's clipboard to
                                   this PC whenever it changes, with no window
                                   and no video

    So each phone is asked which of the two routes it can take, and the window
    says which one it got:

      cmd       both ways over adb, by asking the phone every second or two
      scrcpy    the phone's side arrives by itself; this PC's side is sent by
                typing it, or by the paste shortcut in a mirroring window

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
# serial -> 'cmd' | 'scrcpy' | 'none', so a phone is asked once
$script:clipRoutes = @{}
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
    if (Test-ClipboardShellRoute -Serial $Serial) {
        $route = 'cmd'
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
        'scrcpy' { return 'what the phone copies arrives by itself; what this PC copies is typed on the phone' }
        default  { return 'no way in: this phone has no cmd clipboard, and scrcpy was not found' }
    }
}

function Get-PhoneClipboard {
    # what the phone has, where the phone lets its shell say
    param([string]$Serial)

    if ((Get-ClipboardRoute -Serial $Serial) -ne 'cmd') { return $null }
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
    if ((Get-ClipboardRoute -Serial $Serial) -eq 'cmd') {
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
        } elseif ($share.Route -eq 'cmd') {
            $phoneText = Get-PhoneClipboard -Serial $serial
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
            if ($share.Route -ne 'cmd') { continue }
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
    if ($route -ne 'cmd') {
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
