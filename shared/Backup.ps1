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

    A backup is one .zip file with manifest.json inside it saying what it
    holds. The files are pulled into a folder first, because that is what adb
    writes; the folder is packed and then removed, so what is kept is a single
    file to copy, to move, or to put on another drive. Already-packed things -
    photos, video, APKs - are stored as they are rather than squeezed again.

    Nothing has to be unpacked to use a backup: what is inside it is listed
    from the zip's own index, and restoring takes one file out at a time.
    Backups made before this - plain folders with manifest.json - open exactly
    the same way, and a backup whose packing was cancelled stays a folder.

    Every backup taken is written into %APPDATA%\AndroidDC\backups.json, so
    both windows can show the backups this PC has without hunting for them;
    that list holds paths, not copies, and a backup that was moved away says so
    instead of disappearing quietly.

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

# 1 was a folder of files; 2 is the same shape packed into one .zip
$script:backupFormat = 2
$script:backupListFile = if ($env:ANDROIDDC_BACKUP_LIST) { $env:ANDROIDDC_BACKUP_LIST } else {
    Join-Path $env:APPDATA 'AndroidDC\backups.json' }
$script:backupPump = ''
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

# --------------------------------------------------------------- the zip ----

function Invoke-BackupPump {
    # One turn of the window's message loop. Wait-Pumped sleeps 10 ms each
    # turn, which is right while adb runs and wrong while this thread is the
    # one working: packing a 4 GB video would spend minutes asleep.
    if (-not $script:backupPump) {
        $script:backupPump = if (Get-Command Invoke-Pump -ErrorAction SilentlyContinue) { 'nova' } else { 'forms' }
    }
    try {
        if ($script:backupPump -eq 'nova') { Invoke-Pump } else { [System.Windows.Forms.Application]::DoEvents() }
    } catch { }
}

function Initialize-BackupZip {
    # Windows PowerShell loads neither zip assembly by itself, and it takes
    # both: ZipFile and ExtractToFile come from ...Compression.FileSystem,
    # while ZipArchive and ZipArchiveMode - what writing an entry at a time
    # needs - come from ...Compression, which the first one does not drag in.
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
    }
    if (-not ('System.IO.Compression.ZipArchiveMode' -as [type])) {
        try { Add-Type -AssemblyName System.IO.Compression } catch { }
    }
    return [bool](('System.IO.Compression.ZipFile' -as [type]) -and ('System.IO.Compression.ZipArchiveMode' -as [type]))
}

function Get-BackupCompression {
    # Photos, video and APKs are packed already: packing them again costs the
    # whole backup's time and saves nothing, so they go in as they are.
    param([string]$Name)

    $packed = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif', '.mp4', '.mkv', '.mov',
        '.3gp', '.webm', '.avi', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.flac', '.wma',
        '.zip', '.apk', '.apks', '.jar', '.7z', '.rar', '.gz', '.xz', '.bz2')
    $extension = ([System.IO.Path]::GetExtension("$Name")).ToLowerInvariant()
    if ($packed -contains $extension) { return [System.IO.Compression.CompressionLevel]::NoCompression }
    return [System.IO.Compression.CompressionLevel]::Fastest
}

function Test-BackupRoom {
    # Packing needs room for a second copy at worst. Answers $true when the
    # drive has it, so a full drive is said out loud instead of half a zip.
    param([string]$Path, [long]$Needed)

    try {
        $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot((Get-Item -LiteralPath (Split-Path -Parent $Path)).FullName))
        return ($drive.AvailableFreeSpace -gt $Needed)
    } catch {
        return $true
    }
}

