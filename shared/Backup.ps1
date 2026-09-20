<#
    AndroidDC - a backup of the phone on this PC, and putting one back.

    What Android lets adb read without root, and no more:

      files     everything under /sdcard the phone will hand over. Android 11
                closed Android/data and Android/obb to adb, so those are
                skipped; Android/media, where messaging apps keep pictures,
                is not closed and is taken.
      apps      the APK of every app you installed, splits included. What is
                inside an app (chats, game saves, its own settings) cannot be
                read without root - no tool without root can - and this one
                says so rather than pretending.
      personal  contacts, messages and the call log. Contacts go back on a
                phone; messages and the call log are saved to read and to
                keep, because Android has no way for adb to write them.
      settings  settings list, getprop, the installed packages and a device
                report, as text to read while setting a phone up again.

    A backup is a folder of ordinary files - no archive, no password, nothing
    to unpack - with manifest.json saying what is in it. Restoring reads that
    manifest, never the folder's name.

    Long work can be stopped, and never runs blind:

      * every adb call goes through Invoke-BackupAdb, which watches the process
        while the window keeps drawing, says how far it has got, and kills adb
        the moment Stop-BackupRun is called;
      * a phone that is unplugged is noticed at once - adb says so - and the
        run ends there instead of failing file after file;
      * however it ends, the manifest is written, the log says what was done,
        and a notification by the clock says it has finished.

    Dot-sourced by androiddc.ps1 and nova\androiddc-nova.ps1. Nothing here
    touches a control: each window passes a progress script block, and decides
    what to ask before files already on the phone are written over.
#>

$script:backupFormat = 1
$script:backupProgress = $null
$script:backupStopped = $false
$script:backupStopReason = ''
$script:backupRunning = $false

function Initialize-Backup {
    # Progress: param($Text, $Done, $Total); $Done and $Total are -1 when unknown
    param([scriptblock]$Progress)
    $script:backupProgress = $Progress
}

function Write-BackupProgress {
    param([string]$Text, [int]$Done = -1, [int]$Total = -1)
    if ($script:backupProgress) { try { & $script:backupProgress $Text $Done $Total } catch { } }
}

# ------------------------------------------------------ starting, stopping ----

function Start-BackupRun {
    # a fresh run: nothing stopped, nothing to report yet
    $script:backupStopped = $false
    $script:backupStopReason = ''
    $script:backupRunning = $true
}

function Stop-BackupRun {
    # what Cancel calls, and what a lost phone calls; the run notices between
    # files, and kills adb in the middle of one
    param([string]$Reason = 'cancelled')

    if (-not $script:backupRunning) { return }
    if (-not $script:backupStopped) {
        $script:backupStopped = $true
        $script:backupStopReason = $Reason
    }
}

function Complete-BackupRun {
    $script:backupRunning = $false
}

function Test-BackupStopped {
    return $script:backupStopped
}

function Get-BackupStopReason {
    return $script:backupStopReason
}

function Test-BackupRunning {
    return $script:backupRunning
}

function Test-BackupDeviceGone {
    # what adb says when the phone has gone: stop everything, not just this file
    param([string]$Text)
    return ("$Text" -match 'device .*not found|device offline|no devices/emulators found|error: closed|device unauthorized')
}

function Send-BackupNotice {
    # a notification by the clock when a long run ends, however it ended
    param([string]$Title, [string]$Text)

    Write-Log "$Title - $Text" $colorInfo
    if (Get-Command Show-TrayBalloon -ErrorAction SilentlyContinue) {
        $null = Show-TrayBalloon -Title $Title -Text $Text
    }
}

