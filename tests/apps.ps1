# needs: phone
# Apps by name: names read from the phone once and kept, read again when the
# installed apps change, the filter by name, the export, and Start app on the
# Mirroring page. Examples are taken from whatever apps the phone has.

function Get-ListAppsReads { ([regex]::Matches($txtLog.Text, 'scrcpy --list-apps')).Count }
function Find-App { param([string]$Package) @($lstApps.Items | Where-Object { $_.Text -eq $Package })[0] }

Select-TestPhone
$tabs.SelectedTab = $tabApps
Wait-Pumped -Milliseconds 400
$chkAppsSystem.Checked = $false
$txtAppFilter.Text = ''

Say '== first refresh reads the names =='
$reads = Get-ListAppsReads
$btnAppsRefresh.PerformClick()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt 40 -and $lstApps.Items.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
Say ("'{0}'" -f $lblAppsCount.Text)
Say ("scrcpy --list-apps read once   {0}" -f (Mark (((Get-ListAppsReads) - $reads) -eq 1)))
Say ("Name column shown first   {0}" -f (Mark ($lstApps.Columns[4].DisplayIndex -eq 0)))

$named = @($lstApps.Items | Where-Object { $_.SubItems[4].Text })
if ($named.Count -eq 0) {
    Say 'SKIPPED the name checks - no app on this phone has a name (scrcpy --list-apps gave none)'
} else {
    # a name whose first word is not in its package, so a hit proves the name matched
    $probe = $null
    $word = ''
    foreach ($item in $named) {
        $first = ($item.SubItems[4].Text -split '[^A-Za-z]+' | Where-Object { $_.Length -ge 3 })[0]
        if ($first -and $item.Text -notlike "*$first*") { $probe = $item; $word = $first; break }
    }
    Say ("Text is still the package and SubItems 1..3 are unchanged   {0}" -f
        (Mark ($named[0].Text -match '^[A-Za-z0-9_.]+$' -and $named[0].SubItems[2].Text -in 'user', 'system')))

    # a name with letters outside ASCII must arrive whole, not as box-drawing characters
    $wide = @($named | Where-Object { $_.SubItems[4].Text -match '[^\x00-\x7F]' })
    if ($wide.Count -eq 0) {
        Say 'SKIPPED the non-ASCII name check - no app name on this phone has one'
    } else {
        $text = $wide[0].SubItems[4].Text
        $garbled = @($text.ToCharArray() | Where-Object { [int]$_ -eq 0xFFFD -or ([int]$_ -ge 0x2500 -and [int]$_ -le 0x257F) })
        Say ("a non-ASCII name arrives whole ({0})   {1}" -f $wide[0].Text, (Mark ($garbled.Count -eq 0)))
        $letters = -join @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 } | Select-Object -First 3)
        $txtAppFilter.Text = $letters
        Update-AppList
        Say ("  the filter finds it by those letters   {0}" -f (Mark (@($lstApps.Items | ForEach-Object { $_.Text }) -contains $wide[0].Text)))
        $txtAppFilter.Text = ''
    }

    Say ''
    Say '== kept, and read again only when the apps change =='
    $reads = Get-ListAppsReads
    Update-AppList
    Say ("a second refresh does not ask again   {0}" -f (Mark (((Get-ListAppsReads) - $reads) -eq 0)))
    $script:appLabelsSeen[$TestSerial] = 'as if an app had been installed since'
    $reads = Get-ListAppsReads
    Update-AppList
    Say ("after a change it asks once   {0}" -f (Mark (((Get-ListAppsReads) - $reads) -eq 1)))

    if ($probe) {
        Say ''
        Say '== the filter =='
        $txtAppFilter.Text = $word
        Update-AppList
        Say ("'{0}' finds {1} by its name   {2}" -f $word, $probe.Text, (Mark (@($lstApps.Items | ForEach-Object { $_.Text }) -contains $probe.Text)))
        $prefix = (($probe.Text -split '[.]') | Select-Object -First 2) -join '.'
        $txtAppFilter.Text = $prefix
        Update-AppList
        Say ("'{0}' still finds it by its package   {1}" -f $prefix, (Mark (@($lstApps.Items | ForEach-Object { $_.Text }) -contains $probe.Text)))
        $txtAppFilter.Text = ''
        Update-AppList
    }

    Say ''
    Say '== system apps too =='
    $userNamed = @($lstApps.Items | Where-Object { $_.SubItems[4].Text }).Count
    $reads = Get-ListAppsReads
    $chkAppsSystem.Checked = $true
    Update-AppList
    $allNamed = @($lstApps.Items | Where-Object { $_.SubItems[4].Text }).Count
    Say ("{0} named with system apps, {1} without, no new read   {2}" -f $allNamed, $userNamed,
        (Mark ($allNamed -ge $userNamed -and ((Get-ListAppsReads) - $reads) -eq 0)))
    $chkAppsSystem.Checked = $false
    Update-AppList

    Say ''
    Say '== export =='
    $csv = @(Get-AppListCsv)
    Say ("header   {0}" -f (Mark ($csv[0] -eq 'package,version,type,state,name')))
    $row = @($csv | Where-Object { $_ -like ($named[0].Text + ',*') })[0]
    $quoted = '"' + $named[0].SubItems[4].Text.Replace('"', '""') + '"'
    Say ("a row ends with its quoted name   {0}" -f (Mark ($row -and $row.EndsWith(',' + $quoted))))
    Say ("one row per package   {0}" -f (Mark (($csv.Count - 1) -eq $lstApps.Items.Count)))
}

