# Advanced > Backup: what a backup can hold, the folder name, the row parser,
# a made-up backup folder read back, which files are already on the phone, and
# the tab itself. adb is made up for everything that would write; with a phone
# attached the last section takes a real settings-only backup, which only reads.

$work = Join-Path $TestOutput 'backup-work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work

Say '== what a backup can hold =='
$parts = @(Get-BackupParts)
$ids = @($parts | ForEach-Object { $_.Id })
Say ("  {0} parts: {1}   {2}" -f $parts.Count, ($ids -join ', '),
    (Mark (($ids -join ',') -eq 'files,apps,personal,settings')))
Say ("  each one has words for it   {0}" -f (Mark (@($parts | Where-Object { $_.Label -and $_.Note }).Count -eq 4)))
Say ("  the tab ticks all four by default   {0}" -f (Mark (((Get-BackupTickedParts) -join ',') -eq 'files,apps,personal,settings')))

Say ''
Say '== the folder name =='
$when = [datetime]::new(2026, 9, 20, 14, 5, 9)
$name = ConvertTo-BackupName -Model 'Redmi 13C' -Serial 'ABC123' -When $when
Say ("  '{0}'   {1}" -f $name, (Mark ($name -eq 'AndroidDC-backup-Redmi-13C-ABC123-20260920-140509')))
$odd = ConvertTo-BackupName -Model 'a/b:c*?' -Serial '1"2' -When $when
Say ("  a model with \ / : * ? in it: '{0}'   {1}" -f $odd,
    (Mark ($odd -notmatch '[\\/:*?"<>|]' -and $odd -like 'AndroidDC-backup-*-20260920-140509')))

Say ''
Say '== reading what content query prints =='
$answer = "Row: 0 display_name=Ada, Countess, data1=+1 555 0100`nRow: 1 display_name=Bob, data1=+1 555 0111"
$rows = @(Split-BackupRows -Text $answer)
$first = Get-BackupRowValue -Row $rows[0] -Column 'display_name'
$number = Get-BackupRowValue -Row $rows[0] -Column 'data1'
Say ("  two rows, and a name with a comma stays whole: '{0}' / '{1}'   {2}" -f $first, $number,
    (Mark ($rows.Count -eq 2 -and $first -eq 'Ada, Countess' -and $number -eq '+1 555 0100')))

Say ''
Say '== a backup folder, read back =='
$folder = Join-Path $work 'AndroidDC-backup-test'
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'files\Pictures') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'files\Download') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'apps\com.example.app') -Force
Set-Content -LiteralPath (Join-Path $folder 'files\Pictures\one.jpg') -Value 'picture one' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $folder 'files\Download\two.txt') -Value 'file two' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $folder 'apps\com.example.app\base.apk') -Value 'not really an apk' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $folder 'apps\com.example.app\split_config.apk') -Value 'split' -Encoding Ascii
Save-BackupText -Path (Join-Path $folder 'personal\contacts.json') -Text (ConvertTo-Json -InputObject @(
    [PSCustomObject]@{ Name = 'Ada'; Number = '+1 555 0100' }) -Depth 3)
Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 1; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-20T14:05:09'
    Parts = @('files', 'apps', 'personal'); Files = [PSCustomObject]@{ Files = 2; Bytes = 20 }
    Apps = @([PSCustomObject]@{ Package = 'com.example.app'; Files = @('base.apk', 'split_config.apk'); Bytes = 24 })
    Personal = [PSCustomObject]@{ Contacts = 1; Messages = 0; Calls = 0 }; Settings = @(); Bytes = 44
}))

$manifest = Read-BackupManifest -Folder $folder
Say ("  the manifest says {0} ({1}), Android {2}   {3}" -f $manifest.Model, $manifest.Serial, $manifest.Android,
    (Mark ($manifest.Serial -eq 'ABC123' -and @($manifest.Parts).Count -eq 3)))
$lines = @(Get-BackupSummaryLines -Manifest $manifest)
Say ("  in words: {0}" -f ($lines -join ' | '))
Say ("  it names the phone, the files and the apps   {0}" -f (Mark (
    ($lines -join ' ') -match 'Redmi 13C' -and ($lines -join ' ') -match 'Files: 2' -and ($lines -join ' ') -match 'Apps: 1')))
Say ("  a folder that is not a backup gives nothing   {0}" -f (Mark ($null -eq (Read-BackupManifest -Folder $work))))

$apps = @(Get-BackupAppRows -Folder $folder)
$baseFirst = @($apps)[0].Apks[0] -like '*base.apk'
Say ("  the app rows: {0} ({1}), base APK first   {2}" -f $apps[0].Package, $apps[0].Size,
    (Mark ($apps.Count -eq 1 -and $apps[0].Apks.Count -eq 2 -and $baseFirst -and $apps[0].State -eq 'missing')))

Say ''
Say '== which files the phone already has =='
$plan = Get-BackupFilePlan -Folder $folder
Say ("  {0} file(s) in the backup, none marked yet   {1}" -f $plan.Total, (Mark ($plan.Total -eq 2 -and $plan.Existing -eq 0)))
Say ("  each one knows where it goes   {0}" -f (Mark (
    ((@($plan.Items | ForEach-Object { $_.Remote }) | Sort-Object) -join ',') -eq '/sdcard/Download/two.txt,/sdcard/Pictures/one.jpg')))
