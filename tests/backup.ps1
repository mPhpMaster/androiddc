# Advanced > Backup: what a backup can hold, the name it is given, the row
# parser, a made-up backup packed into a .zip and read back out of it, which
# files are already on the phone, the list of backups this PC has, and the tab
# itself. adb is made up for everything that would write; with a phone attached
# the last section takes a real settings-only backup, which only reads.

$work = Join-Path $TestOutput 'backup-work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work
# one spelling of it: %TEMP% is handed out short (LONGNA~1) and everything the
# program writes down says the long one, so the two would never compare equal
$work = (Get-Item -LiteralPath $work).FullName

Say '== what a backup can hold =='
$parts = @(Get-BackupParts)
$ids = @($parts | ForEach-Object { $_.Id })
Say ("  {0} parts: {1}   {2}" -f $parts.Count, ($ids -join ', '),
    (Mark (($ids -join ',') -eq 'files,card,apps,personal,settings')))
Say ("  each one has words for it   {0}" -f (Mark (@($parts | Where-Object { $_.Label -and $_.Note }).Count -eq 5)))
Say ("  the tab ticks four of them, the card left off   {0}" -f (Mark (
    ((Get-BackupTickedParts) -join ',') -eq 'files,apps,personal,settings' -and -not $chkBackupCard.Checked)))
$chkBackupCard.Checked = $true
Say ("  ticking the card puts it in: {0}   {1}" -f ((Get-BackupTickedParts) -join ','),
    (Mark (((Get-BackupTickedParts) -join ',') -eq 'files,card,apps,personal,settings')))
$chkBackupCard.Checked = $false

Say ''
Say '== the name it is given =='
$when = [datetime]::new(2026, 9, 20, 14, 5, 9)
$name = ConvertTo-BackupName -Model 'Redmi 13C' -Serial 'ABC123' -When $when
Say ("  '{0}'   {1}" -f $name, (Mark ($name -eq 'AndroidDC-backup-Redmi-13C-ABC123-20260920-140509')))
$called = ConvertTo-BackupName -Model 'Redmi 13C' -Serial 'ABC123' -When $when -Name 'before the update'
Say ("  with a name of your own: '{0}'   {1}" -f $called,
    (Mark ($called -eq 'AndroidDC-backup-before-the-update-Redmi-13C-ABC123-20260920-140509')))
Say ("  a name with a slash in it cannot make a folder of its own   {0}" -f (Mark (
    (ConvertTo-BackupName -Model 'M' -Serial 'S' -When $when -Name 'a/b\c') -notmatch '[\/:*?"<>|]')))
Say ("  times are written the way a clock is read: '{0}'   {1}" -f (Format-BackupWhen -Text '2026-10-02T15:22:36'),
    (Mark ((Format-BackupWhen -Text '2026-10-02T15:22:36') -eq '2026-10-02 03:22:36 PM')))
Say ("  and something that is not a time comes back as it was   {0}" -f (Mark (
    (Format-BackupWhen -Text 'no idea') -eq 'no idea')))
$odd = ConvertTo-BackupName -Model 'a/b:c*?' -Serial '1"2' -When $when
Say ("  a model with \ / : * ? in it: '{0}'   {1}" -f $odd,
    (Mark ($odd -notmatch '[\\/:*?"<>|]' -and $odd -like 'AndroidDC-backup-*-20260920-140509')))

Say ''
Say '== a memory card in a backup =='
# a backup of a phone with a card: the card's files sit under card\<its name>,
# so two cards - or a card and the phone - never land on top of each other
# in a folder of its own: the checks further down count what is in $work
$cardFolder = Join-Path $work 'card-test\AndroidDC-backup-card'
$null = New-Item -ItemType Directory -Path (Join-Path $cardFolder 'files\Download') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $cardFolder 'card\1A2B-3C4D\DCIM') -Force
Set-Content -LiteralPath (Join-Path $cardFolder 'files\Download\phone.txt') -Value 'on the phone' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $cardFolder 'card\1A2B-3C4D\DCIM\card.jpg') -Value 'on the card' -Encoding Ascii
Save-BackupText -Path (Join-Path $cardFolder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-22T10:00:00'
    Parts = @('files', 'card'); Files = [PSCustomObject]@{ Files = 1; Bytes = 12 }
    Card = [PSCustomObject]@{ Cards = @('/storage/1A2B-3C4D'); Files = 1; Bytes = 11; Refused = @() }
    Apps = @(); Personal = $null; Settings = @(); Bytes = 23; Complete = $true; Stopped = ''
}))

$cardSource = Open-BackupSource -Path $cardFolder
Say ("  its words say what came off the card: {0}" -f (
    (@(Get-BackupSummaryLines -Manifest $cardSource.Manifest -Source $cardSource) | Where-Object { $_ -like 'Memory card*' }) -join ''))
Say ("  the summary names the card part   {0}" -f (Mark (
    ((@(Get-BackupSummaryLines -Manifest $cardSource.Manifest -Source $cardSource)) -join ' ') -match 'Memory card: 1 file')))
Say ("  and the list of what it holds says 'card'   {0}" -f (Mark (
    (Get-BackupPartWords -Parts $cardSource.Manifest.Parts) -eq 'files, card')))

$cardInside = Get-BackupInsideRows -Source $cardSource
$cardRow = @($cardInside.Rows | Where-Object { $_.Entry -like 'card/*' })[0]
Say ("  inside it, that file is a Card file that was at {0}   {1}" -f $cardRow.Path,
    (Mark ($cardRow.What -eq 'Card' -and $cardRow.Path -eq '/storage/1A2B-3C4D/DCIM/card.jpg')))

