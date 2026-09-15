# pages\Users.ps1 - the users on the selected phone: switch, add, rename,
# remove, the multi-user switch, and the phone's own settings screens (which
# the Radios page opens through Open-DeviceSettingsScreen too).

$script:userRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:usersSerial = $null

$usersPage = Register-Page -Key 'users' -Title 'Users' -Glyph 'E716' -Section 'System' -Xaml 'Users.xaml' `
    -OnShow { if ($script:userRows.Count -eq 0 -and (Test-UsersDeviceReady)) { Update-UserList } } `
    -OnDeviceChanged {
        $serial = Get-SelectedSerial
        if ($serial -and $serial -eq $script:usersSerial) { return }
        Clear-UserList
        if ((Test-PageShown -Key 'users') -and (Test-UsersDeviceReady)) { Update-UserList }
    } `
    -Refresh { Update-UserList }

$ui.UsersList.ItemsSource = $script:userRows

function Test-UsersDeviceReady {
    $first = Get-SelectedDevice
    return ($null -ne $first -and $first.State -eq 'device')
}

function Clear-UserList {
    $script:userRows.Clear()
    $script:usersSerial = $null
    $ui.UsersState.Text = 'users: unknown'
}

function ConvertFrom-UserListText {
    # the rows of "pm list users"; also what the test checks without a phone
    param([string]$Text)

    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        # UserInfo{0:Owner:4c13} running
        if ($line -match 'UserInfo\{(\d+):([^:]*):([0-9a-fA-F]+)\}\s*(.*)$') {
            $flags = [Convert]::ToInt32($Matches[3], 16)
            $kind = @()
            if ($flags -band 0x00000001) { $kind += 'primary' }
            if ($flags -band 0x00000002) { $kind += 'admin' }
            if ($flags -band 0x00000004) { $kind += 'guest' }
            if ($flags -band 0x00000008) { $kind += 'restricted' }
            if ($flags -band 0x00000020) { $kind += 'managed' }
            if ($flags -band 0x00000800) { $kind += 'system' }
            $rows += [PSCustomObject]@{
                Id    = $Matches[1]
                Name  = $Matches[2]
                State = $Matches[4].Trim()
                Kind  = ($kind -join ', ')
                Flags = '0x' + $Matches[3]
            }
        }
    }
    return $rows
}

function Update-UserList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'list', 'users')).Text
    $current = (Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'get-current-user')).Text.Trim()
    $max = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'get-max-users')).Text
    $maxCount = if ($max -match '(\d+)') { $Matches[1] } else { '?' }
    $switcher = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'get', 'global', 'user_switcher_enabled')).Text.Trim()
    # another phone may have been picked while those were read
    if ((Get-SelectedSerial) -ne $serial) { return }

    $rows = @(ConvertFrom-UserListText -Text $text)
    $green = Get-Resource 'Success'
    $ink = Get-Resource 'Ink'
    $selected = @($ui.UsersList.SelectedItems | ForEach-Object { $_.Id })

    $script:userRows.Clear()
    foreach ($row in $rows) {
        $isCurrent = ($row.Id -eq $current)
        $item = [PSCustomObject]@{
            Id = $row.Id; Name = $row.Name; State = $row.State; Kind = $row.Kind; Flags = $row.Flags
            IdText = $(if ($isCurrent) { "$($row.Id)  <- current" } else { $row.Id })
            IsCurrent = $isCurrent
            Brush = $(if ($isCurrent) { $green } else { $ink })
        }
        $script:userRows.Add($item)
        if ($selected -contains $row.Id) { $ui.UsersList.SelectedItem = $item }
    }
    $script:usersSerial = $serial

    $switchLabel = switch ($switcher) { '1' { 'on' } '0' { 'off' } default { 'not set' } }
    $ui.UsersState.Text = "$($rows.Count) user(s) of at most $maxCount   |   current user: $current   |   user switcher: $switchLabel"
    if ($maxCount -eq '1') {
        $ui.UsersState.Text = "This phone allows a single user only (pm get-max-users = 1)."
    }
}

function Get-SelectedUser {
    $row = $ui.UsersList.SelectedItem
    if ($null -eq $row) {
        Write-Log 'Pick a user in the list first.' $colorWarn
        return $null
    }
    return $row
}

function Switch-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    Write-Log "Switching $serial to user $($user.Id) ($($user.Name)) ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'switch-user', $user.Id)
    if ($result.Text -match 'Error|Exception|denied') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }
    Wait-Pumped -Milliseconds 2500
    Write-Log "The phone is now on user $($user.Id)." $colorGood
    Update-UserList
}

function Add-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $answer = Show-InputDialog -Title 'Add user' -Fields @('Name for the new user:') -Values @('user') -OkText 'Add'
    if ($null -eq $answer) { return }
    $name = "$(@($answer)[0])".Trim()
    if (-not $name) { return }

    # a typed name goes through base64 and sh quoting, whatever it holds
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('pm', 'create-user', $name)
    if ($result.Text -match 'Success.*id (\d+)') {
        Write-Log "Created user $($Matches[1]) '$name'." $colorGood
    } else {
        Write-Log ("create-user said: " + $result.Text.Trim()) $colorBad
    }
    Update-UserList
}

function Rename-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    $answer = Show-InputDialog -Title 'Rename user' -Fields @("New name for user $($user.Id):") -Values @($user.Name) `
        -OkText 'Rename' -Hint ('Android usually refuses a rename from adb: it needs MANAGE_USERS, a system permission. ' +
            'If it does, rename the user on the phone - Settings > Users, or User settings here.')
    if ($null -eq $answer) { return }
    $name = "$(@($answer)[0])"
    if (-not $name.Trim() -or $name -eq $user.Name) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('pm', 'rename-user', $user.Id, $name.Trim())
    if ($result.Text -match 'MANAGE_USERS') {
        # adb shell holds CREATE_USERS but not MANAGE_USERS, so Android refuses
        Write-Log 'Android does not let adb rename a user (MANAGE_USERS is a system permission).' $colorWarn
        Write-Log 'Rename it on the phone: Settings > Users, or use "User settings" here.' $colorInfo
    } elseif ($result.Text -match 'Error|Exception|denied|Unknown') {
        Write-Log $result.Text.Trim() $colorBad
    } else {
        Write-Log "User $($user.Id) is now '$($name.Trim())'." $colorGood
    }
    Update-UserList
}