# what a phone holding the picture but not the download would answer
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @('/sdcard/Pictures/one.jpg', '/sdcard/Music/other.mp3')
$marked = @($plan.Items | Where-Object { $_.Exists } | ForEach-Object { $_.Remote })
Say ("  against that phone: {0} of {1} already there ({2})   {3}" -f $plan.Existing, $plan.Total, ($marked -join ','),
    (Mark ($plan.Existing -eq 1 -and ($marked -join ',') -eq '/sdcard/Pictures/one.jpg')))

$sent = & {
    function Invoke-Adb { param($CommandArguments, $TimeoutMs) $script:pushed += ,@($CommandArguments); return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Lines = @() } }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    $script:pushed = @()
    $result = Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'skip'
    [PSCustomObject]@{ Result = $result; Pushed = $script:pushed }
}
Say ("  skipping what is there sends 1 and leaves 1   {0}" -f (Mark (
    $sent.Result.Sent -eq 1 -and $sent.Result.Skipped -eq 1 -and $sent.Result.Failed -eq 0)))
Say ("  and it pushed the missing one   {0}" -f (Mark (((@($sent.Pushed) | ForEach-Object { $_ -join ' ' }) -join '|') -match 'two\.txt')))

$all = & {
    function Invoke-Adb { param($CommandArguments, $TimeoutMs) return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Lines = @() } }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'replace'
}
Say ("  replacing sends both   {0}" -f (Mark ($all.Sent -eq 2 -and $all.Skipped -eq 0)))

Say ''
Say '== installing an app from a backup =='
$installed = & {
    function Invoke-Adb { param($CommandArguments, $TimeoutMs) $script:ran = $CommandArguments -join ' '; return [PSCustomObject]@{ ExitCode = 0; Text = 'Success'; Lines = @() } }
    $script:ran = ''
    $result = Restore-BackupApps -Rows $apps -Serial 'ABC123'
    [PSCustomObject]@{ Result = $result; Ran = $script:ran }
}
Say ("  a split app goes in one install-multiple: '{0}'   {1}" -f $installed.Ran,
    (Mark ($installed.Result.Installed -eq 1 -and $installed.Ran -match 'install-multiple -r' -and $installed.Ran -match 'base\.apk')))

Say ''
Say '== the tab =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabBackup
Wait-Pumped -Milliseconds 400
$shown = Show-BackupAt -Folder $folder
Say ("  opening the backup fills the box and lists its app   {0}" -f (Mark (
    $shown -and $txtBackupInfo.Text -match 'Redmi 13C' -and $clbBackupApps.Items.Count -eq 1)))
Say ("  the app this phone lacks is ticked   {0}" -f (Mark ($clbBackupApps.CheckedIndices.Count -eq 1)))
Set-BackupProgressUi -Text 'Files: Pictures' -Done 3 -Total 10
Say ("  the strip says '{0}' at {1} of {2}   {3}" -f $lblBackupProgress.Text, $prgBackup.Value, $prgBackup.Maximum,
    (Mark ($lblBackupProgress.Text -eq 'Files: Pictures' -and $prgBackup.Value -eq 3 -and $prgBackup.Maximum -eq 10)))
$null = Show-BackupAt -Folder $work
Say ("  a folder without a manifest is refused   {0}" -f (Mark ($script:backupFolder -eq $folder)))

Say ''
Say '== a real backup, reading only =='
$attached = @(Get-AdbDevices | Where-Object { $_.Serial -eq $TestSerial -and $_.State -eq 'device' }).Count -gt 0
if (-not $TestSerial -or -not $attached) {
    Say 'SKIPPED - no phone attached right now'
} else {
    Select-TestPhone
    $real = Invoke-PhoneBackup -Serial $TestSerial -Destination $work -Parts @('settings') -Model 'test phone'
    $settingsFolder = Join-Path $real.Folder 'settings'
    $written = @(Get-ChildItem -LiteralPath $settingsFolder -File -ErrorAction SilentlyContinue)
    $properties = Join-Path $settingsFolder 'properties.txt'
    $hasProps = (Test-Path -LiteralPath $properties) -and ((Get-Content -LiteralPath $properties -Raw) -match 'ro.build.version.release')
    Say ("  {0} file(s) of settings, properties among them   {1}" -f $written.Count, (Mark ($written.Count -ge 6 -and $hasProps)))
    $back = Read-BackupManifest -Folder $real.Folder
    Say ("  its manifest reads back: parts {0}, serial matches   {1}" -f (@($back.Parts) -join ','),
        (Mark ((@($back.Parts) -join ',') -eq 'settings' -and $back.Serial -eq $TestSerial)))
    Say ("  nothing was written to the phone: only settings were asked for   {0}" -f (Mark (
        -not (Test-Path -LiteralPath (Join-Path $real.Folder 'files')) -and -not (Test-Path -LiteralPath (Join-Path $real.Folder 'apps')))))
}
