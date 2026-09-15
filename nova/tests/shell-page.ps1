# needs: phone for the live part (skipped without one)
# The Shell page: both inner pages fit and give the output the room, the
# logcat filter, trim, cap and drop counting on made-up lines, the history,
# and - with a phone - the live shell in UTF-8 both ways and logcat arriving,
# with the shell still answering while logcat runs and after it stops.
# Only read-only commands reach the phone; its log buffer is never cleared.

Say '== the page =='
Show-Page -Page 'shell'
$null = Wait-Idle -Seconds 30
Say ("  page shown   {0}" -f (Mark (Test-PageShown -Key 'shell')))

foreach ($tab in @(0, 1)) {
    $ui.ShellTabs.SelectedIndex = $tab
    foreach ($size in @('default', 'min')) {
        Set-WindowSize $size
        $null = Wait-Idle -Seconds 10
        $path = Save-WindowPicture "shell-page-tab$tab-$size"
        Say ("  tab {0} {1}: {2}" -f $tab, $size, $path)
        $outside = @(Get-OutsideElements -Root $shellPage.Root)
        Say ("  tab {0} {1}: nothing sticks out on the right {2}  {3}" -f $tab, $size, ($outside -join '; '), (Mark ($outside.Count -eq 0)))
        $box = if ($tab -eq 0) { $ui.ShellOut } else { $ui.ShellLogcatText }
        $bottom = $box.TransformToAncestor($ui.PageHost).Transform((New-Object System.Windows.Point(0, 0))).Y + $box.ActualHeight
        Say ("  tab {0} {1}: the output is {2:N0} px tall and ends inside the page ({3:N0} of {4:N0})   {5}" -f $tab, $size,
            $box.ActualHeight, $bottom, $ui.PageHost.ActualHeight, (Mark ($box.ActualHeight -ge 120 -and $bottom -le $ui.PageHost.ActualHeight + 1)))
    }
}
Set-WindowSize 'default'
$ui.ShellTabs.SelectedIndex = 1

Say ''
Say '== logcat on made-up lines =='
Say ("  levels V D I W E F, I picked   {0}" -f (Mark ($ui.ShellLogcatLevel.Items.Count -eq 6 -and "$($ui.ShellLogcatLevel.SelectedItem)" -like 'I *')))
$script:logcatProcess = $null
$ui.ShellLogcatFilter.Text = ''
Wait-Pumped -Milliseconds 500
Clear-Logcat -AlsoPhone $false
$script:logcatRaw = New-Object 'System.Collections.Generic.List[string]'
$script:logcatQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
for ($i = 0; $i -lt 7000; $i++) { $script:logcatQueue.Enqueue(('09-15 12:00:00.000 I/Tag{0}( 123): line {1}' -f ($i % 3), $i)) }
$ticks = 0
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($script:logcatQueue.Count -gt 0 -and $ticks -lt 50) { Update-LogcatView; $ticks++ }
$watch.Stop()
Say ("  7000 lines in {0} ticks of 800 ({1} ms)   {2}" -f $ticks, $watch.ElapsedMilliseconds, (Mark ($ticks -eq 9)))
Say ("  memory keeps at most 6000: {0}, the newest last   {1}" -f $script:logcatRaw.Count,
    (Mark ($script:logcatRaw.Count -eq 5000 -and $script:logcatRaw[$script:logcatRaw.Count - 1] -like '*line 6999')))
$shownLines = @($ui.ShellLogcatText.Text -split "`r?`n" | Where-Object { $_ })
Say ("  the window shows every line: {0}   {1}" -f $shownLines.Count, (Mark ($shownLines.Count -eq 7000 -and (Get-ShellConsoleLength -Box $ui.ShellLogcatText) -eq $ui.ShellLogcatText.Text.Length)))