# with a card in the phone now, whatever it is called, the files go onto it
$cardPlan = Get-BackupFilePlan -Source $cardSource -CardRoot '/storage/9999-8888'
$goes = (@($cardPlan.Items | ForEach-Object { $_.Remote }) | Sort-Object) -join ', '
Say ("  put back with a card in the phone, they go to: {0}" -f $goes)
Say ("  the phone's file to /sdcard, the card's to the card that is there now   {0}" -f (Mark (
    $cardPlan.Total -eq 2 -and $cardPlan.CardSkipped -eq 0 -and
    $goes -eq '/sdcard/Download/phone.txt, /storage/9999-8888/DCIM/card.jpg')))
Say ("  and it knows where to ask the phone what it has: {0}   {1}" -f (@($cardPlan.Tops) -join ', '),
    (Mark ((@($cardPlan.Tops) -join ',') -eq '/sdcard/Download,/storage/9999-8888/DCIM')))

# with no card in the phone there is nowhere to put them, and it says so
$noCard = Get-BackupFilePlan -Source $cardSource
Say ("  with no card in the phone: {0} file(s) to send, {1} left out   {2}" -f $noCard.Total, $noCard.CardSkipped,
    (Mark ($noCard.Total -eq 1 -and $noCard.CardSkipped -eq 1 -and $noCard.Items[0].Remote -eq '/sdcard/Download/phone.txt')))

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
# what the backup writes down about its apps: the name each had and its version
Save-BackupText -Path (Join-Path $folder 'apps\apps.json') -Text (ConvertTo-Json -Depth 4 -InputObject @(
    [PSCustomObject]@{ Package = 'com.example.app'; Name = 'Example'; Version = '42'
        Files = @('base.apk', 'split_config.apk'); Bytes = 26 }))
Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-20T14:05:09'
    Parts = @('files', 'apps', 'personal'); Files = [PSCustomObject]@{ Files = 2; Bytes = 20 }
    Apps = @([PSCustomObject]@{ Package = 'com.example.app'; Files = @('base.apk', 'split_config.apk'); Bytes = 24 })
    Personal = [PSCustomObject]@{ Contacts = 1; Messages = 0; Calls = 0 }; Settings = @(); Bytes = 44
    Complete = $true; Stopped = ''
}))

$manifest = Read-BackupManifest -Path $folder
Say ("  the manifest says {0} ({1}), Android {2}   {3}" -f $manifest.Model, $manifest.Serial, $manifest.Android,
    (Mark ($manifest.Serial -eq 'ABC123' -and @($manifest.Parts).Count -eq 3)))
$lines = @(Get-BackupSummaryLines -Manifest $manifest)
Say ("  in words: {0}" -f ($lines -join ' | '))
Say ("  it names the phone, the files and the apps   {0}" -f (Mark (
    ($lines -join ' ') -match 'Redmi 13C' -and ($lines -join ' ') -match 'Files: 2' -and ($lines -join ' ') -match 'Apps: 1')))
Say ("  a folder that is not a backup gives nothing   {0}" -f (Mark ($null -eq (Read-BackupManifest -Path $work))))

$apps = @(Get-BackupAppRows -Source $folder)
$baseFirst = @($apps)[0].Apks[0] -like '*base.apk'
Say ("  the app row: '{0}' ({1}), version {2}, {3}, base APK first   {4}" -f $apps[0].Shown, $apps[0].Package,
    $apps[0].Version, $apps[0].Size,
    (Mark ($apps.Count -eq 1 -and $apps[0].Apks.Count -eq 2 -and $baseFirst -and
        $apps[0].Shown -eq 'Example' -and $apps[0].Version -eq '42' -and $apps[0].Parts -eq '2 files')))
Say ("  with no phone to compare against it says so, and is not called missing   {0}" -f (
    Mark ($apps[0].State -eq 'no phone to compare')))

# what the four answers are, against a phone that has this app
Say ("  a phone without it: '{0}'   {1}" -f (Get-BackupAppState -Serial 'ABC123' -Installed $false -Backup '42' -Phone ''),
    (Mark ((Get-BackupAppState -Serial 'ABC123' -Installed $false -Backup '42' -Phone '') -eq 'not on the phone')))
Say ("  the same version on it: '{0}'   {1}" -f (Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '42'),
    (Mark ((Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '42') -eq 'on the phone')))
Say ("  an older one on it: '{0}'   {1}" -f (Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '41'),
    (Mark ((Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '41') -eq 'older on the phone')))
Say ("  a newer one on it: '{0}'   {1}" -f (Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '43'),
    (Mark ((Get-BackupAppState -Serial 'ABC123' -Installed $true -Backup '42' -Phone '43') -eq 'newer on the phone')))

Say ''
Say '== packed into one .zip =='
$zipPath = Join-Path $work 'AndroidDC-backup-test.zip'
Start-BackupRun
$packed = Compress-BackupFolder -Folder $folder -ZipPath $zipPath
Complete-BackupRun
Say ("  {0} file(s) packed into {1}   {2}" -f $packed.Files, (Format-FileSize -Bytes $packed.Bytes),
    (Mark ($packed.Ok -and $packed.Files -eq 7 -and (Test-Path -LiteralPath $zipPath -PathType Leaf))))
Say ("  the zip reads back with all seven in it   {0}" -f (Mark ((Test-BackupArchive -Path $zipPath) -eq 7)))
Say ("  a jpg goes in as it is, a txt is squeezed   {0}" -f (Mark (
    (Get-BackupCompression -Name 'one.jpg') -eq [System.IO.Compression.CompressionLevel]::NoCompression -and
    (Get-BackupCompression -Name 'two.txt') -eq [System.IO.Compression.CompressionLevel]::Fastest)))

$zip = Open-BackupSource -Path $zipPath
Say ("  opened: {0}, manifest says {1}, and its index is not read yet   {2}" -f $zip.Kind, $zip.Manifest.Model,
    (Mark ($zip.Kind -eq 'zip' -and $null -eq $zip.Entries -and $zip.Manifest.Serial -eq 'ABC123')))
