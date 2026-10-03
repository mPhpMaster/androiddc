# pages\Backup.ps1 - a copy of the phone on this PC, and putting one back. The
# work itself is ..\shared\Backup.ps1, which the classic window uses as well
# (Advanced > Backup); this page ticks what goes in, lists the backups this PC
# has, shows every file inside the open one, and asks before anything on the
# phone is written over.

$script:backupPath = ''
$script:backupSource = $null
$script:backupManifest = $null
$script:backupAppRows = @()
$script:backupInsideRows = @()
$script:backupListRows = @()
# what is inside, and the apps, are read when their tab is looked at - a backup
# of forty thousand files would otherwise be read before the card even says
# whose phone it is
$script:backupInsideStale = $true
$script:backupAppsStale = $true
# the phone the user list was read from, and what each line of the box means:
# a line is a set of ids, so "everyone" and "just this one" are one question
$script:backupUsersFor = ''
$script:backupUserChoices = @()
# named here, not where it is made: reading a variable that was never assigned
# is an error under Set-StrictMode
$script:backupFindTimer = $null
# a phone can hold tens of thousands of files; a list that long takes a visible
# pause to fill, so the rest wait behind the find box
$script:backupInsideMax = 3000

$backupPage = Register-Page -Key 'backup' -Title 'Backup' -Glyph 'E8F7' -Section 'System' -Xaml 'Backup.xaml' `
    -OnShow { Update-BackupPageShownTab; Update-BackupPageUsers } `
    -OnDeviceChanged {
        # the phone decides which apps are ticked, so they are read again - but
        # only if that tab is the one being looked at
        $script:backupAppsStale = $true
        if (Test-PageShown -Key 'backup') { Update-BackupPageShownTab; Update-BackupPageUsers }
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
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListOpen', 'BackupBrowse', 'BackupAppsMissing',
        'BackupMenuOpen', 'BackupMenuShow', 'BackupMenuResume', 'BackupMenuDelete', 'BackupUsers')) {
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
    if ($ui.BackupCard.IsChecked) { $parts += 'card' }
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
    # the apps in the opened backup, with the ones this phone does not have
    # picked out: those are the ones there is anything to do about
    $script:backupAppsStale = $false
    $script:backupAppRows = @()
    if (-not $script:backupSource) {
        $ui.BackupAppList.ItemsSource = $null
        $ui.BackupAppsCount.Text = 'Open a backup to see the apps in it.'
        return
    }

    Set-BackupPageReading -Running $true
    try {
        $serial = Get-SelectedSerial
        $rows = @(Get-BackupAppRows -Source $script:backupSource -Serial $(if ($serial) { $serial } else { '' }))
        foreach ($row in $rows) {
            # two columns the list binds to, so the grid holds no logic of its own
            Add-Member -InputObject $row -NotePropertyName 'Held' -NotePropertyValue $(
                if ($row.Version) { "version $($row.Version)" } else { $row.Parts }) -Force
            Add-Member -InputObject $row -NotePropertyName 'Says' -NotePropertyValue $(
                if ($row.State -eq 'on the phone' -and $row.Phone) { "on the phone (version $($row.Phone))" } else { $row.State }) -Force
        }
        $script:backupAppRows = $rows
        $ui.BackupAppList.ItemsSource = $rows
        Set-BackupPageAppFilter
        Select-BackupPageMissing
    } finally {
        Set-BackupPageReading -Running $false
    }
}

function Set-BackupPageAppFilter {
    # the find box over the app list; the picks are kept while you look
    $find = "$($ui.BackupAppFind.Text)".Trim()
    if ($find) {
        Set-ListFilter -List $ui.BackupAppList -Accept {
            param($row)
            return ((Test-TextContains "$($row.Package)" $find) -or (Test-TextContains "$($row.Shown)" $find))
        }.GetNewClosure()
    } else {
        Set-ListFilter -List $ui.BackupAppList -Accept $null
    }
    Update-BackupPageAppsCount
}

function Select-BackupPageMissing {
    # picks out every app the phone does not have
    $ui.BackupAppList.SelectedItems.Clear()
    foreach ($row in $script:backupAppRows) {
        if ($row.State -eq 'not on the phone') { $null = $ui.BackupAppList.SelectedItems.Add($row) }
    }
    Update-BackupPageAppsCount
}

