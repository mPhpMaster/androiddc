# The Overview page: it opens and reads the phone (battery, memory, toggle
# states, details - reads only), the toggle marks follow a made-up answer, and
# it fits the window at both sizes. Nothing on the phone is changed.

Show-Page -Page 'overview'
$idle = Wait-Idle -Seconds 40
Say '== opening the page =='
Say ("  idle after reading   {0}" -f (Mark $idle))

Say ''
Say '== the toggle marks, from a made-up answer =='
$states = ConvertFrom-ToggleOutput "rotation=1`nlocation=false`nbluetooth=null`nwifi=0`nstayawake=3`nnot a state line"
Set-ToggleMarks $states
$pairs = $script:toggleButtons
Say ("  auto-rotate 1: On only   {0}" -f (Mark ((Test-ToggleLit $pairs.rotation[0]) -and -not (Test-ToggleLit $pairs.rotation[1]))))
Say ("  location false: Off only   {0}" -f (Mark ((Test-ToggleLit $pairs.location[1]) -and -not (Test-ToggleLit $pairs.location[0]))))
Say ("  bluetooth null: neither   {0}" -f (Mark (-not (Test-ToggleLit $pairs.bluetooth[0]) -and -not (Test-ToggleLit $pairs.bluetooth[1]))))
Say ("  stay awake 3: On   {0}" -f (Mark (Test-ToggleLit $pairs.stayawake[0])))
Say ("  battery saver not in the answer: neither   {0}" -f (Mark (-not (Test-ToggleLit $pairs.saver[0]) -and -not (Test-ToggleLit $pairs.saver[1]))))
Set-ToggleMarks $null
$lit = @($pairs.Values | ForEach-Object { $_ } | Where-Object { Test-ToggleLit $_ }).Count
Say ("  cleared: none lit   {0}" -f (Mark ($lit -eq 0)))
Say ("  ten toggle rows   {0}" -f (Mark ($ui.OverviewToggleHost.Children.Count -eq 10)))

Say ''
Say '== from the phone (reads only) =='
if (-not (Get-SelectedSerial)) {
    Say 'SKIPPED - no phone attached'
} else {
    Update-OverviewMetrics -Force
    Show-ToggleStates -Quiet
    $null = Wait-Idle -Seconds 30
    Say ("  battery shows '{0} {1}'   {2}" -f $ui.OverviewBatteryValue.Text, $ui.OverviewBatteryNote.Text, (Mark ($ui.OverviewBatteryValue.Text -match '^\d+%$')))
    Say ("  memory shows '{0} {1}'   {2}" -f $ui.OverviewMemoryValue.Text, $ui.OverviewMemoryNote.Text, (Mark ($ui.OverviewMemoryValue.Text -match 'GB$')))
    $known = @($pairs.Keys | Where-Object { (Test-ToggleLit $pairs[$_][0]) -or (Test-ToggleLit $pairs[$_][1]) }).Count
    $both = @($pairs.Keys | Where-Object { (Test-ToggleLit $pairs[$_][0]) -and (Test-ToggleLit $pairs[$_][1]) }).Count
    Say ("  {0} of 10 toggles known, none with both sides lit   {1}" -f $known, (Mark ($known -ge 1 -and $both -eq 0)))
    Say ("  the marks are this phone's   {0}" -f (Mark ($script:toggleSerial -eq (Get-SelectedSerial))))

    Invoke-ButtonClick -Button $ui.OverviewLoad
    $null = Wait-Idle -Seconds 60
    $details = $ui.OverviewDetails.Text
    Say ("  Load details fills the box ({0} lines)   {1}" -f @($details -split "`r?`n").Count,
        (Mark ($details -match '(?m)^Model\s*:' -and $details -match '(?m)^Battery\s*:' -and $ui.OverviewDetailsHint.Visibility -eq 'Collapsed')))
    $handled = Invoke-WindowKey -Key ([System.Windows.Input.Key]::F5) -Modifiers ([System.Windows.Input.ModifierKeys]::None)
    $null = Wait-Idle -Seconds 60
    Say ("  F5 on this page reads the details again   {0}" -f (Mark $handled))
}

Say ''
Say '== fitting the window =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Show-Page -Page 'overview'
    $null = Wait-Idle -Seconds 20
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "overview-$size"))
    $outside = @(Get-OutsideElements -Root $overviewPage.Root)
    foreach ($line in $outside) { Say "    $line" }
    Say ("  {0}: nothing sticks out on the right   {1}" -f $size, (Mark ($outside.Count -eq 0)))
}