$entries = Get-BackupSourceEntries -Source $zip
Say ("  asked for it: {0} file(s), and it is kept   {1}" -f $entries.Count,
    (Mark ($entries.Count -eq 7 -and $null -ne $zip.Entries)))
Say ("  its words say it is packed   {0}" -f (Mark (
    ((@(Get-BackupSummaryLines -Manifest $zip.Manifest -Source $zip)) -join ' ') -match 'Packed:')))
Say ("  a .zip that is not a backup is refused   {0}" -f (Mark ($null -eq (Open-BackupSource -Path (Join-Path $folder 'manifest.json')))))

Say ''
Say '== looking inside one, without unpacking it =='
$inside = Get-BackupInsideRows -Source $zip
Say ("  {0} line(s): {1}" -f $inside.Total, ((@($inside.Rows | ForEach-Object { $_.Path }) | Sort-Object) -join ', '))
$picture = @($inside.Rows | Where-Object { $_.Entry -eq 'files/Pictures/one.jpg' })[0]
Say ("  a file says which part it is in and where it was: {0} / {1}   {2}" -f $picture.What, $picture.Path,
    (Mark ($inside.Total -eq 7 -and $picture.What -eq 'Files' -and $picture.Path -eq '/sdcard/Pictures/one.jpg')))
$found = Get-BackupInsideRows -Source $zip -Filter 'Pictures'
Say ("  looking for Pictures leaves {0}   {1}" -f $found.Total, (Mark ($found.Total -eq 1)))
Say ("  looking for something not in it leaves none   {0}" -f (
    Mark ((Get-BackupInsideRows -Source $zip -Filter 'no-such-thing').Total -eq 0)))
$capped = Get-BackupInsideRows -Source $zip -Limit 2
Say ("  a limit lists 2 of {0}, and still says how many there are   {1}" -f $capped.Total,
    (Mark ($capped.Rows.Count -eq 2 -and $capped.Total -eq 7)))

$saved = Join-Path $work 'saved'
$copy = Save-BackupCopy -Source $zip -Entries @('files/Pictures/one.jpg') -Destination $saved
$savedFile = Join-Path $saved 'files\Pictures\one.jpg'
Say ("  one file saved out of the zip, and it reads back   {0}" -f (Mark (
    $copy.Saved -eq 1 -and (Test-Path -LiteralPath $savedFile) -and
    (Get-Content -LiteralPath $savedFile -Raw) -match 'picture one')))

Say ''
Say '== which files the phone already has =='
$plan = Get-BackupFilePlan -Source $folder
Say ("  {0} file(s) in the backup, none marked yet   {1}" -f $plan.Total, (Mark ($plan.Total -eq 2 -and $plan.Existing -eq 0)))
Say ("  each one knows where it goes   {0}" -f (Mark (
    ((@($plan.Items | ForEach-Object { $_.Remote }) | Sort-Object) -join ',') -eq '/sdcard/Download/two.txt,/sdcard/Pictures/one.jpg')))
# what a phone holding the picture but not the download would answer
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @('/sdcard/Pictures/one.jpg', '/sdcard/Music/other.mp3')
$marked = @($plan.Items | Where-Object { $_.Exists } | ForEach-Object { $_.Remote })
Say ("  against that phone: {0} of {1} already there ({2})   {3}" -f $plan.Existing, $plan.Total, ($marked -join ','),
    (Mark ($plan.Existing -eq 1 -and ($marked -join ',') -eq '/sdcard/Pictures/one.jpg')))

# Invoke-BackupAdb is what a restore calls now: one adb it can watch and kill
$sent = & {
    function Invoke-BackupAdb { param($ArgumentList, $Caption, $Expected, $OnPoll) $script:pushed += ,@($ArgumentList); return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Stopped = $false } }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    $script:pushed = @()
    $result = Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'skip'
    [PSCustomObject]@{ Result = $result; Pushed = $script:pushed }
}
Say ("  skipping what is there sends 1 and leaves 1   {0}" -f (Mark (
    $sent.Result.Sent -eq 1 -and $sent.Result.Skipped -eq 1 -and $sent.Result.Failed -eq 0)))
Say ("  and it pushed the missing one   {0}" -f (Mark (((@($sent.Pushed) | ForEach-Object { $_ -join ' ' }) -join '|') -match 'two\.txt')))

$all = & {
    function Invoke-BackupAdb { param($ArgumentList, $Caption, $Expected, $OnPoll) return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Stopped = $false } }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'replace'
}
Say ("  replacing sends both   {0}" -f (Mark ($all.Sent -eq 2 -and $all.Skipped -eq 0)))

Say ''
Say '== restoring out of the zip itself =='
$zipPlan = Get-BackupFilePlan -Source $zip
$noneOnDisk = @(@($zipPlan.Items) | Where-Object { "$($_.Local)" }).Count -eq 0
Say ("  {0} file(s), none of them lying on this PC   {1}" -f $zipPlan.Total, (Mark ($zipPlan.Total -eq 2 -and $noneOnDisk)))
$zipPlan = Set-BackupFilePlanKnown -Plan $zipPlan -RemotePaths @()
$fromZip = & {
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        # what adb would be given: the file taken out of the zip a moment ago
        $local = @($ArgumentList)[3]
        $text = ''
        if (Test-Path -LiteralPath $local) { $text = (Get-Content -LiteralPath $local -Raw) }
        $script:seen += ,("$(@($ArgumentList)[4])=" + $text.Trim())
        return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Stopped = $false }
    }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    $script:seen = @()
    $result = Restore-BackupFiles -Plan $zipPlan -Serial 'ABC123' -OnConflict 'replace'
    [PSCustomObject]@{ Result = $result; Seen = $script:seen }
}
Say ("  both sent, unpacked one at a time: {0}" -f (($fromZip.Seen | Sort-Object) -join ' | '))
Say ("  and what adb was handed really held the file   {0}" -f (Mark (
    $fromZip.Result.Sent -eq 2 -and (($fromZip.Seen | Sort-Object) -join '|') -match 'Pictures/one\.jpg=picture one')))