function Invoke-BackupAdb {
    <#
        One adb call that can be watched and stopped. adb prints no progress
        when its output is redirected, so how far it has got is measured where
        the bytes land: OnPoll is asked every second or so and answers the size
        so far, or -1 when that cannot be known.

        Returns ExitCode, Text and Stopped.
    #>
    param(
        [string[]]$ArgumentList,
        [string]$Caption = '',
        [long]$Expected = -1,
        [scriptblock]$OnPoll
    )

    if (Test-BackupStopped) { return [PSCustomObject]@{ ExitCode = 1; Text = 'stopped'; Stopped = $true } }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    # every argument quoted on its own: a path may hold spaces
    $info.Arguments = (@($ArgumentList | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # adb writes UTF-8; left unset, .NET decodes with the console page and an
    # Arabic name in adb's messages comes back garbled
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { return [PSCustomObject]@{ ExitCode = 1; Text = 'adb did not start'; Stopped = $false } }
    } catch {
        return [PSCustomObject]@{ ExitCode = 1; Text = $_.Exception.Message; Stopped = $false }
    }

    # both streams are read as they come, so a chatty adb never blocks on a full pipe
    $errorRead = $process.StandardError.ReadToEndAsync()
    $outputRead = $process.StandardOutput.ReadToEndAsync()

    $script:busy++
    $script:busyWhat = 'adb ' + ($ArgumentList -join ' ')
    $stopped = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPoll = -2000
    try {
        while (-not $process.HasExited) {
            # the window keeps drawing, and Cancel keeps working, while adb runs
            Wait-Pumped -Milliseconds 120
            if (Test-BackupStopped) {
                try { $process.Kill() } catch { }
                $stopped = $true
                break
            }
            if ($OnPoll -and ($watch.ElapsedMilliseconds - $lastPoll) -gt 1200) {
                $lastPoll = $watch.ElapsedMilliseconds
                $done = [long](-1)
                try { $done = [long](& $OnPoll) } catch { $done = [long](-1) }
                if ($Expected -gt 0 -and $done -ge 0) {
                    $share = [int]([Math]::Min(100, 100 * $done / $Expected))
                    Write-BackupProgress -Text ("$Caption  " + (Format-FileSize -Bytes $done) + ' of ' +
                        (Format-FileSize -Bytes $Expected)) -Done $share -Total 100
                } elseif ($done -ge 0) {
                    Write-BackupProgress -Text ("$Caption  " + (Format-FileSize -Bytes $done) + ' so far') -Done -1 -Total -1
                }
            }
        }
        $null = $process.WaitForExit(5000)
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
    }

    $text = ''
    try {
        if ($errorRead.Wait(3000)) { $text += $errorRead.Result }
        if ($outputRead.Wait(3000)) { $text += $outputRead.Result }
    } catch { }

    $code = 1
    try { $code = $process.ExitCode } catch { }
    if (-not $stopped -and (Test-BackupDeviceGone -Text $text)) {
        Stop-BackupRun -Reason 'the phone was disconnected'
        $stopped = $true
    }
    return [PSCustomObject]@{ ExitCode = $code; Text = "$text".Trim(); Stopped = $stopped }
}

# ------------------------------------------------------------------ parts ----

function Get-BackupParts {
    # what a backup can hold; each one is ticked on its own
    return @(
        [PSCustomObject]@{ Id = 'files'; Label = 'Phone files (internal storage)'
            Note = 'Photos, videos, downloads, documents - everything under /sdcard that Android lets adb read' }
        [PSCustomObject]@{ Id = 'apps'; Label = 'Apps (their APK files)'
            Note = 'The apps you installed, so they can be installed again. What is inside an app stays on the phone: Android does not let adb read it without root' }
        [PSCustomObject]@{ Id = 'personal'; Label = 'Contacts, messages and call log'
            Note = 'Contacts can be put back on a phone; messages and the call log are saved to read, because Android has no way for adb to write them' }
        [PSCustomObject]@{ Id = 'settings'; Label = 'Settings and the app list'
            Note = 'settings list, getprop, the installed packages and a device report, as text' }
    )
}

function Get-BackupPartLabel {
    param([string]$Id)
    foreach ($part in (Get-BackupParts)) { if ($part.Id -eq $Id) { return $part.Label } }
    return $Id
}

function ConvertTo-BackupName {
    # a folder name for a backup: which phone, and when it was taken
    param([string]$Model, [string]$Serial, [datetime]$When = [datetime]::Now)

    $text = "$Model $Serial"
    foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) { $text = $text.Replace($bad, '-') }
    $text = ($text -replace '\s+', '-').Trim('-')
    if (-not $text) { $text = 'phone' }
    return ('AndroidDC-backup-{0}-{1}' -f $text, $When.ToString('yyyyMMdd-HHmmss'))
}

function Split-BackupRows {
    # 'content query' prints one record per "Row: <n> col=val, col=val"; a body
    # may hold newlines, so the row marker is what rows are split on. Named
    # apart from the windows' own Split-ContentRows, which belongs to a page.
    param([string]$Text)

    $rows = @()
    foreach ($chunk in ("$Text" -split '(?m)^Row:\s+\d+\s+')) {
        if ($chunk.Trim()) { $rows += $chunk }
    }
    return $rows
}

function Get-BackupRowValue {
    param([string]$Row, [string]$Column)

    # a value may hold commas, so a column ends where the next "name=" begins
    $pattern = '(?s)' + [regex]::Escape($Column) + '=(.*?)(?=,\s+[A-Za-z_][A-Za-z_0-9]*=|$)'
    if ($Row -match $pattern) { return $Matches[1].Trim() }
    return ''
}

