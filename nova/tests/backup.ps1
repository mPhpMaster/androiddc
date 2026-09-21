# The Backup page: it opens and fits, the tick boxes say what goes in, a
# made-up backup is packed into a .zip and read back out of it, the list of
# backups this PC has fills, and the file plan marks what a phone already has.
# Nothing is sent to a phone: the phone in the checks is made up, and the
# page's buttons are not pressed.

$work = Join-Path $TestOut 'backup-work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work
# one spelling of it: %TEMP% is handed out short (LONGNA~1) and everything the
# program writes down says the long one, so the two would never compare equal
$work = (Get-Item -LiteralPath $work).FullName

Say '== loaded =='
Say ("  shared\Backup.ps1 found in the project folder   {0}" -f (Mark (Test-BackupShared)))
$parts = @(Get-BackupParts)
Say ("  {0} parts: {1}   {2}" -f $parts.Count, ((@($parts | ForEach-Object { $_.Id })) -join ', '),
    (Mark ((@($parts | ForEach-Object { $_.Id }) -join ',') -eq 'files,apps,personal,settings')))
Say ("  the page ticks all four by default   {0}" -f (Mark (((Get-BackupPageParts) -join ',') -eq 'files,apps,personal,settings')))

Say ''
Say '== a backup folder, packed into one .zip =='
$folder = Join-Path $work 'AndroidDC-backup-test'
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'files\Pictures') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'apps\com.example.app') -Force
Set-Content -LiteralPath (Join-Path $folder 'files\Pictures\one.jpg') -Value 'picture one' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $folder 'apps\com.example.app\base.apk') -Value 'not really an apk' -Encoding Ascii
Save-BackupText -Path (Join-Path $folder 'apps\apps.json') -Text (ConvertTo-Json -Depth 4 -InputObject @(
    [PSCustomObject]@{ Package = 'com.example.app'; Name = 'Example'; Version = '42'; Files = @('base.apk'); Bytes = 17 }))
Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-20T14:05:09'
    Parts = @('files', 'apps'); Files = [PSCustomObject]@{ Files = 1; Bytes = 11 }
    Apps = @([PSCustomObject]@{ Package = 'com.example.app'; Files = @('base.apk'); Bytes = 17 })
    Personal = $null; Settings = @(); Bytes = 28; Complete = $true; Stopped = ''
}))

$zipPath = Join-Path $work 'AndroidDC-backup-test.zip'
Start-BackupRun
$packed = Compress-BackupFolder -Folder $folder -ZipPath $zipPath
Complete-BackupRun
Say ("  {0} file(s) packed into {1}   {2}" -f $packed.Files, (Format-FileSize -Bytes $packed.Bytes),
    (Mark ($packed.Ok -and $packed.Files -eq 4 -and (Test-Path -LiteralPath $zipPath -PathType Leaf))))

Show-Page -Page 'backup'
$null = Wait-Idle
$ui.BackupTabs.SelectedItem = $ui.BackupTabList
$null = Wait-Idle
$shown = Show-BackupPageAt -Path $zipPath
Say ("  it names the phone and what is in it: {0}" -f $ui.BackupInfo.Text)
Say ("  opened from the .zip, and read no further than the manifest   {0}" -f (Mark (
    $shown -and $ui.BackupInfo.Text -match 'Redmi 13C' -and $ui.BackupInfo.Text -match 'Packed:' -and
    $script:backupAppRows.Count -eq 0 -and $script:backupInsideRows.Count -eq 0)))
$ui.BackupTabs.SelectedItem = $ui.BackupTabApps
$null = Wait-Idle
$appRow = @($script:backupAppRows)[0]
Say ("  the apps tab, read when it is looked at: {0} | {1} | {2} | {3}" -f $appRow.Shown, $appRow.Package,
    $appRow.Held, $appRow.Says)
Say ("  it says the app's name and its version, not just the package   {0}" -f (Mark (
    $script:backupAppRows.Count -eq 1 -and $appRow.Shown -eq 'Example' -and $appRow.Held -eq 'version 42')))
Say ("  the one this phone does not have is picked out, and the line says what to press: '{0}'   {1}" -f
    $ui.BackupAppsCount.Text, (Mark (@($ui.BackupAppList.SelectedItems).Count -eq 1 -and
        $ui.BackupAppsCount.Text -match 'Install picked apps')))
$ui.BackupAppFind.Text = 'nothing like this'
$null = Wait-Idle
Say ("  the find box over the apps leaves {0} on screen   {1}" -f $ui.BackupAppList.Items.Count,
    (Mark ($ui.BackupAppList.Items.Count -eq 0)))
$ui.BackupAppFind.Text = ''
$null = Wait-Idle
Say ("  a folder without a manifest is refused   {0}" -f (Mark (
    (Show-BackupPageAt -Path $work) -eq $false -and $script:backupPath -eq $zipPath)))

Say ''
Say '== what is inside it =='
$ui.BackupTabs.SelectedItem = $ui.BackupTabInside
$null = Wait-Idle
Say ("  all four files are listed: {0}" -f ((@($script:backupInsideRows | ForEach-Object { $_.Path }) | Sort-Object) -join ', '))
Say ("  each says which part it is in   {0}" -f (Mark (
    $script:backupInsideRows.Count -eq 4 -and
    @($script:backupInsideRows | Where-Object { $_.Path -eq '/sdcard/Pictures/one.jpg' -and $_.What -eq 'Files' }).Count -eq 1)))
