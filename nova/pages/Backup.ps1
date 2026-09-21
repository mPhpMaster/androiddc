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
# what is inside, and the apps, are read when their tab is looked at - a backup
# of forty thousand files would otherwise be read before the card even says
# whose phone it is
$script:backupInsideStale = $true
$script:backupAppsStale = $true
# named here, not where it is made: reading a variable that was never assigned
# is an error under Set-StrictMode
$script:backupFindTimer = $null
# a phone can hold tens of thousands of files; a list that long takes a visible
# pause to fill, so the rest wait behind the find box
$script:backupInsideMax = 3000

$backupPage = Register-Page -Key 'backup' -Title 'Backup' -Glyph 'E8F7' -Section 'System' -Xaml 'Backup.xaml' `
    -OnShow { Update-BackupPageShownTab } `
    -OnDeviceChanged {
        # the phone decides which apps are ticked, so they are read again - but
        # only if that tab is the one being looked at
        $script:backupAppsStale = $true
        if (Test-PageShown -Key 'backup') { Update-BackupPageShownTab }
    }

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
    foreach ($name in @('BackupRun', 'BackupOpen', 'BackupRestoreFiles', 'BackupInstallApps',
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListOpen', 'BackupBrowse')) {
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

function Set-BackupPageReading {
    # reading a backup is not a run that can be cancelled, but it can take a
    # moment, and the page says so instead of going quiet
    param([bool]$Running)

    if ($Running) {
        $ui.BackupProgressText.Text = 'Reading the backup ...'
        $ui.BackupProgress.IsIndeterminate = $true
    } else {
        $ui.BackupProgress.IsIndeterminate = $false
        $ui.BackupProgress.Value = 0
    }
    $null = Wait-Pumped -Milliseconds 1
}

function Update-BackupPageShownTab {
    # fills the tab that is on screen, once, and leaves the others alone
    if ($ui.BackupTabs.SelectedItem -eq $ui.BackupTabInside -and $script:backupInsideStale) { Update-BackupPageInside }
    elseif ($ui.BackupTabs.SelectedItem -eq $ui.BackupTabApps -and $script:backupAppsStale) { Update-BackupPageApps }
}

function Update-BackupPageApps {
    # the apps in the opened backup, ticked where this phone does not have them
    $ui.BackupAppList.Children.Clear()
    $script:backupAppBoxes = @()
    $script:backupAppsStale = $false
    if (-not $script:backupSource) { return }

    Set-BackupPageReading -Running $true
    try {
        $serial = Get-SelectedSerial
        $script:backupAppRows = @(Get-BackupAppRows -Source $script:backupSource -Serial $(if ($serial) { $serial } else { '' }))
        $boxes = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:backupAppRows) {
            $box = New-Object System.Windows.Controls.CheckBox
            $box.Content = ('{0}   {1}   {2}' -f $row.Package, $row.Size, $row.State)
            $box.Tag = $row.Package
            $box.IsChecked = ($row.State -eq 'missing')
            $box.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
            $null = $ui.BackupAppList.Children.Add($box)
            $null = $boxes.Add($box)
        }
        $script:backupAppBoxes = $boxes.ToArray()
    } finally {
        Set-BackupPageReading -Running $false
    }
}

function Update-BackupPageInside {
    # every file in the opened backup, read from its index - nothing is unpacked
    $script:backupInsideStale = $false
    if (-not $script:backupSource) {
        $ui.BackupInside.ItemsSource = $null
        $script:backupInsideRows = @()
        $ui.BackupInsideCount.Text = 'Nothing open.'
        return
    }

    Set-BackupPageReading -Running $true
    try {
        $found = Get-BackupInsideRows -Source $script:backupSource -Filter $ui.BackupFind.Text -Limit $script:backupInsideMax
        $script:backupInsideRows = $found.Rows
        $ui.BackupInside.ItemsSource = $found.Rows
        if ($found.Total -gt $found.Rows.Count) {
            $ui.BackupInsideCount.Text = ('{0} file(s), {1} - the first {2} are listed' -f $found.Total,
                (Format-FileSize -Bytes $found.Bytes), $found.Rows.Count)
        } else {
            $ui.BackupInsideCount.Text = ('{0} file(s), {1}' -f $found.Total, (Format-FileSize -Bytes $found.Bytes))
        }
    } finally {
        Set-BackupPageReading -Running $false
    }
    $ui.BackupInsideCount.ToolTip = $ui.BackupInsideCount.Text
}

function Update-BackupPageList {
    # the backups in the folder the box above says, newest first
    $folder = "$($ui.BackupWhere.Text)".Trim()
    $script:backupListRows = @(Get-BackupsInFolder -Folder $folder)
    $ui.BackupList.ItemsSource = $script:backupListRows
}

function Set-BackupPageFolder {
    # the folder the list looks in, remembered for both windows
    param([string]$Folder, [switch]$Remember)

    $ui.BackupWhere.Text = "$Folder"
    if ($Remember) { $null = Set-BackupFolderPath -Folder $Folder }
    Update-BackupPageList
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
    # the manifest is read here and nothing else; the two lists below read the
    # backup itself, and only when they are looked at
    $script:backupInsideStale = $true
    $script:backupAppsStale = $true
    $ui.BackupInside.ItemsSource = $null
    $ui.BackupAppList.Children.Clear()
    $script:backupAppBoxes = @()
    $ui.BackupInsideCount.Text = 'Open the tab to read what is inside.'
    Update-BackupPageShownTab
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
        # the list follows the backup just taken
        Set-BackupPageFolder -Folder $where
        if ($manifest.Complete) { Show-Toast -Text 'Backup done' -Color 'good' }
        else { Show-Toast -Text "Backup stopped: $($manifest.Stopped)" -Color 'warn' }
    }
}

