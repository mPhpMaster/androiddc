# needs: phone (reads only)
# The Apps page: names read from the phone once and kept, read again when the
# installed apps change, the filter by name or package, user / system and
# enabled / disabled by whole package name, the export, the refusal reasons of
# an install, and the page fitting the smallest window. Nothing is launched,
# stopped, installed or uninstalled.

function Get-ListAppsReads { @($script:logLines | Where-Object { $_.Text -like 'scrcpy --list-apps*' }).Count }
function Get-ListedCount { @($script:logLines | Where-Object { $_.Text -like 'Listed * packages on *' }).Count }
function Get-VisiblePackages { @(Get-AppsVisibleRows | ForEach-Object { $_.Package }) }

Say '== the page =='
$null = Wait-Idle -Seconds 60
Show-Page -Page 'apps'
$null = Wait-Idle -Seconds 60
$columns = @($ui.AppsList.View.Columns | ForEach-Object { "$($_.Header)" })
Say ("columns: {0}   {1}" -f ($columns -join ', '), (Mark ($columns[0] -eq 'NAME' -and $columns[1] -eq 'PACKAGE')))
Say ("right-click menu has the button actions ({0} entries)   {1}" -f $ui.AppsList.ContextMenu.Items.Count,
    (Mark ($ui.AppsList.ContextMenu.Items.Count -eq 8)))
Say ("Uninstall is a danger button   {0}" -f (Mark ([object]::ReferenceEquals($ui.AppsUninstall.Style, (Get-Resource 'DangerButton')))))
Say ("Launch is the primary button   {0}" -f (Mark ([object]::ReferenceEquals($ui.AppsLaunch.Style, (Get-Resource 'Primary')))))
Say ("guarded calls: Get-ScrcpyArguments not needed, Update-Capture loaded = {0}   OK" -f [bool](Get-Command Update-Capture -ErrorAction SilentlyContinue))

Say ''
Say '== install refusals, in words =='
$restricted = @(Get-InstallRefusalReason -Text 'Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]')
Say ("USER_RESTRICTED names Install via USB and MIUI   {0}" -f (Mark ($restricted.Count -eq 2 -and ($restricted -join ' ') -match 'Install via USB' -and ($restricted -join ' ') -match 'MIUI')))
Say ("MISSING_SPLIT asks for the whole set   {0}" -f (Mark ((@(Get-InstallRefusalReason -Text 'INSTALL_FAILED_MISSING_SPLIT') -join '') -match 'every apk')))
Say ("NO_MATCHING_ABIS names the CPU   {0}" -f (Mark ((@(Get-InstallRefusalReason -Text 'INSTALL_FAILED_NO_MATCHING_ABIS') -join '') -match 'CPU')))
Say ("an unknown code adds nothing   {0}" -f (Mark (@(Get-InstallRefusalReason -Text 'Failure [SOMETHING_ELSE]').Count -eq 0)))