function Update-BackupPageAppsCount {
    $all = @($script:backupAppRows).Count
    $picked = @($ui.BackupAppList.SelectedItems).Count
    $missing = @($script:backupAppRows | Where-Object { $_.State -eq 'not on the phone' }).Count
    if ($all -eq 0) {
        $ui.BackupAppsCount.Text = 'This backup holds no apps.'
    } else {
        $ui.BackupAppsCount.Text = ('{0} app(s), {1} not on the phone, {2} picked - press "Install picked apps"' -f
            $all, $missing, $picked)
    }
    $ui.BackupAppsCount.ToolTip = $ui.BackupAppsCount.Text
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
    $ui.BackupAppList.ItemsSource = $null
    $script:backupAppRows = @()
    $ui.BackupInsideCount.Text = 'Open the tab to read what is inside.'
    $ui.BackupAppsCount.Text = 'Open the tab to see the apps in it.'
    Update-BackupPageShownTab
    Write-Log "Backup opened: $($source.Path)" $colorInfo
    return $true
}

function Update-BackupPageUsers {
    # who is on this phone, and which of them adb may read. It costs a handful
    # of adb calls, so it is read when the page is opened or the phone changes.
    param([switch]$Force)

    if (-not (Test-BackupShared)) { return }
    $serial = Get-SelectedSerial
    if (-not $serial) {
        $script:backupUsersFor = ''
        $ui.BackupUsersNote.Text = 'no phone picked'
        return
    }
    if (-not $Force -and $script:backupUsersFor -eq $serial) { return }
    $script:backupUsersFor = $serial

    $users = @(Get-BackupUsers -Serial $serial)
    $choices = New-Object System.Collections.Generic.List[object]
    foreach ($user in $users) {
        $text = $(if ($user.Id -le 0) { 'The main user (0)' } else { "User $($user.Id)" })
        if ("$($user.Name)") { $text += " - $($user.Name)" }
        # offered even when their files are shut: their app list, settings and
        # contacts can still be read, and a label is better than a missing line
        if (-not $user.Readable) { $text += ' (no files to read)' }
        $null = $choices.Add([PSCustomObject]@{ Text = $text; Ids = @($user.Id); Users = @($user) })
    }
    if ($users.Count -gt 1) {
        $null = $choices.Add([PSCustomObject]@{
            Text  = "Every user ($($users.Count))"
            Ids   = @($users | ForEach-Object { $_.Id })
            Users = @($users) })
    }
    if ($choices.Count -eq 0) {
        $null = $choices.Add([PSCustomObject]@{ Text = 'The main user (0)'; Ids = @(0); Users = @() })
    }

    $script:backupUserChoices = $choices.ToArray()
    $ui.BackupUsers.Items.Clear()
    foreach ($choice in $script:backupUserChoices) { $null = $ui.BackupUsers.Items.Add($choice.Text) }
    $ui.BackupUsers.SelectedIndex = 0

    $shut = @($users | Where-Object { -not $_.Readable })
    if ($shut.Count -eq 0) {
        $ui.BackupUsersNote.Text = "$($users.Count) user(s) on this phone"
    } else {
        $ui.BackupUsersNote.Text = "$($users.Count) user(s); adb cannot read " +
            (@($shut | ForEach-Object { "$($_.Id)" }) -join ', ')
    }
}

