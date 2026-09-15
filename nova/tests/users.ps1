# needs: phone (reads only)
# The Users page: the users line, the list against pm list users, the current
# user marked, the flags read into words, and the page fitting the smallest
# window. Nobody is switched to, added, renamed or removed.

Say '== reading the flags =='
$sample = @(ConvertFrom-UserListText -Text ("Users:`n`tUserInfo{0:Owner:c13} running`n`tUserInfo{10:Guest user:14} "))
Say ("two users read from the sample   {0}" -f (Mark ($sample.Count -eq 2)))
Say ("0x c13 is primary, admin, system   {0}" -f (Mark ($sample[0].Kind -eq 'primary, admin, system' -and $sample[0].State -eq 'running' -and $sample[0].Flags -eq '0xc13')))

Say ''
Say '== the page =='
$null = Wait-Idle -Seconds 60
Show-Page -Page 'users'
$null = Wait-Idle -Seconds 60
Say ("right-click menu has the button actions ({0} entries)   {1}" -f $ui.UsersList.ContextMenu.Items.Count,
    (Mark ($ui.UsersList.ContextMenu.Items.Count -eq 7)))
Say ("Remove is a danger button   {0}" -f (Mark ([object]::ReferenceEquals($ui.UsersRemove.Style, (Get-Resource 'DangerButton')))))
Say ("Open-DeviceSettingsScreen is there for the Radios page   {0}" -f (Mark ([bool](Get-Command Open-DeviceSettingsScreen -ErrorAction SilentlyContinue))))
Say ("Rename explains the limit   {0}" -f (Mark ("$($ui.UsersRename.ToolTip)" -match 'MANAGE_USERS')))

if (-not (Test-UsersDeviceReady)) {
    Say 'SKIPPED the phone checks - no ready device'
} else {
    $serial = Get-SelectedSerial
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 30 -and $script:userRows.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
    Say ''
    Say '== opening the page read the users =='
    Say ("'{0}'" -f $ui.UsersState.Text)
    $pattern = '^\d+ user\(s\) of at most (\d+|\?)   \|   current user: \d+   \|   user switcher: (on|off|not set)$'
    Say ("the users line   {0}" -f (Mark ($ui.UsersState.Text -match $pattern -or $ui.UsersState.Text -like 'This phone allows a single user only*')))

    $listed = @(ConvertFrom-UserListText -Text (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'list', 'users')).Text)
    $current = (Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'get-current-user')).Text.Trim()
    Say ("{0} user(s) listed, as pm list users says   {1}" -f $script:userRows.Count, (Mark ($script:userRows.Count -gt 0 -and $script:userRows.Count -eq $listed.Count)))
    $marked = @($script:userRows | Where-Object { $_.IdText -like '*<- current' })
    Say ("exactly the current user ({0}) is marked, in green   {1}" -f $current,
        (Mark ($marked.Count -eq 1 -and $marked[0].Id -eq $current -and [object]::ReferenceEquals($marked[0].Brush, (Get-Resource 'Success')))))
    if ($ui.UsersState.Text -match $pattern) {
        Say ("the line counts the rows   {0}" -f (Mark ($ui.UsersState.Text -like "$($script:userRows.Count) user(s) *")))
    }
    foreach ($row in $script:userRows) { Say ("  user {0}: state '{1}', kind '{2}', flags {3}" -f $row.Id, $row.State, $row.Kind, $row.Flags) }

    $ui.UsersList.UnselectAll()
    Say ("nothing selected: no user to act on   {0}" -f (Mark ($null -eq (Get-SelectedUser))))

    Say ''
    Say '== another phone clears the list when the page is not on screen =='
    $script:usersSerial = 'another phone'
    $script:currentPage = $null
    & (Get-Page -Key 'users').OnDeviceChanged
    Say ("cleared   {0}" -f (Mark ($script:userRows.Count -eq 0 -and $ui.UsersState.Text -eq 'users: unknown')))
    Show-Page -Page 'users'
    $null = Wait-Idle -Seconds 30
    Say ("and read again when it is opened   {0}" -f (Mark ($script:userRows.Count -gt 0)))
}

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "users-$size"))
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'users').Root)
    Say ("  {0}: nothing sticks out on the right {1}   {2}" -f $size, ($outside -join '; '), (Mark ($outside.Count -eq 0)))
    $bottom = $ui.UsersRemove.TransformToAncestor($ui.PageHost).Transform((New-Object System.Windows.Point(0, 0))).Y + $ui.UsersRemove.ActualHeight
    Say ("  {0}: the buttons are inside the page ({1:N0} of {2:N0}), the list {3:N0} px tall   {4}" -f $size, $bottom,
        $ui.PageHost.ActualHeight, $ui.UsersList.ActualHeight, (Mark ($bottom -le $ui.PageHost.ActualHeight + 1 -and $ui.UsersList.ActualHeight -ge 120)))
}