function Get-BackupStorageEntries {
    # the top level of /sdcard, with what adb cannot read left out
    param([string]$Serial)

    $entries = @()
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('ls', '-1', '/sdcard/')).Lines) {
        $name = "$line".Trim()
        if (-not $name -or $name -match 'Permission denied|No such file|Not a directory') { continue }
        if ($name -eq 'Android') {
            # Android/data and Android/obb have been closed to adb since Android
            # 11; Android/media is not, and holds what messaging apps keep
            $media = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('ls', '-d', '/sdcard/Android/media')).Text
            if ($media -match '/sdcard/Android/media') { $entries += 'Android/media' }
            continue
        }
        $entries += $name
    }
    return $entries
}

function Get-BackupRemoteSize {
    # how big a folder on the phone is, so the bar can mean something; -1 when
    # the phone has no du, which some ROMs do not
    param([string]$Serial, [string]$Path)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @("du -sk '$Path' 2>/dev/null")).Text
    if ("$text" -match '^\s*(\d+)') { return ([long]$Matches[1] * 1024) }
    return [long](-1)
}

function Save-BackupText {
    # one text file in the backup, written as UTF-8 without a BOM
    param([string]$Path, [string]$Text)

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    [System.IO.File]::WriteAllText($Path, "$Text", (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BackupFolderSize {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $total = [long]0
    foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) { $total += $file.Length }
    return $total
}

function Backup-PhoneFiles {
    # /sdcard onto the PC, one top-level folder at a time, so the log says where
    # it is and Cancel lands between folders as well as inside one
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'files'
    $null = New-Item -ItemType Directory -Path $target -Force
    $entries = @(Get-BackupStorageEntries -Serial $Serial)
    Write-Log "Backup: $($entries.Count) folder(s) of internal storage ..." $colorStep

    $index = 0
    $refused = @()
    foreach ($entry in $entries) {
        if (Test-BackupStopped) { break }
        $index++
        Write-BackupProgress -Text "Files: $entry" -Done $index -Total $entries.Count
        Write-Log "  pulling /sdcard/$entry ..." $colorInfo

        $local = Join-Path $target ($entry -replace '/', [string][char]92)
        $parent = Split-Path -Parent $local
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }

        $expected = Get-BackupRemoteSize -Serial $Serial -Path "/sdcard/$entry"
        $result = Invoke-BackupAdb -ArgumentList @('-s', $Serial, 'pull', '-a', "/sdcard/$entry", $local) `
            -Caption "Files: $entry" -Expected $expected -OnPoll { Get-BackupFolderSize -Path $local }.GetNewClosure()
        if ($result.Stopped) { break }
        if ($result.ExitCode -ne 0) {
            $refused += $entry
            Write-Log ('  ' + $result.Text) $colorWarn
        }
    }

    $count = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue).Count
    $bytes = Get-BackupFolderSize -Path $target
    if ($refused.Count -gt 0) { Write-Log ('  the phone refused: ' + ($refused -join ', ')) $colorWarn }
    Write-Log ("  $count file(s), " + (Format-FileSize -Bytes $bytes)) $colorGood
    return [PSCustomObject]@{ Files = $count; Bytes = $bytes; Folders = @($entries); Refused = @($refused) }
}

function Backup-PhoneApps {
    # the APK of every app the user installed, splits included
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'apps'
    $null = New-Item -ItemType Directory -Path $target -Force
    $packages = @()
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'packages', '-3')).Lines) {
        if ("$line" -match '^package:(\S+)') { $packages += $Matches[1] }
    }
    $packages = @($packages | Sort-Object -Unique)
    Write-Log "Backup: $($packages.Count) app(s) ..." $colorStep

    $apps = @()
    $index = 0
    foreach ($package in $packages) {
        if (Test-BackupStopped) { break }
        $index++
        Write-BackupProgress -Text "Apps: $package" -Done $index -Total $packages.Count

        $paths = @()
        foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'path', $package)).Lines) {
            if ("$line" -match '^package:(/\S+\.apk)$') { $paths += $Matches[1] }
        }
        if ($paths.Count -eq 0) { Write-Log "  $package : no readable APK" $colorWarn; continue }

        $appFolder = Join-Path $target $package
        $null = New-Item -ItemType Directory -Path $appFolder -Force
        $saved = @()
        foreach ($path in $paths) {
            if (Test-BackupStopped) { break }
            $name = [System.IO.Path]::GetFileName($path)
            $result = Invoke-BackupAdb -ArgumentList @('-s', $Serial, 'pull', $path, (Join-Path $appFolder $name)) `
                -Caption "Apps: $package"
            if ($result.Stopped) { break }
            if ($result.ExitCode -eq 0) { $saved += $name } else { Write-Log ("  $package : " + $result.Text) $colorWarn }
        }
        if ($saved.Count -eq 0) { continue }
        $apps += [PSCustomObject]@{ Package = $package; Files = @($saved); Bytes = (Get-BackupFolderSize -Path $appFolder) }
    }

    Write-Log ("  $($apps.Count) app(s), " + (Format-FileSize -Bytes (Get-BackupFolderSize -Path $target))) $colorGood
    return $apps
}