function Get-BackupPageUsers {
    # the users the box is on, as the rows the backup writes into its manifest
    $index = $ui.BackupUsers.SelectedIndex
    if ($index -lt 0 -or $index -ge @($script:backupUserChoices).Count) { return @(0) }
    $choice = $script:backupUserChoices[$index]
    if (@($choice.Users).Count -gt 0) { return @($choice.Users) }
    return @($choice.Ids)
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
        $manifest = Invoke-PhoneBackup -Serial $serial -Destination $where -Parts $parts -Model $model `
            -Name "$($ui.BackupName.Text)".Trim() -Pack ([bool]$ui.BackupPack.IsChecked) -Users (Get-BackupPageUsers)
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

function Resume-BackupPagePicked {
    # carries a stopped backup on, or brings a finished one up to date; both
    # are the same work - compare with the phone and fetch the difference
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    if ($row.Kind -ne 'folder') {
        Write-Log 'That backup is one packed file, so it cannot be carried on or brought up to date.' $colorWarn
        Write-Log '  Untick "Pack into one .zip" when taking one, and it can be.' $colorInfo
        return
    }
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Set-BackupPageBusy -Running $true
    try {
        $manifest = Resume-PhoneBackup -Serial $serial -Folder $row.Path -Pack ([bool]$ui.BackupPack.IsChecked)
    } finally {
        Set-BackupPageBusy -Running $false
    }
    if ($manifest) {
        $null = Show-BackupPageAt -Path $manifest.Path
        if ($manifest.Complete) { Show-Toast -Text 'Backup brought up to date' -Color 'good' }
        else { Show-Toast -Text "Stopped again: $($manifest.Stopped)" -Color 'warn' }
    }
    Update-BackupPageList
}

function Remove-BackupPagePicked {
    # deletes the backup picked in the list, after asking plainly
    $row = Get-BackupPagePick
    if (-not $row) { Write-Log 'Pick the backup to delete in the list first.' $colorWarn; return }
    $sure = Show-Confirm -Title 'Delete a backup' -Text (
        "Delete $($row.Name) from this PC?`n`n$($row.Phone), taken $($row.When), $($row.Size)`n`n" +
        'There is no undoing it. Nothing on the phone is touched.')
    if (-not $sure) { return }

    if (Remove-BackupAt -Path $row.Path) {
        # the one that was open has just gone
        if ($script:backupPath -eq $row.Path) {
            $script:backupSource = $null
            $script:backupPath = ''
            $script:backupManifest = $null
            $script:backupAppsStale = $true
            $script:backupInsideStale = $true
            $ui.BackupInfo.Text = 'No backup opened yet.'
            $ui.BackupInside.ItemsSource = $null
            $ui.BackupAppList.ItemsSource = $null
        }
        Show-Toast -Text 'Backup deleted' -Color 'good'
        Update-BackupPageList
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

    # where a card's files would go: the card in this phone, whatever it is called
    $cards = @(Get-BackupCardPaths -Serial $serial)
    $plan = Get-BackupFilePlan -Source $script:backupSource -CardRoot $(if ($cards.Count -gt 0) { $cards[0] } else { '' }) `
        -UserIds @(@(Get-BackupUsers -Serial $serial -Quick) | ForEach-Object { $_.Id })
    if ($plan.CardSkipped -gt 0) {
        Write-Log ("  $($plan.CardSkipped) file(s) in this backup came off a memory card, and there is none in " +
            'this phone: they are left out.') $colorWarn
    }
    if ($plan.UserSkipped -gt 0) {
        Write-Log ("  $($plan.UserSkipped) file(s) belong to a user this phone does not have any more: " +
            'they are left out.') $colorWarn
    }
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

    $picked = @($ui.BackupAppList.SelectedItems)
    if ($picked.Count -eq 0) {
        Write-Log 'Pick the apps to install first - the ones this phone does not have are picked for you.' $colorWarn
        return
    }
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
# the rest of what a backup can have done to it is on the list's right-click
# menu, where there is room for it to be said in words
$ui.BackupMenuOpen.Add_Click({ Open-BackupPagePicked })
$ui.BackupMenuShow.Add_Click({ Show-BackupPagePicked })
$ui.BackupMenuResume.Add_Click({ Resume-BackupPagePicked })
$ui.BackupMenuDelete.Add_Click({ Remove-BackupPagePicked })
$ui.BackupSaveCopy.Add_Click({ Save-BackupPageCopy })
$ui.BackupAppsMissing.Add_Click({ Select-BackupPageMissing })
$ui.BackupAppFind.Add_TextChanged({ Set-BackupPageAppFilter })
$ui.BackupAppList.Add_SelectionChanged({ Update-BackupPageAppsCount })
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
        'BackupRestoreContacts', 'BackupSaveCopy', 'BackupListRefresh', 'BackupListOpen',
        'BackupMenuOpen', 'BackupMenuShow', 'BackupMenuResume', 'BackupMenuDelete', 'BackupUsers')) {
        $ui[$name].IsEnabled = $false
    }
}

