<#
    AndroidDC - formatting: erasing a memory card, and resetting the phone
    itself to new.

    What adb is allowed to do here was measured on a phone rather than hoped
    for (Android 13, "dumpsys package com.android.shell"):

      MOUNT_FORMAT_FILESYSTEMS  granted  so "sm format" is permitted and a
                                         memory card really can be formatted
                                         from this PC, in one call
      MASTER_CLEAR              not held so the broadcast that wipes a phone
                                         is refused with a SecurityException

    A factory reset is therefore asked for from here and, where Android
    refuses it - which is most phones - the phone's own reset screen is opened
    and the last tap is taken on the phone. That is not a workaround to
    apologise for: a PC that could erase a phone over a cable without anyone
    touching the phone would be a hole, not a feature.

    Nothing here asks a question. Each window asks in its own way first - both
    make the person type the word - and only then calls these. And nothing
    here claims success it has not verified: a format is checked by reading
    the volume back, an erase by counting what is left.

    Dot-sourced after shared\Backup.ps1, whose Write-BackupProgress,
    Test-BackupStopped and Invoke-BackupPump keep long work stoppable, and
    whose list of backups answers "is there a backup of this phone first?".
#>

# paths that are never the thing being emptied, whatever is passed: the roots
# themselves, and the folders Android keeps its own mounts in
$script:eraseNever = @('/', '/sdcard', '/storage', '/storage/emulated', '/storage/self',
    '/data', '/system', '/vendor', '/mnt', '/mnt/user')

function Get-DeviceVolumes {
    <#
        Every storage volume the phone has, as Android's own storage manager
        lists them:

          public:179,1 mounted A1B2C3D4E5F6      a memory card
          emulated;0   mounted null               the phone's own storage
          private      mounted null               where apps live

        Path is where its files are read and written, and is empty when the
        volume has none to offer - which is what an unmounted card looks like.
    #>
    param([string]$Serial)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('sm', 'list-volumes', 'all')).Lines) {
        $text = "$line".Trim()
        if (-not $text -or $text -notmatch '^(\S+)\s+(\S+)\s+(\S+)$') { continue }
        $id = $Matches[1]
        $state = $Matches[2]
        $uuid = $Matches[3]
        if ($uuid -eq 'null') { $uuid = '' }
        $kind = ($id -split '[:;]')[0]
        $path = ''
        if ($kind -eq 'public' -and $uuid -and $state -eq 'mounted') { $path = "/storage/$uuid" }
        elseif ($kind -eq 'emulated' -and $id -ne 'emulated;999' -and $state -eq 'mounted') { $path = '/sdcard' }
        $null = $rows.Add([PSCustomObject]@{
            Id     = $id
            Kind   = $kind
            State  = $state
            Fsuuid = $uuid
            Path   = $path
        })
    }
    return $rows.ToArray()
}

function Get-DeviceRoom {
    # how big the filesystem at a path is and how much of it is in use; -1
    # where the phone has no df, which a few ROMs do not
    param([string]$Serial, [string]$Path)

    $unknown = [PSCustomObject]@{ Total = [long](-1); Used = [long](-1); Free = [long](-1) }
    if (-not "$Path") { return $unknown }
    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'df -k ' + (Quote-DeviceArgument $Path) + ' 2>/dev/null')).Text
    foreach ($line in ("$text" -split "`r?`n")) {
        # "/dev/fuse  124852220  54631048  70221172  44% /storage/45C6..."
        if ("$line" -match '^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%') {
            return [PSCustomObject]@{
                Total = ([long]$Matches[1] * 1024)
                Used  = ([long]$Matches[2] * 1024)
                Free  = ([long]$Matches[3] * 1024)
            }
        }
    }
    return $unknown
}