function Backup-PhonePersonal {
    # contacts, messages and the call log, as the phone has them now
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'personal'
    $null = New-Item -ItemType Directory -Path $target -Force

    Write-BackupProgress -Text 'Contacts ...' -Done 1 -Total 3
    $contacts = @()
    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection display_name:data1')).Text
    if (Test-BackupDeviceGone -Text $text) { Stop-BackupRun -Reason 'the phone was disconnected' }
    foreach ($row in (Split-BackupRows -Text $text)) {
        $number = Get-BackupRowValue -Row $row -Column 'data1'
        if (-not $number) { continue }
        $contacts += [PSCustomObject]@{ Name = (Get-BackupRowValue -Row $row -Column 'display_name'); Number = $number }
    }
    Save-BackupText -Path (Join-Path $target 'contacts.json') -Text (ConvertTo-Json -InputObject @($contacts) -Depth 3)

    $messages = @()
    if (-not (Test-BackupStopped)) {
        Write-BackupProgress -Text 'Messages ...' -Done 2 -Total 3
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'content query --uri content://sms --projection _id:address:date:type:body')).Text
        foreach ($row in (Split-BackupRows -Text $text)) {
            $address = Get-BackupRowValue -Row $row -Column 'address'
            if (-not $address) { continue }
            $messages += [PSCustomObject]@{
                Number = $address
                When   = (Get-BackupRowValue -Row $row -Column 'date')
                Kind   = (Get-BackupRowValue -Row $row -Column 'type')
                Text   = (Get-BackupRowValue -Row $row -Column 'body')
            }
        }
        Save-BackupText -Path (Join-Path $target 'messages.json') -Text (ConvertTo-Json -InputObject @($messages) -Depth 3)
    }

    $calls = @()
    if (-not (Test-BackupStopped)) {
        Write-BackupProgress -Text 'Call log ...' -Done 3 -Total 3
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'content query --uri content://call_log/calls --projection number:date:duration:type')).Text
        foreach ($row in (Split-BackupRows -Text $text)) {
            $number = Get-BackupRowValue -Row $row -Column 'number'
            if (-not $number) { continue }
            $calls += [PSCustomObject]@{
                Number  = $number
                When    = (Get-BackupRowValue -Row $row -Column 'date')
                Seconds = (Get-BackupRowValue -Row $row -Column 'duration')
                Kind    = (Get-BackupRowValue -Row $row -Column 'type')
            }
        }
        Save-BackupText -Path (Join-Path $target 'calls.json') -Text (ConvertTo-Json -InputObject @($calls) -Depth 3)
    }

    Write-Log "  $($contacts.Count) contact(s), $($messages.Count) message(s), $($calls.Count) call(s)" $colorGood
    return [PSCustomObject]@{ Contacts = $contacts.Count; Messages = $messages.Count; Calls = $calls.Count }
}

function Backup-PhoneSettings {
    # what the phone says about itself, as text to read while setting one up again
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'settings'
    $null = New-Item -ItemType Directory -Path $target -Force
    $reads = @(
        [PSCustomObject]@{ File = 'settings-system.txt'; Command = @('settings', 'list', 'system') }
        [PSCustomObject]@{ File = 'settings-secure.txt'; Command = @('settings', 'list', 'secure') }
        [PSCustomObject]@{ File = 'settings-global.txt'; Command = @('settings', 'list', 'global') }
        [PSCustomObject]@{ File = 'properties.txt'; Command = @('getprop') }
        [PSCustomObject]@{ File = 'packages-user.txt'; Command = @('pm', 'list', 'packages', '-3', '--show-versioncode') }
        [PSCustomObject]@{ File = 'packages-system.txt'; Command = @('pm', 'list', 'packages', '-s') }
    )

    $written = @()
    $index = 0
    foreach ($read in $reads) {
        if (Test-BackupStopped) { break }
        $index++
        Write-BackupProgress -Text "Settings: $($read.File)" -Done $index -Total ($reads.Count + 1)
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments $read.Command).Text
        if (Test-BackupDeviceGone -Text $text) { Stop-BackupRun -Reason 'the phone was disconnected'; break }
        Save-BackupText -Path (Join-Path $target $read.File) -Text $text
        $written += $read.File
    }

    if (-not (Test-BackupStopped)) {
        Write-BackupProgress -Text 'Settings: the device report' -Done ($reads.Count + 1) -Total ($reads.Count + 1)
        # the Overview page's report, when this window has it
        if (Get-Command Get-DeviceReport -ErrorAction SilentlyContinue) {
            Save-BackupText -Path (Join-Path $target 'device.txt') -Text (Get-DeviceReport -Serial $Serial)
            $written += 'device.txt'
        }
    }
    Write-Log ('  ' + ($written -join ', ')) $colorGood
    return $written
}

