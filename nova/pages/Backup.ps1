# pages\Backup.ps1 - a copy of the phone on this PC, and putting one back. The
# work itself is ..\shared\Backup.ps1, which the classic window uses as well
# (Advanced > Backup); this page ticks what goes in, lists the backups this PC
# has, shows every file inside the open one, and asks before anything on the
# phone is written over.

$script:backupPath = ''
$script:backupSource = $null
$script:backupManifest = $null
$script:backupAppRows = @()
$script:backupAppBoxes = @()
$script:backupInsideRows = @()
$script:backupListRows = @()
# a phone can hold tens of thousands of files; a list that long takes a visible
# pause to fill, so the rest wait behind the find box
$script:backupInsideMax = 3000

$backupPage = Register-Page -Key 'backup' -Title 'Backup' -Glyph 'E8F7' -Section 'System' -Xaml 'Backup.xaml' `
    -OnShow { Update-BackupPageApps; Update-BackupPageList } `
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

function Set-BackupPageBusy {
    # while a backup or a restore runs, Cancel is the only button that works
    param([bool]$Running)

    $ui.BackupCancel.IsEnabled = $Running
    foreach ($name in @('BackupRun', 'BackupOpen', 'BackupOpenFolder', 'BackupRestoreFiles', 'BackupInstallApps',
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListOpen', 'BackupListLook', 'BackupListForget')) {
        $ui[$name].IsEnabled = -not $Running
    }
    if (-not $Running) {
        $ui.BackupProgress.IsIndeterminate = $false
        $ui.BackupProgress.Value = 0
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
    if (-not $script:backupSource) { return }

    $serial = Get-SelectedSerial
    $script:backupAppRows = @(Get-BackupAppRows -Source $script:backupSource -Serial $(if ($serial) { $serial } else { '' }))
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

function Update-BackupPageInside {
    # every file in the opened backup, read from its index - nothing is unpacked
    $rows = @()
    if ($script:backupSource) { $rows = @(Get-BackupInsideRows -Source $script:backupSource -Filter $ui.BackupFind.Text) }
    $script:backupInsideRows = $rows

    $bytes = [long]0
    foreach ($row in $rows) { $bytes += $row.Bytes }
    $shown = $rows
    if ($rows.Count -gt $script:backupInsideMax) { $shown = @($rows[0..($script:backupInsideMax - 1)]) }
    $ui.BackupInside.ItemsSource = $shown

    if (-not $script:backupSource) {
        $ui.BackupInsideCount.Text = 'Nothing open.'
    } elseif ($rows.Count -gt $shown.Count) {
        $ui.BackupInsideCount.Text = ('{0} file(s), {1} - the first {2} are listed' -f $rows.Count,
            (Format-FileSize -Bytes $bytes), $shown.Count)
    } else {
        $ui.BackupInsideCount.Text = ('{0} file(s), {1}' -f $rows.Count, (Format-FileSize -Bytes $bytes))
    }
    $ui.BackupInsideCount.ToolTip = $ui.BackupInsideCount.Text
}

function Update-BackupPageList {
    # the backups this PC has taken, newest first, each checked for being there
    $script:backupListRows = @(Get-BackupListRows)
    $ui.BackupList.ItemsSource = $script:backupListRows
}

function Get-BackupPagePick {
    # the backup picked in the list, or nothing when none is
    $row = $ui.BackupList.SelectedItem
    if ($null -eq $row) { return $null }
    return $row
}

function Show-BackupPageAt {
    # what a backup holds - the .zip it is, or the folder an older one was;
    # $false when that path is not a backup at all
    param([Alias('Folder')][string]$Path)

    $source = Open-BackupSource -Path $Path
    if ($null -eq $source) {
        Write-Log "That holds no manifest.json, so it is not a backup: $Path" $colorBad
        return $false
    }
    $script:backupSource = $source
    $script:backupPath = $source.Path
    $script:backupManifest = $source.Manifest
    $ui.BackupInfo.Text = ((@($source.Path) + @(Get-BackupSummaryLines -Manifest $source.Manifest -Source $source)) -join '   |   ')
    $ui.BackupInfo.ToolTip = $ui.BackupInfo.Text
    Update-BackupPageApps
    Update-BackupPageInside
    Write-Log "Backup opened: $($source.Path)" $colorInfo
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

    Set-BackupPageBusy -Running $true
    try {
        $manifest = Invoke-PhoneBackup -Serial $serial -Destination $where -Parts $parts -Model $model
    } finally {
        Set-BackupPageBusy -Running $false
    }
    if ($manifest) {
        $null = Show-BackupPageAt -Path $manifest.Path
        Update-BackupPageList
        if ($manifest.Complete) { Show-Toast -Text 'Backup done' -Color 'good' }
        else { Show-Toast -Text "Backup stopped: $($manifest.Stopped)" -Color 'warn' }
    }
}

function Open-BackupPageFile {
    $folder = ''
    if ($script:backupPath -and (Test-Path -LiteralPath $script:backupPath)) { $folder = Split-Path -Parent $script:backupPath }
    $picked = @(Select-OpenFiles -Filter 'Backup (*.zip)|*.zip|Every file (*.*)|*.*' -InitialDirectory $folder)
    if ($picked.Count -eq 0) { return }
    if (Show-BackupPageAt -Path $picked[0]) {
        $null = Add-BackupToList -Path $picked[0] -Manifest $script:backupManifest -Kind 'zip'
    }
    Update-BackupPageList
}

function Open-BackupPageFolder {
    $where = Select-Folder -Description 'Pick a backup folder - the one with manifest.json in it' -Selected $script:backupPath
    if (-not $where) { return }
    if (Show-BackupPageAt -Path $where) {
        $null = Add-BackupToList -Path $where -Manifest $script:backupManifest -Kind 'folder'
    }
    Update-BackupPageList
}

function Open-BackupPagePicked {
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    if ($row.Missing) {
        Write-Log "That backup is not where it was put any more: $($row.Path)" $colorWarn
        Write-Log '  Use "Look in a folder" to find it again, or Forget to take the line out.' $colorInfo
        return
    }
    $null = Show-BackupPageAt -Path $row.Path
    $ui.BackupTabs.SelectedItem = $ui.BackupTabInside
}

function Show-BackupPagePath {
    # a file is picked out in its folder; a folder is opened
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Log 'That backup is not there any more.' $colorWarn
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"')
    } else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $Path + '"')
    }
}