function Open-BackupPageFile {
    $folder = "$($ui.BackupWhere.Text)".Trim()
    if ($script:backupPath -and (Test-Path -LiteralPath $script:backupPath)) { $folder = Split-Path -Parent $script:backupPath }
    $picked = @(Select-OpenFiles -Filter 'Backup (*.zip)|*.zip|Every file (*.*)|*.*' -InitialDirectory $folder)
    if ($picked.Count -eq 0) { return }
    if (Show-BackupPageAt -Path $picked[0]) {
        # the list follows the backup that was opened
        Set-BackupPageFolder -Folder (Split-Path -Parent $picked[0]) -Remember
    }
}

function Select-BackupPageFolder {
    $now = "$($ui.BackupWhere.Text)".Trim()
    $where = Select-Folder -Description 'Which folder are your backups kept in?' -Selected $now
    if (-not $where) { return }
    Set-BackupPageFolder -Folder $where -Remember
}

function Open-BackupPagePicked {
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $row.Path)) {
        Write-Log "That backup is not there any more: $($row.Path)" $colorWarn
        Update-BackupPageList
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

function Update-BackupPageFind {
    # the find box waits a moment: a backup can hold tens of thousands of files,
    # and each letter would walk them all
    if ($null -eq $script:backupFindTimer) {
        $script:backupFindTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:backupFindTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $null = $script:backupFindTimer.Add_Tick({
            $script:backupFindTimer.Stop()
            Update-BackupPageInside
        })
    }
    $script:backupFindTimer.Stop()
    $script:backupFindTimer.Start()
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
$ui.BackupBrowse.Add_Click({ Select-BackupPageFolder })
$ui.BackupRestoreFiles.Add_Click({ Start-BackupPageFiles })
$ui.BackupInstallApps.Add_Click({ Start-BackupPageApps })
$ui.BackupRestoreContacts.Add_Click({ Start-BackupPageContacts })
$ui.BackupShowFolder.Add_Click({ Show-BackupPageFolder })
$ui.BackupListRefresh.Add_Click({ Update-BackupPageList })
$ui.BackupListOpen.Add_Click({ Open-BackupPagePicked })
$ui.BackupListShow.Add_Click({ Show-BackupPagePicked })
$ui.BackupSaveCopy.Add_Click({ Save-BackupPageCopy })
$ui.BackupList.Add_MouseDoubleClick({ Open-BackupPagePicked })
$ui.BackupFind.Add_TextChanged({ Update-BackupPageFind })
# a path typed in by hand: Enter reads it, and so does leaving the box
$ui.BackupWhere.Add_KeyDown({
    param($eventSender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) {
        $eventArgs.Handled = $true
        Set-BackupPageFolder -Folder "$($ui.BackupWhere.Text)".Trim() -Remember
    }
})
$ui.BackupWhere.Add_LostFocus({
    if ("$($ui.BackupWhere.Text)".Trim() -ne "$(Get-BackupFolderPath)") {
        Set-BackupPageFolder -Folder "$($ui.BackupWhere.Text)".Trim() -Remember
    }
})
# a tab is filled when it is looked at, not when the backup is opened
$ui.BackupTabs.Add_SelectionChanged({
    param($eventSender, $eventArgs)
    if ($eventArgs.OriginalSource -ne $ui.BackupTabs) { return }
    Update-BackupPageShownTab
})

if (Test-BackupShared) {
    Initialize-Backup -Progress { param($Text, $Done, $Total) Set-BackupPageProgress -Text $Text -Done $Done -Total $Total }
    # the folder of the last backup, and what is in it, are there from the start
    $ui.BackupWhere.Text = Get-BackupFolderPath
    Update-BackupPageList
} else {
    $ui.BackupInfo.Text = 'shared\Backup.ps1 is not in the project folder: no backups from here.'
    foreach ($name in @('BackupRun', 'BackupOpen', 'BackupBrowse', 'BackupRestoreFiles', 'BackupInstallApps',
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListRefresh', 'BackupListOpen', 'BackupListShow')) {
        $ui[$name].IsEnabled = $false
    }
}