function Get-DeviceCards {
    <#
        The memory cards in this phone, with enough about each one to put in
        front of someone before they erase it: the volume to format, where its
        files are, and how full it is.

        A card that is in the phone but not mounted is listed as well, with no
        path: it cannot be read, and it can still be formatted.
    #>
    param([string]$Serial)

    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(Get-DeviceVolumes -Serial $Serial)) {
        if ($volume.Kind -ne 'public') { continue }
        $room = Get-DeviceRoom -Serial $Serial -Path $volume.Path
        $null = $cards.Add([PSCustomObject]@{
            Id      = $volume.Id
            Path    = $volume.Path
            Fsuuid  = $volume.Fsuuid
            State   = $volume.State
            Total   = $room.Total
            Used    = $room.Used
            Free    = $room.Free
            Mounted = ($volume.State -eq 'mounted')
        })
    }
    if ($cards.Count -gt 0) { return $cards.ToArray() }

    # sm is not on every ROM. The card is still where Android puts it, under a
    # name that is its filesystem's serial: 1A2B-3C4D for FAT, and sixteen hex
    # digits for exFAT - measured on a phone with an exFAT card, which a
    # pattern written for the four-four shape alone would have missed.
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('ls', '-1', '/storage')).Lines) {
        $name = "$line".Trim()
        if ($name -notmatch '^([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8,16})$') { continue }
        $room = Get-DeviceRoom -Serial $Serial -Path "/storage/$name"
        $null = $cards.Add([PSCustomObject]@{
            Id      = ''
            Path    = "/storage/$name"
            Fsuuid  = $name
            State   = 'mounted'
            Total   = $room.Total
            Used    = $room.Used
            Free    = $room.Free
            Mounted = $true
        })
    }
    return $cards.ToArray()
}

function Get-DeviceCardWords {
    # one line about a card, for a hint or for the question before erasing it
    param($Card)

    if (-not $Card) { return 'no memory card in this phone' }
    $words = "$($Card.Path)"
    if (-not $words) { $words = "$($Card.Id)" }
    if ($Card.Total -gt 0) {
        $words += ' - ' + (Format-FileSize -Bytes $Card.Total) + ', ' +
            (Format-FileSize -Bytes $Card.Used) + ' of it in use'
    }
    if (-not $Card.Mounted) { $words += ' (not mounted)' }
    return $words
}

function Test-DeviceErasablePath {
    # a path this is allowed to empty: inside a card or the phone's own files,
    # and never a root. An rm -rf is being built here; it gets a guard.
    param([string]$Path)

    $text = ("$Path" -replace '/+$', '')
    if (-not $text) { return $false }
    if ($script:eraseNever -contains $text) { return $false }
    if ($text -match '\.\.') { return $false }
    return ($text -like '/storage/*' -or $text -like '/sdcard/*')
}

function Get-DeviceTreeCount {
    # how many files are under a path, so an erase can be checked afterwards;
    # -1 where the phone has no find
    param([string]$Serial, [string]$Path)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'find ' + (Quote-DeviceArgument $Path) + ' -type f 2>/dev/null | wc -l')).Text
    if ("$text" -match '(\d+)') { return [int]$Matches[1] }
    return -1
}

function Clear-DeviceFiles {
    <#
        Everything inside a folder on the phone, gone: the top level is read
        and removed name by name, so the log says what went, the bar moves,
        and Cancel is answered between names instead of after all of them.

        The folder itself stays. It is a mount point, and removing it would
        leave the card with nowhere to appear.

        Returns what was asked for, what the phone would not let go, and how
        many files are still there afterwards.
    #>
    param([string]$Serial, [string]$Path, [string]$Caption = 'Erasing')

    $answer = [PSCustomObject]@{ Asked = 0; Gone = 0; Refused = 0; Left = -1; Stopped = $false; Ok = $false }
    if (-not (Test-DeviceErasablePath -Path $Path)) {
        Write-Log "That is not a path this will empty: $Path" $colorBad
        return $answer
    }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'ls -A1 ' + (Quote-DeviceArgument $Path) + ' 2>/dev/null')).Lines) {
        $name = "$line".Trim()
        if (-not $name -or $name -eq '.' -or $name -eq '..') { continue }
        if ($name -match 'Permission denied|No such file|Not a directory') { continue }
        $null = $names.Add($name)
    }
    $answer.Asked = $names.Count
    if ($names.Count -eq 0) {
        Write-Log "$Path is empty already." $colorInfo
        $answer.Left = 0
        $answer.Ok = $true
        return $answer
    }

    Write-Log "$Caption $Path - $($names.Count) thing(s) at the top level ..." $colorStep
    foreach ($name in $names) {
        if (Test-BackupStopped) { $answer.Stopped = $true; break }
        $answer.Gone++
        Write-BackupProgress -Text "$Caption $name" -Done $answer.Gone -Total $names.Count
        $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'rm -rf ' + (Quote-DeviceArgument ("$Path/$name")) + ' 2>&1')
        $said = "$($result.Text)".Trim()
        if ($said) {
            $answer.Refused++
            Write-Log "  $name : $said" $colorWarn
        }
        Invoke-BackupPump
    }

    $answer.Left = Get-DeviceTreeCount -Serial $Serial -Path $Path
    if ($answer.Stopped) {
        Write-Log "Stopped part way: $($answer.Gone) of $($answer.Asked) gone." $colorWarn
    } elseif ($answer.Left -gt 0) {
        Write-Log "$($answer.Left) file(s) are still there - Android would not let adb remove them." $colorWarn
    } elseif ($answer.Left -eq 0) {
        Write-Log "$Path is empty now." $colorGood
        $answer.Ok = $true
    } else {
        # no find on this ROM: say what was done, not what cannot be checked
        Write-Log "Removed $($answer.Gone) thing(s); this phone has no find, so nothing was counted after." $colorInfo
        $answer.Ok = ($answer.Refused -eq 0)
    }
    return $answer
}