function Compress-BackupFolder {
    <#
        The pulled folder into one .zip. Files are copied a megabyte at a time,
        so a phone's worth of video never sits in memory, the window keeps
        drawing, and Cancel lands inside a big file as well as between two.

        A pack that fails or is stopped leaves no half zip behind: the folder
        is what is kept, and it opens as a backup just as the zip does.
    #>
    param([string]$Folder, [string]$ZipPath)

    $result = [PSCustomObject]@{ Ok = $false; Files = 0; Bytes = [long]0; Error = ''; Stopped = '' }
    if (-not (Initialize-BackupZip)) { $result.Error = 'this PowerShell has no zip support'; return $result }

    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { $result.Error = 'there is nothing to pack'; return $result }
    $needed = [long]0
    foreach ($file in $files) { $needed += $file.Length }
    if (-not (Test-BackupRoom -Path $ZipPath -Needed $needed)) {
        $result.Error = 'the drive has no room for the packed copy'
        return $result
    }

    # one spelling of the folder for both the walk and the cut - see Get-BackupFilePlan
    $rootPath = (Get-Item -LiteralPath $Folder).FullName.TrimEnd([char]92)
    $rootLength = $rootPath.Length + 1
    Write-Log ("Backup: packing $($files.Count) file(s) into " + [System.IO.Path]::GetFileName($ZipPath) + ' ...') $colorStep

    $archive = $null
    $stream = $null
    $buffer = New-Object byte[] 1048576
    # named before the try: the catch below reads it, and a failure to open the
    # zip at all happens before the loop has given it a value
    $relative = ''
    $script:busy++
    $script:busyWhat = 'packing the backup'
    try {
        $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        $index = 0
        foreach ($file in $files) {
            if (Test-BackupStopped) { break }
            $index++
            $relative = $file.FullName.Substring($rootLength).Replace([char]92, [char]47)
            Write-BackupProgress -Text "Packing: $relative" -Done $index -Total $files.Count
            Invoke-BackupPump

            $entry = $archive.CreateEntry($relative, (Get-BackupCompression -Name $file.Name))
            try { $entry.LastWriteTime = $file.LastWriteTime } catch { }
            $target = $entry.Open()
            $source = $null
            try {
                $source = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                while ($true) {
                    $read = $source.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $target.Write($buffer, 0, $read)
                    if (Test-BackupStopped) { break }
                    Invoke-BackupPump
                }
            } finally {
                if ($source) { $source.Dispose() }
                $target.Dispose()
            }
            $result.Files++
        }
    } catch {
        # a file that cannot be read stops the packing rather than being left
        # quietly out of it: the pulled folder is then what is kept, whole
        $result.Error = "$relative : " + $_.Exception.Message
    } finally {
        if ($archive) { try { $archive.Dispose() } catch { } }
        if ($stream) { try { $stream.Dispose() } catch { } }
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
    }

    if (Test-BackupStopped) { $result.Stopped = Get-BackupStopReason }
    if (-not $result.Error -and -not $result.Stopped) {
        # it is read back before the pulled files are let go of
        $count = Test-BackupArchive -Path $ZipPath
        if ($count -ne $files.Count) { $result.Error = "the packed file holds $count of $($files.Count) file(s)" }
    }
    if ($result.Error -or $result.Stopped) {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        return $result
    }

    $result.Bytes = (Get-Item -LiteralPath $ZipPath).Length
    $result.Ok = $true
    Write-Log ('  packed into ' + (Format-FileSize -Bytes $result.Bytes) +
        ' from ' + (Format-FileSize -Bytes $needed)) $colorGood
    return $result
}

function Test-BackupArchive {
    # how many files a zip really holds; -1 when it cannot be read at all
    param([string]$Path)

    if (-not (Initialize-BackupZip)) { return -1 }
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        return @($archive.Entries | Where-Object { $_.Name }).Count
    } catch {
        return -1
    } finally {
        if ($archive) { try { $archive.Dispose() } catch { } }
    }
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
    # the APK of every app the user installed, splits included, and what each
    # one is called and which version it is - asked while the phone still has
    # them, so a backup read a year later says WhatsApp, not com.whatsapp, even
    # for an app this phone no longer has
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'apps'
    $null = New-Item -ItemType Directory -Path $target -Force
    $packages = @()
    $versions = @{}
    foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'pm', 'list', 'packages', '-3', '--show-versioncode')).Lines) {
        if ("$line" -notmatch '^package:(\S+)') { continue }
        $packages += $Matches[1]
        if ("$line" -match 'versionCode:(\S+)') { $versions[$packages[-1]] = $Matches[1] }
    }
    $packages = @($packages | Sort-Object -Unique)

    # the window's own way of asking (scrcpy --list-apps); a window without it
    # still takes the backup, with packages for names
    $labels = @{}
    if (Get-Command Get-AppLabels -ErrorAction SilentlyContinue) {
        try { $labels = Get-AppLabels -Serial $Serial } catch { $labels = @{} }
    }
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
        $apps += [PSCustomObject]@{
            Package = $package
            Name    = $(if ($labels.ContainsKey($package)) { "$($labels[$package])" } else { '' })
            Version = $(if ($versions.ContainsKey($package)) { "$($versions[$package])" } else { '' })
            Files   = @($saved)
            Bytes   = (Get-BackupFolderSize -Path $appFolder)
        }
    }

    # beside the APKs, so what each one is stays with them even if the manifest
    # is read by something older than this
    Save-BackupText -Path (Join-Path $target 'apps.json') -Text (ConvertTo-Json -InputObject @($apps) -Depth 4)
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
    # the folder is where adb pulls; the .zip beside it is what is kept
    $name = ConvertTo-BackupName -Model $Model -Serial $Serial -When $started
    $folder = Join-Path $Destination $name
    $zipPath = Join-Path $Destination ($name + '.zip')
    $null = New-Item -ItemType Directory -Path $folder -Force
    Write-Log "Backup of $Serial into $zipPath" $colorStep
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

    # the packing is inside the run, so Cancel still works while it packs
    $path = $folder
    $kind = 'folder'
    $packed = $null
    try {
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
        }

        if ($manifest.Complete) {
            $packed = Compress-BackupFolder -Folder $folder -ZipPath $zipPath
            if ($packed.Ok) {
                $path = $zipPath
                $kind = 'zip'
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
            } elseif ($packed.Stopped) {
                Write-Log "  Packing was stopped ($($packed.Stopped)); the files are kept in the folder." $colorWarn
            } else {
                Write-Log "  It could not be packed ($($packed.Error)); the files are kept in the folder." $colorWarn
            }
        }
    } finally {
        Complete-BackupRun
    }

    $minutes = ([datetime]::Now - $started).TotalMinutes
    $size = Format-FileSize -Bytes $manifest.Bytes
    $where = [System.IO.Path]::GetFileName($path)
    if ($manifest.Complete) {
        $packedSize = if ($packed -and $packed.Ok) { ', ' + (Format-FileSize -Bytes $packed.Bytes) + ' packed' } else { '' }
        Write-Log ("Backup done: $size$packedSize" + (' in {0:N1} minute(s).' -f $minutes)) $colorGood
        Send-BackupNotice -Title 'Backup done' -Text "$size from $Serial is in $where."
    } else {
        Write-Log ("Backup stopped ($($manifest.Stopped)) after $size" + (' and {0:N1} minute(s).' -f $minutes)) $colorWarn
        Write-Log '  What was already pulled is kept, and the manifest says this backup is not complete.' $colorInfo
        Send-BackupNotice -Title 'Backup stopped' -Text "$($manifest.Stopped). $size was kept in $where."
    }
    Write-BackupProgress -Text $(if ($manifest.Complete) { 'Backup done' } else { "Backup stopped: $($manifest.Stopped)" }) -Done 1 -Total 1

    $result = [PSCustomObject]$manifest
    Add-Member -InputObject $result -NotePropertyName 'Path' -NotePropertyValue $path -Force
    Add-Member -InputObject $result -NotePropertyName 'Kind' -NotePropertyValue $kind -Force
    # the backups list looks where the last backup was put
    $null = Set-BackupFolderPath -Folder $Destination
    return $result
}