$leftOver = @(Get-ChildItem -LiteralPath (Get-BackupTempFolder) -File -ErrorAction SilentlyContinue)
Say ("  nothing is left lying in the temp folder afterwards   {0}" -f (Mark ($leftOver.Count -eq 0)))

$zipApps = @(Get-BackupAppRows -Source $zip)
$fromZipApps = & {
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        $script:ran = @($ArgumentList)
        $script:read = ''
        foreach ($argument in @($ArgumentList)) {
            if ($argument -like '*base.apk') { $script:read = (Get-Content -LiteralPath $argument -Raw).Trim() }
        }
        return [PSCustomObject]@{ ExitCode = 0; Text = 'Success'; Stopped = $false }
    }
    $script:ran = @()
    $script:read = ''
    $result = Restore-BackupApps -Rows $zipApps -Serial 'ABC123' -Source $zip
    [PSCustomObject]@{ Result = $result; Ran = ($script:ran -join ' '); Read = $script:read }
}
Say ("  an app out of the zip is installed from its unpacked APKs   {0}" -f (Mark (
    $fromZipApps.Result.Installed -eq 1 -and $fromZipApps.Ran -match 'install-multiple -r' -and
    $fromZipApps.Read -eq 'not really an apk')))
$contactsFromZip = & {
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    function Invoke-DeviceCommand { param($Serial, $Arguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    Restore-BackupContacts -Source $zip -Serial 'ABC123'
}
Say ("  the contacts in the zip are read: {0} tried   {1}" -f ($contactsFromZip.Added + $contactsFromZip.Failed),
    (Mark (($contactsFromZip.Added + $contactsFromZip.Failed) -eq 1)))

Say ''
Say '== installing an app from a backup =='
$installed = & {
    function Invoke-BackupAdb { param($ArgumentList, $Caption, $Expected, $OnPoll) $script:ran = $ArgumentList -join ' '; return [PSCustomObject]@{ ExitCode = 0; Text = 'Success'; Stopped = $false } }
    $script:ran = ''
    $result = Restore-BackupApps -Rows $apps -Serial 'ABC123'
    [PSCustomObject]@{ Result = $result; Ran = $script:ran }
}
Say ("  a split app goes in one install-multiple: '{0}'   {1}" -f $installed.Ran,
    (Mark ($installed.Result.Installed -eq 1 -and $installed.Ran -match 'install-multiple -r' -and $installed.Ran -match 'base\.apk')))

Say ''
Say '== a backup of six thousand files, opened =='
# a phone's worth of photos, without pulling one: the point is that opening a
# backup reads its manifest and stops there, however many files are in it
# in a folder of its own: the checks below count what is in $work
$bigFolder = Join-Path $work 'big'
$null = New-Item -ItemType Directory -Path $bigFolder -Force
$bigPath = Join-Path $bigFolder 'AndroidDC-backup-big.zip'
$null = Initialize-BackupZip
$bigStream = [System.IO.File]::Open($bigPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$bigZip = New-Object System.IO.Compression.ZipArchive($bigStream, [System.IO.Compression.ZipArchiveMode]::Create)
$bytes = [System.Text.Encoding]::ASCII.GetBytes('a picture')
$manifestText = ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-20T14:05:09'
    Parts = @('files'); Files = [PSCustomObject]@{ Files = 6000; Bytes = 54000 }
    Apps = @(); Personal = $null; Settings = @(); Bytes = 54000; Complete = $true; Stopped = ''
})
$entry = $bigZip.CreateEntry('manifest.json', [System.IO.Compression.CompressionLevel]::Fastest)
$writer = $entry.Open()
$manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestText)
$writer.Write($manifestBytes, 0, $manifestBytes.Length)
$writer.Dispose()
for ($i = 0; $i -lt 6000; $i++) {
    $entry = $bigZip.CreateEntry("files/DCIM/Camera/photo-$i.jpg", [System.IO.Compression.CompressionLevel]::NoCompression)
    $writer = $entry.Open()
    $writer.Write($bytes, 0, $bytes.Length)
    $writer.Dispose()
}
$bigZip.Dispose()
$bigStream.Dispose()

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$big = Open-BackupSource -Path $bigPath
$openMs = $watch.ElapsedMilliseconds
Say ("  opened in {0} ms, without reading its index   {1}" -f $openMs,
    (Mark ($null -ne $big -and $null -eq $big.Entries -and $openMs -lt 2000)))
$watch.Restart()
$bigInside = Get-BackupInsideRows -Source $big -Limit 3000
$readMs = $watch.ElapsedMilliseconds
Say ("  its 6001 files read and the first 3000 made into rows in {0} ms   {1}" -f $readMs,
    (Mark ($bigInside.Total -eq 6001 -and $bigInside.Rows.Count -eq 3000 -and $readMs -lt 25000)))
$watch.Restart()
$bigFound = Get-BackupInsideRows -Source $big -Filter 'photo-4242.jpg'
$findMs = $watch.ElapsedMilliseconds
Say ("  and looking for one of them takes {0} ms, off the index it kept   {1}" -f $findMs,
    (Mark ($bigFound.Total -eq 1 -and $findMs -lt 5000)))

Say ''
Say '== how long is left =='
# the clock is told when it started, so these are the same every time
Start-BackupClock -Total 1000 -Started ([datetime]::Now.AddSeconds(-10))
Add-BackupClockDone -Amount 100
Say ("  a tenth of it in ten seconds: '{0}'   {1}" -f (Get-BackupLeftText),
    (Mark ((Get-BackupLeftText) -match '^about 2 minutes left, done by \d{1,2}:\d\d (AM|PM)$')))
