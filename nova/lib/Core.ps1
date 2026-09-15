<#
    AndroidDC Nova - everything that is not the window.

    Finding the tools, running adb without freezing the window, quoting for
    the phone's shell, settings, and reading what state a phone is in.
    Dot-sourced by androiddc-nova.ps1, so every name here is script scope.

    Nothing in this file touches a control. The window's helpers are in
    lib\Ui.ps1, and each page keeps its own work in pages\<Page>.ps1.
#>

$script:appName = 'AndroidDC Nova'
$script:appVersion = '1.2.1'
$script:packageName = 'com.genymobile.gnirehtet'
# its own file: the WinForms AndroidDC keeps settings.json, and neither must
# overwrite the other's keys
$script:settingsPath = Join-Path $env:APPDATA 'AndroidDC\nova-settings.json'

$script:adbPath = $null
$script:gnirehtetPath = $null
$script:scrcpyPath = $null

# Where adb, scrcpy, gnirehtet and get-upstream.ps1 live. Nova sits in the nova\
# folder of the AndroidDC project and shares that folder's tools with the
# classic window; run on its own, it uses its own folder.
$script:toolsRoot = $scriptRoot
$parentFolder = Split-Path -Parent $scriptRoot
if ($parentFolder -and (Test-Path -LiteralPath (Join-Path $parentFolder 'get-upstream.ps1') -PathType Leaf)) {
    $script:toolsRoot = $parentFolder
}

# ------------------------------------------------------------------ tools ----

function Resolve-Tool {
    # this folder, then the project folder, then PATH
    param([string]$FileName)

    foreach ($folder in @($scriptRoot, $script:toolsRoot)) {
        $local = Join-Path $folder $FileName
        if (Test-Path -LiteralPath $local -PathType Leaf) { return (Resolve-Path -LiteralPath $local).Path }
    }

    $command = Get-Command $FileName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Install-UpstreamPackage {
    # scrcpy or gnirehtet is missing: ask, then let get-upstream.ps1 fetch it
    # from the official release, and wait until it has finished
    param([ValidateSet('scrcpy', 'gnirehtet')][string]$Package)

    $downloader = Join-Path $script:toolsRoot 'get-upstream.ps1'
    if (-not (Test-Path -LiteralPath $downloader -PathType Leaf)) {
        [void][System.Windows.MessageBox]::Show(
            "$Package was not found in`r`n$($script:toolsRoot)`r`n`r`nget-upstream.ps1 is not there either, so it cannot be downloaded.",
            "$Package is missing", 'OK', 'Warning')
        return $false
    }

    $answer = [System.Windows.MessageBox]::Show(
        "$Package was not found in`r`n$($script:toolsRoot)`r`n`r`nDownload it now from the official GitHub release?",
        "$Package is missing", 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return $false }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$downloader`"",
        '-OnlyMissing', '-Destination', "`"$($script:toolsRoot)`"")
    if ($Package -eq 'scrcpy') { $arguments += '-SkipGnirehtet' } else { $arguments += '-SkipScrcpy' }

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
        # reading the handle first is what makes ExitCode readable afterwards
        $null = $process.Handle
        $process.WaitForExit()
    } catch {
        [void][System.Windows.MessageBox]::Show("The download could not be started:`r`n$($_.Exception.Message)",
            $script:appName, 'OK', 'Error')
        return $false
    }
    return ($process.ExitCode -eq 0)
}

# ------------------------------------------------------- off the UI thread ----

# adb must never run on the window's thread: a screenshot alone costs more
# than a second. The work runs in one reused background runspace while the
# window keeps drawing; $script:busy counts what is running, and timers skip
# a tick while it is above zero.
$script:workRunspace = $null
$script:busy = 0
$script:busyWhat = ''
$script:busySince = $null

function Invoke-Pump {
    # what DoEvents is for WinForms: let WPF draw and handle input, then return
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null },
        $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Pumped {
    # Start-Sleep for the window's thread: the window keeps answering meanwhile
    param([int]$Milliseconds)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
        Invoke-Pump
        Start-Sleep -Milliseconds 10
    }
}

