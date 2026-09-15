# pages\Running.ps1 - what the selected phone runs right now, from dumpsys
# activity processes and top: force stop, kill, app info, kill all background,
# copy and export, with an automatic refresh.

$script:runningRows = @()
$script:runningItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:runningSortColumn = 'Memory'
$script:runningSortDescending = $true
$script:runningFree = ''
$script:runningSerial = $null

$runningPage = Register-Page -Key 'running' -Title 'Running' -Glyph 'E9D9' -Section 'System' -Xaml 'Running.xaml' `
    -OnShow { if ($script:runningItems.Count -eq 0 -and (Test-RunningDeviceReady)) { Update-RunningList } } `
    -OnDeviceChanged {
        $serial = Get-SelectedSerial
        if ($serial -and $serial -eq $script:runningSerial) { return }
        Clear-RunningList
        if ((Test-PageShown -Key 'running') -and (Test-RunningDeviceReady)) { Update-RunningList }
    } `
    -Refresh { Update-RunningList }

$ui.RunningList.ItemsSource = $script:runningItems

function Test-RunningDeviceReady {
    $first = Get-SelectedDevice
    return ($null -ne $first -and $first.State -eq 'device')
}

function Clear-RunningList {
    $script:runningRows = @()
    $script:runningItems.Clear()
    $script:runningSerial = $null
    $script:runningFree = ''
    $ui.RunningInfo.Text = 'Refresh reads the processes of the selected phone'
}

function Get-RunningProcesses {
    param([string]$Serial)

    # importance and kind come from the activity manager, cpu/memory from top
    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys activity processes | grep -E "Proc #"')).Text
    # one sample always reports 0 %CPU: take two and keep the second
    $top = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'top -b -n 2 -d 1 -q -o PID,USER,%CPU,RES,CMDLINE')).Text

    $cpu = @{}
    $memory = @{}
    $user = @{}
    foreach ($line in ($top -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+(\S+)\s+([\d.]+)\s+(\S+)\s+(.*)$') {
            $pid1 = $Matches[1]
            $user[$pid1] = $Matches[2]
            $cpu[$pid1] = [double]$Matches[3]

            $size = $Matches[4]
            $value = 0.0
            if ($size -match '^([\d.]+)([KMGB])?$') {
                $value = [double]$Matches[1]
                $unit = if ($Matches.ContainsKey(2)) { $Matches[2] } else { '' }
                switch ($unit) {
                    'M' { }                              # already megabytes
                    'G' { $value = $value * 1024 }
                    'K' { $value = $value / 1024 }
                    default { $value = $value / 1024 }   # bare number = kilobytes
                }
            }
            $memory[$pid1] = [Math]::Round($value, 1)
        }
    }

    $rows = @()
    $seen = @{}
    foreach ($line in ($dump -split "`r?`n")) {
        # Proc #12: fg     F/S/FGS  ---NFUA  t: 0 3630:com.example/u0a175 (service)
        if ($line -notmatch 'Proc\s*#\s*\d+:\s+(\S+)') { continue }
        $state = $Matches[1]
        if ($line -notmatch '(?<pid>\d+):(?<name>[^\s/]+)/(?<uid>[^\s/]+)(?:\s+\((?<kind>[\w-]+)\))?\s*$') { continue }
        $processId = $Matches['pid']
        $name = $Matches['name']
        $uid = $Matches['uid']
        $kind = if ($Matches.ContainsKey('kind')) { $Matches['kind'] } else { '' }

        # a dumpsys dump can be cut mid-line and glue two records together:
        # a real process name never starts with a digit
        if ($name -match '^\d' -or $name -notmatch '\.') { continue }

        if ($seen.ContainsKey($processId)) { continue }
        $seen[$processId] = $true

        $rows += [PSCustomObject]@{
            Name   = $name
            Pid    = $processId
            State  = $state
            Kind   = $kind
            Cpu    = $(if ($cpu.ContainsKey($processId)) { $cpu[$processId] } else { 0.0 })
            Memory = $(if ($memory.ContainsKey($processId)) { $memory[$processId] } else { 0.0 })
            User   = $(if ($user.ContainsKey($processId)) { $user[$processId] } else { $uid })
        }
    }

    return $rows
}

function Update-RunningView {
    # the rows read last, filtered and sorted as the page says; no trip to the phone
    $filter = $ui.RunningFilter.Text.Trim()
    $rows = @($script:runningRows)
    if ($ui.RunningApps.IsChecked) {
        $rows = @($rows | Where-Object { $_.Name -like '*.*' })
    }
    if ($filter) {
        $rows = @($rows | Where-Object { Test-TextContains $_.Name $filter })
    }

    $property = switch ($script:runningSortColumn) {
        'Pid' { @{ Expression = { [int]$_.Pid } } }
        'Cpu' { @{ Expression = { [double]$_.Cpu } } }
        'Memory' { @{ Expression = { [double]$_.Memory } } }
        default { $script:runningSortColumn }
    }
    $rows = @($rows | Sort-Object -Property $property -Descending:$script:runningSortDescending)

    $selected = @($ui.RunningList.SelectedItems | ForEach-Object { $_.Pid })
    $green = Get-Resource 'Success'
    $grey = Get-Resource 'MutedText'
    $ink = Get-Resource 'Ink'

    $script:runningItems.Clear()
    foreach ($row in $rows) {
        # foreground work in green, cached/empty processes in grey
        $brush = $ink
        if ($row.State -like 'fg*' -or $row.State -like 'vis*' -or $row.State -like 'top*') { $brush = $green }
        elseif ($row.State -like 'cch*' -or $row.State -like 'empty*') { $brush = $grey }
        $item = [PSCustomObject]@{
            Name = $row.Name; Pid = $row.Pid; State = $row.State; Kind = $row.Kind
            Cpu = $row.Cpu; Memory = $row.Memory; User = $row.User
            CpuText = ('{0:N1}' -f $row.Cpu); MemoryText = ('{0:N1}' -f $row.Memory); Brush = $brush
        }
        $script:runningItems.Add($item)
        if ($selected -contains $row.Pid) { $null = $ui.RunningList.SelectedItems.Add($item) }
    }

    if ($script:runningSerial) {
        $ui.RunningInfo.Text = "$($script:runningItems.Count) processes  |  $($script:runningFree)"
    }
}

function Update-RunningList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-RunningProcesses -Serial $serial)
    $free = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cat /proc/meminfo | grep MemAvailable')).Text
    # another phone may have been picked while those were read
    if ((Get-SelectedSerial) -ne $serial) { return }

    $script:runningRows = $rows
    $script:runningSerial = $serial
    $script:runningFree = if ($free -match '(\d+)\s*kB') { ('{0:N0} MB free' -f ([long]$Matches[1] / 1024)) } else { '' }
    Update-RunningView
}

function Get-SelectedProcesses {
    $rows = @()
    foreach ($item in @($ui.RunningList.SelectedItems)) {
        $rows += [PSCustomObject]@{
            Name    = $item.Name
            Package = ($item.Name -split ':')[0]
            Pid     = $item.Pid
            User    = $item.User
        }
    }
    return $rows
}

function Stop-RunningProcess {
    param([switch]$Soft)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedProcesses)
    if ($rows.Count -eq 0) { Write-Log 'Pick a process in the list first.' $colorWarn; return }

    $system = @($rows | Where-Object { $_.User -in @('root', 'system') -or $_.Package -like 'com.android.systemui*' })
    $prompt = "Stop these processes on $serial ?" + [Environment]::NewLine +
        (($rows | ForEach-Object { "$($_.Name)  (pid $($_.Pid))" }) -join [Environment]::NewLine)
    if ($system.Count -gt 0) {
        $prompt += [Environment]::NewLine + [Environment]::NewLine +
            'Careful: some of these belong to the system and the phone may misbehave.'
    }

    if (-not (Show-Confirm -Title 'Stop process' -Text $prompt -Yes 'Stop' -No 'Cancel' -Danger)) { return }

    foreach ($row in $rows) {
        $verb = if ($Soft) { 'kill' } else { 'force-stop' }
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', $verb, $row.Package)
        $text = $result.Text.Trim()
        Write-Log ("$verb $($row.Package)" + $(if ($text) { " -> $text" } else { ' -> done' })) `
            $(if ($text -match 'Error|Exception|denied') { $colorBad } else { $colorGood })
    }

    Wait-Pumped -Milliseconds 800
    Update-RunningList
}