Add-BackupClockDone -Amount 800
Say ("  nine tenths done: '{0}'   {1}" -f (Get-BackupLeftText),
    (Mark ((Get-BackupLeftText) -eq 'less than a minute left')))

Start-BackupClock -Total 100000 -Started ([datetime]::Now.AddSeconds(-10))
Add-BackupClockDone -Amount 100
Say ("  a long one says the hours and the time of day: '{0}'   {1}" -f (Get-BackupLeftText),
    (Mark ((Get-BackupLeftText) -match '^about 2 hours \d+ min left, done by \d{1,2}:\d\d (AM|PM)$')))

# a folder being pulled counts while it fills, not only when it ends
Start-BackupClock -Total 1000 -Started ([datetime]::Now.AddSeconds(-10))
Set-BackupClockItem -Amount 250
Say ("  a quarter of the way into one folder: '{0}'   {1}" -f (Get-BackupLeftText),
    (Mark ((Get-BackupLeftText) -eq 'less than a minute left')))

Start-BackupClock -Total 1000 -Started ([datetime]::Now.AddSeconds(-1))
Add-BackupClockDone -Amount 10
Say ("  the first seconds say nothing, rather than something wild   {0}" -f (Mark ((Get-BackupLeftText) -eq '')))

Start-BackupClock -Total 1000 -Started ([datetime]::Now.AddSeconds(-10))
Add-BackupClockDone -Amount 100
Write-BackupProgress -Text 'Files: DCIM' -Done 1 -Total 2
Say ("  and the line in the window carries it: '{0}'   {1}" -f $lblBackupProgress.Text,
    (Mark ($lblBackupProgress.Text -match '^Files: DCIM  -  about 2 minutes left')))
Stop-BackupClock
Write-BackupProgress -Text 'Files: DCIM' -Done 1 -Total 2
Say ("  with nothing to go on it says the plain line   {0}" -f (Mark ($lblBackupProgress.Text -eq 'Files: DCIM')))

Say ''
Say '== carrying a stopped backup on =='
# what a backup that stopped leaves behind: a folder, a manifest saying it is
# not complete, and the files that did come over
$half = Join-Path $work 'half\AndroidDC-backup-half'
$null = New-Item -ItemType Directory -Path (Join-Path $half 'files\DCIM') -Force
# one file that came over whole, and one that was cut off part way
[System.IO.File]::WriteAllBytes((Join-Path $half 'files\DCIM\whole.jpg'), (New-Object byte[] 10))
[System.IO.File]::WriteAllBytes((Join-Path $half 'files\DCIM\short.jpg'), (New-Object byte[] 3))
Save-BackupText -Path (Join-Path $half 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-22T09:00:00'
    Parts = @('files'); Files = [PSCustomObject]@{ Files = 2; Bytes = 13 }
    Card = $null; Apps = @(); Personal = $null; Settings = @(); Bytes = 13
    Complete = $false; Stopped = 'the phone was disconnected'; Finished = '2026-09-22T09:20:00'
}))

$halfSource = Open-BackupSource -Path $half
Say ("  a stopped backup is one that can be carried on   {0}" -f (Mark (Test-BackupResumable -Source $halfSource)))
Say ("  a packed one is not: it finished   {0}" -f (Mark (-not (Test-BackupResumable -Source (Open-BackupSource -Path $zipPath)))))
$rows = @(Get-BackupsInFolder -Folder (Split-Path -Parent $half))
Say ("  and the list says why: '{0}'   {1}" -f $rows[0].State, (Mark ($rows[0].State -eq 'stopped part way')))

# the phone says what it holds and how big each one is; the fakes stand in for it
$fakeShell = {
    param($Serial, $CommandArguments)
    $command = (@($CommandArguments) -join ' ')
    $text = ''
    if ($command -eq 'ls -1 /sdcard/') { $text = "DCIM`n" }
    elseif ($command -like "find '/sdcard/DCIM' -type f*") {
        # whole.jpg is here already, short.jpg came over cut off, new.jpg never arrived
        $text = "10 /sdcard/DCIM/whole.jpg`n7 /sdcard/DCIM/short.jpg`n5 /sdcard/DCIM/new.jpg`n"
    }
    return [PSCustomObject]@{ Lines = @($text -split "`n"); Text = $text; ExitCode = 0 }
}

$carried = & {
    function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        $script:fetched += ,(@($ArgumentList)[4])
        return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pulled'; Stopped = $false }
    }
    $script:fetched = @()
    Start-BackupRun
    $one = Resume-BackupFiles -Serial 'ABC123' -Folder $half
    Complete-BackupRun
    [PSCustomObject]@{ Result = $one; Fetched = @($script:fetched) }
}
Say ("  it fetched: {0}" -f (($carried.Fetched | Sort-Object) -join ', '))
Say ("  only the one that was cut off and the one never fetched, {0} kept   {1}" -f $carried.Result.Kept, (Mark (
    $carried.Result.Fetched -eq 2 -and $carried.Result.Kept -eq 1 -and
    (($carried.Fetched | Sort-Object) -join ',') -eq '/sdcard/DCIM/new.jpg,/sdcard/DCIM/short.jpg')))

$wrongPhone = & {
    function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Resume-PhoneBackup -Serial 'ANOTHER-PHONE' -Folder $half
}
Say ("  a backup of another phone is refused, not mixed   {0}" -f (Mark ($null -eq $wrongPhone)))
Say ("  so is one that already finished   {0}" -f (Mark ($null -eq (Resume-PhoneBackup -Serial 'ABC123' -Folder $zipPath))))