function Invoke-PhoneBackup {
    <#
        One backup into a new folder under Destination. Parts are ids from
        Get-BackupParts. Stopping - by Cancel, or by the phone going away -
        ends it where it is; the manifest is written either way, and Complete
        says whether everything asked for was taken.
    #>
    param([string]$Serial, [string]$Destination, [string[]]$Parts, [string]$Model = '')

    $wanted = @(@($Parts) | Where-Object { $_ })
    if ($wanted.Count -eq 0) { Write-Log 'Backup: nothing was ticked.' $colorWarn; return $null }
    if (-not (Test-Path -LiteralPath $Destination)) { $null = New-Item -ItemType Directory -Path $Destination -Force }

    $started = [datetime]::Now
    $folder = Join-Path $Destination (ConvertTo-BackupName -Model $Model -Serial $Serial -When $started)
    $null = New-Item -ItemType Directory -Path $folder -Force
    Write-Log "Backup of $Serial into $folder" $colorStep
    Start-BackupRun

    $manifest = [ordered]@{
        Format   = $script:backupFormat
        Serial   = $Serial
        Model    = $Model
        Android  = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'ro.build.version.release')).Text.Trim()
        Created  = $started.ToString('s')
        Parts    = @($wanted)
        Files    = $null
        Apps     = @()
        Personal = $null
        Settings = @()
        Bytes    = [long]0
        Complete = $true
        Stopped  = ''
        Finished = ''
    }

    try {
        if (-not (Test-BackupStopped) -and $wanted -contains 'files') { $manifest.Files = Backup-PhoneFiles -Serial $Serial -Folder $folder }
        if (-not (Test-BackupStopped) -and $wanted -contains 'apps') { $manifest.Apps = @(Backup-PhoneApps -Serial $Serial -Folder $folder) }
        if (-not (Test-BackupStopped) -and $wanted -contains 'personal') { $manifest.Personal = Backup-PhonePersonal -Serial $Serial -Folder $folder }
        if (-not (Test-BackupStopped) -and $wanted -contains 'settings') { $manifest.Settings = @(Backup-PhoneSettings -Serial $Serial -Folder $folder) }
    } finally {
        $manifest.Bytes = Get-BackupFolderSize -Path $folder
        $manifest.Finished = ([datetime]::Now).ToString('s')
        $manifest.Complete = -not (Test-BackupStopped)
        $manifest.Stopped = Get-BackupStopReason
        Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -InputObject $manifest -Depth 6)
        Complete-BackupRun
    }

    $minutes = ([datetime]::Now - $started).TotalMinutes
    $size = Format-FileSize -Bytes $manifest.Bytes
    if ($manifest.Complete) {
        Write-Log ("Backup done: $size" + (' in {0:N1} minute(s).' -f $minutes)) $colorGood
        Send-BackupNotice -Title 'Backup done' -Text "$size from $Serial is in the folder."
    } else {
        Write-Log ("Backup stopped ($($manifest.Stopped)) after $size" + (' and {0:N1} minute(s).' -f $minutes)) $colorWarn
        Write-Log '  What was already pulled is kept, and the manifest says this backup is not complete.' $colorInfo
        Send-BackupNotice -Title 'Backup stopped' -Text "$($manifest.Stopped). $size was kept."
    }
    Write-BackupProgress -Text $(if ($manifest.Complete) { 'Backup done' } else { "Backup stopped: $($manifest.Stopped)" }) -Done 1 -Total 1

    $result = [PSCustomObject]$manifest
    Add-Member -InputObject $result -NotePropertyName 'Folder' -NotePropertyValue $folder -Force
    return $result
}

# --------------------------------------------------------------- restoring ----