function Format-DeviceCard {
    <#
        A memory card formatted by the phone itself: "sm format" hands the
        whole job to Android's storage manager, which unmounts the card,
        writes a new filesystem and mounts it again.

        Allowed because adb's shell holds MOUNT_FORMAT_FILESYSTEMS - measured,
        not assumed - and reported exactly as the phone answered it. The new
        filesystem has a new serial, so where the card appears changes: the
        volumes are read again afterwards to say where it is now.
    #>
    param([string]$Serial, [string]$Volume)

    $answer = [PSCustomObject]@{ Ok = $false; Refused = $false; Text = ''; Path = ''; Left = -1 }
    if (-not "$Volume") {
        Write-Log 'There is no volume to format - the card has to be in the phone.' $colorWarn
        return $answer
    }

    Write-Log "Formatting $Volume - the phone does the work, which can take a minute." $colorStep
    Write-BackupProgress -Text "Formatting $Volume ..." -Done -1 -Total -1
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('sm', 'format', $Volume)
    $said = "$($result.Text)".Trim()
    $answer.Text = $said
    foreach ($line in ("$said" -split "`r?`n")) {
        if ("$line".Trim()) { Write-Log ('  ' + "$line".Trim()) $colorInfo }
    }
    if ($said -match 'SecurityException|Permission Denial|permission denied|requires .*permission') {
        $answer.Refused = $true
        Write-Log 'Android refused: this phone does not let adb format a card.' $colorBad
        Write-Log '  Format it on the phone instead: Settings > Storage > the card > Format.' $colorInfo
        return $answer
    }
    if ($said -match 'Error|Exception|failed|Unknown volume') {
        Write-Log 'The phone did not format it, so nothing was changed.' $colorBad
        return $answer
    }

    # Where it is now, under its new filesystem's name. Not $volume for this:
    # the parameter is [string]$Volume, PowerShell reads the two names as one
    # variable, and the row would be flattened into "@{Id=public:179,1; ...}"
    # before anything could be read off it.
    $found = @(@(Get-DeviceVolumes -Serial $Serial) | Where-Object { $_.Id -eq $Volume })
    $row = $(if ($found.Count -gt 0) { $found[0] } else { $null })
    if ($row -and $row.State -ne 'mounted') {
        Write-Log '  mounting it again ...' $colorInfo
        $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('sm', 'mount', $Volume)
        $found = @(@(Get-DeviceVolumes -Serial $Serial) | Where-Object { $_.Id -eq $Volume })
        $row = $(if ($found.Count -gt 0) { $found[0] } else { $null })
    }
    if ($row) { $answer.Path = "$($row.Path)" }
    if (-not $answer.Path) {
        Write-Log 'The card was formatted, but the phone has not mounted it again yet.' $colorWarn
        Write-Log '  Take it out and put it back, or restart the phone, and it will appear.' $colorInfo
        $answer.Ok = $true
        return $answer
    }

    $answer.Left = Get-DeviceTreeCount -Serial $Serial -Path $answer.Path
    if ($answer.Left -gt 0) {
        Write-Log "It says it formatted the card, and $($answer.Left) file(s) are still on it." $colorWarn
        return $answer
    }
    $answer.Ok = $true
    Write-Log "The card is formatted and mounted at $($answer.Path) - it is empty." $colorGood
    return $answer
}