$finished = & {
    function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        # what the phone would have sent, so the packed backup holds it
        [System.IO.File]::WriteAllBytes((@($ArgumentList)[5]), (New-Object byte[] 4))
        return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pulled'; Stopped = $false }
    }
    Resume-PhoneBackup -Serial 'ABC123' -Folder $half
}
Say ("  carried on to the end: {0}, complete {1}" -f [System.IO.Path]::GetFileName("$($finished.Path)"), $finished.Complete)
Say ("  it is one .zip now, the folder is gone, and the manifest says complete   {0}" -f (Mark (
    $finished.Complete -and $finished.Kind -eq 'zip' -and (Test-Path -LiteralPath $finished.Path -PathType Leaf) -and
    -not (Test-Path -LiteralPath $half))))
Say ("  and what was already here was not fetched again   {0}" -f (Mark (
    (Open-BackupSource -Path $finished.Path).Manifest.Files.Kept -eq 1)))

# the same work brings a finished one up to date: only what changed comes over
$upToDate = Join-Path $work 'update\AndroidDC-backup-done'
$null = New-Item -ItemType Directory -Path (Join-Path $upToDate 'files\DCIM') -Force
[System.IO.File]::WriteAllBytes((Join-Path $upToDate 'files\DCIM\whole.jpg'), (New-Object byte[] 10))
Save-BackupText -Path (Join-Path $upToDate 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-22T08:00:00'
    Name = ''; Parts = @('files'); Files = [PSCustomObject]@{ Files = 1; Bytes = 10 }; Card = $null
    Apps = @(); Personal = $null; Settings = @(); Bytes = 10; Complete = $true; Stopped = ''
    Finished = '2026-09-22T08:30:00' }))
$brought = & {
    function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        $script:again += ,(@($ArgumentList)[4])
        [System.IO.File]::WriteAllBytes((@($ArgumentList)[5]), (New-Object byte[] 4))
        return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pulled'; Stopped = $false }
    }
    $script:again = @()
    $result = Resume-PhoneBackup -Serial 'ABC123' -Folder $upToDate -Pack $false
    [PSCustomObject]@{ Result = $result; Fetched = @($script:again) }
}
Say ("  a finished backup brought up to date fetched: {0}" -f (($brought.Fetched | Sort-Object) -join ', '))
Say ("  only the two the phone has now and it did not, and it stayed a folder   {0}" -f (Mark (
    $brought.Fetched.Count -eq 2 -and $brought.Result.Kind -eq 'folder' -and $brought.Result.Complete)))

Say ''
Say '== the backups in a folder =='
Say ("  the file the test writes is its own, not yours   {0}" -f (Mark ((Get-BackupListFile) -like '*backups-backup.json')))
$rows = @(Get-BackupsInFolder -Folder $work)
$row = @($rows | Where-Object { $_.Path -eq $zipPath })[0]
Say ("  one line: {0} | {1} | {2} | {3} | {4}" -f $row.When, $row.Phone, $row.Holds, $row.Size, $row.State)
Say ("  the zip and the folder beside it, and each says what it holds   {0}" -f (Mark (
    $rows.Count -eq 2 -and $row.Phone -match 'Redmi 13C' -and $row.Holds -eq 'files, apps, contacts' -and
    $row.State -eq 'complete' -and @($rows | Where-Object { $_.Kind -eq 'folder' }).Count -eq 1)))
Say ("  a folder with nothing in it lists nothing   {0}" -f (Mark (
    @(Get-BackupsInFolder -Folder $saved).Count -eq 0)))
Say ("  a folder that is not there lists nothing   {0}" -f (Mark (
    @(Get-BackupsInFolder -Folder (Join-Path $work 'no-such-folder')).Count -eq 0)))
$null = Set-BackupFolderPath -Folder $work
Say ("  the folder is remembered for both windows   {0}" -f (Mark ((Get-BackupFolderPath) -eq $work)))
Say ("  the lines are newest first, by when they were taken   {0}" -f (Mark (
    @($rows)[0].Taken -ge @($rows)[-1].Taken)))

# deleting one, and only one that is a backup
$spare = Join-Path $work 'spare\AndroidDC-backup-spare'
$null = New-Item -ItemType Directory -Path (Join-Path $spare 'files') -Force
Set-Content -LiteralPath (Join-Path $spare 'files\one.txt') -Value 'one' -Encoding Ascii
Save-BackupText -Path (Join-Path $spare 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-22T11:00:00'
    Name = 'the spare'; Parts = @('files'); Files = $null; Card = $null; Apps = @(); Personal = $null
    Settings = @(); Bytes = 3; Complete = $true; Stopped = '' }))
$spareRows = @(Get-BackupsInFolder -Folder (Split-Path -Parent $spare))
Say ("  a backup with a name of its own says it: '{0}'   {1}" -f $spareRows[0].Called,
    (Mark ($spareRows[0].Called -eq 'the spare')))
Say ("  deleting it takes the folder with it   {0}" -f (Mark (
    (Remove-BackupAt -Path $spare) -and -not (Test-Path -LiteralPath $spare))))
$notBackup = Join-Path $work 'not-a-backup'
$null = New-Item -ItemType Directory -Path $notBackup -Force
Set-Content -LiteralPath (Join-Path $notBackup 'holiday.jpg') -Value 'mine' -Encoding Ascii
Say ("  a folder that is not a backup is left alone   {0}" -f (Mark (
    -not (Remove-BackupAt -Path $notBackup) -and (Test-Path -LiteralPath $notBackup))))

Say ''
Say '== the tab =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabBackup
Wait-Pumped -Milliseconds 400
$tabsBackupView.SelectedTab = $tabBackupList
$shown = Show-BackupAt -Path $zipPath
Say ("  opening it fills the box, and reads no further than the manifest   {0}" -f (Mark (
    $shown -and $txtBackupInfo.Text -match 'Redmi 13C' -and $lstBackupInside.Items.Count -eq 0 -and
    $lstBackupApps.Items.Count -eq 0)))
