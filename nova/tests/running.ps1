# needs: phone (reads only)
# The Running page: processes read from dumpsys and top, the info line, the
# filter, apps only, sorting numbers as numbers, the colours, the export, the
# automatic refresh (and that it waits while something is running), and the
# page fitting the smallest window. Nothing is stopped or killed.

Say '== the page =='
$null = Wait-Idle -Seconds 60
Show-Page -Page 'running'
$null = Wait-Idle -Seconds 60
$columns = @($ui.RunningList.View.Columns | ForEach-Object { "$($_.Header)" })
Say ("columns: {0}   {1}" -f ($columns -join ', '), (Mark ($columns.Count -eq 7 -and $columns[0] -eq 'PROCESS')))
Say ("right-click menu has the button actions ({0} entries)   {1}" -f $ui.RunningList.ContextMenu.Items.Count,
    (Mark ($ui.RunningList.ContextMenu.Items.Count -eq 6)))
Say ("Kill all background is a danger button   {0}" -f (Mark ([object]::ReferenceEquals($ui.RunningKillAll.Style, (Get-Resource 'DangerButton')))))
Say ("the copy glyph carries its words   {0}" -f (Mark ((Get-ButtonCaption -Button $ui.RunningCopy) -eq 'Copy the selected rows')))

$watch = [System.Diagnostics.Stopwatch]::StartNew()
while ((Test-RunningDeviceReady) -and $watch.Elapsed.TotalSeconds -lt 40 -and $script:runningItems.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
if (-not (Test-RunningDeviceReady) -or $script:runningItems.Count -eq 0) {
    if (Test-RunningDeviceReady) { Say ("the phone is ready but no process was listed   {0}" -f (Mark $false)) }
    Say 'SKIPPED the phone checks - no ready device'
} else {
    Say ''
    Say '== opening the page read the processes =='
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 40 -and $script:runningItems.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
    Say ("'{0}'" -f $ui.RunningInfo.Text)
    Say ("{0} processes read, {1} shown   {2}" -f @($script:runningRows).Count, $script:runningItems.Count, (Mark ($script:runningItems.Count -gt 0)))
    Say ("info line 'N processes  |  M MB free'   {0}" -f (Mark ($ui.RunningInfo.Text -match "^$($script:runningItems.Count) processes  \|  [\d,.]+ MB free$")))
    $withMemory = @($script:runningItems | Where-Object { $_.Memory -gt 0 }).Count
    Say ("{0} rows have a memory figure from top   {1}" -f $withMemory, (Mark ($withMemory -gt 0)))
    $pidsOk = @($script:runningItems | Where-Object { $_.Pid -notmatch '^\d+$' }).Count -eq 0
    $namesOk = @($script:runningItems | Where-Object { $_.Name -match '^\d' -or $_.Name -notmatch '\.' }).Count -eq 0
    Say ("every pid is a number, every name a real process name   {0}" -f (Mark ($pidsOk -and $namesOk)))
    $unique = @($script:runningItems | ForEach-Object { $_.Pid } | Sort-Object -Unique).Count
    Say ("each pid listed once   {0}" -f (Mark ($unique -eq $script:runningItems.Count)))

    Say ''
    Say '== colours =='
    $front = @($script:runningItems | Where-Object { $_.State -like 'fg*' -or $_.State -like 'vis*' -or $_.State -like 'top*' })
    $cached = @($script:runningItems | Where-Object { $_.State -like 'cch*' -or $_.State -like 'empty*' })
    $green = Get-Resource 'Success'
    $grey = Get-Resource 'MutedText'
    Say ("{0} foreground rows in green, {1} cached rows in grey   {2}" -f $front.Count, $cached.Count,
        (Mark (@($front | Where-Object { -not [object]::ReferenceEquals($_.Brush, $green) }).Count -eq 0 -and
               @($cached | Where-Object { -not [object]::ReferenceEquals($_.Brush, $grey) }).Count -eq 0)))

    Say ''
    Say '== sorting =='
    $memories = @($script:runningItems | ForEach-Object { [double]$_.Memory })
    $sorted = $true
    for ($i = 1; $i -lt $memories.Count; $i++) { if ($memories[$i] -gt $memories[$i - 1]) { $sorted = $false } }
    Say ("memory, the biggest first, by default   {0}" -f (Mark $sorted))
    $script:runningSortColumn = 'Pid'
    $script:runningSortDescending = $false
    Update-RunningView
    $pids = @($script:runningItems | ForEach-Object { [int]$_.Pid })
    $sorted = $true
    for ($i = 1; $i -lt $pids.Count; $i++) { if ($pids[$i] -lt $pids[$i - 1]) { $sorted = $false } }
    Say ("pid as a number, not as text   {0}" -f (Mark $sorted))
    $script:runningSortColumn = 'Memory'
    $script:runningSortDescending = $true
    Update-RunningView

    Say ''
    Say '== filter and apps only =='
    $name = $script:runningItems[0].Name
    $part = ($name -split '[.:]')[-1]
    $ui.RunningFilter.Text = $part
    $wrongRows = @($script:runningItems | Where-Object { -not (Test-TextContains $_.Name $part) }).Count
    Say ("'{0}' keeps {1} matching row(s) and no other   {2}" -f $part, $script:runningItems.Count,
        (Mark ($script:runningItems.Count -gt 0 -and $wrongRows -eq 0 -and (@($script:runningItems | ForEach-Object { $_.Name }) -contains $name))))
    $ui.RunningFilter.Text = '[*'
    Say ("'[*' is literal text: {0} rows   {1}" -f $script:runningItems.Count, (Mark ($script:runningItems.Count -eq 0)))
    $ui.RunningFilter.Text = ''
    $ui.RunningApps.IsChecked = $false
    Update-RunningView
    $allCount = $script:runningItems.Count
    $ui.RunningApps.IsChecked = $true
    Update-RunningView
    Say ("apps only shows no more than all ({0} of {1})   {2}" -f $script:runningItems.Count, $allCount, (Mark ($script:runningItems.Count -le $allCount)))

    # Enter in the filter reads the phone again
    $script:runningItems.Clear()
    $source = [System.Windows.PresentationSource]::FromVisual($ui.RunningFilter)
    if ($source) {
        $press = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [System.Windows.Input.Key]::Return)
        $press.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $ui.RunningFilter.RaiseEvent($press)
        $null = Wait-Idle -Seconds 40
        Say ("Enter in the filter reads the list again   {0}" -f (Mark ($script:runningItems.Count -gt 0)))
    } else {
        Update-RunningList
        Say 'SKIPPED the Enter check - the filter box has no presentation source'
    }

    Say ''
    Say '== export =='
    $csv = @(Get-RunningListCsv)
    Say ("header   {0}" -f (Mark ($csv[0] -eq 'process,pid,state,kind,cpu,memory_mb,user')))
    Say ("one line per row, seven fields   {0}" -f (Mark ($csv.Count -ge 2 -and ($csv.Count - 1) -eq $script:runningItems.Count -and ($csv[1] -split ',').Count -ge 7)))

    Say ''
    Say '== automatic refresh =='
    $ui.RunningMs.Text = '999'
    $ui.RunningAuto.IsChecked = $true
    Set-RunningAuto
    Say ("the milliseconds keep their limits: {0}   {1}" -f $ui.RunningMs.Text, (Mark ($ui.RunningMs.Text -eq '2000' -and $script:runningTimer.Interval.TotalMilliseconds -eq 2000)))
    Say ("the timer runs while auto is on   {0}" -f (Mark $script:runningTimer.IsEnabled))

    $script:busy++
    $script:runningItems.Clear()
    Wait-Pumped -Milliseconds 5000
    Say ("a tick is skipped while something runs   {0}" -f (Mark ($script:runningItems.Count -eq 0)))
    $script:busy--

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 25 -and $script:runningItems.Count -eq 0) { Wait-Pumped -Milliseconds 300 }
    Say ("and the next one reads the list ({0:N1} s)   {1}" -f $watch.Elapsed.TotalSeconds, (Mark ($script:runningItems.Count -gt 0)))
    $ui.RunningAuto.IsChecked = $false
    Set-RunningAuto
    $ui.RunningMs.Text = '5000'
    $null = Wait-Idle -Seconds 30
    Say ("off again stops the timer   {0}" -f (Mark (-not $script:runningTimer.IsEnabled)))

    $ui.RunningList.UnselectAll()
    Say ("nothing selected: no process to act on   {0}" -f (Mark (@(Get-SelectedProcesses).Count -eq 0)))
}

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "running-$size"))
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'running').Root)
    Say ("  {0}: nothing sticks out on the right {1}   {2}" -f $size, ($outside -join '; '), (Mark ($outside.Count -eq 0)))
    $bottom = $ui.RunningKillAll.TransformToAncestor($ui.PageHost).Transform((New-Object System.Windows.Point(0, 0))).Y + $ui.RunningKillAll.ActualHeight
    Say ("  {0}: the buttons are inside the page ({1:N0} of {2:N0}), the list {3:N0} px tall   {4}" -f $size, $bottom,
        $ui.PageHost.ActualHeight, $ui.RunningList.ActualHeight, (Mark ($bottom -le $ui.PageHost.ActualHeight + 1 -and $ui.RunningList.ActualHeight -ge 120)))
}