# ---------------------------------------------------------- opening one ----

function Open-BackupSource {
    <#
        A backup to read from: the .zip a backup is now, or the folder older
        ones were. Answers $null when neither holds a manifest.json, which is
        what makes a folder or a zip a backup - never its name.

        Only the manifest is read here, so opening a backup of forty thousand
        photos is as quick as opening one of ten. The list of what is in it is
        read when something asks for it, by Get-BackupSourceEntries, and kept
        afterwards.
    #>
    param([Alias('Folder')][string]$Path, [switch]$WithEntries)

    if (-not "$Path" -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $full = (Get-Item -LiteralPath $Path).FullName
    $source = [PSCustomObject]@{
        Path     = $full
        Kind     = 'folder'
        Name     = [System.IO.Path]::GetFileName($full)
        Manifest = $null
        # $null until read; an empty list is a backup with nothing in it
        Entries  = $null
        Bytes    = [long]0
        Packed   = [long]0
    }

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if (-not (Initialize-BackupZip)) { return $null }
        $source.Kind = 'zip'
        $source.Packed = (Get-Item -LiteralPath $full).Length
        $text = ''
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($full)
            # GetEntry, not a walk: the manifest is found by name in the index
            $entry = $archive.GetEntry('manifest.json')
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } catch {
            return $null
        } finally {
            if ($archive) { try { $archive.Dispose() } catch { } }
        }
        if (-not $text) { return $null }
        try { $source.Manifest = ($text | ConvertFrom-Json) } catch { return $null }
    } else {
        $manifestPath = Join-Path $full 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
        try { $source.Manifest = (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }

    if ($source.Manifest.PSObject.Properties['Bytes']) { $source.Bytes = [long]$source.Manifest.Bytes }
    if ($WithEntries) { $null = Get-BackupSourceEntries -Source $source }
    return $source
}

function Get-BackupSourceEntries {
    <#
        Every file in a backup, named the way the zip names them -
        files/Pictures/one.jpg - whichever kind it is, so everything else reads
        one shape. Read once and kept on the source.

        Built into a List, never with +=: an array grows by copying itself, and
        a backup of thirty thousand files spent minutes on that alone, with the
        window frozen and nothing to look at.
    #>
    param($Source)

    if ($null -eq $Source) { return @() }
    if ($null -ne $Source.Entries) { return $Source.Entries }

    $entries = New-Object System.Collections.Generic.List[object]
    $script:busy++
    $script:busyWhat = 'reading the backup'
    try {
        if ($Source.Kind -eq 'zip') {
            if (-not (Initialize-BackupZip)) { $Source.Entries = $entries; return $entries }
            $archive = $null
            try {
                $archive = [System.IO.Compression.ZipFile]::OpenRead($Source.Path)
                foreach ($entry in $archive.Entries) {
                    # a folder is an entry with no name of its own
                    if (-not $entry.Name) { continue }
                    $null = $entries.Add([PSCustomObject]@{ Path = $entry.FullName; Bytes = [long]$entry.Length })
                    if (($entries.Count % 2000) -eq 0) {
                        Write-BackupProgress -Text "Reading the backup: $($entries.Count) file(s) ..." -Done -1 -Total -1
                        Invoke-BackupPump
                    }
                }
            } catch {
                Write-Log ('The backup could not be read: ' + $_.Exception.Message) $colorBad
            } finally {
                if ($archive) { try { $archive.Dispose() } catch { } }
            }
        } else {
            $rootPath = "$($Source.Path)".TrimEnd([char]92)
            $rootLength = $rootPath.Length + 1
            foreach ($file in (Get-ChildItem -LiteralPath $rootPath -Recurse -File -ErrorAction SilentlyContinue)) {
                $null = $entries.Add([PSCustomObject]@{
                    Path  = $file.FullName.Substring($rootLength).Replace([char]92, [char]47)
                    Bytes = [long]$file.Length
                })
                if (($entries.Count % 2000) -eq 0) {
                    Write-BackupProgress -Text "Reading the backup: $($entries.Count) file(s) ..." -Done -1 -Total -1
                    Invoke-BackupPump
                }
            }
        }
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
    }

    $total = [long]0
    foreach ($entry in $entries) { $total += $entry.Bytes }
    # handed out as a plain array: a List is what it was built in, for speed,
    # but @($list) on a List[object] throws inside the running window
    $Source.Entries = $entries.ToArray()
    if ($total -gt 0) { $Source.Bytes = $total }
    Write-BackupProgress -Text "$($entries.Count) file(s) in this backup" -Done 1 -Total 1
    return $entries
}

function ConvertTo-BackupSource {
    # each of the functions below takes either an opened backup or its path
    param($Source)

    if ($null -eq $Source) { return $null }
    if ($Source -is [string]) { return (Open-BackupSource -Path $Source) }
    return $Source
}

function Read-BackupManifest {
    # what a backup says about itself, or $null when that path is not one
    param([Alias('Folder')][string]$Path)

    $source = Open-BackupSource -Path $Path
    if ($null -eq $source) { return $null }
    return $source.Manifest
}

function Get-BackupEntryPath {
    # where an entry of a folder backup is on this PC; nothing, for a zip
    param($Source, [string]$Entry)

    if ($Source.Kind -ne 'folder') { return '' }
    return (Join-Path $Source.Path ("$Entry".Replace([char]47, [char]92)))
}

function Open-BackupArchive {
    # one open zip for a whole loop: opening it per file reads its index again
    param($Source)

    if ($null -eq $Source -or $Source.Kind -ne 'zip') { return $null }
    if (-not (Initialize-BackupZip)) { return $null }
    try { return [System.IO.Compression.ZipFile]::OpenRead($Source.Path) } catch { return $null }
}

function Close-BackupArchive {
    param($Archive)

    if ($Archive) { try { $Archive.Dispose() } catch { } }
}

function Export-BackupEntry {
    # one file out of a backup onto this PC; $true when it landed
    param($Source, [string]$Entry, [string]$Destination, $Archive = $null)

    $folder = Split-Path -Parent $Destination
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

    if ($Source.Kind -eq 'folder') {
        $from = Get-BackupEntryPath -Source $Source -Entry $Entry
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { return $false }
        try { Copy-Item -LiteralPath $from -Destination $Destination -Force; return $true } catch { return $false }
    }

    $own = $null
    if (-not $Archive) { $own = Open-BackupArchive -Source $Source; $Archive = $own }
    if (-not $Archive) { return $false }
    try {
        $item = $Archive.GetEntry($Entry)
        if (-not $item) { return $false }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item, $Destination, $true)
        return $true
    } catch {
        return $false
    } finally {
        if ($own) { Close-BackupArchive -Archive $own }
    }
}