function Get-WorkRunspace {
    if ($null -eq $script:workRunspace -or $script:workRunspace.RunspaceStateInfo.State -ne 'Opened') {
        $script:workRunspace = [runspacefactory]::CreateRunspace()
        $script:workRunspace.ApartmentState = 'MTA'
        $script:workRunspace.ThreadOptions = 'ReuseThread'
        $script:workRunspace.Open()
    }
    return $script:workRunspace
}

function Get-BusyText {
    # what the busy strip names: the program and its arguments, without
    # "-s serial", and a command sent over base64 shown as the command it is
    param([string]$FilePath, [string[]]$ArgumentList)

    $words = @($ArgumentList)
    if ($words.Count -gt 2 -and $words[0] -eq '-s') { $words = $words[2..($words.Count - 1)] }
    $text = $words -join ' '
    if ($text -match '^shell echo (\S+) \| base64 -d \| sh$') {
        try { $text = 'shell ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) } catch { }
    }
    $text = ([IO.Path]::GetFileNameWithoutExtension($FilePath) + ' ' + $text).Trim()
    if ($text.Length -gt 110) { $text = $text.Substring(0, 107) + '...' }
    return $text
}

function Invoke-OffThread {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutMs = 180000)

    $shell = [powershell]::Create()
    $shell.Runspace = Get-WorkRunspace
    $null = $shell.AddScript({
        param($exe, $arguments)
        $ErrorActionPreference = 'Continue'
        # adb, scrcpy and gnirehtet write UTF-8, but PowerShell decodes a native
        # program with the console page: on an OEM page every Arabic name came
        # back garbled. Decode as UTF-8 for the call, then put the page back.
        $page = $null
        try {
            $page = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch { $page = $null }
        try {
            $lines = @(& $exe @arguments 2>&1 | ForEach-Object { "$_" })
        } finally {
            if ($page) { try { [Console]::OutputEncoding = $page } catch { } }
        }
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
    }).AddArgument($FilePath).AddArgument($ArgumentList)

    if ($script:busy -eq 0) { $script:busyWhat = Get-BusyText -FilePath $FilePath -ArgumentList $ArgumentList }
    $script:busy++
    try {
        $handle = $shell.BeginInvoke()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handle.IsCompleted) {
            Invoke-Pump
            Start-Sleep -Milliseconds 10
            if ($watch.ElapsedMilliseconds -gt $TimeoutMs) {
                $shell.Stop()
                return [PSCustomObject]@{ ExitCode = -1; Lines = @("timed out after $TimeoutMs ms") }
            }
        }
        $result = $null
        try { $result = @($shell.EndInvoke($handle))[0] } catch {
            return [PSCustomObject]@{ ExitCode = -1; Lines = @($_.Exception.Message) }
        }
        if ($null -eq $result) { return [PSCustomObject]@{ ExitCode = -1; Lines = @() } }
        return $result
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $shell.Dispose()
    }
}

function Invoke-Adb {
    param([string[]]$CommandArguments, [int]$TimeoutMs = 180000)

    $result = Invoke-OffThread -FilePath $script:adbPath -ArgumentList $CommandArguments -TimeoutMs $TimeoutMs
    return [PSCustomObject]@{
        ExitCode = $result.ExitCode
        Lines    = $result.Lines
        Text     = ($result.Lines -join "`n")
    }
}

function Invoke-DeviceShell {
    # a fixed command; for text a person typed, use Invoke-DeviceCommand
    param([string]$Serial, [string[]]$CommandArguments)
    return Invoke-Adb -CommandArguments (@('-s', $Serial, 'shell') + $CommandArguments)
}

function Invoke-DeviceShellText {
    # one whole shell line, sent over base64 so neither side parses it on the way
    param([string]$Serial, [string]$Command)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    return Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', "echo $encoded | base64 -d | sh")
}