function Test-DeviceResetScreen {
    <#
        The phone's own factory reset screen, if it has one adb may open. The
        first of these that resolves is the one used; on the phone this was
        written against only the first did - a ROM whose Settings has no
        BACKUP_AND_RESET_SETTINGS at all.
    #>
    param([string]$Serial)

    foreach ($action in @('com.android.settings.action.FACTORY_RESET',
            'android.settings.BACKUP_AND_RESET_SETTINGS', 'android.settings.PRIVACY_SETTINGS',
            'android.settings.SETTINGS')) {
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'cmd', 'package', 'resolve-activity', '--brief', '-a', $action)).Text
        foreach ($line in ("$text" -split "`r?`n")) {
            $name = "$line".Trim()
            if ($name -match '^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$') {
                return [PSCustomObject]@{ Action = $action; Component = $name }
            }
        }
    }
    return $null
}

function Open-DeviceResetScreen {
    # the reset screen on the phone's own display, for the taps Android keeps
    # to itself
    param([string]$Serial)

    $screen = Test-DeviceResetScreen -Serial $Serial
    if (-not $screen) {
        Write-Log 'This phone has no reset screen adb can open.' $colorWarn
        Write-Log '  Open Settings on the phone and look for "Reset" or "Erase all data".' $colorInfo
        return $false
    }
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('am', 'start', '-a', $screen.Action)
    if ("$($result.Text)" -match 'Error|Exception') {
        Write-Log ('am start said: ' + "$($result.Text)".Trim()) $colorBad
        return $false
    }
    Write-Log "Opened $($screen.Component) on the phone." $colorGood
    Write-Log '  The last step is on the phone: tap Erase and enter the screen lock.' $colorInfo
    return $true
}

function Test-DeviceResetAllowed {
    <#
        Whether adb's shell on this phone holds MASTER_CLEAR, which is what
        Android checks before it acts on the reset broadcast.

        It is asked because the broadcast does not say. "Broadcast completed:
        result=0" means the message was delivered, not that anything was done
        with it: the receiver lives in the system, and a system that does not
        like the caller drops it without a word back down the cable. The phone
        this was written against grants its shell 1046 permissions and this is
        not one of them.
    #>
    param([string]$Serial)

    $said = "$((Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys package com.android.shell 2>/dev/null')).Text)"
    if (-not $said) { return $false }
    foreach ($line in ($said -split "`r?`n")) {
        if ($line -notmatch 'MASTER_CLEAR') { continue }
        # "android.permission.MASTER_CLEAR: granted=true", or a bare line in
        # the install-time list, which is also a grant
        if ($line -match 'granted=false') { continue }
        return $true
    }
    return $false
}

function Wait-DeviceGone {
    <#
        A phone that has really started erasing itself leaves the cable within
        seconds: it restarts into recovery to do the wiping. One that ignored
        the broadcast goes on answering as though nothing had been asked.

        That difference is the only honest evidence there is, so it is what the
        window is told, rather than what the broadcast said about itself.
    #>
    param([string]$Serial, [int]$Seconds = 25)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        # the phone is asked before anything else is minded: a stop left over
        # from an earlier run would otherwise answer for it, and "it did not
        # go" is what this would then have said about a phone never asked
        $said = "$((Invoke-DeviceShell -Serial $Serial -CommandArguments @('echo', 'still-here')).Text)"
        if ($said -notmatch 'still-here') { return $true }
        if (Test-BackupStopped) { return $false }
        if ($watch.Elapsed.TotalSeconds -ge $Seconds) { return $false }
        Start-Sleep -Milliseconds 600
        Invoke-BackupPump
    }
}