function Remove-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    if ($user.Id -eq '0') {
        Write-Log 'User 0 is the owner and cannot be removed.' $colorWarn
        return
    }

    $answer = Show-Confirm -Title 'Remove user' -Yes 'Remove user' -No 'Cancel' -Danger -Text (
        "Delete user $($user.Id) '$($user.Name)' and everything inside it?" + "`r`n`r`n" +
        'Apps, accounts and files of that user are erased on the phone. This cannot be undone.')
    if (-not $answer) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'remove-user', $user.Id)
    if ($result.Text -match 'Success') {
        Write-Log "Removed user $($user.Id)." $colorGood
    } else {
        Write-Log ("remove-user said: " + $result.Text.Trim()) $colorBad
    }
    Update-UserList
}

function Set-UserSwitcher {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'put', 'global', 'user_switcher_enabled', $(if ($On) { '1' } else { '0' }))
    Write-Log ("User switcher turned " + $(if ($On) { 'on' } else { 'off' }) + ". Existing users are untouched.") $colorGood
    Update-UserList
}

function Open-DeviceSettingsScreen {
    param([string]$Action)

    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-a', $Action)
    Write-Log "Opened $Action on the phone." $colorInfo
}

# ------------------------------------------------------------------ events ----

$ui.UsersRefresh.Add_Click({ Update-UserList })
$ui.UsersSwitch.Add_Click({ Switch-DeviceUser })
$ui.UsersAdd.Add_Click({ Add-DeviceUser })
$ui.UsersRename.Add_Click({ Rename-DeviceUser })
$ui.UsersRemove.Add_Click({ Remove-DeviceUser })
$ui.UsersSwitcherOn.Add_Click({ Set-UserSwitcher -On $true })
$ui.UsersSwitcherOff.Add_Click({ Set-UserSwitcher -On $false })
$ui.UsersSettings.Add_Click({ Open-DeviceSettingsScreen -Action 'android.settings.USER_SETTINGS' })
$ui.UsersList.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    # a double-click on a row, not on a header or the empty space under the rows
    $source = $eventArgs.OriginalSource
    try {
        while ($source -and $source -isnot [System.Windows.Controls.ListViewItem] -and $source -ne $sender) {
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        }
    } catch { return }
    if ($source -is [System.Windows.Controls.ListViewItem]) { Switch-DeviceUser }
})
Set-ListColumnsSortable -List $ui.UsersList
Add-ListContextMenu -List $ui.UsersList -Buttons @($ui.UsersSwitch, $null, $ui.UsersAdd, $ui.UsersRename,
    $ui.UsersRemove, $null, $ui.UsersSettings)