$tabsBackupView.SelectedTab = $tabBackupApps
Wait-Pumped -Milliseconds 300
$appRow = $lstBackupApps.Items[0]
Say ("  the apps tab, read when it is looked at: {0} | {1} | {2} | {3} | {4}" -f $appRow.Text,
    $appRow.SubItems[1].Text, $appRow.SubItems[2].Text, $appRow.SubItems[3].Text, $appRow.SubItems[4].Text)
Say ("  it says the app's name, its package and its version, not just the package   {0}" -f (Mark (
    $lstBackupApps.Items.Count -eq 1 -and $appRow.Text -eq 'Example' -and
    $appRow.SubItems[1].Text -eq 'com.example.app' -and $appRow.SubItems[2].Text -eq 'version 42')))
Say ("  the one this phone does not have is ticked for you, and the line says what to press: '{0}'   {1}" -f
    $lblBackupApps.Text, (Mark ($appRow.Checked -and $lblBackupApps.Text -match 'Install ticked apps')))
$txtBackupAppFind.Text = 'nothing like this'
Wait-Pumped -Milliseconds 600
Say ("  the find box over the apps leaves {0}   {1}" -f $lstBackupApps.Items.Count,
    (Mark ($lstBackupApps.Items.Count -eq 0)))
$txtBackupAppFind.Text = 'Example'
Wait-Pumped -Milliseconds 600
Say ("  looking for its name finds it, still ticked   {0}" -f (Mark (
    $lstBackupApps.Items.Count -eq 1 -and $lstBackupApps.Items[0].Checked)))
Set-BackupAppTicks -On $false
Say ("  Tick none clears it   {0}" -f (Mark (-not $lstBackupApps.Items[0].Checked -and
    @($script:backupAppTicked.Keys).Count -eq 0)))
Set-BackupAppTicks -On $true
Say ("  Tick all puts it back   {0}" -f (Mark ($lstBackupApps.Items[0].Checked)))
$txtBackupAppFind.Text = ''
Wait-Pumped -Milliseconds 600
$tabsBackupView.SelectedTab = $tabBackupInside
Wait-Pumped -Milliseconds 300
Say ("  and What is inside lists all seven when it is looked at   {0}" -f (Mark ($lstBackupInside.Items.Count -eq 7)))
$txtBackupFind.Text = 'Pictures'
# the box waits a moment before it filters, so a word typed letter by letter
# does not walk the whole backup five times
Wait-Pumped -Milliseconds 600
Say ("  typing in the find box leaves {0} of them   {1}" -f $lstBackupInside.Items.Count,
    (Mark ($lstBackupInside.Items.Count -eq 1 -and $lblBackupInside.Text -match '^1 file')))
$txtBackupFind.Text = ''
Wait-Pumped -Milliseconds 600
Say ("  emptying it brings them all back   {0}" -f (Mark ($lstBackupInside.Items.Count -eq 7)))

Set-BackupFolderUi -Folder $work
Say ("  the box says where to look, and the list shows what is in it: {0} of them   {1}" -f $lstBackupList.Items.Count,
    (Mark ($txtBackupWhere.Text -eq $work -and $lstBackupList.Items.Count -eq 2)))
Set-BackupFolderUi -Folder (Join-Path $work 'no-such-folder')
$hint = @($script:listHints | Where-Object { $_.List -eq $lstBackupList })[0]
Say ("  a folder that is not there: no rows, and the list says why - '{0}'   {1}" -f $hint.Label.Text,
    (Mark ($lstBackupList.Items.Count -eq 0 -and $hint.Label.Text -match 'no such folder')))
Set-BackupFolderUi -Folder $work
Set-BackupProgressUi -Text 'Files: Pictures' -Done 3 -Total 10
Say ("  the strip says '{0}' at {1} of {2}   {3}" -f $lblBackupProgress.Text, $prgBackup.Value, $prgBackup.Maximum,
    (Mark ($lblBackupProgress.Text -eq 'Files: Pictures' -and $prgBackup.Value -eq 3 -and $prgBackup.Maximum -eq 10)))
$null = Show-BackupAt -Path $work
Say ("  a folder without a manifest is refused   {0}" -f (Mark ($script:backupPath -eq $zipPath)))

Say ''
Say '== stopping, and saying so =='
Say ("  a phone that has gone is recognised   {0}" -f (Mark (
    (Test-BackupDeviceGone -Text "adb: error: device 'ABC123' not found") -and
    (Test-BackupDeviceGone -Text 'error: device offline') -and
    -not (Test-BackupDeviceGone -Text '1 file pushed, 0 skipped.'))))

Start-BackupRun
Say ("  a fresh run is not stopped   {0}" -f (Mark ((-not (Test-BackupStopped)) -and (Test-BackupRunning))))
Stop-BackupRun -Reason 'you cancelled it'
Say ("  Cancel stops it and says why: '{0}'   {1}" -f (Get-BackupStopReason),
    (Mark ((Test-BackupStopped) -and (Get-BackupStopReason) -eq 'you cancelled it')))
Stop-BackupRun -Reason 'something else'
Say ("  the first reason is the one kept   {0}" -f (Mark ((Get-BackupStopReason) -eq 'you cancelled it')))
Complete-BackupRun
Say ("  and a stop after the run has ended is ignored   {0}" -f (Mark (-not (Test-BackupRunning))))