$serial = Get-SelectedSerial
$ready = Test-AppsDeviceReady
if (-not $ready) {
    Say 'SKIPPED the phone checks - no ready device'
} else {
    function Hide-Serial { param([string]$Text) return $Text.Replace($serial, '<serial>') }

    Say ''
    Say '== opening the page read the list and the names once =='
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60 -and $script:appRows.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
    Say ("'{0}'" -f (Hide-Serial $ui.AppsCount.Text))
    Say ("rows listed: {0}   {1}" -f $script:appRows.Count, (Mark ($script:appRows.Count -gt 0)))
    Say ("scrcpy --list-apps read once ({0})   {1}" -f (Get-ListAppsReads), (Mark ((Get-ListAppsReads) -eq 1)))
    Say ("count line reads 'N packages on <serial>, M of them apps with a name'   {0}" -f
        (Mark ((Hide-Serial $ui.AppsCount.Text) -match '^\d+ packages on <serial>, \d+ of them apps with a name$')))

    Say ''
    Say '== kept, and read again only when the apps change =='
    $reads = Get-ListAppsReads
    Update-AppList
    Say ("a second refresh does not ask again   {0}" -f (Mark (((Get-ListAppsReads) - $reads) -eq 0)))
    $script:appLabelsSeen[$serial] = 'as if an app had been installed since'
    $reads = Get-ListAppsReads
    Update-AppList
    Say ("after a change it asks once   {0}" -f (Mark (((Get-ListAppsReads) - $reads) -eq 1)))

    $named = @($script:appRows | Where-Object { $_.Name })
    if ($named.Count -eq 0) {
        Say 'SKIPPED the name checks - no app on this phone has a name (scrcpy --list-apps gave none)'
    } else {
        Say ("{0} of {1} rows have a name   OK" -f $named.Count, $script:appRows.Count)
        $wide = @($named | Where-Object { $_.Name -match '[^\x00-\x7F]' })
        if ($wide.Count -eq 0) {
            Say 'SKIPPED the non-ASCII name check - no app name on this phone has one'
        } else {
            $text = $wide[0].Name
            $garbled = @($text.ToCharArray() | Where-Object { [int]$_ -eq 0xFFFD -or ([int]$_ -ge 0x2500 -and [int]$_ -le 0x257F) })
            Say ("a non-ASCII name arrives whole ({0})   {1}" -f $wide[0].Package, (Mark ($garbled.Count -eq 0)))
            $letters = -join @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 } | Select-Object -First 3)
            $ui.AppsFilter.Text = $letters
            Say ("  the filter finds it by those letters   {0}" -f (Mark ((Get-VisiblePackages) -contains $wide[0].Package)))
            $ui.AppsFilter.Text = ''
        }

        Say ''
        Say '== the filter =='
        $probe = $null
        $word = ''
        foreach ($row in $named) {
            $first = $row.Name -split '[^A-Za-z]+' | Where-Object { $_.Length -ge 3 } | Select-Object -First 1
            if ($first -and $row.Package -notlike "*$first*") { $probe = $row; $word = $first; break }
        }
        if ($probe) {
            $ui.AppsFilter.Text = $word
            Say ("'{0}' finds {1} by its name   {2}" -f $word, $probe.Package, (Mark ((Get-VisiblePackages) -contains $probe.Package)))
            $prefix = (($probe.Package -split '[.]') | Select-Object -First 2) -join '.'
            $ui.AppsFilter.Text = $prefix
            $all = @(Get-AppsVisibleRows)
            Say ("'{0}' still finds it by its package, and every row matches   {1}" -f $prefix,
                (Mark ((Get-VisiblePackages) -contains $probe.Package -and @($all | Where-Object { -not ((Test-TextContains $_.Package $prefix) -or (Test-TextContains $_.Name $prefix)) }).Count -eq 0)))
            Say ("  the count line follows the filter   {0}" -f (Mark ((Hide-Serial $ui.AppsCount.Text) -like "$($all.Count) packages on <serial>,*")))
        } else {
            Say 'SKIPPED the name-only filter check - every name is inside its package'
        }
        $ui.AppsFilter.Text = '[*'
        Say ("'[*' is literal text, not a pattern: {0} rows   {1}" -f @(Get-AppsVisibleRows).Count, (Mark (@(Get-AppsVisibleRows).Count -eq 0)))
        $ui.AppsFilter.Text = ''
        Say ("an empty filter shows every row again   {0}" -f (Mark (@(Get-AppsVisibleRows).Count -eq $script:appRows.Count)))

        # Enter in the filter reads the list again
        $listed = Get-ListedCount
        $source = [System.Windows.PresentationSource]::FromVisual($ui.AppsFilter)
        if ($source) {
            $press = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [System.Windows.Input.Key]::Return)
            $press.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
            $ui.AppsFilter.RaiseEvent($press)
            $null = Wait-Idle -Seconds 60
            Say ("Enter in the filter reads the list again   {0}" -f (Mark (((Get-ListedCount) - $listed) -eq 1)))
        } else {
            Say 'SKIPPED the Enter check - the filter box has no presentation source'
        }

        Say ''
        Say '== export =='
        $csv = @(Get-AppListCsv)
        Say ("header   {0}" -f (Mark ($csv[0] -eq 'package,version,type,state,name')))
        $row = $csv | Where-Object { $_ -like ($named[0].Package + ',*') } | Select-Object -First 1
        $quoted = '"' + $named[0].Name.Replace('"', '""') + '"'
        Say ("a row ends with its quoted name   {0}" -f (Mark ($row -and $row.EndsWith(',' + $quoted))))
        Say ("one row per listed package   {0}" -f (Mark (($csv.Count - 1) -eq @(Get-AppsVisibleRows).Count)))

        Say ''
        Say '== system apps too =='
        $userNamed = @($script:appRows | Where-Object { $_.Name }).Count
        $reads = Get-ListAppsReads
        $ui.AppsSystem.IsChecked = $true
        Update-AppList
        $allNamed = @($script:appRows | Where-Object { $_.Name }).Count
        Say ("{0} named with system apps, {1} without, no new read   {2}" -f $allNamed, $userNamed,
            (Mark ($allNamed -ge $userNamed -and ((Get-ListAppsReads) - $reads) -eq 0)))
    }

    Say ''
    Say '== user / system and enabled / disabled, by whole name =='
    $ui.AppsSystem.IsChecked = $true
    $ui.AppsFilter.Text = ''
    Update-AppList
    $third = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -3')).Text
    $off = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -d')).Text
    $userSet = @([regex]::Matches($third, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $offSet = @([regex]::Matches($off, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $wrong = 0
    $oldWrong = 0
    foreach ($item in $script:appRows) {
        $package = $item.Package
        $wantType = if ($userSet -contains $package) { 'user' } else { 'system' }
        $wantState = if ($offSet -contains $package) { 'disabled' } else { 'enabled' }
        if ($item.Type -ne $wantType -or $item.State -ne $wantState) { $wrong++ }
        # what the prefix search used to answer, so the check is seen able to fail
        $oldType = if ($third -match [regex]::Escape("package:$package")) { 'user' } else { 'system' }
        $oldState = if ($off -match [regex]::Escape("package:$package")) { 'disabled' } else { 'enabled' }
        if ($oldType -ne $wantType -or $oldState -ne $wantState) { $oldWrong++ }
    }
    Say ("{0} packages ({1} user, {2} disabled), {3} labelled wrong   {4}" -f $script:appRows.Count, $userSet.Count, $offSet.Count,
        $wrong, (Mark ($script:appRows.Count -gt 0 -and $wrong -eq 0)))
    Say ("  (the prefix search would have labelled {0} of them wrong on this phone)" -f $oldWrong)
    $ui.AppsSystem.IsChecked = $false
    Update-AppList

    $ui.AppsList.UnselectAll()
    Say ("nothing selected: no packages to act on   {0}" -f (Mark (@(Get-SelectedPackages).Count -eq 0)))
}

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "apps-$size"))
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'apps').Root)
    Say ("  {0}: nothing sticks out on the right {1}   {2}" -f $size, ($outside -join '; '), (Mark ($outside.Count -eq 0)))
    $bottom = $ui.AppsUninstall.TransformToAncestor($ui.PageHost).Transform((New-Object System.Windows.Point(0, 0))).Y + $ui.AppsUninstall.ActualHeight
    Say ("  {0}: the buttons are inside the page ({1:N0} of {2:N0}), the list {3:N0} px tall   {4}" -f $size, $bottom,
        $ui.PageHost.ActualHeight, $ui.AppsList.ActualHeight, (Mark ($bottom -le $ui.PageHost.ActualHeight + 1 -and $ui.AppsList.ActualHeight -ge 120)))
}