$ui.ShellLogcatFilter.Text = 'tag1('
$script:logcatFilterTimer.Stop()
Show-LogcatFiltered
$expected = @($script:logcatRaw | Where-Object { $_.IndexOf('tag1(', [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
$shownLines = @($ui.ShellLogcatText.Text -split "`r?`n" | Where-Object { $_ })
Say ("  status: '{0}'   {1}" -f $ui.ShellLogcatState.Text,
    (Mark ($ui.ShellLogcatState.Text -eq "$expected of 5000 kept lines match 'tag1(' - showing the newest 1200")))
Say ("  the lines already there are re-filtered, newest 1200 drawn   {0}" -f (Mark (
    $shownLines.Count -eq 1200 -and @($shownLines | Where-Object { $_ -notlike '*Tag1(*' }).Count -eq 0)))
$script:logcatQueue.Enqueue('09-15 12:00:01.000 I/Tag1( 123): new one')
$script:logcatQueue.Enqueue('09-15 12:00:01.000 I/Tag2( 123): new two')
Update-LogcatView
$shownLines = @($ui.ShellLogcatText.Text -split "`r?`n" | Where-Object { $_ })
Say ("  new lines pass the filter too   {0}" -f (Mark ($shownLines[-1] -like '*new one' -and $shownLines.Count -eq 1201)))

$ui.ShellLogcatFilter.Text = ''
Wait-Pumped -Milliseconds 120
$early = @($ui.ShellLogcatText.Text -split "`r?`n" | Where-Object { $_ }).Count
Wait-Pumped -Milliseconds 700
$late = @($ui.ShellLogcatText.Text -split "`r?`n" | Where-Object { $_ })
Say ("  clearing the filter redraws after the typing settles ({0} then {1})   {2}" -f $early, $late.Count,
    (Mark ($early -eq 1201 -and $late.Count -eq 1200 -and $late[-1] -like '*new two' -and $ui.ShellLogcatState.Text -eq 'stopped')))

for ($i = 0; $i -lt 25000; $i++) { $script:logcatQueue.Enqueue("storm $i") }
Update-LogcatView
Say ("  a storm drops the oldest and says so: {0} dropped   {1}" -f $script:logcatDropped, (Mark (
    $script:logcatDropped -eq 14200 -and $script:logcatQueue.Count -eq 10000 -and $ui.ShellLogcatState.Text -like '*14200 line(s) dropped*')))

Clear-Logcat -AlsoPhone $false
Say ("  Clear empties the window, the memory and the count   {0}" -f (Mark (
    $ui.ShellLogcatText.Text.Length -eq 0 -and $script:logcatRaw.Count -eq 0 -and $script:logcatDropped -eq 0)))
$script:logcatQueue = $null

$builder = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 9000; $i++) { $null = $builder.Append(('L{0:D6} {1}' -f $i, ('x' * 41))).Append("`n") }
Set-ShellConsoleText -Box $ui.ShellLogcatText -Text $builder.ToString()
$before = $ui.ShellLogcatText.Text.Length
$watch = [Diagnostics.Stopwatch]::StartNew()
Remove-LogcatHead
$watch.Stop()
$after = $ui.ShellLogcatText.Text
Say ("  head trim: {0} -> {1} characters in {2} ms, on a line start   {3}" -f $before, $after.Length, $watch.ElapsedMilliseconds, (Mark (
    $before -eq 450000 -and $after.Length -le 200000 -and $after.Length -gt 199900 -and $after.StartsWith('L') -and $after.EndsWith("`n") -and
    (Get-ShellConsoleLength -Box $ui.ShellLogcatText) -eq $after.Length -and $ui.ShellLogcatText.IsReadOnly)))
Clear-Logcat -AlsoPhone $false

Say ''
Say '== shell box, presets and history =='
$ui.ShellTabs.SelectedIndex = 0
Clear-ShellConsole -Box $ui.ShellOut
Write-Shell 'first'
Write-Shell "second`r`nthird"
Say ("  Write-Shell appends lines   {0}" -f (Mark ($ui.ShellOut.Text -eq ("first`r`nsecond`r`nthird`r`n"))))
$ui.ShellInput.Text = 'echo nothing'
Send-ShellLine
Say ("  without a session a line is refused, not lost   {0}" -f (Mark ($ui.ShellOut.Text -like '*No live shell*' -and $ui.ShellInput.Text -eq 'echo nothing')))
$ui.ShellPreset.SelectedIndex = 3
Say ("  a preset fills the box and the list goes back   {0}" -f (Mark ($ui.ShellInput.Text -eq 'ip route' -and $ui.ShellPreset.SelectedIndex -eq 0)))
$script:shellHistory = @('echo a', 'echo b')
$script:shellHistoryIndex = 2
$ui.ShellInput.Text = ''
$up1 = Step-ShellHistory -Step -1; $t1 = $ui.ShellInput.Text
$up2 = Step-ShellHistory -Step -1; $t2 = $ui.ShellInput.Text
$null = Step-ShellHistory -Step -1; $t3 = $ui.ShellInput.Text
$null = Step-ShellHistory -Step 1; $t4 = $ui.ShellInput.Text
$null = Step-ShellHistory -Step 1; $t5 = $ui.ShellInput.Text
Say ("  Up/Down walk the history and end on an empty line   {0}" -f (Mark (
    $up1 -and $up2 -and $t1 -eq 'echo b' -and $t2 -eq 'echo a' -and $t3 -eq 'echo a' -and $t4 -eq 'echo b' -and $t5 -eq '')))
$script:shellHistory = @()
$script:shellHistoryIndex = 0
Say ("  no history, the key is left alone   {0}" -f (Mark (-not (Step-ShellHistory -Step -1))))
Clear-ShellConsole -Box $ui.ShellOut

Say ''
Say '== with the phone =='
$row = @($ui.DeviceList.SelectedItems) | Select-Object -First 1
if ($null -eq $row -or $row.State -ne 'device') {
    Say '  no ready phone - the live checks are skipped'
} else {
    # built from code points: test files are ASCII
    $word = -join [char[]](0x0645, 0x0631, 0x062D, 0x0628, 0x0627)

    function Test-ShellPageEcho {
        param([string]$Label)
        $script:shellTimer.Stop()   # answers are drained here, not by the window's timer
        $null = $script:shell.Drain(400)
        $script:shell.Send('echo ' + $Label)
        $script:shell.Send('echo ' + $word)
        Wait-Pumped -Milliseconds 2000
        $got = @($script:shell.Drain(400) | Where-Object { "$_".Trim() })
        $script:shellTimer.Start()
        Say ("  shell {0}: ascii {1}, arabic {2}   {3}" -f $Label, ($got -contains $Label), ($got -contains $word),
            (Mark (($got -contains $Label) -and ($got -contains $word))))
    }

    Start-LiveShell
    Wait-Pumped -Milliseconds 1500
    Say ("  the shell starts: Start off, Stop on   {0}" -f (Mark ($script:shell -and $script:shell.Running -and -not $ui.ShellStart.IsEnabled -and $ui.ShellStop.IsEnabled -and $ui.ShellStatus.Text -like 'connected to *')))
    Test-ShellPageEcho -Label 'before-logcat'

    $ui.ShellInput.Text = 'getprop ro.build.version.release'
    Invoke-ButtonClick -Button $ui.ShellSend
    Wait-Pumped -Milliseconds 2000
    $outLines = @($ui.ShellOut.Text -split "`r?`n")
    Say ("  Send through the page: the command is echoed and the answer drawn by the timer   {0}" -f (Mark (
        ($outLines -contains '$ getprop ro.build.version.release') -and @($outLines | Where-Object { $_ -match '^\d+(\.\d+)*$' }).Count -ge 1 -and
        $script:shellHistory[-1] -eq 'getprop ro.build.version.release' -and $ui.ShellInput.Text -eq '')))

    $ui.ShellInput.Text = 'echo ' + $word
    Send-ShellLine
    Wait-Pumped -Milliseconds 1500
    Say ("  Arabic typed into the box comes back unchanged   {0}" -f (Mark (@($ui.ShellOut.Text -split "`r?`n") -contains $word)))

    $ui.ShellTabs.SelectedIndex = 1
    Start-Logcat
    Wait-Pumped -Milliseconds 4000
    $info = $script:logcatProcess.StartInfo
    Say ("  logcat streams: {0} line(s) kept   {1}" -f $script:logcatRaw.Count, (Mark ($script:logcatRaw.Count -gt 0 -and $ui.ShellLogcatText.Text.Length -gt 0)))
    Say ("  logcat reads UTF-8, Start off, Stop on   {0}" -f (Mark ($info.StandardOutputEncoding.WebName -eq 'utf-8' -and
        $info.StandardErrorEncoding.WebName -eq 'utf-8' -and -not $ui.ShellLogcatStart.IsEnabled -and $ui.ShellLogcatStop.IsEnabled)))
    Test-ShellPageEcho -Label 'while-logcat-runs'

    Stop-Logcat
    Wait-Pumped -Milliseconds 800
    Say ("  logcat stopped   {0}" -f (Mark ((-not $script:logcatProcess) -and $ui.ShellLogcatStart.IsEnabled -and $ui.ShellLogcatState.Text -eq 'stopped')))
    Test-ShellPageEcho -Label 'after-logcat'

    Start-Logcat
    Wait-Pumped -Milliseconds 2500
    Stop-Logcat -Quiet
    Wait-Pumped -Milliseconds 800
    Test-ShellPageEcho -Label 'after-a-second-logcat'

    Stop-LiveShell
    Say ("  the shell stops: Start on, not connected   {0}" -f (Mark ($null -eq $script:shell -and $ui.ShellStart.IsEnabled -and $ui.ShellStatus.Text -eq 'not connected')))
    Clear-Logcat -AlsoPhone $false
    Clear-ShellConsole -Box $ui.ShellOut
}