function Get-BackupEntryText {
    # a text file inside a backup - the manifest, the contacts - as one string
    param($Source, [string]$Entry, $Archive = $null)

    if ($null -eq $Source) { return '' }
    if ($Source.Kind -eq 'folder') {
        $path = Get-BackupEntryPath -Source $Source -Entry $Entry
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8) } catch { return '' }
    }

    $own = $null
    if (-not $Archive) { $own = Open-BackupArchive -Source $Source; $Archive = $own }
    if (-not $Archive) { return '' }
    try {
        $item = $Archive.GetEntry($Entry)
        if (-not $item) { return '' }
        $reader = New-Object System.IO.StreamReader($item.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } catch {
        return ''
    } finally {
        if ($own) { Close-BackupArchive -Archive $own }
    }
}

function Get-BackupTempFolder {
    # where a file is unpacked to on its way to the phone, and cleared after
    $path = Join-Path $env:TEMP 'AndroidDC-restore'
    if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType Directory -Path $path -Force }
    return $path
}

# ------------------------------------------------------ what is inside it ----

function Get-BackupEntryWhat {
    # which part of the backup an entry belongs to
    param([string]$Entry)

    if ("$Entry" -like 'files/*') { return 'Files' }
    if ("$Entry" -like 'apps/*') { return 'Apps' }
    if ("$Entry" -like 'personal/*') { return 'Personal' }
    if ("$Entry" -like 'settings/*') { return 'Settings' }
    return 'Backup'
}