$ui.BackupFind.Text = 'Pictures'
# the box waits a moment before it filters, so a word typed letter by letter
# does not walk the whole backup five times
Start-Sleep -Milliseconds 400
$null = Wait-Idle
Say ("  the find box leaves {0}, and the line under it says so: '{1}'   {2}" -f $script:backupInsideRows.Count,
    $ui.BackupInsideCount.Text, (Mark ($script:backupInsideRows.Count -eq 1 -and $ui.BackupInsideCount.Text -match '^1 file')))
$ui.BackupFind.Text = ''
Start-Sleep -Milliseconds 400
$null = Wait-Idle
Say ("  emptying it brings them all back   {0}" -f (Mark ($script:backupInsideRows.Count -eq 4)))

$saved = Join-Path $work 'saved'
$copy = Save-BackupCopy -Source $script:backupSource -Entries @('files/Pictures/one.jpg') -Destination $saved
Say ("  a file saved out of the zip reads back   {0}" -f (Mark (
    $copy.Saved -eq 1 -and (Get-Content -LiteralPath (Join-Path $saved 'files\Pictures\one.jpg') -Raw) -match 'picture one')))

Say ''
Say '== the backups in a folder =='
Say ("  the file the test writes is its own, not yours   {0}" -f (Mark ((Get-BackupListFile) -like '*backups-backup.json')))
Set-BackupPageFolder -Folder $work -Remember
$null = Wait-Idle
$row = @($script:backupListRows | Where-Object { $_.Path -eq $zipPath })[0]
Say ("  one line: {0} | {1} | {2} | {3}" -f $row.When, $row.Phone, $row.Holds, $row.State)
Say ("  the box says where to look, and the list shows the zip and the folder beside it   {0}" -f (Mark (
    $ui.BackupWhere.Text -eq $work -and $script:backupListRows.Count -eq 2 -and
    $row.Phone -match 'Redmi 13C' -and $row.Holds -eq 'files, apps' -and $row.State -eq 'complete')))
Say ("  and the page's list shows those lines   {0}" -f (Mark (@($ui.BackupList.ItemsSource).Count -eq 2)))
Say ("  the folder is remembered for both windows   {0}" -f (Mark ((Get-BackupFolderPath) -eq $work)))
Set-BackupPageFolder -Folder (Join-Path $work 'no-such-folder')
$null = Wait-Idle
Say ("  a folder that is not there lists nothing   {0}" -f (Mark ($script:backupListRows.Count -eq 0)))
Set-BackupPageFolder -Folder $work

Say ''
Say '== which files a phone already has =='
$plan = Get-BackupFilePlan -Source $script:backupSource
Say ("  {0} file(s), going to {1}   {2}" -f $plan.Total, (@($plan.Items | ForEach-Object { $_.Remote }) -join ','),
    (Mark ($plan.Total -eq 1 -and $plan.Items[0].Remote -eq '/sdcard/Pictures/one.jpg')))
Say ("  and it lies in the zip, not on this PC   {0}" -f (Mark (-not "$($plan.Items[0].Local)")))
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @('/sdcard/Pictures/one.jpg')
Say ("  a phone that has it: {0} already there   {1}" -f $plan.Existing, (Mark ($plan.Existing -eq 1)))
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @()
Say ("  a phone without it: {0} already there   {1}" -f $plan.Existing, (Mark ($plan.Existing -eq 0)))

Say ''
Say '== stopping, and saying so =='
Say ("  a phone that has gone is recognised   {0}" -f (Mark (
    (Test-BackupDeviceGone -Text "adb: error: device 'ABC123' not found") -and
    -not (Test-BackupDeviceGone -Text '1 file pushed, 0 skipped.'))))
Start-BackupRun
Stop-BackupRun -Reason 'you cancelled it'
Say ("  Cancel stops it and says why: '{0}'   {1}" -f (Get-BackupStopReason),
    (Mark ((Test-BackupStopped) -and (Get-BackupStopReason) -eq 'you cancelled it')))
$halfZip = Join-Path $work 'half.zip'
$half = Compress-BackupFolder -Folder $folder -ZipPath $halfZip
Complete-BackupRun
Say ("  packing stopped leaves no half zip behind   {0}" -f (Mark (
    -not $half.Ok -and -not (Test-Path -LiteralPath $halfZip) -and (Test-Path -LiteralPath (Join-Path $folder 'manifest.json')))))

$logBefore = @(Get-LogText -split "`n").Count
Send-BackupNotice -Title 'Backup done' -Text '1 file from a made-up phone.'
Say ("  finishing says so in the log   {0}" -f (Mark ((Get-LogText) -match 'Backup done')))

Set-BackupPageBusy -Running $true
Say ("  while it runs, Cancel is the only button that works   {0}" -f (Mark (
    $ui.BackupCancel.IsEnabled -and -not $ui.BackupRun.IsEnabled -and -not $ui.BackupRestoreFiles.IsEnabled -and
    -not $ui.BackupSaveCopy.IsEnabled -and -not $ui.BackupListOpen.IsEnabled -and -not $ui.BackupBrowse.IsEnabled -and
    -not $ui.BackupAppsMissing.IsEnabled)))
Set-BackupPageBusy -Running $false
Say ("  and afterwards the buttons are back   {0}" -f (Mark (
    (-not $ui.BackupCancel.IsEnabled) -and $ui.BackupRun.IsEnabled -and $ui.BackupRestoreFiles.IsEnabled)))

Say ''
Say '== fitting the window =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize -Size $size
    $null = Wait-Idle
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture -Name "backup-$size"))
    $outside = @(Get-OutsideElements -Root $backupPage.Root)
    Say ("  {0}: nothing sticks out{1}   {2}" -f $size, $(if ($outside) { ' - ' + ($outside -join '; ') } else { '' }),
        (Mark ($outside.Count -eq 0)))
}