function Stop-AllBackground {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (-not (Show-Confirm -Title 'Kill all' -Text "Kill every background process on $serial ?" -Yes 'Kill all' -No 'Cancel' -Danger)) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'kill-all')
    Write-Log ('am kill-all -> ' + $(if ($result.Text.Trim()) { $result.Text.Trim() } else { 'done' })) $colorGood
    Wait-Pumped -Milliseconds 800
    Update-RunningList
}

function Show-RunningAppInfo {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedProcesses)
    if ($rows.Count -eq 0) { Write-Log 'Pick a process first.' $colorWarn; return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.APPLICATION_DETAILS_SETTINGS', '-d', "package:$($rows[0].Package)")
    Write-Log "Opened the system page for $($rows[0].Package)." $colorInfo
    Wait-Pumped -Milliseconds 800
    $capture = Get-Command Update-Capture -ErrorAction SilentlyContinue
    if ($capture) {
        if ($capture.Parameters.ContainsKey('Quiet')) { Update-Capture -Quiet } else { Update-Capture }
    }
}

function Get-RunningListCsv {
    $lines = @('process,pid,state,kind,cpu,memory_mb,user')
    foreach ($item in @($script:runningItems)) {
        $lines += ('{0},{1},{2},{3},{4},{5},{6}' -f $item.Name, $item.Pid, $item.State, $item.Kind,
            $item.CpuText, $item.MemoryText, $item.User)
    }
    return $lines
}

