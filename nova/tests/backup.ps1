# The Backup page: it opens and fits, the tick boxes say what goes in, a
# made-up backup folder is read back and its app listed, and the file plan
# marks what a phone already has. Nothing is sent to a phone: the phone in the
# checks is made up, and the page's buttons are not pressed.

$work = Join-Path $TestOut 'backup-work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work

Say '== loaded =='
Say ("  shared\Backup.ps1 found in the project folder   {0}" -f (Mark (Test-BackupShared)))
$parts = @(Get-BackupParts)
Say ("  {0} parts: {1}   {2}" -f $parts.Count, ((@($parts | ForEach-Object { $_.Id })) -join ', '),
    (Mark ((@($parts | ForEach-Object { $_.Id }) -join ',') -eq 'files,apps,personal,settings')))
Say ("  the page ticks all four by default   {0}" -f (Mark (((Get-BackupPageParts) -join ',') -eq 'files,apps,personal,settings')))

Say ''
Say '== a backup folder, read back =='
$folder = Join-Path $work 'AndroidDC-backup-test'
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'files\Pictures') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $folder 'apps\com.example.app') -Force
Set-Content -LiteralPath (Join-Path $folder 'files\Pictures\one.jpg') -Value 'picture one' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $folder 'apps\com.example.app\base.apk') -Value 'not really an apk' -Encoding Ascii
Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 1; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'; Created = '2026-09-20T14:05:09'
    Parts = @('files', 'apps'); Files = [PSCustomObject]@{ Files = 1; Bytes = 11 }
    Apps = @([PSCustomObject]@{ Package = 'com.example.app'; Files = @('base.apk'); Bytes = 17 })
    Personal = $null; Settings = @(); Bytes = 28
}))

Show-Page -Page 'backup'
$null = Wait-Idle
$shown = Show-BackupPageAt -Folder $folder
Say ("  it names the phone and what is in it: {0}" -f $ui.BackupInfo.Text)
Say ("  opened, and its app is listed and ticked   {0}" -f (Mark (
    $shown -and $ui.BackupInfo.Text -match 'Redmi 13C' -and $script:backupAppBoxes.Count -eq 1 -and $script:backupAppBoxes[0].IsChecked)))
Say ("  a folder without a manifest is refused   {0}" -f (Mark ((Show-BackupPageAt -Folder $work) -eq $false -and $script:backupFolder -eq $folder)))

Set-BackupPageProgress -Text 'Files: Pictures' -Done 3 -Total 10
Say ("  the strip says '{0}' at {1} of {2}   {3}" -f $ui.BackupProgressText.Text, $ui.BackupProgress.Value, $ui.BackupProgress.Maximum,
    (Mark ($ui.BackupProgressText.Text -eq 'Files: Pictures' -and $ui.BackupProgress.Value -eq 3 -and $ui.BackupProgress.Maximum -eq 10)))

Say ''
Say '== which files a phone already has =='
$plan = Get-BackupFilePlan -Folder $folder
Say ("  {0} file(s), going to {1}   {2}" -f $plan.Total, (@($plan.Items | ForEach-Object { $_.Remote }) -join ','),
    (Mark ($plan.Total -eq 1 -and $plan.Items[0].Remote -eq '/sdcard/Pictures/one.jpg')))
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @('/sdcard/Pictures/one.jpg')
Say ("  a phone that has it: {0} already there   {1}" -f $plan.Existing, (Mark ($plan.Existing -eq 1)))
$plan = Set-BackupFilePlanKnown -Plan $plan -RemotePaths @()
Say ("  a phone without it: {0} already there   {1}" -f $plan.Existing, (Mark ($plan.Existing -eq 0)))

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
