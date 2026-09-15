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