function Show-BackupPagePicked {
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    Show-BackupPagePath -Path $row.Path
}

function Add-BackupPageFolder {
    $where = Select-Folder -Description 'Which folder should be looked through for backups?'
    if (-not $where) { return }
    $added = Add-BackupFolderToList -Folder $where
    Update-BackupPageList
    Show-Toast -Text "$added backup(s) added to the list" -Color $(if ($added -gt 0) { 'good' } else { 'warn' })
}

function Remove-BackupPagePicked {
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    $null = Remove-BackupFromList -Path $row.Path
    Write-Log "Forgotten (the file itself is untouched): $($row.Path)" $colorInfo
    Update-BackupPageList
}

function Save-BackupPageCopy {
    # files out of the backup onto this PC, without a phone in it at all
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }
    $entries = @()
    foreach ($row in @($ui.BackupInside.SelectedItems)) { $entries += "$($row.Entry)" }
    if ($entries.Count -eq 0) { Write-Log 'Pick the files to save in the list first.' $colorWarn; return }

    $where = Select-Folder -Description "Where should these $($entries.Count) file(s) be written?"
    if (-not $where) { return }
    Set-BackupPageBusy -Running $true
    try {
        $result = Save-BackupCopy -Source $script:backupSource -Entries $entries -Destination $where
    } finally {
        Set-BackupPageBusy -Running $false
    }
    Show-Toast -Text "$($result.Saved) file(s) saved" -Color $(if ($result.Failed -gt 0) { 'warn' } else { 'good' })
}