function Read-BackupManifest {
    # the manifest of a backup folder, or $null when that folder is not one
    param([string]$Folder)

    $path = Join-Path "$Folder" 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-BackupSummaryLines {
    # what a backup holds, in words, to show before anything is put back
    param($Manifest)

    if ($null -eq $Manifest) { return @('Not a backup folder: it has no manifest.json.') }
    $lines = @("$($Manifest.Model) ($($Manifest.Serial)), Android $($Manifest.Android), taken " +
        (("$($Manifest.Created)" -replace 'T', ' ')))
    if ($Manifest.PSObject.Properties['Bytes']) { $lines += 'Size: ' + (Format-FileSize -Bytes ([long]$Manifest.Bytes)) }
    if ($Manifest.PSObject.Properties['Complete'] -and -not $Manifest.Complete) {
        $lines += "Not complete: this backup was stopped ($($Manifest.Stopped))"
    }
    if ($Manifest.PSObject.Properties['Files'] -and $Manifest.Files) {
        $lines += "Files: $($Manifest.Files.Files) file(s), " + (Format-FileSize -Bytes ([long]$Manifest.Files.Bytes))
    }
    if ($Manifest.PSObject.Properties['Apps']) { $lines += "Apps: $(@($Manifest.Apps).Count)" }
    if ($Manifest.PSObject.Properties['Personal'] -and $Manifest.Personal) {
        $lines += "Contacts: $($Manifest.Personal.Contacts), messages: $($Manifest.Personal.Messages), calls: $($Manifest.Personal.Calls)"
    }
    if ($Manifest.PSObject.Properties['Settings'] -and @($Manifest.Settings).Count -gt 0) {
        $lines += 'Settings: ' + (@($Manifest.Settings) -join ', ')
    }
    return $lines
}

function Get-BackupAppRows {
    # the apps in a backup, and whether the phone has each one already
    param([string]$Folder, [string]$Serial = '')

    $installed = @()
    if ($Serial) {
        foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'packages')).Lines) {
            if ("$line" -match '^package:(\S+)') { $installed += $Matches[1] }
        }
    }

    $rows = @()
    $appsFolder = Join-Path "$Folder" 'apps'
    if (-not (Test-Path -LiteralPath $appsFolder)) { return $rows }
    foreach ($appFolder in (Get-ChildItem -LiteralPath $appsFolder -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $apks = @(Get-ChildItem -LiteralPath $appFolder.FullName -Filter *.apk -File -ErrorAction SilentlyContinue)
        if ($apks.Count -eq 0) { continue }
        $bytes = [long]0
        foreach ($apk in $apks) { $bytes += $apk.Length }
        $rows += [PSCustomObject]@{
            Package = $appFolder.Name
            # the base APK goes first: install-multiple takes it before its splits
            Apks    = @($apks | Sort-Object { $_.Name -notlike 'base*' }, Name | ForEach-Object { $_.FullName })
            Size    = (Format-FileSize -Bytes $bytes)
            State   = $(if ($installed -contains $appFolder.Name) { 'installed' } else { 'missing' })
        }
    }
    return $rows
}