Say ''
Say '== user / system and enabled / disabled, by whole name =='
$chkAppsSystem.Checked = $true
$txtAppFilter.Text = ''
Update-AppList
$third = (Invoke-DeviceShell -Serial $TestSerial -CommandArguments @('pm list packages -3')).Text
$off = (Invoke-DeviceShell -Serial $TestSerial -CommandArguments @('pm list packages -d')).Text
$userSet = @([regex]::Matches($third, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
$offSet = @([regex]::Matches($off, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
$wrong = 0
$oldWrong = 0
foreach ($item in $lstApps.Items) {
    $package = $item.Text
    $wantType = if ($userSet -contains $package) { 'user' } else { 'system' }
    $wantState = if ($offSet -contains $package) { 'disabled' } else { 'enabled' }
    if ($item.SubItems[2].Text -ne $wantType -or $item.SubItems[3].Text -ne $wantState) { $wrong++ }
    # what the prefix search used to answer, so the check is seen able to fail
    $oldType = if ($third -match [regex]::Escape("package:$package")) { 'user' } else { 'system' }
    $oldState = if ($off -match [regex]::Escape("package:$package")) { 'disabled' } else { 'enabled' }
    if ($oldType -ne $wantType -or $oldState -ne $wantState) { $oldWrong++ }
}
Say ("{0} packages, {1} labelled wrong   {2}" -f $lstApps.Items.Count, $wrong, (Mark ($lstApps.Items.Count -gt 0 -and $wrong -eq 0)))
Say ("  (the prefix search would have labelled {0} of them wrong on this phone)" -f $oldWrong)
$chkAppsSystem.Checked = $false
Update-AppList

Say ''
Say '== Start app =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabScrcpy
Wait-Pumped -Milliseconds 400
Update-StartAppChoices
$names = Get-AppLabels -Serial $TestSerial
Say ("one choice per name   {0}" -f (Mark ($cmbStartApp.Items.Count -eq $names.Count)))
# a name that has its own brackets must still give the package
$null = $cmbStartApp.Items.Add('Example (beta)  (com.example.beta)')
$cmbStartApp.SelectedIndex = -1
$cmbStartApp.SelectedItem = 'Example (beta)  (com.example.beta)'
Say ("a pick gives its package   {0}" -f (Mark ((Get-StartAppValue) -eq 'com.example.beta')))
$cmbStartApp.Text = '+Example (beta)  (com.example.beta)'
Say ("a + in front is kept   {0}" -f (Mark ((Get-StartAppValue) -eq '+com.example.beta')))
foreach ($typed in @('com.example.app', '+com.example.app', '?Example')) {
    $cmbStartApp.Text = $typed
    Say ("typed '{0}' passes through   {1}" -f $typed, (Mark ((Get-StartAppValue) -eq $typed)))
}
$cmbStartApp.SelectedIndex = -1
$cmbStartApp.SelectedItem = 'Example (beta)  (com.example.beta)'
if ($chkOtg.Checked) {
    Say 'SKIPPED the command check - OTG is ticked in these settings, and OTG sends no --start-app'
} else {
    Say ("the mirror command carries it   {0}" -f (Mark (@(Get-ScrcpyArguments -Serial $TestSerial) -contains '--start-app=com.example.beta')))
}

$script:appLabels.Clear()
$cmbStartApp.Items.Clear()
$cmbStartApp.Text = 'kept while it fills'
$reads = Get-ListAppsReads
$onDropDown = [System.Windows.Forms.ComboBox].GetMethod('OnDropDown', [System.Reflection.BindingFlags]'Instance,NonPublic')
$box = [object[]]::new(1); $box[0] = [System.EventArgs]::Empty
$null = $onDropDown.Invoke($cmbStartApp, $box)
Wait-Pumped -Milliseconds 300
Say ("opening the list with nothing read fills it and keeps the typed text   {0}" -f
    (Mark (((Get-ListAppsReads) - $reads) -eq 1 -and $cmbStartApp.Text -eq 'kept while it fills')))

$cmbStartApp.Text = 'Example (beta)  (com.example.beta)'
Save-Settings
$cmbStartApp.Text = ''
Restore-Settings
Say ("remembered across a restart   {0}" -f (Mark ((Get-StartAppValue) -eq 'com.example.beta')))
$cmbStartApp.Text = ''