function Start-BackupPageFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }

    $plan = Get-BackupFilePlan -Source $script:backupSource
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
    Set-BackupPageBusy -Running $true
    try {
        $result = Restore-BackupFiles -Plan $plan -Serial $serial -OnConflict $mode
    } finally {
        Set-BackupPageBusy -Running $false
    }
    if ($result.Stopped) { Show-Toast -Text "Restore stopped: $($result.Stopped)" -Color 'warn' }
    else { Show-Toast -Text "$($result.Sent) file(s) sent" -Color 'good' }
}

function Start-BackupPageApps {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }

    $picked = @()
    foreach ($box in $script:backupAppBoxes) {
        if (-not $box.IsChecked) { continue }
        foreach ($row in $script:backupAppRows) { if ($row.Package -eq "$($box.Tag)") { $picked += $row } }
    }
    if ($picked.Count -eq 0) { Write-Log 'Tick the apps to install first.' $colorWarn; return }
    Set-BackupPageBusy -Running $true
    try {
        $result = Restore-BackupApps -Rows $picked -Serial $serial -Source $script:backupSource
    } finally {
        Set-BackupPageBusy -Running $false
    }
    if ($result.Stopped) { Show-Toast -Text "Installing stopped: $($result.Stopped)" -Color 'warn' }
    else { Show-Toast -Text "$($result.Installed) app(s) installed" -Color 'good' }
    Update-BackupPageApps
}

function Start-BackupPageContacts {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }
    Set-BackupPageBusy -Running $true
    try {
        $result = Restore-BackupContacts -Source $script:backupSource -Serial $serial
    } finally {
        Set-BackupPageBusy -Running $false
    }
    if ($result.Stopped) { Show-Toast -Text "Contacts stopped: $($result.Stopped)" -Color 'warn' }
    else { Show-Toast -Text "$($result.Added) contact(s) added" -Color 'good' }
}

function Show-BackupPageFolder {
    if (-not $script:backupPath) { Write-Log 'Open a backup first.' $colorWarn; return }
    Show-BackupPagePath -Path $script:backupPath
}

# ------------------------------------------------------------------ events ----

$ui.BackupRun.Add_Click({ Start-BackupPageNow })
$ui.BackupCancel.Add_Click({
    Write-Log 'Stopping ...' $colorWarn
    Stop-BackupRun -Reason 'you cancelled it'
})
$ui.BackupOpen.Add_Click({ Open-BackupPageFile })
$ui.BackupOpenFolder.Add_Click({ Open-BackupPageFolder })
$ui.BackupRestoreFiles.Add_Click({ Start-BackupPageFiles })
$ui.BackupInstallApps.Add_Click({ Start-BackupPageApps })
$ui.BackupRestoreContacts.Add_Click({ Start-BackupPageContacts })
$ui.BackupShowFolder.Add_Click({ Show-BackupPageFolder })
$ui.BackupListRefresh.Add_Click({ Update-BackupPageList })
$ui.BackupListOpen.Add_Click({ Open-BackupPagePicked })
$ui.BackupListShow.Add_Click({ Show-BackupPagePicked })
$ui.BackupListLook.Add_Click({ Add-BackupPageFolder })
$ui.BackupListForget.Add_Click({ Remove-BackupPagePicked })
$ui.BackupSaveCopy.Add_Click({ Save-BackupPageCopy })
$ui.BackupList.Add_MouseDoubleClick({ Open-BackupPagePicked })
# the find box filters as it is typed
$ui.BackupFind.Add_TextChanged({ Update-BackupPageInside })

if (Test-BackupShared) {
    Initialize-Backup -Progress { param($Text, $Done, $Total) Set-BackupPageProgress -Text $Text -Done $Done -Total $Total }
    Update-BackupPageList
} else {
    $ui.BackupInfo.Text = 'shared\Backup.ps1 is not in the project folder: no backups from here.'
    foreach ($name in @('BackupRun', 'BackupOpen', 'BackupOpenFolder', 'BackupRestoreFiles', 'BackupInstallApps',
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListRefresh', 'BackupListOpen', 'BackupListShow',
        'BackupListLook', 'BackupListForget')) {
        $ui[$name].IsEnabled = $false
    }
}