function Get-BackupFilePlan {
    <#
        What restoring the files would do: every file in the backup and where
        it goes on the phone. Nothing is asked of the phone here, so this can
        be read on its own; Set-BackupFilePlanState marks what is already there.
    #>
    param([string]$Folder)

    $plan = [PSCustomObject]@{ Total = 0; Existing = 0; Items = @(); Tops = @() }
    $root = Join-Path "$Folder" 'files'
    if (-not (Test-Path -LiteralPath $root)) { return $plan }

    # One spelling of the folder for both the walk and the cut: %TEMP% is handed
    # out in its 8.3 form (LONGNA~1) while Resolve-Path answers the long one, and
    # cutting a long prefix off a short path ate the first letters of every name.
    # [char]92 is the backslash - as a quoted string it is one escape away from a
    # regex that means nothing, which is how this line broke once already.
    $rootPath = (Get-Item -LiteralPath $root).FullName.TrimEnd([char]92)
    $rootLength = $rootPath.Length + 1
    $items = @()
    foreach ($file in (Get-ChildItem -LiteralPath $rootPath -Recurse -File -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($rootLength)
        $items += [PSCustomObject]@{
            Local  = $file.FullName
            Remote = '/sdcard/' + $relative.Replace([char]92, [char]47)
            Exists = $false
        }
    }
    $plan.Items = $items
    $plan.Total = $items.Count
    $plan.Tops = @(Get-ChildItem -LiteralPath $rootPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    return $plan
}

function Set-BackupFilePlanKnown {
    # marks the files the phone already has, from a list of its paths
    param($Plan, [string[]]$RemotePaths)

    $onPhone = @{}
    foreach ($path in @($RemotePaths)) {
        $text = "$path".Trim()
        if ($text -like '/sdcard/*') { $onPhone[$text] = $true }
    }
    foreach ($item in @($Plan.Items)) { $item.Exists = $onPhone.ContainsKey($item.Remote) }
    $Plan.Existing = @(@($Plan.Items) | Where-Object { $_.Exists }).Count
    return $Plan
}

function Set-BackupFilePlanState {
    # asks the phone what it has, once per top folder with find, not once per file
    param($Plan, [string]$Serial)

    if (@($Plan.Items).Count -eq 0) { return $Plan }
    $paths = @()
    foreach ($top in @($Plan.Tops)) {
        $paths += (Invoke-DeviceShell -Serial $Serial -CommandArguments @("find '/sdcard/$top' -type f 2>/dev/null")).Lines
    }
    return (Set-BackupFilePlanKnown -Plan $Plan -RemotePaths $paths)
}

function Restore-BackupFiles {
    # OnConflict: 'skip' leaves what the phone has, 'replace' writes over it.
    # Stops on Cancel and when the phone goes away, and says how far it got.
    param($Plan, [string]$Serial, [ValidateSet('skip', 'replace')][string]$OnConflict = 'skip')

    $items = @($Plan.Items)
    if ($OnConflict -eq 'skip') { $items = @($items | Where-Object { -not $_.Exists }) }
    if ($items.Count -eq 0) {
        Write-Log 'Restore: every file in the backup is already on the phone.' $colorInfo
        return [PSCustomObject]@{ Sent = 0; Failed = 0; Skipped = $Plan.Existing; Stopped = '' }
    }

    Write-Log "Restore: sending $($items.Count) file(s) ..." $colorStep
    Start-BackupRun
    $sent = 0
    $failed = 0
    $index = 0
    try {
        foreach ($item in $items) {
            if (Test-BackupStopped) { break }
            $index++
            Write-BackupProgress -Text "Files: $($item.Remote)" -Done $index -Total $items.Count
            $result = Invoke-BackupAdb -ArgumentList @('-s', $Serial, 'push', $item.Local, $item.Remote) -Caption 'Restore'
            if ($result.Stopped) { break }
            if ($result.ExitCode -eq 0) {
                $sent++
            } else {
                $failed++
                if ($failed -le 5) { Write-Log ('  ' + $result.Text) $colorWarn }
                # a phone that refuses everything is not worth ten thousand tries
                if ($failed -ge 20 -and $sent -eq 0) {
                    Stop-BackupRun -Reason 'the phone refused the first 20 files'
                    break
                }
            }
        }
    } finally {
        Complete-BackupRun
    }

    $skipped = $(if ($OnConflict -eq 'skip') { $Plan.Existing } else { 0 })
    $stopped = Get-BackupStopReason
    if ($stopped) {
        Write-Log "Restore stopped ($stopped): $sent of $($items.Count) file(s) had been sent." $colorWarn
        Send-BackupNotice -Title 'Restore stopped' -Text "$stopped. $sent file(s) were sent before it stopped."
    } else {
        Write-Log "  $sent sent, $failed refused, $skipped left as they were." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
        Send-BackupNotice -Title 'Restore done' -Text "$sent file(s) sent to $Serial, $failed refused."
    }
    Write-BackupProgress -Text $(if ($stopped) { "Restore stopped: $stopped" } else { 'Restore done' }) -Done 1 -Total 1

    # the gallery shows what it has scanned, not what is on the card
    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content call --uri content://media --method scan_volume --arg external_primary')
    return [PSCustomObject]@{ Sent = $sent; Failed = $failed; Skipped = $skipped; Stopped = $stopped }
}

function Restore-BackupApps {
    # installs the apps whose rows were picked; a split app goes in one call
    param($Rows, [string]$Serial)

    $rows = @($Rows)
    if ($rows.Count -eq 0) { return [PSCustomObject]@{ Installed = 0; Failed = 0; Stopped = '' } }
    Write-Log "Restore: installing $($rows.Count) app(s) ..." $colorStep
    Start-BackupRun

    $installed = 0
    $failed = 0
    $index = 0
    try {
        foreach ($row in $rows) {
            if (Test-BackupStopped) { break }
            $index++
            Write-BackupProgress -Text "Apps: $($row.Package)" -Done $index -Total $rows.Count

            $apks = @($row.Apks)
            $arguments = @('-s', $Serial)
            $arguments += $(if ($apks.Count -gt 1) { @('install-multiple', '-r') } else { @('install', '-r') })
            $arguments += $apks

            $result = Invoke-BackupAdb -ArgumentList $arguments -Caption "Apps: $($row.Package)"
            if ($result.Stopped) { break }
            $text = $result.Text
            if ($text -match 'Success') {
                $installed++
                Write-Log "  $($row.Package) installed." $colorGood
            } else {
                $failed++
                Write-Log ("  $($row.Package): " + $text) $colorBad
                # measured on a Xiaomi phone: it refuses every adb install until allowed
                if ($text -match 'INSTALL_FAILED_USER_RESTRICTED') {
                    Write-Log ('  The phone blocks installs over USB. On Xiaomi / Redmi / POCO turn on ' +
                        'Developer options > Install via USB, then try again.') $colorWarn
                    Stop-BackupRun -Reason 'the phone blocks installs over USB'
                    break
                }
            }
        }
    } finally {
        Complete-BackupRun
    }

    $stopped = Get-BackupStopReason
    if ($stopped) {
        Write-Log "Installing stopped ($stopped): $installed app(s) installed." $colorWarn
        Send-BackupNotice -Title 'Installing stopped' -Text "$stopped. $installed app(s) were installed."
    } else {
        Write-Log "  $installed installed, $failed refused." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
        Send-BackupNotice -Title 'Apps installed' -Text "$installed installed on $Serial, $failed refused."
    }
    Write-BackupProgress -Text $(if ($stopped) { "Installing stopped: $stopped" } else { 'Apps installed' }) -Done 1 -Total 1
    return [PSCustomObject]@{ Installed = $installed; Failed = $failed; Stopped = $stopped }
}

function Restore-BackupContacts {
    # the contacts in the backup this phone does not have, by name and number
    param([string]$Folder, [string]$Serial)

    $path = Join-Path (Join-Path "$Folder" 'personal') 'contacts.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log 'Restore: this backup holds no contacts.' $colorWarn
        return [PSCustomObject]@{ Added = 0; Failed = 0; Skipped = 0; Stopped = '' }
    }
    try {
        $contacts = @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Log ('Restore: the contacts file could not be read: ' + $_.Exception.Message) $colorBad
        return [PSCustomObject]@{ Added = 0; Failed = 0; Skipped = 0; Stopped = '' }
    }

    # what the phone has now, so no contact is added twice
    $have = @{}
    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection display_name:data1')).Text
    foreach ($row in (Split-BackupRows -Text $text)) {
        $key = ((Get-BackupRowValue -Row $row -Column 'display_name') + '|' +
            ((Get-BackupRowValue -Row $row -Column 'data1') -replace '[\s\-()]', ''))
        $have[$key.ToLowerInvariant()] = $true
    }

    Write-Log "Restore: $($contacts.Count) contact(s) in the backup ..." $colorStep
    Start-BackupRun
    $added = 0
    $failed = 0
    $skipped = 0
    $index = 0
    try {
        foreach ($contact in $contacts) {
            if (Test-BackupStopped) { break }
            $index++
            $name = "$($contact.Name)".Trim()
            $number = "$($contact.Number)".Trim()
            if (-not $number) { continue }
            $key = ($name + '|' + ($number -replace '[\s\-()]', '')).ToLowerInvariant()
            if ($have.ContainsKey($key)) { $skipped++; continue }
            Write-BackupProgress -Text "Contacts: $name" -Done $index -Total $contacts.Count

            $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
                'content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:null --bind account_type:s:null')
            if (Test-BackupDeviceGone -Text $result.Text) { Stop-BackupRun -Reason 'the phone was disconnected'; break }
            if ($result.Text -match 'Error|Exception') { $failed++; continue }
            # the row just made is the one with the highest id
            $newest = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
                "content query --uri content://com.android.contacts/raw_contacts --projection _id --sort '_id DESC' | head -1")).Text
            if ($newest -notmatch '_id=(\d+)') { $failed++; continue }
            $rawId = $Matches[1]

            # one argument each: a name has spaces, and may hold an apostrophe
            $null = Invoke-DeviceCommand -Serial $Serial -Arguments @('content', 'insert', '--uri',
                'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
                '--bind', 'mimetype:s:vnd.android.cursor.item/name', '--bind', "data1:s:$name")
            $null = Invoke-DeviceCommand -Serial $Serial -Arguments @('content', 'insert', '--uri',
                'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
                '--bind', 'mimetype:s:vnd.android.cursor.item/phone_v2', '--bind', "data1:s:$number")
            $added++
            $have[$key] = $true
        }
    } finally {
        Complete-BackupRun
    }

    $stopped = Get-BackupStopReason
    if ($stopped) {
        Write-Log "Contacts stopped ($stopped): $added contact(s) added." $colorWarn
        Send-BackupNotice -Title 'Contacts stopped' -Text "$stopped. $added contact(s) were added."
    } else {
        Write-Log "  $added added, $skipped already there, $failed refused." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
        Send-BackupNotice -Title 'Contacts restored' -Text "$added added to $Serial, $skipped were already there."
    }
    Write-BackupProgress -Text $(if ($stopped) { "Contacts stopped: $stopped" } else { 'Contacts restored' }) -Done 1 -Total 1
    return [PSCustomObject]@{ Added = $added; Failed = $failed; Skipped = $skipped; Stopped = $stopped }
}