function Export-RunningList {
    if ($script:runningItems.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $file = Select-SaveFile -Filter 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt' `
        -FileName ('running-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if (-not $file) { return }

    Set-Content -LiteralPath $file -Value (Get-RunningListCsv) -Encoding UTF8
    Write-Log "Exported $($script:runningItems.Count) processes to $file" $colorGood
}

function Set-RunningAuto {
    # the timer follows the switch and the milliseconds box
    $script:runningTimer.Interval = [TimeSpan]::FromMilliseconds((Get-NumberValue -Box $ui.RunningMs -Default 5000 -Minimum 2000 -Maximum 60000))
    if ($ui.RunningAuto.IsChecked) { $script:runningTimer.Start() } else { $script:runningTimer.Stop() }
}

# ------------------------------------------------------------------ events ----

$script:runningTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:runningTimer.Interval = [TimeSpan]::FromMilliseconds(5000)
$script:runningTimer.Add_Tick({
    # never on top of a call still running; and only for a list on screen
    if ($script:busy -gt 0 -or -not (Test-PageShown -Key 'running') -or -not (Test-RunningDeviceReady)) { return }
    $script:runningTimer.Stop()
    try { Update-RunningList } finally { if ($ui.RunningAuto.IsChecked) { $script:runningTimer.Start() } }
})
Register-Cleanup { $script:runningTimer.Stop() }

$ui.RunningRefresh.Add_Click({ Update-RunningList })
$ui.RunningStop.Add_Click({ Stop-RunningProcess })
$ui.RunningKill.Add_Click({ Stop-RunningProcess -Soft })
$ui.RunningKillAll.Add_Click({ Stop-AllBackground })
$ui.RunningAppInfo.Add_Click({ Show-RunningAppInfo })
$ui.RunningCopy.Add_Click({ Copy-ListSelection -List $ui.RunningList })
$ui.RunningExport.Add_Click({ Export-RunningList })
$ui.RunningApps.Add_Click({ Update-RunningView })
$ui.RunningFilter.Add_TextChanged({ Update-RunningView })
$ui.RunningFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Update-RunningList }
})
$ui.RunningAuto.Add_Click({ Set-RunningAuto })
$ui.RunningMs.Add_LostFocus({ Set-RunningAuto })
$ui.RunningMs.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Set-RunningAuto }
})

# a header click sorts the rows already read: numbers as numbers, the biggest
# first; a second click on the same column reverses
$ui.RunningList.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $eventArgs)
    $header = $eventArgs.OriginalSource
    if ($header -isnot [System.Windows.Controls.GridViewColumnHeader] -or -not $header.Column) { return }
    $binding = $header.Column.DisplayMemberBinding
    if (-not $binding) { return }
    $column = switch ($binding.Path.Path) { 'CpuText' { 'Cpu' } 'MemoryText' { 'Memory' } default { $binding.Path.Path } }
    if ($script:runningSortColumn -eq $column) {
        $script:runningSortDescending = -not $script:runningSortDescending
    } else {
        $script:runningSortColumn = $column
        $script:runningSortDescending = $true
    }
    Update-RunningView
})

Add-ListContextMenu -List $ui.RunningList -Buttons @($ui.RunningStop, $ui.RunningKill, $null,
    $ui.RunningAppInfo, $ui.RunningCopy, $ui.RunningExport)
