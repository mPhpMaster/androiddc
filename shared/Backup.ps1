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

    Dot-sourced by androiddc.ps1 and nova\androiddc-nova.ps1. Nothing here
    touches a control: each window passes a progress script block, and decides
    what to ask before files already on the phone are written over.
#>

$script:backupFormat = 1
$script:backupProgress = $null
# a whole phone is minutes, not seconds; adb's own calls keep their timeout
$script:backupTimeoutMs = 7200000

function Initialize-Backup {
    # Progress: param($Text, $Done, $Total); $Done and $Total are -1 when unknown
    param([scriptblock]$Progress)
    $script:backupProgress = $Progress
}

function Write-BackupProgress {
    param([string]$Text, [int]$Done = -1, [int]$Total = -1)
    if ($script:backupProgress) { try { & $script:backupProgress $Text $Done $Total } catch { } }
}

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
    # /sdcard onto the PC, one top-level folder at a time so the log says where it is
    param([string]$Serial, [string]$Folder)

    $target = Join-Path $Folder 'files'
    $null = New-Item -ItemType Directory -Path $target -Force
    $entries = @(Get-BackupStorageEntries -Serial $Serial)
    Write-Log "Backup: $($entries.Count) folder(s) of internal storage ..." $colorStep

    $index = 0
    $refused = @()
    foreach ($entry in $entries) {
        $index++
        Write-BackupProgress -Text "Files: $entry" -Done $index -Total $entries.Count
        Write-Log "  pulling /sdcard/$entry ..." $colorInfo
        $local = Join-Path $target ($entry -replace '/', '\')
        $parent = Split-Path -Parent $local
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'pull', '-a', "/sdcard/$entry", $local) -TimeoutMs $script:backupTimeoutMs
        if ($result.ExitCode -ne 0) {
            $refused += $entry
            Write-Log ('  ' + $result.Text.Trim()) $colorWarn
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
            $name = [System.IO.Path]::GetFileName($path)
            $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'pull', $path, (Join-Path $appFolder $name)) -TimeoutMs $script:backupTimeoutMs
            if ($result.ExitCode -eq 0) { $saved += $name } else { Write-Log ("  $package : " + $result.Text.Trim()) $colorWarn }
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
    foreach ($row in (Split-BackupRows -Text $text)) {
        $number = Get-BackupRowValue -Row $row -Column 'data1'
        if (-not $number) { continue }
        $contacts += [PSCustomObject]@{ Name = (Get-BackupRowValue -Row $row -Column 'display_name'); Number = $number }
    }
    Save-BackupText -Path (Join-Path $target 'contacts.json') -Text (ConvertTo-Json -InputObject @($contacts) -Depth 3)

    Write-BackupProgress -Text 'Messages ...' -Done 2 -Total 3
    $messages = @()
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

    Write-BackupProgress -Text 'Call log ...' -Done 3 -Total 3
    $calls = @()
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
        $index++
        Write-BackupProgress -Text "Settings: $($read.File)" -Done $index -Total ($reads.Count + 1)
        Save-BackupText -Path (Join-Path $target $read.File) -Text (Invoke-DeviceShell -Serial $Serial -CommandArguments $read.Command).Text
        $written += $read.File
    }

    Write-BackupProgress -Text 'Settings: the device report' -Done ($reads.Count + 1) -Total ($reads.Count + 1)
    # the Overview page's report, when this window has it
    if (Get-Command Get-DeviceReport -ErrorAction SilentlyContinue) {
        Save-BackupText -Path (Join-Path $target 'device.txt') -Text (Get-DeviceReport -Serial $Serial)
        $written += 'device.txt'
    }
    Write-Log ('  ' + ($written -join ', ')) $colorGood
    return $written
}