function Test-TextContains {
    # what a filter box means: the typed text anywhere in the value, any case.
    # -like would read [ ] ? * as a pattern.
    param([string]$Text, [string]$Part)
    return $Text.IndexOf($Part, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Quote-DeviceArgument {
    # one word for the phone's shell, whatever it contains
    param([string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

function Invoke-DeviceCommand {
    <#
        Runs one command on the phone with every argument arriving exactly as
        given. adb joins its arguments with spaces and the phone's shell splits
        them again ("printf [%s] a 'b c'" printed [a][b][c]), and Windows
        PowerShell drops a double quote inside an argument to a native
        program. So each argument is quoted for sh and the line goes over
        base64.
    #>
    param([string]$Serial, [string[]]$Arguments)

    $command = (@($Arguments) | ForEach-Object { Quote-DeviceArgument $_ }) -join ' '
    return Invoke-DeviceShellText -Serial $Serial -Command $command
}

function Get-AdbBytes {
    <#
        The raw bytes adb writes to stdout (exec-out screencap, exec-out cat),
        read straight into memory. Never through a file: a redirected file
        stays locked, which once crashed the capture.
    #>
    param([string]$Arguments, [int]$TimeoutMs = 20000)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return $null }

    $buffer = New-Object System.IO.MemoryStream
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
    if ($script:busy -eq 0) { $script:busyWhat = 'adb ' + ($Arguments -replace '^-s \S+ ', '') }
    $script:busy++
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $copy.IsCompleted) {
            Invoke-Pump
            Start-Sleep -Milliseconds 10
            if ($watch.ElapsedMilliseconds -gt $TimeoutMs) {
                try { $process.Kill() } catch { }
                return $null
            }
        }
        $null = $process.WaitForExit(2000)
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $process.Dispose()
    }

    $bytes = $buffer.ToArray()
    $buffer.Dispose()
    # the comma keeps a byte[] whole: returned bare, it is unrolled into bytes
    return ,$bytes
}

# ---------------------------------------------------------------- devices ----

function Get-AdbDevices {
    $result = Invoke-Adb -CommandArguments @('devices', '-l')

    $devices = @()
    foreach ($line in $result.Lines) {
        $text = "$line".Trim()
        if ($text -eq '' -or $text -like 'List of devices*' -or $text -like '*daemon*') { continue }
        $parts = $text -split '\s+'
        if ($parts.Count -lt 2) { continue }

        $model = ($parts | Where-Object { $_ -like 'model:*' } | Select-Object -First 1)
        if ($model) { $model = $model.Substring(6) } else { $model = 'unknown' }

        $devices += [PSCustomObject]@{
            Serial = $parts[0]
            State  = $parts[1]
            Model  = $model
            Link   = if ($parts[0] -match ':\d+$') { 'tcp' } else { 'usb' }
        }
    }
    return $devices
}

function Get-DeviceSignature {
    param($Devices)
    return (@($Devices) | ForEach-Object { "$($_.Serial)=$($_.State)" } | Sort-Object) -join ';'
}

function Get-BatteryInfo {
    # level, charging and temperature, as values rather than one line
    param([string]$Serial)

    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys', 'battery')).Text
    $info = [PSCustomObject]@{ Level = $null; Status = 'unknown'; Temperature = $null; Line = '' }
    if ($dump -match '(?m)^\s*level:\s*(\d+)') { $info.Level = [int]$Matches[1] }
    $status = if ($dump -match '(?m)^\s*status:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    if ($dump -match '(?m)^\s*temperature:\s*(\d+)') { $info.Temperature = [int]$Matches[1] / 10 }
    # BatteryManager.BATTERY_STATUS_*
    $info.Status = switch ($status) { 2 { 'charging' } 3 { 'discharging' } 4 { 'not charging' } 5 { 'full' } default { 'unknown' } }

    $level = if ($null -ne $info.Level) { "$($info.Level)" } else { '?' }
    $info.Line = "battery $level% ($($info.Status)"
    if ($null -ne $info.Temperature) { $info.Line += ', ' + ('{0:N1}' -f $info.Temperature) + ' C' }
    $info.Line += ')'
    return $info
}

function Get-SignalInfo {
    param([string]$Serial)

    $info = [PSCustomObject]@{ Operator = ''; Network = ''; Level = $null; Dbm = $null; NoSim = $false; Line = '' }
    $info.Operator = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.operator.alpha')).Text.Trim()
    $info.Network = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.network.type')).Text.Trim()
    $sim = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.sim.state')).Text.Trim()

    if (-not $sim -or $sim -match 'ABSENT|UNKNOWN' -and -not $info.Operator) {
        $info.NoSim = $true
        $info.Line = 'no SIM'
        return $info
    }

    # one long line holds every radio's CellSignalStrength*
    $strength = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys telephony.registry | grep -m1 mSignalStrength')).Text
    foreach ($match in [regex]::Matches($strength, 'CellSignalStrength(Lte|Nr|Wcdma|Gsm|Tdscdma|Cdma):(?<body>[^,]{0,200})')) {
        $body = $match.Groups['body'].Value
        $level = if ($body -match '(?<!miui)(?<!mOptimized)\blevel\s*=\s*(\d+)') { [int]$Matches[1] } else { -1 }
        $dbm = $null
        foreach ($field in @('rsrp', 'ssRsrp', 'rssi', 'cdmaDbm')) {
            if ($body -match "$field\s*=\s*(-?\d+)") {
                $value = [int]$Matches[1]
                # 2147483647 = Integer.MAX_VALUE = "not available"
                if ($value -ne 2147483647 -and $value -lt 0) { $dbm = $value; break }
            }
        }
        if ($level -gt 0 -and $null -ne $dbm -and ($null -eq $info.Level -or $level -gt $info.Level)) {
            $info.Level = $level
            $info.Dbm = $dbm
        }
    }

    $parts = @()
    if ($info.Operator) { $parts += $info.Operator }
    if ($info.Network) { $parts += $info.Network }
    if ($null -ne $info.Level) { $parts += "signal $($info.Level)/4 ($($info.Dbm) dBm)" } else { $parts += 'signal unknown' }
    $info.Line = $parts -join '  |  '
    return $info
}

function Get-DeviceScreenState {
    # locked / unlocked and screen on / off
    param([string]$Serial)

    $state = [PSCustomObject]@{ Locked = $null; ScreenOn = $null }

    # the trust dump lists every user; only the current one matters
    $trust = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys', 'trust')).Text
    foreach ($line in ($trust -split "`r?`n")) {
        if ($line -match '\(current\)' -and $line -match 'deviceLocked=(\d)') {
            $state.Locked = ($Matches[1] -eq '1')
            break
        }
    }
    if ($null -eq $state.Locked -and $trust -match 'deviceLocked=(\d)') { $state.Locked = ($Matches[1] -eq '1') }

    $display = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys display | grep -m1 mScreenState')).Text
    if ($display -match 'mScreenState=(\w+)') {
        $state.ScreenOn = ($Matches[1] -eq 'ON')
    } else {
        $power = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys power | grep -m1 mWakefulness=')).Text
        if ($power -match 'mWakefulness=(\w+)') { $state.ScreenOn = ($Matches[1] -eq 'Awake') }
    }
    return $state
}

function Get-MemoryInfo {
    # RAM in use and in total, in bytes, from /proc/meminfo
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('cat', '/proc/meminfo')).Text
    $total = if ($text -match '(?m)^MemTotal:\s+(\d+)') { [long]$Matches[1] * 1024 } else { $null }
    $available = if ($text -match '(?m)^MemAvailable:\s+(\d+)') { [long]$Matches[1] * 1024 } else { $null }
    if ($null -eq $total -or $null -eq $available) { return $null }
    return [PSCustomObject]@{ Used = ($total - $available); Total = $total }
}

function Format-FileSize {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$([int]$Bytes) B"
}

# --------------------------------------------------------------- settings ----

# Each page registers what it keeps: a name, how to read it from the window
# and how to put it back. Nothing is written while the program runs; the file
# is saved when the window closes normally.
$script:settingHandlers = New-Object System.Collections.ArrayList

function Register-Setting {
    param([string]$Name, [scriptblock]$Get, [scriptblock]$Set)
    $null = $script:settingHandlers.Add([PSCustomObject]@{ Name = $Name; Get = $Get; Set = $Set })
}

function Save-Settings {
    try {
        $folder = Split-Path -Parent $script:settingsPath
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        $data = [ordered]@{}
        foreach ($handler in $script:settingHandlers) {
            try { $data[$handler.Name] = & $handler.Get } catch { }
        }
        $data | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    } catch {
        # settings are a convenience: never block the exit on them
    }
}

function Restore-Settings {
    if (-not (Test-Path -LiteralPath $script:settingsPath)) { return }
    try { $data = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json } catch { return }
    if ($null -eq $data) { return }

    $names = @($data.PSObject.Properties.Name)
    foreach ($handler in $script:settingHandlers) {
        if ($names -notcontains $handler.Name) { continue }
        try { & $handler.Set $data.($handler.Name) } catch { }
    }
}