# packing cancelled halfway leaves no half zip behind, and keeps the folder
Start-BackupRun
Stop-BackupRun -Reason 'you cancelled it'
$halfZip = Join-Path $work 'half.zip'
$half = Compress-BackupFolder -Folder $folder -ZipPath $halfZip
Complete-BackupRun
Say ("  packing stopped: '{0}', no half zip left, the folder is still there   {1}" -f $half.Stopped, (Mark (
    -not $half.Ok -and $half.Stopped -eq 'you cancelled it' -and -not (Test-Path -LiteralPath $halfZip) -and
    (Test-Path -LiteralPath (Join-Path $folder 'manifest.json')))))

# Cancel in the middle: the first file stops it, and the rest are never sent
$plan = Get-BackupFilePlan -Source $folder
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @()
$cancelled = & {
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        if (Test-BackupStopped) { return [PSCustomObject]@{ ExitCode = 1; Text = 'stopped'; Stopped = $true } }
        $script:calls++
        if ($script:calls -eq 1) { Stop-BackupRun -Reason 'you cancelled it' }
        return [PSCustomObject]@{ ExitCode = 0; Text = '1 file pushed'; Stopped = $false }
    }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    $script:calls = 0
    $result = Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'replace'
    [PSCustomObject]@{ Result = $result; Calls = $script:calls }
}
Say ("  a restore cancelled after the first file sends one, not two: {0} call(s)   {1}" -f $cancelled.Calls,
    (Mark ($cancelled.Calls -eq 1 -and $cancelled.Result.Sent -eq 1 -and $cancelled.Result.Stopped -eq 'you cancelled it')))

# the phone unplugged halfway: adb says so, and the run ends there
$gone = & {
    function Invoke-BackupAdb {
        param($ArgumentList, $Caption, $Expected, $OnPoll)
        if (Test-BackupStopped) { return [PSCustomObject]@{ ExitCode = 1; Text = 'stopped'; Stopped = $true } }
        Stop-BackupRun -Reason 'the phone was disconnected'
        return [PSCustomObject]@{ ExitCode = 1; Text = "adb: error: device 'ABC123' not found"; Stopped = $true }
    }
    function Invoke-DeviceShell { param($Serial, $CommandArguments) return [PSCustomObject]@{ Lines = @(); Text = ''; ExitCode = 0 } }
    Restore-BackupFiles -Plan $plan -Serial 'ABC123' -OnConflict 'replace'
}
Say ("  a phone unplugged halfway ends it: '{0}', {1} sent   {2}" -f $gone.Stopped, $gone.Sent,
    (Mark ($gone.Stopped -eq 'the phone was disconnected' -and $gone.Sent -eq 0)))

$logBefore = $txtLog.TextLength
Send-BackupNotice -Title 'Backup done' -Text '2 file(s) from a made-up phone.'
$said = $txtLog.Text.Substring($logBefore)
Say ("  finishing says so in the log   {0}" -f (Mark ($said -match 'Backup done' -and $said -match 'made-up phone')))

Say ("  a name can be typed for a backup, and packing can be turned off   {0}" -f (Mark (
    $txtBackupName.Text -eq '' -and $chkBackupPack.Checked)))
Set-BackupBusyUi -Running $true
Say ("  while it runs, Cancel is the only button that works   {0}" -f (Mark (
    $btnBackupCancel.Enabled -and -not $btnBackupRun.Enabled -and -not $btnRestoreFiles.Enabled -and
    -not $btnBackupSaveCopy.Enabled -and -not $btnBackupListOpen.Enabled -and -not $btnBackupWhereBrowse.Enabled -and
    -not $btnBackupListDelete.Enabled)))
Set-BackupBusyUi -Running $false
Say ("  and afterwards the buttons are back   {0}" -f (Mark (
    (-not $btnBackupCancel.Enabled) -and $btnBackupRun.Enabled -and $btnRestoreFiles.Enabled -and $prgBackup.Value -eq 0)))

Say ''
Say '== a real backup, reading only =='
$attached = @(Get-AdbDevices | Where-Object { $_.Serial -eq $TestSerial -and $_.State -eq 'device' }).Count -gt 0
if (-not $TestSerial -or -not $attached) {
    Say 'SKIPPED - no phone attached right now'
} else {
    Select-TestPhone
    $real = Invoke-PhoneBackup -Serial $TestSerial -Destination $work -Parts @('settings') -Model 'test phone'
    Say ("  it made one file, not a folder: {0}   {1}" -f [System.IO.Path]::GetFileName($real.Path),
        (Mark ($real.Kind -eq 'zip' -and (Test-Path -LiteralPath $real.Path -PathType Leaf) -and
            -not (Test-Path -LiteralPath ($real.Path -replace '\.zip$', '')))))
    $realSource = Open-BackupSource -Path $real.Path
    $realEntries = @(Get-BackupSourceEntries -Source $realSource)
    $written = @($realEntries | Where-Object { $_.Path -like 'settings/*' })
    $properties = (Get-BackupEntryText -Source $realSource -Entry 'settings/properties.txt')
    Say ("  {0} file(s) of settings inside it, properties among them   {1}" -f $written.Count,
        (Mark ($written.Count -ge 6 -and $properties -match 'ro.build.version.release')))
    Say ("  its manifest reads back: parts {0}, serial matches   {1}" -f (@($realSource.Manifest.Parts) -join ','),
        (Mark ((@($realSource.Manifest.Parts) -join ',') -eq 'settings' -and $realSource.Manifest.Serial -eq $TestSerial)))
    Say ("  nothing was written to the phone: only settings were asked for   {0}" -f (Mark (
        @($realEntries | Where-Object { $_.Path -like 'files/*' -or $_.Path -like 'apps/*' }).Count -eq 0)))
    Say ("  the list looks where it was put, and finds it   {0}" -f (Mark (
        (Get-BackupFolderPath) -eq $work -and
        @(Get-BackupsInFolder -Folder $work | Where-Object { $_.Path -eq $real.Path }).Count -eq 1)))
}