function Invoke-PhoneBackup {
    <#
        One backup into a new folder under Destination. Parts are ids from
        Get-BackupParts. Returns the manifest, or $null when nothing was taken.
    #>
    param([string]$Serial, [string]$Destination, [string[]]$Parts, [string]$Model = '')

    $wanted = @(@($Parts) | Where-Object { $_ })
    if ($wanted.Count -eq 0) { Write-Log 'Backup: nothing was ticked.' $colorWarn; return $null }
    if (-not (Test-Path -LiteralPath $Destination)) { $null = New-Item -ItemType Directory -Path $Destination -Force }

    $started = [datetime]::Now
    $folder = Join-Path $Destination (ConvertTo-BackupName -Model $Model -Serial $Serial -When $started)
    $null = New-Item -ItemType Directory -Path $folder -Force
    Write-Log "Backup of $Serial into $folder" $colorStep

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
        Finished = ''
    }

    if ($wanted -contains 'files') { $manifest.Files = Backup-PhoneFiles -Serial $Serial -Folder $folder }
    if ($wanted -contains 'apps') { $manifest.Apps = @(Backup-PhoneApps -Serial $Serial -Folder $folder) }
    if ($wanted -contains 'personal') { $manifest.Personal = Backup-PhonePersonal -Serial $Serial -Folder $folder }
    if ($wanted -contains 'settings') { $manifest.Settings = @(Backup-PhoneSettings -Serial $Serial -Folder $folder) }

    $manifest.Bytes = Get-BackupFolderSize -Path $folder
    $manifest.Finished = ([datetime]::Now).ToString('s')
    Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -InputObject $manifest -Depth 6)

    $minutes = ([datetime]::Now - $started).TotalMinutes
    Write-Log ('Backup done: ' + (Format-FileSize -Bytes $manifest.Bytes) + (' in {0:N1} minute(s).' -f $minutes)) $colorGood
    Write-BackupProgress -Text 'Backup done' -Done 1 -Total 1
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
    # OnConflict: 'skip' leaves what the phone has, 'replace' writes over it
    param($Plan, [string]$Serial, [ValidateSet('skip', 'replace')][string]$OnConflict = 'skip')

    $items = @($Plan.Items)
    if ($OnConflict -eq 'skip') { $items = @($items | Where-Object { -not $_.Exists }) }
    if ($items.Count -eq 0) {
        Write-Log 'Restore: every file in the backup is already on the phone.' $colorInfo
        return [PSCustomObject]@{ Sent = 0; Failed = 0; Skipped = $Plan.Existing }
    }

    Write-Log "Restore: sending $($items.Count) file(s) ..." $colorStep
    $sent = 0
    $failed = 0
    $index = 0
    foreach ($item in $items) {
        $index++
        if (($index % 25) -eq 1 -or $index -eq $items.Count) {
            Write-BackupProgress -Text "Files: $($item.Remote)" -Done $index -Total $items.Count
        }
        $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'push', $item.Local, $item.Remote) -TimeoutMs $script:backupTimeoutMs
        if ($result.ExitCode -eq 0) {
            $sent++
        } else {
            $failed++
            if ($failed -le 5) { Write-Log ('  ' + $result.Text.Trim()) $colorWarn }
        }
    }

    $skipped = $(if ($OnConflict -eq 'skip') { $Plan.Existing } else { 0 })
    Write-Log "  $sent sent, $failed refused, $skipped left as they were." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
    # the gallery shows what it has scanned, not what is on the card
    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content call --uri content://media --method scan_volume --arg external_primary')
    return [PSCustomObject]@{ Sent = $sent; Failed = $failed; Skipped = $skipped }
}

function Restore-BackupApps {
    # installs the apps whose rows were picked; a split app goes in one call
    param($Rows, [string]$Serial)

    $rows = @($Rows)
    if ($rows.Count -eq 0) { return [PSCustomObject]@{ Installed = 0; Failed = 0 } }
    Write-Log "Restore: installing $($rows.Count) app(s) ..." $colorStep

    $installed = 0
    $failed = 0
    $index = 0
    foreach ($row in $rows) {
        $index++
        Write-BackupProgress -Text "Apps: $($row.Package)" -Done $index -Total $rows.Count
        $apks = @($row.Apks)
        $arguments = @('-s', $Serial)
        $arguments += $(if ($apks.Count -gt 1) { @('install-multiple', '-r') } else { @('install', '-r') })
        $arguments += $apks

        $text = (Invoke-Adb -CommandArguments $arguments -TimeoutMs $script:backupTimeoutMs).Text.Trim()
        if ($text -match 'Success') {
            $installed++
            Write-Log "  $($row.Package) installed." $colorGood
        } else {
            $failed++
            Write-Log ("  $($row.Package): " + $text) $colorBad
            # measured on a Xiaomi phone: it refuses any adb install until allowed
            if ($text -match 'INSTALL_FAILED_USER_RESTRICTED') {
                Write-Log ('  The phone blocks installs over USB. On Xiaomi / Redmi / POCO turn on ' +
                    'Developer options > Install via USB, then try again.') $colorWarn
            }
        }
    }
    Write-Log "  $installed installed, $failed refused." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
    return [PSCustomObject]@{ Installed = $installed; Failed = $failed }
}

function Restore-BackupContacts {
    # the contacts in the backup this phone does not have, by name and number
    param([string]$Folder, [string]$Serial)

    $path = Join-Path (Join-Path "$Folder" 'personal') 'contacts.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log 'Restore: this backup holds no contacts.' $colorWarn
        return [PSCustomObject]@{ Added = 0; Failed = 0; Skipped = 0 }
    }
    try {
        $contacts = @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Log ('Restore: the contacts file could not be read: ' + $_.Exception.Message) $colorBad
        return [PSCustomObject]@{ Added = 0; Failed = 0; Skipped = 0 }
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
    $added = 0
    $failed = 0
    $skipped = 0
    $index = 0
    foreach ($contact in $contacts) {
        $index++
        $name = "$($contact.Name)".Trim()
        $number = "$($contact.Number)".Trim()
        if (-not $number) { continue }
        $key = ($name + '|' + ($number -replace '[\s\-()]', '')).ToLowerInvariant()
        if ($have.ContainsKey($key)) { $skipped++; continue }
        Write-BackupProgress -Text "Contacts: $name" -Done $index -Total $contacts.Count

        $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:null --bind account_type:s:null')
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

    Write-Log "  $added added, $skipped already there, $failed refused." $(if ($failed -gt 0) { $colorWarn } else { $colorGood })
    return [PSCustomObject]@{ Added = $added; Failed = $failed; Skipped = $skipped }
}