function Get-BackupEntryWhere {
    # where that file was on the phone, when it came from one
    param([string]$Entry)

    if ("$Entry" -like 'files/*') { return '/sdcard/' + "$Entry".Substring(6) }
    return "$Entry"
}

function Get-BackupInsideRows {
    <#
        What a backup holds, to read before anything is put back: which part
        each file belongs to, where it was on the phone, and how big it is.
        Nothing is unpacked - a zip says all of this in its own index.

        Filter is plain text matched anywhere in the path, not a wildcard.
        Limit stops at that many rows: a list control cannot show forty
        thousand without a pause, and the find box is what reaches the rest.
        The order is the order the backup was taken in - files, then apps,
        then the rest - which is already the order a person looks for them in.
    #>
    param($Source, [string]$Filter = '', [int]$Limit = 0)

    $source = ConvertTo-BackupSource -Source $Source
    if ($null -eq $source) { return [PSCustomObject]@{ Rows = @(); Total = 0; Bytes = [long]0 } }
    $entries = Get-BackupSourceEntries -Source $source

    $text = "$Filter".Trim()
    $rows = New-Object System.Collections.Generic.List[object]
    $total = 0
    $bytes = [long]0
    foreach ($entry in $entries) {
        $where = Get-BackupEntryWhere -Entry $entry.Path
        if ($text -and $where.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $total++
        $bytes += $entry.Bytes
        if ($Limit -gt 0 -and $rows.Count -ge $Limit) { continue }
        $null = $rows.Add([PSCustomObject]@{
            What  = (Get-BackupEntryWhat -Entry $entry.Path)
            Path  = $where
            Size  = (Format-FileSize -Bytes $entry.Bytes)
            Bytes = $entry.Bytes
            Entry = $entry.Path
        })
    }
    return [PSCustomObject]@{ Rows = $rows.ToArray(); Total = $total; Bytes = $bytes }
}

function Save-BackupCopy {
    # files out of a backup onto this PC, in the folders they were in, without
    # a phone anywhere near it
    param($Source, [string[]]$Entries, [string]$Destination)

    $source = ConvertTo-BackupSource -Source $Source
    $list = @(@($Entries) | Where-Object { $_ })
    $result = [PSCustomObject]@{ Saved = 0; Failed = 0 }
    if ($null -eq $source -or $list.Count -eq 0) { return $result }
    if (-not (Test-Path -LiteralPath $Destination)) { $null = New-Item -ItemType Directory -Path $Destination -Force }

    Write-Log "Saving $($list.Count) file(s) out of $($source.Name) ..." $colorStep
    $archive = Open-BackupArchive -Source $source
    try {
        $index = 0
        foreach ($entry in $list) {
            $index++
            Write-BackupProgress -Text "Saving: $entry" -Done $index -Total $list.Count
            Invoke-BackupPump
            $target = Join-Path $Destination ("$entry".Replace([char]47, [char]92))
            if (Export-BackupEntry -Source $source -Entry $entry -Destination $target -Archive $archive) {
                $result.Saved++
            } else {
                $result.Failed++
            }
        }
    } finally {
        Close-BackupArchive -Archive $archive
    }
    Write-Log "  $($result.Saved) saved to $Destination, $($result.Failed) could not be read." `
        $(if ($result.Failed -gt 0) { $colorWarn } else { $colorGood })
    Write-BackupProgress -Text "$($result.Saved) file(s) saved" -Done 1 -Total 1
    return $result
}

function Get-BackupSummaryLines {
    # what a backup holds, in words, to show before anything is put back. It
    # reads the manifest only, so it never waits for the whole index.
    param($Manifest, $Source = $null)

    if ($null -eq $Manifest) { return @('Not a backup: it holds no manifest.json.') }
    $lines = @("$($Manifest.Model) ($($Manifest.Serial)), Android $($Manifest.Android), taken " +
        (("$($Manifest.Created)" -replace 'T', ' ')))
    if ($Manifest.PSObject.Properties['Bytes']) { $lines += 'Size: ' + (Format-FileSize -Bytes ([long]$Manifest.Bytes)) }
    if ($Source -and $Source.Kind -eq 'zip') {
        $lines += 'Packed: ' + (Format-FileSize -Bytes ([long]$Source.Packed)) + ' in one .zip'
    } elseif ($Source) {
        $lines += 'Kept as a folder, not packed'
    }
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

# --------------------------------------------------------------- restoring ----

function Get-BackupAppNotes {
    # what the backup wrote down about its apps: the name each one had and the
    # version it was. Older backups have neither, and say so by saying nothing.
    param($Source, $Archive = $null)

    $notes = @{}
    $text = Get-BackupEntryText -Source $Source -Entry 'apps/apps.json' -Archive $Archive
    if (-not $text) { return $notes }
    try {
        $read = ($text | ConvertFrom-Json)
    } catch {
        return $notes
    }
    foreach ($row in @($read)) {
        if ($null -eq $row -or $null -eq $row.PSObject.Properties['Package']) { continue }
        $notes["$($row.Package)"] = $row
    }
    return $notes
}

function Get-BackupAppState {
    <#
        What putting this app back would mean, in words a person can act on:

          not on the phone   installing it puts it back
          on the phone       the same version is there already
          older on the phone installing it would bring the phone up to the
                             backup's version
          newer on the phone the phone has moved on; installing the backup's
                             version would be a downgrade, which Android
                             refuses unless the app is removed first

        With no phone picked there is nothing to compare against, and it says
        that rather than calling every app missing.
    #>
    param([string]$Serial, [bool]$Installed, [string]$Backup, [string]$Phone)

    if (-not $Serial) { return 'no phone to compare' }
    if (-not $Installed) { return 'not on the phone' }
    $ours = 0
    $theirs = 0
    if ([int]::TryParse("$Backup", [ref]$ours) -and [int]::TryParse("$Phone", [ref]$theirs)) {
        if ($ours -gt $theirs) { return 'older on the phone' }
        if ($ours -lt $theirs) { return 'newer on the phone' }
    }
    return 'on the phone'
}

function Get-BackupAppRows {
    <#
        The apps in a backup: what each is called, which version the backup
        holds, how big it is, and how it stands against the phone. Sorted with
        the ones the phone does not have first, because those are the ones
        anything is done about.
    #>
    param([Alias('Folder')]$Source, [string]$Serial = '')

    $source = ConvertTo-BackupSource -Source $Source
    if ($null -eq $source) { return @() }
    $entries = Get-BackupSourceEntries -Source $source
    $notes = Get-BackupAppNotes -Source $source

    $installed = @{}
    $labels = @{}
    if ($Serial) {
        foreach ($line in (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'pm', 'list', 'packages', '--show-versioncode')).Lines) {
            if ("$line" -notmatch '^package:(\S+)') { continue }
            $package = $Matches[1]
            $installed[$package] = $(if ("$line" -match 'versionCode:(\S+)') { $Matches[1] } else { '' })
        }
        # the names the phone knows, for a backup taken before names were kept
        if (Get-Command Get-AppLabels -ErrorAction SilentlyContinue) {
            try { $labels = Get-AppLabels -Serial $Serial } catch { $labels = @{} }
        }
    }

    $byPackage = @{}
    foreach ($entry in $entries) {
        if ($entry.Path -notmatch '^apps/([^/]+)/[^/]+\.apk$') { continue }
        $package = $Matches[1]
        if (-not $byPackage.ContainsKey($package)) { $byPackage[$package] = (New-Object System.Collections.Generic.List[object]) }
        $null = $byPackage[$package].Add($entry)
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($byPackage.Keys | Sort-Object)) {
        # the base APK goes first: install-multiple takes it before its splits
        $apkEntries = @($byPackage[$package] | Sort-Object { $_.Path -notmatch '/base[^/]*\.apk$' }, Path)
        $bytes = [long]0
        foreach ($entry in $apkEntries) { $bytes += $entry.Bytes }
        $apks = @()
        if ($source.Kind -eq 'folder') {
            $apks = @($apkEntries | ForEach-Object { Get-BackupEntryPath -Source $source -Entry $_.Path })
        }

        $name = ''
        $version = ''
        if ($notes.ContainsKey($package)) {
            if ($null -ne $notes[$package].PSObject.Properties['Name']) { $name = "$($notes[$package].Name)" }
            if ($null -ne $notes[$package].PSObject.Properties['Version']) { $version = "$($notes[$package].Version)" }
        }
        if (-not $name -and $labels.ContainsKey($package)) { $name = "$($labels[$package])" }
        $onPhone = $installed.ContainsKey($package)
        $phoneVersion = $(if ($onPhone) { "$($installed[$package])" } else { '' })

        $null = $rows.Add([PSCustomObject]@{
            Package = $package
            Name    = $name
            # what to show where there is no name: the package says more than a blank
            Shown   = $(if ($name) { $name } else { $package })
            Version = $version
            Phone   = $phoneVersion
            Parts   = $(if ($apkEntries.Count -gt 1) { "$($apkEntries.Count) files" } else { 'one file' })
            Entries = @($apkEntries | ForEach-Object { $_.Path })
            Apks    = $apks
            Size    = (Format-FileSize -Bytes $bytes)
            Bytes   = $bytes
            State   = (Get-BackupAppState -Serial $Serial -Installed $onPhone -Backup $version -Phone $phoneVersion)
        })
    }
    # what the phone lacks first: those are the ones a person came here for
    return @($rows | Sort-Object @{ Expression = { $_.State -ne 'not on the phone' } }, Shown)
}

function Get-BackupFilePlan {
    <#
        What restoring the files would do: every file in the backup and where
        it goes on the phone. Nothing is asked of the phone here, so this can
        be read on its own; Set-BackupFilePlanState marks what is already there.
    #>
    param([Alias('Folder')]$Source)

    $source = ConvertTo-BackupSource -Source $Source
    $plan = [PSCustomObject]@{ Total = 0; Existing = 0; Items = @(); Tops = @(); Source = $source }
    if ($null -eq $source) { return $plan }
    $entries = Get-BackupSourceEntries -Source $source

    $items = New-Object System.Collections.Generic.List[object]
    $tops = @{}
    foreach ($entry in $entries) {
        if ($entry.Path -notlike 'files/*') { continue }
        $relative = $entry.Path.Substring(6)
        if (-not $relative) { continue }
        $tops[($relative -split '/')[0]] = $true
        $null = $items.Add([PSCustomObject]@{
            Entry  = $entry.Path
            # a folder backup pushes the file where it lies; a zip unpacks it first
            Local  = (Get-BackupEntryPath -Source $source -Entry $entry.Path)
            Remote = '/sdcard/' + $relative
            Bytes  = $entry.Bytes
            Exists = $false
        })
        if (($items.Count % 2000) -eq 0) {
            Write-BackupProgress -Text "Reading the backup: $($items.Count) file(s) ..." -Done -1 -Total -1
            Invoke-BackupPump
        }
    }
    $plan.Items = $items.ToArray()
    $plan.Total = $items.Count
    $plan.Tops = @($tops.Keys | Sort-Object)
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
    # A zip is not unpacked whole: one file is taken out, sent, and dropped.
    param($Plan, [string]$Serial, [ValidateSet('skip', 'replace')][string]$OnConflict = 'skip')

    $items = @($Plan.Items)
    if ($OnConflict -eq 'skip') { $items = @($items | Where-Object { -not $_.Exists }) }
    if ($items.Count -eq 0) {
        Write-Log 'Restore: every file in the backup is already on the phone.' $colorInfo
        return [PSCustomObject]@{ Sent = 0; Failed = 0; Skipped = $Plan.Existing; Stopped = '' }
    }

    $source = $null
    if ($Plan.PSObject.Properties['Source']) { $source = $Plan.Source }
    $archive = Open-BackupArchive -Source $source
    $temp = ''
    if ($archive) { $temp = Get-BackupTempFolder }

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

            $local = "$($item.Local)"
            $unpacked = ''
            if (-not $local) {
                $unpacked = Join-Path $temp ("$index-" + [System.IO.Path]::GetFileName($item.Remote))
                if (-not (Export-BackupEntry -Source $source -Entry $item.Entry -Destination $unpacked -Archive $archive)) {
                    $failed++
                    Write-Log "  $($item.Entry) could not be read out of the backup." $colorWarn
                    continue
                }
                $local = $unpacked
            }

            $result = Invoke-BackupAdb -ArgumentList @('-s', $Serial, 'push', $local, $item.Remote) -Caption 'Restore'
            if ($unpacked) { Remove-Item -LiteralPath $unpacked -Force -ErrorAction SilentlyContinue }
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
        Close-BackupArchive -Archive $archive
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
    # installs the apps whose rows were picked; a split app goes in one call.
    # Source is needed for a zip: its APKs are taken out one app at a time.
    param($Rows, [string]$Serial, $Source = $null)

    $rows = @($Rows)
    if ($rows.Count -eq 0) { return [PSCustomObject]@{ Installed = 0; Failed = 0; Stopped = '' } }
    $source = ConvertTo-BackupSource -Source $Source
    $archive = Open-BackupArchive -Source $source
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

            $apks = @(@($row.Apks) | Where-Object { $_ })
            $unpacked = ''
            if ($apks.Count -eq 0 -and $source -and $row.PSObject.Properties['Entries']) {
                $unpacked = Join-Path (Get-BackupTempFolder) "$($row.Package)"
                foreach ($entry in @($row.Entries)) {
                    $target = Join-Path $unpacked ([System.IO.Path]::GetFileName($entry))
                    if (Export-BackupEntry -Source $source -Entry $entry -Destination $target -Archive $archive) { $apks += $target }
                }
            }
            if ($apks.Count -eq 0) {
                $failed++
                Write-Log "  $($row.Package): its APK could not be read out of the backup." $colorBad
                continue
            }

            $arguments = @('-s', $Serial)
            $arguments += $(if ($apks.Count -gt 1) { @('install-multiple', '-r') } else { @('install', '-r') })
            $arguments += $apks

            $result = Invoke-BackupAdb -ArgumentList $arguments -Caption "Apps: $($row.Package)"
            if ($unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue }
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
                # what the list calls "newer on the phone", said again where it happens
                if ($text -match 'INSTALL_FAILED_VERSION_DOWNGRADE') {
                    Write-Log ('  The phone already has a newer version of this app, and Android will not ' +
                        'put an older one over it. Remove the app on the phone first if you want the ' +
                        "backup's version back.") $colorWarn
                }
                if ($text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
                    Write-Log ('  The app on the phone was signed by someone else - a different build of ' +
                        'the same app. Remove the one on the phone first, and its data goes with it.') $colorWarn
                }
            }
        }
    } finally {
        Close-BackupArchive -Archive $archive
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
    param([Alias('Folder')]$Source, [string]$Serial)

    $source = ConvertTo-BackupSource -Source $Source
    $text = Get-BackupEntryText -Source $source -Entry 'personal/contacts.json'
    if (-not $text) {
        Write-Log 'Restore: this backup holds no contacts.' $colorWarn
        return [PSCustomObject]@{ Added = 0; Failed = 0; Skipped = 0; Stopped = '' }
    }
    try {
        # assigned first, wrapped after: ConvertFrom-Json hands a list back as
        # one array object, and @(a pipe of it) is a list holding that array
        $read = ($text | ConvertFrom-Json)
        $contacts = @($read)
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

# -------------------------------------------------- where your backups are ----
# One folder to look in, kept in %APPDATA%\AndroidDC\backups.json so both
# windows show the same one. Nothing about a backup is remembered here: what
# is listed is what is in that folder at the moment it is read, so a backup
# moved into it appears and one taken out of it is gone, with nothing to tidy.

function Get-BackupListFile {
    return $script:backupListFile
}

function Get-BackupFolderPath {
    # the folder the backups list shows; empty until a backup is taken or one
    # is picked
    $path = Get-BackupListFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $data = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return ''
    }
    if ($null -eq $data) { return '' }
    if ($null -ne $data.PSObject.Properties['Folder']) { return "$($data.Folder)" }

    # a file written by the version that kept a list of the backups taken: the
    # folder the newest of them was put in is the one to look in
    foreach ($row in @($data)) {
        if ($null -eq $row -or $null -eq $row.PSObject.Properties['Path']) { continue }
        $parent = Split-Path -Parent "$($row.Path)"
        if ($parent) { return $parent }
    }
    return ''
}

function Set-BackupFolderPath {
    param([string]$Folder)

    $path = Get-BackupListFile
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    Save-BackupText -Path $path -Text (ConvertTo-Json -InputObject ([ordered]@{ Folder = "$Folder" }) -Depth 3)
    return "$Folder"
}

function Get-BackupPartWords {
    # what a backup holds, in a few words for a list column
    param($Parts)

    $short = @{ files = 'files'; apps = 'apps'; personal = 'contacts'; settings = 'settings' }
    $words = @()
    foreach ($part in @($Parts)) {
        $id = "$part"
        $words += $(if ($short.ContainsKey($id)) { $short[$id] } else { $id })
    }
    if ($words.Count -eq 0) { return '' }
    return ($words -join ', ')
}

function Get-BackupsInFolder {
    <#
        The backups in a folder, newest first: every .zip that holds a
        manifest.json, and every folder beside them that holds one, which is
        what a backup taken before they were packed looks like.

        Only the manifest of each is read, never its whole index, so a folder
        of twenty backups lists at once.
    #>
    param([string]$Folder)

    $rows = New-Object System.Collections.Generic.List[object]
    if (-not "$Folder" -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-ChildItem -LiteralPath $Folder -Filter *.zip -File -ErrorAction SilentlyContinue)) {
        $null = $paths.Add($file.FullName)
    }
    foreach ($directory in (Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'manifest.json') -PathType Leaf) {
            $null = $paths.Add($directory.FullName)
        }
    }

    foreach ($path in $paths) {
        $source = Open-BackupSource -Path $path
        if ($null -eq $source) { continue }
        $manifest = $source.Manifest
        $size = $source.Packed
        if ($source.Kind -eq 'folder') { $size = $source.Bytes }
        $complete = $true
        if ($manifest.PSObject.Properties['Complete']) { $complete = [bool]$manifest.Complete }
        $null = $rows.Add([PSCustomObject]@{
            Path  = $source.Path
            Name  = $source.Name
            Kind  = $source.Kind
            When  = (("$($manifest.Created)") -replace 'T', ' ')
            Phone = (("$($manifest.Model) ($($manifest.Serial))").Trim())
            Holds = (Get-BackupPartWords -Parts $manifest.Parts)
            Size  = (Format-FileSize -Bytes ([long]$size))
            Bytes = [long]$size
            State = $(if ($complete) { 'complete' } else { 'stopped part way' })
        })
    }
    return @($rows | Sort-Object -Property When -Descending)
}
