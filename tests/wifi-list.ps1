# The Wi-Fi list, strongest network first by the number, not by the text:
# "-60 dBm" sorted as text comes before "-45 dBm". Without a phone the rule is
# checked on a made-up list; with one, the list the phone gives is checked
# too. Reads only - the scan results the phone already has and its saved
# networks; nothing is scanned, joined or forgotten.

Say '== the order rule =='
$signals = @('-60 dBm', 'saved', '-45 dBm', '-100 dBm', '-7 dBm')
$ordered = @($signals | Sort-Object -Property @{ Expression = { Get-SignalStrength $_ } } -Descending)
Say ("  {0}   {1}" -f ($ordered -join ', '), (Mark (($ordered -join ',') -eq '-7 dBm,-45 dBm,-60 dBm,-100 dBm,saved')))
# the old rule, so the check is seen able to fail
$asText = @($signals | Sort-Object -Descending)
Say ("  (as text, as before: {0})" -f ($asText -join ', '))

Say ''
Say '== the list a phone gives =='
# no "return" here: it would skip the end marker the harness waits for
if (-not $TestSerial) {
    Say 'SKIPPED - no phone given'
} else {
    Select-TestPhone
    $tabs.SelectedTab = $tabRadios
    $tabsRadios.SelectedTab = $tabWifi
    Wait-Pumped -Milliseconds 400
    Update-WifiList

    # the scan's own value: the row of the network the phone is on shows the
    # live link's figure instead, which can differ from the scan it was sorted by
    $values = @($lstWifi.Items | ForEach-Object { Get-SignalStrength $_.Tag.Signal })
    $measured = @($values | Where-Object { $_ -gt -1000 })
    Say ("{0} network(s), {1} with a signal" -f $values.Count, $measured.Count)
    if ($measured.Count -lt 2) {
        Say 'SKIPPED - fewer than two networks with a signal in what the phone already has'
    } else {
        $sorted = @($values | Sort-Object -Descending)
        Say ("strongest first, saved-only last   {0}" -f (Mark (($values -join ',') -eq ($sorted -join ','))))
    }
}

Say ''
Say '== the saved-passwords window (built, not shown) =='
# New-WifiPasswordWindow builds the window from a result; the passwords are
# hidden behind dots until Show is ticked, and the real one rides on each row's
# Tag so Copy can reach it without it ever being on screen. Built here with a
# made-up Ok result, so no phone and no real passwords are involved.
$dot = [string][char]0x2022
$okRes = [PSCustomObject]@{ Status = 'Ok'; Count = 2; Error = ''; Rows = @(
    [PSCustomObject]@{ Ssid = 'Home 2.4'; Password = 'secret12'; IsOpen = $false },
    [PSCustomObject]@{ Ssid = 'Cafe Open'; Password = ''; IsOpen = $true }) }
$win = New-WifiPasswordWindow -Result $okRes -Serial 'TEST-SERIAL'
$list = $win.Controls.Find('WifiPwList', $true)[0]
$show = $win.Controls.Find('WifiPwShow', $true)[0]
Say ("  two rows, the window built   {0}" -f (Mark ($null -ne $list -and $list.Items.Count -eq 2)))
$pwCell = { ($list.Items | ForEach-Object { "$($_.SubItems[1].Text)" }) -join '|' }
$hiddenOpen = (& $pwCell)
Say ("  at open the password is dots, the open network says so, and nothing shows the real key   {0}" -f (Mark (
    $hiddenOpen -match ([regex]::Escape($dot * 10)) -and $hiddenOpen -match '\(open network\)' -and $hiddenOpen -notmatch 'secret12')))
Say ("  the real password is on the row's Tag, not on screen   {0}" -f (Mark ("$($list.Items[0].Tag)" -eq 'secret12')))
$show.Checked = $true
Say ("  ticking Show reveals the saved key (the open one stays its note)   {0}" -f (Mark (
    "$($list.Items[0].SubItems[1].Text)" -eq 'secret12' -and "$($list.Items[1].SubItems[1].Text)" -eq '(open network)')))
$show.Checked = $false
Say ("  unticking hides it again   {0}" -f (Mark ("$($list.Items[0].SubItems[1].Text)" -eq ($dot * 10))))
$win.Dispose()

Say ''
Say '== the hint line, by what the phone allows =='
Say ("  Android 13+ is told it needs root, not called an error   {0}" -f (Mark (
    (Get-WifiPasswordHint -Status 'Unsupported') -match 'Android 13' -and (Get-WifiPasswordHint -Status 'Unsupported') -match 'root')))
Say ("  each status has its own words   {0}" -f (Mark (
    (Get-WifiPasswordHint -Status 'Ok') -and (Get-WifiPasswordHint -Status 'Empty') -and
    (Get-WifiPasswordHint -Status 'NoDex') -and (Get-WifiPasswordHint -Status 'Masked'))))

Say ''
Say '== reading the passwords off the phone (reads only) =='
if (-not $TestSerial) {
    Say 'SKIPPED - no phone given'
} else {
    $res = Get-SavedWifiPasswords -Serial $TestSerial
    # counts and the status only - never a password
    $withPw = @($res.Rows | Where-Object { -not $_.IsOpen }).Count
    Say ("  status '{0}', {1} network(s), {2} with a password   {3}" -f $res.Status, $res.Count, $withPw, (Mark (
        $res.Status -in @('Ok', 'Unsupported', 'Masked', 'Empty'))))
    if ($res.Status -eq 'Ok') {
        Say ("  every row has a name, and the open ones alone have no password   {0}" -f (Mark (
            @($res.Rows | Where-Object { -not $_.Ssid }).Count -eq 0 -and
            @($res.Rows | Where-Object { -not $_.IsOpen -and -not $_.Password }).Count -eq 0)))
    }
}
