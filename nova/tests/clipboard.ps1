# The Clipboard page: it opens and fits, the buttons are there, and one turn
# of the watch moves something each way. The phone is made up - nothing is
# written to a real one - and this PC's own clipboard is put back at the end.

$before = $null
try { $before = Get-Clipboard -Format Text -Raw -ErrorAction Stop } catch { }

Say '== the page =='
Show-Page -Page 'clipboard'
$null = Wait-Idle
$names = @('ClipboardStart', 'ClipboardStop', 'ClipboardSend', 'ClipboardTake', 'ClipboardType',
    'ClipboardState', 'ClipboardList', 'ClipboardCopy', 'ClipboardClear')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  every control is there{0}   {1}" -f $(if ($missing) { ' - missing ' + ($missing -join ', ') } else { '' }),
    (Mark ($missing.Count -eq 0)))
Say ("  shared\Clipboard.ps1 found in the project folder   {0}" -f (Mark (Test-ClipboardShared)))
Say ("  every button says what it does on hover   {0}" -f (Mark (
    @(@('ClipboardStart', 'ClipboardStop', 'ClipboardSend', 'ClipboardTake', 'ClipboardCopy', 'ClipboardClear') |
        Where-Object { -not "$($ui[$_].ToolTip)" }).Count -eq 0)))
Say ("  it starts off, and says so: '{0}'   {1}" -f $ui.ClipboardState.Text, (Mark (
    $ui.ClipboardState.Text -eq 'Not sharing.' -and $ui.ClipboardStart.IsEnabled -and -not $ui.ClipboardStop.IsEnabled)))

Say ''
Say '== one turn of the watch =='
Stop-AllClipboardShares
Clear-ClipboardEvents
$script:answers = @{ 'cmd clipboard get-primary-clip' = '' }
$fakeShell = {
    param($Serial, $CommandArguments)
    $command = (@($CommandArguments) -join ' ')
    $text = ''
    foreach ($key in @($script:answers.Keys | Sort-Object -Property Length -Descending)) {
        if ($command -like $key) { $text = $script:answers[$key]; break }
    }
    return [PSCustomObject]@{ Lines = @("$text" -split "`n"); Text = $text; ExitCode = 0 }
}
function Invoke-WithFakePhone {
    param([scriptblock]$Body)
    & {
        function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
        function Invoke-DeviceCommand { param($Serial, $Arguments) & $fakeShell $Serial $Arguments }
        & $Body
    }
}

$share = Invoke-WithFakePhone { Start-ClipboardShare -Serial 'ABC123' -Model 'Test phone' }
Update-ClipboardPage
Say ("  sharing the {0} way, and the page says so: '{1}'   {2}" -f $share.Route, $ui.ClipboardState.Text, (Mark (
    $share.Route -eq 'cmd' -and $ui.ClipboardState.Text -match 'Test phone \(cmd\)' -and
    -not $ui.ClipboardStart.IsEnabled -and $ui.ClipboardStop.IsEnabled)))

$null = Set-Clipboard -Value 'here before sharing'
$null = Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet }
$null = Set-Clipboard -Value 'copied on this PC'
$second = @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet })
Update-ClipboardPageList
$null = Wait-Idle
Say ("  what this PC copies goes over: {0}   {1}" -f ((@($second | ForEach-Object { $_.Way })) -join ', '), (Mark (
    $second.Count -eq 1 -and $second[0].Way -eq 'PC -> phone')))
$script:answers['cmd clipboard get-primary-clip'] = 'copied on the phone'
$third = @(Invoke-WithFakePhone { Invoke-ClipboardTick -Quiet })
Update-ClipboardPageList
$null = Wait-Idle
Say ("  and what the phone copies comes here   {0}" -f (Mark (
    $third.Count -eq 1 -and $third[0].Way -eq 'phone -> PC' -and (Get-ClipboardHere) -eq 'copied on the phone')))
Say ("  the list shows both, newest first   {0}" -f (Mark (
    @($ui.ClipboardList.ItemsSource).Count -eq 2 -and @($ui.ClipboardList.ItemsSource)[0].Way -eq 'phone -> PC')))

$ui.ClipboardList.SelectedIndex = 1
Copy-ClipboardPageRow
Say ("  a line can be put back on this PC   {0}" -f (Mark ((Get-ClipboardHere) -eq 'copied on this PC')))
Say ("  and what was copied is not written to the log   {0}" -f (Mark (
    (Get-LogText) -notmatch 'copied on the phone')))

Stop-ClipboardPageSharing
$null = Wait-Idle
Say ("  stopping leaves nothing sharing   {0}" -f (Mark (
    -not (Test-ClipboardSharing) -and $ui.ClipboardStart.IsEnabled -and -not $ui.ClipboardStop.IsEnabled)))
$ui.ClipboardClear.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
$null = Wait-Idle
Say ("  and the list can be emptied   {0}" -f (Mark (@($ui.ClipboardList.ItemsSource).Count -eq 0)))

Say ''
Say '== fitting the window =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize -Size $size
    $null = Wait-Idle
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture -Name "clipboard-$size"))
    $outside = @(Get-OutsideElements -Root $clipboardPage.Root)
    Say ("  {0}: nothing sticks out{1}   {2}" -f $size, $(if ($outside) { ' - ' + ($outside -join '; ') } else { '' }),
        (Mark ($outside.Count -eq 0)))
}
Set-WindowSize 'default'

if ($null -ne $before -and "$before") { $null = Set-Clipboard -Value $before }
else { [System.Windows.Clipboard]::Clear() }