function Reset-DeviceToNew {
    <#
        The phone back to how it left the factory: apps, accounts, files,
        settings, everything.

        Android resets on a broadcast, and adb's shell is allowed to send it
        on hardly any phone. Worse, it is allowed to send it everywhere: the
        broadcast is delivered and reported completed whether or not anything
        acts on it. So this asks first whether the phone would act on it, and
        afterwards whether it did - a phone erasing itself leaves the cable,
        and one that ignored the message does not.

        Where the phone will not take it, its own reset screen is opened and
        the taps happen there. The window is told which of the two it was,
        because "it is erasing itself now" and "there is a screen waiting for
        you on the phone" are not the same news.
    #>
    param([string]$Serial)

    $answer = [PSCustomObject]@{ Wiping = $false; Opened = $false; Text = '' }

    if (-not (Test-DeviceResetAllowed -Serial $Serial)) {
        Write-Log 'Android does not let adb erase this phone: its shell does not hold MASTER_CLEAR.' $colorWarn
        Write-Log '  The broadcast would be delivered and then quietly dropped, so it is not sent.' $colorInfo
        Write-Log 'Opening the phone''s own reset screen instead - the taps are done there.' $colorInfo
        $answer.Opened = [bool](Open-DeviceResetScreen -Serial $Serial)
        return $answer
    }

    Write-Log 'Asking the phone to reset itself to new ...' $colorStep
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('am', 'broadcast',
        '-a', 'android.intent.action.FACTORY_RESET', '-p', 'android', '--receiver-foreground',
        '--es', 'android.intent.extra.REASON', 'AndroidDC')
    $said = "$($result.Text)".Trim()
    $answer.Text = $said

    if ($said -match 'SecurityException|Permission Denial') {
        Write-Log ('Android refused it: ' + ($said -split "`r?`n")[0]) $colorWarn
        Write-Log 'Opening the phone''s own reset screen instead - the taps are done there.' $colorInfo
        $answer.Opened = [bool](Open-DeviceResetScreen -Serial $Serial)
        return $answer
    }

    Write-Log '  Sent. Watching whether the phone goes off the cable to do it ...' $colorInfo
    if (Wait-DeviceGone -Serial $Serial) {
        $answer.Wiping = $true
        Write-Log 'The phone has left the cable: it is erasing itself and will restart as new.' $colorGood
        Write-Log '  Leave the cable alone until it has restarted.' $colorInfo
        return $answer
    }

    # delivered, reported completed, and nothing happened: the phone is still
    # answering. Saying it took it would be saying something that is not so.
    Write-Log 'The phone is still here, so it did not act on it - whatever the broadcast reported.' $colorWarn
    Write-Log 'Opening the phone''s own reset screen instead - the taps are done there.' $colorInfo
    $answer.Opened = [bool](Open-DeviceResetScreen -Serial $Serial)
    return $answer
}

function Format-EraseAgo {
    # how long ago, in the words a person would use
    param([datetime]$When)

    $days = [int][Math]::Floor(((Get-Date) - $When).TotalDays)
    if ($days -lt 0) { return 'in the future, by this PC''s clock' }
    if ($days -eq 0) { return 'today' }
    if ($days -eq 1) { return 'yesterday' }
    if ($days -lt 30) { return "$days days ago" }
    $months = [int][Math]::Round($days / 30.0)
    if ($months -le 1) { return 'about a month ago' }
    if ($months -lt 12) { return "about $months months ago" }
    return 'more than a year ago'
}

function Get-DeviceBackupNote {
    <#
        What this PC has of this phone, in one sentence, to put in front of
        someone about to erase it. "Is there a backup first?" is the only part
        of a factory reset a program on this side of the cable can help with.
    #>
    param([string]$Serial)

    if (-not (Get-Command Get-BackupsInFolder -ErrorAction SilentlyContinue)) { return '' }
    $rows = @()
    try { $rows = @(Get-BackupsInFolder -Folder (Get-BackupFolderPath)) } catch { $rows = @() }
    $mine = @($rows | Where-Object { "$($_.Phone)" -like "*($Serial)*" })
    if ($mine.Count -eq 0) {
        return 'This PC has no backup of this phone. Everything on it will be gone.'
    }
    $newest = $mine[0]
    $words = "Newest backup of this phone here: $($newest.When) (" + (Format-EraseAgo -When $newest.Taken) + ')'
    if ("$($newest.Called)") { $words += ", called '$($newest.Called)'" }
    $words += ". It holds $($newest.Holds)."
    if ("$($newest.State)" -ne 'complete') { $words += ' It stopped part way.' }
    return $words
}
