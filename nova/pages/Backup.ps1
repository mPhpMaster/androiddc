# pages\Backup.ps1 - a copy of the phone on this PC, and putting one back. The
# work itself is ..\shared\Backup.ps1, which the classic window uses as well
# (Advanced > Backup); this page ticks what goes in, shows what a backup holds,
# and asks before anything on the phone is written over.

$script:backupFolder = ''
$script:backupManifest = $null
$script:backupAppRows = @()
$script:backupAppBoxes = @()

$backupPage = Register-Page -Key 'backup' -Title 'Backup' -Glyph 'E8F7' -Section 'System' -Xaml 'Backup.xaml' `
    -OnShow { Update-BackupPageApps } `
    -OnDeviceChanged { if (Test-PageShown -Key 'backup') { Update-BackupPageApps } }

function Test-BackupShared {
    # shared\Backup.ps1 was found and loaded
    return [bool](Get-Command Invoke-PhoneBackup -ErrorAction SilentlyContinue)
}

function Set-BackupPageProgress {
    param([string]$Text, [int]$Done, [int]$Total)

    $ui.BackupProgressText.Text = $Text
    $ui.BackupProgressText.ToolTip = $Text
    if ($Total -gt 0 -and $Done -ge 0) {
        $ui.BackupProgress.IsIndeterminate = $false
        $ui.BackupProgress.Maximum = $Total
        $ui.BackupProgress.Value = [Math]::Max(0, [Math]::Min($Total, $Done))
    } else {
        $ui.BackupProgress.IsIndeterminate = $true
    }
}

function Get-BackupPageParts {
    $parts = @()
    if ($ui.BackupFiles.IsChecked) { $parts += 'files' }
    if ($ui.BackupApps.IsChecked) { $parts += 'apps' }
    if ($ui.BackupPersonal.IsChecked) { $parts += 'personal' }
    if ($ui.BackupSettings.IsChecked) { $parts += 'settings' }
    return $parts
}

function Update-BackupPageApps {
    # the apps in the opened backup, ticked where this phone does not have them
    $ui.BackupAppList.Children.Clear()
    $script:backupAppBoxes = @()
    if (-not $script:backupFolder) { return }

    $serial = Get-SelectedSerial
    $script:backupAppRows = @(Get-BackupAppRows -Folder $script:backupFolder -Serial $(if ($serial) { $serial } else { '' }))
    foreach ($row in $script:backupAppRows) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = ('{0}   {1}   {2}' -f $row.Package, $row.Size, $row.State)
        $box.Tag = $row.Package
        $box.IsChecked = ($row.State -eq 'missing')
        $box.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $null = $ui.BackupAppList.Children.Add($box)
        $script:backupAppBoxes += $box
    }
}

function Show-BackupPageAt {
    # what a backup folder holds; $false when that folder is not a backup
    param([string]$Folder)

    $manifest = Read-BackupManifest -Folder $Folder
    if ($null -eq $manifest) {
        Write-Log "That folder has no manifest.json, so it is not a backup: $Folder" $colorBad
        return $false
    }
    $script:backupFolder = $Folder
    $script:backupManifest = $manifest
    $ui.BackupInfo.Text = ((@($Folder) + @(Get-BackupSummaryLines -Manifest $manifest)) -join '   |   ')
    $ui.BackupInfo.ToolTip = $ui.BackupInfo.Text
    Update-BackupPageApps
    Write-Log "Backup opened: $Folder" $colorInfo
    return $true
}

function Start-BackupPageNow {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $parts = @(Get-BackupPageParts)
    if ($parts.Count -eq 0) { Write-Log 'Tick what should go into the backup first.' $colorWarn; return }

    $where = Select-Folder -Description 'Where should this backup be kept?'
    if (-not $where) { return }
    $device = Get-SelectedDevice
    $model = if ($device) { "$($device.Model)" } else { '' }

    $manifest = Invoke-PhoneBackup -Serial $serial -Destination $where -Parts $parts -Model $model
    if ($manifest) {
        $null = Show-BackupPageAt -Folder $manifest.Folder
        Show-Toast -Text 'Backup done' -Color 'good'
    }
}

function Open-BackupPageFolder {
    $where = Select-Folder -Description 'Pick a backup folder - the one with manifest.json in it' -Selected $script:backupFolder
    if (-not $where) { return }
    $null = Show-BackupPageAt -Folder $where
}

function Start-BackupPageFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupFolder) { Write-Log 'Open a backup first.' $colorWarn; return }

    $plan = Get-BackupFilePlan -Folder $script:backupFolder
    if ($plan.Total -eq 0) { Write-Log 'This backup holds no files.' $colorWarn; return }
    Write-Log 'Restore: reading what the phone already has ...' $colorStep
    $plan = Set-BackupFilePlanState -Plan $plan -Serial $serial

    $mode = 'skip'
    if ($plan.Existing -gt 0) {
        $answer = Show-Choice -Title 'Restore files' -Choices @('Write over them', 'Send only the rest') -Text (
            "$($plan.Existing) of $($plan.Total) file(s) in this backup are already on the phone.")
        if (-not $answer) { Write-Log 'Restore cancelled.' $colorWarn; return }
        if ($answer -eq 'Write over them') { $mode = 'replace' }
    }
    $null = Restore-BackupFiles -Plan $plan -Serial $serial -OnConflict $mode
}

function Start-BackupPageApps {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupFolder) { Write-Log 'Open a backup first.' $colorWarn; return }

    $picked = @()
    foreach ($box in $script:backupAppBoxes) {
        if (-not $box.IsChecked) { continue }
        foreach ($row in $script:backupAppRows) { if ($row.Package -eq "$($box.Tag)") { $picked += $row } }
    }
    if ($picked.Count -eq 0) { Write-Log 'Tick the apps to install first.' $colorWarn; return }
    $null = Restore-BackupApps -Rows $picked -Serial $serial
    Update-BackupPageApps
}

function Start-BackupPageContacts {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupFolder) { Write-Log 'Open a backup first.' $colorWarn; return }
    $null = Restore-BackupContacts -Folder $script:backupFolder -Serial $serial
}

function Show-BackupPageFolder {
    if (-not $script:backupFolder -or -not (Test-Path -LiteralPath $script:backupFolder)) {
        Write-Log 'Open a backup first.' $colorWarn
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:backupFolder + '"')
}

# ------------------------------------------------------------------ events ----

$ui.BackupRun.Add_Click({ Start-BackupPageNow })
$ui.BackupOpen.Add_Click({ Open-BackupPageFolder })
$ui.BackupRestoreFiles.Add_Click({ Start-BackupPageFiles })
$ui.BackupInstallApps.Add_Click({ Start-BackupPageApps })
$ui.BackupRestoreContacts.Add_Click({ Start-BackupPageContacts })
$ui.BackupShowFolder.Add_Click({ Show-BackupPageFolder })

if (Test-BackupShared) {
    Initialize-Backup -Progress { param($Text, $Done, $Total) Set-BackupPageProgress -Text $Text -Done $Done -Total $Total }
} else {
    $ui.BackupInfo.Text = 'shared\Backup.ps1 is not in the project folder: no backups from here.'
    foreach ($name in @('BackupRun', 'BackupOpen', 'BackupRestoreFiles', 'BackupInstallApps', 'BackupRestoreContacts')) {
        $ui[$name].IsEnabled = $false
    }
}
