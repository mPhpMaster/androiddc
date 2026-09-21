#Requires -Version 5.1

<#
.SYNOPSIS
    AndroidDC - one Windows window that drives Android devices over adb.

.DESCRIPTION
    Twelve tabs sharing one device list and one log pane: Device,
    Tethering (both directions), Advanced (scrcpy mirroring and its options,
    adb tools, root / recovery), Apps, Contacts, SMS, Cam / Mic, Files,
    Running, Radios (Wi-Fi, Bluetooth, NFC), Users and Shell (live shell,
    logcat).
    The full guide is docs\user-guide.md; what changed is CHANGELOG.md.

    Closing the window stops the relay, stops the client on the device and
    removes the adb reverse tunnel.

    adb.exe, gnirehtet.exe, gnirehtet.apk and scrcpy.exe are taken from the
    script folder when present, otherwise from PATH. get-upstream.ps1 fetches
    the missing ones.
    Settings are remembered in %APPDATA%\AndroidDC\settings.json.
#>

[CmdletBinding()]
param(
    # started with Windows (Advanced > Automation): the window opens minimized,
    # and a phone that is already plugged in runs its rule as if just plugged
    [switch]$Minimized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox for rename / new folder
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# the release this file is; CHANGELOG.md says what each one changed
$appVersion = '1.3.0'
$packageName = 'com.genymobile.gnirehtet'
$settingsPath = Join-Path $env:APPDATA 'AndroidDC\settings.json'
$legacySettingsPath = Join-Path $env:APPDATA 'gnirehtet-gui\settings.json'

# starting with Windows and the rules per phone, and the icon by the clock,
# shared with the Nova window
. (Join-Path $scriptRoot 'shared\Automation.ps1')
. (Join-Path $scriptRoot 'shared\Tray.ps1')
. (Join-Path $scriptRoot 'shared\Backup.ps1')

$script:adbPath = $null
$script:gnirehtetPath = $null
$script:scrcpyPath = $null
$script:relayProcess = $null
$script:activeSerials = @()
$script:wifiDisabled = @()     # the phones whose Wi-Fi sharing turned off
$script:outFile = $null
$script:audioEncoders = @()   # filled from scrcpy --list-encoders
$script:appLabels = @{}       # serial -> @{ package = app name }, from scrcpy --list-apps
$script:appLabelsSeen = @{}   # serial -> the user-installed packages when the names were read
$script:rootCheckedSerial = $null   # the phone the Root page's marks were read from
$script:errFile = $null
$script:outOffset = 0
$script:errOffset = 0
$script:scrcpyProcesses = @()
$script:audioProcess = $null

# ---------------------------------------------------------------- helpers ---

function Resolve-Tool {
    param([string]$FileName)

    $local = Join-Path $scriptRoot $FileName
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        return (Resolve-Path -LiteralPath $local).Path
    }

    $command = Get-Command $FileName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }

    return $null
}

function Install-UpstreamPackage {
    # scrcpy or gnirehtet is not here: ask, then let get-upstream.ps1 fetch it
    # from the official release and wait until it has finished
    param([ValidateSet('scrcpy', 'gnirehtet')][string]$Package)

    $downloader = Join-Path $scriptRoot 'get-upstream.ps1'
    if (-not (Test-Path -LiteralPath $downloader -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "$Package was not found in`r`n$scriptRoot`r`n`r`n" +
            'get-upstream.ps1 is not in that folder either, so it cannot be downloaded automatically.',
            "$Package is missing", 'OK', 'Warning')
        return $false
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$Package was not found in`r`n$scriptRoot`r`n`r`n" +
        'Download it now from the official GitHub release?',
        "$Package is missing", 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$downloader`"",
        '-OnlyMissing', '-Destination', "`"$scriptRoot`"")
    $arguments += $(if ($Package -eq 'scrcpy') { '-GetScrcpy' } else { '-GetGnirehtet' })

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
        # reading the handle first is what makes ExitCode readable afterwards
        $null = $process.Handle
        $process.WaitForExit()
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "The download could not be started:`r`n$($_.Exception.Message)",
            'AndroidDC', 'OK', 'Error')
        return $false
    }

    if ($process.ExitCode -ne 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "The download of $Package did not finish. The window it opened says why.",
            'AndroidDC', 'OK', 'Warning')
        return $false
    }

    return $true
}

# Every adb call used to run on the UI thread, so the window froze for as long
# as the phone took to answer (a screenshot alone costs well over a second).
# The work now happens in a background runspace while the message loop keeps
# running, which keeps the window alive and redrawing.
$script:workRunspace = $null
$script:busy = 0
# what the busy strip under the pages names, and since when something runs
$script:busyWhat = ''
$script:busySince = $null
# the serials and states adb reported last, so a plugged or pulled phone is noticed
$script:deviceSignature = ''
$script:devicesReadOnce = $false

function Get-WorkRunspace {
    if ($null -eq $script:workRunspace -or $script:workRunspace.RunspaceStateInfo.State -ne 'Opened') {
        $script:workRunspace = [runspacefactory]::CreateRunspace()
        $script:workRunspace.ApartmentState = 'MTA'
        $script:workRunspace.ThreadOptions = 'ReuseThread'
        $script:workRunspace.Open()
    }
    return $script:workRunspace
}

function Wait-Pumped {
    param([int]$Milliseconds)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}

function Get-BusyText {
    # what the busy strip says: the program and its arguments, without "-s
    # serial", and a command sent over base64 shown as the command it is
    param([string]$FilePath, [string[]]$ArgumentList)

    $words = @($ArgumentList)
    if ($words.Count -gt 2 -and $words[0] -eq '-s') { $words = $words[2..($words.Count - 1)] }
    $text = $words -join ' '
    if ($text -match '^shell echo (\S+) \| base64 -d \| sh$') {
        try { $text = 'shell ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) } catch { }
    }
    $text = ([IO.Path]::GetFileNameWithoutExtension($FilePath) + ' ' + $text).Trim()
    if ($text.Length -gt 90) { $text = $text.Substring(0, 87) + '...' }
    return $text
}

function Invoke-OffThread {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutMs = 180000
    )

    $shell = [powershell]::Create()
    $shell.Runspace = Get-WorkRunspace
    $null = $shell.AddScript({
        param($exe, $arguments)
        $ErrorActionPreference = 'Continue'
        # adb, scrcpy and gnirehtet all write UTF-8, and they are the only
        # programs that come through here. PowerShell decodes a native program
        # with the console code page instead, so on a PC still on an OEM page
        # (437, 720, ...) every Arabic app or contact name arrives garbled.
        # Decode as UTF-8 for the call, and put the page back afterwards. A
        # window with no console at all cannot change it, and runs as before.
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
            [System.Windows.Forms.Application]::DoEvents()
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
    param([string]$Serial, [string[]]$CommandArguments)

    return Invoke-Adb -CommandArguments (@('-s', $Serial, 'shell') + $CommandArguments)
}

function Invoke-DeviceShellText {
    param([string]$Serial, [string]$Command)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    return Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', "echo $encoded | base64 -d | sh")
}

function Test-TextContains {
    # what the filter boxes mean: the typed text somewhere in the value, any
    # case. -like "*$filter*" read [ ] ? * as a pattern, so "IMG [1]" found
    # "IMG 1" but not "IMG [1].jpg", and a lone "[" was an invalid pattern.
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
        given. Measured on a phone: "adb shell printf [%s] a 'b c'" printed
        [a][b][c] - adb joins its arguments with spaces and the phone's shell
        splits them again, so an SMS body kept only its first word. Quoting
        for that shell is not enough on its own either: Windows PowerShell
        drops a double quote inside an argument to a native program ('say
        "hi"' arrived as 'say hi'). So each argument is quoted for sh, and the
        whole line goes over base64, which has no character either side reads.
    #>
    param([string]$Serial, [string[]]$Arguments)

    $command = (@($Arguments) | ForEach-Object { Quote-DeviceArgument $_ }) -join ' '
    return Invoke-DeviceShellText -Serial $Serial -Command $command
}

function Invoke-Gnirehtet {
    param([string[]]$CommandArguments)

    $result = Invoke-OffThread -FilePath $script:gnirehtetPath -ArgumentList $CommandArguments
    return [PSCustomObject]@{
        ExitCode = $result.ExitCode
        Lines    = $result.Lines
        Text     = ($result.Lines -join "`n")
    }
}

function Get-PortOwner {
    param([int]$Port)

    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if (-not $connection) { return $null }

        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            ProcessId   = $connection.OwningProcess
            ProcessName = if ($process) { $process.ProcessName } else { 'unknown' }
        }
    } catch {
        # Get-NetTCPConnection is missing: fall back to a plain listener probe (no PID).
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if (@($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0) {
            return [PSCustomObject]@{ ProcessId = 0; ProcessName = 'unknown' }
        }
        return $null
    }
}

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

# -------------------------------------------------------------------- UI ----

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AndroidDC - Android Device Control'
$iconPath = Join-Path $scriptRoot (Join-Path 'assets' 'androiddc.ico')
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    try { $form.Icon = New-Object System.Drawing.Icon $iconPath } catch { }
}
$form.Size = New-Object System.Drawing.Size(1420, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 700)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$toolTip = New-Object System.Windows.Forms.ToolTip

# The phone picture lives in its own full-height pane on the left; every other
# control sits on the right, so the screenshot gets the whole window height.
$splitMain = New-Object System.Windows.Forms.SplitContainer
# a real size must come first: the min sizes are validated against the current
# width, and a freshly created SplitContainer is only 150 px wide
$splitMain.Size = New-Object System.Drawing.Size(1400, 860)
$splitMain.SplitterWidth = 6
$splitMain.SplitterDistance = 440
$splitMain.Panel1MinSize = 280
$splitMain.Panel2MinSize = 700
$splitMain.Dock = 'Fill'
$form.Controls.Add($splitMain)

# everything about the phone picture lives in one frame, so it can be folded
# away with a single button
$grpScreen = New-Object System.Windows.Forms.GroupBox
$grpScreen.Text = 'Phone screen'
$grpScreen.Dock = 'Fill'
$splitMain.Panel1.Controls.Add($grpScreen)

function New-RowSeparator {
    param($Parent)

    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = [System.Drawing.Color]::FromArgb(198, 202, 206)
    $line.Size = New-Object System.Drawing.Size(1, 22)
    $Parent.Controls.Add($line)
    return $line
}

# --- devices -----------------------------------------------------------------
$grpDevices = New-Object System.Windows.Forms.GroupBox
$grpDevices.Text = 'Devices  (Ctrl+click or Shift+click to pick several)'
$grpDevices.Location = New-Object System.Drawing.Point(12, 10)
$grpDevices.Size = New-Object System.Drawing.Size(890, 182)
$grpDevices.Anchor = 'Top, Left, Right'
$splitMain.Panel2.Controls.Add($grpDevices)

$lstDevices = New-Object System.Windows.Forms.ListView
$lstDevices.View = 'Details'
$lstDevices.FullRowSelect = $true
$lstDevices.MultiSelect = $true
$lstDevices.HideSelection = $false
$lstDevices.Location = New-Object System.Drawing.Point(12, 22)
$lstDevices.Size = New-Object System.Drawing.Size(750, 115)
$lstDevices.Anchor = 'Top, Left, Right'
$null = $lstDevices.Columns.Add('Serial', 210)
$null = $lstDevices.Columns.Add('Link', 55)
$null = $lstDevices.Columns.Add('Model', 150)
$null = $lstDevices.Columns.Add('Android', 70)
$null = $lstDevices.Columns.Add('State', 85)
# not "Client": the word said nothing. The column is about one app
$null = $lstDevices.Columns.Add('gnirehtet', 70)
$grpDevices.Controls.Add($lstDevices)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(772, 22)
$btnRefresh.Size = New-Object System.Drawing.Size(106, 28)
$btnRefresh.Anchor = 'Top, Right'
$grpDevices.Controls.Add($btnRefresh)

$btnInfo = New-Object System.Windows.Forms.Button
$btnInfo.Text = 'Device info'
$btnInfo.Location = New-Object System.Drawing.Point(772, 56)
$btnInfo.Size = New-Object System.Drawing.Size(106, 28)
$btnInfo.Anchor = 'Top, Right'
$grpDevices.Controls.Add($btnInfo)

$chkAll = New-Object System.Windows.Forms.CheckBox
$chkAll.Text = 'All devices'
$chkAll.Location = New-Object System.Drawing.Point(774, 92)
$chkAll.Size = New-Object System.Drawing.Size(104, 24)
$chkAll.Anchor = 'Top, Right'
$grpDevices.Controls.Add($chkAll)
$toolTip.SetToolTip($chkAll, 'Reverse tether every connected device (gnirehtet autorun)')

$lblDeviceStatus = New-Object System.Windows.Forms.Label
$lblDeviceStatus.Text = 'select a device to read its battery and signal'
$lblDeviceStatus.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblDeviceStatus.Location = New-Object System.Drawing.Point(14, 144)
# one line: wrapped, it broke an item in two at the smallest window. What does
# not fit ends in "...", and the tooltip holds the whole line.
$lblDeviceStatus.Size = New-Object System.Drawing.Size(750, 20)
$lblDeviceStatus.AutoEllipsis = $true
$lblDeviceStatus.Anchor = 'Top, Left, Right'
$grpDevices.Controls.Add($lblDeviceStatus)

# --- tabs --------------------------------------------------------------------
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 200)
$tabs.Size = New-Object System.Drawing.Size(890, 434)
$tabs.Anchor = 'Top, Bottom, Left, Right'
$splitMain.Panel2.Controls.Add($tabs)

$tabDevice = New-Object System.Windows.Forms.TabPage
$tabDevice.Text = 'Device'
$tabDevice.BackColor = [System.Drawing.SystemColors]::Control
# at the smallest window a page is about 250 px tall; the pages whose content
# is taller scroll instead of cutting their lower groups off
$tabDevice.AutoScroll = $true
$tabs.TabPages.Add($tabDevice)

# Sharing the connection is one subject with two directions, so both live
# under one tab; same for the two pages of advanced options.
$tabTethering = New-Object System.Windows.Forms.TabPage
$tabTethering.Text = 'Tethering'
$tabTethering.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabTethering)

$tabsTethering = New-Object System.Windows.Forms.TabControl
$tabsTethering.Dock = 'Fill'
$tabTethering.Controls.Add($tabsTethering)

$tabShare = New-Object System.Windows.Forms.TabPage
$tabShare.Text = 'PC -> Phone'
$tabShare.BackColor = [System.Drawing.SystemColors]::Control
$tabShare.AutoScroll = $true
$tabsTethering.TabPages.Add($tabShare)

$tabTether = New-Object System.Windows.Forms.TabPage
$tabTether.Text = 'Phone -> PC'
$tabTether.BackColor = [System.Drawing.SystemColors]::Control
$tabTether.AutoScroll = $true
$tabsTethering.TabPages.Add($tabTether)

$tabAdvanced = New-Object System.Windows.Forms.TabPage
$tabAdvanced.Text = 'Advanced'
$tabAdvanced.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabAdvanced)

$tabsAdvanced = New-Object System.Windows.Forms.TabControl
$tabsAdvanced.Dock = 'Fill'
$tabAdvanced.Controls.Add($tabsAdvanced)

$tabScrcpy = New-Object System.Windows.Forms.TabPage
$tabScrcpy.Text = 'Mirroring'
$tabScrcpy.BackColor = [System.Drawing.SystemColors]::Control
$tabScrcpy.AutoScroll = $true
$tabsAdvanced.TabPages.Add($tabScrcpy)

$tabMore = New-Object System.Windows.Forms.TabPage
$tabMore.Text = 'More options'
$tabMore.BackColor = [System.Drawing.SystemColors]::Control
$tabMore.AutoScroll = $true
$tabsAdvanced.TabPages.Add($tabMore)

$tabRoot = New-Object System.Windows.Forms.TabPage
$tabRoot.Text = 'Root / recovery'
$tabRoot.BackColor = [System.Drawing.SystemColors]::Control
$tabRoot.AutoScroll = $true

$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = 'Device tools'
$tabTools.BackColor = [System.Drawing.SystemColors]::Control
$tabTools.AutoScroll = $true
$tabsAdvanced.TabPages.Add($tabTools)
$tabsAdvanced.TabPages.Add($tabRoot)

$tabAutomation = New-Object System.Windows.Forms.TabPage
$tabAutomation.Text = 'Automation'
$tabAutomation.BackColor = [System.Drawing.SystemColors]::Control
$tabsAdvanced.TabPages.Add($tabAutomation)

$tabBackup = New-Object System.Windows.Forms.TabPage
$tabBackup.Text = 'Backup'
$tabBackup.BackColor = [System.Drawing.SystemColors]::Control
$tabsAdvanced.TabPages.Add($tabBackup)

$tabApps = New-Object System.Windows.Forms.TabPage
$tabApps.Text = 'Apps'
$tabApps.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabApps)

$tabContacts = New-Object System.Windows.Forms.TabPage
$tabContacts.Text = 'Contacts'
$tabContacts.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabContacts)

$tabSms = New-Object System.Windows.Forms.TabPage
$tabSms.Text = 'SMS'
$tabSms.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabSms)

$tabCamera = New-Object System.Windows.Forms.TabPage
$tabCamera.Text = 'Cam / Mic'
$tabCamera.BackColor = [System.Drawing.SystemColors]::Control
# at the smallest window the page is about 250 px tall and the audio group ends
# near 380, so it scrolls rather than cutting the audio controls off
$tabCamera.AutoScroll = $true
$tabs.TabPages.Add($tabCamera)

$tabFiles = New-Object System.Windows.Forms.TabPage
$tabFiles.Text = 'Files'
$tabFiles.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabFiles)

$tabRunning = New-Object System.Windows.Forms.TabPage
$tabRunning.Text = 'Running'
$tabRunning.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabRunning)

# Wi-Fi, Bluetooth and NFC are one subject, the phone's radios. As three tabs
# of their own they pushed Users and Shell off the strip at the smallest window.
$tabRadios = New-Object System.Windows.Forms.TabPage
$tabRadios.Text = 'Radios'
$tabRadios.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabRadios)

$tabsRadios = New-Object System.Windows.Forms.TabControl
$tabsRadios.Dock = 'Fill'
$tabRadios.Controls.Add($tabsRadios)

$tabWifi = New-Object System.Windows.Forms.TabPage
$tabWifi.Text = 'Wi-Fi'
$tabWifi.BackColor = [System.Drawing.SystemColors]::Control
$tabsRadios.TabPages.Add($tabWifi)

$tabBt = New-Object System.Windows.Forms.TabPage
$tabBt.Text = 'Bluetooth'
$tabBt.BackColor = [System.Drawing.SystemColors]::Control
$tabsRadios.TabPages.Add($tabBt)

$tabNfc = New-Object System.Windows.Forms.TabPage
$tabNfc.Text = 'NFC'
$tabNfc.BackColor = [System.Drawing.SystemColors]::Control
$tabsRadios.TabPages.Add($tabNfc)

$tabUsers = New-Object System.Windows.Forms.TabPage
$tabUsers.Text = 'Users'
$tabUsers.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabUsers)

$tabShellHost = New-Object System.Windows.Forms.TabPage
$tabShellHost.Text = 'Shell'
$tabShellHost.BackColor = [System.Drawing.SystemColors]::Control
$tabs.TabPages.Add($tabShellHost)

# --- tab 0: device details ---------------------------------------------------
$btnDeviceRefresh = New-Object System.Windows.Forms.Button
$btnDeviceRefresh.Text = 'Load details + screenshot'
$btnDeviceRefresh.Location = New-Object System.Drawing.Point(14, 10)
$btnDeviceRefresh.Size = New-Object System.Drawing.Size(190, 28)
$tabDevice.Controls.Add($btnDeviceRefresh)

$btnDeviceCopy = New-Object System.Windows.Forms.Button
$btnDeviceCopy.Text = 'Copy'
$btnDeviceCopy.Location = New-Object System.Drawing.Point(212, 10)
$btnDeviceCopy.Size = New-Object System.Drawing.Size(80, 28)
$tabDevice.Controls.Add($btnDeviceCopy)

$lblDeviceHint = New-Object System.Windows.Forms.Label
$lblDeviceHint.Text = 'Double-click a device in the list above to load its details here and grab its screen.'
$lblDeviceHint.ForeColor = [System.Drawing.Color]::DimGray
$lblDeviceHint.Location = New-Object System.Drawing.Point(302, 16)
$lblDeviceHint.Size = New-Object System.Drawing.Size(520, 20)
$tabDevice.Controls.Add($lblDeviceHint)

$btnDeviceScrcpy = New-Object System.Windows.Forms.Button
$btnDeviceScrcpy.Text = 'Mirror with scrcpy'
$btnDeviceScrcpy.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnDeviceScrcpy.Location = New-Object System.Drawing.Point(300, 10)
$btnDeviceScrcpy.Size = New-Object System.Drawing.Size(150, 28)
$tabDevice.Controls.Add($btnDeviceScrcpy)
$toolTip.SetToolTip($btnDeviceScrcpy, 'Start scrcpy right away, using whatever is set on the Advanced tab')

# the same tool in the new window (nova\); this one closes the normal way
$btnOpenNova = New-Object System.Windows.Forms.Button
$btnOpenNova.Text = 'Open Nova window'
$btnOpenNova.Location = New-Object System.Drawing.Point(458, 10)
$btnOpenNova.Size = New-Object System.Drawing.Size(140, 28)
$tabDevice.Controls.Add($btnOpenNova)
$toolTip.SetToolTip($btnOpenNova, 'Close this window and open AndroidDC Nova: the same tool in the new design')

$grpToggles = New-Object System.Windows.Forms.GroupBox
$grpToggles.Text = 'Quick toggles  (applied to every selected device)'
$grpToggles.Location = New-Object System.Drawing.Point(480, 46)
$grpToggles.Size = New-Object System.Drawing.Size(440, 214)
$tabDevice.Controls.Add($grpToggles)

$grpDial = New-Object System.Windows.Forms.GroupBox
$grpDial.Text = 'Phone number'
$grpDial.Location = New-Object System.Drawing.Point(480, 268)
$grpDial.Size = New-Object System.Drawing.Size(440, 84)
$tabDevice.Controls.Add($grpDial)

$lblPhoneNumber = New-Object System.Windows.Forms.Label
$lblPhoneNumber.Text = 'Number'
$lblPhoneNumber.Location = New-Object System.Drawing.Point(12, 28)
$lblPhoneNumber.Size = New-Object System.Drawing.Size(56, 20)
$grpDial.Controls.Add($lblPhoneNumber)

$txtPhoneNumber = New-Object System.Windows.Forms.TextBox
$txtPhoneNumber.Location = New-Object System.Drawing.Point(72, 25)
$txtPhoneNumber.Size = New-Object System.Drawing.Size(150, 24)
$grpDial.Controls.Add($txtPhoneNumber)
$toolTip.SetToolTip($txtPhoneNumber, 'A phone number to call or text, or a USSD code such as *111#')

$btnPhoneCall = New-Object System.Windows.Forms.Button
$btnPhoneCall.Text = 'Call'
$btnPhoneCall.Location = New-Object System.Drawing.Point(230, 24)
$btnPhoneCall.Size = New-Object System.Drawing.Size(66, 26)
$grpDial.Controls.Add($btnPhoneCall)

$btnPhoneEnd = New-Object System.Windows.Forms.Button
$btnPhoneEnd.Text = 'Hang up'
$btnPhoneEnd.Location = New-Object System.Drawing.Point(304, 24)
$btnPhoneEnd.Size = New-Object System.Drawing.Size(76, 26)
$grpDial.Controls.Add($btnPhoneEnd)

$btnPhoneSms = New-Object System.Windows.Forms.Button
$btnPhoneSms.Text = 'Send SMS...'
$btnPhoneSms.Location = New-Object System.Drawing.Point(72, 54)
$btnPhoneSms.Size = New-Object System.Drawing.Size(110, 26)
$grpDial.Controls.Add($btnPhoneSms)

$btnPhoneUssd = New-Object System.Windows.Forms.Button
$btnPhoneUssd.Text = 'Send USSD'
$btnPhoneUssd.Location = New-Object System.Drawing.Point(190, 54)
$btnPhoneUssd.Size = New-Object System.Drawing.Size(106, 26)
$grpDial.Controls.Add($btnPhoneUssd)
$toolTip.SetToolTip($btnPhoneUssd, 'Dial a code like *111# - the operator answer appears on the phone screen')

$btnPhoneDialer = New-Object System.Windows.Forms.Button
$btnPhoneDialer.Text = 'Open dialer'
$btnPhoneDialer.Location = New-Object System.Drawing.Point(304, 54)
$btnPhoneDialer.Size = New-Object System.Drawing.Size(106, 26)
$grpDial.Controls.Add($btnPhoneDialer)
$toolTip.SetToolTip($btnPhoneDialer, 'Put the number in the phone dialer without calling it')

$txtDeviceInfo = New-Object System.Windows.Forms.RichTextBox
$txtDeviceInfo.ReadOnly = $true
$txtDeviceInfo.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtDeviceInfo.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtDeviceInfo.Location = New-Object System.Drawing.Point(14, 46)
$txtDeviceInfo.Size = New-Object System.Drawing.Size(820, 240)
# a big empty box says nothing about what fills it
$txtDeviceInfo.Text = 'Press "Load details + screenshot", or double-click the phone in the list above.'
$txtDeviceInfo.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$tabDevice.Controls.Add($txtDeviceInfo)

# --- tab 1: gnirehtet --------------------------------------------------------
# Named apart from $lblDns on the Device tools page. Both were once called
# $lblDns: from the second New-Object on, the name meant the tools label only,
# so this one was never placed by Update-TetherLayout and sat 6 px above the
# Port and Routes labels on its row.
$lblTunnelDns = New-Object System.Windows.Forms.Label
$lblTunnelDns.Text = 'DNS'
$lblTunnelDns.Location = New-Object System.Drawing.Point(16, 22)
$lblTunnelDns.Size = New-Object System.Drawing.Size(34, 20)
$tabShare.Controls.Add($lblTunnelDns)

$cmbDns = New-Object System.Windows.Forms.ComboBox
$cmbDns.DropDownStyle = 'DropDown'
$cmbDns.Location = New-Object System.Drawing.Point(52, 19)
$cmbDns.Size = New-Object System.Drawing.Size(150, 24)
$null = $cmbDns.Items.AddRange(@('8.8.8.8', '8.8.8.8,8.8.4.4', '1.1.1.1', '9.9.9.9', '208.67.222.222'))
$cmbDns.Text = '8.8.8.8'
$tabShare.Controls.Add($cmbDns)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = 'Port'
$lblPort.Location = New-Object System.Drawing.Point(218, 22)
$lblPort.Size = New-Object System.Drawing.Size(32, 20)
$tabShare.Controls.Add($lblPort)

$numPort = New-Object System.Windows.Forms.NumericUpDown
$numPort.Minimum = 1024
$numPort.Maximum = 65535
$numPort.Value = 31416
$numPort.Location = New-Object System.Drawing.Point(252, 19)
$numPort.Size = New-Object System.Drawing.Size(80, 24)
$tabShare.Controls.Add($numPort)

$lblRoutes = New-Object System.Windows.Forms.Label
$lblRoutes.Text = 'Routes'
$lblRoutes.Location = New-Object System.Drawing.Point(348, 22)
$lblRoutes.Size = New-Object System.Drawing.Size(48, 20)
$tabShare.Controls.Add($lblRoutes)

$txtRoutes = New-Object System.Windows.Forms.TextBox
$txtRoutes.Location = New-Object System.Drawing.Point(398, 19)
$txtRoutes.Size = New-Object System.Drawing.Size(240, 24)
$tabShare.Controls.Add($txtRoutes)
$toolTip.SetToolTip($txtRoutes, 'Optional, comma separated (e.g. 192.168.0.0/24). Empty = all traffic')

$chkWifi = New-Object System.Windows.Forms.CheckBox
$chkWifi.Text = 'Turn Wi-Fi off while sharing'
$chkWifi.Location = New-Object System.Drawing.Point(18, 56)
$chkWifi.Size = New-Object System.Drawing.Size(200, 24)
$tabShare.Controls.Add($chkWifi)

$chkReinstall = New-Object System.Windows.Forms.CheckBox
$chkReinstall.Text = 'Reinstall client APK'
$chkReinstall.Location = New-Object System.Drawing.Point(226, 56)
$chkReinstall.Size = New-Object System.Drawing.Size(160, 24)
$tabShare.Controls.Add($chkReinstall)

$chkAutoTest = New-Object System.Windows.Forms.CheckBox
$chkAutoTest.Text = 'Check internet after start'
$chkAutoTest.Checked = $true
$chkAutoTest.Location = New-Object System.Drawing.Point(396, 56)
$chkAutoTest.Size = New-Object System.Drawing.Size(160, 24)
$tabShare.Controls.Add($chkAutoTest)

$chkScrcpyAfter = New-Object System.Windows.Forms.CheckBox
$chkScrcpyAfter.Text = 'Open scrcpy after start'
$chkScrcpyAfter.Location = New-Object System.Drawing.Point(566, 56)
$chkScrcpyAfter.Size = New-Object System.Drawing.Size(180, 24)
$tabShare.Controls.Add($chkScrcpyAfter)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Start sharing'
$btnStart.Location = New-Object System.Drawing.Point(18, 94)
$btnStart.Size = New-Object System.Drawing.Size(140, 34)
$tabShare.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'
$btnStop.Enabled = $false
$btnStop.Location = New-Object System.Drawing.Point(166, 94)
$btnStop.Size = New-Object System.Drawing.Size(100, 34)
$tabShare.Controls.Add($btnStop)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test connection'
$btnTest.Location = New-Object System.Drawing.Point(274, 94)
$btnTest.Size = New-Object System.Drawing.Size(130, 34)
$tabShare.Controls.Add($btnTest)

$btnShareRestart = New-Object System.Windows.Forms.Button
$btnShareRestart.Text = 'Restart'
$btnShareRestart.Location = New-Object System.Drawing.Point(12, 200)
$btnShareRestart.Size = New-Object System.Drawing.Size(100, 28)
$tabShare.Controls.Add($btnShareRestart)
$toolTip.SetToolTip($btnShareRestart, 'gnirehtet restart: stop and start again without touching the client')

$chkShareAutostart = New-Object System.Windows.Forms.CheckBox
$chkShareAutostart.Text = 'keep serving devices as they are plugged in'
$chkShareAutostart.Location = New-Object System.Drawing.Point(120, 202)
$chkShareAutostart.Size = New-Object System.Drawing.Size(320, 22)
$tabShare.Controls.Add($chkShareAutostart)
$toolTip.SetToolTip($chkShareAutostart, 'gnirehtet autostart instead of start: every device that appears is served')

$btnInstallClient = New-Object System.Windows.Forms.Button
$btnInstallClient.Text = 'Install client'
$btnInstallClient.Location = New-Object System.Drawing.Point(412, 94)
$btnInstallClient.Size = New-Object System.Drawing.Size(120, 34)
$tabShare.Controls.Add($btnInstallClient)

$btnUninstallClient = New-Object System.Windows.Forms.Button
$btnUninstallClient.Text = 'Uninstall client'
$btnUninstallClient.Location = New-Object System.Drawing.Point(540, 94)
$btnUninstallClient.Size = New-Object System.Drawing.Size(120, 34)
$tabShare.Controls.Add($btnUninstallClient)

$lblShareHint = New-Object System.Windows.Forms.Label
$lblShareHint.Text = 'The phone routes its TCP/UDP traffic through the PC (no root needed). ICMP is not relayed, so ping fails even when it works.'
$lblShareHint.ForeColor = [System.Drawing.Color]::DimGray
$lblShareHint.Location = New-Object System.Drawing.Point(18, 140)
$lblShareHint.Size = New-Object System.Drawing.Size(850, 20)
$tabShare.Controls.Add($lblShareHint)

# --- tab 2: USB tethering ----------------------------------------------------
$lblTetherHint = New-Object System.Windows.Forms.Label
$lblTetherHint.Text = 'Opposite direction: the phone shares its mobile data with the PC over USB (RNDIS).'
$lblTetherHint.Location = New-Object System.Drawing.Point(18, 18)
$lblTetherHint.Size = New-Object System.Drawing.Size(840, 20)
$tabTether.Controls.Add($lblTetherHint)

$lblTetherHint2 = New-Object System.Windows.Forms.Label
$lblTetherHint2.Text = "'Enable' uses svc usb setFunctions rndis; many phones block it without root, so use 'Open settings on phone' and tap USB tethering."
$lblTetherHint2.ForeColor = [System.Drawing.Color]::DimGray
$lblTetherHint2.Location = New-Object System.Drawing.Point(18, 40)
$lblTetherHint2.Size = New-Object System.Drawing.Size(840, 20)
$tabTether.Controls.Add($lblTetherHint2)

$btnTetherOn = New-Object System.Windows.Forms.Button
$btnTetherOn.Text = 'Enable USB tethering'
$btnTetherOn.Location = New-Object System.Drawing.Point(18, 74)
$btnTetherOn.Size = New-Object System.Drawing.Size(180, 34)
$tabTether.Controls.Add($btnTetherOn)

$btnTetherOff = New-Object System.Windows.Forms.Button
$btnTetherOff.Text = 'Disable'
$btnTetherOff.Location = New-Object System.Drawing.Point(206, 74)
$btnTetherOff.Size = New-Object System.Drawing.Size(110, 34)
$tabTether.Controls.Add($btnTetherOff)

$btnTetherSettings = New-Object System.Windows.Forms.Button
$btnTetherSettings.Text = 'Open settings on phone'
$btnTetherSettings.Location = New-Object System.Drawing.Point(324, 74)
$btnTetherSettings.Size = New-Object System.Drawing.Size(180, 34)
$tabTether.Controls.Add($btnTetherSettings)

$btnAdapters = New-Object System.Windows.Forms.Button
$btnAdapters.Text = 'Check PC adapters'
$btnAdapters.Location = New-Object System.Drawing.Point(512, 74)
$btnAdapters.Size = New-Object System.Drawing.Size(150, 34)
$tabTether.Controls.Add($btnAdapters)

$chkTetherMetered = New-Object System.Windows.Forms.CheckBox
$chkTetherMetered.Text = 'After enabling, open Windows network settings to set the link as metered'
$chkTetherMetered.Location = New-Object System.Drawing.Point(20, 120)
$chkTetherMetered.Size = New-Object System.Drawing.Size(500, 24)
$tabTether.Controls.Add($chkTetherMetered)

$lblTetherStatus = New-Object System.Windows.Forms.Label
$lblTetherStatus.Text = 'PC side: not checked yet.'
$lblTetherStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblTetherStatus.Location = New-Object System.Drawing.Point(18, 150)
$lblTetherStatus.Size = New-Object System.Drawing.Size(840, 20)
$tabTether.Controls.Add($lblTetherStatus)

$lblProxyTitle = New-Object System.Windows.Forms.Label
$lblProxyTitle.Text = 'Proxy over ADB - use the phone data on the PC when USB tethering is blocked:'
$lblProxyTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblProxyTitle.Location = New-Object System.Drawing.Point(18, 178)
$lblProxyTitle.Size = New-Object System.Drawing.Size(600, 20)
$tabTether.Controls.Add($lblProxyTitle)

$lblProxyPort = New-Object System.Windows.Forms.Label
$lblProxyPort.Text = 'Proxy port'
$lblProxyPort.Location = New-Object System.Drawing.Point(18, 210)
$lblProxyPort.Size = New-Object System.Drawing.Size(66, 20)
$tabTether.Controls.Add($lblProxyPort)

$numProxyPort = New-Object System.Windows.Forms.NumericUpDown
$numProxyPort.Minimum = 1
$numProxyPort.Maximum = 65535
$numProxyPort.Value = 8080
$numProxyPort.Location = New-Object System.Drawing.Point(88, 207)
$numProxyPort.Size = New-Object System.Drawing.Size(80, 24)
$tabTether.Controls.Add($numProxyPort)

$btnProxyOn = New-Object System.Windows.Forms.Button
$btnProxyOn.Text = 'Use phone proxy'
$btnProxyOn.Location = New-Object System.Drawing.Point(180, 204)
$btnProxyOn.Size = New-Object System.Drawing.Size(150, 30)
$tabTether.Controls.Add($btnProxyOn)
$toolTip.SetToolTip($btnProxyOn, 'adb forward + set the Windows proxy to 127.0.0.1:<port>')

$btnProxyOff = New-Object System.Windows.Forms.Button
$btnProxyOff.Text = 'Stop proxy'
$btnProxyOff.Enabled = $false
$btnProxyOff.Location = New-Object System.Drawing.Point(338, 204)
$btnProxyOff.Size = New-Object System.Drawing.Size(120, 30)
$tabTether.Controls.Add($btnProxyOff)

$btnProxyTest = New-Object System.Windows.Forms.Button
$btnProxyTest.Text = 'Test proxy'
$btnProxyTest.Location = New-Object System.Drawing.Point(466, 204)
$btnProxyTest.Size = New-Object System.Drawing.Size(120, 30)
$tabTether.Controls.Add($btnProxyTest)

$lblProxyHint = New-Object System.Windows.Forms.Label
$lblProxyHint.Text = 'Needs a proxy app running on the phone (Every Proxy, Drony, ...) listening on that port with HTTP proxy enabled.'
$lblProxyHint.ForeColor = [System.Drawing.Color]::DimGray
$lblProxyHint.Location = New-Object System.Drawing.Point(18, 240)
$lblProxyHint.Size = New-Object System.Drawing.Size(840, 20)
$tabTether.Controls.Add($lblProxyHint)


# Both tethering pages were flat rows. The settings you change now sit in one
# box and the buttons that act on them in another.
$grpTunnel = New-Object System.Windows.Forms.GroupBox
$grpTunnel.Text = 'Tunnel settings'
$tabShare.Controls.Add($grpTunnel)

foreach ($control in @($lblTunnelDns, $cmbDns, $lblPort, $numPort, $lblRoutes, $txtRoutes,
        $chkWifi, $chkReinstall, $chkAutoTest, $chkScrcpyAfter)) {
    $tabShare.Controls.Remove($control)
    $grpTunnel.Controls.Add($control)
}

$grpUsbTether = New-Object System.Windows.Forms.GroupBox
$grpUsbTether.Text = 'USB tethering  (the phone shares its data over the cable)'
$tabTether.Controls.Add($grpUsbTether)

foreach ($control in @($btnTetherOn, $btnTetherOff, $btnTetherSettings, $btnAdapters,
        $chkTetherMetered, $lblTetherStatus, $lblTetherHint, $lblTetherHint2)) {
    $tabTether.Controls.Remove($control)
    $grpUsbTether.Controls.Add($control)
}

$grpProxy = New-Object System.Windows.Forms.GroupBox
$grpProxy.Text = 'Proxy over ADB  (when the cable route is blocked)'
$tabTether.Controls.Add($grpProxy)

foreach ($control in @($lblProxyPort, $numProxyPort, $btnProxyOn, $btnProxyOff, $btnProxyTest,
        $lblProxyHint, $lblProxyTitle)) {
    $tabTether.Controls.Remove($control)
    $grpProxy.Controls.Add($control)
}

# --- tab 3: scrcpy -----------------------------------------------------------
$script:scrcpyLabels = @{}

function New-ScrcpyLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 60)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, ($Y + 3))
    $label.Size = New-Object System.Drawing.Size($Width, 20)
    $tabScrcpy.Controls.Add($label)
    # kept so the label can follow its control into a group box
    $script:scrcpyLabels[$Text] = $label
}

New-ScrcpyLabel -Text 'Max size' -X 16 -Y 18 -Width 58
$cmbMaxSize = New-Object System.Windows.Forms.ComboBox
$cmbMaxSize.DropDownStyle = 'DropDown'
$cmbMaxSize.Location = New-Object System.Drawing.Point(76, 18)
$cmbMaxSize.Size = New-Object System.Drawing.Size(80, 24)
$null = $cmbMaxSize.Items.AddRange(@('0', '800', '1024', '1280', '1600', '1920'))
$cmbMaxSize.Text = '1280'
$tabScrcpy.Controls.Add($cmbMaxSize)
$toolTip.SetToolTip($cmbMaxSize, '0 = native resolution')

New-ScrcpyLabel -Text 'Bit rate' -X 168 -Y 18 -Width 52
$cmbBitrate = New-Object System.Windows.Forms.ComboBox
$cmbBitrate.DropDownStyle = 'DropDown'
$cmbBitrate.Location = New-Object System.Drawing.Point(222, 18)
$cmbBitrate.Size = New-Object System.Drawing.Size(80, 24)
$null = $cmbBitrate.Items.AddRange(@('2M', '4M', '8M', '16M', '32M'))
$cmbBitrate.Text = '8M'
$tabScrcpy.Controls.Add($cmbBitrate)

New-ScrcpyLabel -Text 'Max FPS' -X 314 -Y 18 -Width 58
$cmbFps = New-Object System.Windows.Forms.ComboBox
$cmbFps.DropDownStyle = 'DropDown'
$cmbFps.Location = New-Object System.Drawing.Point(374, 18)
$cmbFps.Size = New-Object System.Drawing.Size(70, 24)
$null = $cmbFps.Items.AddRange(@('0', '30', '60', '90', '120'))
$cmbFps.Text = '60'
$tabScrcpy.Controls.Add($cmbFps)
$toolTip.SetToolTip($cmbFps, '0 = unlimited')

New-ScrcpyLabel -Text 'Codec' -X 456 -Y 18 -Width 44
$cmbCodec = New-Object System.Windows.Forms.ComboBox
$cmbCodec.DropDownStyle = 'DropDownList'
$cmbCodec.Location = New-Object System.Drawing.Point(502, 18)
$cmbCodec.Size = New-Object System.Drawing.Size(80, 24)
$null = $cmbCodec.Items.AddRange(@('default', 'h264', 'h265', 'av1'))
$cmbCodec.SelectedIndex = 0
$tabScrcpy.Controls.Add($cmbCodec)

New-ScrcpyLabel -Text 'Display' -X 594 -Y 18 -Width 50
$cmbDisplay = New-Object System.Windows.Forms.ComboBox
$cmbDisplay.DropDownStyle = 'DropDown'
$cmbDisplay.Location = New-Object System.Drawing.Point(646, 18)
$cmbDisplay.Size = New-Object System.Drawing.Size(70, 24)
$null = $cmbDisplay.Items.Add('0')
$cmbDisplay.Text = '0'
$tabScrcpy.Controls.Add($cmbDisplay)

$btnListDisplays = New-Object System.Windows.Forms.Button
$btnListDisplays.Text = 'List displays'
$btnListDisplays.Location = New-Object System.Drawing.Point(724, 17)
$btnListDisplays.Size = New-Object System.Drawing.Size(110, 26)
$tabScrcpy.Controls.Add($btnListDisplays)

$chkFullscreen = New-Object System.Windows.Forms.CheckBox
$chkFullscreen.Text = 'Fullscreen'
$chkFullscreen.Location = New-Object System.Drawing.Point(18, 54)
$chkFullscreen.Size = New-Object System.Drawing.Size(100, 24)
$tabScrcpy.Controls.Add($chkFullscreen)

$chkBorderless = New-Object System.Windows.Forms.CheckBox
$chkBorderless.Text = 'Borderless'
$chkBorderless.Location = New-Object System.Drawing.Point(126, 54)
$chkBorderless.Size = New-Object System.Drawing.Size(100, 24)
$tabScrcpy.Controls.Add($chkBorderless)

$chkOnTop = New-Object System.Windows.Forms.CheckBox
$chkOnTop.Text = 'Always on top'
$chkOnTop.Location = New-Object System.Drawing.Point(234, 54)
$chkOnTop.Size = New-Object System.Drawing.Size(120, 24)
$tabScrcpy.Controls.Add($chkOnTop)

$chkScreenOff = New-Object System.Windows.Forms.CheckBox
$chkScreenOff.Text = 'Turn screen off'
$chkScreenOff.Location = New-Object System.Drawing.Point(362, 54)
$chkScreenOff.Size = New-Object System.Drawing.Size(126, 24)
$tabScrcpy.Controls.Add($chkScreenOff)

$chkStayAwake = New-Object System.Windows.Forms.CheckBox
$chkStayAwake.Text = 'Stay awake'
$chkStayAwake.Checked = $true
$chkStayAwake.Location = New-Object System.Drawing.Point(496, 54)
$chkStayAwake.Size = New-Object System.Drawing.Size(110, 24)
$tabScrcpy.Controls.Add($chkStayAwake)

$chkNoAudio = New-Object System.Windows.Forms.CheckBox
$chkNoAudio.Text = 'No audio'
$chkNoAudio.Location = New-Object System.Drawing.Point(614, 54)
$chkNoAudio.Size = New-Object System.Drawing.Size(90, 24)
$tabScrcpy.Controls.Add($chkNoAudio)

$chkViewOnly = New-Object System.Windows.Forms.CheckBox
$chkViewOnly.Text = 'View only'
$chkViewOnly.Location = New-Object System.Drawing.Point(712, 54)
$chkViewOnly.Size = New-Object System.Drawing.Size(100, 24)
$tabScrcpy.Controls.Add($chkViewOnly)
$toolTip.SetToolTip($chkViewOnly, 'Mirror without controlling the device (--no-control)')

$chkPowerOff = New-Object System.Windows.Forms.CheckBox
$chkPowerOff.Text = 'Power off on close'
$chkPowerOff.Location = New-Object System.Drawing.Point(18, 84)
$chkPowerOff.Size = New-Object System.Drawing.Size(150, 24)
$tabScrcpy.Controls.Add($chkPowerOff)

$chkNoScreensaver = New-Object System.Windows.Forms.CheckBox
$chkNoScreensaver.Text = 'Disable screensaver'
$chkNoScreensaver.Location = New-Object System.Drawing.Point(176, 84)
$chkNoScreensaver.Size = New-Object System.Drawing.Size(160, 24)
$tabScrcpy.Controls.Add($chkNoScreensaver)

$chkNewDisplay = New-Object System.Windows.Forms.CheckBox
$chkNewDisplay.Text = 'Virtual display'
$chkNewDisplay.Location = New-Object System.Drawing.Point(344, 84)
$chkNewDisplay.Size = New-Object System.Drawing.Size(120, 24)
$tabScrcpy.Controls.Add($chkNewDisplay)
$toolTip.SetToolTip($chkNewDisplay, 'scrcpy --new-display, e.g. 1920x1080/240')

$txtNewDisplay = New-Object System.Windows.Forms.TextBox
$txtNewDisplay.Text = '1920x1080/240'
$txtNewDisplay.Location = New-Object System.Drawing.Point(468, 84)
$txtNewDisplay.Size = New-Object System.Drawing.Size(130, 24)
$tabScrcpy.Controls.Add($txtNewDisplay)

New-ScrcpyLabel -Text 'Start app' -X 610 -Y 84 -Width 62
$cmbStartApp = New-Object System.Windows.Forms.ComboBox
$cmbStartApp.DropDownStyle = 'DropDown'   # pick from the phone, or type as before
$cmbStartApp.Location = New-Object System.Drawing.Point(674, 84)
$cmbStartApp.Size = New-Object System.Drawing.Size(160, 24)
$cmbStartApp.DropDownWidth = 360
$tabScrcpy.Controls.Add($cmbStartApp)
$toolTip.SetToolTip($cmbStartApp, 'scrcpy --start-app. Open the list to pick an app by name - it is read from the phone - ' +
    'or type a package. A leading + force-stops the app first; a leading ? finds it by name')

$chkRecord = New-Object System.Windows.Forms.CheckBox
$chkRecord.Text = 'Record to'
$chkRecord.Location = New-Object System.Drawing.Point(18, 118)
$chkRecord.Size = New-Object System.Drawing.Size(90, 24)
$tabScrcpy.Controls.Add($chkRecord)

$txtRecord = New-Object System.Windows.Forms.TextBox
$txtRecord.Location = New-Object System.Drawing.Point(112, 118)
$txtRecord.Size = New-Object System.Drawing.Size(486, 24)
$tabScrcpy.Controls.Add($txtRecord)

$btnBrowseRecord = New-Object System.Windows.Forms.Button
$btnBrowseRecord.Text = 'Browse...'
$btnBrowseRecord.Location = New-Object System.Drawing.Point(606, 117)
$btnBrowseRecord.Size = New-Object System.Drawing.Size(90, 26)
$tabScrcpy.Controls.Add($btnBrowseRecord)

$lblExtraArgs = New-Object System.Windows.Forms.Label
$lblExtraArgs.Text = 'Extra args'
$lblExtraArgs.Location = New-Object System.Drawing.Point(18, 155)
$lblExtraArgs.Size = New-Object System.Drawing.Size(70, 20)
$tabScrcpy.Controls.Add($lblExtraArgs)

$txtExtraArgs = New-Object System.Windows.Forms.TextBox
$txtExtraArgs.Location = New-Object System.Drawing.Point(90, 152)
$txtExtraArgs.Size = New-Object System.Drawing.Size(508, 24)
$tabScrcpy.Controls.Add($txtExtraArgs)
$toolTip.SetToolTip($txtExtraArgs, 'Appended as-is, e.g. --crop=1080:1920:0:0 --window-title="Phone"')

$chkOtg = New-Object System.Windows.Forms.CheckBox
$chkOtg.Text = 'OTG mode'
$chkOtg.Location = New-Object System.Drawing.Point(18, 190)
$chkOtg.Size = New-Object System.Drawing.Size(96, 24)
$tabScrcpy.Controls.Add($chkOtg)
$toolTip.SetToolTip($chkOtg, 'Physical keyboard/mouse over USB (AOA HID). No mirroring, no USB debugging needed, USB only.')

New-ScrcpyLabel -Text 'Keyboard' -X 120 -Y 190 -Width 60
$cmbKeyboard = New-Object System.Windows.Forms.ComboBox
$cmbKeyboard.DropDownStyle = 'DropDownList'
$cmbKeyboard.Location = New-Object System.Drawing.Point(184, 190)
$cmbKeyboard.Size = New-Object System.Drawing.Size(94, 24)
$null = $cmbKeyboard.Items.AddRange(@('default', 'sdk', 'uhid', 'aoa', 'disabled'))
$cmbKeyboard.SelectedIndex = 0
$tabScrcpy.Controls.Add($cmbKeyboard)

New-ScrcpyLabel -Text 'Mouse' -X 290 -Y 190 -Width 44
$cmbMouse = New-Object System.Windows.Forms.ComboBox
$cmbMouse.DropDownStyle = 'DropDownList'
$cmbMouse.Location = New-Object System.Drawing.Point(336, 190)
$cmbMouse.Size = New-Object System.Drawing.Size(94, 24)
$null = $cmbMouse.Items.AddRange(@('default', 'sdk', 'uhid', 'aoa', 'disabled'))
$cmbMouse.SelectedIndex = 0
$tabScrcpy.Controls.Add($cmbMouse)

New-ScrcpyLabel -Text 'Gamepad' -X 442 -Y 190 -Width 58
$cmbGamepad = New-Object System.Windows.Forms.ComboBox
$cmbGamepad.DropDownStyle = 'DropDownList'
$cmbGamepad.Location = New-Object System.Drawing.Point(504, 190)
$cmbGamepad.Size = New-Object System.Drawing.Size(94, 24)
$null = $cmbGamepad.Items.AddRange(@('default', 'uhid', 'aoa', 'disabled'))
$cmbGamepad.SelectedIndex = 0
$tabScrcpy.Controls.Add($cmbGamepad)

$btnKeyboardLayout = New-Object System.Windows.Forms.Button
$btnKeyboardLayout.Text = 'Keyboard layout...'
$btnKeyboardLayout.Location = New-Object System.Drawing.Point(610, 189)
$btnKeyboardLayout.Size = New-Object System.Drawing.Size(140, 26)
$tabScrcpy.Controls.Add($btnKeyboardLayout)
$toolTip.SetToolTip($btnKeyboardLayout, 'Open the physical-keyboard layout settings on the device (needed once for uhid/aoa)')

$grpAudio = New-Object System.Windows.Forms.GroupBox
$grpAudio.Text = 'Microphone / audio  (phone -> PC)'
$grpAudio.Location = New-Object System.Drawing.Point(18, 200)
$grpAudio.Size = New-Object System.Drawing.Size(820, 128)
$tabCamera.Controls.Add($grpAudio)

$lblAudioSource = New-Object System.Windows.Forms.Label
$lblAudioSource.Text = 'Source'
$lblAudioSource.Location = New-Object System.Drawing.Point(14, 30)
$lblAudioSource.Size = New-Object System.Drawing.Size(50, 20)
$grpAudio.Controls.Add($lblAudioSource)

$cmbAudioSource = New-Object System.Windows.Forms.ComboBox
$cmbAudioSource.DropDownStyle = 'DropDownList'
$cmbAudioSource.Location = New-Object System.Drawing.Point(68, 26)
$cmbAudioSource.Size = New-Object System.Drawing.Size(200, 24)
$null = $cmbAudioSource.Items.AddRange(@(
    'mic', 'mic-voice-communication', 'mic-unprocessed', 'mic-voice-recognition',
    'output', 'playback', 'voice-call', 'voice-call-uplink', 'voice-call-downlink'))
$cmbAudioSource.SelectedIndex = 0
$grpAudio.Controls.Add($cmbAudioSource)

$btnListen = New-Object System.Windows.Forms.Button
$btnListen.Text = 'Listen'
$btnListen.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnListen.Location = New-Object System.Drawing.Point(278, 25)
$btnListen.Size = New-Object System.Drawing.Size(96, 26)
$grpAudio.Controls.Add($btnListen)
$toolTip.SetToolTip($btnListen, 'Stream that audio source from the phone to the PC speakers (no video)')


$lblAudioCodec = New-Object System.Windows.Forms.Label
$lblAudioCodec.Text = 'Codec'
$lblAudioCodec.Location = New-Object System.Drawing.Point(14, 62)
$lblAudioCodec.Size = New-Object System.Drawing.Size(48, 20)
$grpAudio.Controls.Add($lblAudioCodec)

$cmbAudioCodec = New-Object System.Windows.Forms.ComboBox
$cmbAudioCodec.DropDownStyle = 'DropDownList'
$cmbAudioCodec.Location = New-Object System.Drawing.Point(68, 58)
$cmbAudioCodec.Size = New-Object System.Drawing.Size(120, 24)
$null = $cmbAudioCodec.Items.AddRange(@('default', 'opus', 'aac', 'flac', 'raw'))
$cmbAudioCodec.SelectedIndex = 0
$grpAudio.Controls.Add($cmbAudioCodec)
$toolTip.SetToolTip($cmbAudioCodec, 'scrcpy --audio-codec. raw is uncompressed and needs a fast link')

$lblAudioEncoder = New-Object System.Windows.Forms.Label
$lblAudioEncoder.Text = 'Encoder'
$lblAudioEncoder.Location = New-Object System.Drawing.Point(178, 62)
$lblAudioEncoder.Size = New-Object System.Drawing.Size(56, 20)
$grpAudio.Controls.Add($lblAudioEncoder)

$cmbAudioEncoder = New-Object System.Windows.Forms.ComboBox
$cmbAudioEncoder.DropDownStyle = 'DropDownList'
$cmbAudioEncoder.Location = New-Object System.Drawing.Point(236, 58)
$cmbAudioEncoder.Size = New-Object System.Drawing.Size(210, 24)
$null = $cmbAudioEncoder.Items.Add('default')
$cmbAudioEncoder.SelectedIndex = 0
$cmbAudioEncoder.Enabled = $false
$grpAudio.Controls.Add($cmbAudioEncoder)
$toolTip.SetToolTip($cmbAudioEncoder, 'scrcpy --audio-encoder. Only the encoders this phone has for the chosen codec ' +
    'are offered - press Codecs to read them. Not remembered between runs: the names differ from phone to phone')

$btnAudioEncoders = New-Object System.Windows.Forms.Button
$btnAudioEncoders.Text = 'Codecs'
$btnAudioEncoders.Location = New-Object System.Drawing.Point(452, 57)
$btnAudioEncoders.Size = New-Object System.Drawing.Size(80, 26)
$grpAudio.Controls.Add($btnAudioEncoders)
$toolTip.SetToolTip($btnAudioEncoders, 'Ask the phone which audio codecs and encoders it really has, and fill the lists with them')

$lblAudioBitrate = New-Object System.Windows.Forms.Label
$lblAudioBitrate.Text = 'Bit rate'
$lblAudioBitrate.Location = New-Object System.Drawing.Point(200, 62)
$lblAudioBitrate.Size = New-Object System.Drawing.Size(54, 20)
$grpAudio.Controls.Add($lblAudioBitrate)

$cmbAudioBitrate = New-Object System.Windows.Forms.ComboBox
$cmbAudioBitrate.DropDownStyle = 'DropDown'
$cmbAudioBitrate.Location = New-Object System.Drawing.Point(258, 58)
$cmbAudioBitrate.Size = New-Object System.Drawing.Size(100, 24)
$null = $cmbAudioBitrate.Items.AddRange(@('default', '64K', '128K', '196K', '256K'))
$cmbAudioBitrate.SelectedIndex = 0
$grpAudio.Controls.Add($cmbAudioBitrate)
$toolTip.SetToolTip($cmbAudioBitrate, 'scrcpy --audio-bit-rate')

$chkAudioDup = New-Object System.Windows.Forms.CheckBox
$chkAudioDup.Text = 'keep playing on the phone too'
$chkAudioDup.Location = New-Object System.Drawing.Point(374, 60)
$chkAudioDup.Size = New-Object System.Drawing.Size(230, 22)
$grpAudio.Controls.Add($chkAudioDup)
$toolTip.SetToolTip($chkAudioDup, 'scrcpy --audio-dup: sound comes out of both, instead of only the PC. Android 13 and newer, output source only')

$lblAudioBuffer = New-Object System.Windows.Forms.Label
$lblAudioBuffer.Text = 'Buffer ms'
$lblAudioBuffer.Location = New-Object System.Drawing.Point(614, 62)
$lblAudioBuffer.Size = New-Object System.Drawing.Size(66, 20)
$grpAudio.Controls.Add($lblAudioBuffer)

$txtAudioBuffer = New-Object System.Windows.Forms.TextBox
$txtAudioBuffer.Location = New-Object System.Drawing.Point(684, 58)
$txtAudioBuffer.Size = New-Object System.Drawing.Size(60, 24)
$grpAudio.Controls.Add($txtAudioBuffer)
$toolTip.SetToolTip($txtAudioBuffer, 'scrcpy --audio-buffer: lower is snappier, higher survives a busy link. Blank leaves the default')

$lblAudioHint = New-Object System.Windows.Forms.Label
$lblAudioHint.Text = 'Phone -> PC only. Android gives no way to push PC audio to the phone speaker.'
$lblAudioHint.ForeColor = [System.Drawing.Color]::DimGray
$lblAudioHint.Location = New-Object System.Drawing.Point(14, 96)
$lblAudioHint.Size = New-Object System.Drawing.Size(700, 20)
$grpAudio.Controls.Add($lblAudioHint)

$btnListenStop = New-Object System.Windows.Forms.Button
$btnListenStop.Text = 'Stop audio'
$btnListenStop.Enabled = $false
$btnListenStop.Location = New-Object System.Drawing.Point(382, 25)
$btnListenStop.Size = New-Object System.Drawing.Size(96, 26)
$grpAudio.Controls.Add($btnListenStop)

$btnRecordAudio = New-Object System.Windows.Forms.Button
$btnRecordAudio.Text = 'Record audio...'
$btnRecordAudio.Location = New-Object System.Drawing.Point(486, 25)
$btnRecordAudio.Size = New-Object System.Drawing.Size(120, 26)
$grpAudio.Controls.Add($btnRecordAudio)
$toolTip.SetToolTip($btnRecordAudio, 'Record that audio source to an .opus/.m4a file instead of playing it')


# The mirroring page was one flat field of forty controls. They now sit in the
# box that says what they change, in the order you would actually use them.
$grpVideo = New-Object System.Windows.Forms.GroupBox
$grpVideo.Text = 'Picture'
$tabScrcpy.Controls.Add($grpVideo)

$grpWindowOpts = New-Object System.Windows.Forms.GroupBox
$grpWindowOpts.Text = 'Window'
$tabScrcpy.Controls.Add($grpWindowOpts)

$grpPhoneOpts = New-Object System.Windows.Forms.GroupBox
$grpPhoneOpts.Text = 'While mirroring, the phone'
$tabScrcpy.Controls.Add($grpPhoneOpts)

$grpTarget = New-Object System.Windows.Forms.GroupBox
$grpTarget.Text = 'What to mirror, and recording'
$tabScrcpy.Controls.Add($grpTarget)

$grpControl = New-Object System.Windows.Forms.GroupBox
$grpControl.Text = 'Keyboard, mouse and OTG'
$tabScrcpy.Controls.Add($grpControl)

foreach ($entry in @(
        @($grpVideo, @($cmbMaxSize, $cmbBitrate, $cmbFps, $cmbCodec),
            @('Max size', 'Bit rate', 'Max FPS', 'Codec')),
        @($grpWindowOpts, @($chkFullscreen, $chkBorderless, $chkOnTop, $chkNoScreensaver), @()),
        @($grpPhoneOpts, @($chkScreenOff, $chkStayAwake, $chkNoAudio, $chkViewOnly, $chkPowerOff), @()),
        @($grpTarget, @($cmbDisplay, $btnListDisplays, $chkNewDisplay, $txtNewDisplay, $cmbStartApp,
            $chkRecord, $txtRecord, $btnBrowseRecord, $lblExtraArgs, $txtExtraArgs),
            @('Display', 'Start app')),
        @($grpControl, @($chkOtg, $cmbKeyboard, $cmbMouse, $cmbGamepad, $btnKeyboardLayout),
            @('Keyboard', 'Mouse', 'Gamepad')))) {
    foreach ($control in $entry[1]) {
        $tabScrcpy.Controls.Remove($control)
        $entry[0].Controls.Add($control)
    }
    foreach ($name in $entry[2]) {
        $label = $script:scrcpyLabels[$name]
        if ($label) {
            $tabScrcpy.Controls.Remove($label)
            $entry[0].Controls.Add($label)
        }
    }
}

$btnScrcpy = New-Object System.Windows.Forms.Button
$btnScrcpy.Text = 'Launch scrcpy'
$btnScrcpy.Location = New-Object System.Drawing.Point(18, 232)
$btnScrcpy.Size = New-Object System.Drawing.Size(150, 36)
$tabScrcpy.Controls.Add($btnScrcpy)

$btnScrcpyShare = New-Object System.Windows.Forms.Button
$btnScrcpyShare.Text = 'Share internet + scrcpy'
$btnScrcpyShare.Location = New-Object System.Drawing.Point(176, 232)
$btnScrcpyShare.Size = New-Object System.Drawing.Size(180, 36)
$tabScrcpy.Controls.Add($btnScrcpyShare)

$btnOtg = New-Object System.Windows.Forms.Button
$btnOtg.Text = 'Launch OTG'
$btnOtg.Location = New-Object System.Drawing.Point(364, 232)
$btnOtg.Size = New-Object System.Drawing.Size(130, 36)
$tabScrcpy.Controls.Add($btnOtg)

$btnScrcpyClose = New-Object System.Windows.Forms.Button
$btnScrcpyClose.Text = 'Close all scrcpy'
$btnScrcpyClose.Location = New-Object System.Drawing.Point(502, 232)
$btnScrcpyClose.Size = New-Object System.Drawing.Size(150, 36)
$tabScrcpy.Controls.Add($btnScrcpyClose)

$btnShowCommand = New-Object System.Windows.Forms.Button
$btnShowCommand.Text = 'Show command'
$btnShowCommand.Location = New-Object System.Drawing.Point(658, 232)
$btnShowCommand.Size = New-Object System.Drawing.Size(140, 36)
$tabScrcpy.Controls.Add($btnShowCommand)


# --- tab: more scrcpy options -------------------------------------------------
function New-MoreLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 96, $Parent)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 20)
    $Parent.Controls.Add($label)
    return $label
}

$grpRecord = New-Object System.Windows.Forms.GroupBox
$grpRecord.Text = 'Recording'
$grpRecord.Location = New-Object System.Drawing.Point(12, 8)
$grpRecord.Size = New-Object System.Drawing.Size(440, 84)
$tabMore.Controls.Add($grpRecord)

$null = New-MoreLabel -Text 'Format' -X 12 -Y 28 -Width 54 -Parent $grpRecord
$cmbRecordFormat = New-Object System.Windows.Forms.ComboBox
$cmbRecordFormat.DropDownStyle = 'DropDownList'
$cmbRecordFormat.Location = New-Object System.Drawing.Point(70, 24)
$cmbRecordFormat.Size = New-Object System.Drawing.Size(96, 24)
$null = $cmbRecordFormat.Items.AddRange(@('from the name', 'mp4', 'mkv', 'm4a', 'mka', 'opus', 'aac', 'flac', 'wav'))
$cmbRecordFormat.SelectedIndex = 0
$grpRecord.Controls.Add($cmbRecordFormat)
$toolTip.SetToolTip($cmbRecordFormat, 'scrcpy --record-format; "from the name" lets the file extension decide')

$null = New-MoreLabel -Text 'Rotate' -X 178 -Y 28 -Width 48 -Parent $grpRecord
$cmbRecordOrientation = New-Object System.Windows.Forms.ComboBox
$cmbRecordOrientation.DropDownStyle = 'DropDownList'
$cmbRecordOrientation.Location = New-Object System.Drawing.Point(228, 24)
$cmbRecordOrientation.Size = New-Object System.Drawing.Size(76, 24)
$null = $cmbRecordOrientation.Items.AddRange(@('0', '90', '180', '270', 'flip0', 'flip90', 'flip180', 'flip270'))
$cmbRecordOrientation.SelectedIndex = 0
$grpRecord.Controls.Add($cmbRecordOrientation)
$toolTip.SetToolTip($cmbRecordOrientation, 'scrcpy --record-orientation: how the saved file is rotated')

$null = New-MoreLabel -Text 'Stop after' -X 12 -Y 56 -Width 66 -Parent $grpRecord
$numTimeLimit = New-Object System.Windows.Forms.NumericUpDown
$numTimeLimit.Minimum = 0
$numTimeLimit.Maximum = 86400
$numTimeLimit.Increment = 30
$numTimeLimit.Value = 0
$numTimeLimit.Location = New-Object System.Drawing.Point(82, 53)
$numTimeLimit.Size = New-Object System.Drawing.Size(84, 24)
$grpRecord.Controls.Add($numTimeLimit)
$toolTip.SetToolTip($numTimeLimit, 'scrcpy --time-limit in seconds; 0 means no limit')
$null = New-MoreLabel -Text 'seconds (0 = no limit)' -X 172 -Y 56 -Width 150 -Parent $grpRecord

$grpTurn = New-Object System.Windows.Forms.GroupBox
$grpTurn.Text = 'Orientation'
$grpTurn.Location = New-Object System.Drawing.Point(464, 8)
$grpTurn.Size = New-Object System.Drawing.Size(440, 84)
$tabMore.Controls.Add($grpTurn)

$null = New-MoreLabel -Text 'Window' -X 12 -Y 28 -Width 58 -Parent $grpTurn
$cmbOrientation = New-Object System.Windows.Forms.ComboBox
$cmbOrientation.DropDownStyle = 'DropDownList'
$cmbOrientation.Location = New-Object System.Drawing.Point(74, 24)
$cmbOrientation.Size = New-Object System.Drawing.Size(92, 24)
$null = $cmbOrientation.Items.AddRange(@('as it comes', '0', '90', '180', '270', 'flip0', 'flip90', 'flip180', 'flip270'))
$cmbOrientation.SelectedIndex = 0
$grpTurn.Controls.Add($cmbOrientation)
$toolTip.SetToolTip($cmbOrientation, 'scrcpy --orientation: turns the picture on the PC only')

$null = New-MoreLabel -Text 'Capture' -X 178 -Y 28 -Width 56 -Parent $grpTurn
$cmbCaptureOrientation = New-Object System.Windows.Forms.ComboBox
$cmbCaptureOrientation.DropDownStyle = 'DropDownList'
$cmbCaptureOrientation.Location = New-Object System.Drawing.Point(238, 24)
$cmbCaptureOrientation.Size = New-Object System.Drawing.Size(110, 24)
$null = $cmbCaptureOrientation.Items.AddRange(@('as it comes', '0', '90', '180', '270',
    '@0', '@90', '@180', '@270'))
$cmbCaptureOrientation.SelectedIndex = 0
$grpTurn.Controls.Add($cmbCaptureOrientation)
$toolTip.SetToolTip($cmbCaptureOrientation, 'scrcpy --capture-orientation: turns what the phone sends; @ locks it')

$null = New-MoreLabel -Text 'Turning the capture also turns what is recorded.' -X 12 -Y 56 -Width 400 -Parent $grpTurn

$grpVirtual = New-Object System.Windows.Forms.GroupBox
$grpVirtual.Text = 'New display  (used by "Own scrcpy window")'
$grpVirtual.Location = New-Object System.Drawing.Point(12, 100)
$grpVirtual.Size = New-Object System.Drawing.Size(440, 84)
$tabMore.Controls.Add($grpVirtual)

$null = New-MoreLabel -Text 'Keyboard' -X 12 -Y 28 -Width 64 -Parent $grpVirtual
$cmbImePolicy = New-Object System.Windows.Forms.ComboBox
$cmbImePolicy.DropDownStyle = 'DropDownList'
$cmbImePolicy.Location = New-Object System.Drawing.Point(80, 24)
$cmbImePolicy.Size = New-Object System.Drawing.Size(150, 24)
$null = $cmbImePolicy.Items.AddRange(@('leave it alone', 'local', 'fallback-display', 'hide'))
$cmbImePolicy.SelectedIndex = 0
$grpVirtual.Controls.Add($cmbImePolicy)
$toolTip.SetToolTip($cmbImePolicy, 'scrcpy --display-ime-policy: "local" keeps the keyboard on the new display')

$chkNoDecorations = New-Object System.Windows.Forms.CheckBox
$chkNoDecorations.Text = 'no system bars'
$chkNoDecorations.Location = New-Object System.Drawing.Point(244, 26)
$chkNoDecorations.Size = New-Object System.Drawing.Size(130, 22)
$grpVirtual.Controls.Add($chkNoDecorations)
$toolTip.SetToolTip($chkNoDecorations, 'scrcpy --no-vd-system-decorations')

$chkKeepContent = New-Object System.Windows.Forms.CheckBox
$chkKeepContent.Text = 'keep the apps running when the window closes'
$chkKeepContent.Location = New-Object System.Drawing.Point(14, 54)
$chkKeepContent.Size = New-Object System.Drawing.Size(400, 22)
$grpVirtual.Controls.Add($chkKeepContent)
$toolTip.SetToolTip($chkKeepContent, 'scrcpy --no-vd-destroy-content')

$grpWindow = New-Object System.Windows.Forms.GroupBox
$grpWindow.Text = 'Window on this PC'
$grpWindow.Location = New-Object System.Drawing.Point(464, 100)
$grpWindow.Size = New-Object System.Drawing.Size(440, 84)
$tabMore.Controls.Add($grpWindow)

$windowBoxes = @()
$x = 14
foreach ($name in @('x', 'y', 'width', 'height')) {
    $null = New-MoreLabel -Text $name -X $x -Y 28 -Width 44 -Parent $grpWindow
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(($x + 44), 25)
    $box.Size = New-Object System.Drawing.Size(56, 24)
    $grpWindow.Controls.Add($box)
    $windowBoxes += $box
    $x += 106
}
$txtWindowX = $windowBoxes[0]
$txtWindowY = $windowBoxes[1]
$txtWindowW = $windowBoxes[2]
$txtWindowH = $windowBoxes[3]
$toolTip.SetToolTip($txtWindowX, 'scrcpy --window-x, left blank to let Windows decide')

$chkPrintFps = New-Object System.Windows.Forms.CheckBox
$chkPrintFps.Text = 'print the frame rate in the log'
$chkPrintFps.Location = New-Object System.Drawing.Point(14, 54)
$chkPrintFps.Size = New-Object System.Drawing.Size(240, 22)
$grpWindow.Controls.Add($chkPrintFps)
$toolTip.SetToolTip($chkPrintFps, 'scrcpy --print-fps')

$null = New-MoreLabel -Text 'Screen off after' -X 258 -Y 56 -Width 96 -Parent $grpWindow
$txtScreenOffTimeout = New-Object System.Windows.Forms.TextBox
$txtScreenOffTimeout.Location = New-Object System.Drawing.Point(358, 53)
$txtScreenOffTimeout.Size = New-Object System.Drawing.Size(64, 24)
$grpWindow.Controls.Add($txtScreenOffTimeout)
$toolTip.SetToolTip($txtScreenOffTimeout, 'scrcpy --screen-off-timeout in seconds, while mirroring only')

$grpInput = New-Object System.Windows.Forms.GroupBox
$grpInput.Text = 'Keyboard and mouse'
$grpInput.Location = New-Object System.Drawing.Point(12, 192)
$grpInput.Size = New-Object System.Drawing.Size(892, 84)
$tabMore.Controls.Add($grpInput)

$null = New-MoreLabel -Text 'Shortcut key' -X 12 -Y 28 -Width 80 -Parent $grpInput
$cmbShortcutMod = New-Object System.Windows.Forms.ComboBox
$cmbShortcutMod.DropDownStyle = 'DropDownList'
$cmbShortcutMod.Location = New-Object System.Drawing.Point(96, 24)
$cmbShortcutMod.Size = New-Object System.Drawing.Size(120, 24)
$null = $cmbShortcutMod.Items.AddRange(@('default (left Alt)', 'lalt', 'ralt', 'lctrl', 'rctrl', 'lsuper', 'rsuper'))
$cmbShortcutMod.SelectedIndex = 0
$grpInput.Controls.Add($cmbShortcutMod)
$toolTip.SetToolTip($cmbShortcutMod, 'scrcpy --shortcut-mod: which key starts a scrcpy shortcut')

$null = New-MoreLabel -Text 'Mouse buttons' -X 232 -Y 28 -Width 92 -Parent $grpInput
$txtMouseBind = New-Object System.Windows.Forms.TextBox
$txtMouseBind.Location = New-Object System.Drawing.Point(328, 25)
$txtMouseBind.Size = New-Object System.Drawing.Size(120, 24)
$grpInput.Controls.Add($txtMouseBind)
$toolTip.SetToolTip($txtMouseBind, 'scrcpy --mouse-bind, for example bhsn - leave blank for the default')

$chkPreferText = New-Object System.Windows.Forms.CheckBox
$chkPreferText.Text = 'send text, not key codes'
$chkPreferText.Location = New-Object System.Drawing.Point(468, 26)
$chkPreferText.Size = New-Object System.Drawing.Size(184, 22)
$grpInput.Controls.Add($chkPreferText)
$toolTip.SetToolTip($chkPreferText, 'scrcpy --prefer-text: better for typing, worse for games')

$chkRawKeys = New-Object System.Windows.Forms.CheckBox
$chkRawKeys.Text = 'raw key events'
$chkRawKeys.Location = New-Object System.Drawing.Point(660, 26)
$chkRawKeys.Size = New-Object System.Drawing.Size(140, 22)
$grpInput.Controls.Add($chkRawKeys)
$toolTip.SetToolTip($chkRawKeys, 'scrcpy --raw-key-events')

$chkNoKeyRepeat = New-Object System.Windows.Forms.CheckBox
$chkNoKeyRepeat.Text = 'no key repeat'
$chkNoKeyRepeat.Location = New-Object System.Drawing.Point(14, 54)
$chkNoKeyRepeat.Size = New-Object System.Drawing.Size(130, 22)
$grpInput.Controls.Add($chkNoKeyRepeat)
$toolTip.SetToolTip($chkNoKeyRepeat, 'scrcpy --no-key-repeat')

$chkLegacyPaste = New-Object System.Windows.Forms.CheckBox
$chkLegacyPaste.Text = 'legacy paste'
$chkLegacyPaste.Location = New-Object System.Drawing.Point(154, 54)
$chkLegacyPaste.Size = New-Object System.Drawing.Size(120, 22)
$grpInput.Controls.Add($chkLegacyPaste)
$toolTip.SetToolTip($chkLegacyPaste, 'scrcpy --legacy-paste: paste as keystrokes for apps that ignore the clipboard')

$chkKillAdb = New-Object System.Windows.Forms.CheckBox
$chkKillAdb.Text = 'kill the adb server when scrcpy closes'
$chkKillAdb.Location = New-Object System.Drawing.Point(284, 54)
$chkKillAdb.Size = New-Object System.Drawing.Size(270, 22)
$grpInput.Controls.Add($chkKillAdb)
$toolTip.SetToolTip($chkKillAdb, 'scrcpy --kill-adb-on-close. It also drops any tunnel, so it is off by default')

$chkNoCleanup = New-Object System.Windows.Forms.CheckBox
$chkNoCleanup.Text = 'leave the phone as it is on close'
$chkNoCleanup.Location = New-Object System.Drawing.Point(564, 54)
$chkNoCleanup.Size = New-Object System.Drawing.Size(240, 22)
$grpInput.Controls.Add($chkNoCleanup)
$toolTip.SetToolTip($chkNoCleanup, 'scrcpy --no-cleanup: do not restore the screen or clipboard afterwards')

# --- tab 4: adb tools --------------------------------------------------------

$btnPair = New-Object System.Windows.Forms.Button
$btnPair.Text = 'Pair over Wi-Fi...'
$btnPair.Location = New-Object System.Drawing.Point(18, 20)
$btnPair.Size = New-Object System.Drawing.Size(150, 28)
$tabTools.Controls.Add($btnPair)
$toolTip.SetToolTip($btnPair, 'Wireless debugging without a cable (Android 11 and newer)')

$btnMdns = New-Object System.Windows.Forms.Button
$btnMdns.Text = 'Find devices'
$btnMdns.Location = New-Object System.Drawing.Point(176, 20)
$btnMdns.Size = New-Object System.Drawing.Size(120, 28)
$tabTools.Controls.Add($btnMdns)
$toolTip.SetToolTip($btnMdns, 'List the phones advertising wireless debugging on this network')

$btnReconnect = New-Object System.Windows.Forms.Button
$btnReconnect.Text = 'Reconnect'
$btnReconnect.Location = New-Object System.Drawing.Point(304, 20)
$btnReconnect.Size = New-Object System.Drawing.Size(110, 28)
$tabTools.Controls.Add($btnReconnect)
$toolTip.SetToolTip($btnReconnect, 'The usual cure for a device stuck as offline')

$btnBugReport = New-Object System.Windows.Forms.Button
$btnBugReport.Text = 'Bug report...'
$btnBugReport.Location = New-Object System.Drawing.Point(422, 20)
$btnBugReport.Size = New-Object System.Drawing.Size(120, 28)
$tabTools.Controls.Add($btnBugReport)
$toolTip.SetToolTip($btnBugReport, 'A full diagnostic zip from the phone; it takes a few minutes')

$btnTcpip = New-Object System.Windows.Forms.Button
$btnTcpip.Text = 'Wireless ADB (tcpip 5555)'
$btnTcpip.Location = New-Object System.Drawing.Point(18, 20)
$btnTcpip.Size = New-Object System.Drawing.Size(200, 34)
$tabTools.Controls.Add($btnTcpip)
$toolTip.SetToolTip($btnTcpip, 'Switch the selected USB device to TCP/IP and connect over Wi-Fi')

$txtConnect = New-Object System.Windows.Forms.TextBox
$txtConnect.Location = New-Object System.Drawing.Point(226, 24)
$txtConnect.Size = New-Object System.Drawing.Size(170, 24)
$tabTools.Controls.Add($txtConnect)
$toolTip.SetToolTip($txtConnect, 'ip:port, e.g. 192.168.1.20:5555')

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Connect'
$btnConnect.Location = New-Object System.Drawing.Point(404, 20)
$btnConnect.Size = New-Object System.Drawing.Size(100, 34)
$tabTools.Controls.Add($btnConnect)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = 'Disconnect all'
$btnDisconnect.Location = New-Object System.Drawing.Point(512, 20)
$btnDisconnect.Size = New-Object System.Drawing.Size(120, 34)
$tabTools.Controls.Add($btnDisconnect)

$btnRestartServer = New-Object System.Windows.Forms.Button
$btnRestartServer.Text = 'Restart ADB server'
$btnRestartServer.Location = New-Object System.Drawing.Point(640, 20)
$btnRestartServer.Size = New-Object System.Drawing.Size(150, 34)
$tabTools.Controls.Add($btnRestartServer)

$btnInstallApk = New-Object System.Windows.Forms.Button
$btnInstallApk.Text = 'Install APK...'
$btnInstallApk.Location = New-Object System.Drawing.Point(18, 66)
$btnInstallApk.Size = New-Object System.Drawing.Size(140, 34)
$tabTools.Controls.Add($btnInstallApk)

$btnScreenshot = New-Object System.Windows.Forms.Button
$btnScreenshot.Text = 'Screenshot to PC'
$btnScreenshot.Location = New-Object System.Drawing.Point(166, 66)
$btnScreenshot.Size = New-Object System.Drawing.Size(150, 34)
$tabTools.Controls.Add($btnScreenshot)

$btnScreenToggle = New-Object System.Windows.Forms.Button
$btnScreenToggle.Text = 'Screen on/off'
$btnScreenToggle.Location = New-Object System.Drawing.Point(324, 66)
$btnScreenToggle.Size = New-Object System.Drawing.Size(130, 34)
$tabTools.Controls.Add($btnScreenToggle)

$btnReboot = New-Object System.Windows.Forms.Button
$btnReboot.Text = 'Reboot device'
$btnReboot.Location = New-Object System.Drawing.Point(678, 66)
$btnReboot.Size = New-Object System.Drawing.Size(130, 34)
$tabTools.Controls.Add($btnReboot)

$btnBattery = New-Object System.Windows.Forms.Button
$btnBattery.Text = 'Battery / network'
$btnBattery.Location = New-Object System.Drawing.Point(18, 112)
$btnBattery.Size = New-Object System.Drawing.Size(150, 34)
$tabTools.Controls.Add($btnBattery)

$btnReverseList = New-Object System.Windows.Forms.Button
$btnReverseList.Text = 'List reverse tunnels'
$btnReverseList.Location = New-Object System.Drawing.Point(176, 112)
$btnReverseList.Size = New-Object System.Drawing.Size(160, 34)
$tabTools.Controls.Add($btnReverseList)

$btnKillRelays = New-Object System.Windows.Forms.Button
$btnKillRelays.Text = 'Kill stray relays'
$btnKillRelays.Location = New-Object System.Drawing.Point(502, 112)
$btnKillRelays.Size = New-Object System.Drawing.Size(150, 34)
$tabTools.Controls.Add($btnKillRelays)
$toolTip.SetToolTip($btnKillRelays, 'Kill gnirehtet.exe processes left over from previous runs')

$btnRepairTunnel = New-Object System.Windows.Forms.Button
$btnRepairTunnel.Text = 'Repair tunnel'
$btnRepairTunnel.Location = New-Object System.Drawing.Point(660, 112)
$btnRepairTunnel.Size = New-Object System.Drawing.Size(150, 34)
$tabTools.Controls.Add($btnRepairTunnel)
$toolTip.SetToolTip($btnRepairTunnel, 'Re-create the adb reverse tunnel after an adb restart or an unplug/replug')

# builds "<label>  [On] [Off]" and returns the two buttons
$script:togglePairs = @()

function New-TogglePair {
    param([string]$Text, [int]$X, [int]$Y, [int]$LabelWidth = 86, $Parent = $null)

    if ($null -eq $Parent) { $Parent = $grpToggles }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, ($Y + 5))
    $label.Size = New-Object System.Drawing.Size($LabelWidth, 20)
    $Parent.Controls.Add($label)

    $on = New-Object System.Windows.Forms.Button
    $on.Text = 'On'
    $on.Location = New-Object System.Drawing.Point(($X + $LabelWidth + 4), $Y)
    $on.Size = New-Object System.Drawing.Size(52, 26)
    $Parent.Controls.Add($on)

    $off = New-Object System.Windows.Forms.Button
    $off.Text = 'Off'
    $off.Location = New-Object System.Drawing.Point(($X + $LabelWidth + 60), $Y)
    $off.Size = New-Object System.Drawing.Size(52, 26)
    $Parent.Controls.Add($off)

    $script:togglePairs += , @($label, $on, $off)
    return @($on, $off)
}

$pair = New-TogglePair -Text 'Auto-rotate' -X 12 -Y 22 -LabelWidth 100
$btnRotationOn = $pair[0]; $btnRotationOff = $pair[1]

$pair = New-TogglePair -Text 'Location' -X 196 -Y 22 -LabelWidth 100
$btnLocationOn = $pair[0]; $btnLocationOff = $pair[1]

$pair = New-TogglePair -Text 'Bluetooth' -X 12 -Y 52 -LabelWidth 100
$btnBtOn = $pair[0]; $btnBtOff = $pair[1]

$pair = New-TogglePair -Text 'Wi-Fi' -X 196 -Y 52 -LabelWidth 100
$btnWifiOn = $pair[0]; $btnWifiOff = $pair[1]

$pair = New-TogglePair -Text 'Battery saver' -X 12 -Y 82 -LabelWidth 100
$btnSaverOn = $pair[0]; $btnSaverOff = $pair[1]

$pair = New-TogglePair -Text 'Vibrate on ring' -X 196 -Y 82 -LabelWidth 100
$btnRingVibeOn = $pair[0]; $btnRingVibeOff = $pair[1]

$pair = New-TogglePair -Text 'Touch haptics' -X 12 -Y 112 -LabelWidth 100
$btnHapticsOn = $pair[0]; $btnHapticsOff = $pair[1]

$btnTorch = New-Object System.Windows.Forms.Button
$btnTorch.Text = 'Torch'
$btnTorch.Location = New-Object System.Drawing.Point(12, 172)
$btnTorch.Size = New-Object System.Drawing.Size(96, 26)
$grpToggles.Controls.Add($btnTorch)
$toolTip.SetToolTip($btnTorch, 'Android has no supported adb torch switch; this clicks the quick-settings tile and verifies the result')

$btnBuzz = New-Object System.Windows.Forms.Button
$btnBuzz.Text = 'Buzz'
$btnBuzz.Location = New-Object System.Drawing.Point(114, 172)
$btnBuzz.Size = New-Object System.Drawing.Size(74, 26)
$grpToggles.Controls.Add($btnBuzz)
$toolTip.SetToolTip($btnBuzz, 'Ask the device to vibrate once (some ROMs ignore the shell vibrator)')

$btnReadToggles = New-Object System.Windows.Forms.Button
$btnReadToggles.Text = 'Read states'
$btnReadToggles.Location = New-Object System.Drawing.Point(194, 172)
$btnReadToggles.Size = New-Object System.Drawing.Size(102, 26)
$grpToggles.Controls.Add($btnReadToggles)

$pair = New-TogglePair -Text 'Show taps' -X 196 -Y 112 -LabelWidth 100
$btnTapsOn = $pair[0]; $btnTapsOff = $pair[1]

$pair = New-TogglePair -Text 'Stay awake' -X 12 -Y 142 -LabelWidth 100
$btnAwakeOn = $pair[0]; $btnAwakeOff = $pair[1]

$pair = New-TogglePair -Text 'Developer opts' -X 196 -Y 142 -LabelWidth 100
$btnDevOn = $pair[0]; $btnDevOff = $pair[1]

$btnDevOpen = New-Object System.Windows.Forms.Button
$btnDevOpen.Text = 'Dev screen'
$btnDevOpen.Location = New-Object System.Drawing.Point(302, 172)
$btnDevOpen.Size = New-Object System.Drawing.Size(98, 26)
$grpToggles.Controls.Add($btnDevOpen)
$toolTip.SetToolTip($btnDevOpen, 'Open the developer options screen on the phone')

$lblIme = New-Object System.Windows.Forms.Label
$lblIme.Text = 'Keyboard (IME)'
$lblIme.Location = New-Object System.Drawing.Point(18, 150)
$lblIme.Size = New-Object System.Drawing.Size(92, 20)
$tabTools.Controls.Add($lblIme)

$cmbIme = New-Object System.Windows.Forms.ComboBox
$cmbIme.DropDownStyle = 'DropDown'
$cmbIme.Location = New-Object System.Drawing.Point(112, 146)
$cmbIme.Size = New-Object System.Drawing.Size(420, 24)
$tabTools.Controls.Add($cmbIme)
$toolTip.SetToolTip($cmbIme, 'Input methods reported by the device (ime list -a -s)')

$btnImeList = New-Object System.Windows.Forms.Button
$btnImeList.Text = 'List'
$btnImeList.Location = New-Object System.Drawing.Point(540, 145)
$btnImeList.Size = New-Object System.Drawing.Size(80, 26)
$tabTools.Controls.Add($btnImeList)

$btnImeDisable = New-Object System.Windows.Forms.Button
$btnImeDisable.Text = 'Disable'
$btnImeDisable.Location = New-Object System.Drawing.Point(628, 145)
$btnImeDisable.Size = New-Object System.Drawing.Size(90, 26)
$tabTools.Controls.Add($btnImeDisable)
$toolTip.SetToolTip($btnImeDisable, 'ime disable <id> - hides the on-screen keyboard (handy with a scrcpy hardware keyboard)')

$btnImeEnable = New-Object System.Windows.Forms.Button
$btnImeEnable.Text = 'Enable'
$btnImeEnable.Location = New-Object System.Drawing.Point(726, 145)
$btnImeEnable.Size = New-Object System.Drawing.Size(90, 26)
$tabTools.Controls.Add($btnImeEnable)

$btnImeDefault = New-Object System.Windows.Forms.Button
$btnImeDefault.Text = 'Set as default'
$btnImeDefault.Location = New-Object System.Drawing.Point(112, 180)
$btnImeDefault.Size = New-Object System.Drawing.Size(120, 26)
$tabTools.Controls.Add($btnImeDefault)

$btnImeReset = New-Object System.Windows.Forms.Button
$btnImeReset.Text = 'Reset IMEs'
$btnImeReset.Location = New-Object System.Drawing.Point(240, 180)
$btnImeReset.Size = New-Object System.Drawing.Size(110, 26)
$tabTools.Controls.Add($btnImeReset)
$toolTip.SetToolTip($btnImeReset, 'ime reset - brings back the keyboards you disabled')

$lblImeHint = New-Object System.Windows.Forms.Label
$lblImeHint.Text = 'No IME enabled = no keyboard.'
$lblImeHint.ForeColor = [System.Drawing.Color]::DimGray
$lblImeHint.Location = New-Object System.Drawing.Point(360, 186)
$lblImeHint.Size = New-Object System.Drawing.Size(214, 20)
$tabTools.Controls.Add($lblImeHint)

$lblDns = New-Object System.Windows.Forms.Label
$lblDns.Text = 'DNS'
$lblDns.Location = New-Object System.Drawing.Point(18, 118)
$lblDns.Size = New-Object System.Drawing.Size(34, 20)
$tabTools.Controls.Add($lblDns)

$cmbDnsMode = New-Object System.Windows.Forms.ComboBox
$cmbDnsMode.DropDownStyle = 'DropDownList'
$cmbDnsMode.Location = New-Object System.Drawing.Point(56, 114)
$cmbDnsMode.Size = New-Object System.Drawing.Size(190, 24)
$null = $cmbDnsMode.Items.AddRange(@('automatic (opportunistic)', 'off', 'custom hostname'))
$cmbDnsMode.SelectedIndex = 0
$tabTools.Controls.Add($cmbDnsMode)
$toolTip.SetToolTip($cmbDnsMode, 'Android Private DNS: automatic upgrades to DNS-over-TLS when the resolver supports it')

$txtDnsHost = New-Object System.Windows.Forms.TextBox
$txtDnsHost.Location = New-Object System.Drawing.Point(254, 114)
$txtDnsHost.Size = New-Object System.Drawing.Size(230, 24)
$tabTools.Controls.Add($txtDnsHost)
$toolTip.SetToolTip($txtDnsHost, 'Provider hostname for custom mode, e.g. dns.google, dns.adguard.com, one.one.one.one')

$btnDnsRead = New-Object System.Windows.Forms.Button
$btnDnsRead.Text = 'Read DNS'
$btnDnsRead.Location = New-Object System.Drawing.Point(492, 113)
$btnDnsRead.Size = New-Object System.Drawing.Size(96, 26)
$tabTools.Controls.Add($btnDnsRead)

$btnDnsAdGuard = New-Object System.Windows.Forms.Button
$btnDnsAdGuard.Text = 'AD'
$btnDnsAdGuard.Location = New-Object System.Drawing.Point(596, 113)
$btnDnsAdGuard.Size = New-Object System.Drawing.Size(46, 26)
$tabTools.Controls.Add($btnDnsAdGuard)
$toolTip.SetToolTip($btnDnsAdGuard, 'AdGuard')

$btnDnsApply = New-Object System.Windows.Forms.Button
$btnDnsApply.Text = 'Apply'
$btnDnsApply.Location = New-Object System.Drawing.Point(650, 113)
$btnDnsApply.Size = New-Object System.Drawing.Size(80, 26)
$tabTools.Controls.Add($btnDnsApply)

$txtDnsState = New-Object System.Windows.Forms.TextBox
$txtDnsState.ReadOnly = $true
$txtDnsState.BackColor = [System.Drawing.SystemColors]::Control
$txtDnsState.BorderStyle = 'None'
$txtDnsState.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtDnsState.Location = New-Object System.Drawing.Point(56, 144)
$txtDnsState.Size = New-Object System.Drawing.Size(790, 20)
$tabTools.Controls.Add($txtDnsState)
$toolTip.SetToolTip($txtDnsState, 'What the selected device resolves through right now')

$lblHotspot = New-Object System.Windows.Forms.Label
$lblHotspot.Text = 'Hotspot'
$lblHotspot.Location = New-Object System.Drawing.Point(18, 218)
$lblHotspot.Size = New-Object System.Drawing.Size(58, 20)
$tabTools.Controls.Add($lblHotspot)

$btnHotspotOn = New-Object System.Windows.Forms.Button
$btnHotspotOn.Text = 'Hotspot on'
$btnHotspotOn.Location = New-Object System.Drawing.Point(80, 214)
$btnHotspotOn.Size = New-Object System.Drawing.Size(110, 28)
$tabTools.Controls.Add($btnHotspotOn)
$toolTip.SetToolTip($btnHotspotOn, 'Android has no adb command for this: the button flips the switch on the phone settings page for you')

$btnHotspotOff = New-Object System.Windows.Forms.Button
$btnHotspotOff.Text = 'Hotspot off'
$btnHotspotOff.Location = New-Object System.Drawing.Point(198, 214)
$btnHotspotOff.Size = New-Object System.Drawing.Size(110, 28)
$tabTools.Controls.Add($btnHotspotOff)

$btnHotspotState = New-Object System.Windows.Forms.Button
$btnHotspotState.Text = 'Hotspot status'
$btnHotspotState.Location = New-Object System.Drawing.Point(316, 214)
$btnHotspotState.Size = New-Object System.Drawing.Size(120, 28)
$tabTools.Controls.Add($btnHotspotState)

$btnHotspotSettings = New-Object System.Windows.Forms.Button
$btnHotspotSettings.Text = 'Hotspot settings'
$btnHotspotSettings.Location = New-Object System.Drawing.Point(444, 214)
$btnHotspotSettings.Size = New-Object System.Drawing.Size(130, 28)
$tabTools.Controls.Add($btnHotspotSettings)

$btnUsbTetherOn = New-Object System.Windows.Forms.Button
$btnUsbTetherOn.Text = 'USB tether on'
$btnUsbTetherOn.Location = New-Object System.Drawing.Point(582, 214)
$btnUsbTetherOn.Size = New-Object System.Drawing.Size(120, 28)
$tabTools.Controls.Add($btnUsbTetherOn)
$toolTip.SetToolTip($btnUsbTetherOn, 'Share the phone connection over the USB cable')

$btnUsbTetherOff = New-Object System.Windows.Forms.Button
$btnUsbTetherOff.Text = 'USB tether off'
$btnUsbTetherOff.Location = New-Object System.Drawing.Point(710, 214)
$btnUsbTetherOff.Size = New-Object System.Drawing.Size(120, 28)
$tabTools.Controls.Add($btnUsbTetherOff)

$btnHotspotInfo = New-Object System.Windows.Forms.Button
$btnHotspotInfo.Text = 'Wi-Fi name / password'
$btnHotspotInfo.Location = New-Object System.Drawing.Point(582, 180)
$btnHotspotInfo.Size = New-Object System.Drawing.Size(160, 26)
$tabTools.Controls.Add($btnHotspotInfo)
$toolTip.SetToolTip($btnHotspotInfo, 'Read the hotspot name, security and password from the phone settings page')

$lblToolsHint = New-Object System.Windows.Forms.Label
$lblToolsHint.Text = 'Every action here runs on all selected devices.'
$lblToolsHint.ForeColor = [System.Drawing.Color]::DimGray
$lblToolsHint.Location = New-Object System.Drawing.Point(12, 434)
$lblToolsHint.Size = New-Object System.Drawing.Size(480, 20)
$tabTools.Controls.Add($lblToolsHint)


# The tools page used to be four unlabelled rows of buttons. The same controls
# now sit in the box that says what they are for.
$grpConnect = New-Object System.Windows.Forms.GroupBox
$grpConnect.Text = 'Connection'
$tabTools.Controls.Add($grpConnect)

# The Connection box had twelve controls in it and read as a wall. The three
# that are only reached for when something is stuck have their own box now.
$grpUnstick = New-Object System.Windows.Forms.GroupBox
$grpUnstick.Text = 'When something is stuck'
$tabTools.Controls.Add($grpUnstick)

$grpDeviceActions = New-Object System.Windows.Forms.GroupBox
$grpDeviceActions.Text = 'This device'
$tabTools.Controls.Add($grpDeviceActions)

$grpDnsBox = New-Object System.Windows.Forms.GroupBox
$grpDnsBox.Text = 'Private DNS'
$tabTools.Controls.Add($grpDnsBox)

$grpImeBox = New-Object System.Windows.Forms.GroupBox
$grpImeBox.Text = 'Keyboard (IME)'
$tabTools.Controls.Add($grpImeBox)

$grpHotspotBox = New-Object System.Windows.Forms.GroupBox
$grpHotspotBox.Text = 'Hotspot and tethering'
$tabTools.Controls.Add($grpHotspotBox)

foreach ($entry in @(
        @($grpConnect, @($btnPair, $btnMdns, $btnReconnect, $btnBugReport, $btnTcpip, $txtConnect,
            $btnConnect, $btnDisconnect, $btnRestartServer)),
        @($grpUnstick, @($btnReverseList, $btnKillRelays, $btnRepairTunnel)),
        @($grpDeviceActions, @($btnInstallApk, $btnScreenshot, $btnScreenToggle, $btnReboot, $btnBattery)),
        @($grpDnsBox, @($lblDns, $cmbDnsMode, $txtDnsHost, $btnDnsRead, $btnDnsAdGuard, $btnDnsApply, $txtDnsState)),
        @($grpImeBox, @($lblIme, $cmbIme, $btnImeList, $btnImeDisable, $btnImeEnable, $btnImeDefault,
            $btnImeReset, $lblImeHint)),
        @($grpHotspotBox, @($lblHotspot, $btnHotspotOn, $btnHotspotOff, $btnHotspotState, $btnHotspotSettings,
            $btnHotspotInfo, $btnUsbTetherOn, $btnUsbTetherOff)))) {
    foreach ($control in $entry[1]) {
        $tabTools.Controls.Remove($control)
        $entry[0].Controls.Add($control)
    }
}


# --- tab: root / recovery -----------------------------------------------------
# These exist in adb but cannot run on an ordinary retail phone. They are shown
# rather than hidden, marked with a sign, explained by their tooltip, and
# checked against the device that is actually selected. One checkbox unlocks
# them for somebody on a rooted or userdebug build.

$script:rootButtons = @()

$lblRootWarn = New-Object System.Windows.Forms.Label
$lblRootWarn.Text = 'Everything on this page needs root, a userdebug build, or the phone in recovery. ' +
    'On a normal retail phone none of it can work, so it is switched off.'
$lblRootWarn.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)
$lblRootWarn.Location = New-Object System.Drawing.Point(14, 10)
$lblRootWarn.Size = New-Object System.Drawing.Size(860, 36)
$tabRoot.Controls.Add($lblRootWarn)

$chkRootUnlock = New-Object System.Windows.Forms.CheckBox
$chkRootUnlock.Text = 'I understand - let me try anyway'
$chkRootUnlock.Location = New-Object System.Drawing.Point(14, 50)
$chkRootUnlock.Size = New-Object System.Drawing.Size(300, 22)
$tabRoot.Controls.Add($chkRootUnlock)

$btnRootCheck = New-Object System.Windows.Forms.Button
$btnRootCheck.Text = 'Check this device'
$btnRootCheck.Location = New-Object System.Drawing.Point(330, 46)
$btnRootCheck.Size = New-Object System.Drawing.Size(150, 28)
$tabRoot.Controls.Add($btnRootCheck)
$toolTip.SetToolTip($btnRootCheck, 'Read ro.build.type and friends, and mark what this phone would allow')

$lblRootState = New-Object System.Windows.Forms.Label
$lblRootState.Text = 'not checked yet'
$lblRootState.ForeColor = [System.Drawing.Color]::DimGray
$lblRootState.Location = New-Object System.Drawing.Point(496, 52)
$lblRootState.Size = New-Object System.Drawing.Size(380, 20)
$tabRoot.Controls.Add($lblRootState)

function New-RootAction {
    param([string]$Caption, [string]$Why, [string]$Needs, [int]$X, [int]$Y, [int]$Width = 150)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = [string][char]0x26D4 + ' ' + $Caption
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 28)
    $button.Enabled = $false
    $button.Tag = [PSCustomObject]@{ Caption = $Caption; Needs = $Needs }
    $tabRoot.Controls.Add($button)
    $toolTip.SetToolTip($button, "$Why  Needs: $Needs")
    $script:rootButtons += $button
    return $button
}

$grpRootAdb = New-Object System.Windows.Forms.GroupBox
$grpRootAdb.Text = 'adb as root'
$grpRootAdb.Location = New-Object System.Drawing.Point(12, 82)
$grpRootAdb.Size = New-Object System.Drawing.Size(864, 68)
$tabRoot.Controls.Add($grpRootAdb)

$grpRootImage = New-Object System.Windows.Forms.GroupBox
$grpRootImage.Text = 'System image'
$grpRootImage.Location = New-Object System.Drawing.Point(12, 156)
$grpRootImage.Size = New-Object System.Drawing.Size(864, 68)
$tabRoot.Controls.Add($grpRootImage)

$grpRootOther = New-Object System.Windows.Forms.GroupBox
$grpRootOther.Text = 'Recovery, emulator and developer plumbing'
$grpRootOther.Location = New-Object System.Drawing.Point(12, 230)
$grpRootOther.Size = New-Object System.Drawing.Size(864, 100)
$tabRoot.Controls.Add($grpRootOther)

$btnRootOn = New-RootAction -Caption 'adb root' -X 12 -Y 26 -Width 130 `
    -Why 'Restarts adbd with root rights.' -Needs 'userdebug or eng build'
$btnRootOff = New-RootAction -Caption 'adb unroot' -X 150 -Y 26 -Width 130 `
    -Why 'Puts adbd back to the ordinary shell user.' -Needs 'a rooted adbd'
$btnRootRemount = New-RootAction -Caption 'remount' -X 288 -Y 26 -Width 130 `
    -Why 'Makes /system writable.' -Needs 'root, and verity off'
$btnRootWaitDevice = New-RootAction -Caption 'wait-for-device' -X 426 -Y 26 -Width 150 `
    -Why 'Blocks until a device answers. Harmless, and useful after a reboot.' -Needs 'nothing'

$btnRootVerityOff = New-RootAction -Caption 'disable-verity' -X 12 -Y 26 -Width 150 `
    -Why 'Turns off verified boot checking on the system image.' -Needs 'root, changes verified boot'
$btnRootVerityOn = New-RootAction -Caption 'enable-verity' -X 170 -Y 26 -Width 150 `
    -Why 'Turns verified boot checking back on.' -Needs 'root'

$btnRootSideload = New-RootAction -Caption 'sideload a zip...' -X 12 -Y 26 -Width 160 `
    -Why 'Flashes an OTA package.' -Needs 'the phone in recovery, not in Android'
$btnRootEmu = New-RootAction -Caption 'emu console...' -X 180 -Y 26 -Width 150 `
    -Why 'Talks to the emulator console.' -Needs 'an emulator, not a phone'
$btnRootJdwp = New-RootAction -Caption 'jdwp' -X 338 -Y 26 -Width 110 `
    -Why 'Lists the processes that accept a Java debugger. adb jdwp never stops by itself, so it is given three seconds.' -Needs 'a debuggable app running'
$btnRootKeygen = New-RootAction -Caption 'keygen...' -X 456 -Y 26 -Width 120 `
    -Why 'Writes a new adb key pair to a file.' -Needs 'nothing, though it re-pairs nothing by itself'
$btnRootDevPath = New-RootAction -Caption 'get-devpath' -X 584 -Y 26 -Width 130 `
    -Why 'Prints the USB device path.' -Needs 'nothing'

# each group owns its own buttons
foreach ($entry in @(
        @($grpRootAdb, @($btnRootOn, $btnRootOff, $btnRootRemount, $btnRootWaitDevice)),
        @($grpRootImage, @($btnRootVerityOff, $btnRootVerityOn)),
        @($grpRootOther, @($btnRootSideload, $btnRootEmu, $btnRootJdwp, $btnRootKeygen, $btnRootDevPath)))) {
    foreach ($control in $entry[1]) {
        $tabRoot.Controls.Remove($control)
        $entry[0].Controls.Add($control)
    }
}

$lblRootNote = New-Object System.Windows.Forms.Label
$lblRootNote.Text = 'scrcpy --v4l2-sink and --v4l2-buffer are Linux only and are not built into the Windows scrcpy at all, ' +
    'so they have no button here.'
$lblRootNote.ForeColor = [System.Drawing.Color]::DimGray
$lblRootNote.Location = New-Object System.Drawing.Point(14, 338)
$lblRootNote.Size = New-Object System.Drawing.Size(860, 20)
$tabRoot.Controls.Add($lblRootNote)

# --- tab 5: screen (screenshot + touch forwarding) ---------------------------
$btnCapture = New-Object System.Windows.Forms.Button
$btnCapture.Text = 'Capture'
$btnCapture.Location = New-Object System.Drawing.Point(14, 8)
$btnCapture.Size = New-Object System.Drawing.Size(96, 28)
$grpScreen.Controls.Add($btnCapture)

$chkAutoShot = New-Object System.Windows.Forms.CheckBox
$chkAutoShot.Text = 'Auto'
$chkAutoShot.Location = New-Object System.Drawing.Point(118, 12)
$chkAutoShot.Size = New-Object System.Drawing.Size(56, 24)
$grpScreen.Controls.Add($chkAutoShot)

$numShotMs = New-Object System.Windows.Forms.NumericUpDown
$numShotMs.Minimum = 500
$numShotMs.Maximum = 30000
$numShotMs.Increment = 500
$numShotMs.Value = 2000
$numShotMs.Location = New-Object System.Drawing.Point(176, 9)
$numShotMs.Size = New-Object System.Drawing.Size(74, 24)
$grpScreen.Controls.Add($numShotMs)
$toolTip.SetToolTip($numShotMs, 'Milliseconds between automatic captures (one capture costs about 1.4 s, so lower values just run continuously)')

$btnSaveShot = New-Object System.Windows.Forms.Button
$btnSaveShot.Text = 'Save as...'
$btnSaveShot.Location = New-Object System.Drawing.Point(258, 8)
$btnSaveShot.Size = New-Object System.Drawing.Size(94, 28)
$grpScreen.Controls.Add($btnSaveShot)

$btnClearShot = New-Object System.Windows.Forms.Button
$btnClearShot.Text = 'Clear'
$btnClearShot.Location = New-Object System.Drawing.Point(310, 8)
$btnClearShot.Size = New-Object System.Drawing.Size(74, 26)
$grpScreen.Controls.Add($btnClearShot)
$toolTip.SetToolTip($btnClearShot, 'Drop the picture that is on screen right now')

$btnKeyBack = New-Object System.Windows.Forms.Button
$btnKeyBack.Text = 'Back'
$btnKeyBack.Location = New-Object System.Drawing.Point(366, 8)
$btnKeyBack.Size = New-Object System.Drawing.Size(70, 28)
$grpScreen.Controls.Add($btnKeyBack)

$btnKeyHome = New-Object System.Windows.Forms.Button
$btnKeyHome.Text = 'Home'
$btnKeyHome.Location = New-Object System.Drawing.Point(442, 8)
$btnKeyHome.Size = New-Object System.Drawing.Size(70, 28)
$grpScreen.Controls.Add($btnKeyHome)

$btnKeyRecents = New-Object System.Windows.Forms.Button
$btnKeyRecents.Text = 'Recents'
$btnKeyRecents.Location = New-Object System.Drawing.Point(518, 8)
$btnKeyRecents.Size = New-Object System.Drawing.Size(80, 28)
$grpScreen.Controls.Add($btnKeyRecents)

$btnKeyPower = New-Object System.Windows.Forms.Button
$btnKeyPower.Text = 'Power'
$btnKeyPower.Location = New-Object System.Drawing.Point(604, 8)
$btnKeyPower.Size = New-Object System.Drawing.Size(70, 28)
$grpScreen.Controls.Add($btnKeyPower)

$btnKeyVolUp = New-Object System.Windows.Forms.Button
$btnKeyVolUp.Text = 'Vol +'
$btnKeyVolUp.Location = New-Object System.Drawing.Point(680, 8)
$btnKeyVolUp.Size = New-Object System.Drawing.Size(62, 28)
$grpScreen.Controls.Add($btnKeyVolUp)

$btnKeyVolDown = New-Object System.Windows.Forms.Button
$btnKeyVolDown.Text = 'Vol -'
$btnKeyVolDown.Location = New-Object System.Drawing.Point(748, 8)
$btnKeyVolDown.Size = New-Object System.Drawing.Size(62, 28)
$grpScreen.Controls.Add($btnKeyVolDown)

$txtSendText = New-Object System.Windows.Forms.TextBox
$txtSendText.Location = New-Object System.Drawing.Point(14, 42)
$txtSendText.Size = New-Object System.Drawing.Size(560, 26)
$grpScreen.Controls.Add($txtSendText)
$toolTip.SetToolTip($txtSendText, 'Type here and press Send text to type on the phone')

$btnSendText = New-Object System.Windows.Forms.Button
$btnSendText.Text = 'Send text'
$btnSendText.Location = New-Object System.Drawing.Point(582, 41)
$btnSendText.Size = New-Object System.Drawing.Size(96, 28)
$grpScreen.Controls.Add($btnSendText)

$lblScreenInfo = New-Object System.Windows.Forms.Label
$lblScreenInfo.Text = 'no capture yet'
$lblScreenInfo.ForeColor = [System.Drawing.Color]::DimGray
$lblScreenInfo.Location = New-Object System.Drawing.Point(688, 46)
$lblScreenInfo.Size = New-Object System.Drawing.Size(180, 20)
$grpScreen.Controls.Add($lblScreenInfo)

$picScreen = New-Object System.Windows.Forms.PictureBox
$picScreen.SizeMode = 'Zoom'
$picScreen.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$picScreen.BorderStyle = 'FixedSingle'
$picScreen.Location = New-Object System.Drawing.Point(14, 76)
$picScreen.Size = New-Object System.Drawing.Size(854, 344)
$picScreen.Cursor = [System.Windows.Forms.Cursors]::Hand
$grpScreen.Controls.Add($picScreen)

$lblScreenHint = New-Object System.Windows.Forms.Label
$lblScreenHint.Text = "Click = tap  |  drag = swipe  |  hold = long press`r`nRight = Back  |  thumb back = Recents  |  thumb forward = notifications"
$lblScreenHint.ForeColor = [System.Drawing.Color]::DimGray
$lblScreenHint.Location = New-Object System.Drawing.Point(14, 424)
$lblScreenHint.Size = New-Object System.Drawing.Size(854, 20)
$grpScreen.Controls.Add($lblScreenHint)

# --- tab: installed apps -----------------------------------------------------
$lstApps = New-Object System.Windows.Forms.ListView
$lstApps.View = 'Details'
$lstApps.FullRowSelect = $true
$lstApps.MultiSelect = $true
$lstApps.HideSelection = $false
$lstApps.Location = New-Object System.Drawing.Point(12, 44)
$lstApps.Size = New-Object System.Drawing.Size(840, 240)
$null = $lstApps.Columns.Add('Package', 320)
$null = $lstApps.Columns.Add('Version', 110)
$null = $lstApps.Columns.Add('Type', 80)
$null = $lstApps.Columns.Add('State', 90)
# The name is added last, so SubItems[1..3] keep meaning version, type and
# state and every item's Text stays the package - the actions rely on both.
# It is only moved to the front on screen.
$null = $lstApps.Columns.Add('Name', 230)
$lstApps.Columns[4].DisplayIndex = 0
$tabApps.Controls.Add($lstApps)

$txtAppFilter = New-Object System.Windows.Forms.TextBox
$txtAppFilter.Location = New-Object System.Drawing.Point(12, 12)
$txtAppFilter.Size = New-Object System.Drawing.Size(200, 24)
$tabApps.Controls.Add($txtAppFilter)
$toolTip.SetToolTip($txtAppFilter, 'Type to filter the list by package name')

$chkAppsSystem = New-Object System.Windows.Forms.CheckBox
$chkAppsSystem.Text = 'include system'
$chkAppsSystem.Location = New-Object System.Drawing.Point(220, 14)
$chkAppsSystem.Size = New-Object System.Drawing.Size(120, 22)
$tabApps.Controls.Add($chkAppsSystem)

$btnAppsRefresh = New-Object System.Windows.Forms.Button
$btnAppsRefresh.Text = 'Refresh'
$btnAppsRefresh.Location = New-Object System.Drawing.Point(346, 10)
$btnAppsRefresh.Size = New-Object System.Drawing.Size(84, 26)
$tabApps.Controls.Add($btnAppsRefresh)

$lblAppsCount = New-Object System.Windows.Forms.Label
$lblAppsCount.Text = ''
$lblAppsCount.ForeColor = [System.Drawing.Color]::DimGray
$lblAppsCount.Location = New-Object System.Drawing.Point(440, 15)
$lblAppsCount.Size = New-Object System.Drawing.Size(240, 20)
$tabApps.Controls.Add($lblAppsCount)

$btnAppLaunch = New-Object System.Windows.Forms.Button
$btnAppLaunch.Text = 'Launch'
$btnAppLaunch.Location = New-Object System.Drawing.Point(12, 294)
$btnAppLaunch.Size = New-Object System.Drawing.Size(100, 28)
$tabApps.Controls.Add($btnAppLaunch)

$btnAppNewDisplay = New-Object System.Windows.Forms.Button
$btnAppNewDisplay.Text = 'Own scrcpy window'
$btnAppNewDisplay.Location = New-Object System.Drawing.Point(120, 294)
$btnAppNewDisplay.Size = New-Object System.Drawing.Size(160, 28)
$tabApps.Controls.Add($btnAppNewDisplay)
$toolTip.SetToolTip($btnAppNewDisplay, 'scrcpy --new-display --start-app: the app runs on its own virtual screen')

$btnAppStop = New-Object System.Windows.Forms.Button
$btnAppStop.Text = 'Force stop'
$btnAppStop.Location = New-Object System.Drawing.Point(288, 294)
$btnAppStop.Size = New-Object System.Drawing.Size(100, 28)
$tabApps.Controls.Add($btnAppStop)

$btnAppInfo = New-Object System.Windows.Forms.Button
$btnAppInfo.Text = 'App info'
$btnAppInfo.Location = New-Object System.Drawing.Point(396, 294)
$btnAppInfo.Size = New-Object System.Drawing.Size(100, 28)
$tabApps.Controls.Add($btnAppInfo)

$btnAppUninstall = New-Object System.Windows.Forms.Button
$btnAppUninstall.Text = 'Uninstall'
$btnAppUninstall.Location = New-Object System.Drawing.Point(504, 294)
$btnAppUninstall.Size = New-Object System.Drawing.Size(100, 28)
$tabApps.Controls.Add($btnAppUninstall)

$btnAppInstall = New-Object System.Windows.Forms.Button
$btnAppInstall.Text = 'Install APK...'
$btnAppInstall.Location = New-Object System.Drawing.Point(612, 294)
$btnAppInstall.Size = New-Object System.Drawing.Size(120, 28)
$tabApps.Controls.Add($btnAppInstall)

$btnAppExport = New-Object System.Windows.Forms.Button
$btnAppExport.Text = 'Export list...'
$btnAppExport.Location = New-Object System.Drawing.Point(740, 294)
$btnAppExport.Size = New-Object System.Drawing.Size(112, 28)
$tabApps.Controls.Add($btnAppExport)

# --- tab: contacts -----------------------------------------------------------
$lstContacts = New-Object System.Windows.Forms.ListView
$lstContacts.View = 'Details'
$lstContacts.FullRowSelect = $true
$lstContacts.MultiSelect = $true
$lstContacts.HideSelection = $false
$lstContacts.Location = New-Object System.Drawing.Point(12, 44)
$lstContacts.Size = New-Object System.Drawing.Size(840, 240)
$null = $lstContacts.Columns.Add('Name', 300)
$null = $lstContacts.Columns.Add('Number', 220)
$null = $lstContacts.Columns.Add('Contact id', 100)
$null = $lstContacts.Columns.Add('Raw id', 100)
$tabContacts.Controls.Add($lstContacts)

$txtContactFilter = New-Object System.Windows.Forms.TextBox
$txtContactFilter.Location = New-Object System.Drawing.Point(12, 12)
$txtContactFilter.Size = New-Object System.Drawing.Size(220, 24)
$tabContacts.Controls.Add($txtContactFilter)
$toolTip.SetToolTip($txtContactFilter, 'Filter by name or number')

$btnContactsRefresh = New-Object System.Windows.Forms.Button
$btnContactsRefresh.Text = 'Refresh'
$btnContactsRefresh.Location = New-Object System.Drawing.Point(240, 10)
$btnContactsRefresh.Size = New-Object System.Drawing.Size(84, 26)
$tabContacts.Controls.Add($btnContactsRefresh)

$lblContactsCount = New-Object System.Windows.Forms.Label
$lblContactsCount.Text = ''
$lblContactsCount.ForeColor = [System.Drawing.Color]::DimGray
$lblContactsCount.Location = New-Object System.Drawing.Point(334, 15)
$lblContactsCount.Size = New-Object System.Drawing.Size(300, 20)
$tabContacts.Controls.Add($lblContactsCount)

$btnContactAdd = New-Object System.Windows.Forms.Button
$btnContactAdd.Text = 'Add'
$btnContactAdd.Location = New-Object System.Drawing.Point(12, 294)
$btnContactAdd.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactAdd)

$btnContactEdit = New-Object System.Windows.Forms.Button
$btnContactEdit.Text = 'Edit'
$btnContactEdit.Location = New-Object System.Drawing.Point(110, 294)
$btnContactEdit.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactEdit)

$btnContactDelete = New-Object System.Windows.Forms.Button
$btnContactDelete.Text = 'Delete'
$btnContactDelete.Location = New-Object System.Drawing.Point(208, 294)
$btnContactDelete.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactDelete)

$btnContactCall = New-Object System.Windows.Forms.Button
$btnContactCall.Text = 'Call'
$btnContactCall.Location = New-Object System.Drawing.Point(306, 294)
$btnContactCall.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactCall)

$btnContactEndCall = New-Object System.Windows.Forms.Button
$btnContactEndCall.Text = 'End call'
$btnContactEndCall.Location = New-Object System.Drawing.Point(404, 294)
$btnContactEndCall.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactEndCall)

$btnContactCopy = New-Object System.Windows.Forms.Button
$btnContactCopy.Text = 'Copy'
$btnContactCopy.Location = New-Object System.Drawing.Point(502, 294)
$btnContactCopy.Size = New-Object System.Drawing.Size(90, 28)
$tabContacts.Controls.Add($btnContactCopy)

$btnContactExport = New-Object System.Windows.Forms.Button
$btnContactExport.Text = 'Export all...'
$btnContactExport.Location = New-Object System.Drawing.Point(600, 294)
$btnContactExport.Size = New-Object System.Drawing.Size(112, 28)
$tabContacts.Controls.Add($btnContactExport)

$lblDialNumber = New-Object System.Windows.Forms.Label
$lblDialNumber.Text = 'Dial'
$lblDialNumber.TextAlign = 'MiddleRight'
$lblDialNumber.Location = New-Object System.Drawing.Point(676, 306)
$lblDialNumber.Size = New-Object System.Drawing.Size(38, 20)
$tabContacts.Controls.Add($lblDialNumber)

$txtDialNumber = New-Object System.Windows.Forms.TextBox
$txtDialNumber.Location = New-Object System.Drawing.Point(720, 296)
$txtDialNumber.Size = New-Object System.Drawing.Size(132, 24)
$tabContacts.Controls.Add($txtDialNumber)
$toolTip.SetToolTip($txtDialNumber, 'Type a number here to call it directly with the Call button')

# --- tab: SMS ----------------------------------------------------------------
$lstSms = New-Object System.Windows.Forms.ListView
$lstSms.View = 'Details'
$lstSms.FullRowSelect = $true
$lstSms.MultiSelect = $true
$lstSms.HideSelection = $false
$lstSms.Location = New-Object System.Drawing.Point(12, 44)
$lstSms.Size = New-Object System.Drawing.Size(840, 200)
$null = $lstSms.Columns.Add('Date', 130)
$null = $lstSms.Columns.Add('Dir', 50)
$null = $lstSms.Columns.Add('Number', 150)
$null = $lstSms.Columns.Add('Message', 460)
$null = $lstSms.Columns.Add('id', 70)
$tabSms.Controls.Add($lstSms)

$txtSmsFilter = New-Object System.Windows.Forms.TextBox
$txtSmsFilter.Location = New-Object System.Drawing.Point(12, 12)
$txtSmsFilter.Size = New-Object System.Drawing.Size(220, 24)
$tabSms.Controls.Add($txtSmsFilter)
$toolTip.SetToolTip($txtSmsFilter, 'Filter by number or text')

$btnSmsRefresh = New-Object System.Windows.Forms.Button
$btnSmsRefresh.Text = 'Refresh'
$btnSmsRefresh.Location = New-Object System.Drawing.Point(240, 10)
$btnSmsRefresh.Size = New-Object System.Drawing.Size(84, 26)
$tabSms.Controls.Add($btnSmsRefresh)

$lblSmsCount = New-Object System.Windows.Forms.Label
$lblSmsCount.Text = ''
$lblSmsCount.ForeColor = [System.Drawing.Color]::DimGray
$lblSmsCount.Location = New-Object System.Drawing.Point(334, 15)
$lblSmsCount.Size = New-Object System.Drawing.Size(300, 20)
$tabSms.Controls.Add($lblSmsCount)

$lblSmsTo = New-Object System.Windows.Forms.Label
$lblSmsTo.Text = 'To'
$lblSmsTo.Location = New-Object System.Drawing.Point(12, 258)
$lblSmsTo.Size = New-Object System.Drawing.Size(24, 20)
$tabSms.Controls.Add($lblSmsTo)

$txtSmsTo = New-Object System.Windows.Forms.TextBox
$txtSmsTo.Location = New-Object System.Drawing.Point(38, 254)
$txtSmsTo.Size = New-Object System.Drawing.Size(180, 24)
$tabSms.Controls.Add($txtSmsTo)

$txtSmsBody = New-Object System.Windows.Forms.TextBox
$txtSmsBody.Location = New-Object System.Drawing.Point(226, 254)
$txtSmsBody.Size = New-Object System.Drawing.Size(500, 24)
$txtSmsBody.RightToLeft = 'No'
$tabSms.Controls.Add($txtSmsBody)
$toolTip.SetToolTip($txtSmsBody, 'Arabic works: the text is handed to the SMS app as an intent extra')

$btnSmsSend = New-Object System.Windows.Forms.Button
$btnSmsSend.Text = 'Send'
$btnSmsSend.Location = New-Object System.Drawing.Point(734, 253)
$btnSmsSend.Size = New-Object System.Drawing.Size(118, 26)
$tabSms.Controls.Add($btnSmsSend)

$chkSmsAutoSend = New-Object System.Windows.Forms.CheckBox
$chkSmsAutoSend.Text = 'tap Send on the phone automatically'
$chkSmsAutoSend.Checked = $true
$chkSmsAutoSend.Location = New-Object System.Drawing.Point(38, 286)
$chkSmsAutoSend.Size = New-Object System.Drawing.Size(280, 22)
$tabSms.Controls.Add($chkSmsAutoSend)
$toolTip.SetToolTip($chkSmsAutoSend, 'Android has no shell command that sends an SMS: the message is composed in the SMS app and its Send button is tapped')

$btnSmsCopy = New-Object System.Windows.Forms.Button
$btnSmsCopy.Text = 'Copy'
$btnSmsCopy.Location = New-Object System.Drawing.Point(330, 284)
$btnSmsCopy.Size = New-Object System.Drawing.Size(90, 28)
$tabSms.Controls.Add($btnSmsCopy)

$btnSmsDelete = New-Object System.Windows.Forms.Button
$btnSmsDelete.Text = 'Delete'
$btnSmsDelete.Location = New-Object System.Drawing.Point(428, 284)
$btnSmsDelete.Size = New-Object System.Drawing.Size(90, 28)
$tabSms.Controls.Add($btnSmsDelete)

$btnSmsEdit = New-Object System.Windows.Forms.Button
$btnSmsEdit.Text = 'Edit body'
$btnSmsEdit.Location = New-Object System.Drawing.Point(526, 284)
$btnSmsEdit.Size = New-Object System.Drawing.Size(90, 28)
$tabSms.Controls.Add($btnSmsEdit)

$btnSmsExport = New-Object System.Windows.Forms.Button
$btnSmsExport.Text = 'Export all...'
$btnSmsExport.Location = New-Object System.Drawing.Point(624, 284)
$btnSmsExport.Size = New-Object System.Drawing.Size(112, 28)
$tabSms.Controls.Add($btnSmsExport)

# --- tab: camera -------------------------------------------------------------
$script:cameraLabels = @{}

function New-CameraLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 60)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, ($Y + 3))
    $label.Size = New-Object System.Drawing.Size($Width, 20)
    $tabCamera.Controls.Add($label)
    $script:cameraLabels[$Text] = $label
}

New-CameraLabel -Text 'Camera' -X 16 -Y 16 -Width 52
$cmbCamera = New-Object System.Windows.Forms.ComboBox
$cmbCamera.DropDownStyle = 'DropDownList'
$cmbCamera.Location = New-Object System.Drawing.Point(72, 16)
$cmbCamera.Size = New-Object System.Drawing.Size(330, 24)
$null = $cmbCamera.Items.Add('press "List cameras"')
$cmbCamera.SelectedIndex = 0
$tabCamera.Controls.Add($cmbCamera)

$btnCameraList = New-Object System.Windows.Forms.Button
$btnCameraList.Text = 'List cameras'
$btnCameraList.Location = New-Object System.Drawing.Point(410, 15)
$btnCameraList.Size = New-Object System.Drawing.Size(110, 26)
$tabCamera.Controls.Add($btnCameraList)

New-CameraLabel -Text 'Facing' -X 532 -Y 16 -Width 46
$cmbCameraFacing = New-Object System.Windows.Forms.ComboBox
$cmbCameraFacing.DropDownStyle = 'DropDownList'
$cmbCameraFacing.Location = New-Object System.Drawing.Point(580, 16)
$cmbCameraFacing.Size = New-Object System.Drawing.Size(110, 24)
$null = $cmbCameraFacing.Items.AddRange(@('by id', 'back', 'front', 'external'))
$cmbCameraFacing.SelectedIndex = 0
$tabCamera.Controls.Add($cmbCameraFacing)
$toolTip.SetToolTip($cmbCameraFacing, 'Pick a camera by id, or let scrcpy choose the first one facing this way')

New-CameraLabel -Text 'Size' -X 16 -Y 52 -Width 40
$cmbCameraSize = New-Object System.Windows.Forms.ComboBox
$cmbCameraSize.DropDownStyle = 'DropDown'
$cmbCameraSize.Location = New-Object System.Drawing.Point(72, 52)
$cmbCameraSize.Size = New-Object System.Drawing.Size(140, 24)
$null = $cmbCameraSize.Items.AddRange(@('1920x1080', '1280x720', '3840x2160', '640x480', 'sensor max'))
$cmbCameraSize.Text = '1920x1080'
$tabCamera.Controls.Add($cmbCameraSize)

New-CameraLabel -Text 'FPS' -X 224 -Y 52 -Width 32
$cmbCameraFps = New-Object System.Windows.Forms.ComboBox
$cmbCameraFps.DropDownStyle = 'DropDown'
$cmbCameraFps.Location = New-Object System.Drawing.Point(260, 52)
$cmbCameraFps.Size = New-Object System.Drawing.Size(80, 24)
$null = $cmbCameraFps.Items.AddRange(@('30', '24', '20', '15', '10'))
$cmbCameraFps.Text = '30'
$tabCamera.Controls.Add($cmbCameraFps)

New-CameraLabel -Text 'Aspect' -X 352 -Y 52 -Width 48
$cmbCameraAr = New-Object System.Windows.Forms.ComboBox
$cmbCameraAr.DropDownStyle = 'DropDown'
$cmbCameraAr.Location = New-Object System.Drawing.Point(404, 52)
$cmbCameraAr.Size = New-Object System.Drawing.Size(100, 24)
$null = $cmbCameraAr.Items.AddRange(@('(size)', '16:9', '4:3', '1:1'))
$cmbCameraAr.Text = '(size)'
$tabCamera.Controls.Add($cmbCameraAr)
$toolTip.SetToolTip($cmbCameraAr, 'Aspect ratio instead of an explicit size - scrcpy accepts only one of the two')

$chkCameraHighSpeed = New-Object System.Windows.Forms.CheckBox
$chkCameraHighSpeed.Text = 'high speed'
$chkCameraHighSpeed.Location = New-Object System.Drawing.Point(520, 53)
$chkCameraHighSpeed.Size = New-Object System.Drawing.Size(100, 22)
$tabCamera.Controls.Add($chkCameraHighSpeed)
$toolTip.SetToolTip($chkCameraHighSpeed, 'High frame rate capture (fewer sizes are available)')

$chkCameraTorch = New-Object System.Windows.Forms.CheckBox
$chkCameraTorch.Text = 'torch'
$chkCameraTorch.Location = New-Object System.Drawing.Point(628, 53)
$chkCameraTorch.Size = New-Object System.Drawing.Size(64, 22)
$tabCamera.Controls.Add($chkCameraTorch)
$toolTip.SetToolTip($chkCameraTorch, 'Turn the flash on while the camera streams')

$chkCameraMic = New-Object System.Windows.Forms.CheckBox
$chkCameraMic.Text = 'record microphone too'
$chkCameraMic.Location = New-Object System.Drawing.Point(18, 88)
$chkCameraMic.Size = New-Object System.Drawing.Size(180, 22)
$tabCamera.Controls.Add($chkCameraMic)

$chkCameraRecord = New-Object System.Windows.Forms.CheckBox
$chkCameraRecord.Text = 'Record to'
$chkCameraRecord.Location = New-Object System.Drawing.Point(206, 88)
$chkCameraRecord.Size = New-Object System.Drawing.Size(90, 22)
$tabCamera.Controls.Add($chkCameraRecord)

$txtCameraRecord = New-Object System.Windows.Forms.TextBox
$txtCameraRecord.Location = New-Object System.Drawing.Point(300, 86)
$txtCameraRecord.Size = New-Object System.Drawing.Size(310, 24)
$tabCamera.Controls.Add($txtCameraRecord)

$btnCameraBrowse = New-Object System.Windows.Forms.Button
$btnCameraBrowse.Text = 'Browse...'
$btnCameraBrowse.Location = New-Object System.Drawing.Point(618, 85)
$btnCameraBrowse.Size = New-Object System.Drawing.Size(90, 26)
$tabCamera.Controls.Add($btnCameraBrowse)


$btnCameraStart = New-Object System.Windows.Forms.Button
$btnCameraStart.Text = 'Start camera'
$btnCameraStart.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnCameraStart.Location = New-Object System.Drawing.Point(18, 124)
$btnCameraStart.Size = New-Object System.Drawing.Size(140, 34)
$tabCamera.Controls.Add($btnCameraStart)

$btnCameraFront = New-Object System.Windows.Forms.Button
$btnCameraFront.Text = 'Front'
$btnCameraFront.Location = New-Object System.Drawing.Point(166, 124)
$btnCameraFront.Size = New-Object System.Drawing.Size(90, 34)
$tabCamera.Controls.Add($btnCameraFront)

$btnCameraBack = New-Object System.Windows.Forms.Button
$btnCameraBack.Text = 'Back'
$btnCameraBack.Location = New-Object System.Drawing.Point(264, 124)
$btnCameraBack.Size = New-Object System.Drawing.Size(90, 34)
$tabCamera.Controls.Add($btnCameraBack)

$btnCameraStop = New-Object System.Windows.Forms.Button
$btnCameraStop.Text = 'Stop camera'
$btnCameraStop.Location = New-Object System.Drawing.Point(362, 124)
$btnCameraStop.Size = New-Object System.Drawing.Size(120, 34)
$tabCamera.Controls.Add($btnCameraStop)

$btnCameraCommand = New-Object System.Windows.Forms.Button
$btnCameraCommand.Text = 'Show command'
$btnCameraCommand.Location = New-Object System.Drawing.Point(490, 124)
$btnCameraCommand.Size = New-Object System.Drawing.Size(130, 34)
$tabCamera.Controls.Add($btnCameraCommand)

$lblCameraHint = New-Object System.Windows.Forms.Label
$lblCameraHint.Text = 'Streams the phone camera to a window on the PC (Android 12+). The phone screen stays untouched.'
$lblCameraHint.ForeColor = [System.Drawing.Color]::DimGray
$lblCameraHint.Location = New-Object System.Drawing.Point(18, 170)
$lblCameraHint.Size = New-Object System.Drawing.Size(700, 20)
$tabCamera.Controls.Add($lblCameraHint)

# The camera settings and the microphone are two different jobs that happen to
# share a tab, so each gets its own box.
$grpCamera = New-Object System.Windows.Forms.GroupBox
$grpCamera.Text = 'Camera  (phone camera as a video source, Android 12+)'
$tabCamera.Controls.Add($grpCamera)

foreach ($control in @($cmbCamera, $btnCameraList, $cmbCameraFacing, $cmbCameraSize, $cmbCameraFps,
        $cmbCameraAr, $chkCameraHighSpeed, $chkCameraTorch, $chkCameraMic, $chkCameraRecord,
        $txtCameraRecord, $btnCameraBrowse, $lblCameraHint)) {
    $tabCamera.Controls.Remove($control)
    $grpCamera.Controls.Add($control)
}
foreach ($name in @('Camera', 'Facing', 'Size', 'FPS', 'Aspect')) {
    $label = $script:cameraLabels[$name]
    if ($label) {
        $tabCamera.Controls.Remove($label)
        $grpCamera.Controls.Add($label)
    }
}

$btnListEncoders = New-Object System.Windows.Forms.Button
$btnListEncoders.Text = 'Codecs'
$btnListEncoders.Location = New-Object System.Drawing.Point(700, 22)
$btnListEncoders.Size = New-Object System.Drawing.Size(80, 26)
$grpVideo.Controls.Add($btnListEncoders)
$toolTip.SetToolTip($btnListEncoders, 'Ask the phone which codecs it really has, and fill the lists with them')

$lblCameraZoom = New-Object System.Windows.Forms.Label
$lblCameraZoom.Text = 'Zoom'
$lblCameraZoom.Location = New-Object System.Drawing.Point(12, 88)
$lblCameraZoom.Size = New-Object System.Drawing.Size(40, 20)
$grpCamera.Controls.Add($lblCameraZoom)

$cmbCameraZoom = New-Object System.Windows.Forms.ComboBox
$cmbCameraZoom.DropDownStyle = 'DropDown'
$cmbCameraZoom.Location = New-Object System.Drawing.Point(56, 84)
$cmbCameraZoom.Size = New-Object System.Drawing.Size(70, 24)
$null = $cmbCameraZoom.Items.AddRange(@('1', '2', '3', '5', '10'))
$cmbCameraZoom.Text = '1'
$grpCamera.Controls.Add($cmbCameraZoom)
$toolTip.SetToolTip($cmbCameraZoom, 'scrcpy --camera-zoom, 1 is no zoom. The camera must support it')

$btnListCameraSizes = New-Object System.Windows.Forms.Button
$btnListCameraSizes.Text = 'Sizes'
$btnListCameraSizes.Location = New-Object System.Drawing.Point(348, 52)
$btnListCameraSizes.Size = New-Object System.Drawing.Size(70, 26)
$grpCamera.Controls.Add($btnListCameraSizes)
$toolTip.SetToolTip($btnListCameraSizes, 'Ask the phone which camera sizes it supports')

# --- tab: file browser / transfer --------------------------------------------
$btnFileUp = New-Object System.Windows.Forms.Button
$btnFileUp.Text = 'Up'
$btnFileUp.Location = New-Object System.Drawing.Point(12, 10)
$btnFileUp.Size = New-Object System.Drawing.Size(50, 26)
$tabFiles.Controls.Add($btnFileUp)

$txtFilePath = New-Object System.Windows.Forms.TextBox
$txtFilePath.Text = '/sdcard'
$txtFilePath.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtFilePath.Location = New-Object System.Drawing.Point(70, 11)
$txtFilePath.Size = New-Object System.Drawing.Size(430, 24)
$tabFiles.Controls.Add($txtFilePath)
$toolTip.SetToolTip($txtFilePath, 'Path on the phone - press Enter to open it')

$btnFileGo = New-Object System.Windows.Forms.Button
$btnFileGo.Text = 'Go'
$btnFileGo.Location = New-Object System.Drawing.Point(508, 10)
$btnFileGo.Size = New-Object System.Drawing.Size(50, 26)
$tabFiles.Controls.Add($btnFileGo)

$cmbFileQuick = New-Object System.Windows.Forms.ComboBox
$cmbFileQuick.DropDownStyle = 'DropDownList'
$cmbFileQuick.Location = New-Object System.Drawing.Point(566, 11)
$cmbFileQuick.Size = New-Object System.Drawing.Size(150, 24)
$null = $cmbFileQuick.Items.AddRange(@('go to...', '/sdcard', '/sdcard/Download', '/sdcard/DCIM/Camera',
    '/sdcard/Pictures', '/sdcard/Movies', '/sdcard/Music', '/sdcard/Documents', '/sdcard/Android/media',
    '/storage', '/data/local/tmp', '/system'))
$cmbFileQuick.SelectedIndex = 0
$tabFiles.Controls.Add($cmbFileQuick)

$chkFileHidden = New-Object System.Windows.Forms.CheckBox
$chkFileHidden.Text = 'hidden'
$chkFileHidden.Checked = $true
$chkFileHidden.Location = New-Object System.Drawing.Point(724, 13)
$chkFileHidden.Size = New-Object System.Drawing.Size(70, 22)
$tabFiles.Controls.Add($chkFileHidden)

$txtFileSearch = New-Object System.Windows.Forms.TextBox
$txtFileSearch.Location = New-Object System.Drawing.Point(70, 43)
$txtFileSearch.Size = New-Object System.Drawing.Size(300, 24)
$tabFiles.Controls.Add($txtFileSearch)
$toolTip.SetToolTip($txtFileSearch, 'Type to filter this folder; press Enter or "Search here" to look inside subfolders too')

$lblFileSearch = New-Object System.Windows.Forms.Label
$lblFileSearch.Text = 'Search'
$lblFileSearch.Location = New-Object System.Drawing.Point(14, 46)
$lblFileSearch.Size = New-Object System.Drawing.Size(50, 20)
$tabFiles.Controls.Add($lblFileSearch)

$btnFileSearch = New-Object System.Windows.Forms.Button
$btnFileSearch.Text = 'Search here'
$btnFileSearch.Location = New-Object System.Drawing.Point(378, 42)
$btnFileSearch.Size = New-Object System.Drawing.Size(110, 26)
$tabFiles.Controls.Add($btnFileSearch)
$toolTip.SetToolTip($btnFileSearch, 'Search the current folder and everything under it')

$btnFileRecent = New-Object System.Windows.Forms.Button
$btnFileRecent.Text = 'Recent files'
$btnFileRecent.Location = New-Object System.Drawing.Point(576, 42)
$btnFileRecent.Size = New-Object System.Drawing.Size(110, 26)
$tabFiles.Controls.Add($btnFileRecent)
$toolTip.SetToolTip($btnFileRecent, 'Everything created or changed on the phone within the chosen window, wherever it lives')

$cmbFileRecent = New-Object System.Windows.Forms.ComboBox
$cmbFileRecent.DropDownStyle = 'DropDownList'
$cmbFileRecent.Location = New-Object System.Drawing.Point(694, 43)
$cmbFileRecent.Size = New-Object System.Drawing.Size(110, 24)
$null = $cmbFileRecent.Items.AddRange(@('today', 'last 2 days', 'last week', 'last 30 days'))
$cmbFileRecent.SelectedIndex = 0
$tabFiles.Controls.Add($cmbFileRecent)

$btnFileSearchClear = New-Object System.Windows.Forms.Button
$btnFileSearchClear.Text = 'Clear'
$btnFileSearchClear.Location = New-Object System.Drawing.Point(496, 42)
$btnFileSearchClear.Size = New-Object System.Drawing.Size(70, 26)
$tabFiles.Controls.Add($btnFileSearchClear)

$lstFiles = New-Object System.Windows.Forms.ListView
$lstFiles.View = 'Details'
$lstFiles.FullRowSelect = $true
$lstFiles.MultiSelect = $true
$lstFiles.HideSelection = $false
$lstFiles.Location = New-Object System.Drawing.Point(12, 76)
$lstFiles.Size = New-Object System.Drawing.Size(840, 220)
$null = $lstFiles.Columns.Add('Name', 330)
$null = $lstFiles.Columns.Add('Type', 70)
$null = $lstFiles.Columns.Add('Size', 100)
$null = $lstFiles.Columns.Add('Modified', 140)
$null = $lstFiles.Columns.Add('Permissions', 110)
$null = $lstFiles.Columns.Add('Owner', 100)
$tabFiles.Controls.Add($lstFiles)

$btnFileSelectAll = New-Object System.Windows.Forms.Button
$btnFileSelectAll.Text = 'Select all'
$btnFileSelectAll.Location = New-Object System.Drawing.Point(12, 270)
$btnFileSelectAll.Size = New-Object System.Drawing.Size(92, 26)
$tabFiles.Controls.Add($btnFileSelectAll)
$toolTip.SetToolTip($btnFileSelectAll, 'Select every row in the list (Ctrl+A)')

$btnFileSelectNone = New-Object System.Windows.Forms.Button
$btnFileSelectNone.Text = 'None'
$btnFileSelectNone.Location = New-Object System.Drawing.Point(110, 270)
$btnFileSelectNone.Size = New-Object System.Drawing.Size(58, 26)
$tabFiles.Controls.Add($btnFileSelectNone)
$toolTip.SetToolTip($btnFileSelectNone, 'Clear the selection (Esc)')

$btnFileSelectInvert = New-Object System.Windows.Forms.Button
$btnFileSelectInvert.Text = 'Invert'
$btnFileSelectInvert.Location = New-Object System.Drawing.Point(174, 270)
$btnFileSelectInvert.Size = New-Object System.Drawing.Size(62, 26)
$tabFiles.Controls.Add($btnFileSelectInvert)
$toolTip.SetToolTip($btnFileSelectInvert, 'Select what is not selected right now')

$lblFileLocal = New-Object System.Windows.Forms.Label
$lblFileLocal.Text = 'PC folder'
$lblFileLocal.Location = New-Object System.Drawing.Point(12, 274)
$lblFileLocal.Size = New-Object System.Drawing.Size(62, 20)
$tabFiles.Controls.Add($lblFileLocal)

$txtFileLocal = New-Object System.Windows.Forms.TextBox
$txtFileLocal.Text = [Environment]::GetFolderPath('MyDocuments')
$txtFileLocal.Location = New-Object System.Drawing.Point(78, 271)
$txtFileLocal.Size = New-Object System.Drawing.Size(500, 24)
$tabFiles.Controls.Add($txtFileLocal)
$toolTip.SetToolTip($txtFileLocal, 'Where downloads are saved on this PC')

$btnFileLocalBrowse = New-Object System.Windows.Forms.Button
$btnFileLocalBrowse.Text = 'Browse...'
$btnFileLocalBrowse.Location = New-Object System.Drawing.Point(586, 270)
$btnFileLocalBrowse.Size = New-Object System.Drawing.Size(90, 26)
$tabFiles.Controls.Add($btnFileLocalBrowse)

$btnFileOpenLocal = New-Object System.Windows.Forms.Button
$btnFileOpenLocal.Text = 'Open folder'
$btnFileOpenLocal.Location = New-Object System.Drawing.Point(684, 270)
$btnFileOpenLocal.Size = New-Object System.Drawing.Size(100, 26)
$tabFiles.Controls.Add($btnFileOpenLocal)

$btnFileDownload = New-Object System.Windows.Forms.Button
$btnFileDownload.Text = 'Download'
$btnFileDownload.Location = New-Object System.Drawing.Point(12, 304)
$btnFileDownload.Size = New-Object System.Drawing.Size(100, 28)
$tabFiles.Controls.Add($btnFileDownload)
$toolTip.SetToolTip($btnFileDownload, 'adb pull the selected files into the PC folder')

$btnFileUpload = New-Object System.Windows.Forms.Button
$btnFileUpload.Text = 'Upload...'
$btnFileUpload.Location = New-Object System.Drawing.Point(120, 304)
$btnFileUpload.Size = New-Object System.Drawing.Size(100, 28)
$tabFiles.Controls.Add($btnFileUpload)

$btnFileNewDir = New-Object System.Windows.Forms.Button
$btnFileNewDir.Text = 'New folder'
$btnFileNewDir.Location = New-Object System.Drawing.Point(228, 304)
$btnFileNewDir.Size = New-Object System.Drawing.Size(100, 28)
$tabFiles.Controls.Add($btnFileNewDir)

$btnFileRename = New-Object System.Windows.Forms.Button
$btnFileRename.Text = 'Rename'
$btnFileRename.Location = New-Object System.Drawing.Point(336, 304)
$btnFileRename.Size = New-Object System.Drawing.Size(90, 28)
$tabFiles.Controls.Add($btnFileRename)

$btnFileDelete = New-Object System.Windows.Forms.Button
$btnFileDelete.Text = 'Delete'
$btnFileDelete.Location = New-Object System.Drawing.Point(434, 304)
$btnFileDelete.Size = New-Object System.Drawing.Size(90, 28)
$tabFiles.Controls.Add($btnFileDelete)

$btnFileOpenPhone = New-Object System.Windows.Forms.Button
$btnFileOpenPhone.Text = 'Open on phone'
$btnFileOpenPhone.Location = New-Object System.Drawing.Point(532, 304)
$btnFileOpenPhone.Size = New-Object System.Drawing.Size(120, 28)
$tabFiles.Controls.Add($btnFileOpenPhone)

$btnFileMoveToPc = New-Object System.Windows.Forms.Button
$btnFileMoveToPc.Text = 'Move to PC'
$btnFileMoveToPc.Location = New-Object System.Drawing.Point(660, 304)
$btnFileMoveToPc.Size = New-Object System.Drawing.Size(110, 28)
$tabFiles.Controls.Add($btnFileMoveToPc)
$toolTip.SetToolTip($btnFileMoveToPc, 'Download, verify the copy, then delete it from the phone')

$btnFileMoveToPhone = New-Object System.Windows.Forms.Button
$btnFileMoveToPhone.Text = 'Move to phone'
$btnFileMoveToPhone.Location = New-Object System.Drawing.Point(778, 304)
$btnFileMoveToPhone.Size = New-Object System.Drawing.Size(120, 28)
$tabFiles.Controls.Add($btnFileMoveToPhone)
$toolTip.SetToolTip($btnFileMoveToPhone, 'Upload, verify it arrived, then delete the file from this PC')

$btnFileCopyPath = New-Object System.Windows.Forms.Button
$btnFileCopyPath.Text = 'Copy path'
$btnFileCopyPath.Location = New-Object System.Drawing.Point(660, 304)
$btnFileCopyPath.Size = New-Object System.Drawing.Size(100, 28)
$tabFiles.Controls.Add($btnFileCopyPath)

$chkFileFoldersFirst = New-Object System.Windows.Forms.CheckBox
$chkFileFoldersFirst.Text = 'folders first'
$chkFileFoldersFirst.Checked = $true
$chkFileFoldersFirst.Location = New-Object System.Drawing.Point(724, 13)
$chkFileFoldersFirst.Size = New-Object System.Drawing.Size(104, 22)
$tabFiles.Controls.Add($chkFileFoldersFirst)

$btnFileCompress = New-Object System.Windows.Forms.Button
$btnFileCompress.Text = 'Compress'
$btnFileCompress.Location = New-Object System.Drawing.Point(12, 336)
$btnFileCompress.Size = New-Object System.Drawing.Size(100, 28)
$tabFiles.Controls.Add($btnFileCompress)
$toolTip.SetToolTip($btnFileCompress, 'Pack the selected items into a .tar.gz on the phone itself')

$btnFileExtract = New-Object System.Windows.Forms.Button
$btnFileExtract.Text = 'Extract'
$btnFileExtract.Location = New-Object System.Drawing.Point(120, 336)
$btnFileExtract.Size = New-Object System.Drawing.Size(90, 28)
$tabFiles.Controls.Add($btnFileExtract)
$toolTip.SetToolTip($btnFileExtract, 'Unpack a .zip, .tar, .tar.gz or .gz on the phone itself')

$btnFilePreview = New-Object System.Windows.Forms.Button
$btnFilePreview.Text = 'Preview'
$btnFilePreview.Location = New-Object System.Drawing.Point(216, 336)
$btnFilePreview.Size = New-Object System.Drawing.Size(90, 28)
$tabFiles.Controls.Add($btnFilePreview)
$toolTip.SetToolTip($btnFilePreview, 'Look at a picture or a text file without saving it on this PC')

$lblFileSpace = New-Object System.Windows.Forms.Label
$lblFileSpace.Text = ''
$lblFileSpace.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblFileSpace.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$lblFileSpace.Location = New-Object System.Drawing.Point(14, 300)
$lblFileSpace.Size = New-Object System.Drawing.Size(700, 18)
$tabFiles.Controls.Add($lblFileSpace)
$toolTip.SetToolTip($lblFileSpace, 'Space on the volume that holds the folder on screen')

# each call parenthesised: a bare comma would bind to -Parent and pass an array
$fileRules = @(
    (New-RowSeparator -Parent $tabFiles),
    (New-RowSeparator -Parent $tabFiles),
    (New-RowSeparator -Parent $tabFiles)
)

$prgFile = New-Object System.Windows.Forms.ProgressBar
$prgFile.Minimum = 0
$prgFile.Maximum = 1000
$prgFile.Visible = $false
$prgFile.Location = New-Object System.Drawing.Point(14, 300)
$prgFile.Size = New-Object System.Drawing.Size(300, 18)
$tabFiles.Controls.Add($prgFile)

$lblFileProgress = New-Object System.Windows.Forms.Label
$lblFileProgress.Text = ''
$lblFileProgress.Visible = $false
$lblFileProgress.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$lblFileProgress.Location = New-Object System.Drawing.Point(322, 300)
$lblFileProgress.Size = New-Object System.Drawing.Size(420, 18)
$tabFiles.Controls.Add($lblFileProgress)

$btnFileCancel = New-Object System.Windows.Forms.Button
$btnFileCancel.Text = 'Cancel'
$btnFileCancel.Visible = $false
$btnFileCancel.Location = New-Object System.Drawing.Point(750, 296)
$btnFileCancel.Size = New-Object System.Drawing.Size(80, 24)
$tabFiles.Controls.Add($btnFileCancel)
$toolTip.SetToolTip($btnFileCancel, 'Stop the transfer and remove the half written file')

$lblFileInfo = New-Object System.Windows.Forms.Label
$lblFileInfo.Text = ''
$lblFileInfo.ForeColor = [System.Drawing.Color]::DimGray
$lblFileInfo.Location = New-Object System.Drawing.Point(802, 14)
$lblFileInfo.Size = New-Object System.Drawing.Size(120, 20)
$tabFiles.Controls.Add($lblFileInfo)


# --- tab: Wi-Fi ---------------------------------------------------------------
$lstWifi = New-Object System.Windows.Forms.ListView
$lstWifi.View = 'Details'
$lstWifi.FullRowSelect = $true
$lstWifi.HideSelection = $false
$lstWifi.Location = New-Object System.Drawing.Point(12, 44)
$lstWifi.Size = New-Object System.Drawing.Size(840, 250)
$null = $lstWifi.Columns.Add('SSID', 300)
$null = $lstWifi.Columns.Add('Security', 130)
$null = $lstWifi.Columns.Add('Signal', 90)
$null = $lstWifi.Columns.Add('BSSID', 160)
$null = $lstWifi.Columns.Add('Saved id', 80)
$tabWifi.Controls.Add($lstWifi)

$lblWifiState = New-Object System.Windows.Forms.Label
$lblWifiState.Text = 'Wi-Fi: unknown'
$lblWifiState.Location = New-Object System.Drawing.Point(14, 16)
$lblWifiState.Size = New-Object System.Drawing.Size(400, 20)
$tabWifi.Controls.Add($lblWifiState)

$btnWifiOnTab = New-Object System.Windows.Forms.Button
$btnWifiOnTab.Text = 'Wi-Fi on'
$btnWifiOnTab.Location = New-Object System.Drawing.Point(430, 10)
$btnWifiOnTab.Size = New-Object System.Drawing.Size(90, 28)
$tabWifi.Controls.Add($btnWifiOnTab)

$btnWifiOffTab = New-Object System.Windows.Forms.Button
$btnWifiOffTab.Text = 'Wi-Fi off'
$btnWifiOffTab.Location = New-Object System.Drawing.Point(526, 10)
$btnWifiOffTab.Size = New-Object System.Drawing.Size(90, 28)
$tabWifi.Controls.Add($btnWifiOffTab)

$btnWifiScan = New-Object System.Windows.Forms.Button
$btnWifiScan.Text = 'Scan'
$btnWifiScan.Location = New-Object System.Drawing.Point(622, 10)
$btnWifiScan.Size = New-Object System.Drawing.Size(80, 28)
$tabWifi.Controls.Add($btnWifiScan)
$toolTip.SetToolTip($btnWifiScan, 'Ask the phone to scan and list what it can see')

$btnWifiSaved = New-Object System.Windows.Forms.Button
$btnWifiSaved.Text = 'Saved networks'
$btnWifiSaved.Location = New-Object System.Drawing.Point(708, 10)
$btnWifiSaved.Size = New-Object System.Drawing.Size(120, 28)
$tabWifi.Controls.Add($btnWifiSaved)

$lblWifiPass = New-Object System.Windows.Forms.Label
$lblWifiPass.Text = 'Password'
$lblWifiPass.Location = New-Object System.Drawing.Point(14, 306)
$lblWifiPass.Size = New-Object System.Drawing.Size(64, 20)
$tabWifi.Controls.Add($lblWifiPass)

$txtWifiPass = New-Object System.Windows.Forms.TextBox
$txtWifiPass.Location = New-Object System.Drawing.Point(82, 303)
$txtWifiPass.Size = New-Object System.Drawing.Size(200, 24)
$tabWifi.Controls.Add($txtWifiPass)
$toolTip.SetToolTip($txtWifiPass, 'Only needed when joining a network the phone has not saved')

$chkWifiShowPass = New-Object System.Windows.Forms.CheckBox
$chkWifiShowPass.Text = 'show'
$chkWifiShowPass.Location = New-Object System.Drawing.Point(290, 305)
$chkWifiShowPass.Size = New-Object System.Drawing.Size(60, 22)
$tabWifi.Controls.Add($chkWifiShowPass)

$btnWifiConnect = New-Object System.Windows.Forms.Button
$btnWifiConnect.Text = 'Connect'
$btnWifiConnect.Location = New-Object System.Drawing.Point(356, 302)
$btnWifiConnect.Size = New-Object System.Drawing.Size(100, 28)
$tabWifi.Controls.Add($btnWifiConnect)

$btnWifiForget = New-Object System.Windows.Forms.Button
$btnWifiForget.Text = 'Forget'
$btnWifiForget.Location = New-Object System.Drawing.Point(464, 302)
$btnWifiForget.Size = New-Object System.Drawing.Size(90, 28)
$tabWifi.Controls.Add($btnWifiForget)
$toolTip.SetToolTip($btnWifiForget, 'Remove a saved network - pick a row that has a saved id')

$btnWifiStatus = New-Object System.Windows.Forms.Button
$btnWifiStatus.Text = 'Status'
$btnWifiStatus.Location = New-Object System.Drawing.Point(562, 302)
$btnWifiStatus.Size = New-Object System.Drawing.Size(90, 28)
$tabWifi.Controls.Add($btnWifiStatus)

$btnWifiSettings = New-Object System.Windows.Forms.Button
$btnWifiSettings.Text = 'Wi-Fi settings'
$btnWifiSettings.Location = New-Object System.Drawing.Point(660, 302)
$btnWifiSettings.Size = New-Object System.Drawing.Size(120, 28)
$tabWifi.Controls.Add($btnWifiSettings)
$toolTip.SetToolTip($btnWifiSettings, 'Open the Wi-Fi screen on the phone itself')

# --- tab: Bluetooth -----------------------------------------------------------
$lstBt = New-Object System.Windows.Forms.ListView
$lstBt.View = 'Details'
$lstBt.FullRowSelect = $true
$lstBt.HideSelection = $false
$lstBt.Location = New-Object System.Drawing.Point(12, 44)
$lstBt.Size = New-Object System.Drawing.Size(840, 250)
$null = $lstBt.Columns.Add('Name', 320)
$null = $lstBt.Columns.Add('Address', 180)
$null = $lstBt.Columns.Add('Bond', 120)
$tabBt.Controls.Add($lstBt)

$lblBtState = New-Object System.Windows.Forms.Label
$lblBtState.Text = 'Bluetooth: unknown'
$lblBtState.Location = New-Object System.Drawing.Point(14, 16)
$lblBtState.Size = New-Object System.Drawing.Size(400, 20)
$tabBt.Controls.Add($lblBtState)

$btnBtOnTab = New-Object System.Windows.Forms.Button
$btnBtOnTab.Text = 'Bluetooth on'
$btnBtOnTab.Location = New-Object System.Drawing.Point(500, 10)
$btnBtOnTab.Size = New-Object System.Drawing.Size(110, 28)
$tabBt.Controls.Add($btnBtOnTab)

$btnBtOffTab = New-Object System.Windows.Forms.Button
$btnBtOffTab.Text = 'Bluetooth off'
$btnBtOffTab.Location = New-Object System.Drawing.Point(616, 10)
$btnBtOffTab.Size = New-Object System.Drawing.Size(110, 28)
$tabBt.Controls.Add($btnBtOffTab)

$btnBtRefresh = New-Object System.Windows.Forms.Button
$btnBtRefresh.Text = 'Refresh'
$btnBtRefresh.Location = New-Object System.Drawing.Point(732, 10)
$btnBtRefresh.Size = New-Object System.Drawing.Size(96, 28)
$tabBt.Controls.Add($btnBtRefresh)

$btnBtSettings = New-Object System.Windows.Forms.Button
$btnBtSettings.Text = 'Bluetooth settings'
$btnBtSettings.Location = New-Object System.Drawing.Point(12, 302)
$btnBtSettings.Size = New-Object System.Drawing.Size(150, 28)
$tabBt.Controls.Add($btnBtSettings)
$toolTip.SetToolTip($btnBtSettings, 'Pairing and connecting happen on the phone - this opens that screen')

$btnBtCopy = New-Object System.Windows.Forms.Button
$btnBtCopy.Text = 'Copy address'
$btnBtCopy.Location = New-Object System.Drawing.Point(170, 302)
$btnBtCopy.Size = New-Object System.Drawing.Size(120, 28)
$tabBt.Controls.Add($btnBtCopy)

$lblBtHint = New-Object System.Windows.Forms.Label
$lblBtHint.Text = 'Android has no adb command that pairs or connects a Bluetooth device; the radio and the paired list are all it exposes.'
$lblBtHint.ForeColor = [System.Drawing.Color]::DimGray
$lblBtHint.Location = New-Object System.Drawing.Point(300, 308)
$lblBtHint.Size = New-Object System.Drawing.Size(540, 20)
$tabBt.Controls.Add($lblBtHint)

# --- tab: NFC -----------------------------------------------------------------
$lblNfcState = New-Object System.Windows.Forms.Label
$lblNfcState.Text = 'NFC: unknown'
$lblNfcState.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblNfcState.Location = New-Object System.Drawing.Point(18, 24)
$lblNfcState.Size = New-Object System.Drawing.Size(420, 28)
$tabNfc.Controls.Add($lblNfcState)

$btnNfcOn = New-Object System.Windows.Forms.Button
$btnNfcOn.Text = 'NFC on'
$btnNfcOn.Location = New-Object System.Drawing.Point(18, 66)
$btnNfcOn.Size = New-Object System.Drawing.Size(110, 32)
$tabNfc.Controls.Add($btnNfcOn)

$btnNfcOff = New-Object System.Windows.Forms.Button
$btnNfcOff.Text = 'NFC off'
$btnNfcOff.Location = New-Object System.Drawing.Point(136, 66)
$btnNfcOff.Size = New-Object System.Drawing.Size(110, 32)
$tabNfc.Controls.Add($btnNfcOff)

$btnNfcRefresh = New-Object System.Windows.Forms.Button
$btnNfcRefresh.Text = 'Refresh'
$btnNfcRefresh.Location = New-Object System.Drawing.Point(254, 66)
$btnNfcRefresh.Size = New-Object System.Drawing.Size(110, 32)
$tabNfc.Controls.Add($btnNfcRefresh)

$btnNfcSettings = New-Object System.Windows.Forms.Button
$btnNfcSettings.Text = 'NFC settings'
$btnNfcSettings.Location = New-Object System.Drawing.Point(372, 66)
$btnNfcSettings.Size = New-Object System.Drawing.Size(130, 32)
$tabNfc.Controls.Add($btnNfcSettings)

$txtNfcInfo = New-Object System.Windows.Forms.TextBox
$txtNfcInfo.Multiline = $true
$txtNfcInfo.ReadOnly = $true
$txtNfcInfo.ScrollBars = 'Vertical'
$txtNfcInfo.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtNfcInfo.Location = New-Object System.Drawing.Point(18, 112)
$txtNfcInfo.Size = New-Object System.Drawing.Size(820, 190)
$tabNfc.Controls.Add($txtNfcInfo)

# --- tab: Users ---------------------------------------------------------------
$lstUsers = New-Object System.Windows.Forms.ListView
$lstUsers.View = 'Details'
$lstUsers.FullRowSelect = $true
$lstUsers.HideSelection = $false
$lstUsers.Location = New-Object System.Drawing.Point(12, 44)
$lstUsers.Size = New-Object System.Drawing.Size(840, 250)
$null = $lstUsers.Columns.Add('Id', 60)
$null = $lstUsers.Columns.Add('Name', 260)
$null = $lstUsers.Columns.Add('State', 110)
$null = $lstUsers.Columns.Add('Kind', 150)
$null = $lstUsers.Columns.Add('Flags', 110)
$tabUsers.Controls.Add($lstUsers)

$lblUsersState = New-Object System.Windows.Forms.Label
$lblUsersState.Text = 'users: unknown'
$lblUsersState.Location = New-Object System.Drawing.Point(14, 16)
$lblUsersState.Size = New-Object System.Drawing.Size(500, 20)
$tabUsers.Controls.Add($lblUsersState)

$btnUsersRefresh = New-Object System.Windows.Forms.Button
$btnUsersRefresh.Text = 'Refresh'
$btnUsersRefresh.Location = New-Object System.Drawing.Point(732, 10)
$btnUsersRefresh.Size = New-Object System.Drawing.Size(96, 28)
$tabUsers.Controls.Add($btnUsersRefresh)

$btnUserSwitch = New-Object System.Windows.Forms.Button
$btnUserSwitch.Text = 'Switch to'
$btnUserSwitch.Location = New-Object System.Drawing.Point(12, 302)
$btnUserSwitch.Size = New-Object System.Drawing.Size(100, 28)
$tabUsers.Controls.Add($btnUserSwitch)
$toolTip.SetToolTip($btnUserSwitch, 'Switch the phone screen to the selected user')

$btnUserAdd = New-Object System.Windows.Forms.Button
$btnUserAdd.Text = 'Add user'
$btnUserAdd.Location = New-Object System.Drawing.Point(120, 302)
$btnUserAdd.Size = New-Object System.Drawing.Size(100, 28)
$tabUsers.Controls.Add($btnUserAdd)

$btnUserRename = New-Object System.Windows.Forms.Button
$btnUserRename.Text = 'Rename'
$btnUserRename.Location = New-Object System.Drawing.Point(228, 302)
$btnUserRename.Size = New-Object System.Drawing.Size(100, 28)
$tabUsers.Controls.Add($btnUserRename)

$btnUserRemove = New-Object System.Windows.Forms.Button
$btnUserRemove.Text = 'Remove'
$btnUserRemove.Location = New-Object System.Drawing.Point(336, 302)
$btnUserRemove.Size = New-Object System.Drawing.Size(100, 28)
$tabUsers.Controls.Add($btnUserRemove)

$btnUserSwitcherOn = New-Object System.Windows.Forms.Button
$btnUserSwitcherOn.Text = 'Multi-user on'
$btnUserSwitcherOn.Location = New-Object System.Drawing.Point(456, 302)
$btnUserSwitcherOn.Size = New-Object System.Drawing.Size(120, 28)
$tabUsers.Controls.Add($btnUserSwitcherOn)

$btnUserSwitcherOff = New-Object System.Windows.Forms.Button
$btnUserSwitcherOff.Text = 'Multi-user off'
$btnUserSwitcherOff.Location = New-Object System.Drawing.Point(584, 302)
$btnUserSwitcherOff.Size = New-Object System.Drawing.Size(120, 28)
$tabUsers.Controls.Add($btnUserSwitcherOff)
$toolTip.SetToolTip($btnUserSwitcherOff, 'Hides the user switcher; the users themselves are kept')

$btnUserSettings = New-Object System.Windows.Forms.Button
$btnUserSettings.Text = 'User settings'
$btnUserSettings.Location = New-Object System.Drawing.Point(712, 302)
$btnUserSettings.Size = New-Object System.Drawing.Size(120, 28)
$tabUsers.Controls.Add($btnUserSettings)

# --- tab: running processes --------------------------------------------------
$lstRunning = New-Object System.Windows.Forms.ListView
$lstRunning.View = 'Details'
$lstRunning.FullRowSelect = $true
$lstRunning.MultiSelect = $true
$lstRunning.HideSelection = $false
$lstRunning.Location = New-Object System.Drawing.Point(12, 44)
$lstRunning.Size = New-Object System.Drawing.Size(840, 240)
$null = $lstRunning.Columns.Add('Process', 330)
$null = $lstRunning.Columns.Add('PID', 70)
$null = $lstRunning.Columns.Add('State', 110)
$null = $lstRunning.Columns.Add('Kind', 90)
$null = $lstRunning.Columns.Add('CPU %', 70)
$null = $lstRunning.Columns.Add('Memory MB', 90)
$null = $lstRunning.Columns.Add('User', 90)
$tabRunning.Controls.Add($lstRunning)

$txtRunningFilter = New-Object System.Windows.Forms.TextBox
$txtRunningFilter.Location = New-Object System.Drawing.Point(12, 12)
$txtRunningFilter.Size = New-Object System.Drawing.Size(200, 24)
$tabRunning.Controls.Add($txtRunningFilter)
$toolTip.SetToolTip($txtRunningFilter, 'Filter by process name')

$chkRunningApps = New-Object System.Windows.Forms.CheckBox
$chkRunningApps.Text = 'apps only'
$chkRunningApps.Checked = $true
$chkRunningApps.Location = New-Object System.Drawing.Point(220, 14)
$chkRunningApps.Size = New-Object System.Drawing.Size(96, 22)
$tabRunning.Controls.Add($chkRunningApps)
$toolTip.SetToolTip($chkRunningApps, 'Hide kernel and native system processes')

$btnRunningRefresh = New-Object System.Windows.Forms.Button
$btnRunningRefresh.Text = 'Refresh'
$btnRunningRefresh.Location = New-Object System.Drawing.Point(322, 10)
$btnRunningRefresh.Size = New-Object System.Drawing.Size(84, 26)
$tabRunning.Controls.Add($btnRunningRefresh)

$chkRunningAuto = New-Object System.Windows.Forms.CheckBox
$chkRunningAuto.Text = 'auto'
$chkRunningAuto.Location = New-Object System.Drawing.Point(414, 14)
$chkRunningAuto.Size = New-Object System.Drawing.Size(56, 22)
$tabRunning.Controls.Add($chkRunningAuto)

$numRunningMs = New-Object System.Windows.Forms.NumericUpDown
$numRunningMs.Minimum = 2000
$numRunningMs.Maximum = 60000
$numRunningMs.Increment = 1000
$numRunningMs.Value = 5000
$numRunningMs.Location = New-Object System.Drawing.Point(470, 11)
$numRunningMs.Size = New-Object System.Drawing.Size(74, 24)
$tabRunning.Controls.Add($numRunningMs)
$toolTip.SetToolTip($numRunningMs, 'Milliseconds between automatic refreshes')

$lblRunningInfo = New-Object System.Windows.Forms.Label
$lblRunningInfo.Text = ''
$lblRunningInfo.ForeColor = [System.Drawing.Color]::DimGray
$lblRunningInfo.Location = New-Object System.Drawing.Point(556, 15)
$lblRunningInfo.Size = New-Object System.Drawing.Size(300, 20)
$tabRunning.Controls.Add($lblRunningInfo)

$btnRunningStop = New-Object System.Windows.Forms.Button
$btnRunningStop.Text = 'Force stop'
$btnRunningStop.Location = New-Object System.Drawing.Point(12, 294)
$btnRunningStop.Size = New-Object System.Drawing.Size(110, 28)
$tabRunning.Controls.Add($btnRunningStop)

$btnRunningKill = New-Object System.Windows.Forms.Button
$btnRunningKill.Text = 'Kill (background)'
$btnRunningKill.Location = New-Object System.Drawing.Point(130, 294)
$btnRunningKill.Size = New-Object System.Drawing.Size(140, 28)
$tabRunning.Controls.Add($btnRunningKill)
$toolTip.SetToolTip($btnRunningKill, 'am kill: only stops the process when it is safe to do so')

$btnRunningInfo = New-Object System.Windows.Forms.Button
$btnRunningInfo.Text = 'App info'
$btnRunningInfo.Location = New-Object System.Drawing.Point(278, 294)
$btnRunningInfo.Size = New-Object System.Drawing.Size(100, 28)
$tabRunning.Controls.Add($btnRunningInfo)

$btnRunningKillAll = New-Object System.Windows.Forms.Button
$btnRunningKillAll.Text = 'Kill all background'
$btnRunningKillAll.Location = New-Object System.Drawing.Point(386, 294)
$btnRunningKillAll.Size = New-Object System.Drawing.Size(150, 28)
$tabRunning.Controls.Add($btnRunningKillAll)
$toolTip.SetToolTip($btnRunningKillAll, 'am kill-all: stops every safe-to-kill background process at once')

$btnRunningCopy = New-Object System.Windows.Forms.Button
$btnRunningCopy.Text = 'Copy'
$btnRunningCopy.Location = New-Object System.Drawing.Point(544, 294)
$btnRunningCopy.Size = New-Object System.Drawing.Size(90, 28)
$tabRunning.Controls.Add($btnRunningCopy)

$btnRunningExport = New-Object System.Windows.Forms.Button
$btnRunningExport.Text = 'Export...'
$btnRunningExport.Location = New-Object System.Drawing.Point(642, 294)
$btnRunningExport.Size = New-Object System.Drawing.Size(100, 28)
$tabRunning.Controls.Add($btnRunningExport)

# --- tab 6: live shell + logcat ----------------------------------------------
# The tab holds two pages now. Everything below that says $tabShell still means
# the shell page, so the existing layout code needs no changes.
$tabsShell = New-Object System.Windows.Forms.TabControl
$tabsShell.Dock = 'Fill'
$tabShellHost.Controls.Add($tabsShell)

$tabShell = New-Object System.Windows.Forms.TabPage
$tabShell.Text = 'Shell'
$tabShell.BackColor = [System.Drawing.SystemColors]::Control
$tabsShell.TabPages.Add($tabShell)

$tabLogcat = New-Object System.Windows.Forms.TabPage
$tabLogcat.Text = 'Logcat'
$tabLogcat.BackColor = [System.Drawing.SystemColors]::Control
$tabsShell.TabPages.Add($tabLogcat)

$btnLogcatStart = New-Object System.Windows.Forms.Button
$btnLogcatStart.Text = 'Start'
$btnLogcatStart.Location = New-Object System.Drawing.Point(14, 10)
$btnLogcatStart.Size = New-Object System.Drawing.Size(80, 28)
$tabLogcat.Controls.Add($btnLogcatStart)
$toolTip.SetToolTip($btnLogcatStart, 'Stream adb logcat from the selected device')

$btnLogcatStop = New-Object System.Windows.Forms.Button
$btnLogcatStop.Text = 'Stop'
$btnLogcatStop.Location = New-Object System.Drawing.Point(100, 10)
$btnLogcatStop.Size = New-Object System.Drawing.Size(70, 28)
$btnLogcatStop.Enabled = $false
$tabLogcat.Controls.Add($btnLogcatStop)

$btnLogcatClear = New-Object System.Windows.Forms.Button
$btnLogcatClear.Text = 'Clear'
$btnLogcatClear.Location = New-Object System.Drawing.Point(176, 10)
$btnLogcatClear.Size = New-Object System.Drawing.Size(70, 28)
$tabLogcat.Controls.Add($btnLogcatClear)
$toolTip.SetToolTip($btnLogcatClear, 'Clear the window; hold Shift to also clear the buffer on the phone')

$lblLogcatLevel = New-Object System.Windows.Forms.Label
$lblLogcatLevel.Text = 'Level'
$lblLogcatLevel.Location = New-Object System.Drawing.Point(258, 16)
$lblLogcatLevel.Size = New-Object System.Drawing.Size(40, 20)
$tabLogcat.Controls.Add($lblLogcatLevel)

$cmbLogcatLevel = New-Object System.Windows.Forms.ComboBox
$cmbLogcatLevel.DropDownStyle = 'DropDownList'
$cmbLogcatLevel.Location = New-Object System.Drawing.Point(300, 12)
$cmbLogcatLevel.Size = New-Object System.Drawing.Size(150, 24)
$null = $cmbLogcatLevel.Items.AddRange(@('V  everything', 'D  debug and up', 'I  info and up',
    'W  warnings and up', 'E  errors and up', 'F  fatal only'))
$cmbLogcatLevel.SelectedIndex = 2
$tabLogcat.Controls.Add($cmbLogcatLevel)
$toolTip.SetToolTip($cmbLogcatLevel, 'The lowest priority the phone will send')

$lblLogcatFilter = New-Object System.Windows.Forms.Label
$lblLogcatFilter.Text = 'Contains'
$lblLogcatFilter.Location = New-Object System.Drawing.Point(462, 16)
$lblLogcatFilter.Size = New-Object System.Drawing.Size(58, 20)
$tabLogcat.Controls.Add($lblLogcatFilter)

$txtLogcatFilter = New-Object System.Windows.Forms.TextBox
$txtLogcatFilter.Location = New-Object System.Drawing.Point(524, 12)
$txtLogcatFilter.Size = New-Object System.Drawing.Size(180, 24)
$tabLogcat.Controls.Add($txtLogcatFilter)
$toolTip.SetToolTip($txtLogcatFilter, 'Only lines holding this text are shown; it filters here, the phone still sends everything')

$chkLogcatFollow = New-Object System.Windows.Forms.CheckBox
$chkLogcatFollow.Text = 'follow'
$chkLogcatFollow.Checked = $true
$chkLogcatFollow.Location = New-Object System.Drawing.Point(714, 14)
$chkLogcatFollow.Size = New-Object System.Drawing.Size(70, 22)
$tabLogcat.Controls.Add($chkLogcatFollow)
$toolTip.SetToolTip($chkLogcatFollow, 'Keep scrolling to the newest line')

$btnLogcatSave = New-Object System.Windows.Forms.Button
$btnLogcatSave.Text = 'Save...'
$btnLogcatSave.Location = New-Object System.Drawing.Point(790, 10)
$btnLogcatSave.Size = New-Object System.Drawing.Size(80, 28)
$tabLogcat.Controls.Add($btnLogcatSave)

$txtLogcat = New-Object System.Windows.Forms.RichTextBox
$txtLogcat.ReadOnly = $true
$txtLogcat.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$txtLogcat.ForeColor = [System.Drawing.Color]::Gainsboro
$txtLogcat.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLogcat.WordWrap = $false
$txtLogcat.Location = New-Object System.Drawing.Point(14, 46)
$txtLogcat.Size = New-Object System.Drawing.Size(854, 250)
$tabLogcat.Controls.Add($txtLogcat)

$lblLogcatState = New-Object System.Windows.Forms.Label
$lblLogcatState.Text = 'stopped'
$lblLogcatState.ForeColor = [System.Drawing.Color]::DimGray
$lblLogcatState.Location = New-Object System.Drawing.Point(14, 302)
$lblLogcatState.Size = New-Object System.Drawing.Size(500, 20)
$tabLogcat.Controls.Add($lblLogcatState)

$btnShellStart = New-Object System.Windows.Forms.Button
$btnShellStart.Text = 'Start shell'
$btnShellStart.Location = New-Object System.Drawing.Point(14, 10)
$btnShellStart.Size = New-Object System.Drawing.Size(110, 28)
$tabShell.Controls.Add($btnShellStart)

$btnShellStop = New-Object System.Windows.Forms.Button
$btnShellStop.Text = 'Stop'
$btnShellStop.Enabled = $false
$btnShellStop.Location = New-Object System.Drawing.Point(130, 10)
$btnShellStop.Size = New-Object System.Drawing.Size(80, 28)
$tabShell.Controls.Add($btnShellStop)

$btnShellClear = New-Object System.Windows.Forms.Button
$btnShellClear.Text = 'Clear'
$btnShellClear.Location = New-Object System.Drawing.Point(216, 10)
$btnShellClear.Size = New-Object System.Drawing.Size(80, 28)
$tabShell.Controls.Add($btnShellClear)

$lblShellStatus = New-Object System.Windows.Forms.Label
$lblShellStatus.Text = 'not connected'
$lblShellStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblShellStatus.Location = New-Object System.Drawing.Point(306, 16)
$lblShellStatus.Size = New-Object System.Drawing.Size(260, 20)
$tabShell.Controls.Add($lblShellStatus)

$cmbShellPreset = New-Object System.Windows.Forms.ComboBox
$cmbShellPreset.DropDownStyle = 'DropDownList'
$cmbShellPreset.Location = New-Object System.Drawing.Point(578, 11)
$cmbShellPreset.Size = New-Object System.Drawing.Size(290, 26)
$null = $cmbShellPreset.Items.AddRange(@(
    'presets...',
    'getprop ro.product.model',
    'ip -f inet addr show wlan0',
    'ip route',
    'pm list packages -3',
    'dumpsys battery',
    'settings get secure default_input_method',
    'ime list -a -s',
    'wm size; wm density',
    'top -n 1 -b | head -20',
    'logcat -d -t 40',
    'df -h',
    'su'))
$cmbShellPreset.SelectedIndex = 0
$tabShell.Controls.Add($cmbShellPreset)

$txtShellOut = New-Object System.Windows.Forms.RichTextBox
$txtShellOut.ReadOnly = $true
$txtShellOut.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$txtShellOut.ForeColor = [System.Drawing.Color]::Gainsboro
$txtShellOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtShellOut.Location = New-Object System.Drawing.Point(14, 46)
$txtShellOut.Size = New-Object System.Drawing.Size(854, 194)
$tabShell.Controls.Add($txtShellOut)

$txtShellIn = New-Object System.Windows.Forms.TextBox
$txtShellIn.Font = New-Object System.Drawing.Font('Consolas', 10)
$txtShellIn.Location = New-Object System.Drawing.Point(14, 248)
$txtShellIn.Size = New-Object System.Drawing.Size(760, 26)
$tabShell.Controls.Add($txtShellIn)

$btnShellSend = New-Object System.Windows.Forms.Button
$btnShellSend.Text = 'Send'
$btnShellSend.Location = New-Object System.Drawing.Point(782, 247)
$btnShellSend.Size = New-Object System.Drawing.Size(86, 28)
$tabShell.Controls.Add($btnShellSend)

$lblShellHint = New-Object System.Windows.Forms.Label
$lblShellHint.Text = 'Enter runs the line, Up/Down browses history. The session keeps its state (cd, su, variables) on the first selected device.'
$lblShellHint.ForeColor = [System.Drawing.Color]::DimGray
$lblShellHint.Location = New-Object System.Drawing.Point(14, 280)
$lblShellHint.Size = New-Object System.Drawing.Size(854, 20)
$tabShell.Controls.Add($lblShellHint)

# --- status + log ------------------------------------------------------------
$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear log'
$btnClear.Location = New-Object System.Drawing.Point(12, 644)
$btnClear.Size = New-Object System.Drawing.Size(96, 28)
$btnClear.Anchor = 'Bottom, Left'
$splitMain.Panel2.Controls.Add($btnClear)

# a slim strip along the edge of the pane it folds, the way a sidebar toggle
# behaves everywhere else
$btnTogglePane = New-Object System.Windows.Forms.Button
$btnTogglePane.Text = [char]0x25C0
$btnTogglePane.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$btnTogglePane.FlatStyle = 'Flat'
$btnTogglePane.FlatAppearance.BorderSize = 0
$btnTogglePane.BackColor = [System.Drawing.Color]::FromArgb(228, 232, 234)
$btnTogglePane.Location = New-Object System.Drawing.Point(0, 300)
$btnTogglePane.Size = New-Object System.Drawing.Size(16, 76)
$splitMain.Panel2.Controls.Add($btnTogglePane)
$toolTip.SetToolTip($btnTogglePane, 'Hide the phone screen and make the window narrower')

$btnSaveLog = New-Object System.Windows.Forms.Button
$btnSaveLog.Text = 'Save log...'
$btnSaveLog.Location = New-Object System.Drawing.Point(116, 644)
$btnSaveLog.Size = New-Object System.Drawing.Size(96, 28)
$btnSaveLog.Anchor = 'Bottom, Left'
$splitMain.Panel2.Controls.Add($btnSaveLog)

# The log took a fixed share of the height, and at the smallest window that
# left the Files list about 40 px - not one row. It can now be dragged taller
# or shorter by the bar above its buttons, or folded away.
# The log holds everything the program did, and there was no way to look
# through it. This box shows only the lines that hold what is typed; the lines
# themselves are kept, so clearing the box brings them all back.
$txtLogFind = New-Object System.Windows.Forms.TextBox
$splitMain.Panel2.Controls.Add($txtLogFind)
$toolTip.SetToolTip($txtLogFind, 'Shows only the log lines holding this text. Empty shows everything again.')

$lblLogFind = New-Object System.Windows.Forms.Label
$lblLogFind.Text = 'Find:'
$lblLogFind.TextAlign = 'MiddleRight'
$splitMain.Panel2.Controls.Add($lblLogFind)

$btnLogFold = New-Object System.Windows.Forms.Button
$btnLogFold.Text = [char]0x25BC
$btnLogFold.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$btnLogFold.Size = New-Object System.Drawing.Size(28, 28)
$splitMain.Panel2.Controls.Add($btnLogFold)

$pnlLogGrip = New-Object System.Windows.Forms.Panel
$pnlLogGrip.Cursor = [System.Windows.Forms.Cursors]::HSplit
$pnlLogGrip.Size = New-Object System.Drawing.Size(200, 6)
$splitMain.Panel2.Controls.Add($pnlLogGrip)
$toolTip.SetToolTip($pnlLogGrip, 'Drag to give the log more or less room; double-click to fold it')

# 0 = the height that suits the window; anything else was dragged by hand
$script:logHeight = 0
$script:logFolded = $false
$script:logDrag = $null

# "Stopped" alone read as the state of the whole program; it is the state of
# the internet sharing only, so it says so
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Sharing: off'
$lblStatus.TextAlign = 'MiddleRight'
$lblStatus.AutoEllipsis = $true
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblStatus.Location = New-Object System.Drawing.Point(560, 644)
$lblStatus.Size = New-Object System.Drawing.Size(220, 28)
$lblStatus.Anchor = 'Bottom, Right'
$splitMain.Panel2.Controls.Add($lblStatus)
$toolTip.SetToolTip($lblStatus, "Internet sharing from this PC to the phone (Tethering tab)")

# Every adb call already runs off the window's thread and is counted in
# $script:busy, but nothing on screen said so: a click that takes seconds
# looked like a click that did nothing.
$prgBusy = New-Object System.Windows.Forms.ProgressBar
$prgBusy.Style = 'Marquee'
$prgBusy.MarqueeAnimationSpeed = 30
$prgBusy.Size = New-Object System.Drawing.Size(90, 12)
$prgBusy.Visible = $false
$splitMain.Panel2.Controls.Add($prgBusy)

$lblBusy = New-Object System.Windows.Forms.Label
$lblBusy.ForeColor = [System.Drawing.Color]::DimGray
$lblBusy.AutoEllipsis = $true
$lblBusy.Size = New-Object System.Drawing.Size(200, 20)
$lblBusy.Visible = $false
$splitMain.Panel2.Controls.Add($lblBusy)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(12, 678)
$txtLog.Size = New-Object System.Drawing.Size(890, 146)
$txtLog.Anchor = 'Bottom, Left, Right'
$splitMain.Panel2.Controls.Add($txtLog)

$colorInfo = [System.Drawing.Color]::Gainsboro
$colorStep = [System.Drawing.Color]::FromArgb(102, 192, 244)
$colorGood = [System.Drawing.Color]::FromArgb(126, 211, 33)
$colorWarn = [System.Drawing.Color]::FromArgb(240, 173, 78)
$colorBad = [System.Drawing.Color]::FromArgb(232, 96, 96)

# Every line the program has written this session, so the find box can show a
# few of them and then give all of them back. Capped, like the box itself.
$script:logLines = New-Object System.Collections.Generic.List[object]

function Add-LogLineToBox {
    param([string]$Stamp, [string]$Text, [System.Drawing.Color]$Color)

    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.SelectionLength = 0
    $txtLog.SelectionColor = $Color
    $txtLog.AppendText($Stamp + '  ' + $Text + [Environment]::NewLine)
    $txtLog.SelectionColor = $txtLog.ForeColor
}

function Test-LogLineShown {
    param([string]$Text)

    $find = ''
    if ($txtLogFind) { $find = $txtLogFind.Text.Trim() }
    if (-not $find) { return $true }
    return ($Text.IndexOf($find, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Clear-Log {
    # the lines as well as the box: otherwise the find box would bring back
    # everything a moment after it was cleared
    $script:logLines.Clear()
    $txtLog.Clear()
}

function Update-LogView {
    # the box built again from the lines that match what is typed
    $txtLog.SuspendLayout()
    try {
        $txtLog.Clear()
        foreach ($line in $script:logLines) {
            if (Test-LogLineShown -Text $line.Text) { Add-LogLineToBox -Stamp $line.Stamp -Text $line.Text -Color $line.Color }
        }
    } finally {
        $txtLog.ResumeLayout()
    }
    $txtLog.ScrollToCaret()
}

function Write-Log {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro
    )

    $stamp = Get-Date -Format 'HH:mm:ss'
    foreach ($line in ($Message -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        $script:logLines.Add([PSCustomObject]@{ Stamp = $stamp; Text = $line; Color = $Color })
        # the oldest go first, so a long session cannot grow without end
        while ($script:logLines.Count -gt 3000) { $script:logLines.RemoveAt(0) }
        if (Test-LogLineShown -Text $line) { Add-LogLineToBox -Stamp $stamp -Text $line -Color $Color }
    }
    $txtLog.ScrollToCaret()
}

# --- Advanced > Automation ---------------------------------------------------
# Starting with Windows, and what happens when a given phone is plugged in. The
# rules are kept in %APPDATA%\AndroidDC\automation.json and the start-up entry
# under the user's Run key, both shared with the Nova window
# (shared\Automation.ps1). Docked, not laid out by hand: the page is one list
# and one checklist, and both simply take the room there is.
$grpAutoRules = New-Object System.Windows.Forms.GroupBox
$grpAutoRules.Text = 'When a phone is plugged in'
$grpAutoRules.Dock = 'Fill'
$tabAutomation.Controls.Add($grpAutoRules)

# added after the Fill group, so it takes the top edge first
$grpAutoStart = New-Object System.Windows.Forms.GroupBox
$grpAutoStart.Text = 'Start with Windows'
$grpAutoStart.Dock = 'Top'
$grpAutoStart.Height = 56
$tabAutomation.Controls.Add($grpAutoStart)

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = 'Start minimized when I sign in, in the'
$chkAutoStart.Location = New-Object System.Drawing.Point(12, 22)
$chkAutoStart.Size = New-Object System.Drawing.Size(250, 24)
$grpAutoStart.Controls.Add($chkAutoStart)
$toolTip.SetToolTip($chkAutoStart, ('Adds AndroidDC to the programs that start when you sign in (your Run key). ' +
    'The window opens minimized and runs the rules below for phones already plugged in.'))

$rdoAutoClassic = New-Object System.Windows.Forms.RadioButton
$rdoAutoClassic.Text = 'classic window'
$rdoAutoClassic.Location = New-Object System.Drawing.Point(268, 22)
$rdoAutoClassic.Size = New-Object System.Drawing.Size(120, 24)
$rdoAutoClassic.Checked = $true
$grpAutoStart.Controls.Add($rdoAutoClassic)

$rdoAutoNova = New-Object System.Windows.Forms.RadioButton
$rdoAutoNova.Text = 'Nova window'
$rdoAutoNova.Location = New-Object System.Drawing.Point(392, 22)
$rdoAutoNova.Size = New-Object System.Drawing.Size(110, 24)
$grpAutoStart.Controls.Add($rdoAutoNova)

$pnlAutoEdit = New-Object System.Windows.Forms.Panel
$pnlAutoEdit.Dock = 'Fill'
$pnlAutoEdit.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$grpAutoRules.Controls.Add($pnlAutoEdit)

$pnlAutoList = New-Object System.Windows.Forms.Panel
$pnlAutoList.Dock = 'Left'
$pnlAutoList.Width = 330
$grpAutoRules.Controls.Add($pnlAutoList)

$lstAutoRules = New-Object System.Windows.Forms.ListView
$lstAutoRules.Dock = 'Fill'
$lstAutoRules.View = 'Details'
$lstAutoRules.FullRowSelect = $true
$lstAutoRules.HideSelection = $false
$lstAutoRules.MultiSelect = $false
$lstAutoRules.ShowItemToolTips = $true
$null = $lstAutoRules.Columns.Add('On', 40)
$null = $lstAutoRules.Columns.Add('Phone', 130)
$null = $lstAutoRules.Columns.Add('Serial', 136)
$pnlAutoList.Controls.Add($lstAutoRules)

$pnlAutoButtons = New-Object System.Windows.Forms.Panel
$pnlAutoButtons.Dock = 'Bottom'
$pnlAutoButtons.Height = 34
$pnlAutoList.Controls.Add($pnlAutoButtons)

$btnAutoAdd = New-Object System.Windows.Forms.Button
$btnAutoAdd.Text = 'Add the selected phone'
$btnAutoAdd.Location = New-Object System.Drawing.Point(0, 5)
$btnAutoAdd.Size = New-Object System.Drawing.Size(150, 26)
$pnlAutoButtons.Controls.Add($btnAutoAdd)
$toolTip.SetToolTip($btnAutoAdd, 'A rule for the phone selected in the device list')

$btnAutoRun = New-Object System.Windows.Forms.Button
$btnAutoRun.Text = 'Run now'
$btnAutoRun.Location = New-Object System.Drawing.Point(156, 5)
$btnAutoRun.Size = New-Object System.Drawing.Size(80, 26)
$pnlAutoButtons.Controls.Add($btnAutoRun)
$toolTip.SetToolTip($btnAutoRun, "Runs the rule's actions on its phone now, without plugging it in again")

$btnAutoRemove = New-Object System.Windows.Forms.Button
$btnAutoRemove.Text = 'Remove'
$btnAutoRemove.Location = New-Object System.Drawing.Point(242, 5)
$btnAutoRemove.Size = New-Object System.Drawing.Size(84, 26)
$pnlAutoButtons.Controls.Add($btnAutoRemove)
$toolTip.SetToolTip($btnAutoRemove, 'Removes the rule; the phone is not touched')

$clbAutoActions = New-Object System.Windows.Forms.CheckedListBox
$clbAutoActions.Dock = 'Fill'
$clbAutoActions.CheckOnClick = $true
$clbAutoActions.IntegralHeight = $false
$pnlAutoEdit.Controls.Add($clbAutoActions)

$pnlAutoTop = New-Object System.Windows.Forms.Panel
$pnlAutoTop.Dock = 'Top'
$pnlAutoTop.Height = 28
$pnlAutoEdit.Controls.Add($pnlAutoTop)

$lblAutoHint = New-Object System.Windows.Forms.Label
$lblAutoHint.Dock = 'Fill'
$lblAutoHint.TextAlign = 'MiddleLeft'
$lblAutoHint.AutoEllipsis = $true
$pnlAutoTop.Controls.Add($lblAutoHint)

$chkAutoRuleOn = New-Object System.Windows.Forms.CheckBox
$chkAutoRuleOn.Text = 'This rule is on'
$chkAutoRuleOn.Dock = 'Left'
$chkAutoRuleOn.Width = 130
$pnlAutoTop.Controls.Add($chkAutoRuleOn)

$pnlAutoApp = New-Object System.Windows.Forms.Panel
$pnlAutoApp.Dock = 'Bottom'
$pnlAutoApp.Height = 30
$pnlAutoApp.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 3)
$pnlAutoEdit.Controls.Add($pnlAutoApp)

$txtAutoApp = New-Object System.Windows.Forms.TextBox
$txtAutoApp.Dock = 'Fill'
$pnlAutoApp.Controls.Add($txtAutoApp)
$toolTip.SetToolTip($txtAutoApp, 'For "Open an app": the package name, like com.whatsapp - the Apps tab lists them')

$lblAutoApp = New-Object System.Windows.Forms.Label
$lblAutoApp.Text = 'App package:'
$lblAutoApp.Dock = 'Left'
$lblAutoApp.Width = 90
$lblAutoApp.TextAlign = 'MiddleLeft'
$pnlAutoApp.Controls.Add($lblAutoApp)

# one line per action, in the order a rule runs them; the ids say which is which
$script:automationActionIds = @()
foreach ($automationAction in @(Get-AutomationActionList)) {
    $null = $clbAutoActions.Items.Add("$($automationAction.Group): $($automationAction.Label)")
    $script:automationActionIds += $automationAction.Id
}

# --- Advanced > Backup -------------------------------------------------------
# A backup is a folder on this PC with manifest.json in it; shared\Backup.ps1
# does the work and the Nova window has the same page. Docked, not laid out by
# hand: two groups, a list and a few rows of buttons.
$grpBackupRestore = New-Object System.Windows.Forms.GroupBox
$grpBackupRestore.Text = 'Put a backup back on a phone'
$grpBackupRestore.Dock = 'Fill'
$tabBackup.Controls.Add($grpBackupRestore)

# added after the Fill group, so it takes the top edge first
$grpBackupMake = New-Object System.Windows.Forms.GroupBox
$grpBackupMake.Text = 'Back this phone up'
$grpBackupMake.Dock = 'Top'
$grpBackupMake.Height = 104
$tabBackup.Controls.Add($grpBackupMake)

$chkBackupFiles = New-Object System.Windows.Forms.CheckBox
$chkBackupFiles.Text = 'Phone files'
$chkBackupFiles.Checked = $true
$chkBackupFiles.Location = New-Object System.Drawing.Point(12, 22)
$chkBackupFiles.Size = New-Object System.Drawing.Size(150, 22)
$grpBackupMake.Controls.Add($chkBackupFiles)

$chkBackupApps = New-Object System.Windows.Forms.CheckBox
$chkBackupApps.Text = 'Apps (APK files)'
$chkBackupApps.Checked = $true
$chkBackupApps.Location = New-Object System.Drawing.Point(168, 22)
$chkBackupApps.Size = New-Object System.Drawing.Size(150, 22)
$grpBackupMake.Controls.Add($chkBackupApps)

$chkBackupPersonal = New-Object System.Windows.Forms.CheckBox
$chkBackupPersonal.Text = 'Contacts, messages, calls'
$chkBackupPersonal.Checked = $true
$chkBackupPersonal.Location = New-Object System.Drawing.Point(324, 22)
$chkBackupPersonal.Size = New-Object System.Drawing.Size(200, 22)
$grpBackupMake.Controls.Add($chkBackupPersonal)

$chkBackupSettings = New-Object System.Windows.Forms.CheckBox
$chkBackupSettings.Text = 'Settings and app list'
$chkBackupSettings.Checked = $true
$chkBackupSettings.Location = New-Object System.Drawing.Point(530, 22)
$chkBackupSettings.Size = New-Object System.Drawing.Size(170, 22)
$grpBackupMake.Controls.Add($chkBackupSettings)

$btnBackupRun = New-Object System.Windows.Forms.Button
$btnBackupRun.Text = 'Back up now ...'
$btnBackupRun.Location = New-Object System.Drawing.Point(12, 48)
$btnBackupRun.Size = New-Object System.Drawing.Size(140, 28)
$grpBackupMake.Controls.Add($btnBackupRun)
$toolTip.SetToolTip($btnBackupRun, 'Asks where to keep it, then writes a folder named after this phone and the time')

$btnBackupCancel = New-Object System.Windows.Forms.Button
$btnBackupCancel.Text = 'Cancel'
$btnBackupCancel.Location = New-Object System.Drawing.Point(158, 48)
$btnBackupCancel.Size = New-Object System.Drawing.Size(90, 28)
$btnBackupCancel.Enabled = $false
$grpBackupMake.Controls.Add($btnBackupCancel)
$toolTip.SetToolTip($btnBackupCancel, 'Stops the backup or the restore where it is; what was already done stays')

$prgBackup = New-Object System.Windows.Forms.ProgressBar
$prgBackup.Location = New-Object System.Drawing.Point(256, 52)
$prgBackup.Size = New-Object System.Drawing.Size(150, 20)
$grpBackupMake.Controls.Add($prgBackup)

$lblBackupProgress = New-Object System.Windows.Forms.Label
$lblBackupProgress.Text = 'What an app keeps inside itself cannot be read without root - see the guide.'
$lblBackupProgress.Location = New-Object System.Drawing.Point(414, 54)
$lblBackupProgress.Size = New-Object System.Drawing.Size(286, 20)
$lblBackupProgress.AutoEllipsis = $true
$grpBackupMake.Controls.Add($lblBackupProgress)

# three lists, one at a time: the backups this PC has, what is inside the one
# that is open, and the apps in it. Added before the docked panels, so Fill
# takes what the top and bottom rows leave.
$tabsBackupView = New-Object System.Windows.Forms.TabControl
$tabsBackupView.Dock = 'Fill'
$grpBackupRestore.Controls.Add($tabsBackupView)

$tabBackupList = New-Object System.Windows.Forms.TabPage
$tabBackupList.Text = 'My backups'
$tabBackupList.BackColor = [System.Drawing.SystemColors]::Control
$tabsBackupView.TabPages.Add($tabBackupList)

$lstBackupList = New-Object System.Windows.Forms.ListView
$lstBackupList.View = 'Details'
$lstBackupList.FullRowSelect = $true
$lstBackupList.MultiSelect = $false
$lstBackupList.HideSelection = $false
$lstBackupList.Dock = 'Fill'
$null = $lstBackupList.Columns.Add('Taken', 130)
$null = $lstBackupList.Columns.Add('Phone', 150)
$null = $lstBackupList.Columns.Add('Holds', 130)
$null = $lstBackupList.Columns.Add('Size', 70)
$null = $lstBackupList.Columns.Add('State', 100)
$null = $lstBackupList.Columns.Add('File', 260)
$tabBackupList.Controls.Add($lstBackupList)

# the folder the list shows, and the way to change it
$pnlBackupWhere = New-Object System.Windows.Forms.Panel
$pnlBackupWhere.Dock = 'Top'
$pnlBackupWhere.Height = 30
$tabBackupList.Controls.Add($pnlBackupWhere)

$lblBackupWhere = New-Object System.Windows.Forms.Label
$lblBackupWhere.Text = 'Backups in:'
$lblBackupWhere.Location = New-Object System.Drawing.Point(4, 7)
$lblBackupWhere.Size = New-Object System.Drawing.Size(74, 20)
$pnlBackupWhere.Controls.Add($lblBackupWhere)

$txtBackupWhere = New-Object System.Windows.Forms.TextBox
$txtBackupWhere.Location = New-Object System.Drawing.Point(80, 4)
$txtBackupWhere.Size = New-Object System.Drawing.Size(390, 22)
$pnlBackupWhere.Controls.Add($txtBackupWhere)
$toolTip.SetToolTip($txtBackupWhere, 'The folder the list below looks in - type a path and press Enter, or use Browse')

$btnBackupWhereBrowse = New-Object System.Windows.Forms.Button
$btnBackupWhereBrowse.Text = 'Browse ...'
$btnBackupWhereBrowse.Location = New-Object System.Drawing.Point(476, 3)
$btnBackupWhereBrowse.Size = New-Object System.Drawing.Size(94, 24)
$pnlBackupWhere.Controls.Add($btnBackupWhereBrowse)
$toolTip.SetToolTip($btnBackupWhereBrowse, 'Pick the folder your backups are kept in')

# placed by hand, not anchored: an anchor keeps the width the control was built
# with, and this row is built before the page has the width it will have
$pnlBackupWhere.Add_Resize({
    $width = $pnlBackupWhere.ClientSize.Width
    if ($width -lt 240) { return }
    $btnBackupWhereBrowse.Location = New-Object System.Drawing.Point(($width - 98), 3)
    $txtBackupWhere.Size = New-Object System.Drawing.Size(($width - 186), 22)
})

$pnlBackupListButtons = New-Object System.Windows.Forms.Panel
$pnlBackupListButtons.Dock = 'Bottom'
$pnlBackupListButtons.Height = 30
$tabBackupList.Controls.Add($pnlBackupListButtons)

$btnBackupListRefresh = New-Object System.Windows.Forms.Button
$btnBackupListRefresh.Text = 'Refresh'
$btnBackupListRefresh.Location = New-Object System.Drawing.Point(4, 2)
$btnBackupListRefresh.Size = New-Object System.Drawing.Size(84, 26)
$pnlBackupListButtons.Controls.Add($btnBackupListRefresh)
$toolTip.SetToolTip($btnBackupListRefresh, 'Reads the list again, and checks whether each backup is still where it was put')

$btnBackupListOpen = New-Object System.Windows.Forms.Button
$btnBackupListOpen.Text = 'Open this one'
$btnBackupListOpen.Location = New-Object System.Drawing.Point(92, 2)
$btnBackupListOpen.Size = New-Object System.Drawing.Size(116, 26)
$pnlBackupListButtons.Controls.Add($btnBackupListOpen)
$toolTip.SetToolTip($btnBackupListOpen, 'Opens the selected backup, so what is inside it can be read and put back')

$btnBackupListShow = New-Object System.Windows.Forms.Button
$btnBackupListShow.Text = 'Show in Explorer'
$btnBackupListShow.Location = New-Object System.Drawing.Point(212, 2)
$btnBackupListShow.Size = New-Object System.Drawing.Size(126, 26)
$pnlBackupListButtons.Controls.Add($btnBackupListShow)
$toolTip.SetToolTip($btnBackupListShow, 'Opens Explorer with the backup file picked out')

$tabBackupInside = New-Object System.Windows.Forms.TabPage
$tabBackupInside.Text = 'What is inside'
$tabBackupInside.BackColor = [System.Drawing.SystemColors]::Control
$tabsBackupView.TabPages.Add($tabBackupInside)

$lstBackupInside = New-Object System.Windows.Forms.ListView
$lstBackupInside.View = 'Details'
$lstBackupInside.FullRowSelect = $true
$lstBackupInside.HideSelection = $false
$lstBackupInside.Dock = 'Fill'
$null = $lstBackupInside.Columns.Add('What', 80)
$null = $lstBackupInside.Columns.Add('Where it was', 500)
$null = $lstBackupInside.Columns.Add('Size', 80)
$tabBackupInside.Controls.Add($lstBackupInside)

$pnlBackupInsideRow = New-Object System.Windows.Forms.Panel
$pnlBackupInsideRow.Dock = 'Bottom'
$pnlBackupInsideRow.Height = 30
$tabBackupInside.Controls.Add($pnlBackupInsideRow)

$lblBackupFind = New-Object System.Windows.Forms.Label
$lblBackupFind.Text = 'Find:'
$lblBackupFind.Location = New-Object System.Drawing.Point(4, 7)
$lblBackupFind.Size = New-Object System.Drawing.Size(36, 20)
$pnlBackupInsideRow.Controls.Add($lblBackupFind)

$txtBackupFind = New-Object System.Windows.Forms.TextBox
$txtBackupFind.Location = New-Object System.Drawing.Point(42, 4)
$txtBackupFind.Size = New-Object System.Drawing.Size(160, 22)
$pnlBackupInsideRow.Controls.Add($txtBackupFind)
$toolTip.SetToolTip($txtBackupFind, 'Shows only the files whose path holds this text; empty it to see them all')

$lblBackupInside = New-Object System.Windows.Forms.Label
$lblBackupInside.Text = 'Nothing open.'
$lblBackupInside.Location = New-Object System.Drawing.Point(210, 7)
$lblBackupInside.Size = New-Object System.Drawing.Size(300, 20)
$lblBackupInside.AutoEllipsis = $true
$pnlBackupInsideRow.Controls.Add($lblBackupInside)

$btnBackupSaveCopy = New-Object System.Windows.Forms.Button
$btnBackupSaveCopy.Text = 'Save a copy ...'
$btnBackupSaveCopy.Location = New-Object System.Drawing.Point(518, 2)
$btnBackupSaveCopy.Size = New-Object System.Drawing.Size(126, 26)
$pnlBackupInsideRow.Controls.Add($btnBackupSaveCopy)
$toolTip.SetToolTip($btnBackupSaveCopy, 'Writes the picked files out of the backup into a folder on this PC; no phone is needed')

$tabBackupApps = New-Object System.Windows.Forms.TabPage
$tabBackupApps.Text = 'Apps to install'
$tabBackupApps.BackColor = [System.Drawing.SystemColors]::Control
$tabsBackupView.TabPages.Add($tabBackupApps)

# a list with columns, not a row of packages: com.shiftatinc.worker tells
# nobody which app it is, and the version beside the phone's says whether
# putting it back would change anything
$lstBackupApps = New-Object System.Windows.Forms.ListView
$lstBackupApps.View = 'Details'
$lstBackupApps.CheckBoxes = $true
$lstBackupApps.FullRowSelect = $true
$lstBackupApps.HideSelection = $false
$lstBackupApps.Dock = 'Fill'
$null = $lstBackupApps.Columns.Add('App', 190)
$null = $lstBackupApps.Columns.Add('Package', 230)
$null = $lstBackupApps.Columns.Add('In the backup', 100)
$null = $lstBackupApps.Columns.Add('Size', 75)
$null = $lstBackupApps.Columns.Add('On this phone', 150)
$tabBackupApps.Controls.Add($lstBackupApps)

$pnlBackupAppsRow = New-Object System.Windows.Forms.Panel
$pnlBackupAppsRow.Dock = 'Bottom'
$pnlBackupAppsRow.Height = 30
$tabBackupApps.Controls.Add($pnlBackupAppsRow)

$lblBackupAppFind = New-Object System.Windows.Forms.Label
$lblBackupAppFind.Text = 'Find:'
$lblBackupAppFind.Location = New-Object System.Drawing.Point(4, 7)
$lblBackupAppFind.Size = New-Object System.Drawing.Size(36, 20)
$pnlBackupAppsRow.Controls.Add($lblBackupAppFind)

$txtBackupAppFind = New-Object System.Windows.Forms.TextBox
$txtBackupAppFind.Location = New-Object System.Drawing.Point(42, 4)
$txtBackupAppFind.Size = New-Object System.Drawing.Size(150, 22)
$pnlBackupAppsRow.Controls.Add($txtBackupAppFind)
$toolTip.SetToolTip($txtBackupAppFind, 'Shows only the apps whose name or package holds this text; ticks are kept while you look')

$btnBackupAppsAll = New-Object System.Windows.Forms.Button
$btnBackupAppsAll.Text = 'Tick all'
$btnBackupAppsAll.Location = New-Object System.Drawing.Point(200, 2)
$btnBackupAppsAll.Size = New-Object System.Drawing.Size(76, 26)
$pnlBackupAppsRow.Controls.Add($btnBackupAppsAll)
$toolTip.SetToolTip($btnBackupAppsAll, 'Ticks every app the list is showing')

$btnBackupAppsNone = New-Object System.Windows.Forms.Button
$btnBackupAppsNone.Text = 'Tick none'
$btnBackupAppsNone.Location = New-Object System.Drawing.Point(280, 2)
$btnBackupAppsNone.Size = New-Object System.Drawing.Size(76, 26)
$pnlBackupAppsRow.Controls.Add($btnBackupAppsNone)
$toolTip.SetToolTip($btnBackupAppsNone, 'Unticks every app the list is showing')

$lblBackupApps = New-Object System.Windows.Forms.Label
$lblBackupApps.Text = 'Open a backup to see the apps in it.'
$lblBackupApps.Location = New-Object System.Drawing.Point(364, 7)
$lblBackupApps.Size = New-Object System.Drawing.Size(320, 20)
$lblBackupApps.AutoEllipsis = $true
$pnlBackupAppsRow.Controls.Add($lblBackupApps)

$pnlBackupTop = New-Object System.Windows.Forms.Panel
$pnlBackupTop.Dock = 'Top'
# 58, not 76: at the smallest window every row above the list is a row the
# list does not have
$pnlBackupTop.Height = 58
$grpBackupRestore.Controls.Add($pnlBackupTop)

# docked, not anchored: an anchored box keeps the width it was built with and
# grew past its panel at every window size
$txtBackupInfo = New-Object System.Windows.Forms.TextBox
$txtBackupInfo.Multiline = $true
$txtBackupInfo.ReadOnly = $true
$txtBackupInfo.ScrollBars = 'Vertical'
$txtBackupInfo.Dock = 'Fill'
$txtBackupInfo.Text = 'No backup opened yet.'
$pnlBackupTop.Controls.Add($txtBackupInfo)

$pnlBackupOpen = New-Object System.Windows.Forms.Panel
$pnlBackupOpen.Dock = 'Left'
$pnlBackupOpen.Width = 156
$pnlBackupTop.Controls.Add($pnlBackupOpen)

$btnBackupOpen = New-Object System.Windows.Forms.Button
$btnBackupOpen.Text = 'Open a backup ...'
$btnBackupOpen.Location = New-Object System.Drawing.Point(10, 4)
$btnBackupOpen.Size = New-Object System.Drawing.Size(140, 26)
$pnlBackupOpen.Controls.Add($btnBackupOpen)
$toolTip.SetToolTip($btnBackupOpen, 'Pick the .zip file a backup is')

$pnlBackupButtons = New-Object System.Windows.Forms.Panel
$pnlBackupButtons.Dock = 'Bottom'
$pnlBackupButtons.Height = 34
$grpBackupRestore.Controls.Add($pnlBackupButtons)

$btnRestoreFiles = New-Object System.Windows.Forms.Button
$btnRestoreFiles.Text = 'Restore files ...'
$btnRestoreFiles.Location = New-Object System.Drawing.Point(10, 4)
$btnRestoreFiles.Size = New-Object System.Drawing.Size(130, 26)
$pnlBackupButtons.Controls.Add($btnRestoreFiles)
$toolTip.SetToolTip($btnRestoreFiles, 'Sends the files back; it asks first about the ones the phone already has')

$btnRestoreApps = New-Object System.Windows.Forms.Button
$btnRestoreApps.Text = 'Install ticked apps'
$btnRestoreApps.Location = New-Object System.Drawing.Point(146, 4)
$btnRestoreApps.Size = New-Object System.Drawing.Size(140, 26)
$pnlBackupButtons.Controls.Add($btnRestoreApps)

$btnRestoreContacts = New-Object System.Windows.Forms.Button
$btnRestoreContacts.Text = 'Restore contacts'
$btnRestoreContacts.Location = New-Object System.Drawing.Point(292, 4)
$btnRestoreContacts.Size = New-Object System.Drawing.Size(130, 26)
$pnlBackupButtons.Controls.Add($btnRestoreContacts)
$toolTip.SetToolTip($btnRestoreContacts, 'Adds the contacts this phone does not have; messages and the call log cannot be written by adb')

$btnBackupOpenFolder = New-Object System.Windows.Forms.Button
$btnBackupOpenFolder.Text = 'Show in Explorer'
$btnBackupOpenFolder.Location = New-Object System.Drawing.Point(428, 4)
$btnBackupOpenFolder.Size = New-Object System.Drawing.Size(130, 26)
$pnlBackupButtons.Controls.Add($btnBackupOpenFolder)
$toolTip.SetToolTip($btnBackupOpenFolder, 'Opens Explorer with the opened backup picked out')

# --- what an empty list says --------------------------------------------------
# A list that has never been read looks exactly like a list with nothing in it,
# and both look like a program that did nothing. Each one gets a line over it,
# shown only while it is empty, saying which button fills it. The line sits on
# the list on purpose, so the layout audit is told to expect it (Tag).
$script:listHints = @()
# where the log's find box begins, so the busy strip can stop short of it
$script:logFindLeft = 0

function Add-ListHint {
    param($List, [string]$Text)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $label.AutoSize = $false
    $label.Visible = $false
    $label.Tag = 'listhint'
    $List.Parent.Controls.Add($label)
    $script:listHints += [PSCustomObject]@{ List = $List; Label = $label }
}

function Update-ListHints {
    foreach ($hint in $script:listHints) {
        $list = $hint.List
        $label = $hint.Label
        $show = ($list.Items.Count -eq 0 -and $list.Visible)
        $box = $list.Bounds
        # a list too small to hold the line does not get one: left visible, it
        # stayed where it last stood and sat on top of the row above
        if ($box.Width -lt 80 -or $box.Height -lt 40) { $show = $false }
        if ($label.Visible -ne $show) { $label.Visible = $show }
        if (-not $show) { continue }
        $label.SetBounds(($box.X + 8), ($box.Y + [Math]::Max(8, [int]($box.Height / 2) - 18)),
            ($box.Width - 16), 36)
        $label.BringToFront()
    }
}

# ------------------------------------------------------------------ logic ----

function Get-SelectedSerial {
    if ($lstDevices.SelectedItems.Count -eq 0) { return $null }
    return $lstDevices.SelectedItems[0].Text
}

function Get-SelectedSerials {
    $serials = @()
    foreach ($item in $lstDevices.SelectedItems) {
        if ($item.SubItems[4].Text -eq 'device') { $serials += $item.Text }
    }
    return $serials
}

function Get-TargetSerial {
    $serial = Get-SelectedSerial
    if (-not $serial) {
        Write-Log 'Select a device first.' $colorWarn
        return $null
    }
    if ($lstDevices.SelectedItems[0].SubItems[4].Text -ne 'device') {
        Write-Log "Device $serial is not ready ($($lstDevices.SelectedItems[0].SubItems[4].Text))." $colorBad
        return $null
    }
    return $serial
}

function Update-DeviceList {
    $previous = Get-SelectedSerial
    $lstDevices.BeginUpdate()
    try {
        $lstDevices.Items.Clear()
        $found = @(Get-AdbDevices)
        $readIndex = 0
        $script:deviceSignature = Get-DeviceSignature -Devices $found
        $script:devicesReadOnce = $true
        # a phone that just became ready gets its rule queued (Advanced > Automation)
        $null = Register-AutomationArrivals -Devices $found
        foreach ($device in $found) {
            $installed = '-'
            $release = '-'
            if ($device.State -eq 'device') {
                # the strip says which phone of how many, not just "working"
                $readIndex++
                if ($found.Count -gt 1) { $script:busyWhat = "reading phone $readIndex of $($found.Count)" }
                $check = Invoke-DeviceShell -Serial $device.Serial -CommandArguments @('pm', 'list', 'packages', $packageName)
                $installed = if ($check.Text -match [regex]::Escape("package:$packageName")) { 'yes' } else { 'no' }
                $release = (Invoke-DeviceShell -Serial $device.Serial -CommandArguments @('getprop', 'ro.build.version.release')).Text.Trim()
                if (-not $release) { $release = '-' }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($device.Serial)
            $null = $item.SubItems.Add($device.Link)
            $null = $item.SubItems.Add($device.Model)
            $null = $item.SubItems.Add($release)
            $null = $item.SubItems.Add($device.State)
            $null = $item.SubItems.Add($installed)
            if ($device.State -ne 'device') { $item.ForeColor = [System.Drawing.Color]::Firebrick }
            $null = $lstDevices.Items.Add($item)
        }
    } finally {
        $lstDevices.EndUpdate()
    }

    foreach ($item in $lstDevices.Items) {
        if ($item.Text -eq $previous) { $item.Selected = $true }
    }
    if ($lstDevices.SelectedItems.Count -eq 0 -and $lstDevices.Items.Count -gt 0) {
        $lstDevices.Items[0].Selected = $true
    }

    if ($lstDevices.Items.Count -eq 0) {
        Write-Log 'No device detected. Plug the phone in, enable USB debugging and accept the RSA prompt.' $colorWarn
    }
}

function Get-DeviceSignature {
    param($Devices)
    return (@($Devices) | ForEach-Object { "$($_.Serial)=$($_.State)" } | Sort-Object) -join ';'
}

function Test-DeviceListChanged {
    # a phone plugged in, pulled out, or one whose RSA prompt was just accepted
    return ((Get-DeviceSignature -Devices @(Get-AdbDevices)) -ne $script:deviceSignature)
}

function Update-BusyIndicator {
    if ($script:busy -gt 0) {
        # a call that ends within 400 ms is not worth a flicker
        if (-not $script:busySince) { $script:busySince = [DateTime]::Now; return }
        if (([DateTime]::Now - $script:busySince).TotalMilliseconds -lt 400) { return }
        $lblBusy.Text = if ($script:busyWhat) { $script:busyWhat } else { 'working ...' }
        $toolTip.SetToolTip($lblBusy, $lblBusy.Text)
        if (-not $prgBusy.Visible) {
            $prgBusy.Visible = $true
            $lblBusy.Visible = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
        }
    } else {
        $script:busySince = $null
        if ($prgBusy.Visible) {
            $prgBusy.Visible = $false
            $lblBusy.Visible = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
}

function Set-Running {
    param([bool]$IsRunning, [string]$Target = '')

    $btnStart.Enabled = -not $IsRunning
    $btnStop.Enabled = $IsRunning
    $chkAll.Enabled = -not $IsRunning
    $lstDevices.Enabled = -not $chkAll.Checked

    if ($IsRunning) {
        $lblStatus.Text = "Sharing: $Target"
        $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $lblStatus.Text = 'Sharing: off'
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Get-ExtraArguments {
    $dns = $cmbDns.Text.Trim()
    if (-not $dns) { $dns = '8.8.8.8' }

    $arguments = @('-d', $dns, '-p', "$([int]$numPort.Value)")
    if ($txtRoutes.Text.Trim() -ne '') {
        $arguments += @('-r', $txtRoutes.Text.Trim())
    }
    return $arguments
}

function Start-Sharing {
    $useAll = $chkAll.Checked
    $serial = $null

    # A relay left over from a previous run (or from gnirehtet-run.cmd) holds the
    # port and would make the new one die with 'os error 10048'.
    $port = [int]$numPort.Value
    $owner = Get-PortOwner -Port $port
    if ($owner) {
        if ($owner.ProcessName -eq 'gnirehtet') {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Another gnirehtet relay (PID $($owner.ProcessId)) is already listening on port $port." +
                [Environment]::NewLine + 'Stop it and continue?',
                'Gnirehtet', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "Cancelled: port $port is still used by PID $($owner.ProcessId)." $colorWarn
                return
            }

            Stop-Process -Id $owner.ProcessId -Force -ErrorAction SilentlyContinue
            Wait-Pumped -Milliseconds 800
            if (Get-PortOwner -Port $port) {
                Write-Log "Port $port is still busy. Pick another port." $colorBad
                return
            }
            Write-Log "Stopped the old relay (PID $($owner.ProcessId))." $colorInfo
        } else {
            Write-Log "Port $port is used by $($owner.ProcessName) (PID $($owner.ProcessId)). Pick another port." $colorBad
            return
        }
    }

    $serials = @()
    if (-not $useAll) {
        $serials = @(Get-SelectedSerials)
        if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }
        $serial = $serials[0]

        foreach ($item in $lstDevices.SelectedItems) {
            if ($item.SubItems[4].Text -ne 'device') { continue }
            $current = $item.Text

            if ($chkReinstall.Checked) {
                Write-Log "Reinstalling the client on $current ..." $colorStep
                $result = Invoke-Gnirehtet -CommandArguments @('reinstall', $current)
                Write-Log $result.Text $colorInfo
                if ($result.ExitCode -ne 0) { Write-Log 'Reinstall failed.' $colorBad; return }
            } elseif ($item.SubItems[5].Text -ne 'yes') {
                Write-Log "Installing the client on $current ..." $colorStep
                $result = Invoke-Gnirehtet -CommandArguments @('install', $current)
                Write-Log $result.Text $colorInfo
                if ($result.ExitCode -ne 0) {
                    Write-Log 'Install failed.' $colorBad
                    # measured on a Xiaomi phone: it refuses any adb install until allowed
                    if ($result.Text -match 'INSTALL_FAILED_USER_RESTRICTED') {
                        Write-Log ('The phone blocks installs over USB. On Xiaomi / Redmi / POCO turn on ' +
                            'Developer options > Install via USB, then accept the prompt on the phone.') $colorWarn
                    }
                    return
                }
            }

            if ($chkWifi.Checked) {
                # only a radio this turned off is turned back on at the end:
                # a phone kept on mobile data used to come back with Wi-Fi on
                $wifiOn = (Invoke-DeviceShell -Serial $current -CommandArguments @(
                    'settings', 'get', 'global', 'wifi_on')).Text.Trim()
                if ($wifiOn -eq '0') {
                    Write-Log "Wi-Fi is already off on $current, and stays off afterwards." $colorInfo
                } else {
                    Write-Log "Turning Wi-Fi off on $current ..." $colorStep
                    $null = Invoke-DeviceShell -Serial $current -CommandArguments @('svc', 'wifi', 'disable')
                    $script:wifiDisabled += $current
                }
            }
        }
    }

    # a new pair of files for every start. Measured: sharing stopped and started
    # again a few seconds later failed with "being used by another process" -
    # something the stopped relay started still held the old pair open, and
    # emptying that file ended the whole start. The files go when the app closes.
    $stamp = Get-Date -Format 'HHmmssfff'
    $script:outFile = Join-Path $env:TEMP ("androiddc-$PID.relay-$stamp.out.log")
    $script:errFile = Join-Path $env:TEMP ("androiddc-$PID.relay-$stamp.err.log")
    foreach ($file in @($script:outFile, $script:errFile)) {
        Set-Content -LiteralPath $file -Value '' -Encoding UTF8
    }
    $script:outOffset = 0
    $script:errOffset = 0

    # One relay serves every client, so several phones share the same server:
    #   1 device  -> 'run'    (relay + client + cleanup on exit)
    #   n devices -> 'relay'  then one 'start' per device
    #   all       -> 'autorun'
    if ($useAll) {
        $arguments = @($(if ($chkShareAutostart.Checked) { 'autostart' } else { 'autorun' })) + (Get-ExtraArguments)
    } elseif ($serials.Count -gt 1) {
        $arguments = @('relay', '-p', "$port")
    } else {
        $arguments = @('run', $serial) + (Get-ExtraArguments)
    }
    Write-Log ('gnirehtet ' + ($arguments -join ' ')) $colorStep

    $script:relayProcess = Start-Process -FilePath $script:gnirehtetPath -ArgumentList $arguments `
        -NoNewWindow -PassThru -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
    $null = $script:relayProcess.Handle
    $script:activeSerials = $serials

    if ($serials.Count -gt 1) {
        Wait-Pumped -Milliseconds 2000
        foreach ($current in $serials) {
            Write-Log "Starting the client on $current ..." $colorStep
            $result = Invoke-Gnirehtet -CommandArguments (@('start', $current) + (Get-ExtraArguments))
            if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }
        }
    }

    $target = if ($useAll) { 'all devices' } elseif ($serials.Count -gt 1) { "$($serials.Count) devices" } else { $serial }
    Set-Running -IsRunning $true -Target $target
    Write-Log 'Accept the VPN connection request on each phone if it shows up.' $colorWarn
    $timer.Start()

    if ($serials.Count -gt 0 -and $chkAutoTest.Checked) {
        Wait-Pumped -Milliseconds 3000
        foreach ($current in $serials) { Test-Connectivity -Serial $current }
    }

    if ($serials.Count -gt 0 -and $chkScrcpyAfter.Checked) {
        Start-Scrcpy
    }
}

function Stop-Sharing {
    param([switch]$Quiet)

    $timer.Stop()

    if ($script:relayProcess) {
        try {
            if (-not $script:relayProcess.HasExited) {
                $script:relayProcess.Kill()
                $null = $script:relayProcess.WaitForExit(5000)
            }
        } catch {
            if (-not $Quiet) { Write-Log "Could not kill the relay: $($_.Exception.Message)" $colorWarn }
        }
        $script:relayProcess = $null
    }

    foreach ($current in $script:activeSerials) {
        $null = Invoke-Gnirehtet -CommandArguments @('stop', $current)
        $null = Invoke-Adb -CommandArguments @('-s', $current, 'reverse', '--remove', 'localabstract:gnirehtet')

        if ($script:wifiDisabled -contains $current) {
            $null = Invoke-DeviceShell -Serial $current -CommandArguments @('svc', 'wifi', 'enable')
            if (-not $Quiet) { Write-Log "Wi-Fi re-enabled on $current." $colorInfo }
        }
    }
    $script:wifiDisabled = @()

    $script:activeSerials = @()

    if (-not $Quiet) {
        Write-Log 'Reverse tethering stopped.' $colorWarn
        Set-Running -IsRunning $false
    }
}

function Read-NewOutput {
    param([string]$Path, [ref]$Offset)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0 }
        $null = $stream.Seek($Offset.Value, 'Begin')
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } finally {
        $stream.Dispose()
    }
}

function Test-Connectivity {
    param([string]$Serial)

    $serial = $Serial
    if (-not $serial) {
        $serial = if ($script:activeSerials.Count -gt 0) { $script:activeSerials[0] } else { Get-SelectedSerial }
    }
    if (-not $serial) { Write-Log 'Select a device first.' $colorWarn; return }

    # gnirehtet relays TCP and UDP only: ICMP is dropped, so ping ALWAYS fails
    # through the tunnel even when it works perfectly. Never test with ping.
    Write-Log "Checking internet on $serial over TCP (ping/ICMP is not relayed by gnirehtet) ..." $colorStep

    # 1. curl, when the ROM ships it: gives a real HTTP status code.
    if ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'curl')).Text.Trim()) {
        $code = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'curl', '-s', '-m', '8', '-o', '/dev/null', '-w', '%{http_code}',
            'http://connectivitycheck.gstatic.com/generate_204')).Text.Trim()

        if ($code -match '^(204|200)$') {
            Write-Log "HTTP $code from the device - the internet works through the PC." $colorGood
            return
        }
        Write-Log "curl returned '$code'." $colorWarn
    }

    # 2. netcat: plain TCP handshake to a DNS server through the tunnel.
    $netcat = $null
    if ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'nc')).Text.Trim()) {
        $netcat = 'nc'
    } elseif ((Invoke-DeviceShell -Serial $serial -CommandArguments @('command', '-v', 'toybox')).Text.Trim()) {
        $netcat = 'toybox nc'
    }

    if ($netcat) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            "$netcat -w 6 8.8.8.8 53 </dev/null; echo rc=" + '$?')

        if ($result.Text -match 'rc=0') {
            Write-Log 'TCP 8.8.8.8:53 reached through the tunnel - the connection works.' $colorGood
            return
        }
        Write-Log ("netcat said: " + $result.Text.Trim()) $colorWarn
    }

    # 3. Last resort: Android's own verdict on the VPN network.
    $dump = Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'connectivity')
    foreach ($line in ($dump.Text -split "`r?`n")) {
        if ($line -match 'Transports:\s*VPN' -and $line -match 'VALIDATED') {
            Write-Log 'Android reports the VPN network as VALIDATED (it checked the internet itself).' $colorGood
            return
        }
    }

    Write-Log 'Could not confirm connectivity. Open a browser on the phone to check.' $colorBad
    Write-Log 'Remember: a failing ping proves nothing here - gnirehtet does not carry ICMP.' $colorWarn
}

# --- USB tethering (phone -> PC) --------------------------------------------

function Get-TetherAdapters {
    # Windows names the tethered phone 'Remote NDIS based Internet Sharing Device'
    # (note the space), so match NDIS rather than RNDIS.
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.InterfaceDescription -match 'NDIS|Android|Tether|Internet Sharing'
        })
    } catch {
        return @()
    }
}

function Get-AdapterAddress {
    param($Adapter)

    try {
        $address = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -First 1
        if ($address) { return $address.IPAddress }
    } catch { }
    return $null
}

function Show-TetherAdapters {
    $adapters = @(Get-TetherAdapters)
    if ($adapters.Count -eq 0) {
        $lblTetherStatus.Text = 'PC side: no USB tethering adapter found.'
        $lblTetherStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Write-Log 'No RNDIS/Android tethering adapter on the PC yet.' $colorWarn
        return $null
    }

    foreach ($adapter in $adapters) {
        $address = Get-AdapterAddress -Adapter $adapter
        Write-Log ("PC adapter: {0} | {1} | {2} | {3}" -f $adapter.Name, $adapter.InterfaceDescription,
            $adapter.Status, $(if ($address) { $address } else { 'no IPv4' })) $colorInfo
    }

    $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -gt 0) {
        $address = Get-AdapterAddress -Adapter $up[0]
        $lblTetherStatus.Text = "PC side: $($up[0].Name) is up ($($up[0].InterfaceDescription))" +
            $(if ($address) { " - $address" } else { '' })
        $lblTetherStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        return $up[0]
    }

    $lblTetherStatus.Text = "PC side: $($adapters[0].Name) present but $($adapters[0].Status)."
    $lblTetherStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    return $null
}

function Open-MeteredSettings {
    param($Adapter)

    # Windows has no supported API to flip 'metered' on an Ethernet/RNDIS link,
    # so open the page where the toggle lives instead of pretending it is done.
    Write-Log "Open '$($Adapter.Name)' and turn on 'Metered connection' so Windows stops downloading updates over the phone data." $colorWarn
    Start-Process 'ms-settings:network-ethernet'
}

function Enable-UsbTethering {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Enabling USB tethering on $serial ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions', 'rndis')
    if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }

    Wait-Pumped -Milliseconds 4000
    $adapter = Show-TetherAdapters

    if (-not $adapter) {
        Write-Log 'The phone refused the adb switch (usual without root). Opening the tethering settings instead.' $colorWarn
        Open-TetherSettings
        return
    }

    Write-Log 'USB tethering is up. The PC now uses the phone data connection.' $colorGood
    if ($chkTetherMetered.Checked) { Open-MeteredSettings -Adapter $adapter }
}

function Disable-UsbTethering {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Disabling USB tethering on $serial ..." $colorStep
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions')
    Wait-Pumped -Milliseconds 2000
    $null = Show-TetherAdapters
    Write-Log 'USB functions reset to charging.' $colorInfo
}

function Open-TetherSettings {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-a', 'android.settings.TETHER_SETTINGS')
    Write-Log $result.Text $colorInfo

    if ($result.Text -match 'Error|does not exist') {
        $fallback = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-n', 'com.android.settings/.TetherSettings')
        Write-Log $fallback.Text $colorInfo
    }

    Write-Log 'Tap "USB tethering" on the phone, then press "Check PC adapters".' $colorWarn
}

# --- phone proxy over adb forward (phone data on the PC) --------------------

Add-Type -Namespace Win32 -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@

$script:proxyPort = 0
$script:previousProxy = $null

function Update-WinInet {
    # Tell WinINET (Edge, Chrome, Office, most Windows apps) to reload the settings.
    [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Set-WindowsProxy {
    param([string]$Server)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = Get-ItemProperty -Path $key

    $script:previousProxy = [PSCustomObject]@{
        Enable   = if ($current.PSObject.Properties.Name -contains 'ProxyEnable') { $current.ProxyEnable } else { 0 }
        Server   = if ($current.PSObject.Properties.Name -contains 'ProxyServer') { $current.ProxyServer } else { '' }
        Override = if ($current.PSObject.Properties.Name -contains 'ProxyOverride') { $current.ProxyOverride } else { '' }
    }

    Set-ItemProperty -Path $key -Name ProxyServer -Value $Server
    Set-ItemProperty -Path $key -Name ProxyOverride -Value '<local>'
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 1
    Update-WinInet
}

function Restore-WindowsProxy {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    if ($script:previousProxy) {
        Set-ItemProperty -Path $key -Name ProxyServer -Value $script:previousProxy.Server
        Set-ItemProperty -Path $key -Name ProxyOverride -Value $script:previousProxy.Override
        Set-ItemProperty -Path $key -Name ProxyEnable -Value $script:previousProxy.Enable
        $script:previousProxy = $null
    } else {
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 0
    }
    Update-WinInet
}

function Test-PhoneProxy {
    param([int]$Port)

    $proxy = "http://127.0.0.1:$Port"
    try {
        $response = Invoke-WebRequest -Uri 'http://connectivitycheck.gstatic.com/generate_204' `
            -Proxy $proxy -UseBasicParsing -TimeoutSec 8
        Write-Log "Proxy answered: HTTP $($response.StatusCode) - the PC can browse through the phone." $colorGood
        return $true
    } catch {
        Write-Log "Proxy test failed: $($_.Exception.Message)" $colorBad
        Write-Log 'Is the proxy app running on the phone and listening on that port?' $colorWarn
        return $false
    }
}

function Start-PhoneProxy {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $port = [int]$numProxyPort.Value
    Write-Log "adb forward tcp:$port -> phone tcp:$port ..." $colorStep
    $forward = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', "tcp:$port", "tcp:$port")
    if ($forward.ExitCode -ne 0) {
        Write-Log $forward.Text $colorBad
        return
    }

    if (-not (Test-PhoneProxy -Port $port)) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', '--remove', "tcp:$port")
        Write-Log 'Forward removed again; the Windows proxy was left untouched.' $colorWarn
        return
    }

    Set-WindowsProxy -Server "127.0.0.1:$port"
    $script:proxyPort = $port
    $btnProxyOff.Enabled = $true
    $btnProxyOn.Enabled = $false
    Write-Log "Windows now browses through the phone (127.0.0.1:$port)." $colorGood
    Write-Log 'Apps that ignore the system proxy (some games, torrents) still use the normal connection.' $colorWarn
}

function Stop-PhoneProxy {
    param([switch]$Quiet)

    if ($script:proxyPort -le 0) { return }

    Restore-WindowsProxy
    $serial = if ($script:activeSerials.Count -gt 0) { $script:activeSerials[0] } else { Get-SelectedSerial }
    if ($serial) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'forward', '--remove', "tcp:$($script:proxyPort)")
    }

    $script:proxyPort = 0
    if (-not $Quiet) {
        $btnProxyOff.Enabled = $false
        $btnProxyOn.Enabled = $true
        Write-Log 'Phone proxy stopped, Windows proxy settings restored.' $colorWarn
    }
}

function Repair-Tunnel {
    param([string]$Serial)

    if (-not $Serial) { $Serial = Get-SelectedSerial }
    if (-not $Serial) { Write-Log 'Select a device first.' $colorWarn; return }

    # 'gnirehtet tunnel' re-creates the adb reverse tunnel without restarting
    # the relay: the fix after an adb server kill or an unplug/replug.
    # 'gnirehtet tunnel' can hang after an adb server kill; adb reverse is instant.
    $null = Invoke-Adb -CommandArguments @('start-server')
    $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'reverse',
        'localabstract:gnirehtet', "tcp:$([int]$numPort.Value)")
    if ($result.Text.Trim()) { Write-Log $result.Text $colorInfo }

    $check = Invoke-Adb -CommandArguments @('-s', $Serial, 'reverse', '--list')
    if ($check.Text -match 'gnirehtet') {
        Write-Log 'Reverse tunnel is in place again.' $colorGood
    } else {
        Write-Log 'Tunnel not restored - stop and start the sharing again.' $colorBad
    }
}

# --- scrcpy ------------------------------------------------------------------

function Get-HidArguments {
    $arguments = @()
    foreach ($pair in @(@('--keyboard', $cmbKeyboard), @('--mouse', $cmbMouse), @('--gamepad', $cmbGamepad))) {
        $value = "$($pair[1].SelectedItem)"
        if ($value -and $value -ne 'default') { $arguments += "$($pair[0])=$value" }
    }
    return $arguments
}

function Get-ExtraScrcpyArguments {
    $extra = $txtExtraArgs.Text.Trim()
    if (-not $extra) { return @() }
    return @($extra -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)' | Where-Object { $_ -ne '' })
}

function Get-StartAppValue {
    <#
        What --start-app is given. A pick from the list reads "Name  (package)"
        and scrcpy wants the package, keeping a + typed in front of it
        (force-stop first). Anything typed by hand passes through unchanged,
        so "com.example", "+com.example" and "?Name" still work.
    #>
    $text = $cmbStartApp.Text.Trim()
    if ($text -match '^(\+?).*\(([A-Za-z0-9_.]+)\)$') { return $Matches[1] + $Matches[2] }
    return $text
}

function Update-StartAppChoices {
    # the phone's apps by name, sorted; whatever is typed in the box is kept
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $names = Get-AppLabels -Serial $serial
    $typed = $cmbStartApp.Text
    $cmbStartApp.BeginUpdate()
    $cmbStartApp.Items.Clear()
    foreach ($entry in @($names.GetEnumerator() | Sort-Object -Property Value)) {
        $null = $cmbStartApp.Items.Add(('{0}  ({1})' -f $entry.Value, $entry.Key))
    }
    $cmbStartApp.EndUpdate()
    $cmbStartApp.Text = $typed
}

function Get-ScrcpyArguments {
    param([string]$Serial)

    # OTG has no video pipeline at all: video/audio/record/display flags are
    # rejected, so build a separate, minimal command line for it.
    if ($chkOtg.Checked) {
        $arguments = @('--otg')
        if ($Serial) { $arguments += @('-s', $Serial) }
        $arguments += Get-HidArguments
        if ($chkOnTop.Checked) { $arguments += '--always-on-top' }
        if ($chkBorderless.Checked) { $arguments += '--window-borderless' }
        if ($chkNoScreensaver.Checked) { $arguments += '--disable-screensaver' }
        $arguments += Get-ExtraScrcpyArguments
        return $arguments
    }

    $arguments = @()
    if ($Serial) { $arguments += @('-s', $Serial) }

    $maxSize = $cmbMaxSize.Text.Trim()
    if ($maxSize -and $maxSize -ne '0') { $arguments += @('-m', $maxSize) }

    $bitrate = $cmbBitrate.Text.Trim()
    if ($bitrate) { $arguments += @('-b', $bitrate) }

    $fps = $cmbFps.Text.Trim()
    if ($fps -and $fps -ne '0') { $arguments += "--max-fps=$fps" }

    if ($cmbCodec.SelectedItem -and "$($cmbCodec.SelectedItem)" -ne 'default') {
        $arguments += "--video-codec=$($cmbCodec.SelectedItem)"
    }

    $display = $cmbDisplay.Text.Trim()
    if ($display -and $display -ne '0' -and -not $chkNewDisplay.Checked) {
        $arguments += "--display-id=$display"
    }

    if ($chkNewDisplay.Checked) {
        $size = $txtNewDisplay.Text.Trim()
        if ($size) { $arguments += "--new-display=$size" } else { $arguments += '--new-display' }
    }

    if ($chkFullscreen.Checked) { $arguments += '-f' }
    if ($chkBorderless.Checked) { $arguments += '--window-borderless' }
    if ($chkOnTop.Checked) { $arguments += '--always-on-top' }
    if ($chkScreenOff.Checked) { $arguments += '-S' }
    if ($chkStayAwake.Checked) { $arguments += '-w' }
    if ($chkNoAudio.Checked) { $arguments += '--no-audio' }
    if ($chkViewOnly.Checked) { $arguments += '--no-control' }
    if ($chkPowerOff.Checked) { $arguments += '--power-off-on-close' }
    if ($chkNoScreensaver.Checked) { $arguments += '--disable-screensaver' }

    $startApp = Get-StartAppValue
    if ($startApp) { $arguments += "--start-app=$startApp" }

    if ($chkRecord.Checked) {
        $file = $txtRecord.Text.Trim()
        if (-not $file) {
            $file = Join-Path ([Environment]::GetFolderPath('MyVideos')) ("scrcpy-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
            $txtRecord.Text = $file
        }
        $arguments += "--record=$file"

        if ("$($cmbRecordFormat.SelectedItem)" -ne 'from the name') {
            $arguments += "--record-format=$($cmbRecordFormat.SelectedItem)"
        }
        if ("$($cmbRecordOrientation.SelectedItem)" -ne '0') {
            $arguments += "--record-orientation=$($cmbRecordOrientation.SelectedItem)"
        }
    }

    $arguments += Get-MoreScrcpyArguments
    $arguments += Get-HidArguments
    $arguments += Get-ExtraScrcpyArguments

    return $arguments
}


function Get-MoreScrcpyArguments {
    # everything from the "More scrcpy options" page, left out when untouched
    $arguments = @()

    if ("$($cmbOrientation.SelectedItem)" -ne 'as it comes') {
        $arguments += "--orientation=$($cmbOrientation.SelectedItem)"
    }
    if ("$($cmbCaptureOrientation.SelectedItem)" -ne 'as it comes') {
        $arguments += "--capture-orientation=$($cmbCaptureOrientation.SelectedItem)"
    }

    if ($chkNewDisplay.Checked) {
        if ("$($cmbImePolicy.SelectedItem)" -ne 'leave it alone') {
            $arguments += "--display-ime-policy=$($cmbImePolicy.SelectedItem)"
        }
        if ($chkNoDecorations.Checked) { $arguments += '--no-vd-system-decorations' }
        if ($chkKeepContent.Checked) { $arguments += '--no-vd-destroy-content' }
    }

    foreach ($pair in @(@($txtWindowX, '--window-x'), @($txtWindowY, '--window-y'),
            @($txtWindowW, '--window-width'), @($txtWindowH, '--window-height'))) {
        $value = $pair[0].Text.Trim()
        if ($value -match '^-?\d+$') { $arguments += ($pair[1] + '=' + $value) }
    }

    $timeout = $txtScreenOffTimeout.Text.Trim()
    if ($timeout -match '^\d+$' -and [int]$timeout -gt 0) { $arguments += "--screen-off-timeout=$timeout" }

    if ($numTimeLimit.Value -gt 0) { $arguments += "--time-limit=$([int]$numTimeLimit.Value)" }
    if ($chkPrintFps.Checked) { $arguments += '--print-fps' }

    if ("$($cmbShortcutMod.SelectedItem)" -notlike 'default*') {
        $arguments += "--shortcut-mod=$($cmbShortcutMod.SelectedItem)"
    }
    $bind = $txtMouseBind.Text.Trim()
    if ($bind) { $arguments += "--mouse-bind=$bind" }

    if ($chkPreferText.Checked) { $arguments += '--prefer-text' }
    if ($chkRawKeys.Checked) { $arguments += '--raw-key-events' }
    if ($chkNoKeyRepeat.Checked) { $arguments += '--no-key-repeat' }
    if ($chkLegacyPaste.Checked) { $arguments += '--legacy-paste' }
    if ($chkKillAdb.Checked) { $arguments += '--kill-adb-on-close' }
    if ($chkNoCleanup.Checked) { $arguments += '--no-cleanup' }

    return $arguments
}

function Start-WirelessPairing {
    <#
        Android 11 and newer show a pairing code under
        Developer options > Wireless debugging > Pair device with pairing code.
        adb pair takes that host:port and the six digits.
    #>
    $target = [Microsoft.VisualBasic.Interaction]::InputBox(
        "On the phone open" + "`r`n" +
        "Developer options > Wireless debugging > Pair device with pairing code." + "`r`n`r`n" +
        "Type the IP and port it shows (for example 192.168.1.20:37251):",
        'Pair over Wi-Fi', '')
    if (-not "$target".Trim()) { return }
    $target = $target.Trim()

    $code = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Now the six digit pairing code for $target :", 'Pair over Wi-Fi', '')
    if (-not "$code".Trim()) { return }

    Write-Log "adb pair $target ..." $colorStep
    $result = Invoke-Adb -CommandArguments @('pair', $target, $code.Trim())
    $text = ($result.Lines | Where-Object { $_.Trim() }) -join ' '
    if ($text -match 'Successfully paired') {
        Write-Log $text.Trim() $colorGood

        # pairing and debugging use different ports, so ask for the second one
        $connectTo = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Paired." + "`r`n`r`n" +
            "The same screen shows a second IP and port under 'IP address and port'." + "`r`n" +
            "Type it to connect now, or leave it empty:",
            'Connect over Wi-Fi', ($target -replace ':\d+$', ':5555'))
        if ("$connectTo".Trim()) {
            $connect = Invoke-Adb -CommandArguments @('connect', $connectTo.Trim())
            Write-Log (($connect.Lines | Where-Object { $_.Trim() }) -join ' ') $colorInfo
            Update-DeviceList
        }
    } else {
        Write-Log ("pairing failed: " + $text.Trim()) $colorBad
        Write-Log 'The code expires quickly - open the pairing screen again and retry.' $colorInfo
    }
}

function Show-MdnsDevices {
    Write-Log 'Looking for phones advertising wireless debugging ...' $colorStep

    $check = Invoke-Adb -CommandArguments @('mdns', 'check')
    Write-Log ((($check.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()) $colorInfo

    $result = Invoke-Adb -CommandArguments @('mdns', 'services')
    $lines = @($result.Lines | Where-Object { $_.Trim() })
    if ($lines.Count -le 1) {
        Write-Log 'Nothing is advertising. Wireless debugging must be on, and the phone on this network.' $colorWarn
        return
    }
    foreach ($line in $lines) { Write-Log ("  " + $line.Trim()) $colorInfo }
}

function Invoke-Reconnect {
    $serial = Get-SelectedSerial
    $arguments = if ($serial) { @('-s', $serial, 'reconnect') } else { @('reconnect') }
    $result = Invoke-Adb -CommandArguments $arguments
    Write-Log ((($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()) $colorInfo
    Wait-Pumped -Milliseconds 1500
    Update-DeviceList
}

function Save-BugReport {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Bug report (*.zip)|*.zip'
    $dialog.FileName = "bugreport-$serial-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip'
    $dialog.InitialDirectory = $txtFileLocal.Text
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Write-Log "Collecting a bug report from $serial. This takes a few minutes ..." $colorStep
    # the busy strip names it while it runs; this label belongs to the sharing,
    # and emptying it afterwards used to wipe what the sharing had put there
    $result = Invoke-OffThread -FilePath $script:adbPath `
        -ArgumentList @('-s', $serial, 'bugreport', $dialog.FileName) -TimeoutMs 900000

    if (Test-Path -LiteralPath $dialog.FileName) {
        $size = (Get-Item -LiteralPath $dialog.FileName).Length
        Write-Log ("Saved " + $dialog.FileName + " (" + (Format-FileSize -Bytes $size) + ").") $colorGood
    } else {
        foreach ($line in @($result.Lines | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
            Write-Log ("  " + $line) $colorBad
        }
        Write-Log 'No file arrived. Older phones need "adb bugreport" without a path.' $colorWarn
    }
}

function Start-Scrcpy {
    if (-not $script:scrcpyPath) {
        Write-Log 'scrcpy.exe was not found next to this script nor in PATH.' $colorBad
        return
    }

    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }
    $serial = $serials[0]

    if ($chkOtg.Checked) {
        $usb = @($serials | Where-Object { $_ -notmatch ':\d+$' })
        if ($usb.Count -eq 0) {
            Write-Log 'OTG needs a USB connection - the selected devices are over TCP/IP.' $colorBad
            return
        }
        if ($usb.Count -lt $serials.Count) {
            Write-Log 'Skipping the TCP/IP devices: OTG is USB only.' $colorWarn
        }
        $serials = $usb
        if ($script:relayProcess) {
            # scrcpy --otg kills the adb server on startup, which tears down the
            # gnirehtet reverse tunnel. Rebuild it right after OTG comes up.
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'OTG kills the adb server, which drops the gnirehtet tunnel.' + [Environment]::NewLine +
                'The tunnel will be rebuilt automatically a few seconds after OTG starts. Continue?',
                'OTG', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        Write-Log 'OTG: mirroring is disabled; LAlt / LSuper releases the mouse capture.' $colorWarn
    }

    # One window per device, cascaded so they do not land on top of each other.
    $index = 0
    foreach ($current in $serials) {
        $arguments = Get-ScrcpyArguments -Serial $current
        if ($serials.Count -gt 1) {
            $arguments += "--window-title=$current"
            $arguments += "--window-x=$(60 + $index * 80)"
            $arguments += "--window-y=$(60 + $index * 60)"
        }

        Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

        $stdout = Join-Path $env:TEMP ("androiddc-$PID.scrcpy-$index.out")
        $stderr = Join-Path $env:TEMP ("androiddc-$PID.scrcpy-$index.err")
        $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -PassThru `
            -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $script:scrcpyProcesses += $process

        # give it a moment: a bad option or a busy device makes it quit at once
        Wait-Pumped -Milliseconds 2500
        $process.Refresh()

        if ($process.HasExited) {
            $null = $process.WaitForExit(1000)
            $code = $null
            try { $code = $process.ExitCode } catch { }
            Write-Log "scrcpy quit immediately (exit $(if ($null -eq $code) { '?' } else { $code })) for $current." $colorBad
            foreach ($file in @($stdout, $stderr)) {
                if (Test-Path -LiteralPath $file) {
                    $text = (Get-Content -LiteralPath $file -Tail 8) -join [Environment]::NewLine
                    if ($text.Trim()) { Write-Log $text $colorWarn }
                }
            }
        } else {
            Write-Log "scrcpy started for $current (PID $($process.Id), window '$($process.MainWindowTitle)')." $colorGood
        }

        $index++
    }

    if ($chkOtg.Checked -and $script:relayProcess -and $script:activeSerials.Count -gt 0) {
        Wait-Pumped -Milliseconds 4000
        Write-Log 'Rebuilding the gnirehtet tunnel that OTG tore down ...' $colorStep
        foreach ($current in $script:activeSerials) { Repair-Tunnel -Serial $current }
    }
}

function Close-Scrcpy {
    $closed = 0
    foreach ($process in $script:scrcpyProcesses) {
        try {
            if (-not $process.HasExited) { $process.Kill(); $closed++ }
        } catch { }
    }
    $script:scrcpyProcesses = @()
    Write-Log "Closed $closed scrcpy window(s)." $colorInfo
}

# --- adb tools ---------------------------------------------------------------

function Get-DeviceIp {
    param([string]$Serial)

    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ip', '-f', 'inet', 'addr', 'show', 'wlan0')
    if ($result.Text -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    # Older/locked-down ROMs answer nothing to 'ip route', so try the other sources.
    $route = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ip', 'route')
    if ($route.Text -match 'wlan0.+src\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($route.Text -match 'src\s+(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    $prop = Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'dhcp.wlan0.ipaddress')
    if ($prop.Text -match '(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    $ifconfig = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ifconfig', 'wlan0')
    if ($ifconfig.Text -match 'inet\s+addr:?\s*(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }

    return $null
}

function Enable-WirelessAdb {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $ip = Get-DeviceIp -Serial $serial
    if (-not $ip) {
        Write-Log 'Could not read the device Wi-Fi address. Connect the phone to Wi-Fi first.' $colorBad
        return
    }

    Write-Log "Device IP: $ip - switching adb to TCP/IP ..." $colorStep
    $null = Invoke-Adb -CommandArguments @('-s', $serial, 'tcpip', '5555')
    Wait-Pumped -Milliseconds 2000

    $connect = Invoke-Adb -CommandArguments @('connect', "${ip}:5555")
    Write-Log $connect.Text $colorInfo
    $txtConnect.Text = "${ip}:5555"

    if ($connect.Text -match 'connected') {
        Write-Log 'Wireless ADB ready - you can unplug the cable now.' $colorGood
    } else {
        Write-Log 'Connection failed. Same Wi-Fi network on both sides?' $colorBad
    }
    Update-DeviceList
}

function Connect-Wireless {
    $target = $txtConnect.Text.Trim()
    if (-not $target) { Write-Log 'Enter ip:port first.' $colorWarn; return }
    if ($target -notmatch ':\d+$') { $target = "${target}:5555" }

    $result = Invoke-Adb -CommandArguments @('connect', $target)
    Write-Log $result.Text $(if ($result.Text -match 'connected') { $colorGood } else { $colorBad })
    Update-DeviceList
}

function Disconnect-Wireless {
    $result = Invoke-Adb -CommandArguments @('disconnect')
    Write-Log $result.Text $colorInfo
    Update-DeviceList
}

function Restart-AdbServer {
    Write-Log 'Restarting the adb server ...' $colorStep
    $null = Invoke-Adb -CommandArguments @('kill-server')
    Wait-Pumped -Milliseconds 500
    $null = Invoke-Adb -CommandArguments @('start-server')
    Update-DeviceList
    Write-Log 'ADB server restarted.' $colorGood
}

function Install-Apk {
    <#
        Handles the three shapes an Android package arrives in:
          one .apk                     -> adb install -r
          several .apk chosen together -> adb install-multiple (a split app)
          .xapk / .apks / .apkm        -> a zip of splits, unpacked first
        A plain "adb install" fails on the last two, which is what most
        downloads look like today.
    #>
    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Any Android package (*.apk;*.apks;*.xapk;*.apkm)|*.apk;*.apks;*.xapk;*.apkm|' +
        'Single APK (*.apk)|*.apk|Split bundle (*.apks;*.xapk;*.apkm)|*.apks;*.xapk;*.apkm|All files (*.*)|*.*'
    $dialog.Multiselect = $true
    $dialog.Title = 'Install - pick one package, or several splits of the same app'
    $dialog.InitialDirectory = $txtFileLocal.Text
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $chosen = @($dialog.FileNames)
    $unpacked = $null

    try {
        # a bundle is a zip; take every apk out of it
        if ($chosen.Count -eq 1 -and $chosen[0] -match '\.(xapk|apks|apkm)$') {
            $bundle = $chosen[0]
            Write-Log "Unpacking $([System.IO.Path]::GetFileName($bundle)) ..." $colorStep
            $unpacked = Join-Path $env:TEMP ("androiddc-$PID.bundle-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory -Path $unpacked -Force
            try {
                if (-not ('System.IO.Compression.ZipFile' -as [type])) {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                }
                [System.IO.Compression.ZipFile]::ExtractToDirectory($bundle, $unpacked)
            } catch {
                Write-Log "That file is not a readable bundle: $($_.Exception.Message)" $colorBad
                return
            }

            $chosen = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter *.apk |
                Sort-Object { $_.Name -notlike 'base*' }, Name | ForEach-Object { $_.FullName })
            if ($chosen.Count -eq 0) {
                Write-Log 'The bundle holds no .apk at all - nothing to install.' $colorBad
                return
            }
            Write-Log ("  found $($chosen.Count) apk(s): " + (($chosen | ForEach-Object {
                [System.IO.Path]::GetFileName($_) }) -join ', ')) $colorInfo
        }

        $split = $chosen.Count -gt 1
        foreach ($serial in $serials) {
            if ($split) {
                Write-Log "Installing $($chosen.Count) splits on $serial ..." $colorStep
                $arguments = @('-s', $serial, 'install-multiple', '-r') + $chosen
            } else {
                Write-Log "Installing $([System.IO.Path]::GetFileName($chosen[0])) on $serial ..." $colorStep
                $arguments = @('-s', $serial, 'install', '-r', $chosen[0])
            }

            $result = Invoke-Adb -CommandArguments $arguments
            $text = $result.Text.Trim()
            if ($text -match 'Success') {
                Write-Log "  installed on $serial." $colorGood
            } else {
                Write-Log ("  " + $text) $colorBad
                if ($text -match 'INSTALL_FAILED_INVALID_APK|Split.*required|INSTALL_FAILED_MISSING_SPLIT') {
                    Write-Log '  this app is split: pick every apk of the set together, or its .xapk.' $colorInfo
                } elseif ($text -match 'INSTALL_FAILED_USER_RESTRICTED') {
                    Write-Log '  the phone refused, not the file. Turn on "Install via USB" in developer options' $colorInfo
                    Write-Log '  (MIUI and ColorOS keep it off, and MIUI asks for a signed in account first).' $colorInfo
                } elseif ($text -match 'INSTALL_FAILED_VERSION_DOWNGRADE') {
                    Write-Log '  an older version than the one installed; uninstall it first.' $colorInfo
                } elseif ($text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
                    Write-Log '  a different signing key than the installed copy; uninstall it first.' $colorInfo
                } elseif ($text -match 'INSTALL_FAILED_INSUFFICIENT_STORAGE') {
                    Write-Log '  the phone is out of space.' $colorInfo
                } elseif ($text -match 'INSTALL_FAILED_NO_MATCHING_ABIS') {
                    Write-Log '  these splits are built for another CPU than this phone.' $colorInfo
                }
            }
        }
    } finally {
        if ($unpacked -and (Test-Path -LiteralPath $unpacked)) {
            Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Update-DeviceList
}

function Get-DeviceScreenshot {
    foreach ($serial in @(Get-SelectedSerials)) { Get-OneScreenshot -Serial $serial }
}

function Get-OneScreenshot {
    param([string]$Serial)

    $serial = $Serial
    $target = Join-Path ([Environment]::GetFolderPath('MyPictures')) ("android-$serial-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    Write-Log 'Taking a screenshot ...' $colorStep
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('screencap', '-p', '/sdcard/_gui_shot.png')
    $null = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', '/sdcard/_gui_shot.png', $target)
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('rm', '/sdcard/_gui_shot.png')

    if (Test-Path -LiteralPath $target) {
        Write-Log "Saved to $target" $colorGood
        Show-CaptureFile -Path $target -Serial $serial
    } else {
        Write-Log 'Screenshot failed.' $colorBad
    }
}

function Switch-Screen {
    foreach ($serial in @(Get-SelectedSerials)) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '26')
        Write-Log "Sent the power key to $serial (screen on/off)." $colorInfo
    }
}

function Set-DeviceWifi {
    param([bool]$Enabled)

    $action = if ($Enabled) { 'enable' } else { 'disable' }
    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'wifi', $action)
        if ($result.Text.Trim()) { Write-Log $result.Text $colorWarn }
        Write-Log "Wi-Fi $action requested on $serial." $colorInfo
    }
}

function Restart-Device {
    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show("Reboot these devices?" +
        [Environment]::NewLine + ($serials -join [Environment]::NewLine), 'Reboot', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($serial in $serials) {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'reboot')
        Write-Log "Reboot sent to $serial." $colorWarn
    }
}

function Get-DeviceReport {
    param([string]$Serial)

    $lines = @("Device : $Serial")

    $props = [ordered]@{
        'Model'    = 'ro.product.model'
        'Brand'    = 'ro.product.brand'
        'Name'     = 'ro.product.name'
        'Android'  = 'ro.build.version.release'
        'SDK'      = 'ro.build.version.sdk'
        'Build'    = 'ro.build.display.id'
        'ABI'      = 'ro.product.cpu.abi'
        'Serialno' = 'ro.serialno'
    }
    foreach ($key in $props.Keys) {
        $value = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', $props[$key])).Text.Trim()
        $lines += ('{0,-9}: {1}' -f $key, $value)
    }

    $size = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('wm', 'size')).Text.Trim() -replace "`r?`n", ' / '
    $density = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('wm', 'density')).Text.Trim() -replace "`r?`n", ' / '
    $lines += ('{0,-9}: {1}  |  {2}' -f 'Screen', $size, $density)

    $lines += ('{0,-9}: {1}' -f 'Battery', (Get-BatteryLine -Serial $Serial))
    $lines += ('{0,-9}: {1}' -f 'Network', (Get-SignalLine -Serial $Serial))

    $ip = Get-DeviceIp -Serial $Serial
    $lines += ('{0,-9}: {1}' -f 'Wi-Fi IP', $(if ($ip) { $ip } else { 'none' }))

    $storage = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('df -h /data | tail -1')).Text.Trim()
    if ($storage) { $lines += ('{0,-9}: {1}' -f 'Storage', $storage) }

    $uptime = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('uptime')).Text.Trim()
    if ($uptime) { $lines += ('{0,-9}: {1}' -f 'Uptime', $uptime) }

    $client = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'packages', $packageName)).Text
    $lines += ('{0,-9}: {1}' -f 'gnirehtet', $(if ($client -match 'package:') { 'client installed' } else { 'client not installed' }))

    return ($lines -join [Environment]::NewLine)
}

function Show-DeviceTab {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $tabs.SelectedTab = $tabDevice
    $txtDeviceInfo.ForeColor = [System.Drawing.Color]::Black
    $txtDeviceInfo.Text = "reading $serial ..."
    $form.Refresh()

    $txtDeviceInfo.Text = Get-DeviceReport -Serial $serial
    Write-Log "Loaded details for $serial." $colorInfo
    Update-Capture -Quiet
}

function Show-Notifications {
    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'statusbar', 'expand-notifications')
    Write-Log "opened the notification panel on $serial" $colorInfo
    Wait-Pumped -Milliseconds 700
    Update-Capture -Quiet
}


function Get-DeviceCapabilityList {
    <#
        Asks scrcpy what this phone actually supports and returns the lines it
        printed. scrcpy writes these lists to stderr and exits, so a plain call
        is enough - there is no session to keep.
    #>
    param([string]$Serial, [string]$Switch)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return @() }

    Write-Log "scrcpy $Switch ..." $colorStep
    $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $Serial, $Switch) -TimeoutMs 60000
    return @($result.Lines | Where-Object { $_ -and $_.Trim() })
}

function Update-EncoderList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $lines = Get-DeviceCapabilityList -Serial $serial -Switch '--list-encoders'
    # scrcpy prints one line per encoder, in the shape
    #     --video-codec=h264 --video-encoder=c2.mtk.avc.encoder   (hw) [vendor]
    $video = @()
    $audio = @()
    $encoders = @()
    foreach ($line in $lines) {
        if ($line -match '--video-codec=(\S+)') { $video += $Matches[1] }
        elseif ($line -match '--audio-codec=(\S+)\s+--audio-encoder=(\S+)') {
            $codec = $Matches[1]
            $name = $Matches[2]
            $audio += $codec
            # an alias is the same encoder under a second name: offer it once
            if ($line -notmatch 'alias for') {
                $encoders += [PSCustomObject]@{ Codec = $codec; Name = $name }
            }
        }
        elseif ($line -match '--audio-codec=(\S+)') { $audio += $Matches[1] }
    }
    $video = @($video | Sort-Object -Unique)
    $audio = @($audio | Sort-Object -Unique)

    if ($video.Count -gt 0) {
        $keep = "$($cmbCodec.SelectedItem)"
        $cmbCodec.Items.Clear()
        $null = $cmbCodec.Items.Add('default')
        $null = $cmbCodec.Items.AddRange($video)
        $cmbCodec.SelectedIndex = [Math]::Max(0, $cmbCodec.Items.IndexOf($keep))
        Write-Log ("video codecs on this phone: " + ($video -join ', ')) $colorGood
    }
    if ($audio.Count -gt 0) {
        $keep = "$($cmbAudioCodec.SelectedItem)"
        $cmbAudioCodec.Items.Clear()
        $null = $cmbAudioCodec.Items.Add('default')
        $null = $cmbAudioCodec.Items.AddRange($audio)
        # raw is not an encoder, so the phone never lists it - yet scrcpy
        # accepts it, and a refresh must not take a working choice away
        if (-not $cmbAudioCodec.Items.Contains('raw')) { $null = $cmbAudioCodec.Items.Add('raw') }
        $script:audioEncoders = $encoders
        $cmbAudioCodec.SelectedIndex = [Math]::Max(0, $cmbAudioCodec.Items.IndexOf($keep))
        Update-AudioEncoderChoices
        Write-Log ("audio codecs on this phone: " + ($audio -join ', ')) $colorGood
        Write-Log ("audio encoders: " + (($encoders | ForEach-Object { $_.Name }) -join ', ')) $colorGood
    }
    if ($video.Count -eq 0 -and $audio.Count -eq 0) {
        Write-Log 'scrcpy listed no encoders; the fixed choices are still there.' $colorWarn
        foreach ($line in ($lines | Select-Object -Last 3)) { Write-Log ("  " + $line) $colorInfo }
    }
}

function Update-AudioEncoderChoices {
    <#
        scrcpy refuses an encoder that does not produce the chosen codec, so
        only the matching ones are offered. "default" leaves the choice to the
        phone. Before the phone has been asked there is nothing to offer, and
        the list stays disabled rather than pretending.
    #>
    $codec = "$($cmbAudioCodec.SelectedItem)"
    if ($codec -eq 'default') { $codec = 'opus' }   # scrcpy's own default

    $keep = "$($cmbAudioEncoder.SelectedItem)"
    $cmbAudioEncoder.BeginUpdate()
    $cmbAudioEncoder.Items.Clear()
    $null = $cmbAudioEncoder.Items.Add('default')
    foreach ($encoder in @($script:audioEncoders)) {
        if ($encoder.Codec -eq $codec) { $null = $cmbAudioEncoder.Items.Add($encoder.Name) }
    }
    $cmbAudioEncoder.EndUpdate()
    $cmbAudioEncoder.SelectedIndex = [Math]::Max(0, $cmbAudioEncoder.Items.IndexOf($keep))
    $cmbAudioEncoder.Enabled = ($cmbAudioEncoder.Items.Count -gt 1)
}

function Update-CameraSizeList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $lines = Get-DeviceCapabilityList -Serial $serial -Switch '--list-camera-sizes'
    $sizes = @()
    foreach ($line in $lines) {
        foreach ($match in [regex]::Matches($line, '\b(\d{3,5}x\d{3,5})\b')) { $sizes += $match.Groups[1].Value }
    }
    # widest first, so the useful ones are at the top
    $sizes = @($sizes | Sort-Object -Unique | Sort-Object -Property @{
        Expression = { [int](($_ -split 'x')[0]) } } -Descending)

    if ($sizes.Count -eq 0) {
        Write-Log 'scrcpy listed no camera sizes; the fixed choices are still there.' $colorWarn
        foreach ($line in ($lines | Select-Object -Last 3)) { Write-Log ("  " + $line) $colorInfo }
        return
    }

    $keep = $cmbCameraSize.Text
    $cmbCameraSize.Items.Clear()
    $null = $cmbCameraSize.Items.AddRange($sizes)
    $null = $cmbCameraSize.Items.Add('sensor max')
    $cmbCameraSize.Text = $keep
    Write-Log ("$($sizes.Count) camera size(s) reported by $serial.") $colorGood
}

function Get-AudioFileKind {
    <#
        scrcpy picks the container from the file name, and each container
        takes only some codecs - an .opus file cannot hold aac. So the name
        offered for a recording follows the codec. .mka takes all of them.
    #>
    param([string]$Codec)

    switch ($Codec) {
        'aac' { return 'm4a' }
        'flac' { return 'flac' }
        'raw' { return 'wav' }
        default { return 'opus' }   # opus, and "default", which is opus
    }
}

function Get-AudioArguments {
    <#
        The scrcpy command line for Listen and Record, built without starting
        anything, so what gets sent can be checked on its own. A choice that
        cannot apply is dropped with a line in the log saying why.
    #>
    param([string]$Serial, [switch]$ToFile)

    $source = "$($cmbAudioSource.SelectedItem)"
    $arguments = @('-s', $Serial, '--no-video', "--audio-source=$source")

    $codec = "$($cmbAudioCodec.SelectedItem)"
    if ($codec -and $codec -ne 'default') { $arguments += "--audio-codec=$codec" }

    $encoder = "$($cmbAudioEncoder.SelectedItem)"
    if ($encoder -and $encoder -ne 'default') { $arguments += "--audio-encoder=$encoder" }

    $rate = $cmbAudioBitrate.Text.Trim()
    if ($rate -and $rate -ne 'default') { $arguments += "--audio-bit-rate=$rate" }

    $buffer = $txtAudioBuffer.Text.Trim()
    if ($buffer -match '^\d+$') { $arguments += "--audio-buffer=$buffer" }

    if ($chkAudioDup.Checked) {
        # --audio-dup needs the output source, and needs playback left on:
        # scrcpy refuses it outright while recording, which turns playback off
        if ($ToFile) {
            Write-Log "'keep playing on the phone' cannot be used while recording; recording without it." $colorWarn
        } elseif ($source -ne 'output') {
            Write-Log "'keep playing on the phone' works with the output source only, not '$source'." $colorWarn
        } else {
            $arguments += '--audio-dup'
        }
    }

    return $arguments
}

function Start-AudioListen {
    param([switch]$ToFile)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $source = "$($cmbAudioSource.SelectedItem)"
    $arguments = @(Get-AudioArguments -Serial $serial -ToFile:$ToFile)

    if ($ToFile) {
        $kind = Get-AudioFileKind -Codec "$($cmbAudioCodec.SelectedItem)"
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Opus (*.opus)|*.opus|MP4 audio (*.m4a)|*.m4a|FLAC (*.flac)|*.flac|' +
            'WAV (*.wav)|*.wav|Matroska audio (*.mka)|*.mka'
        $dialog.FilterIndex = 1 + [array]::IndexOf(@('opus', 'm4a', 'flac', 'wav'), $kind)
        $dialog.FileName = "phone-audio-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".$kind"
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $arguments += @('--no-playback', "--record=$($dialog.FileName)")
    } else {
        $arguments += '--no-window'
    }

    Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep
    $script:audioProcess = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -NoNewWindow -PassThru
    $btnListenStop.Enabled = $true
    $btnListen.Enabled = $false
    Write-Log "Listening to '$source' on $serial (PID $($script:audioProcess.Id))." $colorGood
    Write-Log 'Android shows a "recording" indicator while the mic is captured.' $colorWarn
}

function Stop-AudioListen {
    if ($script:audioProcess) {
        try { if (-not $script:audioProcess.HasExited) { $script:audioProcess.Kill() } } catch { }
        $script:audioProcess = $null
        Write-Log 'Audio stream stopped.' $colorWarn
    }
    $btnListenStop.Enabled = $false
    $btnListen.Enabled = $true
}

function Show-DeviceInfo {
    foreach ($serial in @(Get-SelectedSerials)) { Show-OneDeviceInfo -Serial $serial }
}

function Show-OneDeviceInfo {
    param([string]$Serial)

    $serial = $Serial
    $props = @{
        'Model'       = 'ro.product.model'
        'Brand'       = 'ro.product.brand'
        'Android'     = 'ro.build.version.release'
        'SDK'         = 'ro.build.version.sdk'
        'ABI'         = 'ro.product.cpu.abi'
    }

    Write-Log "--- $serial ---" $colorStep
    foreach ($key in @('Model', 'Brand', 'Android', 'SDK', 'ABI')) {
        $value = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', $props[$key])).Text.Trim()
        Write-Log ("{0,-8}: {1}" -f $key, $value) $colorInfo
    }

    $size = (Invoke-DeviceShell -Serial $serial -CommandArguments @('wm', 'size')).Text.Trim()
    $density = (Invoke-DeviceShell -Serial $serial -CommandArguments @('wm', 'density')).Text.Trim()
    Write-Log ("Screen  : $size / $density" -replace "`n", ' ') $colorInfo

    $ip = Get-DeviceIp -Serial $serial
    Write-Log ("Wi-Fi IP: " + $(if ($ip) { $ip } else { 'none' })) $colorInfo
}

function Show-BatteryAndNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $battery = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'battery')).Text
    foreach ($key in @('level', 'status', 'temperature')) {
        if ($battery -match "(?m)^\s*$key\s*:\s*(.+)$") {
            Write-Log ("Battery {0,-12}: {1}" -f $key, $Matches[1].Trim()) $colorInfo
        }
    }

    $network = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'connectivity', '--short')).Text
    if (-not $network.Trim()) {
        $network = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ip', 'route')).Text
    }
    Write-Log $network $colorInfo
}

function Show-ReverseTunnels {
    $serial = Get-SelectedSerial
    $arguments = if ($serial) { @('-s', $serial, 'reverse', '--list') } else { @('reverse', '--list') }
    $result = Invoke-Adb -CommandArguments $arguments
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorInfo
    } else {
        Write-Log 'No reverse tunnel.' $colorInfo
    }
}

function Stop-StrayRelays {
    $mine = if ($script:relayProcess) { $script:relayProcess.Id } else { -1 }
    $processes = @(Get-Process gnirehtet -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $mine })

    if ($processes.Count -eq 0) {
        Write-Log 'No stray gnirehtet process.' $colorInfo
        return
    }

    $list = ($processes | ForEach-Object { "PID $($_.Id)" }) -join ', '
    $answer = [System.Windows.Forms.MessageBox]::Show("Kill these gnirehtet processes?" +
        [Environment]::NewLine + $list, 'Gnirehtet', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Write-Log "Killed PID $($process.Id)." $colorInfo
    }
}

function Show-ScrcpyDisplays {
    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $ErrorActionPreference = 'Continue'
    $output = @(& $script:scrcpyPath -s $serial --list-displays 2>&1) | ForEach-Object { "$_" }
    Write-Log ($output -join "`n") $colorInfo

    $cmbDisplay.Items.Clear()
    foreach ($line in $output) {
        if ($line -match '--display-id=(\d+)') { $null = $cmbDisplay.Items.Add($Matches[1]) }
    }
    if ($cmbDisplay.Items.Count -eq 0) { $null = $cmbDisplay.Items.Add('0') }
}

# --- battery / signal / toggles ----------------------------------------------

function Get-BatteryLine {
    param([string]$Serial)

    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys', 'battery')).Text

    $level = if ($dump -match '(?m)^\s*level:\s*(\d+)') { $Matches[1] } else { '?' }
    $status = if ($dump -match '(?m)^\s*status:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $temperature = if ($dump -match '(?m)^\s*temperature:\s*(\d+)') { [int]$Matches[1] } else { $null }

    # BatteryManager.BATTERY_STATUS_*
    $statusText = switch ($status) {
        2 { 'charging' }
        3 { 'discharging' }
        4 { 'not charging' }
        5 { 'full' }
        default { 'unknown' }
    }

    $line = "battery $level% ($statusText"
    if ($null -ne $temperature) { $line += ', ' + ('{0:N1}' -f ($temperature / 10)) + ' C' }
    return $line + ')'
}

function Get-SignalLine {
    param([string]$Serial)

    $operator = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.operator.alpha')).Text.Trim()
    $network = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.network.type')).Text.Trim()
    $sim = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop', 'gsm.sim.state')).Text.Trim()

    if (-not $sim -or $sim -match 'ABSENT|UNKNOWN' -and -not $operator) {
        return 'no SIM'
    }

    # one long line holds every radio's CellSignalStrength*
    $strength = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys telephony.registry | grep -m1 mSignalStrength')).Text

    $best = $null
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
        if ($level -gt 0 -and $null -ne $dbm -and (-not $best -or $level -gt $best.Level)) {
            $best = [PSCustomObject]@{ Level = $level; Dbm = $dbm }
        }
    }

    $parts = @()
    if ($operator) { $parts += $operator }
    if ($network) { $parts += $network }
    if ($best) {
        $parts += "signal $($best.Level)/4 ($($best.Dbm) dBm)"
    } else {
        $parts += 'signal unknown'
    }
    return ($parts -join '  |  ')
}

function Update-DeviceStatus {
    $serial = Get-SelectedSerial
    if (-not $serial -or $lstDevices.SelectedItems.Count -eq 0 -or
        $lstDevices.SelectedItems[0].SubItems[4].Text -ne 'device') {
        $lblDeviceStatus.Text = 'select a ready device to read its battery, signal and screen'
        $toolTip.SetToolTip($lblDeviceStatus, '')
        return
    }

    $lblDeviceStatus.Text = "$serial : reading ..."
    $form.Refresh()

    $battery = Get-BatteryLine -Serial $serial
    $signal = Get-SignalLine -Serial $serial
    $screen = Get-DeviceScreenState -Serial $serial

    $parts = @($serial, $battery, $signal)
    if ($null -ne $screen.ScreenOn) { $parts += $(if ($screen.ScreenOn) { 'screen on' } else { 'SCREEN OFF' }) }
    if ($null -ne $screen.Locked) { $parts += $(if ($screen.Locked) { 'LOCKED' } else { 'unlocked' }) }
    $lblDeviceStatus.Text = ($parts -join '  |  ')
    $toolTip.SetToolTip($lblDeviceStatus, (($parts -join '  |  ') -replace '  \|  ', [Environment]::NewLine))

    # a phone that is locked or dark explains half the things that then fail
    if ($screen.Locked -or ($null -ne $screen.ScreenOn -and -not $screen.ScreenOn)) {
        $lblDeviceStatus.ForeColor = [System.Drawing.Color]::FromArgb(176, 96, 0)
    } else {
        $lblDeviceStatus.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    }
}

function Set-DeviceToggle {
    param(
        [ValidateSet('rotation', 'location', 'bluetooth', 'wifi', 'saver', 'ringvibe', 'haptics',
                     'devopts', 'showtaps', 'stayawake')]
        [string]$Feature,
        [bool]$Enabled
    )

    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    foreach ($serial in $serials) {
        switch ($Feature) {
            'rotation'  { $command = @('settings', 'put', 'system', 'accelerometer_rotation', $(if ($Enabled) { '1' } else { '0' })) }
            'location'  { $command = @('cmd', 'location', 'set-location-enabled', $(if ($Enabled) { 'true' } else { 'false' })) }
            'bluetooth' { $command = @('svc', 'bluetooth', $(if ($Enabled) { 'enable' } else { 'disable' })) }
            'wifi'      { $command = @('svc', 'wifi', $(if ($Enabled) { 'enable' } else { 'disable' })) }
            'saver'     { $command = @('settings', 'put', 'global', 'low_power', $(if ($Enabled) { '1' } else { '0' })) }
            'ringvibe'  { $command = @('settings', 'put', 'system', 'vibrate_when_ringing', $(if ($Enabled) { '1' } else { '0' })) }
            'haptics'   { $command = @('settings', 'put', 'system', 'haptic_feedback_enabled', $(if ($Enabled) { '1' } else { '0' })) }
            'devopts'   { $command = @('settings', 'put', 'global', 'development_settings_enabled', $(if ($Enabled) { '1' } else { '0' })) }
            'showtaps'  { $command = @('settings', 'put', 'system', 'show_touches', $(if ($Enabled) { '1' } else { '0' })) }
            # 3 = keep the screen on while charging over AC or USB
            'stayawake' { $command = @('settings', 'put', 'global', 'stay_on_while_plugged_in', $(if ($Enabled) { '3' } else { '0' })) }
        }

        $result = Invoke-DeviceShell -Serial $serial -CommandArguments $command
        $text = $result.Text.Trim()
        $failed = ($result.ExitCode -ne 0 -or $text -match 'Exception|Error|denied|Unknown command')
        Write-Log ("$serial : " + ($command -join ' ') + $(if ($text) { "  ->  $text" } else { '' })) `
            $(if ($failed) { $colorBad } else { $colorGood })
    }

    Show-ToggleStates
}

# what each toggle reads, in the order the log names them
$script:toggleReads = [ordered]@{
    rotation  = 'settings get system accelerometer_rotation'
    location  = 'cmd location is-location-enabled'
    bluetooth = 'settings get global bluetooth_on'
    wifi      = 'settings get global wifi_on'
    saver     = 'settings get global low_power'
    ringvibe  = 'settings get system vibrate_when_ringing'
    haptics   = 'settings get system haptic_feedback_enabled'
    devopts   = 'settings get global development_settings_enabled'
    showtaps  = 'settings get system show_touches'
    stayawake = 'settings get global stay_on_while_plugged_in'
}
$script:toggleLit = [System.Drawing.Color]::FromArgb(204, 228, 247)
$script:toggleSerial = $null

function ConvertFrom-ToggleOutput {
    # "name=value" lines into on / off / unknown ($null) per toggle
    param([string]$Text)

    $states = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^(\w+)=(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        $state = $null
        if ($key -eq 'stayawake') {
            # a bit mask of chargers: AC, USB, wireless; any of them means on
            if ($value -match '^\d+$') { $state = ([int]$value -ne 0) }
        } elseif ($value -eq '1' -or $value -eq 'true') {
            $state = $true
        } elseif ($value -eq '0' -or $value -eq 'false') {
            $state = $false
        }
        $states[$key] = $state
    }
    return $states
}

function Set-ToggleMarks {
    # The two buttons always looked the same, so the page never said whether
    # Wi-Fi was on; that went to the log only. The one matching the phone is
    # now tinted; a state the phone does not report tints neither.
    param($States)

    $pairs = @{
        rotation = @($btnRotationOn, $btnRotationOff); location = @($btnLocationOn, $btnLocationOff)
        bluetooth = @($btnBtOn, $btnBtOff); wifi = @($btnWifiOn, $btnWifiOff)
        saver = @($btnSaverOn, $btnSaverOff); ringvibe = @($btnRingVibeOn, $btnRingVibeOff)
        haptics = @($btnHapticsOn, $btnHapticsOff); devopts = @($btnDevOn, $btnDevOff)
        showtaps = @($btnTapsOn, $btnTapsOff); stayawake = @($btnAwakeOn, $btnAwakeOff)
    }
    foreach ($key in $pairs.Keys) {
        $state = $null
        if ($States -and $States.ContainsKey($key)) { $state = $States[$key] }
        for ($i = 0; $i -lt 2; $i++) {
            $button = $pairs[$key][$i]
            if ($null -ne $state -and $state -eq ($i -eq 0)) {
                $button.BackColor = $script:toggleLit
            } else {
                $button.BackColor = [System.Drawing.SystemColors]::Control
                $button.UseVisualStyleBackColor = $true
            }
        }
    }
}

function Show-ToggleStates {
    # -Quiet: read for the marks only, as the page opens or the phone changes
    param([switch]$Quiet)

    $serial = if ($Quiet) { Get-SelectedSerial } else { Get-TargetSerial }
    if (-not $serial -or $lstDevices.SelectedItems.Count -eq 0 -or
        $lstDevices.SelectedItems[0].SubItems[4].Text -ne 'device') {
        Set-ToggleMarks $null
        $script:toggleSerial = $null
        return
    }

    # one trip to the phone instead of ten
    $command = @($script:toggleReads.GetEnumerator() | ForEach-Object {
        'echo {0}=$({1} 2>/dev/null)' -f $_.Key, $_.Value }) -join '; '
    $states = ConvertFrom-ToggleOutput (Invoke-DeviceShellText -Serial $serial -Command $command).Text
    Set-ToggleMarks $states
    $script:toggleSerial = $serial
    if ($Quiet) { return }

    $torch = Get-TorchState -Serial $serial
    $words = @($script:toggleReads.Keys | ForEach-Object {
        $value = if ($null -eq $states[$_]) { '?' } elseif ($states[$_]) { 'on' } else { 'off' }
        "$_=$value" })
    Write-Log ("$serial : " + ($words -join '  ') + "  torch=$torch") $colorInfo
}

function Get-TorchState {
    param([string]$Serial)

    # the camera service logs every torch change; the newest line wins
    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys media.camera | grep -m1 Torch')).Text
    if ($dump -match 'turned (on|off)') { return $Matches[1] }
    return 'unknown'
}

function Switch-Torch {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $before = Get-TorchState -Serial $serial
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'statusbar', 'click-tile', 'com.android.systemui/.qs.tiles.FlashlightTile')
    Wait-Pumped -Milliseconds 1200
    $after = Get-TorchState -Serial $serial

    if ($after -ne $before -and $after -ne 'unknown') {
        Write-Log "Torch is now $after on $serial." $colorGood
        return
    }

    # 'flashlight' is a built-in tile, not a TileService, so click-tile is a
    # no-op on many ROMs. Fall back to the panel the user can tap in the Screen tab.
    Write-Log "The ROM ignored the torch command (torch stays $before)." $colorWarn
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 600
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'statusbar', 'expand-settings')
    Wait-Pumped -Milliseconds 800
    Update-Capture -Quiet
    Write-Log 'Opened quick settings - tap the Flashlight tile on the picture.' $colorWarn
}

function Send-Buzz {
    foreach ($serial in @(Get-SelectedSerials)) {
        $before = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'dumpsys vibrator_manager | grep -c finished')).Text.Trim()

        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'vibrator_manager', 'synced', 'oneshot', '400')
        Wait-Pumped -Milliseconds 900

        $after = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'dumpsys vibrator_manager | grep -c finished')).Text.Trim()

        if ($after -ne $before) {
            Write-Log "$serial buzzed." $colorGood
        } else {
            Write-Log "$serial : the ROM ignored the shell vibrate command." $colorWarn
        }
    }
}

# --- apps, contacts, SMS -----------------------------------------------------

function Show-InputDialog {
    param([string]$Title, [string[]]$Fields, [string[]]$Values)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.StartPosition = 'CenterParent'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(460, (60 + 34 * $Fields.Count))

    $boxes = @()
    for ($i = 0; $i -lt $Fields.Count; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Fields[$i]
        $label.SetBounds(12, (16 + 34 * $i), 100, 20)
        $dialog.Controls.Add($label)

        $box = New-Object System.Windows.Forms.TextBox
        $box.SetBounds(118, (12 + 34 * $i), 326, 24)
        if ($Values -and $i -lt $Values.Count) { $box.Text = $Values[$i] }
        $dialog.Controls.Add($box)
        $boxes += $box
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.SetBounds(248, (20 + 34 * $Fields.Count), 90, 28)
    $dialog.Controls.Add($ok)
    $dialog.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.SetBounds(346, (20 + 34 * $Fields.Count), 90, 28)
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return @($boxes | ForEach-Object { $_.Text })
}

function Split-ContentRows {
    param([string]$Text)

    # 'content query' prints one record per "Row: <n> col=val, col=val",
    # but a body may contain newlines, so split on the row marker itself.
    $rows = @()
    foreach ($chunk in ($Text -split '(?m)^Row:\s+\d+\s+')) {
        if ($chunk.Trim()) { $rows += $chunk }
    }
    return $rows
}

function Get-RowValue {
    param([string]$Row, [string]$Column, [switch]$Last)

    # values are comma separated, but a value may hold commas of its own, so a
    # column ends where the next "name=" begins rather than at the first comma
    if ($Last) {
        if ($Row -match "(?s)$Column=(.*)$") { return $Matches[1].Trim() }
    } else {
        $pattern = '(?s)' + [regex]::Escape($Column) + '=(.*?)(?=,\s+[A-Za-z_][A-Za-z_0-9]*=|$)'
        if ($Row -match $pattern) { return $Matches[1].Trim() }
    }
    return ''
}

# --- apps --------------------------------------------------------------------

function Get-AppLabels {
    <#
        The names of the apps on a phone, from scrcpy --list-apps. pm knows
        packages only, and "com.shiftatinc.worker" tells nobody which app it
        is. scrcpy prints one app per line, the name padded into a column:

             - Nafath | <arabic name>          sa.gov.nic.myid

        A name can hold spaces and even "|", but a package never holds a
        space, so the package is the last word and the name is everything
        before it. Asking takes two to five seconds, so each phone is asked
        once and the answer kept; Update-AppList asks again when the set of
        installed apps has changed.
    #>
    param([string]$Serial, [switch]$Refresh)

    if (-not $Refresh -and $script:appLabels.ContainsKey($Serial)) { return $script:appLabels[$Serial] }

    $labels = @{}
    foreach ($line in @(Get-DeviceCapabilityList -Serial $Serial -Switch '--list-apps')) {
        # "*" marks an app that came with the phone, "-" one that was installed
        if ($line -match '^\s*[*-]\s+(.*\S)\s+(\S+)\s*$') { $labels[$Matches[2]] = $Matches[1] }
    }
    if ($labels.Count -eq 0) {
        Write-Log 'scrcpy listed no app names on this phone, so packages are shown without them.' $colorWarn
    }
    # kept even when empty, so a phone that cannot answer is not asked on every refresh
    $script:appLabels[$Serial] = $labels
    return $labels
}

function Update-AppList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $scope = if ($chkAppsSystem.Checked) { '' } else { '-3' }
    $listed = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        "pm list packages --show-versioncode $scope")).Text
    $disabled = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -d')).Text
    $thirdParty = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -3')).Text

    $filter = $txtAppFilter.Text.Trim()

    # the names are read again only when the installed apps have changed -
    # an install from here, from the Play Store, or anywhere else
    # whole names, compared whole: a search for "package:com.foo" also found
    # it at the start of "package:com.foo.bar", so a system app whose name
    # begins another's took that app's user / disabled label
    $userPackages = @([regex]::Matches($thirdParty, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $disabledPackages = @([regex]::Matches($disabled, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $installed = (@($userPackages | Sort-Object) -join ' ')
    $changed = $script:appLabelsSeen.ContainsKey($serial) -and $script:appLabelsSeen[$serial] -ne $installed
    $names = Get-AppLabels -Serial $serial -Refresh:$changed
    $script:appLabelsSeen[$serial] = $installed
    $named = 0

    $lstApps.BeginUpdate()
    try {
        $lstApps.Items.Clear()
        foreach ($line in ($listed -split "`r?`n")) {
            if ($line -notmatch 'package:(\S+)') { continue }
            $package = $Matches[1]
            $version = if ($line -match 'versionCode:(\S+)') { $Matches[1] } else { '' }
            $name = if ($names.ContainsKey($package)) { $names[$package] } else { '' }
            # an app is found by what it is called, not only by its package
            if ($filter -and -not (Test-TextContains $package $filter) -and -not (Test-TextContains $name $filter)) { continue }

            $item = New-Object System.Windows.Forms.ListViewItem($package)
            $null = $item.SubItems.Add($version)
            $null = $item.SubItems.Add($(if ($userPackages -contains $package) { 'user' } else { 'system' }))
            $null = $item.SubItems.Add($(if ($disabledPackages -contains $package) { 'disabled' } else { 'enabled' }))
            $null = $item.SubItems.Add($name)
            if ($name) { $named++ }
            $null = $lstApps.Items.Add($item)
        }
    } finally {
        $lstApps.EndUpdate()
    }

    # only apps with a launcher icon have a name; services and libraries do not
    $lblAppsCount.Text = "$($lstApps.Items.Count) packages on $serial, $named of them apps with a name"
    Write-Log "Listed $($lstApps.Items.Count) packages on $serial." $colorInfo
}

function Get-SelectedPackages {
    return @($lstApps.SelectedItems | ForEach-Object { $_.Text })
}

function Get-LauncherActivity {
    param([string]$Serial, [string]$Package)

    $result = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $Package | tail -1")).Text.Trim()
    if ($result -match '^\S+/\S+$') { return $result }
    return $null
}

function Start-App {
    param([switch]$NewDisplay)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    foreach ($package in $packages) {
        if ($NewDisplay) {
            if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

            $size = $txtNewDisplay.Text.Trim()
            if (-not $size) { $size = '1920x1080/240' }
            $arguments = @('-s', $serial, "--new-display=$size", "--start-app=+$package",
                "--window-title=$package")
            Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

            $stdout = Join-Path $env:TEMP ("androiddc-$PID.app-$package.out")
            $stderr = Join-Path $env:TEMP ("androiddc-$PID.app-$package.err")
            $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -PassThru `
                -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $null = $process.Handle
            $script:scrcpyProcesses += $process
            Wait-Pumped -Milliseconds 2500
            $process.Refresh()

            if ($process.HasExited) {
                Write-Log "scrcpy could not open a display for $package (exit $($process.ExitCode))." $colorBad
                foreach ($file in @($stdout, $stderr)) {
                    if (Test-Path -LiteralPath $file) {
                        $text = (Get-Content -LiteralPath $file -Tail 6) -join [Environment]::NewLine
                        if ($text.Trim()) { Write-Log $text $colorWarn }
                    }
                }
            } else {
                # still alive is not the same as working: read what scrcpy said
                $said = ''
                if (Test-Path -LiteralPath $stdout) { $said = Get-Content -LiteralPath $stdout -Raw }
                if ($said -match 'New display: \S+ \(id=(\d+)\)') {
                    $display = $Matches[1]
                    if ($said -match 'Starting app') {
                        Write-Log "$package runs on its own display $display (PID $($process.Id))." $colorGood
                    } else {
                        Write-Log "Display $display opened but $package has not started on it yet." $colorWarn
                        Write-Log 'Unlock the phone: some ROMs refuse to launch an app on a new display while locked.' $colorInfo
                    }
                } else {
                    Write-Log "scrcpy is running (PID $($process.Id)) but has not reported a new display yet." $colorWarn
                    Write-Log 'A virtual display needs Android 11 or newer, and the phone unlocked.' $colorInfo
                }
            }
            continue
        }

        $activity = Get-LauncherActivity -Serial $serial -Package $package
        if (-not $activity) {
            Write-Log "$package has no launcher activity." $colorWarn
            continue
        }

        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-n', $activity)
        Write-Log ("$package -> " + $result.Text.Trim()) $(if ($result.Text -match 'Error') { $colorBad } else { $colorGood })
    }
}

function Stop-App {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    foreach ($package in @(Get-SelectedPackages)) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'force-stop', $package)
        Write-Log "force-stop $package" $colorInfo
    }
}

function Show-AppInfo {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.APPLICATION_DETAILS_SETTINGS', '-d', "package:$($packages[0])")
    Write-Log "Opened the system page for $($packages[0])." $colorInfo
    Wait-Pumped -Milliseconds 800
    Update-Capture -Quiet
}

function Uninstall-App {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Uninstall these apps from $serial ?" + [Environment]::NewLine + ($packages -join [Environment]::NewLine),
        'Uninstall', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($package in $packages) {
        $result = Invoke-Adb -CommandArguments @('-s', $serial, 'uninstall', $package)
        Write-Log ("uninstall $package -> " + $result.Text.Trim()) `
            $(if ($result.Text -match 'Success') { $colorGood } else { $colorBad })
    }
    Update-AppList
}

function Get-AppListCsv {
    # the name goes last, so a sheet built on the old four columns still reads;
    # it is quoted, because a name can hold a comma or a quote and the rest cannot
    $lines = @('package,version,type,state,name')
    foreach ($item in $lstApps.Items) {
        $name = '"' + $item.SubItems[4].Text.Replace('"', '""') + '"'
        $lines += ('{0},{1},{2},{3},{4}' -f $item.Text, $item.SubItems[1].Text, $item.SubItems[2].Text,
            $item.SubItems[3].Text, $name)
    }
    return $lines
}

function Export-AppList {
    if ($lstApps.Items.Count -eq 0) { Write-Log 'Nothing to export.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt'
    $dialog.FileName = 'apps-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Set-Content -LiteralPath $dialog.FileName -Value (Get-AppListCsv) -Encoding UTF8
    Write-Log "Exported $($lstApps.Items.Count) packages to $($dialog.FileName)" $colorGood
}

# --- contacts ----------------------------------------------------------------

function Update-ContactList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection display_name:data1:contact_id:raw_contact_id')).Text

    $filter = $txtContactFilter.Text.Trim()
    $lstContacts.BeginUpdate()
    try {
        $lstContacts.Items.Clear()
        foreach ($row in (Split-ContentRows -Text $text)) {
            $name = Get-RowValue -Row $row -Column 'display_name'
            $number = Get-RowValue -Row $row -Column 'data1'
            $contactId = Get-RowValue -Row $row -Column 'contact_id'
            $rawId = Get-RowValue -Row $row -Column 'raw_contact_id'
            if (-not $number) { continue }
            if ($filter -and -not (Test-TextContains $name $filter) -and -not (Test-TextContains $number $filter)) { continue }

            $item = New-Object System.Windows.Forms.ListViewItem($name)
            $null = $item.SubItems.Add($number)
            $null = $item.SubItems.Add($contactId)
            $null = $item.SubItems.Add($rawId)
            $null = $lstContacts.Items.Add($item)
        }
    } finally {
        $lstContacts.EndUpdate()
    }

    $lblContactsCount.Text = "$($lstContacts.Items.Count) numbers on $serial"
    Write-Log "Read $($lstContacts.Items.Count) phone numbers from $serial." $colorInfo
}

function Add-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $values = Show-InputDialog -Title 'New contact' -Fields @('Name', 'Number')
    if (-not $values -or -not $values[1].Trim()) { return }

    $name = $values[0].Trim()
    $number = $values[1].Trim()

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:null --bind account_type:s:null')
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text $colorBad; return }

    # the row just made is the one with the highest id; the last row of an
    # unsorted query is only whichever the provider happened to return last
    $newest = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        "content query --uri content://com.android.contacts/raw_contacts --projection _id --sort '_id DESC' | head -1")).Text
    if ($newest -notmatch '_id=(\d+)') { Write-Log 'Could not find the new contact row.' $colorBad; return }
    $rawId = $Matches[1]

    # one argument each: a name has spaces, and can have an apostrophe (O'Brien)
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
        '--bind', 'mimetype:s:vnd.android.cursor.item/name', '--bind', "data1:s:$name")
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
        '--bind', 'mimetype:s:vnd.android.cursor.item/phone_v2', '--bind', "data1:s:$number")

    Write-Log "Added $name ($number) to $serial." $colorGood
    Update-ContactList
}

function Edit-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($lstContacts.SelectedItems.Count -eq 0) { Write-Log 'Pick a contact first.' $colorWarn; return }

    $item = $lstContacts.SelectedItems[0]
    $rawId = $item.SubItems[3].Text
    $values = Show-InputDialog -Title 'Edit contact' -Fields @('Name', 'Number') -Values @($item.Text, $item.SubItems[1].Text)
    if (-not $values) { return }

    $name = $values[0].Trim()
    $number = $values[1].Trim()

    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri',
        'content://com.android.contacts/data', '--bind', "data1:s:$name",
        '--where', "raw_contact_id=$rawId AND mimetype='vnd.android.cursor.item/name'")
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri',
        'content://com.android.contacts/data', '--bind', "data1:s:$number",
        '--where', "raw_contact_id=$rawId AND mimetype='vnd.android.cursor.item/phone_v2'")

    Write-Log "Updated contact $rawId on $serial." $colorGood
    Update-ContactList
}

function Remove-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $items = @($lstContacts.SelectedItems)
    if ($items.Count -eq 0) { Write-Log 'Pick a contact first.' $colorWarn; return }

    $names = ($items | ForEach-Object { "$($_.Text)  $($_.SubItems[1].Text)" }) -join [Environment]::NewLine
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete these contacts from the phone?" + [Environment]::NewLine + $names, 'Delete', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($item in $items) {
        $rawId = $item.SubItems[3].Text
        $null = Invoke-DeviceShellText -Serial $serial -Command (
            "content delete --uri content://com.android.contacts/raw_contacts --where ""_id=$rawId""")
        Write-Log "Deleted contact raw id $rawId." $colorWarn
    }
    Update-ContactList
}

function Start-PhoneCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $txtDialNumber.Text.Trim()
    if (-not $number -and $lstContacts.SelectedItems.Count -gt 0) {
        $number = $lstContacts.SelectedItems[0].SubItems[1].Text
    }
    if (-not $number) { Write-Log 'Pick a contact or type a number.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show("Call $number from $serial ?", 'Call', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # a number from a contact is often written "050 123 4567"
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$number")
    Write-Log ("call $number -> " + $result.Text.Trim()) $colorInfo
    Wait-Pumped -Milliseconds 1200
    Update-Capture -Quiet
}

function Stop-PhoneCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    # KEYCODE_ENDCALL
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '6')
    Write-Log 'Sent the end-call key.' $colorInfo
    Wait-Pumped -Milliseconds 800
    Update-Capture -Quiet
}

function Copy-ListSelection {
    param($List, [int[]]$Columns)

    if ($List.SelectedItems.Count -eq 0) { Write-Log 'Nothing selected.' $colorWarn; return }

    $lines = @()
    foreach ($item in $List.SelectedItems) {
        $parts = @()
        foreach ($column in $Columns) {
            $parts += $(if ($column -eq 0) { $item.Text } else { $item.SubItems[$column].Text })
        }
        $lines += ($parts -join "`t")
    }
    [System.Windows.Forms.Clipboard]::SetText($lines -join [Environment]::NewLine)
    Write-Log "Copied $($lines.Count) row(s) to the clipboard." $colorInfo
}

function Export-Contacts {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($lstContacts.Items.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV (*.csv)|*.csv|vCard (*.vcf)|*.vcf'
    $dialog.FileName = 'contacts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    if ($dialog.FileName -like '*.vcf') {
        $lines = @()
        foreach ($item in $lstContacts.Items) {
            $lines += 'BEGIN:VCARD'
            $lines += 'VERSION:3.0'
            $lines += "FN:$($item.Text)"
            $lines += "TEL:$($item.SubItems[1].Text)"
            $lines += 'END:VCARD'
        }
    } else {
        $lines = @('name,number')
        foreach ($item in $lstContacts.Items) {
            $lines += ('"{0}","{1}"' -f ($item.Text -replace '"', "'"), $item.SubItems[1].Text)
        }
    }

    Set-Content -LiteralPath $dialog.FileName -Value $lines -Encoding UTF8
    Write-Log "Exported $($lstContacts.Items.Count) contacts to $($dialog.FileName)" $colorGood
}

# --- SMS ---------------------------------------------------------------------

function Update-SmsList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content query --uri content://sms --projection _id:address:date:type:body')).Text

    $filter = $txtSmsFilter.Text.Trim()
    $messages = @()
    $lstSms.BeginUpdate()
    try {
        $lstSms.Items.Clear()
        foreach ($row in (Split-ContentRows -Text $text)) {
            $id = Get-RowValue -Row $row -Column '_id'
            $address = Get-RowValue -Row $row -Column 'address'
            $stamp = Get-RowValue -Row $row -Column 'date'
            $type = Get-RowValue -Row $row -Column 'type'
            $body = (Get-RowValue -Row $row -Column 'body' -Last) -replace "`r?`n", ' '
            if (-not $id) { continue }
            if ($filter -and -not (Test-TextContains $address $filter) -and -not (Test-TextContains $body $filter)) { continue }

            $when = ''
            if ($stamp -match '^\d+$') {
                $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$stamp).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
            }
            $direction = switch ($type) { '1' { 'in' } '2' { 'out' } '3' { 'draft' } default { $type } }

            $messages += [PSCustomObject]@{
                When      = $when
                Stamp     = $(if ($stamp -match '^\d+$') { [long]$stamp } else { [long]0 })
                Direction = $direction
                Address   = $address
                Body      = $body
                Id        = $id
            }
        }

        foreach ($message in ($messages | Sort-Object -Property Stamp -Descending | Select-Object -First 500)) {
            $item = New-Object System.Windows.Forms.ListViewItem($message.When)
            $null = $item.SubItems.Add($message.Direction)
            $null = $item.SubItems.Add($message.Address)
            $null = $item.SubItems.Add($message.Body)
            $null = $item.SubItems.Add($message.Id)
            $null = $lstSms.Items.Add($item)
        }
    } finally {
        $lstSms.EndUpdate()
    }

    $lblSmsCount.Text = "$($lstSms.Items.Count) messages (newest first)"
    Write-Log "Read $($lstSms.Items.Count) SMS from $serial." $colorInfo
}

function Send-Sms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $txtSmsTo.Text.Trim()
    $body = $txtSmsBody.Text
    if (-not $number -or -not $body.Trim()) { Write-Log 'Fill in both the number and the message.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Send this SMS from $serial ?" + [Environment]::NewLine + [Environment]::NewLine +
        "To: $number" + [Environment]::NewLine + $body, 'Send SMS', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # Android exposes no shell command that sends an SMS, so the message is
    # composed in the phone's SMS app (Arabic survives: it is an intent extra).
    # The body has spaces, so it goes as one argument, not word by word.
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 500
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.SENDTO', '-d', "sms:$number",
        '--es', 'sms_body', $body, '--ez', 'exit_on_sent', 'true')

    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text $colorBad; return }
    Write-Log "Composed the message to $number on the phone." $colorInfo
    Wait-Pumped -Milliseconds 2000

    if (-not $chkSmsAutoSend.Checked) {
        Update-Capture -Quiet
        Write-Log 'Press Send on the phone (or in the picture on the left).' $colorWarn
        return
    }

    $sendButton = Find-SendButton -Serial $serial
    if (-not $sendButton) {
        Update-Capture -Quiet
        Write-Log 'Could not find the Send button - tap it in the picture on the left.' $colorWarn
        return
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($sendButton.X)", "$($sendButton.Y)")
    Write-Log "Tapped Send at $($sendButton.X),$($sendButton.Y)." $colorGood
    Wait-Pumped -Milliseconds 2000
    Update-Capture -Quiet
    Update-SmsList
}

function Find-SendButton {
    param([string]$Serial)

    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'uiautomator dump /sdcard/_sms_ui.xml >/dev/null 2>&1; cat /sdcard/_sms_ui.xml')).Text
    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('rm', '-f', '/sdcard/_sms_ui.xml')

    # "Send" in English or Arabic. The Arabic word is built from its code
    # points, because this file has no BOM and Windows PowerShell reads such
    # a file in the PC's ANSI code page: typed in directly, the letters were
    # right only on a PC set to UTF-8, and the button was never found elsewhere.
    $arabicSend = -join [char[]](0x0625, 0x0631, 0x0633, 0x0627, 0x0644)
    $sendPattern = '(?i)(send|' + $arabicSend + ')'

    foreach ($match in [regex]::Matches($dump, '<node[^>]*>')) {
        $node = $match.Value
        if ($node -notmatch 'clickable="true"') { continue }
        if ($node -notmatch $sendPattern) { continue }
        if ($node -match 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
            return [PSCustomObject]@{
                X = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
                Y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
            }
        }
    }
    return $null
}

function Remove-Sms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $items = @($lstSms.SelectedItems)
    if ($items.Count -eq 0) { Write-Log 'Pick a message first.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete $($items.Count) message(s) from the phone?", 'Delete SMS', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($item in $items) {
        $id = $item.SubItems[4].Text
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @("content delete --uri content://sms/$id")
        if ($result.Text -match 'Exception|denied') {
            Write-Log ("delete $id -> " + $result.Text.Trim()) $colorBad
        } else {
            Write-Log "Deleted message $id." $colorWarn
        }
    }
    Update-SmsList
}

function Edit-Sms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($lstSms.SelectedItems.Count -eq 0) { Write-Log 'Pick a message first.' $colorWarn; return }

    $item = $lstSms.SelectedItems[0]
    $id = $item.SubItems[4].Text
    $values = Show-InputDialog -Title "Edit message $id" -Fields @('Body') -Values @($item.SubItems[3].Text)
    if (-not $values) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri', 'content://sms',
        '--bind', "body:s:$($values[0])", '--where', "_id=$id")
    if ($result.Text -match 'Exception|denied') {
        Write-Log ("edit $id -> " + $result.Text.Trim()) $colorBad
    } else {
        Write-Log "Message $id updated." $colorGood
    }
    Update-SmsList
}

function Export-Sms {
    if ($lstSms.Items.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt'
    $dialog.FileName = 'sms-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $lines = @('date,direction,number,message')
    foreach ($item in $lstSms.Items) {
        $lines += ('"{0}","{1}","{2}","{3}"' -f $item.Text, $item.SubItems[1].Text,
            $item.SubItems[2].Text, ($item.SubItems[3].Text -replace '"', "'"))
    }
    Set-Content -LiteralPath $dialog.FileName -Value $lines -Encoding UTF8
    Write-Log "Exported $($lstSms.Items.Count) messages to $($dialog.FileName)" $colorGood
}

# --- private DNS -------------------------------------------------------------

function Get-DnsState {
    param([string]$Serial)

    $mode = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'settings', 'get', 'global', 'private_dns_mode')).Text.Trim()
    $host1 = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'settings', 'get', 'global', 'private_dns_specifier')).Text.Trim()

    # the resolvers of the network that actually carries traffic
    $active = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "dumpsys connectivity | grep -m1 'Active default network'")).Text
    $servers = @()
    # dumpsys often appends a 'Broken pipe' line, so anchoring to the end of the
    # text loses the network id: match the label itself instead
    if ($active -match 'Active default network:\s*(\d+)') {
        $id = $Matches[1]
        $line = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "dumpsys connectivity | grep -m1 'network{$id}'")).Text
        foreach ($match in [regex]::Matches($line, 'DnsAddresses:\s*\[([^\]]*)\]')) {
            foreach ($entry in ($match.Groups[1].Value -split ',')) {
                $entry = $entry.Trim().TrimStart('/')
                if ($entry) { $servers += $entry }
            }
        }
    }

    if ($servers.Count -eq 0) {
        # last resort: the first non-empty resolver list in the whole dump
        $any = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "dumpsys connectivity | grep -oE 'DnsAddresses: \[[^]]+\]' | head -3")).Text
        foreach ($match in [regex]::Matches($any, 'DnsAddresses:\s*\[([^\]]*)\]')) {
            foreach ($entry in ($match.Groups[1].Value -split ',')) {
                $entry = $entry.Trim().TrimStart('/')
                if ($entry) { $servers += $entry }
            }
            if ($servers.Count -gt 0) { break }
        }
    }

    if (-not $mode -or $mode -eq 'null') { $mode = 'opportunistic' }
    return [PSCustomObject]@{
        Mode     = $mode
        Hostname = $(if ($host1 -and $host1 -ne 'null') { $host1 } else { '' })
        Servers  = $servers
    }
}

function Show-DnsState {
    param([switch]$Quiet)

    $serial = Get-TargetSerial
    if (-not $serial) { $txtDnsState.Text = ''; return }

    $state = Get-DnsState -Serial $serial
    $label = switch ($state.Mode) {
        'off'           { 'off' }
        'hostname'      { "custom ($($state.Hostname))" }
        'opportunistic' { 'automatic' }
        default         { $state.Mode }
    }

    $ipv4 = @($state.Servers | Where-Object { $_ -notmatch ':' })
    $shown = if ($ipv4.Count -gt 0) { $ipv4 -join ', ' } elseif ($state.Servers.Count -gt 0) { $state.Servers[0] } else { 'none reported' }
    $txtDnsState.Text = "mode: $label   |   resolvers in use: $shown"

    # keep the controls in step with the phone
    $cmbDnsMode.SelectedIndex = switch ($state.Mode) {
        'off'      { 1 }
        'hostname' { 2 }
        default    { 0 }
    }
    if ($state.Hostname) { $txtDnsHost.Text = $state.Hostname }

    if (-not $Quiet) {
        Write-Log "$serial DNS: $label" $colorInfo
        if ($state.Servers.Count -gt 0) {
            Write-Log ('  resolvers: ' + ($state.Servers -join ', ')) $colorInfo
        }
    }
    return $state
}

function Set-DnsMode {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $choice = "$($cmbDnsMode.SelectedItem)"
    $mode = switch -Wildcard ($choice) {
        'off*'    { 'off' }
        'custom*' { 'hostname' }
        default   { 'opportunistic' }
    }

    if ($mode -eq 'hostname') {
        $name = $txtDnsHost.Text.Trim()
        if (-not $name) { Write-Log 'Type the provider hostname first (e.g. dns.google).' $colorWarn; return }
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'settings', 'put', 'global', 'private_dns_specifier', $name)
        if ($result.Text -match 'Exception|denied') { Write-Log $result.Text $colorBad; return }
    }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'put', 'global', 'private_dns_mode', $mode)
    if ($result.Text -match 'Exception|denied') { Write-Log $result.Text $colorBad; return }

    # the resolver takes a moment to switch over
    Wait-Pumped -Milliseconds 1500
    $state = Get-DnsState -Serial $serial
    if ($state.Mode -eq $mode) {
        Write-Log "DNS set to $choice on $serial." $colorGood
    } else {
        Write-Log "The phone kept DNS on '$($state.Mode)'." $colorBad
    }
    $null = Show-DnsState
}

# --- Wi-Fi hotspot -----------------------------------------------------------

function Test-DeviceLocked {
    param([string]$Serial)

    # a multi-user phone prints one line per profile; only (current) matters
    $trust = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'dumpsys trust | grep deviceLocked')).Text

    $lines = @($trust -split "`r?`n")
    $current = @($lines | Where-Object { $_ -match '\(current\)' })
    if ($current.Count -gt 0) { return ($current[0] -match 'deviceLocked=1') }

    return ($trust -match 'deviceLocked=1')
}

function Get-TetheringState {
    param([string]$Serial, [string]$Kind = 'WIFI')

    # 'cmd wifi is-softap-enabled' is denied to the shell user, and the access
    # point interface is named differently on every chipset. The tethering
    # service, however, lists what is actually being shared right now.
    $dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "dumpsys tethering 2>/dev/null | grep -c 'Type: TETHERING_$Kind'")).Text
    if ($dump -match '(\d+)') { return ([int]$Matches[1] -gt 0) }
    return $false
}

function Get-HotspotState {
    param([string]$Serial)

    return Get-TetheringState -Serial $Serial -Kind 'WIFI'
}

function Show-HotspotState {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wifi = Get-TetheringState -Serial $serial -Kind 'WIFI'
    $usb = Get-TetheringState -Serial $serial -Kind 'USB'
    Write-Log ("$serial : Wi-Fi hotspot " + $(if ($wifi) { 'ON' } else { 'off' }) +
        ' | USB tethering ' + $(if ($usb) { 'ON' } else { 'off' })) `
        $(if ($wifi -or $usb) { $colorGood } else { $colorInfo })
    return $wifi
}

function Open-HotspotPage {
    param([string]$Serial, [switch]$WifiPage)

    # the dedicated Wi-Fi hotspot page carries the switch and the credentials;
    # the generic tethering page is the fallback for ROMs without it
    $targets = @()
    if ($WifiPage) {
        $targets += "am start -n 'com.android.settings/.Settings`$WifiTetherSettingsActivity'"
    }
    $targets += 'am start -a android.settings.TETHER_SETTINGS'

    foreach ($command in $targets) {
        $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @($command)
        Wait-Pumped -Milliseconds 2500
        $foreground = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'dumpsys activity activities | grep -m1 ResumedActivity')).Text
        if ($foreground -match 'TetherSettings|WifiTether|Hotspot') { return $true }
    }
    return $false
}

function Show-HotspotCredentials {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'Unlock the phone first: the settings page cannot open behind the lock screen.' $colorBad
        return
    }

    if (-not (Open-HotspotPage -Serial $serial -WifiPage)) {
        Write-Log 'Could not open the Wi-Fi hotspot page.' $colorBad
        return
    }

    $xml = Get-UiDump -Serial $serial
    $texts = @([regex]::Matches($xml, 'text="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

    # the page lists label then value, so read the entry after each label
    function Get-Following {
        param([string[]]$Items, [string]$Label)
        for ($i = 0; $i -lt $Items.Count - 1; $i++) {
            if ($Items[$i] -like "*$Label*") { return $Items[$i + 1] }
        }
        return $null
    }

    $name = Get-Following -Items $texts -Label 'name'
    $security = Get-Following -Items $texts -Label 'Security'
    $password = Get-Following -Items $texts -Label 'password'

    Write-Log "Hotspot name    : $(if ($name) { $name } else { 'not shown' })" $colorGood
    Write-Log "Security        : $(if ($security) { $security } else { 'not shown' })" $colorInfo
    if ($password -and $password -notmatch '^[\u2022*.]+$') {
        Write-Log "Password        : $password" $colorGood
    } else {
        Write-Log 'Password        : hidden by the phone (tap the password row on the screen to reveal it)' $colorWarn
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-Capture -Quiet
}

function Get-UiDump {
    param([string]$Serial)

    return (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'uiautomator dump /sdcard/_hub_ui.xml >/dev/null 2>&1; cat /sdcard/_hub_ui.xml')).Text
}

function Set-Hotspot {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wanted = if ($On) { 'ON' } else { 'off' }
    if ((Get-HotspotState -Serial $serial) -eq $On) {
        Write-Log "The Wi-Fi hotspot is already $wanted." $colorInfo
        return
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 600
    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'The phone is locked - unlock it first, the settings page cannot open behind the lock screen.' $colorBad
        return
    }

    Write-Log "Opening the Wi-Fi hotspot page on $serial ..." $colorStep
    if (-not (Open-HotspotPage -Serial $serial -WifiPage)) {
        Write-Log 'The hotspot page did not come up.' $colorBad
        return
    }

    $xml = Get-UiDump -Serial $serial
    $switch = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*checkable="true"[^>]*>')) {
        $node = $match.Value
        if ($node -notmatch 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') { continue }

        # read the coordinates out of $Matches first: the next -match would
        # overwrite them and the tap would land on 0,0
        $left = [int]$Matches[1]; $top = [int]$Matches[2]
        $right = [int]$Matches[3]; $bottom = [int]$Matches[4]

        $switch = [PSCustomObject]@{
            Checked = ($node -match 'checked="true"')
            X       = [int](($left + $right) / 2)
            Y       = [int](($top + $bottom) / 2)
        }
        break
    }

    if (-not $switch) {
        Write-Log 'That page has no hotspot switch to press. What it shows:' $colorBad
        foreach ($text in [regex]::Matches($xml, 'text="([^"]+)"')) {
            Write-Log ('  ' + $text.Groups[1].Value) $colorWarn
        }
        Write-Log 'On phones with a second space, tethering can only be changed in the first space.' $colorWarn
        return
    }

    if ($switch.Checked -ne $On) {
        Write-Log "Tapping the hotspot switch at $($switch.X),$($switch.Y) ..." $colorStep
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($switch.X)", "$($switch.Y)")
        Wait-Pumped -Milliseconds 4000
    }

    if ((Get-HotspotState -Serial $serial) -eq $On) {
        Write-Log "Wi-Fi hotspot is now $wanted." $colorGood
    } else {
        Write-Log "The hotspot did not turn $wanted - check the phone screen." $colorBad
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-Capture -Quiet
}

function Set-UsbTethering {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $wanted = if ($On) { 'ON' } else { 'off' }
    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is already $wanted." $colorInfo
        return
    }

    # the adb switch works on some ROMs, so try it before touching the UI
    if ($On) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions', 'rndis')
    } else {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('svc', 'usb', 'setFunctions')
    }
    Wait-Pumped -Milliseconds 3000

    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is now $wanted (set through adb)." $colorGood
        return
    }

    Write-Log 'The phone refused the adb switch, using its settings page instead ...' $colorWarn
    if (Test-DeviceLocked -Serial $serial) {
        Write-Log 'The phone is locked - unlock it first.' $colorBad
        return
    }
    if (-not (Open-HotspotPage -Serial $serial)) {
        Write-Log 'The tethering page did not come up.' $colorBad
        return
    }

    # find the row labelled USB and press the switch that sits on its line
    $xml = Get-UiDump -Serial $serial
    $rowY = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*text="([^"]*USB[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
        $rowY = [int](([int]$match.Groups[3].Value + [int]$match.Groups[5].Value) / 2)
        break
    }

    $target = $null
    foreach ($match in [regex]::Matches($xml, '<node[^>]*checkable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
        $top = [int]$match.Groups[2].Value
        $bottom = [int]$match.Groups[4].Value
        $checked = ($match.Value -match 'checked="true"')
        if ($null -eq $rowY -or ($rowY -ge ($top - 40) -and $rowY -le ($bottom + 40))) {
            $target = [PSCustomObject]@{
                Checked = $checked
                X       = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
                Y       = [int](($top + $bottom) / 2)
            }
            break
        }
    }

    if (-not $target) {
        Write-Log 'No USB tethering switch on that page (a second space cannot change it).' $colorBad
        return
    }

    if ($target.Checked -ne $On) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($target.X)", "$($target.Y)")
        Wait-Pumped -Milliseconds 4000
    }

    if ((Get-TetheringState -Serial $serial -Kind 'USB') -eq $On) {
        Write-Log "USB tethering is now $wanted." $colorGood
    } else {
        Write-Log "USB tethering did not turn $wanted - check the phone screen." $colorBad
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '3')
    Update-Capture -Quiet
}

# --- camera ------------------------------------------------------------------

function Update-CameraList {
    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Reading the camera list of $serial ..." $colorStep
    $ErrorActionPreference = 'Continue'
    $output = @(& $script:scrcpyPath -s $serial --list-cameras 2>&1) | ForEach-Object { "$_" }

    $cmbCamera.Items.Clear()
    foreach ($line in $output) {
        # --camera-id=0    (back, 4080x3072, fps={10, 15, 20, 24, 30}, ...)
        if ($line -match '--camera-id=(\d+)\s+\((\w+),\s*(\d+x\d+)') {
            $null = $cmbCamera.Items.Add("$($Matches[1])  -  $($Matches[2])  $($Matches[3])")
            Write-Log ("  " + $line.Trim()) $colorInfo
        }
    }

    if ($cmbCamera.Items.Count -eq 0) {
        $null = $cmbCamera.Items.Add('no camera reported')
        Write-Log 'The device reported no camera (needs Android 12 or newer).' $colorBad
    }
    $cmbCamera.SelectedIndex = 0
}

function Get-CameraArguments {
    param([string]$Serial, [string]$Facing)

    $arguments = @('-s', $Serial, '--video-source=camera')

    if ($Facing) {
        $arguments += "--camera-facing=$Facing"
    } elseif ("$($cmbCameraFacing.SelectedItem)" -ne 'by id') {
        $arguments += "--camera-facing=$($cmbCameraFacing.SelectedItem)"
    } else {
        $selected = "$($cmbCamera.SelectedItem)"
        if ($selected -match '^(\d+)') { $arguments += "--camera-id=$($Matches[1])" }
    }

    # scrcpy takes either an explicit size or an aspect ratio, never both
    $ratio = $cmbCameraAr.Text.Trim()
    $size = $cmbCameraSize.Text.Trim()
    if ($ratio -and $ratio -ne '(size)') {
        $arguments += "--camera-ar=$ratio"
    } elseif ($size -and $size -ne 'sensor max') {
        $arguments += "--camera-size=$size"
    }

    $fps = $cmbCameraFps.Text.Trim()
    if ($fps) { $arguments += "--camera-fps=$fps" }

    if ($chkCameraHighSpeed.Checked) { $arguments += '--camera-high-speed' }

    $zoom = $cmbCameraZoom.Text.Trim()
    if ($zoom -and $zoom -ne '1' -and $zoom -match '^[\d.]+$') { $arguments += "--camera-zoom=$zoom" }
    if ($chkCameraTorch.Checked) { $arguments += '--camera-torch' }

    if ($chkCameraMic.Checked) {
        $arguments += '--audio-source=mic'
    } else {
        $arguments += '--no-audio'
    }

    if ($chkCameraRecord.Checked) {
        $file = $txtCameraRecord.Text.Trim()
        if (-not $file) {
            $file = Join-Path ([Environment]::GetFolderPath('MyVideos')) ('camera-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
            $txtCameraRecord.Text = $file
        }
        $arguments += "--record=$file"
    }

    # no spaces: Start-Process splits an argument on whitespace, and scrcpy
    # then chokes on the leftover word
    $title = if ($Facing) { "camera-$Facing" } else { 'camera' }
    $arguments += "--window-title=$title"
    return $arguments
}

function Start-Camera {
    param([string]$Facing)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $arguments = Get-CameraArguments -Serial $serial -Facing $Facing
    Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

    $stdout = Join-Path $env:TEMP ("androiddc-$PID.camera.out")
    $stderr = Join-Path $env:TEMP ("androiddc-$PID.camera.err")
    $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -PassThru `
        -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    $script:cameraProcesses += $process
    $script:scrcpyProcesses += $process

    Wait-Pumped -Milliseconds 3000
    $process.Refresh()

    if ($process.HasExited) {
        Write-Log "The camera did not start (exit $($process.ExitCode))." $colorBad
        foreach ($file in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $file) {
                $text = (Get-Content -LiteralPath $file -Tail 6) -join [Environment]::NewLine
                if ($text.Trim()) { Write-Log $text $colorWarn }
            }
        }
    } else {
        Write-Log "Camera streaming (PID $($process.Id), window '$($process.MainWindowTitle)')." $colorGood
    }
}

function Stop-Camera {
    $stopped = 0
    foreach ($process in $script:cameraProcesses) {
        try {
            if (-not $process.HasExited) { $process.Kill(); $stopped++ }
        } catch { }
    }
    $script:cameraProcesses = @()
    Write-Log "Stopped $stopped camera window(s)." $colorInfo
}

# --- file browser ------------------------------------------------------------

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Join-DevicePath {
    param([string]$Parent, [string]$Child)

    if ($Parent.EndsWith('/')) { return "$Parent$Child" }
    return "$Parent/$Child"
}

function Update-FileList {
    param([string]$Path)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (-not $Path) { $Path = $txtFilePath.Text.Trim() }
    if (-not $Path) { $Path = '/sdcard' }

    # a trailing slash makes ls list the contents of a symlinked dir (/sdcard)
    # instead of the link entry itself
    $listPath = if ($Path.EndsWith('/')) { $Path } else { "$Path/" }
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ls', '-la', (Quote-DeviceArgument $listPath))
    if ($result.Text -match 'Permission denied') {
        Write-Log "Permission denied: $Path (adb shell cannot read it)" $colorBad
        return
    }
    if ($result.Text -match 'No such file') {
        Write-Log "No such path: $Path" $colorBad
        return
    }

    # remember where we came from, unless this is a refresh or a history jump
    if (-not $script:fileNavigating -and $script:filePath -and $script:filePath -ne $Path) {
        $null = $script:fileBack.Add($script:filePath)
        while ($script:fileBack.Count -gt 100) { $script:fileBack.RemoveAt(0) }
        $script:fileForward.Clear()
    }

    $txtFilePath.Text = $Path
    $script:filePath = $Path

    $rows = @()
    foreach ($line in ($result.Text -split "`r?`n")) {
        $line = $line.TrimEnd()
        if (-not $line -or $line -like 'total *') { continue }

        # drwxrws--- 3 u0_a242 media_rw 3452 2023-12-08 02:26 name with spaces
        if ($line -notmatch '^([dlbcps-][rwxsStT-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$') {
            continue
        }

        $permissions = $Matches[1]
        $owner = $Matches[2]
        $size = [long]$Matches[4]
        $stamp = "$($Matches[5]) $($Matches[6])"
        $name = $Matches[7]

        $isLink = $permissions.StartsWith('l')
        if ($isLink -and $name -match '^(.*?) -> (.*)$') { $name = $Matches[1] }
        $isDirectory = $permissions.StartsWith('d')

        if ($name -eq '.' -or $name -eq '..') { continue }
        if (-not $chkFileHidden.Checked -and $name.StartsWith('.')) { continue }

        $extension = ''
        if (-not $isDirectory) {
            $dot = $name.LastIndexOf('.')
            if ($dot -gt 0 -and $dot -lt ($name.Length - 1)) {
                $extension = $name.Substring($dot + 1).ToUpperInvariant()
            }
        }

        $rows += [PSCustomObject]@{
            Name        = $name
            Label       = $name
            Path        = (Join-DevicePath -Parent $Path -Child $name)
            IsDirectory = $isDirectory
            IsLink      = $isLink
            Extension   = $extension
            Size        = $size
            Stamp       = $stamp
            Permissions = $permissions
            Owner       = $owner
        }
    }

    $script:fileRows = $rows
    $script:fileSearchResults = $false
    Show-FileRows
    Show-FileSpace -Serial $serial -Path $Path
}

function Show-FileRows {
    $rows = $script:fileRows

    # numbers must sort as numbers, dates as dates, names case-insensitively
    $key = switch ($script:fileSortColumn) {
        1 { { $_.Extension } }
        2 { { $_.Size } }
        3 { { $_.Stamp } }
        4 { { $_.Permissions } }
        5 { { $_.Owner } }
        default { { $_.Label.ToLowerInvariant() } }
    }

    $filter = $txtFileSearch.Text.Trim()
    if ($filter -and -not $script:fileSearchResults) {
        $rows = @($rows | Where-Object { Test-TextContains $_.Label $filter })
    }

    if ($script:fileFoldersFirst) {
        $rows = @($rows | Sort-Object @{ Expression = { -not $_.IsDirectory } },
            @{ Expression = $key; Descending = $script:fileSortDescending })
    } else {
        $rows = @($rows | Sort-Object -Property @{ Expression = $key } -Descending:$script:fileSortDescending)
    }

    $arrow = if ($script:fileSortDescending) { ' v' } else { ' ^' }
    $headers = @('Name', 'Type', 'Size', 'Modified', 'Permissions', 'Owner')
    for ($i = 0; $i -lt $lstFiles.Columns.Count; $i++) {
        $lstFiles.Columns[$i].Text = $headers[$i] + $(if ($i -eq $script:fileSortColumn) { $arrow } else { '' })
    }

    $lstFiles.BeginUpdate()
    try {
        $lstFiles.Items.Clear()
        foreach ($row in $rows) {
            $label = if ($row.IsDirectory) { "[ $($row.Label) ]" } else { $row.Label }
            $item = New-Object System.Windows.Forms.ListViewItem($label)
            $null = $item.SubItems.Add($(if ($row.IsDirectory) { '<dir>' } else { $row.Extension }))
            $null = $item.SubItems.Add($(if ($row.IsDirectory) { '' } else { Format-FileSize -Bytes $row.Size }))
            $null = $item.SubItems.Add($row.Stamp)
            $null = $item.SubItems.Add($row.Permissions)
            $null = $item.SubItems.Add($row.Owner)
            $item.Tag = $row
            if ($row.IsDirectory) {
                $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 160)
            } elseif ($row.IsLink) {
                $item.ForeColor = [System.Drawing.Color]::DarkCyan
            }
            $null = $lstFiles.Items.Add($item)
        }
    } finally {
        $lstFiles.EndUpdate()
    }

    $directories = @($rows | Where-Object { $_.IsDirectory }).Count
    $files = $rows.Count - $directories
    $lblFileInfo.Text = "$directories dirs, $files files"
}

function Set-FileSelection {
    param([ValidateSet('all', 'none', 'invert')][string]$Mode = 'all')

    if ($lstFiles.Items.Count -eq 0) { return }

    $lstFiles.BeginUpdate()
    try {
        foreach ($item in $lstFiles.Items) {
            $item.Selected = switch ($Mode) {
                'none'   { $false }
                'invert' { -not $item.Selected }
                default  { $true }
            }
        }
    } finally {
        $lstFiles.EndUpdate()
    }

    # keep the keyboard on the list, so Ctrl+A and the arrows carry on working
    if ($lstFiles.CanFocus) { $null = $lstFiles.Focus() }
    Write-Log "$($lstFiles.SelectedItems.Count) of $($lstFiles.Items.Count) item(s) selected." $colorInfo
}

function Invoke-FileHistory {
    # the mouse back/forward buttons walk the folders visited in this session
    param([ValidateSet('back', 'forward')][string]$Direction)

    # plain assignment, not "$x = if (...) { $list }" - that form unrolls the
    # ArrayList into a fixed size array and RemoveAt then throws
    if ($Direction -eq 'back') {
        $from = $script:fileBack
        $to = $script:fileForward
    } else {
        $from = $script:fileForward
        $to = $script:fileBack
    }

    if ($from.Count -eq 0) {
        Write-Log "No folder to go $Direction to." $colorInfo
        return
    }

    $target = "$($from[$from.Count - 1])"
    $current = $script:filePath
    $from.RemoveAt($from.Count - 1)

    $script:fileNavigating = $true
    try { Update-FileList -Path $target } finally { $script:fileNavigating = $false }

    if ($script:filePath -eq $target) {
        $null = $to.Add($current)
    } else {
        # the folder is gone or unreadable - leave the history as it was
        $null = $from.Add($target)
    }
}


function Split-DevicePath {
    # the folder an entry actually lives in (search hits are not in view)
    param([string]$Path)

    $index = $Path.TrimEnd('/').LastIndexOf('/')
    if ($index -le 0) { return '/' }
    return $Path.Substring(0, $index)
}

function Get-DeviceFileBytes {
    # read a file straight out of adb, without leaving a copy on this PC
    param([string]$Serial, [string]$Path, [int]$TimeoutMs = 30000)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    # exec-out hands the argument to the device as it stands - no shell re-parse
    # there - so the quoting that matters is the one Windows itself removes
    $info.Arguments = "-s $Serial exec-out cat " + '"' + ($Path -replace '"', '\"') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return $null }

    $buffer = New-Object System.IO.MemoryStream
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)

    $script:busy++
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $copy.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
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
    # the comma keeps PowerShell from unrolling the array into single bytes
    return ,$bytes
}

function Show-FileSpace {
    # how full the volume under the current folder is
    param([string]$Serial, [string]$Path)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('df', '-h', (Quote-DeviceArgument $Path))).Text
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+%)\s+(\S+)\s*$') {
            $lblFileSpace.Text = "space here: $($Matches[2]) used of $($Matches[1])   |   $($Matches[3]) free   |   $($Matches[4]) full   |   volume $($Matches[5])"
            return
        }
    }
    $lblFileSpace.Text = ''
}

function Update-FileVolumes {
    # put every mounted volume in the jump list, so storage can be browsed
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('sm', 'list-volumes')).Text
    $paths = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*emulated;(\d+)\s+mounted') { $paths += "/storage/emulated/$($Matches[1])" }
        elseif ($line -match '^\s*public:(\S+)\s+mounted\s+(\S+)') { $paths += "/storage/$($Matches[2])" }
    }
    foreach ($path in $paths) {
        if (-not $cmbFileQuick.Items.Contains($path)) { $null = $cmbFileQuick.Items.Add($path) }
    }
}

function Compress-DeviceFiles {
    param([string]$ArchiveName)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick what to pack first.' $colorWarn; return }

    $folder = Split-DevicePath -Path $rows[0].Path
    $suggested = if ($rows.Count -eq 1) { "$($rows[0].Name).tar.gz" } else { 'archive.tar.gz' }
    $name = $ArchiveName
    if (-not $name) {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Name of the archive, made inside`n$folder", 'Compress', $suggested)
    }
    if (-not "$name".Trim()) { return }
    $name = $name.Trim()
    if ($name -notmatch '\.(tar\.gz|tgz|tar)$') { $name += '.tar.gz' }

    # the phone has tar and gzip but no zip, so a tarball it is. Entries from
    # one folder go in by name; search hits from several go in by their path
    # from /, since no one folder holds them all.
    $target = Join-DevicePath -Parent $folder -Child $name
    $oneFolder = @($rows | Where-Object { (Split-DevicePath -Path $_.Path) -ne $folder }).Count -eq 0
    $base = if ($oneFolder) { $folder } else { '/' }
    $arguments = @('tar', '-czf', (Quote-DeviceArgument $target), '-C', (Quote-DeviceArgument $base))
    foreach ($row in $rows) {
        $entry = if ($oneFolder) { $row.Name } else { $row.Path.TrimStart('/') }
        $arguments += (Quote-DeviceArgument $entry)
    }

    Write-Log "Packing $($rows.Count) item(s) into $target ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
    if ($result.Text -match 'denied|No such|Error|cannot') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }

    $size = Get-DeviceFileSize -Serial $serial -Path $target
    if ($size -gt 0) {
        Write-Log "Made $name ($(Format-FileSize -Bytes $size))." $colorGood
    } else {
        Write-Log "tar said nothing but $name is not there." $colorBad
    }
    Update-FileList
}

function Expand-DeviceArchive {
    param([string]$Into)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles | Where-Object { -not $_.IsDirectory })
    if ($rows.Count -eq 0) { Write-Log 'Pick an archive first.' $colorWarn; return }

    $archive = $rows[0]
    $folder = Split-DevicePath -Path $archive.Path
    $lower = $archive.Name.ToLowerInvariant()

    $into = $Into
    if (-not $into) {
        $into = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Unpack $($archive.Name) into which folder on the phone?", 'Extract', $folder)
    }
    if (-not "$into".Trim()) { return }
    $into = $into.Trim()

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('mkdir', '-p', (Quote-DeviceArgument $into))

    if ($lower.EndsWith('.zip') -or $lower.EndsWith('.apk')) {
        $arguments = @('unzip', '-o', (Quote-DeviceArgument $archive.Path), '-d', (Quote-DeviceArgument $into))
    } elseif ($lower.EndsWith('.tar.gz') -or $lower.EndsWith('.tgz')) {
        $arguments = @('tar', '-xzf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $into))
    } elseif ($lower.EndsWith('.tar.bz2') -or $lower.EndsWith('.tbz')) {
        $arguments = @('tar', '-xjf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $into))
    } elseif ($lower.EndsWith('.tar')) {
        $arguments = @('tar', '-xf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $into))
    } elseif ($lower.EndsWith('.gz')) {
        $plain = Join-DevicePath -Parent $into -Child ($archive.Name -replace '\.gz$', '')
        $arguments = @('gzip', '-dc', (Quote-DeviceArgument $archive.Path), '>', (Quote-DeviceArgument $plain))
    } else {
        Write-Log "$($archive.Name) is not a kind of archive the phone can open (zip, tar, tar.gz, tar.bz2, gz)." $colorWarn
        return
    }

    Write-Log "Unpacking $($archive.Name) into $into ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
    if ($result.Text -match 'denied|cannot|Error|No such') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }
    Write-Log "Unpacked $($archive.Name)." $colorGood
    Update-FileList -Path $into
}

function Show-DeviceFilePreview {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles | Where-Object { -not $_.IsDirectory })
    if ($rows.Count -eq 0) { Write-Log 'Pick a file to look at.' $colorWarn; return }

    $row = $rows[0]
    $extension = ''
    $dot = $row.Name.LastIndexOf('.')
    if ($dot -gt 0) { $extension = $row.Name.Substring($dot + 1).ToLowerInvariant() }

    $pictures = @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico')
    $texts = @('txt', 'log', 'json', 'xml', 'csv', 'md', 'ini', 'conf', 'html', 'htm', 'js', 'css', 'sh', 'prop')
    $media = @('mp4', 'mkv', '3gp', 'webm', 'avi', 'mov', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac')

    $size = Get-DeviceFileSize -Serial $serial -Path $row.Path
    if ($pictures -contains $extension -or $texts -contains $extension) {
        if ($size -gt 25MB) {
            Write-Log "$($row.Name) is $(Format-FileSize -Bytes $size) - too big to show in the window." $colorWarn
            return
        }
        Write-Log "Reading $($row.Name) from the phone ..." $colorStep
        $bytes = Get-DeviceFileBytes -Serial $serial -Path $row.Path
        if (-not $bytes -or $bytes.Length -eq 0) { Write-Log "Could not read $($row.Name)." $colorBad; return }

        if ($pictures -contains $extension) {
            Show-PreviewWindow -Title $row.Name -Bytes $bytes
        } else {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            Show-PreviewWindow -Title $row.Name -Text $text
        }
        Write-Log "Showed $($row.Name) ($(Format-FileSize -Bytes $bytes.Length)); nothing was saved on this PC." $colorGood
        return
    }

    if ($media -contains $extension) {
        # no codec inside this window, so the player needs a file to open;
        # it goes to the temp folder and is removed when the app closes
        Write-Log "Video and sound need a player, so $($row.Name) is copied to the temp folder first." $colorInfo
        $temp = Join-Path $env:TEMP ("androiddc-$PID.preview." + $row.Name)
        $result = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', $row.Path, $temp)
        if (-not (Test-Path -LiteralPath $temp)) { Write-Log $result.Text.Trim() $colorBad; return }
        $script:previewFiles += $temp
        Start-Process -FilePath $temp
        Write-Log "Opened $($row.Name) in the default player." $colorGood
        return
    }

    Write-Log "$($row.Name) is not a picture, a text or a media file - use Download instead." $colorWarn
}

function Show-PreviewWindow {
    param([string]$Title, [byte[]]$Bytes, [string]$Text)

    $window = New-Object System.Windows.Forms.Form
    $window.Text = "$Title  (from the phone, not saved)"
    $window.Size = New-Object System.Drawing.Size(900, 700)
    $window.StartPosition = 'CenterParent'
    $window.ShowIcon = $false

    if ($Bytes) {
        $stream = New-Object System.IO.MemoryStream(, $Bytes)
        try {
            $image = [System.Drawing.Image]::FromStream($stream)
        } catch {
            $stream.Dispose()
            Write-Log "That file is not a picture the PC can read." $colorBad
            return
        }
        $box = New-Object System.Windows.Forms.PictureBox
        $box.Dock = 'Fill'
        $box.SizeMode = 'Zoom'
        $box.Image = $image
        $window.Controls.Add($box)
        $window.Text = "$Title  -  $($image.Width)x$($image.Height)  (from the phone, not saved)"
        $window.Add_FormClosed({
            $box.Image = $null
            try { $image.Dispose(); $stream.Dispose() } catch { }
        }.GetNewClosure())
    } else {
        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true
        $box.ReadOnly = $true
        $box.ScrollBars = 'Both'
        $box.WordWrap = $false
        $box.Font = New-Object System.Drawing.Font('Consolas', 9)
        $box.Dock = 'Fill'
        $box.Text = $Text
        $window.Controls.Add($box)
    }

    $null = $window.ShowDialog($form)
    $window.Dispose()
}

function Get-SelectedFiles {
    $rows = @()
    foreach ($item in $lstFiles.SelectedItems) {
        if ($item.Tag) {
            $rows += [PSCustomObject]@{
                Name        = $item.Tag.Name
                IsDirectory = $item.Tag.IsDirectory
                Path        = $item.Tag.Path
            }
        }
    }
    return $rows
}

function Show-RecentFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $days = switch ("$($cmbFileRecent.SelectedItem)") {
        'last 2 days'  { 2 }
        'last week'    { 7 }
        'last 30 days' { 30 }
        default        { 1 }
    }

    # the whole shared storage, not just the folder on screen
    $root = '/sdcard'
    Write-Log "Looking for files changed in the last $days day(s) across $root ..." $colorStep

    $command = "find -L $root -type f -mtime -$days -exec ls -lad {} + 2>/dev/null | head -400"
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @($command)

    $rows = @(ConvertFrom-LsOutput -Text $result.Text -Root $root)
    $script:fileRows = $rows
    $script:fileSearchResults = $true

    # newest first is the only order that makes sense here
    $script:fileSortColumn = 3
    $script:fileSortDescending = $true
    $script:fileFoldersFirst = $false
    $chkFileFoldersFirst.Checked = $false
    Show-FileRows

    $lblFileInfo.Text = "$($rows.Count) recent"
    Write-Log "$($rows.Count) file(s) changed in the last $days day(s)." $(if ($rows.Count) { $colorGood } else { $colorWarn })
}

function ConvertFrom-LsOutput {
    param([string]$Text, [string]$Root)

    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $line = $line.TrimEnd()
        if ($line -notmatch '^([dlbcps-][rwxsStT-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$') {
            continue
        }

        $permissions = $Matches[1]
        $owner = $Matches[2]
        $size = [long]$Matches[4]
        $stamp = "$($Matches[5]) $($Matches[6])"
        $full = $Matches[7]
        if ($full -match '^(.*?) -> (.*)$') { $full = $Matches[1] }

        $name = $full.Substring($full.LastIndexOf('/') + 1)
        $isDirectory = $permissions.StartsWith('d')

        $extension = ''
        if (-not $isDirectory) {
            $dot = $name.LastIndexOf('.')
            if ($dot -gt 0 -and $dot -lt ($name.Length - 1)) { $extension = $name.Substring($dot + 1).ToUpperInvariant() }
        }

        $shown = $full
        if ($Root -and $full.StartsWith($Root)) { $shown = $full.Substring($Root.TrimEnd('/').Length).TrimStart('/') }

        # Name is the file's own name, as in a folder listing; the path under
        # the search root is only what the list shows. With the relative path
        # as its name, Move to PC looked for dest\DCIM/Camera/x.jpg, found
        # nothing, and never deleted the phone copy; Rename and Compress went
        # to folders that do not exist.
        $rows += [PSCustomObject]@{
            Name        = $name
            Label       = $shown
            Path        = $full
            IsDirectory = $isDirectory
            IsLink      = $permissions.StartsWith('l')
            Extension   = $extension
            Size        = $size
            Stamp       = $stamp
            Permissions = $permissions
            Owner       = $owner
        }
    }
    return $rows
}

function Search-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $query = $txtFileSearch.Text.Trim()
    if (-not $query) { Write-Log 'Type something to search for first.' $colorWarn; return }

    $root = $script:filePath
    Write-Log "Searching '$query' under $root ..." $colorStep

    # one ls line per hit, so the same parser can be reused
    $command = "find -L " + (Quote-DeviceArgument $root) + " -iname " + (Quote-DeviceArgument "*$query*") +
        " -exec ls -lad {} + 2>/dev/null | head -400"
    # typed text: as base64, so a " in the query is not dropped on the way
    $result = Invoke-DeviceShellText -Serial $serial -Command $command

    $rows = @(ConvertFrom-LsOutput -Text $result.Text -Root $root)

    $script:fileRows = $rows
    $script:fileSearchResults = $true
    Show-FileRows
    $lblFileInfo.Text = "$($rows.Count) hits"
    Write-Log "$($rows.Count) match(es) for '$query'." $(if ($rows.Count) { $colorGood } else { $colorWarn })
}

function Open-FileEntry {
    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { return }

    if ($rows[0].IsDirectory) {
        Update-FileList -Path $rows[0].Path
    } else {
        Save-DeviceFiles
    }
}

function Set-FileParent {
    $current = $script:filePath
    if (-not $current -or $current -eq '/') { return }
    $parent = $current.TrimEnd('/')
    $index = $parent.LastIndexOf('/')
    $parent = if ($index -le 0) { '/' } else { $parent.Substring(0, $index) }
    Update-FileList -Path $parent
}


function Show-TransferRow {
    param([switch]$Off)

    $running = -not $Off
    $prgFile.Visible = $running
    $lblFileProgress.Visible = $running
    $btnFileCancel.Visible = $running
    $btnFileCancel.Enabled = $running
    $lblFileSpace.Visible = -not $running
    if (-not $running) {
        $prgFile.Value = 0
        $lblFileProgress.Text = ''
    }
}

function Invoke-FileTransfer {
    <#
        One adb pull or push with a progress bar and a Cancel that really stops
        it. adb prints no progress at all when its output is redirected, so the
        bar measures the destination instead: the local file for a pull, the
        file on the phone for a push.
    #>
    param(
        [string]$Serial,
        [ValidateSet('pull', 'push')][string]$Direction,
        [string]$Source,
        [string]$Target,
        [long]$Size = -1,
        [string]$Caption = ''
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial $Direction " + ('"' + $Source + '" "' + $Target + '"')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # adb writes UTF-8. Left unset, .NET decodes a redirected stream with the
    # console code page, and on a PC still on an OEM page (437, 720, ...) an
    # Arabic file name in adb's messages came back garbled - measured.
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return [PSCustomObject]@{ Ok = $false; Text = 'adb did not start'; Cancelled = $false } }

    $script:busy++
    $cancelled = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPoll = 0
    $done = 0

    try {
        while (-not $process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60

            if ($script:transferCancelled) {
                try { $process.Kill() } catch { }
                $cancelled = $true
                break
            }

            # a pull grows a file here, so ask the file system; a push grows a
            # file over there, so ask the phone, but not too often
            if ($Direction -eq 'pull') {
                if (Test-Path -LiteralPath $Target -PathType Leaf) {
                    try { $done = (Get-Item -LiteralPath $Target).Length } catch { }
                }
            } elseif (($watch.ElapsedMilliseconds - $lastPoll) -gt 700) {
                $lastPoll = $watch.ElapsedMilliseconds
                $remote = Get-DeviceFileSize -Serial $Serial -Path $Target
                if ($remote -gt 0) { $done = $remote }
            }

            if ($Size -gt 0) {
                $share = [Math]::Min(1000, [int](1000 * $done / $Size))
                $prgFile.Value = [Math]::Max(0, $share)
                $lblFileProgress.Text = ('{0}  {1} of {2}  ({3}%)' -f $Caption,
                    (Format-FileSize -Bytes $done), (Format-FileSize -Bytes $Size), [int]($share / 10))
            } else {
                $prgFile.Style = 'Marquee'
                $lblFileProgress.Text = ('{0}  {1} so far' -f $Caption, (Format-FileSize -Bytes $done))
            }
        }
        $null = $process.WaitForExit(3000)
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $prgFile.Style = 'Blocks'
    }

    $text = ($process.StandardError.ReadToEnd() + $process.StandardOutput.ReadToEnd()).Trim()
    $code = $process.ExitCode
    $process.Dispose()

    if ($cancelled) {
        # a half written file helps nobody
        if ($Direction -eq 'pull') {
            if (Test-Path -LiteralPath $Target -PathType Leaf) {
                Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            }
        } else {
            $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('rm', '-f', (Quote-DeviceArgument $Target))
        }
        Write-Log "Cancelled, and the half written copy was removed." $colorWarn
        return [PSCustomObject]@{ Ok = $false; Text = 'cancelled'; Cancelled = $true }
    }

    $prgFile.Value = $prgFile.Maximum
    return [PSCustomObject]@{ Ok = ($code -eq 0); Text = $text; Cancelled = $false }
}

function Save-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something in the list first.' $colorWarn; return }

    $destination = $txtFileLocal.Text.Trim()
    if (-not $destination) { Write-Log 'Set the PC folder first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $destination)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
    }

    $script:transferCancelled = $false
    Show-TransferRow
    try {
        $index = 0
        foreach ($row in $rows) {
            $index++
            if ($script:transferCancelled) { break }

            Write-Log "pull $($row.Path) ..." $colorStep
            $size = if ($row.IsDirectory) { -1 } else { Get-DeviceFileSize -Serial $serial -Path $row.Path }
            $target = Join-Path $destination $row.Name
            $caption = if ($rows.Count -gt 1) { "$index/$($rows.Count)  $($row.Name)" } else { $row.Name }

            $result = Invoke-FileTransfer -Serial $serial -Direction 'pull' -Source $row.Path `
                -Target $target -Size $size -Caption $caption
            if ($result.Cancelled) { break }
            Write-Log ("  " + $result.Text) $(if ($result.Ok) { $colorGood } else { $colorBad })
        }
    } finally {
        Show-TransferRow -Off
    }
}

function Send-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = "Upload to $($script:filePath)"
    $dialog.InitialDirectory = $txtFileLocal.Text
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $script:transferCancelled = $false
    Show-TransferRow
    try {
        $index = 0
        $files = @($dialog.FileNames)
        foreach ($file in $files) {
            $index++
            if ($script:transferCancelled) { break }

            $name = [System.IO.Path]::GetFileName($file)
            $target = Join-DevicePath -Parent $script:filePath -Child $name
            Write-Log "push $file -> $target" $colorStep
            $size = -1
            try { $size = (Get-Item -LiteralPath $file).Length } catch { }
            $caption = if ($files.Count -gt 1) { "$index/$($files.Count)  $name" } else { $name }

            $result = Invoke-FileTransfer -Serial $serial -Direction 'push' -Source $file `
                -Target $target -Size $size -Caption $caption
            if ($result.Cancelled) { break }
            Write-Log ("  " + $result.Text) $(if ($result.Ok) { $colorGood } else { $colorBad })
        }
    } finally {
        Show-TransferRow -Off
    }

    Update-FileList
}

function Get-DeviceFileSize {
    param([string]$Serial, [string]$Path)

    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ls', '-la', (Quote-DeviceArgument $Path))
    if ($result.Text -match '^[dlbcps-][rwxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s') { return [long]$Matches[1] }
    return -1
}

function Move-FilesToPc {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something in the list first.' $colorWarn; return }

    $destination = $txtFileLocal.Text.Trim()
    if (-not $destination) { Write-Log 'Set the PC folder first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $destination)) { $null = New-Item -ItemType Directory -Path $destination -Force }

    $list = ($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Move to $destination and delete from the phone?" + [Environment]::NewLine + $list,
        'Move to PC', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($row in $rows) {
        Write-Log "move $($row.Path) -> PC ..." $colorStep
        $remoteSize = if ($row.IsDirectory) { -1 } else { Get-DeviceFileSize -Serial $serial -Path $row.Path }

        $pull = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', $row.Path, $destination)
        if ($pull.ExitCode -ne 0) {
            Write-Log ('  pull failed, nothing deleted: ' + (($pull.Lines | Select-Object -Last 1))) $colorBad
            continue
        }

        # only delete once the copy is really here and the size matches
        $local = Join-Path $destination $row.Name
        if (-not (Test-Path -LiteralPath $local)) {
            Write-Log '  the copy is not on the PC, nothing deleted.' $colorBad
            continue
        }
        if (-not $row.IsDirectory) {
            $localSize = (Get-Item -LiteralPath $local).Length
            if ($remoteSize -ge 0 -and $localSize -ne $remoteSize) {
                Write-Log "  size mismatch (phone $remoteSize, PC $localSize) - nothing deleted." $colorBad
                continue
            }
        }

        $arguments = if ($row.IsDirectory) { @('rm', '-rf', (Quote-DeviceArgument $row.Path)) }
                     else { @('rm', '-f', (Quote-DeviceArgument $row.Path)) }
        $remove = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
        if ($remove.Text.Trim()) {
            Write-Log ('  delete failed: ' + $remove.Text.Trim()) $colorBad
        } else {
            Write-Log "  moved, phone copy deleted." $colorGood
            $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
                'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $row.Path)
        }
    }

    Update-FileList
}

function Move-FilesToPhone {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = "Move to $($script:filePath) (the PC copy is deleted)"
    $dialog.InitialDirectory = $txtFileLocal.Text
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Upload these and delete them from this PC?" + [Environment]::NewLine + ($dialog.FileNames -join [Environment]::NewLine),
        'Move to phone', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($file in $dialog.FileNames) {
        $name = [System.IO.Path]::GetFileName($file)
        $target = Join-DevicePath -Parent $script:filePath -Child $name
        Write-Log "move $file -> $target ..." $colorStep

        $push = Invoke-Adb -CommandArguments @('-s', $serial, 'push', $file, $target)
        if ($push.ExitCode -ne 0) {
            Write-Log ('  push failed, the PC file is kept: ' + (($push.Lines | Select-Object -Last 1))) $colorBad
            continue
        }

        $localSize = (Get-Item -LiteralPath $file).Length
        $remoteSize = Get-DeviceFileSize -Serial $serial -Path $target
        if ($remoteSize -ne $localSize) {
            Write-Log "  size mismatch (PC $localSize, phone $remoteSize) - the PC file is kept." $colorBad
            continue
        }

        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $file) {
            Write-Log '  uploaded, but the PC file could not be deleted.' $colorWarn
        } else {
            Write-Log '  moved, PC copy deleted.' $colorGood
        }
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $target)
    }

    Update-FileList
}

function New-DeviceDirectory {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $name = [Microsoft.VisualBasic.Interaction]::InputBox("New folder inside $($script:filePath):", 'New folder', 'new-folder')
    if (-not $name.Trim()) { return }

    $target = Join-DevicePath -Parent $script:filePath -Child $name.Trim()
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('mkdir', '-p', (Quote-DeviceArgument $target))
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorBad
    } else {
        Write-Log "created $target" $colorGood
    }
    Update-FileList
}

function Rename-DeviceFile {
    param([string]$NewName)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -ne 1) { Write-Log 'Pick exactly one entry to rename.' $colorWarn; return }

    $name = $NewName
    if (-not $name) {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('New name:', 'Rename', $rows[0].Name)
    }
    if (-not "$name".Trim() -or $name -eq $rows[0].Name) { return }

    # rename inside the folder the entry actually lives in (search hits differ)
    $parent = $rows[0].Path.Substring(0, $rows[0].Path.LastIndexOf('/'))
    if (-not $parent) { $parent = '/' }
    $target = Join-DevicePath -Parent $parent -Child $name.Trim()
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'mv', (Quote-DeviceArgument $rows[0].Path), (Quote-DeviceArgument $target))
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorBad
    } else {
        Write-Log "renamed to $name" $colorGood
    }
    Update-FileList
}

function Remove-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something to delete first.' $colorWarn; return }

    $list = ($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Delete these from the phone? This cannot be undone.' + [Environment]::NewLine + $list,
        'Delete', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($row in $rows) {
        $arguments = if ($row.IsDirectory) { @('rm', '-rf', (Quote-DeviceArgument $row.Path)) }
                     else { @('rm', '-f', (Quote-DeviceArgument $row.Path)) }
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
        if ($result.Text.Trim()) {
            Write-Log ("$($row.Path): " + $result.Text.Trim()) $colorBad
        } else {
            Write-Log "deleted $($row.Path)" $colorWarn
        }
        # media files linger in MediaStore until it rescans
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $row.Path)
    }

    Update-FileList
}

function Open-FileOnPhone {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick a file first.' $colorWarn; return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $rows[0].Path)
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.intent.action.VIEW', '-d', ('file://' + $rows[0].Path))
    Write-Log ($result.Text.Trim()) $colorInfo
    Write-Log 'Android blocks file:// URIs for most apps; the phone may refuse to open it.' $colorWarn
}



# --- root and recovery --------------------------------------------------------

function Update-RootLayout {
    <#
        The page was laid out once, at 864 px, and scrolled sideways in any
        narrower window. Every row now takes the page's own width, and a group
        whose buttons do not fit on one line wraps them onto a second.
    #>
    $width = $tabRoot.ClientSize.Width
    if ($width -lt 300) { return }
    $inner = $width - 24

    $lblRootWarn.SetBounds(14, 10, ($inner - 4), 36)
    $chkRootUnlock.SetBounds(14, 50, 300, 22)
    $btnRootCheck.SetBounds(330, 46, 150, 28)
    # the verdict is long - build, debuggable, secure, uid, then the conclusion -
    # so it has a line of its own instead of being cut off beside the button
    $lblRootState.SetBounds(14, 80, ($inner - 4), 20)

    $y = 106
    foreach ($entry in @(
            @($grpRootAdb, @($btnRootOn, $btnRootOff, $btnRootRemount, $btnRootWaitDevice)),
            @($grpRootImage, @($btnRootVerityOff, $btnRootVerityOn)),
            @($grpRootOther, @($btnRootSideload, $btnRootEmu, $btnRootJdwp, $btnRootKeygen, $btnRootDevPath)))) {
        $x = 12
        $row = 26
        foreach ($button in $entry[1]) {
            if ($x -gt 12 -and ($x + $button.Width) -gt ($inner - 12)) { $x = 12; $row += 34 }
            $button.SetBounds($x, $row, $button.Width, 28)
            $x += $button.Width + 8
        }
        $entry[0].SetBounds(12, $y, $inner, ($row + 40))
        $y += $row + 46
    }
    $lblRootNote.SetBounds(14, $y, ($inner - 4), 36)
}

function Reset-RootAvailability {
    # marks read from one phone must not be read later as another phone's answer
    $script:rootCheckedSerial = $null
    if ($lblRootState.Text -eq 'not checked yet') { return }
    $lblRootState.Text = 'not checked yet'
    $lblRootState.ForeColor = [System.Drawing.Color]::DimGray
    foreach ($button in $script:rootButtons) {
        $button.Text = [string][char]0x26D4 + ' ' + $button.Tag.Caption
        $button.Enabled = $chkRootUnlock.Checked
    }
}

function Get-JdwpProcesses {
    <#
        adb jdwp prints the ids of processes that accept a Java debugger, and
        then keeps running, adding ids as apps start, until it is stopped.
        Measured on the test phone: still running, with nothing printed, when a
        10 s limit ended it. Through Invoke-Adb the button therefore blocked for
        three minutes and then threw the output away. It now gets a few seconds
        and is stopped, and what it printed by then is the answer. The process
        stopped is the adb client for this one command, never the adb server.
    #>
    param([string]$Serial, [int]$Milliseconds = 3000)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial jdwp"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return $null }

    $buffer = New-Object System.IO.MemoryStream
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
    $errorText = ''
    $script:busy++
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -and $watch.ElapsedMilliseconds -lt $Milliseconds) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        $null = $process.WaitForExit(2000)
        try { $null = $copy.Wait(1000) } catch { }
        try { $errorText = $process.StandardError.ReadToEnd().Trim() } catch { }
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $process.Dispose()
    }

    $text = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
    return [PSCustomObject]@{
        Pids  = @($text -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
        Error = $errorText
    }
}

function Get-DeviceProcessNames {
    # pid -> process name, from one ps on the phone; a bare pid tells nobody anything
    param([string]$Serial)

    $names = @{}
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ps', '-A', '-o', 'PID,NAME')
    foreach ($line in @($result.Lines)) {
        if ($line -match '^\s*(\d+)\s+(\S+)') { $names[$Matches[1]] = $Matches[2] }
    }
    return $names
}

function Show-JdwpProcesses {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "adb -s $serial jdwp  (for 3 s - it never stops by itself)" $colorStep
    $result = Get-JdwpProcesses -Serial $serial
    if (-not $result) { Write-Log '  adb did not start.' $colorBad; return }
    if ($result.Error) { Write-Log ("  " + $result.Error) $colorBad; return }
    if ($result.Pids.Count -eq 0) {
        Write-Log ('  no process accepts a debugger. Only apps built as debuggable do, ' +
            'and a retail phone rarely runs one.') $colorInfo
        return
    }

    $names = Get-DeviceProcessNames -Serial $serial
    foreach ($id in $result.Pids) {
        $name = if ($names.ContainsKey($id)) { $names[$id] } else { '?' }
        Write-Log ("  {0,-7} {1}" -f $id, $name) $colorGood
    }
}

function Update-RootAvailability {
    <#
        Marks each action against the device that is selected, rather than
        guessing. A retail phone answers "user" and everything stays off.
    #>
    $serial = Get-TargetSerial
    if (-not $serial) { $lblRootState.Text = 'select a device first'; return }

    $buildType = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.build.type')).Text.Trim()
    $debuggable = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.debuggable')).Text.Trim()
    $secure = (Invoke-DeviceShell -Serial $serial -CommandArguments @('getprop', 'ro.secure')).Text.Trim()
    $uid = (Invoke-DeviceShell -Serial $serial -CommandArguments @('id', '-u')).Text.Trim()

    $rootable = ($buildType -eq 'userdebug') -or ($buildType -eq 'eng') -or ($debuggable -eq '1')
    $alreadyRoot = ($uid -eq '0')

    $lblRootState.Text = "build=$buildType  debuggable=$debuggable  secure=$secure  shell uid=$uid"
    if ($alreadyRoot) {
        $lblRootState.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40)
        $lblRootState.Text += '   -> adb is already root'
    } elseif ($rootable) {
        $lblRootState.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40)
        $lblRootState.Text += '   -> this build allows adb root'
    } else {
        $lblRootState.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)
        $lblRootState.Text += '   -> a retail build: none of this can work here'
    }

    foreach ($button in $script:rootButtons) {
        $needs = $button.Tag.Needs
        $possible = $false
        if ($needs -like 'nothing*') { $possible = $true }
        elseif ($needs -like '*rooted adbd*') { $possible = $alreadyRoot }
        elseif ($needs -like '*userdebug*') { $possible = $rootable }
        elseif ($needs -like '*root*') { $possible = ($rootable -or $alreadyRoot) }

        $mark = if ($possible) { [string][char]0x2714 } else { [string][char]0x26D4 }
        $button.Text = $mark + ' ' + $button.Tag.Caption
        $button.Enabled = $possible -or $chkRootUnlock.Checked
    }

    $script:rootCheckedSerial = $serial
    Write-Log "$serial : build=$buildType debuggable=$debuggable, shell uid=$uid" $colorInfo
}

function Set-RootUnlock {
    foreach ($button in $script:rootButtons) {
        $allowed = $button.Text.StartsWith([string][char]0x2714)
        $button.Enabled = $chkRootUnlock.Checked -or $allowed
    }
    if ($chkRootUnlock.Checked) {
        Write-Log 'Root actions unlocked. A retail phone still refuses them, and that refusal is the phone talking.' $colorWarn
    }
}

function Invoke-RootAction {
    param([string[]]$Arguments)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log ("adb -s $serial " + ($Arguments -join ' ')) $colorStep
    $result = Invoke-Adb -CommandArguments (@('-s', $serial) + $Arguments)
    $text = (($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()
    if (-not $text) {
        $text = "(no output, exit $($result.ExitCode))"
        # measured: adb emu on a phone fails with exit 1 and prints nothing at all
        if ($Arguments[0] -eq 'emu' -and $result.ExitCode -ne 0) { $text += ' - a phone has no emulator console' }
    }

    $bad = ($result.ExitCode -ne 0) -or ($text -match 'cannot run as root|not permitted|closed|error')
    Write-Log ("  " + $text) $(if ($bad) { $colorBad } else { $colorGood })
    if ($bad -and $text -match 'production builds') {
        Write-Log '  that is the phone refusing, exactly as this page warned.' $colorInfo
    }
    Wait-Pumped -Milliseconds 800
    Update-DeviceList
    # root and unroot restart adbd on the same phone: the serial stays, the
    # answer can change. Wait for adbd to come back, then read it again.
    if ($Arguments[0] -in 'root', 'unroot') {
        $null = Invoke-Adb -CommandArguments @('-s', $serial, 'wait-for-device') -TimeoutMs 15000
        Update-RootAvailability
    }
}

function Save-AdbKeygen {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'adb key (*.key)|*.key|All files (*.*)|*.*'
    $dialog.FileName = 'adbkey'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $result = Invoke-Adb -CommandArguments @('keygen', $dialog.FileName)
    Write-Log ("keygen: " + ((($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim())) $colorInfo
    if (Test-Path -LiteralPath $dialog.FileName) {
        Write-Log "Wrote $($dialog.FileName). Nothing was installed; adb still uses its own key." $colorWarn
    }
}

function Send-Sideload {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Update package (*.zip)|*.zip'
    $dialog.Title = 'Sideload - the phone must already be in recovery'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Sideload this package to $serial ?" + [Environment]::NewLine + [Environment]::NewLine +
        'This writes a system update. A phone that is not in recovery simply refuses; one that is ' +
        'must not be unplugged until it finishes.',
        'Sideload', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Invoke-RootAction -Arguments @('sideload', $dialog.FileName)
}

function Restart-Sharing {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "gnirehtet restart $serial ..." $colorStep
    $result = Invoke-Gnirehtet -CommandArguments (@('restart', $serial) + (Get-ExtraArguments))
    Write-Log ((($result.Lines | Where-Object { $_.Trim() }) -join ' ').Trim()) $colorInfo
}

# --- Wi-Fi, Bluetooth, NFC and users -----------------------------------------

function Get-RadioFeature {
    # what the hardware actually has, so a missing radio is reported honestly
    param([string]$Serial)

    if (-not $script:deviceFeatures.ContainsKey($Serial)) {
        $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('pm', 'list', 'features')).Text
        $script:deviceFeatures[$Serial] = $text
    }
    return $script:deviceFeatures[$Serial]
}


function Get-WifiConnection {
    # which network the phone is actually on, not just what it can see
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('cmd', 'wifi', 'status')).Text
    $state = [PSCustomObject]@{ Enabled = $false; Ssid = ''; Rssi = ''; Speed = ''; Frequency = '' }

    if ($text -match 'Wifi is enabled') { $state.Enabled = $true }
    if ($text -match 'Wifi is connected to "([^"]*)"') { $state.Ssid = $Matches[1] }
    # the dump is one long comma separated line, so stop at the comma
    if ($text -match 'RSSI:\s*(-?\d+)') { $state.Rssi = $Matches[1] }
    if ($text -match 'Link speed:\s*([^,]+)') { $state.Speed = $Matches[1].Trim() }
    if ($text -match 'Frequency:\s*([^,]+)') { $state.Frequency = $Matches[1].Trim() }
    return $state
}

function Get-BluetoothConnections {
    # the addresses the dump reports as connected, whatever section they sit in
    param([string]$Dump)

    $addresses = @()
    $inConnected = $false
    foreach ($line in ($Dump -split "`r?`n")) {
        if ($line -match '(?i)connected devices:') { $inConnected = $true; continue }
        if ($inConnected) {
            if ($line -match '([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})') { $addresses += $Matches[1].ToUpper() }
            elseif (-not $line.Trim()) { $inConnected = $false }
            continue
        }
        # per profile lines such as "mCurrentDevice: XX:.." or "ActiveDevice: XX:.."
        if ($line -match '(?i)(current|active|connected)\w*\s*(device)?\s*[:=]\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})') {
            $addresses += $Matches[3].ToUpper()
        }
    }
    return @($addresses | Sort-Object -Unique)
}

function Get-DeviceScreenState {
    # locked / unlocked and screen on / off, for the line under the device list
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
    if ($null -eq $state.Locked -and $trust -match 'deviceLocked=(\d)') {
        $state.Locked = ($Matches[1] -eq '1')
    }

    $display = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "dumpsys display | grep -m1 mScreenState")).Text
    if ($display -match 'mScreenState=(\w+)') {
        $state.ScreenOn = ($Matches[1] -eq 'ON')
    } else {
        $power = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "dumpsys power | grep -m1 mWakefulness=")).Text
        if ($power -match 'mWakefulness=(\w+)') { $state.ScreenOn = ($Matches[1] -eq 'Awake') }
    }
    return $state
}

function Get-SignalStrength {
    # what the list sorts by, strongest first: the number, not the text -
    # as text "-60 dBm" came before "-45 dBm", since 6 > 4. A saved network
    # that is out of range ("saved") goes last.
    param([string]$Signal)

    if ($Signal -match '^(-?\d+)') { return [int]$Matches[1] }
    return -1000
}

function Update-WifiList {
    param([switch]$Scan, [switch]$Saved)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $link = Get-WifiConnection -Serial $serial
    if (-not $link.Enabled) {
        $lblWifiState.Text = 'Wi-Fi: off'
    } elseif ($link.Ssid) {
        $extra = @()
        if ($link.Rssi) { $extra += "$($link.Rssi) dBm" }
        if ($link.Speed) { $extra += $link.Speed }
        if ($link.Frequency) { $extra += $link.Frequency }
        $lblWifiState.Text = "Wi-Fi: connected to $($link.Ssid)" +
            $(if ($extra.Count -gt 0) { '   (' + ($extra -join ', ') + ')' } else { '' })
    } else {
        $lblWifiState.Text = 'Wi-Fi: on, not connected to any network'
    }

    if ($Scan) {
        Write-Log 'Asking the phone to scan ...' $colorStep
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'start-scan')
        Wait-Pumped -Milliseconds 3000
    }

    $rows = @()
    if (-not $Saved) {
        $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'list-scan-results')).Text
        foreach ($line in ($text -split "`r?`n")) {
            # BSSID Frequency RSSI Age(sec) SSID Flags
            if ($line -match '^\s*([0-9a-fA-F:]{17})\s+(\d+)\s+(-?\d+)\s+\S+\s+(.*?)\s{2,}(.*)$') {
                $rows += [PSCustomObject]@{
                    Ssid     = $Matches[4].Trim()
                    Security = $Matches[5].Trim()
                    Signal   = "$($Matches[3]) dBm"
                    Bssid    = $Matches[1]
                    SavedId  = ''
                }
            }
        }
    }

    # saved networks, so Connect and Forget have something to work with
    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'list-networks')).Text
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+(.*?)\s{2,}(\S+)\s*$') {
            # Android 15 prints a network once per security type it accepts,
            # with the same id ("wpa2-psk", then "wpa3-sae^"): one row per id
            if (@($rows | Where-Object { $_.SavedId -eq $Matches[1] }).Count -gt 0) { continue }
            $ssid = $Matches[2].Trim()
            # case-sensitive, and only a scanned row not yet given an id: "KAIF 5G"
            # and "Kaif 5G" are two saved networks, and -eq made them one row
            $known = @($rows | Where-Object { $_.Ssid -ceq $ssid -and -not $_.SavedId })
            if ($known.Count -gt 0) {
                foreach ($entry in $known) { $entry.SavedId = $Matches[1] }
            } elseif ($Saved -or $rows.Count -eq 0) {
                $rows += [PSCustomObject]@{
                    Ssid = $ssid; Security = $Matches[3].Trim(); Signal = 'saved'
                    Bssid = ''; SavedId = $Matches[1]
                }
            }
        }
    }

    $lstWifi.BeginUpdate()
    try {
        $lstWifi.Items.Clear()
        foreach ($row in ($rows | Sort-Object -Property @{ Expression = { Get-SignalStrength $_.Signal } } -Descending)) {
            $joined = ($link.Ssid -and $row.Ssid -ceq $link.Ssid)
            $item = New-Object System.Windows.Forms.ListViewItem(
                $(if ($joined) { $row.Ssid + '   <- connected' } else { $row.Ssid }))
            $null = $item.SubItems.Add($row.Security)
            $null = $item.SubItems.Add($(if ($joined -and $link.Rssi) { "$($link.Rssi) dBm" } else { $row.Signal }))
            $null = $item.SubItems.Add($row.Bssid)
            $null = $item.SubItems.Add($row.SavedId)
            if ($joined) {
                $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40)
                $item.Font = New-Object System.Drawing.Font($lstWifi.Font, [System.Drawing.FontStyle]::Bold)
            }
            $item.Tag = $row
            $null = $lstWifi.Items.Add($item)
        }
    } finally {
        $lstWifi.EndUpdate()
    }
    Write-Log "$($rows.Count) network(s) listed." $colorInfo
}

function Set-WifiRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'wifi', 'set-wifi-enabled', $(if ($On) { 'enabled' } else { 'disabled' }))
    Wait-Pumped -Milliseconds 1200
    Write-Log ("Wi-Fi turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-WifiList
}

function Connect-WifiNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($lstWifi.SelectedItems.Count -eq 0) { Write-Log 'Pick a network first.' $colorWarn; return }

    $row = $lstWifi.SelectedItems[0].Tag
    $security = 'open'
    if ($row.Security -match 'wpa3|sae') { $security = 'wpa3' }
    elseif ($row.Security -match 'wpa2|psk|wpa') { $security = 'wpa2' }
    elseif ($row.Security -match 'wep') { $security = 'wep' }
    elseif ($row.Security -match 'owe') { $security = 'owe' }

    $arguments = @('cmd', 'wifi', 'connect-network', $row.Ssid, $security)
    $password = $txtWifiPass.Text
    if ($security -ne 'open' -and $security -ne 'owe') {
        if (-not $password) {
            Write-Log "$($row.Ssid) needs a password - type it in the box first." $colorWarn
            return
        }
        $arguments += $password
    }

    Write-Log "Joining $($row.Ssid) ($security) ..." $colorStep
    # a network called "My Home", or a password with a space or a $ in it
    $result = Invoke-DeviceCommand -Serial $serial -Arguments $arguments
    if ($result.Text -match 'Failed|Error|error') {
        Write-Log $result.Text.Trim() $colorBad
    } else {
        Write-Log "Connect requested for $($row.Ssid)." $colorGood
    }
    Wait-Pumped -Milliseconds 2500
    Update-WifiList
}

function Remove-WifiNetwork {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($lstWifi.SelectedItems.Count -eq 0) { Write-Log 'Pick a saved network first.' $colorWarn; return }

    $row = $lstWifi.SelectedItems[0].Tag
    if (-not $row.SavedId) { Write-Log "$($row.Ssid) is not saved on the phone." $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show("Forget $($row.Ssid) on the phone?",
        'Forget network', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'forget-network', $row.SavedId)
    Write-Log "Forgot $($row.Ssid)." $colorGood
    Update-WifiList -Saved
}

function Show-WifiStatus {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'wifi', 'status')).Text
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim()) { Write-Log "  $($line.Trim())" $colorInfo }
    }
}

function Update-BluetoothList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if ((Get-RadioFeature -Serial $serial) -notmatch 'android\.hardware\.bluetooth') {
        $lblBtState.Text = 'Bluetooth: this device reports no Bluetooth hardware'
        return
    }

    $dump = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'bluetooth_manager')).Text
    $enabled = if ($dump -match '(?m)^\s*enabled:\s*(\S+)') { $Matches[1] } else { 'unknown' }
    $connected = @(Get-BluetoothConnections -Dump $dump)

    $rows = @()
    $inBonded = $false
    foreach ($line in ($dump -split "`r?`n")) {
        if ($line -match 'Bonded devices:') { $inBonded = $true; continue }
        if ($inBonded) {
            if ($line -match '^\s*([0-9A-Fa-f:]{17})\s*\[([^\]]*)\]\s*(.*)$') {
                $address = $Matches[1].ToUpper()
                $rows += [PSCustomObject]@{
                    Name    = $Matches[3].Trim()
                    Address = $Matches[1]
                    Bond    = $(if ($connected -contains $address) { 'connected' } else { 'paired' })
                }
            } elseif (-not $line.Trim()) {
                $inBonded = $false
            }
        }
    }

    $lstBt.BeginUpdate()
    try {
        $lstBt.Items.Clear()
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem(
                $(if ($row.Bond -eq 'connected') { $row.Name + '   <- connected' } else { $row.Name }))
            $null = $item.SubItems.Add($row.Address)
            $null = $item.SubItems.Add($row.Bond)
            if ($row.Bond -eq 'connected') {
                $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40)
                $item.Font = New-Object System.Drawing.Font($lstBt.Font, [System.Drawing.FontStyle]::Bold)
            }
            $item.Tag = $row
            $null = $lstBt.Items.Add($item)
        }
    } finally {
        $lstBt.EndUpdate()
    }

    $live = @($rows | Where-Object { $_.Bond -eq 'connected' })
    if ($enabled -ne 'true') {
        $lblBtState.Text = 'Bluetooth: off'
    } elseif ($live.Count -gt 0) {
        $lblBtState.Text = "Bluetooth: on   |   connected to " + (($live | ForEach-Object { $_.Name }) -join ', ')
    } else {
        $lblBtState.Text = "Bluetooth: on   |   $($rows.Count) paired, none connected"
    }
    Write-Log "$($rows.Count) paired device(s), $($live.Count) connected." $colorInfo
}

function Set-BluetoothRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cmd', 'bluetooth_manager', $(if ($On) { 'enable' } else { 'disable' }))
    Wait-Pumped -Milliseconds 1500
    Write-Log ("Bluetooth turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-BluetoothList
}

function Update-NfcState {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if ((Get-RadioFeature -Serial $serial) -notmatch 'android\.hardware\.nfc') {
        $lblNfcState.Text = 'NFC: not present on this device'
        $txtNfcInfo.Text = 'pm list features reports no android.hardware.nfc on this phone.'
        return
    }

    $dump = (Invoke-DeviceShell -Serial $serial -CommandArguments @('dumpsys', 'nfc')).Text
    $state = if ($dump -match 'mState=(\S+)') { $Matches[1] } else { 'unknown' }
    $lblNfcState.Text = "NFC: $state"

    $lines = @()
    foreach ($line in ($dump -split "`r?`n")) {
        if ($line -match 'mState=|mIsSecureNfcEnabled|mScreenState|NfcService|mPollingDisableDeathRecipients|SecureNfc') {
            $lines += $line.Trim()
        }
        if ($lines.Count -ge 14) { break }
    }
    $txtNfcInfo.Text = ($lines -join "`r`n")
}

function Set-NfcRadio {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'svc', 'nfc', $(if ($On) { 'enable' } else { 'disable' }))
    if ($result.Text -match 'Killed|denied|Exception') { Write-Log $result.Text.Trim() $colorBad }
    Wait-Pumped -Milliseconds 1500
    Write-Log ("NFC turned " + $(if ($On) { 'on' } else { 'off' }) + " on $serial.") $colorGood
    Update-NfcState
}

function Update-UserList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'list', 'users')).Text
    $current = (Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'get-current-user')).Text.Trim()
    $max = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'get-max-users')).Text
    $maxCount = if ($max -match '(\d+)') { $Matches[1] } else { '?' }
    $switcher = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'get', 'global', 'user_switcher_enabled')).Text.Trim()

    $rows = @()
    foreach ($line in ($text -split "`r?`n")) {
        # UserInfo{0:Owner:4c13} running
        if ($line -match 'UserInfo\{(\d+):([^:]*):([0-9a-fA-F]+)\}\s*(.*)$') {
            $flags = [Convert]::ToInt32($Matches[3], 16)
            $kind = @()
            if ($flags -band 0x00000001) { $kind += 'primary' }
            if ($flags -band 0x00000002) { $kind += 'admin' }
            if ($flags -band 0x00000004) { $kind += 'guest' }
            if ($flags -band 0x00000008) { $kind += 'restricted' }
            if ($flags -band 0x00000020) { $kind += 'managed' }
            if ($flags -band 0x00000800) { $kind += 'system' }
            $rows += [PSCustomObject]@{
                Id    = $Matches[1]
                Name  = $Matches[2]
                State = $Matches[4].Trim()
                Kind  = ($kind -join ', ')
                Flags = '0x' + $Matches[3]
            }
        }
    }

    $lstUsers.BeginUpdate()
    try {
        $lstUsers.Items.Clear()
        foreach ($row in $rows) {
            $label = if ($row.Id -eq $current) { "$($row.Id)  <- current" } else { $row.Id }
            $item = New-Object System.Windows.Forms.ListViewItem($label)
            $null = $item.SubItems.Add($row.Name)
            $null = $item.SubItems.Add($row.State)
            $null = $item.SubItems.Add($row.Kind)
            $null = $item.SubItems.Add($row.Flags)
            if ($row.Id -eq $current) { $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40) }
            $item.Tag = $row
            $null = $lstUsers.Items.Add($item)
        }
    } finally {
        $lstUsers.EndUpdate()
    }

    $switchLabel = switch ($switcher) { '1' { 'on' } '0' { 'off' } default { 'not set' } }
    $lblUsersState.Text = "$($rows.Count) user(s) of at most $maxCount   |   current user: $current   |   user switcher: $switchLabel"
    if ($maxCount -eq '1') {
        $lblUsersState.Text = "This phone allows a single user only (pm get-max-users = 1)."
    }
}

function Get-SelectedUser {
    if ($lstUsers.SelectedItems.Count -eq 0) {
        Write-Log 'Pick a user in the list first.' $colorWarn
        return $null
    }
    return $lstUsers.SelectedItems[0].Tag
}

function Switch-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    Write-Log "Switching $serial to user $($user.Id) ($($user.Name)) ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'switch-user', $user.Id)
    if ($result.Text -match 'Error|Exception|denied') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }
    Wait-Pumped -Milliseconds 2500
    Write-Log "The phone is now on user $($user.Id)." $colorGood
    Update-UserList
}

function Add-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Name for the new user:', 'Add user', 'user')
    if (-not $name.Trim()) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('pm', 'create-user', $name.Trim())
    if ($result.Text -match 'Success.*id (\d+)') {
        Write-Log "Created user $($Matches[1]) '$($name.Trim())'." $colorGood
    } else {
        Write-Log ("create-user said: " + $result.Text.Trim()) $colorBad
    }
    Update-UserList
}

function Rename-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    $name = [Microsoft.VisualBasic.Interaction]::InputBox("New name for user $($user.Id):", 'Rename user', $user.Name)
    if (-not $name.Trim() -or $name -eq $user.Name) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('pm', 'rename-user', $user.Id, $name.Trim())
    if ($result.Text -match 'MANAGE_USERS') {
        # adb shell holds CREATE_USERS but not MANAGE_USERS, so Android refuses
        Write-Log 'Android does not let adb rename a user (MANAGE_USERS is a system permission).' $colorWarn
        Write-Log 'Rename it on the phone: Settings > Users, or use "User settings" here.' $colorInfo
    } elseif ($result.Text -match 'Error|Exception|denied|Unknown') {
        Write-Log $result.Text.Trim() $colorBad
    } else {
        Write-Log "User $($user.Id) is now '$($name.Trim())'." $colorGood
    }
    Update-UserList
}

function Remove-DeviceUser {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $user = Get-SelectedUser
    if (-not $user) { return }

    if ($user.Id -eq '0') {
        Write-Log 'User 0 is the owner and cannot be removed.' $colorWarn
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete user $($user.Id) '$($user.Name)' and everything inside it?" + "`r`n`r`n" +
        'Apps, accounts and files of that user are erased on the phone. This cannot be undone.',
        'Remove user', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('pm', 'remove-user', $user.Id)
    if ($result.Text -match 'Success') {
        Write-Log "Removed user $($user.Id)." $colorGood
    } else {
        Write-Log ("remove-user said: " + $result.Text.Trim()) $colorBad
    }
    Update-UserList
}

function Set-UserSwitcher {
    param([bool]$On)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'put', 'global', 'user_switcher_enabled', $(if ($On) { '1' } else { '0' }))
    Write-Log ("User switcher turned " + $(if ($On) { 'on' } else { 'off' }) + ". Existing users are untouched.") $colorGood
    Update-UserList
}

function Open-DeviceSettingsScreen {
    param([string]$Action)

    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-a', $Action)
    Write-Log "Opened $Action on the phone." $colorInfo
}

# --- running processes -------------------------------------------------------

$script:cameraProcesses = @()
$script:deviceFeatures = @{}
$script:panelWidth = 440
$script:previewFiles = @()
$script:logcatRaw = $null
$script:transferCancelled = $false
$script:widthBeforeHide = 0
$script:filePath = '/sdcard'
$script:fileBack = New-Object System.Collections.ArrayList
$script:fileForward = New-Object System.Collections.ArrayList
$script:fileNavigating = $false
$script:fileRows = @()
$script:fileSortColumn = 0
$script:fileSortDescending = $false
$script:fileFoldersFirst = $true
$script:fileSearchResults = $false
$script:runningRows = @()
$script:runningSortColumn = 5
$script:runningSortDescending = $true

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
                switch ($Matches[2]) {
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
        $kind = if ($Matches['kind']) { $Matches['kind'] } else { '' }

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

function Update-RunningList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $script:runningRows = @(Get-RunningProcesses -Serial $serial)

    $filter = $txtRunningFilter.Text.Trim()
    $rows = $script:runningRows
    if ($chkRunningApps.Checked) {
        $rows = @($rows | Where-Object { $_.Name -like '*.*' })
    }
    if ($filter) {
        $rows = @($rows | Where-Object { Test-TextContains $_.Name $filter })
    }

    $property = switch ($script:runningSortColumn) {
        0 { 'Name' }
        1 { 'Pid' }
        2 { 'State' }
        3 { 'Kind' }
        4 { 'Cpu' }
        5 { 'Memory' }
        default { 'User' }
    }
    $rows = @($rows | Sort-Object -Property $property -Descending:$script:runningSortDescending)

    $selected = @($lstRunning.SelectedItems | ForEach-Object { $_.SubItems[1].Text })

    $lstRunning.BeginUpdate()
    try {
        $lstRunning.Items.Clear()
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
            $null = $item.SubItems.Add($row.Pid)
            $null = $item.SubItems.Add($row.State)
            $null = $item.SubItems.Add($row.Kind)
            $null = $item.SubItems.Add(('{0:N1}' -f $row.Cpu))
            $null = $item.SubItems.Add(('{0:N1}' -f $row.Memory))
            $null = $item.SubItems.Add($row.User)

            # foreground work in green, cached/empty processes in grey
            if ($row.State -like 'fg*' -or $row.State -like 'vis*' -or $row.State -like 'top*') {
                $item.ForeColor = [System.Drawing.Color]::ForestGreen
            } elseif ($row.State -like 'cch*' -or $row.State -like 'empty*') {
                $item.ForeColor = [System.Drawing.Color]::Gray
            }
            if ($selected -contains $row.Pid) { $item.Selected = $true }
            $null = $lstRunning.Items.Add($item)
        }
    } finally {
        $lstRunning.EndUpdate()
    }

    $free = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'cat /proc/meminfo | grep MemAvailable')).Text
    $freeText = if ($free -match '(\d+)\s*kB') { ('{0:N0} MB free' -f ([int]$Matches[1] / 1024)) } else { '' }
    $lblRunningInfo.Text = "$($lstRunning.Items.Count) processes  |  $freeText"
}

function Get-SelectedProcesses {
    $rows = @()
    foreach ($item in $lstRunning.SelectedItems) {
        $rows += [PSCustomObject]@{
            Name    = $item.Text
            Package = ($item.Text -split ':')[0]
            Pid     = $item.SubItems[1].Text
            User    = $item.SubItems[6].Text
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

    $answer = [System.Windows.Forms.MessageBox]::Show($prompt, 'Stop process', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

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

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Kill every background process on $serial ?", 'Kill all', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

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
    Update-Capture -Quiet
}

function Export-RunningList {
    if ($lstRunning.Items.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt'
    $dialog.FileName = 'running-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $lines = @('process,pid,state,kind,cpu,memory_mb,user')
    foreach ($item in $lstRunning.Items) {
        $lines += ('{0},{1},{2},{3},{4},{5},{6}' -f $item.Text, $item.SubItems[1].Text, $item.SubItems[2].Text,
            $item.SubItems[3].Text, $item.SubItems[4].Text, $item.SubItems[5].Text, $item.SubItems[6].Text)
    }
    Set-Content -LiteralPath $dialog.FileName -Value $lines -Encoding UTF8
    Write-Log "Exported $($lstRunning.Items.Count) processes to $($dialog.FileName)" $colorGood
}

# --- explicit layout for the two full-size tabs ------------------------------


function Update-MirrorLayout {
    # The groups stack down the page on one running y; inside each the controls
    # sit on rows. At the smallest window a row that would run out of its group
    # wraps instead, and the group - and everything under it - makes room. At
    # full width every row lands exactly where it always did.
    $width = $tabScrcpy.ClientSize.Width
    if ($width -lt 300) { return }
    $inner = $width - 24
    $half = [int](($inner - 12) / 2)

    $x = 12
    foreach ($pair in @(@('Max size', $cmbMaxSize, 58, 80), @('Bit rate', $cmbBitrate, 52, 80),
            @('Max FPS', $cmbFps, 58, 70), @('Codec', $cmbCodec, 46, 110))) {
        $script:scrcpyLabels[$pair[0]].SetBounds($x, 26, $pair[2], 20)
        $x += $pair[2] + 4
        $pair[1].SetBounds($x, 22, $pair[3], 24)
        $x += $pair[3] + 16
    }
    # Codecs after the codec, or under it when the row is full
    $videoHeight = 56
    if (($x + $btnListEncoders.Width) -gt ($inner - 12)) {
        $btnListEncoders.SetBounds(12, 53, $btnListEncoders.Width, 26)
        $videoHeight = 88
    } else {
        $btnListEncoders.SetBounds($x, 21, $btnListEncoders.Width, 26)
    }
    $grpVideo.SetBounds(12, 6, $inner, $videoHeight)
    $y = 6 + $videoHeight + 6

    $windowBoxes = @($chkFullscreen, $chkBorderless, $chkOnTop, $chkNoScreensaver)
    $phoneBoxes = @($chkScreenOff, $chkStayAwake, $chkNoAudio, $chkViewOnly, $chkPowerOff)
    $null = Set-CheckRow -Left 12 -Top 24 -Limit ($half - 16) -Boxes $windowBoxes
    $null = Set-CheckRow -Left 12 -Top 24 -Limit ($half - 16) -Boxes $phoneBoxes
    # the two halves as tall as the taller one, however their boxes wrapped
    $optsHeight = [Math]::Max(80, 8 + [Math]::Max((Get-ControlsBottom -Controls $windowBoxes),
            (Get-ControlsBottom -Controls $phoneBoxes)))
    $grpWindowOpts.SetBounds(12, $y, $half, $optsHeight)
    $grpPhoneOpts.SetBounds((24 + $half), $y, $half, $optsHeight)
    $y += $optsHeight + 6

    $script:scrcpyLabels['Display'].SetBounds(12, 26, 46, 20)
    $cmbDisplay.SetBounds(62, 22, 70, 24)
    $btnListDisplays.SetBounds(138, 21, $btnListDisplays.Width, 26)
    $chkNewDisplay.SetBounds(($btnListDisplays.Bounds.Right + 12), 24, 110, 22)
    $txtNewDisplay.SetBounds(($chkNewDisplay.Bounds.Right + 4), 22, 130, 24)
    # Start app beside the display, or on a row of its own when that would
    # leave the list too narrow to read an app's name in it
    $row = 0
    if (($inner - $txtNewDisplay.Bounds.Right - 90) -ge 160) {
        $script:scrcpyLabels['Start app'].SetBounds(($txtNewDisplay.Bounds.Right + 12), 26, 62, 20)
        $cmbStartApp.SetBounds(($txtNewDisplay.Bounds.Right + 78), 22, ($inner - $txtNewDisplay.Bounds.Right - 90), 24)
    } else {
        $row = 32
        $script:scrcpyLabels['Start app'].SetBounds(12, 58, 62, 20)
        $cmbStartApp.SetBounds(78, 54, ($inner - 90), 24)
    }

    $chkRecord.SetBounds(12, (54 + $row), 80, 22)
    $txtRecord.SetBounds(96, (52 + $row), [Math]::Max(120, ($inner - 96 - $btnBrowseRecord.Width - 24)), 24)
    $btnBrowseRecord.SetBounds(($txtRecord.Bounds.Right + 8), (51 + $row), $btnBrowseRecord.Width, 26)

    $lblExtraArgs.SetBounds(12, (86 + $row), 96, 20)
    $txtExtraArgs.SetBounds(112, (84 + $row), [Math]::Max(140, ($inner - 130)), 24)
    $grpTarget.SetBounds(12, $y, $inner, (116 + $row))
    $y += 116 + $row + 6

    $chkOtg.SetBounds(12, 24, 150, 22)
    $x = 170
    foreach ($pair in @(@('Keyboard', $cmbKeyboard), @('Mouse', $cmbMouse), @('Gamepad', $cmbGamepad))) {
        $script:scrcpyLabels[$pair[0]].SetBounds($x, 26, 62, 20)
        $pair[1].SetBounds(($x + 64), 22, 90, 24)
        $x += 164
    }
    # the layout button after the three modes, or under them when there is no room
    $controlHeight = 56
    if (($x + $btnKeyboardLayout.Width) -gt ($inner - 12)) {
        $btnKeyboardLayout.SetBounds(12, 53, $btnKeyboardLayout.Width, 26)
        $controlHeight = 88
    } else {
        $btnKeyboardLayout.SetBounds($x, 21, $btnKeyboardLayout.Width, 26)
    }
    $grpControl.SetBounds(12, $y, $inner, $controlHeight)
    $y += $controlHeight + 8

    $null = Set-ButtonFlow -Left 12 -Top $y -Limit ($inner + 12) -Buttons @($btnScrcpy, $btnScrcpyShare, $btnOtg,
        $btnScrcpyClose, $btnShowCommand)
}

function Update-MoreLayout {
    <#
        This page had no layout function: two columns of 440 px groups over an
        892 px one, which ran off any page narrower than about 916 px. Two
        columns when they fit, one otherwise, and the keyboard group's switches
        wrap onto as many rows as its width needs.
    #>
    $width = $tabMore.ClientSize.Width
    if ($width -lt 300) { return }
    $inner = $width - 24

    $switches = @($chkPreferText, $chkRawKeys, $chkNoKeyRepeat, $chkLegacyPaste, $chkKillAdb, $chkNoCleanup)
    if ($inner -ge 892) {
        # as designed
        $grpRecord.SetBounds(12, 8, 440, 84)
        $grpTurn.SetBounds(464, 8, 440, 84)
        $grpVirtual.SetBounds(12, 100, 440, 84)
        $grpWindow.SetBounds(464, 100, 440, 84)
        $chkPreferText.SetBounds(468, 26, 184, 22)
        $chkRawKeys.SetBounds(660, 26, 140, 22)
        $chkNoKeyRepeat.SetBounds(14, 54, 130, 22)
        $chkLegacyPaste.SetBounds(154, 54, 120, 22)
        $chkKillAdb.SetBounds(284, 54, 270, 22)
        $chkNoCleanup.SetBounds(564, 54, 240, 22)
        $grpInput.SetBounds(12, 192, 892, 84)
        return
    }

    $y = 8
    foreach ($group in @($grpRecord, $grpTurn, $grpVirtual, $grpWindow)) {
        $group.SetBounds(12, $y, $inner, 84)
        $y += 92
    }
    # the shortcut key and mouse fields keep their row; the switches follow it
    $null = Set-CheckRow -Left 14 -Top 54 -Limit ($inner - 12) -Boxes $switches
    $grpInput.SetBounds(12, $y, $inner, [Math]::Max(84, (Get-ControlsBottom -Controls $switches) + 8))
}

function Set-CheckRow {
    # check boxes side by side, each as wide as its own text, wrapping to a
    # second line rather than sliding out of the box
    param($Boxes, [int]$Left, [int]$Top, [int]$Gap = 10, [int]$Limit = 0)

    $x = $Left
    $y = $Top
    foreach ($box in $Boxes) {
        $needed = [System.Windows.Forms.TextRenderer]::MeasureText($box.Text, $box.Font).Width + 26
        if ($Limit -gt 0 -and $x -gt $Left -and ($x + $needed) -gt $Limit) {
            $x = $Left
            $y += 26
        }
        $box.SetBounds($x, $y, $needed, 22)
        $x += $needed + $Gap
    }
    return $x
}


function Update-CamMicLayout {
    $width = $tabCamera.ClientSize.Width
    $height = $tabCamera.ClientSize.Height
    if ($width -lt 300 -or $height -lt 200) { return }
    $inner = $width - 24

    $grpCamera.SetBounds(12, 6, $inner, 172)
    $btnListCameraSizes.SetBounds([Math]::Max(300, ($inner - 92)), 52, 70, 26)
    $script:cameraLabels['Camera'].SetBounds(12, 26, 52, 20)
    $cmbCamera.SetBounds(68, 22, [Math]::Max(160, ($inner - 420)), 24)
    $btnCameraList.SetBounds(($cmbCamera.Bounds.Right + 8), 21, $btnCameraList.Width, 26)
    $script:cameraLabels['Facing'].SetBounds(($btnCameraList.Bounds.Right + 14), 26, 46, 20)
    $cmbCameraFacing.SetBounds(($btnCameraList.Bounds.Right + 64), 22, 100, 24)

    $x = 12
    foreach ($pair in @(@('Size', $cmbCameraSize, 40, 110), @('FPS', $cmbCameraFps, 32, 70),
            @('Aspect', $cmbCameraAr, 48, 90))) {
        $script:cameraLabels[$pair[0]].SetBounds($x, 58, $pair[2], 20)
        $x += $pair[2] + 4
        $pair[1].SetBounds($x, 54, $pair[3], 24)
        $x += $pair[3] + 16
    }
    # zoom sits with the other picture settings; the switches get their own row
    # rather than being squeezed against the "Sizes" button
    $lblCameraZoom.SetBounds($x, 58, 40, 20)
    $cmbCameraZoom.SetBounds(($x + 44), 54, 60, 24)

    $null = Set-CheckRow -Left 12 -Top 86 -Limit ($inner - 24) -Boxes @($chkCameraHighSpeed,
        $chkCameraTorch, $chkCameraMic)

    $chkCameraRecord.SetBounds(12, 116, 90, 22)
    $txtCameraRecord.SetBounds(106, 114, [Math]::Max(120, ($inner - 106 - $btnCameraBrowse.Width - 24)), 24)
    $btnCameraBrowse.SetBounds(($txtCameraRecord.Bounds.Right + 8), 113, $btnCameraBrowse.Width, 26)
    $lblCameraHint.SetBounds(12, 146, [Math]::Max(200, $inner - 24), 18)

    $null = Set-ButtonRowLeft -Left 12 -Top 186 -Buttons @($btnCameraStart, $btnCameraFront, $btnCameraBack,
        $btnCameraStop, $btnCameraCommand)

    $grpAudio.SetBounds(12, 226, $inner, 154)
    $lblAudioSource.SetBounds(12, 30, 50, 20)
    $cmbAudioSource.SetBounds(66, 26, 200, 24)
    $null = Set-ButtonRowLeft -Left 274 -Top 25 -Buttons @($btnListen, $btnListenStop, $btnRecordAudio)

    # what is sent: the codec, the encoder that makes it, and the refresh
    # that reads both from the phone - one row, because they depend on each other
    $lblAudioCodec.SetBounds(12, 62, 50, 20)
    $cmbAudioCodec.SetBounds(66, 58, 100, 24)
    $lblAudioEncoder.SetBounds(178, 62, 56, 20)
    $cmbAudioEncoder.SetBounds(236, 58,
        [Math]::Min(260, [Math]::Max(150, ($inner - 236 - $btnAudioEncoders.Width - 30))), 24)
    $btnAudioEncoders.SetBounds(($cmbAudioEncoder.Bounds.Right + 6), 57, $btnAudioEncoders.Width, 26)

    # how much of it, where it plays, and how much delay it may absorb
    $lblAudioBitrate.SetBounds(12, 94, 52, 20)
    $cmbAudioBitrate.SetBounds(66, 90, 100, 24)
    $chkAudioDup.SetBounds(178, 92, 222, 22)
    $lblAudioBuffer.SetBounds(406, 94, 64, 20)
    $txtAudioBuffer.SetBounds(472, 90, 60, 24)

    $lblAudioHint.SetBounds(12, 124, [Math]::Max(200, $inner - 24), 20)
}


function Update-TetherLayout {
    $width = $tabShare.ClientSize.Width
    if ($width -gt 300) {
        $inner = $width - 24

        $grpTunnel.SetBounds(12, 6, $inner, 96)
        $lblTunnelDns.SetBounds(12, 28, 34, 20)
        $cmbDns.SetBounds(50, 24, 150, 24)
        $lblPort.SetBounds(214, 28, 34, 20)
        $numPort.SetBounds(252, 24, 80, 24)
        $lblRoutes.SetBounds(346, 28, 50, 20)
        $txtRoutes.SetBounds(400, 24, [Math]::Max(120, ($inner - 412)), 24)
        $tunnelBoxes = @($chkWifi, $chkReinstall, $chkAutoTest, $chkScrcpyAfter)
        $null = Set-CheckRow -Left 12 -Top 58 -Limit ($inner - 12) -Boxes $tunnelBoxes
        # the boxes wrap at a narrow window; the group grows with them and
        # everything under it moves down by the same amount
        $grow = [Math]::Max(0, (Get-ControlsBottom -Controls $tunnelBoxes) + 8 - 96)
        $grpTunnel.SetBounds(12, 6, $inner, (96 + $grow))

        $null = Set-ButtonRowLeft -Left 12 -Top (112 + $grow) -Buttons @($btnStart, $btnStop, $btnTest)
        $null = Set-ButtonRowLeft -Left 12 -Top (150 + $grow) -Buttons @($btnInstallClient, $btnUninstallClient,
            $btnShareRestart)
        $chkShareAutostart.SetBounds(($btnShareRestart.Bounds.Right + 12), (154 + $grow),
            [Math]::Min(320, [Math]::Max(120, ($width - 12 - $btnShareRestart.Bounds.Right - 12))), 22)
        $lblShareHint.SetBounds(12, (188 + $grow), [Math]::Max(200, $inner), 34)
    }

    $width = $tabTether.ClientSize.Width
    if ($width -gt 300) {
        $inner = $width - 24

        $grpUsbTether.SetBounds(12, 6, $inner, 146)
        $null = Set-ButtonRowLeft -Left 12 -Top 22 -Buttons @($btnTetherOn, $btnTetherOff,
            $btnTetherSettings, $btnAdapters)
        $chkTetherMetered.SetBounds(12, 56, [Math]::Max(200, $inner - 24), 22)
        $lblTetherStatus.SetBounds(12, 80, [Math]::Max(200, $inner - 24), 20)
        $lblTetherHint.SetBounds(12, 100, [Math]::Max(200, $inner - 24), 18)
        $lblTetherHint2.SetBounds(12, 118, [Math]::Max(200, $inner - 24), 18)

        $grpProxy.SetBounds(12, 160, $inner, 104)
        $lblProxyTitle.SetBounds(12, 22, [Math]::Max(200, $inner - 24), 20)
        $lblProxyPort.SetBounds(12, 50, 70, 20)
        $numProxyPort.SetBounds(86, 46, 80, 24)
        $null = Set-ButtonRowLeft -Left 178 -Top 45 -Buttons @($btnProxyOn, $btnProxyOff, $btnProxyTest)
        $lblProxyHint.SetBounds(12, 78, [Math]::Max(200, $inner - 24), 18)
    }
}

function Update-ToolsLayout {
    # every control sits inside the group that names it, and the groups stack
    # down the page in one place
    $width = $tabTools.ClientSize.Width
    if ($width -lt 300) { return }
    $inner = $width - 24

    # the five tools on one row when they fit, on two when they do not; the
    # rows under them, and every group after this one, move down to match
    $next = Set-ButtonFlow -Left 12 -Top 20 -Limit ($inner - 12) -Buttons @($btnPair, $btnMdns, $btnReconnect,
        $btnBugReport, $btnTcpip)
    $grow = $next - 54
    $txtConnect.SetBounds(12, (56 + $grow), 180, 24)
    $null = Set-ButtonRowLeft -Left 200 -Top (54 + $grow) -Buttons @($btnConnect, $btnDisconnect, $btnRestartServer)
    $grpConnect.SetBounds(12, 6, $inner, (96 + $grow))

    # the three that are only reached for when something is stuck sit in their
    # own group: the Connection group had twelve controls and read as a wall
    $grpUnstick.SetBounds(12, (108 + $grow), $inner, 62)
    $null = Set-ButtonRowLeft -Left 12 -Top 24 -Buttons @($btnReverseList, $btnKillRelays, $btnRepairTunnel)

    $grpDeviceActions.SetBounds(12, (176 + $grow), $inner, 62)
    $null = Set-ButtonRowLeft -Left 12 -Top 24 -Buttons @($btnInstallApk, $btnScreenshot, $btnScreenToggle,
        $btnReboot, $btnBattery)

    $grpDnsBox.SetBounds(12, (244 + $grow), $inner, 86)
    $lblDns.SetBounds(12, 28, 34, 20)
    $cmbDnsMode.SetBounds(50, 24, 180, 24)
    # the host box gives up width so its three buttons stay inside the group
    $dnsButtons = @($btnDnsRead, $btnDnsAdGuard, $btnDnsApply)
    $buttonsWidth = 0
    foreach ($button in $dnsButtons) { $buttonsWidth += $button.Width + 8 }
    $hostWidth = [Math]::Max(100, [Math]::Min(200, ($inner - 12 - 238 - 8 - $buttonsWidth)))
    $txtDnsHost.SetBounds(238, 24, $hostWidth, 24)
    $null = Set-ButtonRowLeft -Left (238 + $hostWidth + 8) -Top 23 -Buttons $dnsButtons
    $txtDnsState.SetBounds(12, 56, [Math]::Max(200, $inner - 24), 20)

    $grpImeBox.SetBounds(12, (336 + $grow), $inner, 92)
    $lblIme.SetBounds(12, 28, 92, 20)
    # likewise the keyboard list for its three buttons
    $imeButtons = @($btnImeList, $btnImeDisable, $btnImeEnable)
    $buttonsWidth = 0
    foreach ($button in $imeButtons) { $buttonsWidth += $button.Width + 8 }
    $imeWidth = [Math]::Max(140, [Math]::Min(300, ($inner - 12 - 106 - 8 - $buttonsWidth)))
    $cmbIme.SetBounds(106, 24, $imeWidth, 24)
    $null = Set-ButtonRowLeft -Left (106 + $imeWidth + 8) -Top 23 -Buttons $imeButtons
    $null = Set-ButtonRowLeft -Left 12 -Top 55 -Buttons @($btnImeDefault, $btnImeReset)
    $lblImeHint.SetBounds(($btnImeReset.Bounds.Right + 12), 60, [Math]::Max(80, $inner - $btnImeReset.Bounds.Right - 24), 20)

    $grpHotspotBox.SetBounds(12, (434 + $grow), $inner, 96)
    $lblHotspot.SetBounds(12, 28, 60, 20)
    $null = Set-ButtonRowLeft -Left 76 -Top 24 -Buttons @($btnHotspotOn, $btnHotspotOff, $btnHotspotState,
        $btnHotspotSettings, $btnHotspotInfo)
    $null = Set-ButtonRowLeft -Left 76 -Top 58 -Buttons @($btnUsbTetherOn, $btnUsbTetherOff)

    $lblToolsHint.SetBounds(12, (536 + $grow), [Math]::Max(80, $inner), 20)
}

function Update-ScreenLayout {
    if ($splitMain.Panel1Collapsed) { return }

    $width = $grpScreen.ClientSize.Width
    $height = $grpScreen.ClientSize.Height
    if ($width -lt 200 -or $height -lt 200) { return }

    # the group box caption takes the first rows for itself
    $top = 14

    # row 1: capture controls, row 2: device keys, row 3: text input
    $x = 8
    foreach ($button in @($btnCapture, $btnSaveShot, $btnClearShot)) {
        $button.SetBounds($x, ($top + 4), $button.Width, 26)
        $x += $button.Width + 6
    }
    $chkAutoShot.SetBounds($x, ($top + 8), 50, 22)
    $numShotMs.SetBounds(($x + 52), ($top + 5), 64, 24)
    $lblScreenInfo.SetBounds(($x + 122), ($top + 8), [Math]::Max(40, $width - $x - 130), 20)

    $x = 8
    foreach ($button in @($btnKeyBack, $btnKeyHome, $btnKeyRecents, $btnKeyPower, $btnKeyVolUp, $btnKeyVolDown)) {
        $button.SetBounds($x, ($top + 36), $button.Width, 26)
        $x += $button.Width + 6
    }

    $btnSendText.SetBounds(($width - 98), ($top + 67), 90, 26)
    $txtSendText.SetBounds(8, ($top + 68), [Math]::Max(80, $width - 114), 24)

    # the hint's second line wraps again in a narrow pane; it gets the height
    # its text measures at this width, and the picture ends above it. Two lines
    # measure 30, which puts both exactly where they always were.
    $hintHeight = [System.Windows.Forms.TextRenderer]::MeasureText($lblScreenHint.Text, $lblScreenHint.Font,
        (New-Object System.Drawing.Size(($width - 16), 10000)),
        [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
    $hintHeight = [Math]::Max(30, $hintHeight)
    $lblScreenHint.SetBounds(8, ($height - $hintHeight - 4), ($width - 16), $hintHeight)
    $picScreen.SetBounds(8, ($top + 100), ($width - 16), ($height - $hintHeight - 10 - ($top + 100)))
}


function Set-ButtonRowLeft {
    # place buttons side by side from the left, each keeping its own width
    param($Buttons, [int]$Left, [int]$Top, [int]$Gap = 8)

    $x = $Left
    foreach ($button in $Buttons) {
        $button.SetBounds($x, $Top, $button.Width, 28)
        $x += $button.Width + $Gap
    }
    return $x
}

function Set-ButtonRowRight {
    # place buttons from the right edge backwards, last one nearest the edge
    param($Buttons, [int]$Right, [int]$Top, [int]$Gap = 8)

    $x = $Right
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $x -= $Buttons[$i].Width
        $Buttons[$i].SetBounds($x, $Top, $Buttons[$i].Width, 28)
        $x -= $Gap
    }
}

function Set-ButtonFlow {
    # buttons side by side at their own widths, as Set-ButtonRowLeft does, but
    # one that would pass Limit starts a new row; returns the next free y
    param($Buttons, [int]$Left, [int]$Top, [int]$Limit, [int]$Gap = 8, [int]$RowStep = 34)

    $x = $Left
    $y = $Top
    foreach ($button in $Buttons) {
        if ($x -gt $Left -and ($x + $button.Width) -gt $Limit) { $x = $Left; $y += $RowStep }
        $button.SetBounds($x, $y, $button.Width, 28)
        $x += $button.Width + $Gap
    }
    return ($y + $RowStep)
}

function Get-ControlsBottom {
    # the lowest edge among some controls, to size the box that holds them
    param($Controls)

    $bottom = 0
    foreach ($control in $Controls) {
        if ($control.Bounds.Bottom -gt $bottom) { $bottom = $control.Bounds.Bottom }
    }
    return $bottom
}


function Update-DeviceTabLayout {
    $width = $tabDevice.ClientSize.Width
    $height = $tabDevice.ClientSize.Height
    if ($width -lt 300 -or $height -lt 200) { return }

    $btnDeviceRefresh.SetBounds(14, 10, 190, 28)
    $btnDeviceCopy.SetBounds(212, 10, 80, 28)
    $btnDeviceScrcpy.SetBounds(300, 10, 150, 28)
    $btnOpenNova.SetBounds(458, 10, 140, 28)

    $rightWidth = [Math]::Max(390, [Math]::Min(460, [int]($width * 0.46)))
    $leftWidth = [Math]::Max(200, $width - $rightWidth - 38)
    # a cut off sentence helps nobody: it shows only when it fits, and the
    # tooltip carries it the rest of the time
    $room = $leftWidth - 598
    $lblDeviceHint.Visible = ($room -ge 150)
    # always placed, even when hidden: a control left at its creation spot still
    # has bounds, and those bounds sat on top of the Mirror button
    $lblDeviceHint.SetBounds(604, 16, [Math]::Max(1, $room), 20)
    $toolTip.SetToolTip($btnDeviceRefresh, $lblDeviceHint.Text)
    $txtDeviceInfo.SetBounds(14, 46, $leftWidth, ($height - 58))

    $x = 14 + $leftWidth + 12
    $grpToggles.SetBounds($x, 46, $rightWidth, 214)
    $grpDial.SetBounds($x, 268, $rightWidth, 84)

    # The phone group was never laid out: its buttons kept their design places
    # and ran out of the group at the smallest window. The number and the two
    # buttons that act on it share a row; the other three go below.
    $dialWidth = $grpDial.ClientSize.Width
    $btnPhoneEnd.SetBounds(($dialWidth - 12 - $btnPhoneEnd.Width), 24, $btnPhoneEnd.Width, 26)
    $btnPhoneCall.SetBounds(($btnPhoneEnd.Left - 8 - $btnPhoneCall.Width), 24, $btnPhoneCall.Width, 26)
    $lblPhoneNumber.SetBounds(12, 28, 56, 20)
    $txtPhoneNumber.SetBounds(72, 25, [Math]::Max(100, ($btnPhoneCall.Left - 8 - 72)), 24)
    $x2 = 12
    foreach ($button in @($btnPhoneSms, $btnPhoneUssd, $btnPhoneDialer)) {
        $button.SetBounds($x2, 54, $button.Width, 26)
        $x2 += $button.Width + 8
    }

    # two columns, sized from what the buttons actually are now
    if ($script:togglePairs.Count -gt 0) {
        $buttonWidth = $script:togglePairs[0][1].Width
        # the caption gives way first, down to what the captions need, so the
        # two columns still fit the group at the smallest window
        $room = $grpToggles.ClientSize.Width - 24
        $labelWidth = [Math]::Max(84, [Math]::Min(100, [Math]::Floor(($room - 8) / 2) - (2 * $buttonWidth) - 12))
        $pairWidth = $labelWidth + 8 + (2 * $buttonWidth) + 4
        $column = [Math]::Max($pairWidth + 8, [int](($grpToggles.ClientSize.Width - 24) / 2))

        for ($i = 0; $i -lt $script:togglePairs.Count; $i++) {
            $entry = $script:togglePairs[$i]
            # Floor, not [int]: PowerShell rounds .5 to the even number, so
            # [int](3/2) and [int](5/2) are both 2 and two rows land on each other
            $row = [Math]::Floor($i / 2)
            $left = 12 + (($i % 2) * $column)
            $top = 22 + ($row * 28)
            $entry[0].SetBounds($left, ($top + 5), $labelWidth, 20)
            $entry[1].SetBounds(($left + $labelWidth + 4), $top, $buttonWidth, 26)
            $entry[2].SetBounds(($left + $labelWidth + 8 + $buttonWidth), $top, $buttonWidth, 26)
        }

        $rows = [Math]::Ceiling($script:togglePairs.Count / 2)
        $bottom = 22 + ($rows * 28) + 6
        $null = Set-ButtonRowLeft -Left 12 -Top $bottom -Gap 6 -Buttons @($btnTorch, $btnBuzz,
            $btnReadToggles, $btnDevOpen)
    }
}

function Update-RadioLayout {
    # Wi-Fi, Bluetooth, NFC and Users all look the same: a state line and some
    # buttons on top, a list in the middle, a row of actions at the bottom
    foreach ($entry in @(
            @($tabWifi, $lstWifi, $lblWifiState, @($btnWifiOnTab, $btnWifiOffTab, $btnWifiScan, $btnWifiSaved)),
            @($tabBt, $lstBt, $lblBtState, @($btnBtOnTab, $btnBtOffTab, $btnBtRefresh)),
            @($tabUsers, $lstUsers, $lblUsersState, @($btnUsersRefresh)))) {

        $page = $entry[0]
        $width = $page.ClientSize.Width
        $height = $page.ClientSize.Height
        if ($width -lt 300 -or $height -lt 200) { continue }

        $entry[2].SetBounds(14, 16, [Math]::Max(120, $width - 480), 20)
        $null = Set-ButtonRowRight -Buttons $entry[3] -Right ($width - 12) -Top 10
        $entry[1].SetBounds(12, 44, ($width - 24), ($height - 44 - 50))
    }

    $width = $tabWifi.ClientSize.Width
    $height = $tabWifi.ClientSize.Height
    if ($width -gt 300 -and $height -gt 200) {
        $rowY = $height - 38
        $lblWifiPass.SetBounds(14, ($rowY + 4), 64, 20)
        $txtWifiPass.SetBounds(82, ($rowY + 1), 180, 24)
        $chkWifiShowPass.SetBounds(270, ($rowY + 3), 60, 22)
        $null = Set-ButtonRowLeft -Buttons @($btnWifiConnect, $btnWifiForget, $btnWifiStatus, $btnWifiSettings) -Left 336 -Top $rowY
    }

    $width = $tabBt.ClientSize.Width
    $height = $tabBt.ClientSize.Height
    if ($width -gt 300 -and $height -gt 200) {
        $rowY = $height - 38
        $null = Set-ButtonRowLeft -Buttons @($btnBtSettings, $btnBtCopy) -Left 12 -Top $rowY
        $lblBtHint.SetBounds(300, ($rowY + 6), [Math]::Max(120, $width - 312), 20)
    }

    $width = $tabUsers.ClientSize.Width
    $height = $tabUsers.ClientSize.Height
    if ($width -gt 300 -and $height -gt 200) {
        $null = Set-ButtonRowLeft -Top ($height - 38) -Left 12 -Buttons @($btnUserSwitch, $btnUserAdd, $btnUserRename,
            $btnUserRemove, $btnUserSwitcherOn, $btnUserSwitcherOff, $btnUserSettings)
    }

    $width = $tabNfc.ClientSize.Width
    $height = $tabNfc.ClientSize.Height
    if ($width -gt 300 -and $height -gt 200) {
        $txtNfcInfo.SetBounds(18, 112, ($width - 36), ($height - 124))
    }
}

function Update-DeviceColumns {
    # Serial was 210 px whatever the width, so at the smallest window Client
    # went past the edge behind a scroll bar. The short columns keep their
    # width; Serial and Model share the rest.
    $room = $lstDevices.ClientSize.Width - 4
    if ($room -lt 300 -or $lstDevices.Columns.Count -lt 6) { return }
    $fixed = 55 + 70 + 85 + 70
    $rest = [Math]::Max(200, $room - $fixed)
    $serialWidth = [int]($rest * 0.55)
    $lstDevices.Columns[0].Width = $serialWidth
    $lstDevices.Columns[1].Width = 55
    $lstDevices.Columns[2].Width = $rest - $serialWidth
    $lstDevices.Columns[3].Width = 70
    $lstDevices.Columns[4].Width = 85
    $lstDevices.Columns[5].Width = 70
}

function Switch-LogPane {
    $script:logFolded = -not $script:logFolded
    Update-RightLayout
}

function Update-RightLayout {
    $width = $splitMain.Panel2.ClientSize.Width
    $height = $splitMain.Panel2.ClientSize.Height
    if ($width -lt 400 -or $height -lt 300) { return }

    $btnTogglePane.SetBounds(0, [int](($height - 76) / 2), 16, 76)

    # a short window gives the device list two rows instead of four: one phone
    # is the usual case, and every pixel here is one the pages below lack
    $listHeight = if ($height -lt 760) { 70 } else { 115 }
    $grpDevices.SetBounds(20, 6, ($width - 26), ($listHeight + 56))
    $lstDevices.Height = $listHeight
    # as wide as the list, so it never runs under the buttons beside it
    $lblDeviceStatus.SetBounds(14, (22 + $listHeight + 6), ($lstDevices.Width - 2), 20)
    Update-DeviceColumns
    $tabsTop = $grpDevices.Bottom + 6

    # the pages keep at least this much; the log gives way first
    $pagesLeast = 300
    $logMost = [Math]::Max(60, $height - $tabsTop - 48 - $pagesLeast)
    if ($script:logFolded) {
        $logHeight = 0
    } elseif ($script:logHeight -gt 0) {
        $logHeight = [Math]::Max(60, [Math]::Min($logMost, $script:logHeight))
    } else {
        $logHeight = if ($height -lt 760) { 80 } else { [Math]::Max(90, [Math]::Min(190, [int]($height * 0.22))) }
        $logHeight = [Math]::Min($logMost, $logHeight)
    }

    $rowTop = if ($script:logFolded) { $height - 34 } else { $height - $logHeight - 40 }
    $txtLog.Visible = -not $script:logFolded
    if ($script:logFolded) {
        # hidden, but still placed where it overlaps nothing
        $txtLog.SetBounds(20, ($height - 4), ($width - 26), 1)
        $btnLogFold.Text = [char]0x25B2
        $toolTip.SetToolTip($btnLogFold, 'Show the log again')
    } else {
        $txtLog.SetBounds(20, ($height - $logHeight - 6), ($width - 26), $logHeight)
        $btnLogFold.Text = [char]0x25BC
        $toolTip.SetToolTip($btnLogFold, 'Fold the log away and give its room to the pages')
    }
    $btnClear.SetBounds(20, $rowTop, 96, 28)
    $btnSaveLog.SetBounds(124, $rowTop, 96, 28)
    $btnLogFold.SetBounds(228, $rowTop, 28, 28)
    $lblStatus.SetBounds(($width - 226), $rowTop, 220, 28)
    # the find box sits at the right end of the row, just left of the sharing
    # line; the busy strip below stops where the box begins, and both step
    # aside when the window is too narrow to hold them side by side
    $findWidth = [Math]::Min(200, [Math]::Max(90, [int](($width - 640) / 2)))
    $findLeft = ($width - 234) - $findWidth
    $script:logFindLeft = $findLeft
    # 364 is where the busy line starts; it keeps at least 140 px to name what
    # is running, and the find box only appears with what is left over
    $enoughRoom = (($findLeft - 50) - 364) -ge 140
    $lblLogFind.Visible = $enoughRoom
    $txtLogFind.Visible = $enoughRoom
    if ($enoughRoom) {
        $lblLogFind.SetBounds(($findLeft - 42), $rowTop, 38, 26)
        $txtLogFind.SetBounds($findLeft, ($rowTop + 2), $findWidth, 24)
    } else {
        # hidden is not enough: a control keeps its bounds while it is hidden,
        # and the layout audit rightly counts those. Park the pair in the gap
        # before the sharing line, where they sit on nothing.
        $lblLogFind.SetBounds(($width - 233), $rowTop, 1, 1)
        $txtLogFind.SetBounds(($width - 232), $rowTop, 1, 1)
    }
    $prgBusy.SetBounds(266, ($rowTop + 8), 90, 12)
    # what is running is named up to where the find box starts
    $busyRight = if ($txtLogFind.Visible) { $script:logFindLeft - 50 } else { $width - 234 }
    $lblBusy.SetBounds(364, ($rowTop + 5), [Math]::Max(40, ($busyRight - 364)), 20)
    $pnlLogGrip.SetBounds(20, ($rowTop - 8), ($width - 26), 6)
    $tabs.SetBounds(20, $tabsTop, ($width - 26), ($rowTop - 8 - $tabsTop))

    # the Running page's info line was 300 px from x 556, past a narrow page
    $lblRunningInfo.SetBounds(556, 15, [Math]::Max(100, ($tabRunning.ClientSize.Width - 568)), 20)

    foreach ($pair in @(@($tabApps, $lstApps), @($tabContacts, $lstContacts), @($tabSms, $lstSms),
            @($tabRunning, $lstRunning), @($tabFiles, $lstFiles))) {
        $page = $pair[0]
        $list = $pair[1]
        $pageWidth = $page.ClientSize.Width
        $pageHeight = $page.ClientSize.Height
        if ($pageWidth -lt 300 -or $pageHeight -lt 200) { continue }

        $bottom = if ($list -eq $lstSms) { 120 } else { 90 }
        $list.SetBounds(12, 44, ($pageWidth - 24), ($pageHeight - 44 - $bottom))

        if ($list -eq $lstSms) {
            $rowY = $pageHeight - 74
            $txtSmsTo.SetBounds(38, $rowY, 180, 24)
            $lblSmsTo.SetBounds(12, ($rowY + 4), 24, 20)
            $btnSmsSend.SetBounds(($pageWidth - 130), ($rowY - 1), 118, 26)
            $txtSmsBody.SetBounds(226, $rowY, ($pageWidth - 370), 24)
            $buttonY = $pageHeight - 40
            $chkSmsAutoSend.SetBounds(38, ($buttonY + 4), 280, 22)
            $null = Set-ButtonRowLeft -Left 330 -Top $buttonY -Buttons @($btnSmsCopy, $btnSmsDelete, $btnSmsEdit, $btnSmsExport)
        } elseif ($list -eq $lstApps) {
            $null = Set-ButtonRowLeft -Left 12 -Top ($pageHeight - 40) -Buttons @($btnAppLaunch, $btnAppNewDisplay,
                $btnAppStop, $btnAppInfo, $btnAppUninstall, $btnAppInstall, $btnAppExport)
        } elseif ($list -eq $lstFiles) {
            $list.SetBounds(12, 76, $pageWidth - 24, $pageHeight - 182)
            $lblFileSpace.SetBounds(14, ($pageHeight - 102), [Math]::Max(200, $pageWidth - 28), 18)
            # the transfer row sits where the space line is, and hides it while it runs
            $prgFile.SetBounds(14, ($pageHeight - 102), 300, 18)
            $lblFileProgress.SetBounds(322, ($pageHeight - 102), [Math]::Max(120, $pageWidth - 430), 18)
            $btnFileCancel.SetBounds(($pageWidth - 96), ($pageHeight - 106), 80, 24)
            $rightEnd = $pageWidth - 12
            $cmbFileRecent.SetBounds(($rightEnd - 110), 43, 110, 24)
            $x = $rightEnd - 110 - 8
            foreach ($button in @($btnFileRecent, $btnFileSearchClear, $btnFileSearch)) {
                $x -= $button.Width
                $button.SetBounds($x, 42, $button.Width, 26)
                $x -= 8
            }
            $txtFileSearch.SetBounds(70, 43, [Math]::Max(90, ($x - 78)), 24)
            $rowY = $pageHeight - 78
            # the selection buttons sit directly under the list, the PC folder
            # box takes whatever width is left over
            $btnFileSelectAll.SetBounds(12, ($rowY - 1), 92, 26)
            $btnFileSelectNone.SetBounds(110, ($rowY - 1), 58, 26)
            $btnFileSelectInvert.SetBounds(174, ($rowY - 1), 62, 26)
            $lblFileLocal.SetBounds(244, ($rowY + 3), 62, 20)
            $btnFileOpenLocal.SetBounds(($pageWidth - 12 - $btnFileOpenLocal.Width), ($rowY - 1),
                $btnFileOpenLocal.Width, 26)
            $btnFileLocalBrowse.SetBounds(($btnFileOpenLocal.Bounds.Left - 8 - $btnFileLocalBrowse.Width),
                ($rowY - 1), $btnFileLocalBrowse.Width, 26)
            $txtFileLocal.SetBounds(310, $rowY,
                [Math]::Max(120, ($btnFileLocalBrowse.Bounds.Left - 318)), 24)
            $goLeft = $pageWidth - 462 - $btnFileGo.Width
            $txtFilePath.SetBounds(70, 11, [Math]::Max(90, ($goLeft - 78)), 24)
            $btnFileGo.SetBounds($goLeft, 10, $btnFileGo.Width, 26)
            $cmbFileQuick.SetBounds(($pageWidth - 454), 11, 140, 24)
            $chkFileHidden.SetBounds(($pageWidth - 308), 13, 70, 22)
            $chkFileFoldersFirst.SetBounds(($pageWidth - 232), 13, 104, 22)
            $lblFileInfo.SetBounds(($pageWidth - 122), 14, 114, 20)
            $buttonY = $pageHeight - 40
            # four groups: moving files, organising them, archiving them, opening them
            $null = Set-GroupedRow -Left 12 -Top $buttonY -Rules $fileRules -Groups @(
                @($btnFileDownload, $btnFileMoveToPc, $btnFileUpload, $btnFileMoveToPhone),
                @($btnFileNewDir, $btnFileRename, $btnFileDelete),
                @($btnFileCompress, $btnFileExtract),
                @($btnFilePreview, $btnFileOpenPhone, $btnFileCopyPath))
        } elseif ($list -eq $lstRunning) {
            $null = Set-ButtonRowLeft -Left 12 -Top ($pageHeight - 40) -Buttons @($btnRunningStop, $btnRunningKill,
                $btnRunningInfo, $btnRunningKillAll, $btnRunningCopy, $btnRunningExport)
        } else {
            $buttonY = $pageHeight - 40

            # left: everything that acts on the list
            $null = Set-ButtonRowLeft -Left 12 -Top $buttonY -Buttons @($btnContactAdd, $btnContactEdit,
                $btnContactDelete, $btnContactCopy, $btnContactExport)
            $left = $btnContactExport.Bounds.Right

            # right: the number and the two call buttons, kept as one group
            $boxWidth = 130
            $groupWidth = 46 + $boxWidth + 8 + 84 + 8 + 92
            $start = $pageWidth - 12 - $groupWidth
            if ($start -lt ($left + 16)) {
                # a narrow window steals width from the box, never from the buttons
                $shrink = [Math]::Min(60, (($left + 16) - $start))
                $boxWidth -= $shrink
                $groupWidth -= $shrink
                $start = $pageWidth - 12 - $groupWidth
            }
            $lblDialNumber.SetBounds($start, ($buttonY + 6), 40, 20)
            $txtDialNumber.SetBounds(($start + 46), ($buttonY + 2), $boxWidth, 24)
            $btnContactCall.SetBounds(($start + 46 + $boxWidth + 8), $buttonY, 84, 28)
            $btnContactEndCall.SetBounds(($start + 46 + $boxWidth + 100), $buttonY, 92, 28)
        }
    }

    Update-RadioLayout
    Update-DeviceTabLayout
    Update-MirrorLayout
    Update-CamMicLayout
    Update-TetherLayout
    Update-MoreLayout
}

function Update-LogcatLayout {
    $width = $tabLogcat.ClientSize.Width
    $height = $tabLogcat.ClientSize.Height
    if ($width -lt 300 -or $height -lt 160) { return }

    $btnLogcatSave.SetBounds(($width - 94), 10, 80, 28)
    $chkLogcatFollow.SetBounds(($width - 172), 14, 70, 22)
    # the filter sits between the level and "follow" when there is room for a
    # useful box there, and on a row of its own under the buttons when not -
    # at the smallest window it used to lie on top of "follow" and Save
    $room = ($width - 172 - 8) - 524
    if ($room -ge 120) {
        $lblLogcatFilter.SetBounds(462, 16, 58, 20)
        $txtLogcatFilter.SetBounds(524, 12, $room, 24)
        $top = 46
    } else {
        $lblLogcatFilter.SetBounds(14, 50, 58, 20)
        $txtLogcatFilter.SetBounds(76, 46, ($width - 90), 24)
        $top = 78
    }
    $txtLogcat.SetBounds(14, $top, ($width - 28), ($height - $top - 36))
    $lblLogcatState.SetBounds(14, ($height - 30), ($width - 28), 20)
}

function Update-ShellLayout {
    $width = $tabShell.ClientSize.Width
    $height = $tabShell.ClientSize.Height
    if ($width -lt 300 -or $height -lt 200) { return }

    # the presets list gives way before the status line disappears under it
    $presetWidth = [Math]::Min(290, [Math]::Max(200, ($width - 306 - 150 - 14)))
    $cmbShellPreset.SetBounds(($width - 14 - $presetWidth), 11, $presetWidth, 26)
    $lblShellStatus.SetBounds(306, 16, [Math]::Max(40, ($cmbShellPreset.Left - 8 - 306)), 20)
    $txtShellOut.SetBounds(14, 46, ($width - 28), ($height - 112))
    $btnShellSend.SetBounds(($width - 100), ($height - 58), 86, 28)
    $txtShellIn.SetBounds(14, ($height - 57), ($width - 124), 26)
    $lblShellHint.SetBounds(14, ($height - 24), ($width - 28), 18)
}

# --- screen mirror by screenshot ---------------------------------------------

$script:captureImage = $null
$script:captureSerial = $null
$script:pressPoint = $null
$script:pressTime = $null

$script:capturing = $false
$script:captureCount = 0



function Clear-Capture {
    # drop the picture on screen without touching the phone
    if ($picScreen.Image) {
        $old = $picScreen.Image
        $picScreen.Image = $null
        try { $old.Dispose() } catch { }
    }
    $script:captureImage = $null
    $script:captureSize = $null
    $lblScreenInfo.Text = ''
    Write-Log 'Cleared the picture.' $colorInfo
}

function Switch-ScreenPane {
    # fold the phone picture away and take its width off the window
    if ($splitMain.Panel1Collapsed) {
        $form.MinimumSize = New-Object System.Drawing.Size(1120, 700)
        $splitMain.Panel1Collapsed = $false
        $btnTogglePane.Text = [char]0x25C0
        $toolTip.SetToolTip($btnTogglePane, 'Hide the phone screen and make the window narrower')
        if ($script:widthBeforeHide -gt 0) {
            $form.Width = [Math]::Min([System.Windows.Forms.Screen]::FromControl($form).WorkingArea.Width,
                $script:widthBeforeHide)
        }
        try { $splitMain.SplitterDistance = $script:panelWidth } catch { }
    } else {
        $script:panelWidth = $splitMain.SplitterDistance
        $script:widthBeforeHide = $form.Width
        # without the picture the window may be much narrower than the normal minimum
        $form.MinimumSize = New-Object System.Drawing.Size(760, 700)
        $splitMain.Panel1Collapsed = $true
        $btnTogglePane.Text = [char]0x25B6
        $toolTip.SetToolTip($btnTogglePane, 'Show the phone screen again')
        $form.Width = [Math]::Max($form.MinimumSize.Width, $script:widthBeforeHide - $script:panelWidth)
    }
    Update-RightLayout
    Update-ScreenLayout
}


# --- icon buttons -------------------------------------------------------------
# Windows ships an icon font, so a symbol costs nothing to distribute. Only
# symbols that everybody already reads are used; every other button keeps its
# words, and a glyph the font cannot draw falls back to words by itself.

$script:iconFont = $null
$script:glyphCache = @{}

function Get-IconFont {
    if ($script:iconFont) { return $script:iconFont }

    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families |
        ForEach-Object { $_.Name }
    foreach ($name in @('Segoe Fluent Icons', 'Segoe MDL2 Assets')) {
        if ($installed -contains $name) {
            $script:iconFont = New-Object System.Drawing.Font($name, 12)
            return $script:iconFont
        }
    }
    return $null
}

function Test-Glyph {
    # true when the font really draws this code point, rather than a blank or
    # the missing character box
    param([string]$Code)

    if ($script:glyphCache.ContainsKey($Code)) { return $script:glyphCache[$Code] }

    $font = Get-IconFont
    if (-not $font) { $script:glyphCache[$Code] = $false; return $false }

    $ink = {
        param($character)
        $bitmap = New-Object System.Drawing.Bitmap(40, 40)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawString($character, $font, [System.Drawing.Brushes]::Black, 4, 4)
        $graphics.Dispose()
        # the shape itself, not how much ink it uses: two different glyphs can
        # easily need the same number of pixels
        $shape = New-Object System.Text.StringBuilder
        $count = 0
        for ($y = 0; $y -lt 40; $y += 2) {
            for ($x = 0; $x -lt 40; $x += 2) {
                if ($bitmap.GetPixel($x, $y).R -lt 200) { $null = $shape.Append('1'); $count++ }
                else { $null = $shape.Append('0') }
            }
        }
        $bitmap.Dispose()
        return [PSCustomObject]@{ Count = $count; Shape = $shape.ToString() }
    }

    $drawn = & $ink ([char][convert]::ToInt32($Code, 16))
    # E9FE is not assigned in either font, so it shows whatever "missing" looks like
    $missing = & $ink ([char]0xE9FE)
    $ok = ($drawn.Count -gt 2 -and $drawn.Shape -ne $missing.Shape)
    $script:glyphCache[$Code] = $ok
    return $ok
}

function Set-IconButton {
    <#
        Turns a button into a glyph and moves its old caption into the tooltip.
        A button whose glyph is missing is left exactly as it was.
    #>
    param($Button, [string[]]$Code, [int]$Width = 34, [string]$Hint)

    $caption = $Button.Text
    if (-not $Hint) { $Hint = $caption.Replace('...', '').Trim() }

    $chosen = ''
    foreach ($candidate in $Code) {
        if (Test-Glyph -Code $candidate) { $chosen = $candidate; break }
    }
    if (-not $chosen) {
        $toolTip.SetToolTip($Button, $Hint)
        return $false
    }

    $Button.Text = [string][char][convert]::ToInt32($chosen, 16)
    $Button.Font = Get-IconFont
    $Button.Width = $Width
    $toolTip.SetToolTip($Button, $Hint)
    return $true
}

function Set-TextWidth {
    # a word button is as wide as its word; an icon button keeps its square
    param($Button, [int]$Padding = 22, [int]$Least = 46)

    if ($Button.Font -eq $script:iconFont) { return }
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Button.Text, $Button.Font).Width
    $Button.Width = [Math]::Max($Least, $measured + $Padding)
}

function Convert-ToIconRow {
    # a list of @(button, glyph, hint) pairs, applied in one go
    param($Buttons)

    foreach ($entry in $Buttons) {
        $hint = if ($entry.Count -gt 2) { $entry[2] } else { '' }
        $null = Set-IconButton -Button $entry[0] -Code $entry[1] -Hint $hint
    }
}


function Convert-WindowToIcons {
    <#
        Only symbols a person already reads without being taught: refresh,
        trash, magnifier, arrows, play, gear, camera, floppy, pencil, plus,
        handset, eye, folder, power, X. Everything else keeps its words, and
        any glyph this Windows cannot draw silently keeps its words too.
    #>

    if (-not (Get-IconFont)) {
        Write-Log 'No icon font on this Windows, so every button keeps its words.' $colorInfo
        return
    }

    Convert-ToIconRow -Buttons @(
        # the device list
        @($btnRefresh, 'E72C', 'Refresh the device list'),
        @($btnInfo, 'E946', 'Device info'),

        # the phone picture
        @($btnCapture, 'E114', 'Take a screenshot'),
        @($btnSaveShot, 'E74E', 'Save this picture'),
        @($btnClearShot, 'E711', 'Clear the picture'),
        @($btnKeyBack, 'E72B', 'Back'),
        @($btnKeyHome, 'E80F', 'Home'),
        @($btnKeyPower, 'E7E8', 'Power'),

        # apps
        @($btnAppsRefresh, 'E72C', 'Refresh the app list'),
        @($btnAppLaunch, 'E768', 'Launch the app'),
        @($btnAppInfo, 'E946', 'App info on the phone'),

        # contacts
        @($btnContactsRefresh, 'E72C', 'Refresh the contacts'),
        @($btnContactAdd, 'E710', 'Add a contact'),
        @($btnContactEdit, 'E70F', 'Edit this contact'),
        @($btnContactDelete, 'E74D', 'Delete this contact'),
        @($btnContactCall, 'E717', 'Call the number in the box'),
        @($btnContactCopy, 'E8C8', 'Copy the selected rows'),

        # sms
        @($btnSmsRefresh, 'E72C', 'Refresh the messages'),
        @($btnSmsCopy, 'E8C8', 'Copy the selected rows'),
        @($btnSmsDelete, 'E74D', 'Delete this message'),
        @($btnSmsEdit, 'E70F', 'Edit the body before resending'),

        # running processes
        @($btnRunningRefresh, 'E72C', 'Refresh the process list'),
        @($btnRunningInfo, 'E946', 'App info on the phone'),
        @($btnRunningCopy, 'E8C8', 'Copy the selected rows'),

        # files
        @($btnFileUp, 'E70E', 'Up one folder'),
        @($btnFileSearch, 'E721', 'Search this folder and everything under it'),
        @($btnFileSearchClear, 'E711', 'Clear the search'),
        @($btnFileDownload, @('E896', 'E118', 'E74B'), 'Download to the PC folder'),
        @($btnFileUpload, @('E898', 'E11C', 'E74A'), 'Upload files to this folder'),
        @($btnFileNewDir, 'E8F4', 'New folder on the phone'),
        @($btnFileRename, 'E70F', 'Rename'),
        @($btnFileDelete, 'E74D', 'Delete from the phone'),
        @($btnFileCopyPath, 'E8C8', 'Copy the full path'),
        @($btnFilePreview, 'E7B3', 'Look at it without saving a copy'),
        @($btnFileOpenLocal, 'E8B7', 'Open the PC folder in Explorer'),
        @($btnFileCancel, 'E711', 'Stop the transfer'),

        # radios and users
        @($btnWifiSettings, 'E713', 'Open the Wi-Fi screen on the phone'),
        @($btnBtRefresh, 'E72C', 'Refresh the paired list'),
        @($btnBtSettings, 'E713', 'Open the Bluetooth screen on the phone'),
        @($btnBtCopy, 'E8C8', 'Copy the address'),
        @($btnNfcRefresh, 'E72C', 'Read the NFC state again'),
        @($btnNfcSettings, 'E713', 'Open the NFC screen on the phone'),
        @($btnUsersRefresh, 'E72C', 'Refresh the user list'),
        @($btnUserAdd, 'E710', 'Add a user'),
        @($btnUserRename, 'E70F', 'Rename this user'),
        @($btnUserSettings, 'E713', 'Open the users screen on the phone'),

        # the ones with a symbol everybody already knows
        @($btnFileCompress, @('F012', 'E7B8'), 'Pack the selection into a .tar.gz on the phone'),
        @($btnFileExtract, @('E8A7', 'E7B8'), 'Unpack an archive on the phone'),
        @($btnFileMoveToPc, @('E7F4', 'E839'), 'Download, check the copy, then delete it from the phone'),
        @($btnFileMoveToPhone, @('E8EA', 'E1C9', 'E975'), 'Upload, check it arrived, then delete the PC copy'),
        @($btnUserRemove, @('E738', 'E108'), 'Delete this user and everything in it'),
        @($btnWifiOnTab, @('E701'), 'Turn Wi-Fi on'),
        @($btnWifiOffTab, @('EB5E', 'E904'), 'Turn Wi-Fi off'),
        @($btnKeyRecents, @('E7C4', 'E8F9'), 'Recent apps'),
        @($btnKeyVolUp, @('E995', 'E767'), 'Volume up'),
        @($btnKeyVolDown, @('E993', 'E767'), 'Volume down'),

        # device tools
        @($btnScreenshot, 'E114', 'Save a screenshot straight to a file'),
        @($btnTetherSettings, 'E713', 'Open the tethering screen on the phone'),
        @($btnHotspotSettings, 'E713', 'Open the hotspot screen on the phone'),
        @($btnDevOpen, 'E713', 'Open developer options on the phone')
    )

    # On and Off are the most repeated words in the window; a tick and a cross
    # say the same thing in a third of the space
    foreach ($pair in @(
            @($btnRotationOn, $btnRotationOff), @($btnLocationOn, $btnLocationOff),
            @($btnBtOn, $btnBtOff), @($btnWifiOn, $btnWifiOff),
            @($btnSaverOn, $btnSaverOff), @($btnRingVibeOn, $btnRingVibeOff),
            @($btnHapticsOn, $btnHapticsOff), @($btnTapsOn, $btnTapsOff),
            @($btnAwakeOn, $btnAwakeOff), @($btnDevOn, $btnDevOff))) {
        $null = Set-IconButton -Button $pair[0] -Code @('E73E', 'E10B', 'E8FB') -Width 34 -Hint 'Turn it on'
        $null = Set-IconButton -Button $pair[1] -Code @('E711', 'E10A') -Width 34 -Hint 'Turn it off'
    }

    # the word buttons that sit in a shared row size themselves to their words
    foreach ($button in @($btnAppNewDisplay, $btnAppStop, $btnAppUninstall, $btnAppInstall, $btnAppExport,
            $btnContactEndCall, $btnContactExport, $btnSmsSend, $btnSmsExport,
            $btnRunningStop, $btnRunningKill, $btnRunningKillAll, $btnRunningExport,
            $btnFileOpenPhone, $btnFileSelectAll, $btnFileSelectNone, $btnFileSelectInvert,
            $btnFileLocalBrowse, $btnFileGo, $btnFileRecent,
            $btnWifiScan, $btnWifiSaved, $btnWifiConnect, $btnWifiForget,
            $btnWifiStatus, $btnBtOnTab, $btnBtOffTab, $btnUserSwitch,
            $btnUserSwitcherOn, $btnUserSwitcherOff)) {
        Set-TextWidth -Button $button
    }
}


# --- separators -------------------------------------------------------------
# A row of a dozen buttons reads as a wall. Thin rules break it into groups of
# things that belong together, so the eye finds the right one without reading.

function Set-GroupedRow {
    <#
        Places groups of buttons left to right with a rule between them.
        $Groups is a list of button lists; $Rules is the list of separator
        panels, one fewer than the groups.
    #>
    param($Groups, $Rules, [int]$Left, [int]$Top, [int]$Gap = 4, [int]$GroupGap = 12)

    $x = $Left
    for ($i = 0; $i -lt $Groups.Count; $i++) {
        foreach ($button in $Groups[$i]) {
            $button.SetBounds($x, $Top, $button.Width, 28)
            $x += $button.Width + $Gap
        }
        if ($i -lt ($Groups.Count - 1)) {
            $x += $GroupGap - $Gap
            $Rules[$i].SetBounds($x, ($Top + 3), 1, 22)
            $x += 1 + $GroupGap
        }
    }
    return $x
}

function Invoke-ButtonClick {
    # PerformClick is dropped when the button's tab is not the one on screen
    # (the control is not created yet), so raise Click directly
    param($Button)

    $method = [System.Windows.Forms.Control].GetMethod('OnClick',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $box = [object[]]::new(1)
    $box[0] = [System.EventArgs]::Empty
    $null = $method.Invoke($Button, $box)
}

function Add-ListContextMenu {
    # the same actions as the buttons under each list, on the right mouse button
    param($List, $Buttons)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($button in $Buttons) {
        if ($null -eq $button) {
            $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            continue
        }
        $entry = $menu.Items.Add($button.Text.Replace('...', ''))
        $entry.Tag = $button
        $entry.Add_Click({
            param($sender, $eventArgs)
            Invoke-ButtonClick -Button $sender.Tag
        })
    }

    $menu.Add_Opening({
        param($sender, $eventArgs)
        foreach ($entry in $sender.Items) {
            if ($entry.Tag) { $entry.Enabled = $entry.Tag.Enabled }
        }
    })

    # right-clicking a row that is not selected should pick it first
    $List.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $sender.HitTest($eventArgs.X, $eventArgs.Y)
        if ($hit.Item -and -not $hit.Item.Selected) {
            $sender.SelectedItems.Clear()
            $hit.Item.Selected = $true
        }
    })

    $List.ContextMenuStrip = $menu
    return $menu
}

function Get-PageRefreshButton {
    # what F5 presses: the button that reads the page on screen again, and the
    # device list where a page has nothing of its own to read
    if ($tabs.SelectedTab -eq $tabDevice) { return $btnDeviceRefresh }
    if ($tabs.SelectedTab -eq $tabApps) { return $btnAppsRefresh }
    if ($tabs.SelectedTab -eq $tabContacts) { return $btnContactsRefresh }
    if ($tabs.SelectedTab -eq $tabSms) { return $btnSmsRefresh }
    if ($tabs.SelectedTab -eq $tabFiles) { return $btnFileGo }
    if ($tabs.SelectedTab -eq $tabRunning) { return $btnRunningRefresh }
    if ($tabs.SelectedTab -eq $tabUsers) { return $btnUsersRefresh }
    if (Test-PageShown -Page $tabWifi) { return $btnWifiSaved }
    if (Test-PageShown -Page $tabBt) { return $btnBtRefresh }
    if (Test-PageShown -Page $tabNfc) { return $btnNfcRefresh }
    if (Test-PageShown -Page $tabTools) { return $btnDnsRead }
    if (Test-PageShown -Page $tabRoot) { return $btnRootCheck }
    return $btnRefresh
}

function Set-TabOrder {
    <#
        Tab moved between controls in the order they happened to be created -
        which, on a window built by hand, is the order someone wrote the code,
        not the order anyone reads. This walks a page and numbers its controls
        the way they sit: down the page, and left to right within a row.

        Rows are found by rounding the top edge: controls within 12 px of each
        other are one row, so a row of buttons is walked across, not down.
    #>
    param($Container, [int]$Start = 0)

    $index = $Start
    $children = @($Container.Controls | Where-Object { "$($_.Tag)" -ne 'listhint' })
    foreach ($child in ($children | Sort-Object @{ Expression = { [int]([Math]::Round($_.Top / 12)) } }, @{ Expression = { $_.Left } })) {
        $child.TabIndex = $index
        $index++
        if ($child.Controls.Count -gt 0) { $index = Set-TabOrder -Container $child -Start $index }
    }
    return $index
}

function Set-PageEnterKey {
    <#
        Enter on a page does that page's reading action - refresh the list, go
        to the folder. Only reads: Enter is pressed by accident often enough
        that it must never start, install, delete or send anything.
    #>
    $page = $tabs.SelectedTab
    $button = $null
    if ($page -eq $tabDevice) { $button = $btnDeviceRefresh }
    elseif ($page -eq $tabApps) { $button = $btnAppsRefresh }
    elseif ($page -eq $tabContacts) { $button = $btnContactsRefresh }
    elseif ($page -eq $tabSms) { $button = $btnSmsRefresh }
    elseif ($page -eq $tabFiles) { $button = $btnFileGo }
    elseif ($page -eq $tabRunning) { $button = $btnRunningRefresh }
    elseif ($page -eq $tabUsers) { $button = $btnUsersRefresh }
    elseif ($page -eq $tabRadios) {
        if ($tabsRadios.SelectedTab -eq $tabWifi) { $button = $btnWifiScan }
        elseif ($tabsRadios.SelectedTab -eq $tabBt) { $button = $btnBtRefresh }
        elseif ($tabsRadios.SelectedTab -eq $tabNfc) { $button = $btnNfcRefresh }
    }
    elseif ($page -eq $tabAdvanced -and $tabsAdvanced.SelectedTab -eq $tabBackup) { $button = $btnBackupListRefresh }
    $form.AcceptButton = $button
}

function Invoke-WindowKey {
    # keys that work wherever the focus is; true when the key was used
    param([System.Windows.Forms.Keys]$KeyData)

    $keys = [System.Windows.Forms.Keys]
    if ($KeyData -eq $keys::F5) {
        # never on top of a call still running: F5 held down would stack them
        $button = Get-PageRefreshButton
        if ($script:busy -eq 0 -and $button -and $button.Enabled) { Invoke-ButtonClick -Button $button }
        return $true
    }
    $code = $KeyData -band $keys::KeyCode
    $modifiers = $KeyData -band $keys::Modifiers
    if ($modifiers -eq $keys::Control -and $code -ge $keys::D1 -and $code -le $keys::D9) {
        $index = [int]$code - [int]$keys::D1
        if ($index -lt $tabs.TabCount) { $tabs.SelectedIndex = $index }
        return $true
    }
    # Ctrl+0 is the tenth tab, and Ctrl+Shift+1..9 carries on from there, so
    # the last tabs are reachable too - they had no key of their own at all
    if ($modifiers -eq $keys::Control -and $code -eq $keys::D0) {
        if ($tabs.TabCount -ge 10) { $tabs.SelectedIndex = 9 }
        return $true
    }
    if ($modifiers -eq ($keys::Control -bor $keys::Shift) -and $code -ge $keys::D1 -and $code -le $keys::D9) {
        $index = 10 + [int]$code - [int]$keys::D1
        if ($index -lt $tabs.TabCount) { $tabs.SelectedIndex = $index }
        return $true
    }
    if ($KeyData -eq ($keys::Control -bor $keys::L)) {
        Clear-Log
        return $true
    }
    return $false
}

function Test-PageShown {
    # true when a page is the one on screen, nested tab controls included
    param($Page)

    $parent = $Page.Parent
    if (-not $parent -or $parent.SelectedTab -ne $Page) { return $false }
    if ($parent -eq $tabs) { return $true }
    return (Test-PageShown -Page $parent.Parent)
}

function Start-QuickCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $txtPhoneNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }

    $answer = [System.Windows.Forms.MessageBox]::Show("Call $number from $serial ?", 'Call', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$number")
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text.Trim() $colorBad; return }
    Write-Log "Calling $number from $serial." $colorGood
    Wait-Pumped -Milliseconds 1500
    Update-Capture -Quiet
}

function Open-QuickDialer {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $txtPhoneNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }

    $null = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.DIAL', '-d', "tel:$number")
    Write-Log "Put $number in the dialer without calling." $colorInfo
    Wait-Pumped -Milliseconds 1200
    Update-Capture -Quiet
}

function Send-QuickSms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $txtPhoneNumber.Text.Trim()
    if (-not $number) { Write-Log 'Type a number first.' $colorWarn; return }

    $body = [Microsoft.VisualBasic.Interaction]::InputBox("Message for $number :", 'Send SMS', '')
    if (-not $body.Trim()) { return }

    $txtSmsTo.Text = $number
    $txtSmsBody.Text = $body
    Send-Sms
}

function Send-Ussd {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $code = $txtPhoneNumber.Text.Trim()
    if (-not $code) { Write-Log 'Type the code first, for example *111#.' $colorWarn; return }
    if ($code -notmatch '^[\d\*\#\+]+$') {
        Write-Log 'A USSD code is digits with * and #, such as *111# or *100*1#.' $colorWarn
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Send $code from $serial ?" + "`r`n`r`n" +
        'The operator answers on the phone screen. Some codes cost money or change your plan.',
        'Send USSD', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # the hash sign has to be percent encoded or the dialer swallows the code
    $encoded = $code.Replace('#', '%23')
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$encoded")
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text.Trim() $colorBad; return }

    Write-Log "Sent $code. Watch the phone screen for the answer." $colorGood
    Wait-Pumped -Milliseconds 3000
    Update-Capture -Quiet
}

function Test-PngFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    # share the file: another handle may still be closing
    foreach ($attempt in 1..5) {
        try {
            $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                $header = New-Object byte[] 8
                $read = $stream.Read($header, 0, 8)
                if ($read -lt 8) { return $false }
                return ($header[0] -eq 0x89 -and $header[1] -eq 0x50 -and $header[2] -eq 0x4E -and $header[3] -eq 0x47)
            } finally {
                $stream.Dispose()
            }
        } catch {
            Wait-Pumped -Milliseconds 150
        }
    }
    return $false
}

function Get-CaptureBytes {
    param([string]$Serial)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial exec-out screencap -p"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return $null }

    $buffer = New-Object System.IO.MemoryStream
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)

    $script:busy++
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $copy.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
            if ($watch.ElapsedMilliseconds -gt 20000) {
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
    if ($bytes.Length -lt 8) { return $null }
    if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $null }
    return $bytes
}

function Show-CaptureBytes {
    param([byte[]]$Bytes, [string]$Serial)

    $stream = New-Object System.IO.MemoryStream(,$Bytes)
    try {
        $loaded = [System.Drawing.Image]::FromStream($stream)
        $bitmap = New-Object System.Drawing.Bitmap($loaded)
        $loaded.Dispose()
    } finally {
        $stream.Dispose()
    }

    if ($script:captureImage) { $script:captureImage.Dispose() }
    $script:captureImage = $bitmap
    $script:captureSerial = $Serial
    $script:captureCount++
    $picScreen.Image = $bitmap
    $lblScreenInfo.Text = "$($bitmap.Width)x$($bitmap.Height)  $Serial  #$($script:captureCount)"
}

function Show-CaptureFile {
    param([string]$Path, [string]$Serial)

    # Load through a memory stream so the PNG file stays unlocked and can be
    # overwritten by the next capture.
    # adb may hold the file for a few more milliseconds after it exits
    $bytes = $null
    foreach ($attempt in 1..5) {
        try { $bytes = [System.IO.File]::ReadAllBytes($Path); break } catch { Wait-Pumped -Milliseconds 150 }
    }
    if ($null -eq $bytes) {
        Write-Log 'Could not read the capture (the file was still busy).' $colorWarn
        return
    }
    $stream = New-Object System.IO.MemoryStream(,$bytes)
    try {
        $loaded = [System.Drawing.Image]::FromStream($stream)
        $bitmap = New-Object System.Drawing.Bitmap($loaded)
        $loaded.Dispose()
    } finally {
        $stream.Dispose()
    }

    if ($script:captureImage) { $script:captureImage.Dispose() }
    $script:captureImage = $bitmap
    $script:captureSerial = $Serial
    $picScreen.Image = $bitmap
    $lblScreenInfo.Text = "$($bitmap.Width)x$($bitmap.Height)  $Serial"
}

function Update-Capture {
    param([switch]$Quiet)

    # the pumped message loop lets a click (or a tap, or the timer) ask for a
    # second capture while one is still running: only one may own the file
    if ($script:capturing) { return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $script:capturing = $true
    try {
        Get-CaptureInto -Serial $serial -Quiet:$Quiet
    } catch {
        Write-Log ("Capture failed: " + $_.Exception.Message) $colorBad
    } finally {
        $script:capturing = $false
    }
}

function Get-CaptureInto {
    param([string]$Serial, [switch]$Quiet)

    $bytes = Get-CaptureBytes -Serial $Serial
    if ($bytes) {
        Show-CaptureBytes -Bytes $bytes -Serial $Serial
        if (-not $Quiet) { Write-Log "Captured the screen of $Serial." $colorInfo }
        return
    }

    # some ROMs refuse exec-out: fall back to a file on the phone and pull it
    if (-not $Quiet) { Write-Log 'exec-out gave no PNG, falling back to screencap + pull ...' $colorWarn }
    $file = Join-Path $env:TEMP "androiddc-$PID.pull.png"
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue

    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('screencap', '-p', '/sdcard/_gui_shot.png')
    $null = Invoke-Adb -CommandArguments @('-s', $Serial, 'pull', '/sdcard/_gui_shot.png', $file)
    $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('rm', '/sdcard/_gui_shot.png')

    if (Test-PngFile -Path $file) {
        Show-CaptureFile -Path $file -Serial $Serial
        if (-not $Quiet) { Write-Log "Captured the screen of $Serial." $colorInfo }
    } elseif (-not $Quiet) {
        Write-Log 'Screen capture failed.' $colorBad
    }
}

function Convert-ToDevicePoint {
    param([int]$X, [int]$Y)

    if (-not $script:captureImage) { return $null }

    $imageWidth = $script:captureImage.Width
    $imageHeight = $script:captureImage.Height
    $boxWidth = $picScreen.ClientSize.Width
    $boxHeight = $picScreen.ClientSize.Height

    # PictureBox 'Zoom' keeps the aspect ratio and centres the image.
    $ratio = [Math]::Min($boxWidth / $imageWidth, $boxHeight / $imageHeight)
    $shownWidth = $imageWidth * $ratio
    $shownHeight = $imageHeight * $ratio
    $offsetX = ($boxWidth - $shownWidth) / 2
    $offsetY = ($boxHeight - $shownHeight) / 2

    if ($X -lt $offsetX -or $X -gt ($offsetX + $shownWidth)) { return $null }
    if ($Y -lt $offsetY -or $Y -gt ($offsetY + $shownHeight)) { return $null }

    return [PSCustomObject]@{
        X = [int](($X - $offsetX) / $ratio)
        Y = [int](($Y - $offsetY) / $ratio)
    }
}

function Send-Tap {
    param([int]$X, [int]$Y)

    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$X", "$Y")
    Write-Log "tap $X $Y -> $serial" $colorInfo
    Wait-Pumped -Milliseconds 500
    Update-Capture -Quiet
}

function Send-Swipe {
    param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$Duration = 200)

    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'input', 'swipe', "$X1", "$Y1", "$X2", "$Y2", "$Duration")
    Write-Log "swipe $X1 $Y1 -> $X2 $Y2 (${Duration}ms) on $serial" $colorInfo
    Wait-Pumped -Milliseconds 500
    Update-Capture -Quiet
}

function Send-Key {
    param([int]$KeyCode)

    foreach ($serial in @(Get-SelectedSerials)) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', "$KeyCode")
        Write-Log "keyevent $KeyCode -> $serial" $colorInfo
    }
    Wait-Pumped -Milliseconds 500
    Update-Capture -Quiet
}

function Send-Text {
    $text = $txtSendText.Text
    if ($text.Trim() -eq '') { return }

    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    # 'input text' takes %s for a space; every other character - ' & ( ; -
    # has to reach it untouched by the phone's shell, so it goes as one argument
    $escaped = $text -replace ' ', '%s'
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('input', 'text', $escaped)
    Write-Log "typed on $serial : $text" $colorInfo
    $txtSendText.Clear()
    Wait-Pumped -Milliseconds 400
    Update-Capture -Quiet
}

# --- input methods -----------------------------------------------------------

function Get-ImeId {
    # The combo shows "<id>   (default, enabled)" for each entry.
    $value = $cmbIme.Text.Trim()
    if (-not $value) { return $null }
    return ($value -split '\s+')[0]
}

function Update-ImeList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $all = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'list', '-a', '-s')).Text
    $enabled = (Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'list', '-s')).Text
    $default = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'settings', 'get', 'secure', 'default_input_method')).Text.Trim()

    $cmbIme.Items.Clear()
    foreach ($line in ($all -split "`r?`n")) {
        $id = $line.Trim()
        if (-not $id -or $id -notmatch '/') { continue }

        $tags = @()
        if ($id -eq $default) { $tags += 'default' }
        if ($enabled -match [regex]::Escape($id)) { $tags += 'enabled' } else { $tags += 'disabled' }
        $null = $cmbIme.Items.Add("$id   ($($tags -join ', '))")
    }

    if ($cmbIme.Items.Count -eq 0) {
        Write-Log "No input method reported by $serial." $colorWarn
        return
    }

    $cmbIme.SelectedIndex = 0
    foreach ($item in $cmbIme.Items) {
        if ("$item" -like "$default*") { $cmbIme.SelectedItem = $item }
    }
    Write-Log "$($cmbIme.Items.Count) input methods on $serial (default: $default)." $colorInfo
}

function Set-ImeState {
    param([ValidateSet('enable', 'disable')][string]$Action)

    $id = Get-ImeId
    if (-not $id) { Write-Log 'Pick an input method first (press List).' $colorWarn; return }

    foreach ($serial in @(Get-SelectedSerials)) {
        $default = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'settings', 'get', 'secure', 'default_input_method')).Text.Trim()

        if ($Action -eq 'disable' -and $id -eq $default) {
            Write-Log "$id is the active keyboard on $serial - Android may refuse to disable it." $colorWarn
        }

        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', $Action, $id)
        $text = $result.Text.Trim()
        $good = ($result.ExitCode -eq 0 -and $text -notmatch 'Error|Unknown|Exception')
        Write-Log ("$serial : " + $(if ($text) { $text } else { "ime $Action $id" })) `
            $(if ($good) { $colorGood } else { $colorBad })
    }
}

function Set-ImeDefault {
    $id = Get-ImeId
    if (-not $id) { Write-Log 'Pick an input method first (press List).' $colorWarn; return }

    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'set', $id)
        Write-Log ("$serial : " + $(if ($result.Text.Trim()) { $result.Text.Trim() } else { "ime set $id" })) $colorInfo
    }
    Update-ImeList
}

function Reset-ImeList {
    foreach ($serial in @(Get-SelectedSerials)) {
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ime', 'reset')
        Write-Log ("$serial : " + $(if ($result.Text.Trim()) { $result.Text.Trim() } else { 'ime reset' })) $colorGood
    }
    Update-ImeList
}

# --- live shell --------------------------------------------------------------

# A C# helper owns the process: its stdout/stderr callbacks run on threadpool
# threads, where a PowerShell script block would have no runspace.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;

public class LineReader {
    // Reads a program's output into a queue on .NET's own threads. Logcat used
    // Register-ObjectEvent for this instead, and once that subscription had
    // carried a live adb logcat stream, no asynchronous read completed on any
    // adb process started afterwards: the live shell showed nothing, before
    // or after logcat was stopped. The same logcat read by this class leaves
    // them working, and so does the same subscription on 20000 lines from cmd.
    private readonly ConcurrentQueue<string> queue = new ConcurrentQueue<string>();
    private Process proc;

    public ConcurrentQueue<string> Queue { get { return queue; } }
    public Process Process { get { return proc; } }

    public bool Start(string exe, string arguments) {
        var info = new ProcessStartInfo(exe, arguments);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        // adb writes UTF-8; unset, a line is decoded with the console page
        info.StandardOutputEncoding = new System.Text.UTF8Encoding(false);
        info.StandardErrorEncoding = new System.Text.UTF8Encoding(false);

        proc = new Process();
        proc.StartInfo = info;
        proc.OutputDataReceived += (sender, e) => { if (e.Data != null) queue.Enqueue(e.Data); };
        proc.ErrorDataReceived += (sender, e) => { if (e.Data != null) queue.Enqueue("! " + e.Data); };

        if (!proc.Start()) { return false; }
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        return true;
    }
}

public class LiveShell {
    private Process proc;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();

    public bool Start(string exe, string arguments) {
        var info = new ProcessStartInfo(exe, arguments);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        // adb writes UTF-8; unset, a reply is decoded with the console page
        info.StandardOutputEncoding = new System.Text.UTF8Encoding(false);
        info.StandardErrorEncoding = new System.Text.UTF8Encoding(false);

        proc = new Process();
        proc.StartInfo = info;
        proc.OutputDataReceived += (sender, e) => { if (e.Data != null) lines.Enqueue(e.Data); };
        proc.ErrorDataReceived += (sender, e) => { if (e.Data != null) lines.Enqueue(e.Data); };

        if (!proc.Start()) { return false; }
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        return true;
    }

    public void Send(string line) {
        if (proc != null && !proc.HasExited) {
            // .NET Framework writes stdin in the console's input code page, and
            // has no StandardInputEncoding to change that. On an OEM page every
            // Arabic letter became '?', and the phone's shell then expanded
            // "????" as a file pattern: measured, "echo" and four Arabic letters
            // printed four-letter file names instead. adb reads UTF-8, so the
            // bytes go out as UTF-8, with the same line ending as before.
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(line + proc.StandardInput.NewLine);
            proc.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
            proc.StandardInput.BaseStream.Flush();
        }
    }

    public string[] Drain(int max) {
        var result = new List<string>();
        string item;
        while (result.Count < max && lines.TryDequeue(out item)) { result.Add(item); }
        return result.ToArray();
    }

    public bool Running { get { return proc != null && !proc.HasExited; } }

    public void Stop() {
        try {
            if (proc != null && !proc.HasExited) {
                Send("exit");
                if (!proc.WaitForExit(1500)) { proc.Kill(); }
            }
        } catch { }
        proc = null;
    }
}
"@

$script:shell = $null
$script:shellHistory = @()
$script:shellHistoryIndex = 0

function Write-Shell {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro)

    $txtShellOut.SelectionStart = $txtShellOut.TextLength
    $txtShellOut.SelectionLength = 0
    $txtShellOut.SelectionColor = $Color
    $txtShellOut.AppendText($Text + [Environment]::NewLine)
    $txtShellOut.SelectionColor = $txtShellOut.ForeColor
    $txtShellOut.ScrollToCaret()
}


# --- logcat -------------------------------------------------------------------
# adb logcat never ends by itself, so it runs as a real process and its output
# is drained on a timer. Nothing blocks the window, and Stop kills the process.

# WM_SETREDRAW, so a burst of lines is painted once instead of line by line.
# IsWindowEnabled: the device watch waits while a question of this program is
# open - a dialog or message box disables the window. Not Form.CanFocus: that
# also asks IsWindowVisible, which is false for a window started from a hidden
# process, and the watch then never ran.
if (-not ('AndroidDcNative' -as [type])) {
    Add-Type -Namespace '' -Name 'AndroidDcNative' -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool IsWindowEnabled(IntPtr hWnd);
'@
}

$script:logcatProcess = $null
$script:logcatQueue = $null
$script:logcatTimer = $null
$script:logcatDropped = 0
$script:logcatSubs = @()

function Start-Logcat {
    if ($script:logcatProcess -and -not $script:logcatProcess.HasExited) {
        Write-Log 'logcat is already running.' $colorWarn
        return
    }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $level = "$($cmbLogcatLevel.SelectedItem)".Substring(0, 1)

    $script:logcatRaw = New-Object System.Collections.Generic.List[string]

    # LineReader (a C# class, beside LiveShell) reads the stream on .NET's own
    # threads, in UTF-8. It replaced Register-ObjectEvent, which broke every
    # interactive adb process started after it - see the class.
    $reader = New-Object LineReader
    # -v time gives a readable stamp; *:LEVEL is the priority filter
    if (-not $reader.Start($script:adbPath, "-s $serial logcat -v time *:$level")) {
        Write-Log 'adb logcat did not start.' $colorBad
        return
    }
    # the rest of the page reads the queue and the process, as before
    $script:logcatQueue = $reader.Queue
    $script:logcatProcess = $reader.Process
    $script:logcatDropped = 0

    if (-not $script:logcatTimer) {
        $script:logcatTimer = New-Object System.Windows.Forms.Timer
        $script:logcatTimer.Interval = 250
        $script:logcatTimer.Add_Tick({ Update-LogcatView })
    }
    $script:logcatTimer.Start()

    $btnLogcatStart.Enabled = $false
    $btnLogcatStop.Enabled = $true
    $lblLogcatState.Text = "running on $serial at level $level"
    Write-Log "logcat started on $serial (level $level)." $colorGood
}

function Update-LogcatView {
    if (-not $script:logcatQueue) { return }

    $filter = $txtLogcatFilter.Text.Trim()
    $batch = New-Object System.Text.StringBuilder
    $line = ''
    $taken = 0

    # a busy phone can outrun the window; take a slice per tick and say when
    # lines had to be dropped rather than freezing to keep up
    while ($taken -lt 800 -and $script:logcatQueue.TryDequeue([ref]$line)) {
        $taken++

        # every line is kept unfiltered, capped, so the filter can be changed
        # afterwards and still apply to what is already here
        $null = $script:logcatRaw.Add($line)
        if ($script:logcatRaw.Count -gt 6000) { $script:logcatRaw.RemoveRange(0, 2000) }

        # inline rather than Test-TextContains: this runs for every line
        if ($filter -and $line.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $null = $batch.AppendLine($line)
    }
    # 1500 lines every 250 ms is 6000 a second, past anything but a log storm.
    # If even that is outrun, the oldest lines go rather than the window.
    if ($script:logcatQueue.Count -gt 20000) {
        $spare = ''
        while ($script:logcatQueue.Count -gt 10000 -and $script:logcatQueue.TryDequeue([ref]$spare)) {
            $script:logcatDropped++
        }
    }

    if ($batch.Length -gt 0) {
        # Painting is the expensive part, so the control is frozen for the
        # append and thawed once.
        $null = [AndroidDcNative]::SendMessage($txtLogcat.Handle, 0x000B, [IntPtr]::Zero, [IntPtr]::Zero)
        try {
            Remove-LogcatHead
            $txtLogcat.AppendText($batch.ToString())
            if ($chkLogcatFollow.Checked) {
                $txtLogcat.SelectionStart = $txtLogcat.TextLength
                $txtLogcat.ScrollToCaret()
            }
        } finally {
            $null = [AndroidDcNative]::SendMessage($txtLogcat.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero)
            $txtLogcat.Invalidate()
        }
    }

    if ($script:logcatProcess -and $script:logcatProcess.HasExited) {
        Stop-Logcat -Quiet
        $lblLogcatState.Text = 'stopped: adb ended the stream'
        return
    }
    if ($script:logcatDropped -gt 0) {
        $lblLogcatState.Text = "running   |   $($script:logcatDropped) line(s) dropped, the phone is louder than the window"
    }
}



function Remove-LogcatHead {
    <#
        Drops the oldest text once the box gets long.

        Measured on this control, half a megabyte down to a quarter:

            assign Text with the second half      1,722 ms
            Select(0, boundary) + SelectedText='' 55 ms

        Assigning Text rebuilds the whole buffer and is worse than quadratic:
        250k took 2.5 s, 500k took 7.2 s and 960k took 22.6 s. That single
        assignment was the freeze behind a live log.

        This box is a RichTextBox, and a read only RichTextBox ignores an
        assignment to SelectedText without raising anything - the delete
        simply does not happen. A plain TextBox does obey it even when read
        only, which is what made the first measurement look like a win:

            TextBox      ReadOnly=True   1000 -> 600   deleted
            RichTextBox  ReadOnly=True   1000 -> 1000  ignored in silence

        So ReadOnly comes off for the edit and goes straight back.
    #>
    if ($txtLogcat.TextLength -le 400000) { return }

    $cut = $txtLogcat.TextLength - 200000

    # cut on a line boundary, and find it through the control rather than by
    # reading .Text, which would copy the whole buffer and undo the saving
    $line = $txtLogcat.GetLineFromCharIndex($cut)
    $boundary = $txtLogcat.GetFirstCharIndexFromLine($line + 1)
    if ($boundary -le 0) { $boundary = $cut }

    $wasReadOnly = $txtLogcat.ReadOnly
    $txtLogcat.ReadOnly = $false
    try {
        $txtLogcat.Select(0, $boundary)
        $txtLogcat.SelectedText = ''
        $txtLogcat.Select($txtLogcat.TextLength, 0)
    } finally {
        $txtLogcat.ReadOnly = $wasReadOnly
    }
}

function Show-LogcatFiltered {
    # redraw the window from the lines kept in memory, so typing a filter hides
    # what is already on screen too
    if (-not $script:logcatRaw) { return }

    $filter = $txtLogcatFilter.Text.Trim()

    $matching = New-Object System.Collections.Generic.List[string]
    foreach ($line in $script:logcatRaw) {
        if ($filter -and $line.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $null = $matching.Add($line)
    }

    # rebuilding the box is the costly operation, and it grows worse than
    # linearly, so only the newest lines are drawn; the rest stay in the list
    $shown = $matching
    $trimmed = $false
    if ($matching.Count -gt 1200) {
        $shown = $matching.GetRange(($matching.Count - 1200), 1200)
        $trimmed = $true
    }

    $batch = New-Object System.Text.StringBuilder
    foreach ($line in $shown) { $null = $batch.AppendLine($line) }

    $null = [AndroidDcNative]::SendMessage($txtLogcat.Handle, 0x000B, [IntPtr]::Zero, [IntPtr]::Zero)
    try {
        $txtLogcat.Text = $batch.ToString()
        if ($chkLogcatFollow.Checked) {
            $txtLogcat.SelectionStart = $txtLogcat.TextLength
            $txtLogcat.ScrollToCaret()
        }
    } finally {
        $null = [AndroidDcNative]::SendMessage($txtLogcat.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero)
        $txtLogcat.Invalidate()
    }

    if ($filter) {
        $lblLogcatState.Text = "$($matching.Count) of $($script:logcatRaw.Count) kept lines match '$filter'" +
            $(if ($trimmed) { " - showing the newest 1200" } else { '' })
    }
}

function Stop-Logcat {
    param([switch]$Quiet)

    if ($script:logcatTimer) { $script:logcatTimer.Stop() }
    if ($script:logcatProcess) {
        try { if (-not $script:logcatProcess.HasExited) { $script:logcatProcess.Kill() } } catch { }
        try { $script:logcatProcess.Dispose() } catch { }
        $script:logcatProcess = $null
    }
    # only our own subscriptions, never anyone else's
    foreach ($subscription in @($script:logcatSubs)) {
        if ($subscription) { Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue }
    }
    $script:logcatSubs = @()

    $btnLogcatStart.Enabled = $true
    $btnLogcatStop.Enabled = $false
    if (-not $Quiet) {
        $lblLogcatState.Text = 'stopped'
        Write-Log 'logcat stopped.' $colorInfo
    }
}

function Clear-Logcat {
    $txtLogcat.Clear()
    if ($script:logcatRaw) { $script:logcatRaw.Clear() }
    $script:logcatDropped = 0

    # holding Shift also empties the ring buffer on the phone
    if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) {
        $serial = Get-TargetSerial
        if ($serial) {
            $null = Invoke-Adb -CommandArguments @('-s', $serial, 'logcat', '-c')
            Write-Log 'The log buffer on the phone was cleared as well.' $colorInfo
        }
    }
}

function Save-Logcat {
    if (-not $txtLogcat.TextLength) { Write-Log 'Nothing to save yet.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Log file (*.log)|*.log|Text (*.txt)|*.txt'
    $dialog.FileName = 'logcat-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Set-Content -LiteralPath $dialog.FileName -Value $txtLogcat.Text -Encoding UTF8
    Write-Log "Saved $($dialog.FileName)." $colorGood
}

function Start-LiveShell {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Stop-LiveShell -Quiet

    $script:shell = New-Object LiveShell
    if (-not $script:shell.Start($script:adbPath, "-s $serial shell")) {
        Write-Shell 'Could not start adb shell.' $colorBad
        $script:shell = $null
        return
    }

    $lblShellStatus.Text = "connected to $serial"
    $lblShellStatus.ForeColor = [System.Drawing.Color]::ForestGreen
    $btnShellStop.Enabled = $true
    $btnShellStart.Enabled = $false
    Write-Shell "--- adb -s $serial shell ---" $colorStep
    $shellTimer.Start()
    $null = $txtShellIn.Focus()
}

function Stop-LiveShell {
    param([switch]$Quiet)

    $shellTimer.Stop()
    if ($script:shell) {
        $script:shell.Stop()
        $script:shell = $null
    }

    $btnShellStop.Enabled = $false
    $btnShellStart.Enabled = $true
    $lblShellStatus.Text = 'not connected'
    $lblShellStatus.ForeColor = [System.Drawing.Color]::DimGray
    if (-not $Quiet) { Write-Shell '--- session closed ---' $colorWarn }
}

function Send-ShellLine {
    $line = $txtShellIn.Text
    if ($line.Trim() -eq '') { return }

    if (-not $script:shell -or -not $script:shell.Running) {
        Write-Shell 'No live shell - press "Start shell" first.' $colorWarn
        return
    }

    Write-Shell "$ $line" $colorStep
    $script:shell.Send($line)

    $script:shellHistory += $line
    $script:shellHistoryIndex = $script:shellHistory.Count
    $txtShellIn.Clear()
}

# --- settings ----------------------------------------------------------------

function Save-Settings {
    try {
        $folder = Split-Path -Parent $settingsPath
        if (-not (Test-Path -LiteralPath $folder)) {
            $null = New-Item -ItemType Directory -Path $folder -Force
        }

        $place = if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) { $form.Bounds } else { $form.RestoreBounds }
        $data = [ordered]@{
            Dns            = $cmbDns.Text
            Port           = [int]$numPort.Value
            Routes         = $txtRoutes.Text
            WifiOff        = $chkWifi.Checked
            AutoTest       = $chkAutoTest.Checked
            ScrcpyAfter    = $chkScrcpyAfter.Checked
            TetherMetered  = $chkTetherMetered.Checked
            ProxyPort      = [int]$numProxyPort.Value
            MaxSize        = $cmbMaxSize.Text
            Bitrate        = $cmbBitrate.Text
            Fps            = $cmbFps.Text
            Codec          = "$($cmbCodec.SelectedItem)"
            Fullscreen     = $chkFullscreen.Checked
            Borderless     = $chkBorderless.Checked
            OnTop          = $chkOnTop.Checked
            ScreenOff      = $chkScreenOff.Checked
            StayAwake      = $chkStayAwake.Checked
            NoAudio        = $chkNoAudio.Checked
            AudioSource    = "$($cmbAudioSource.SelectedItem)"
            AudioCodec     = "$($cmbAudioCodec.SelectedItem)"
            AudioBitrate   = $cmbAudioBitrate.Text
            AudioDup       = $chkAudioDup.Checked
            AudioBuffer    = $txtAudioBuffer.Text
            RecordFormat   = "$($cmbRecordFormat.SelectedItem)"
            RecordRotate   = "$($cmbRecordOrientation.SelectedItem)"
            TimeLimit      = [int]$numTimeLimit.Value
            Orientation    = "$($cmbOrientation.SelectedItem)"
            CaptureTurn    = "$($cmbCaptureOrientation.SelectedItem)"
            ImePolicy      = "$($cmbImePolicy.SelectedItem)"
            NoDecorations  = $chkNoDecorations.Checked
            KeepContent    = $chkKeepContent.Checked
            PrintFps       = $chkPrintFps.Checked
            ShortcutMod    = "$($cmbShortcutMod.SelectedItem)"
            PreferText     = $chkPreferText.Checked
            ViewOnly       = $chkViewOnly.Checked
            PowerOff       = $chkPowerOff.Checked
            NoScreensaver  = $chkNoScreensaver.Checked
            NewDisplay     = $chkNewDisplay.Checked
            NewDisplaySize = $txtNewDisplay.Text
            StartApp       = $cmbStartApp.Text
            ExtraArgs      = $txtExtraArgs.Text
            Otg            = $chkOtg.Checked
            Keyboard       = "$($cmbKeyboard.SelectedItem)"
            Mouse          = "$($cmbMouse.SelectedItem)"
            Gamepad        = "$($cmbGamepad.SelectedItem)"
            Connect        = $txtConnect.Text
            WindowWidth    = [int]$place.Width
            WindowHeight   = [int]$place.Height
            WindowLeft     = [int]$place.X
            WindowTop      = [int]$place.Y
            WindowMaximized = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
            LogHeight      = [int]$script:logHeight
            LogFolded      = [bool]$script:logFolded
        }

        $data | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch {
        # settings are a convenience: never block the exit on them
    }
}

function Restore-Settings {
    # settings written by the older name are picked up once, then kept here
    if (-not (Test-Path -LiteralPath $settingsPath) -and (Test-Path -LiteralPath $legacySettingsPath)) {
        $folder = Split-Path -Parent $settingsPath
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        Copy-Item -LiteralPath $legacySettingsPath -Destination $settingsPath -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }

    try {
        $data = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } catch {
        return
    }

    function Get-Setting {
        param([string]$Name)
        if ($data.PSObject.Properties.Name -contains $Name) { return $data.$Name }
        return $null
    }

    $value = Get-Setting 'Dns';            if ($value) { $cmbDns.Text = $value }
    $value = Get-Setting 'Port';           if ($value) { $numPort.Value = [int]$value }
    $value = Get-Setting 'Routes';         if ($null -ne $value) { $txtRoutes.Text = $value }
    $value = Get-Setting 'WifiOff';        if ($null -ne $value) { $chkWifi.Checked = [bool]$value }
    $value = Get-Setting 'AutoTest';       if ($null -ne $value) { $chkAutoTest.Checked = [bool]$value }
    $value = Get-Setting 'ScrcpyAfter';    if ($null -ne $value) { $chkScrcpyAfter.Checked = [bool]$value }
    $value = Get-Setting 'TetherMetered';  if ($null -ne $value) { $chkTetherMetered.Checked = [bool]$value }
    $value = Get-Setting 'ProxyPort';      if ($value) { $numProxyPort.Value = [int]$value }
    $value = Get-Setting 'MaxSize';        if ($value) { $cmbMaxSize.Text = $value }
    $value = Get-Setting 'Bitrate';        if ($value) { $cmbBitrate.Text = $value }
    $value = Get-Setting 'Fps';            if ($value) { $cmbFps.Text = $value }
    $value = Get-Setting 'Codec';          if ($value -and $cmbCodec.Items.Contains($value)) { $cmbCodec.SelectedItem = $value }
    $value = Get-Setting 'Fullscreen';     if ($null -ne $value) { $chkFullscreen.Checked = [bool]$value }
    $value = Get-Setting 'Borderless';     if ($null -ne $value) { $chkBorderless.Checked = [bool]$value }
    $value = Get-Setting 'OnTop';          if ($null -ne $value) { $chkOnTop.Checked = [bool]$value }
    $value = Get-Setting 'ScreenOff';      if ($null -ne $value) { $chkScreenOff.Checked = [bool]$value }
    $value = Get-Setting 'StayAwake';      if ($null -ne $value) { $chkStayAwake.Checked = [bool]$value }
    $value = Get-Setting 'NoAudio';        if ($null -ne $value) { $chkNoAudio.Checked = [bool]$value }
    $value = Get-Setting 'AudioSource';    if ($value -and $cmbAudioSource.Items.Contains($value)) { $cmbAudioSource.SelectedItem = $value }
    $value = Get-Setting 'AudioCodec';     if ($value -and $cmbAudioCodec.Items.Contains($value)) { $cmbAudioCodec.SelectedItem = $value }
    $value = Get-Setting 'AudioBitrate';   if ($value) { $cmbAudioBitrate.Text = $value }
    $value = Get-Setting 'AudioDup';       if ($null -ne $value) { $chkAudioDup.Checked = [bool]$value }
    $value = Get-Setting 'AudioBuffer';    if ($null -ne $value) { $txtAudioBuffer.Text = $value }
    $value = Get-Setting 'RecordFormat';   if ($value) { $cmbRecordFormat.SelectedItem = $value }
    $value = Get-Setting 'RecordRotate';   if ($value) { $cmbRecordOrientation.SelectedItem = $value }
    $value = Get-Setting 'TimeLimit';      if ($null -ne $value) { try { $numTimeLimit.Value = [int]$value } catch { } }
    $value = Get-Setting 'Orientation';    if ($value) { $cmbOrientation.SelectedItem = $value }
    $value = Get-Setting 'CaptureTurn';    if ($value) { $cmbCaptureOrientation.SelectedItem = $value }
    $value = Get-Setting 'ImePolicy';      if ($value) { $cmbImePolicy.SelectedItem = $value }
    $value = Get-Setting 'NoDecorations';  if ($null -ne $value) { $chkNoDecorations.Checked = [bool]$value }
    $value = Get-Setting 'KeepContent';    if ($null -ne $value) { $chkKeepContent.Checked = [bool]$value }
    $value = Get-Setting 'PrintFps';       if ($null -ne $value) { $chkPrintFps.Checked = [bool]$value }
    $value = Get-Setting 'ShortcutMod';    if ($value) { $cmbShortcutMod.SelectedItem = $value }
    $value = Get-Setting 'PreferText';     if ($null -ne $value) { $chkPreferText.Checked = [bool]$value }
    $value = Get-Setting 'ViewOnly';       if ($null -ne $value) { $chkViewOnly.Checked = [bool]$value }
    $value = Get-Setting 'PowerOff';       if ($null -ne $value) { $chkPowerOff.Checked = [bool]$value }
    $value = Get-Setting 'NoScreensaver';  if ($null -ne $value) { $chkNoScreensaver.Checked = [bool]$value }
    $value = Get-Setting 'NewDisplay';     if ($null -ne $value) { $chkNewDisplay.Checked = [bool]$value }
    $value = Get-Setting 'NewDisplaySize'; if ($value) { $txtNewDisplay.Text = $value }
    $value = Get-Setting 'StartApp';       if ($null -ne $value) { $cmbStartApp.Text = $value }
    $value = Get-Setting 'ExtraArgs';      if ($null -ne $value) { $txtExtraArgs.Text = $value }
    $value = Get-Setting 'Otg';            if ($null -ne $value) { $chkOtg.Checked = [bool]$value }
    $value = Get-Setting 'Keyboard';       if ($value -and $cmbKeyboard.Items.Contains($value)) { $cmbKeyboard.SelectedItem = $value }
    $value = Get-Setting 'Mouse';          if ($value -and $cmbMouse.Items.Contains($value)) { $cmbMouse.SelectedItem = $value }
    $value = Get-Setting 'Gamepad';        if ($value -and $cmbGamepad.Items.Contains($value)) { $cmbGamepad.SelectedItem = $value }
    $value = Get-Setting 'Connect';        if ($null -ne $value) { $txtConnect.Text = $value }
    $value = Get-Setting 'LogHeight';      if ($value) { try { $script:logHeight = [int]$value } catch { } }
    $value = Get-Setting 'LogFolded';      if ($null -ne $value) { $script:logFolded = [bool]$value }

    # The window opens where it was left, at the size it was left. A saved place
    # is only used while it is still on a screen this PC has: a window restored
    # onto a monitor that has since been unplugged cannot be reached, and
    # dragging it back is not something a person should have to know how to do.
    $width = Get-Setting 'WindowWidth'
    $height = Get-Setting 'WindowHeight'
    $left = Get-Setting 'WindowLeft'
    $top = Get-Setting 'WindowTop'
    if ($null -ne $width -and $null -ne $height -and $null -ne $left -and $null -ne $top) {
        try {
            $wanted = New-Object System.Drawing.Rectangle ([int]$left), ([int]$top), ([int]$width), ([int]$height)
            if ($wanted.Width -ge $form.MinimumSize.Width -and $wanted.Height -ge $form.MinimumSize.Height) {
                $reachable = $false
                foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
                    # enough of the window must land on a screen to be grabbed
                    $shared = [System.Drawing.Rectangle]::Intersect($screen.WorkingArea, $wanted)
                    if ($shared.Width -ge 200 -and $shared.Height -ge 100) { $reachable = $true; break }
                }
                if ($reachable) {
                    $form.StartPosition = 'Manual'
                    $form.Bounds = $wanted
                }
            }
        } catch { }
    }
    $value = Get-Setting 'WindowMaximized'
    if ($null -ne $value -and [bool]$value) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized }
}

# --- timer: pump the relay output and watch for an unexpected exit ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    $out = Read-NewOutput -Path $script:outFile -Offset ([ref]$script:outOffset)
    if ($out) { Write-Log $out $colorInfo }

    $err = Read-NewOutput -Path $script:errFile -Offset ([ref]$script:errOffset)
    if ($err) { Write-Log $err $colorWarn }

    if ($script:relayProcess -and $script:relayProcess.HasExited) {
        # ExitCode is only readable once the process object has been fully waited on.
        $null = $script:relayProcess.WaitForExit(1000)
        $code = $null
        try { $code = $script:relayProcess.ExitCode } catch { }
        $codeText = if ($null -eq $code) { 'unknown' } else { "$code" }
        Write-Log "gnirehtet exited (code $codeText)." $(if ($code -eq 0) { $colorWarn } else { $colorBad })
        Stop-Sharing
    }
})

$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 450
$statusTimer.Add_Tick({
    if ($script:busy -gt 0) { return }
    $statusTimer.Stop()
    # picking another phone refreshes its DNS line too
    if (Test-PageShown -Page $tabTools) { $null = Show-DnsState -Quiet }
    # and the root page's marks, which belong to one phone: checked again if the
    # page is on screen, otherwise cleared, so they are never shown later as the
    # answer of a phone that was not asked.
    # Only a different phone counts - and "nothing selected" is not one.
    # Update-DeviceList empties the list, asks adb about every phone, and only
    # then selects the same one again; this timer keeps firing in between, and
    # a tick that saw the empty list used to clear the marks, so the same phone
    # came back as "new" and was read again after every refresh.
    $selected = Get-SelectedSerial
    if ($selected -and $selected -ne $script:rootCheckedSerial) {
        if (Test-PageShown -Page $tabRoot) { Update-RootAvailability } else { Reset-RootAvailability }
    }
    # the toggle marks belong to one phone as well
    if ($selected -and $selected -ne $script:toggleSerial) {
        if (Test-PageShown -Page $tabDevice) { Show-ToggleStates -Quiet }
        else { Set-ToggleMarks $null; $script:toggleSerial = $null }
    }
    Update-DeviceStatus
})

# --- timer: the busy strip under the pages -----------------------------------
$logFindTimer = New-Object System.Windows.Forms.Timer
$logFindTimer.Interval = 250
$logFindTimer.Add_Tick({
    $logFindTimer.Stop()
    Update-LogView
})

# the same short pause for the backup's find box: a backup can hold tens of
# thousands of files, and each letter would walk them all
$backupFindTimer = New-Object System.Windows.Forms.Timer
$backupFindTimer.Interval = 250
$backupFindTimer.Add_Tick({
    $backupFindTimer.Stop()
    Update-BackupInside
})

$backupAppFindTimer = New-Object System.Windows.Forms.Timer
$backupAppFindTimer.Interval = 250
$backupAppFindTimer.Add_Tick({
    $backupAppFindTimer.Stop()
    Show-BackupApps
})

$busyTimer = New-Object System.Windows.Forms.Timer
$busyTimer.Interval = 200
$busyTimer.Add_Tick({
    Update-BusyIndicator
    Update-ListHints
})

# --- timer: a phone plugged in or pulled out ---------------------------------
# The list only changed when Refresh was pressed. adb devices alone is cheap;
# the list is read in full only when what it reports has changed. Not while a
# question of this program is waiting (a dialog or message box disables the
# window), and not before the list has been read once at startup. Minimized or
# behind other windows it keeps watching: that is when a phone's rule is most
# useful (Advanced > Automation).
$deviceWatchTimer = New-Object System.Windows.Forms.Timer
$deviceWatchTimer.Interval = 2500
$deviceWatchTimer.Add_Tick({
    if ($script:busy -gt 0 -or -not $script:devicesReadOnce -or $script:logDrag) { return }
    if (-not [AndroidDcNative]::IsWindowEnabled($form.Handle)) { return }
    $deviceWatchTimer.Stop()
    try {
        if (Test-DeviceListChanged) {
            Write-Log 'The attached devices changed; reading the list again.' $colorStep
            Update-DeviceList
        }
        Invoke-AutomationQueue -Enter { param($Serial) Enter-AutomationDevice -Serial $Serial } `
            -Leave { param($State) Exit-AutomationDevice -State $State }
    } finally {
        $deviceWatchTimer.Start()
    }
})

$runningTimer = New-Object System.Windows.Forms.Timer
$runningTimer.Interval = 5000
$runningTimer.Add_Tick({
    if ($script:busy -gt 0) { return }
    $runningTimer.Stop()
    try { Update-RunningList } finally { if ($chkRunningAuto.Checked) { $runningTimer.Start() } }
})

$screenTimer = New-Object System.Windows.Forms.Timer
$screenTimer.Interval = 2000
$screenTimer.Add_Tick({
    # a capture takes over a second: never start another one on top of it
    if ($script:busy -gt 0) { return }
    $screenTimer.Stop()
    try { Update-Capture -Quiet } finally { if ($chkAutoShot.Checked) { $screenTimer.Start() } }
})

$shellTimer = New-Object System.Windows.Forms.Timer
$shellTimer.Interval = 150
$shellTimer.Add_Tick({
    if (-not $script:shell) { $shellTimer.Stop(); return }

    foreach ($line in $script:shell.Drain(400)) { Write-Shell $line }

    if (-not $script:shell.Running) {
        Write-Shell '--- the device closed the shell ---' $colorWarn
        Stop-LiveShell -Quiet
    }
})

# --- events ------------------------------------------------------------------
$btnRefresh.Add_Click({ Update-DeviceList })
$btnInfo.Add_Click({ Show-DeviceInfo })
$btnStart.Add_Click({ Start-Sharing })
$btnStop.Add_Click({ Stop-Sharing })
$btnTest.Add_Click({ Test-Connectivity })
$btnClear.Add_Click({ Clear-Log })
# typed into, the box shows only the lines that hold it - after a short pause,
# so a word typed letter by letter does not rebuild the box five times
$txtLogFind.Add_TextChanged({ $logFindTimer.Stop(); $logFindTimer.Start() })
$chkAll.Add_CheckedChanged({ $lstDevices.Enabled = -not $chkAll.Checked })
$lstDevices.Add_DoubleClick({ Show-DeviceTab })
$btnDeviceRefresh.Add_Click({ Show-DeviceTab })
$btnDeviceCopy.Add_Click({
    if ($txtDeviceInfo.Text.Trim()) {
        [System.Windows.Forms.Clipboard]::SetText($txtDeviceInfo.Text)
        Write-Log 'Device details copied to the clipboard.' $colorInfo
    }
})
$btnListen.Add_Click({ Start-AudioListen })
$btnListenStop.Add_Click({ Stop-AudioListen })
$btnRecordAudio.Add_Click({ Start-AudioListen -ToFile })
$lstDevices.Add_SelectedIndexChanged({
    $txtDnsState.Text = ''
    $lblDeviceStatus.Text = 'reading ...'
    $statusTimer.Stop()
    $statusTimer.Start()
    # another phone means other answers to "is this app on it": the apps in an
    # opened backup are read against the phone now picked
    Update-BackupAppsIfShown
})

$btnInstallClient.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log "Installing the gnirehtet client on $serial ..." $colorStep
    Write-Log (Invoke-Gnirehtet -CommandArguments @('install', $serial)).Text $colorInfo
    Update-DeviceList
})

$btnUninstallClient.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-Gnirehtet -CommandArguments @('uninstall', $serial)).Text $colorInfo
    Update-DeviceList
})

$btnSaveLog.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Log file (*.log)|*.log|Text file (*.txt)|*.txt'
    $dialog.FileName = 'androiddc.log'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Content -LiteralPath $dialog.FileName -Value $txtLog.Text -Encoding UTF8
        Write-Log "Log saved to $($dialog.FileName)" $colorGood
    }
})

$btnTetherOn.Add_Click({ Enable-UsbTethering })
$btnTetherOff.Add_Click({ Disable-UsbTethering })
$btnTetherSettings.Add_Click({ Open-TetherSettings })
$btnAdapters.Add_Click({ $null = Show-TetherAdapters })
$btnProxyOn.Add_Click({ Start-PhoneProxy })
$btnProxyOff.Add_Click({ Stop-PhoneProxy })
$btnProxyTest.Add_Click({ $null = Test-PhoneProxy -Port ([int]$numProxyPort.Value) })

$btnScrcpy.Add_Click({ Start-Scrcpy })
$btnScrcpyShare.Add_Click({
    if (-not $script:relayProcess) { Start-Sharing }
    Start-Scrcpy
})
$btnOtg.Add_Click({
    $chkOtg.Checked = $true
    Start-Scrcpy
})
$btnKeyboardLayout.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.HARD_KEYBOARD_SETTINGS')).Text $colorInfo
    Write-Log 'Set the physical keyboard layout there (needed once for uhid/aoa).' $colorWarn
})
$btnScrcpyClose.Add_Click({ Close-Scrcpy })
$btnListDisplays.Add_Click({ Show-ScrcpyDisplays })
$btnShowCommand.Add_Click({
    $serial = Get-SelectedSerial
    Write-Log ('scrcpy ' + ((Get-ScrcpyArguments -Serial $serial) -join ' ')) $colorStep
})
$btnBrowseRecord.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'MP4 (*.mp4)|*.mp4|Matroska (*.mkv)|*.mkv'
    $dialog.FileName = 'scrcpy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtRecord.Text = $dialog.FileName
        $chkRecord.Checked = $true
    }
})

$btnDnsRead.Add_Click({ $null = Show-DnsState })
$btnDnsAdGuard.Add_Click({
    $cmbDnsMode.SelectedIndex = 2          # custom hostname
    $txtDnsHost.Text = 'dns.adguard.com'
    $txtDnsHost.Enabled = $true
    Write-Log 'AdGuard selected - press Apply to set it on the phone.' $colorInfo
})
$btnDnsApply.Add_Click({ Set-DnsMode })
$cmbDnsMode.Add_SelectedIndexChanged({
    $txtDnsHost.Enabled = ("$($cmbDnsMode.SelectedItem)" -like 'custom*')
})

$btnHotspotOn.Add_Click({ Set-Hotspot -On $true })
$btnHotspotOff.Add_Click({ Set-Hotspot -On $false })
$btnHotspotState.Add_Click({ $null = Show-HotspotState })
$btnHotspotInfo.Add_Click({ Show-HotspotCredentials })
$btnUsbTetherOn.Add_Click({ Set-UsbTethering -On $true })
$btnUsbTetherOff.Add_Click({ Set-UsbTethering -On $false })
$btnHotspotSettings.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    Write-Log (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.TETHER_SETTINGS')).Text $colorInfo
    Wait-Pumped -Milliseconds 1200
    Update-Capture -Quiet
})

$btnCameraList.Add_Click({ Update-CameraList })
$btnListEncoders.Add_Click({ Update-EncoderList })
$btnAudioEncoders.Add_Click({ Update-EncoderList })
$cmbStartApp.Add_DropDown({ Update-StartAppChoices })
$cmbAudioCodec.Add_SelectedIndexChanged({ Update-AudioEncoderChoices })
$btnListCameraSizes.Add_Click({ Update-CameraSizeList })
$btnCameraStart.Add_Click({ Start-Camera })
$btnCameraFront.Add_Click({ Start-Camera -Facing 'front' })
$btnCameraBack.Add_Click({ Start-Camera -Facing 'back' })
$btnCameraStop.Add_Click({ Stop-Camera })
$btnCameraCommand.Add_Click({
    $serial = Get-SelectedSerial
    Write-Log ('scrcpy ' + ((Get-CameraArguments -Serial $serial) -join ' ')) $colorStep
})
$btnCameraBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'MP4 (*.mp4)|*.mp4|Matroska (*.mkv)|*.mkv'
    $dialog.FileName = 'camera-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtCameraRecord.Text = $dialog.FileName
        $chkCameraRecord.Checked = $true
    }
})

$btnFileGo.Add_Click({ Update-FileList })
$btnFileUp.Add_Click({ Set-FileParent })
$btnFileDownload.Add_Click({ Save-DeviceFiles })
$btnFileUpload.Add_Click({ Send-DeviceFiles })
$btnFileNewDir.Add_Click({ New-DeviceDirectory })
$btnFileRename.Add_Click({ Rename-DeviceFile })
$btnFileDelete.Add_Click({ Remove-DeviceFiles })
$btnFileOpenPhone.Add_Click({ Open-FileOnPhone })
$btnFileMoveToPc.Add_Click({ Move-FilesToPc })
$btnFileMoveToPhone.Add_Click({ Move-FilesToPhone })
$btnFileCopyPath.Add_Click({
    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something first.' $colorWarn; return }
    [System.Windows.Forms.Clipboard]::SetText((($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine))
    Write-Log "Copied $($rows.Count) path(s)." $colorInfo
})
$btnFileLocalBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $txtFileLocal.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtFileLocal.Text = $dialog.SelectedPath }
})
$btnFileOpenLocal.Add_Click({
    if (Test-Path -LiteralPath $txtFileLocal.Text) { Start-Process explorer.exe $txtFileLocal.Text }
})
$btnFileSearch.Add_Click({ Search-DeviceFiles })
$btnFileRecent.Add_Click({ Show-RecentFiles })
$btnFileSearchClear.Add_Click({
    $txtFileSearch.Clear()
    Update-FileList
})
$txtFileSearch.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Search-DeviceFiles }
})
$txtFileSearch.Add_TextChanged({
    # instant narrowing of what is already listed
    if (-not $script:fileSearchResults) { Show-FileRows }
})
$chkFileHidden.Add_CheckedChanged({ Update-FileList })
$chkFileFoldersFirst.Add_CheckedChanged({
    $script:fileFoldersFirst = $chkFileFoldersFirst.Checked
    Show-FileRows
})
$lstFiles.Add_ColumnClick({
    param($sender, $eventArgs)
    if ($script:fileSortColumn -eq $eventArgs.Column) {
        $script:fileSortDescending = -not $script:fileSortDescending
    } else {
        $script:fileSortColumn = $eventArgs.Column
        # names read best A-Z, sizes and dates biggest/newest first
        $script:fileSortDescending = ($eventArgs.Column -eq 1 -or $eventArgs.Column -eq 2)
    }
    Show-FileRows
})
$lstFiles.Add_DoubleClick({ Open-FileEntry })
$btnFileCancel.Add_Click({
    $script:transferCancelled = $true
    $btnFileCancel.Enabled = $false
    Write-Log 'Stopping the transfer ...' $colorWarn
})
$btnFileCompress.Add_Click({ Compress-DeviceFiles })
$btnFileExtract.Add_Click({ Expand-DeviceArchive })
$btnFilePreview.Add_Click({ Show-DeviceFilePreview })
$btnFileSelectAll.Add_Click({ Set-FileSelection -Mode all })
$btnFileSelectNone.Add_Click({ Set-FileSelection -Mode none })
$btnFileSelectInvert.Add_Click({ Set-FileSelection -Mode invert })
$lstFiles.Add_KeyDown({
    param($sender, $eventArgs)
    # a plain ListView does not know Ctrl+A, so do it here
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq 'A') {
        $eventArgs.SuppressKeyPress = $true
        Set-FileSelection -Mode all
    } elseif ($eventArgs.KeyCode -eq 'Escape') {
        $eventArgs.SuppressKeyPress = $true
        Set-FileSelection -Mode none
    } elseif ($eventArgs.Alt -and $eventArgs.KeyCode -eq 'Left') {
        $eventArgs.SuppressKeyPress = $true
        Invoke-FileHistory -Direction back
    } elseif ($eventArgs.Alt -and $eventArgs.KeyCode -eq 'Right') {
        $eventArgs.SuppressKeyPress = $true
        Invoke-FileHistory -Direction forward
    } elseif ($eventArgs.KeyCode -eq 'Back') {
        $eventArgs.SuppressKeyPress = $true
        Set-FileParent
    }
})
$lstFiles.Add_MouseUp({
    param($sender, $eventArgs)
    # the two side buttons of the mouse, same as a browser
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton1) {
        Invoke-FileHistory -Direction back
    } elseif ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton2) {
        Invoke-FileHistory -Direction forward
    }
})
$txtFilePath.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Update-FileList }
})
$cmbFileQuick.Add_SelectedIndexChanged({
    if ($cmbFileQuick.SelectedIndex -le 0) { return }
    Update-FileList -Path "$($cmbFileQuick.SelectedItem)"
    $cmbFileQuick.SelectedIndex = 0
})


$btnWifiOnTab.Add_Click({ Set-WifiRadio -On $true })
$btnWifiOffTab.Add_Click({ Set-WifiRadio -On $false })
$btnWifiScan.Add_Click({ Update-WifiList -Scan })
$btnWifiSaved.Add_Click({ Update-WifiList -Saved })
$btnWifiConnect.Add_Click({ Connect-WifiNetwork })
$btnWifiForget.Add_Click({ Remove-WifiNetwork })
$btnWifiStatus.Add_Click({ Show-WifiStatus })
$btnWifiSettings.Add_Click({ Open-DeviceSettingsScreen -Action 'android.settings.WIFI_SETTINGS' })
$chkWifiShowPass.Add_CheckedChanged({
    $txtWifiPass.UseSystemPasswordChar = -not $chkWifiShowPass.Checked
})
$lstWifi.Add_DoubleClick({ Connect-WifiNetwork })

$btnBtOnTab.Add_Click({ Set-BluetoothRadio -On $true })
$btnBtOffTab.Add_Click({ Set-BluetoothRadio -On $false })
$btnBtRefresh.Add_Click({ Update-BluetoothList })
$btnBtSettings.Add_Click({ Open-DeviceSettingsScreen -Action 'android.settings.BLUETOOTH_SETTINGS' })
$btnBtCopy.Add_Click({ Copy-ListSelection -List $lstBt -Columns @(0, 1) })

$btnNfcOn.Add_Click({ Set-NfcRadio -On $true })
$btnNfcOff.Add_Click({ Set-NfcRadio -On $false })
$btnNfcRefresh.Add_Click({ Update-NfcState })
$btnNfcSettings.Add_Click({ Open-DeviceSettingsScreen -Action 'android.settings.NFC_SETTINGS' })

$btnUsersRefresh.Add_Click({ Update-UserList })
$btnUserSwitch.Add_Click({ Switch-DeviceUser })
$btnUserAdd.Add_Click({ Add-DeviceUser })
$btnUserRename.Add_Click({ Rename-DeviceUser })
$btnUserRemove.Add_Click({ Remove-DeviceUser })
$btnUserSwitcherOn.Add_Click({ Set-UserSwitcher -On $true })
$btnUserSwitcherOff.Add_Click({ Set-UserSwitcher -On $false })
$btnUserSettings.Add_Click({ Open-DeviceSettingsScreen -Action 'android.settings.USER_SETTINGS' })
$lstUsers.Add_DoubleClick({ Switch-DeviceUser })


$btnDeviceScrcpy.Add_Click({ Start-Scrcpy })
$btnOpenNova.Add_Click({
    $launcher = Join-Path $scriptRoot 'androiddc-nova.vbs'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-Log 'androiddc-nova.vbs is not next to this program, so the Nova window cannot be opened.' $colorWarn
        return
    }
    Write-Log 'Opening the AndroidDC Nova window and closing this one ...' $colorStep
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $launcher + '"')
    # closed the normal way, so this window's settings are written
    $form.Close()
})
$btnPhoneCall.Add_Click({ Start-QuickCall })
$btnPhoneEnd.Add_Click({ Stop-PhoneCall })
$btnPhoneSms.Add_Click({ Send-QuickSms })
$btnPhoneUssd.Add_Click({ Send-Ussd })
$btnPhoneDialer.Add_Click({ Open-QuickDialer })
$txtPhoneNumber.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Start-QuickCall }
})

# the inner tab strips need the same layout pass as the outer one
$tabsTethering.Add_SelectedIndexChanged({
    Update-TetherLayout
    Update-RightLayout
})
function Update-ShownRadio {
    # a freshly opened radio page should already say what the phone is doing
    if ($script:busy -gt 0 -or -not (Get-SelectedSerial)) { return }
    if ($tabsRadios.SelectedTab -eq $tabWifi -and $lstWifi.Items.Count -eq 0) { Update-WifiList -Saved }
    elseif ($tabsRadios.SelectedTab -eq $tabBt -and $lstBt.Items.Count -eq 0) { Update-BluetoothList }
    elseif ($tabsRadios.SelectedTab -eq $tabNfc) { Update-NfcState }
}
$tabsRadios.Add_SelectedIndexChanged({
    Set-PageEnterKey
    Update-RightLayout
    Update-ShownRadio
})
$tabsAdvanced.Add_SelectedIndexChanged({
    Update-ToolsLayout
    Update-MirrorLayout
    Update-RootLayout
    Update-RightLayout
    # the root page says what this phone allows as soon as it is opened, from
    # either tab - it used to wait until the outer tab changed
    if ($tabsAdvanced.SelectedTab -eq $tabRoot -and $script:busy -eq 0 -and (Get-SelectedSerial)) {
        Update-RootAvailability
    }
})


$btnClearShot.Add_Click({ Clear-Capture })
$btnTogglePane.Add_Click({ Switch-ScreenPane })
$btnLogFold.Add_Click({ Switch-LogPane })
$pnlLogGrip.Add_DoubleClick({ Switch-LogPane })
$pnlLogGrip.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    # screen coordinates: the bar itself moves while it is dragged
    $start = if ($script:logFolded) { 0 } else { $txtLog.Height }
    $script:logDrag = @{ Y = [System.Windows.Forms.Control]::MousePosition.Y; Height = $start }
})
$pnlLogGrip.Add_MouseMove({
    if (-not $script:logDrag) { return }
    $wanted = $script:logDrag.Height - ([System.Windows.Forms.Control]::MousePosition.Y - $script:logDrag.Y)
    $current = if ($script:logFolded) { 0 } else { $txtLog.Height }
    # a layout pass per pixel is more than PowerShell keeps up with
    if ([Math]::Abs($wanted - $current) -lt 4) { return }
    $script:logFolded = $false
    $script:logHeight = [Math]::Max(60, $wanted)
    Update-RightLayout
})
$pnlLogGrip.Add_MouseUp({ $script:logDrag = $null })
$pnlLogGrip.Add_Paint({
    param($sender, $eventArgs)
    # three short lines in the middle say "this can be dragged"
    $middle = [int]($sender.Width / 2)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 164, 168))
    foreach ($y in @(1, 3, 5)) { $eventArgs.Graphics.DrawLine($pen, ($middle - 14), $y, ($middle + 14), $y) }
    $pen.Dispose()
})

# every list gets its own right-click menu, built from the buttons that already
# act on that list, so the two can never drift apart
$null = Add-ListContextMenu -List $lstDevices -Buttons @($btnInfo, $btnDeviceScrcpy, $null, $btnRefresh)
$null = Add-ListContextMenu -List $lstApps -Buttons @($btnAppLaunch, $btnAppNewDisplay, $btnAppStop, $null,
    $btnAppInfo, $btnAppUninstall, $null, $btnAppExport)
$null = Add-ListContextMenu -List $lstContacts -Buttons @($btnContactCall, $btnContactEndCall, $null,
    $btnContactEdit, $btnContactDelete, $null, $btnContactCopy, $btnContactExport)
$null = Add-ListContextMenu -List $lstSms -Buttons @($btnSmsEdit, $btnSmsCopy, $null, $btnSmsDelete, $btnSmsExport)
$null = Add-ListContextMenu -List $lstFiles -Buttons @($btnFilePreview, $btnFileDownload, $btnFileMoveToPc, $null,
    $btnFileCompress, $btnFileExtract, $null,
    $btnFileRename, $btnFileDelete, $btnFileOpenPhone, $btnFileCopyPath, $null,
    $btnFileSelectAll, $btnFileSelectNone, $btnFileSelectInvert)
$null = Add-ListContextMenu -List $lstRunning -Buttons @($btnRunningStop, $btnRunningKill, $null,
    $btnRunningInfo, $btnRunningCopy, $btnRunningExport)
$null = Add-ListContextMenu -List $lstWifi -Buttons @($btnWifiConnect, $btnWifiForget, $null, $btnWifiStatus)
$null = Add-ListContextMenu -List $lstBt -Buttons @($btnBtCopy, $btnBtSettings)
$null = Add-ListContextMenu -List $lstUsers -Buttons @($btnUserSwitch, $null, $btnUserAdd, $btnUserRename,
    $btnUserRemove, $null, $btnUserSettings)

$btnRunningRefresh.Add_Click({ Update-RunningList })
$btnRunningStop.Add_Click({ Stop-RunningProcess })
$btnRunningKill.Add_Click({ Stop-RunningProcess -Soft })
$btnRunningKillAll.Add_Click({ Stop-AllBackground })
$btnRunningInfo.Add_Click({ Show-RunningAppInfo })
$btnRunningCopy.Add_Click({ Copy-ListSelection -List $lstRunning -Columns @(0, 1, 2, 4, 5) })
$btnRunningExport.Add_Click({ Export-RunningList })
$chkRunningApps.Add_CheckedChanged({ Update-RunningList })
$txtRunningFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Update-RunningList }
})
$lstRunning.Add_ColumnClick({
    param($sender, $eventArgs)
    if ($script:runningSortColumn -eq $eventArgs.Column) {
        $script:runningSortDescending = -not $script:runningSortDescending
    } else {
        $script:runningSortColumn = $eventArgs.Column
        $script:runningSortDescending = $true
    }
    Update-RunningList
})
$chkRunningAuto.Add_CheckedChanged({
    if ($chkRunningAuto.Checked) {
        $runningTimer.Interval = [int]$numRunningMs.Value
        $runningTimer.Start()
    } else {
        $runningTimer.Stop()
    }
})
$numRunningMs.Add_ValueChanged({ $runningTimer.Interval = [int]$numRunningMs.Value })

$btnAppsRefresh.Add_Click({ Update-AppList })
$txtAppFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Update-AppList }
})
$btnAppLaunch.Add_Click({ Start-App })
$btnAppNewDisplay.Add_Click({ Start-App -NewDisplay })
$btnAppStop.Add_Click({ Stop-App })
$btnAppInfo.Add_Click({ Show-AppInfo })
$btnAppUninstall.Add_Click({ Uninstall-App })
$btnAppInstall.Add_Click({ Install-Apk })
$btnAppExport.Add_Click({ Export-AppList })

$lstContacts.Add_SelectedIndexChanged({
    # so Call, and the same entry on the right mouse button, use the row you picked
    if ($lstContacts.SelectedItems.Count -eq 0) { return }
    $number = $lstContacts.SelectedItems[0].SubItems[1].Text
    if ($number) { $txtDialNumber.Text = $number }
})
$btnContactsRefresh.Add_Click({ Update-ContactList })
$txtContactFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Update-ContactList }
})
$btnContactAdd.Add_Click({ Add-Contact })
$btnContactEdit.Add_Click({ Edit-Contact })
$btnContactDelete.Add_Click({ Remove-Contact })
$btnContactCall.Add_Click({ Start-PhoneCall })
$btnContactEndCall.Add_Click({ Stop-PhoneCall })
$btnContactCopy.Add_Click({ Copy-ListSelection -List $lstContacts -Columns @(0, 1) })
$btnContactExport.Add_Click({ Export-Contacts })

$btnSmsRefresh.Add_Click({ Update-SmsList })
$txtSmsFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') { $eventArgs.SuppressKeyPress = $true; Update-SmsList }
})
$btnSmsSend.Add_Click({ Send-Sms })
$btnSmsCopy.Add_Click({ Copy-ListSelection -List $lstSms -Columns @(0, 2, 3) })
$btnSmsDelete.Add_Click({ Remove-Sms })
$btnSmsEdit.Add_Click({ Edit-Sms })
$btnSmsExport.Add_Click({ Export-Sms })

$btnRootCheck.Add_Click({ Update-RootAvailability })
$chkRootUnlock.Add_CheckedChanged({ Set-RootUnlock })
$btnRootOn.Add_Click({ Invoke-RootAction -Arguments @('root') })
$btnRootOff.Add_Click({ Invoke-RootAction -Arguments @('unroot') })
$btnRootRemount.Add_Click({ Invoke-RootAction -Arguments @('remount') })
$btnRootWaitDevice.Add_Click({ Invoke-RootAction -Arguments @('wait-for-device') })
$btnRootVerityOff.Add_Click({ Invoke-RootAction -Arguments @('disable-verity') })
$btnRootVerityOn.Add_Click({ Invoke-RootAction -Arguments @('enable-verity') })
$btnRootSideload.Add_Click({ Send-Sideload })
$btnRootEmu.Add_Click({
    $command = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Emulator console command (an emulator only; a phone refuses):', 'emu', 'help')
    if ("$command".Trim()) { Invoke-RootAction -Arguments @('emu', $command.Trim()) }
})
$btnRootJdwp.Add_Click({ Show-JdwpProcesses })
$btnRootKeygen.Add_Click({ Save-AdbKeygen })
$btnRootDevPath.Add_Click({ Invoke-RootAction -Arguments @('get-devpath') })
$btnShareRestart.Add_Click({ Restart-Sharing })

$btnPair.Add_Click({ Start-WirelessPairing })
$btnMdns.Add_Click({ Show-MdnsDevices })
$btnReconnect.Add_Click({ Invoke-Reconnect })
$btnBugReport.Add_Click({ Save-BugReport })
$btnTcpip.Add_Click({ Enable-WirelessAdb })
$btnConnect.Add_Click({ Connect-Wireless })
$btnDisconnect.Add_Click({ Disconnect-Wireless })
$btnRestartServer.Add_Click({ Restart-AdbServer })
$btnInstallApk.Add_Click({ Install-Apk })
$btnScreenshot.Add_Click({ Get-DeviceScreenshot })
$btnScreenToggle.Add_Click({ Switch-Screen })
$btnReboot.Add_Click({ Restart-Device })
$btnBattery.Add_Click({ Show-BatteryAndNetwork })
$btnReverseList.Add_Click({ Show-ReverseTunnels })
$btnKillRelays.Add_Click({ Stop-StrayRelays })
$btnRepairTunnel.Add_Click({ Repair-Tunnel })

# grpScreen fills Panel1 by docking, and a docked control only takes its new
# size in the layout pass that follows Panel1's Resize. Laid out on that
# event, the pane read the old width: after the window shrank, Send text sat
# past the edge until a tab change laid it out again. Its own Resize comes
# after it has been sized.
$grpScreen.Add_Resize({ Update-ScreenLayout })
$splitMain.Panel2.Add_Resize({
    Update-RightLayout
    Update-ShellLayout
    Update-RootLayout
})
$splitMain.Add_SplitterMoved({
    Update-ScreenLayout
    Update-RightLayout
})
$tabShell.Add_Resize({ Update-ShellLayout })
$tabs.Add_SelectedIndexChanged({
    # the page's own reading action answers Enter, and Tab walks it in order
    Set-PageEnterKey
    $null = Set-TabOrder -Container $tabs.SelectedTab
    # a page that was never on screen reports its design size, so its layout
    # function bailed out at startup: run the whole pass now that it is real
    Update-RightLayout
    Update-ScreenLayout
    Update-ShellLayout
    Update-LogcatLayout
    Update-ToolsLayout
    Update-RootLayout

    # opening the tools tab shows the DNS of the selected phone right away
    if ((Test-PageShown -Page $tabTools) -and $script:busy -eq 0) {
        $null = Show-DnsState -Quiet
    }

    # a freshly opened radio tab should already say what the phone is doing
    if ($script:busy -eq 0 -and (Get-TargetSerial)) {
        if ($tabs.SelectedTab -eq $tabDevice) {
            if ((Get-SelectedSerial) -ne $script:toggleSerial) { Show-ToggleStates -Quiet }
        }
        elseif ($tabs.SelectedTab -eq $tabFiles) { Update-FileVolumes -Serial (Get-TargetSerial) }
        elseif ($tabs.SelectedTab -eq $tabRadios) { Update-ShownRadio }
        elseif ($tabs.SelectedTab -eq $tabUsers -and $lstUsers.Items.Count -eq 0) { Update-UserList }
        elseif ($tabs.SelectedTab -eq $tabAdvanced -and $tabsAdvanced.SelectedTab -eq $tabRoot) {
            Update-RootAvailability
        }
    }
})

# F5, Ctrl+1..9 and Ctrl+L reach the window before the control with the focus
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if (Invoke-WindowKey -KeyData $eventArgs.KeyData) {
        $eventArgs.Handled = $true
        $eventArgs.SuppressKeyPress = $true
    }
})

$btnCapture.Add_Click({ Update-Capture })
$btnSaveShot.Add_Click({
    if (-not $script:captureImage) { Write-Log 'Capture something first.' $colorWarn; return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'PNG (*.png)|*.png'
    $dialog.FileName = 'android-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:captureImage.Save($dialog.FileName, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Log "Saved to $($dialog.FileName)" $colorGood
    }
})
$chkAutoShot.Add_CheckedChanged({
    if ($chkAutoShot.Checked) {
        $screenTimer.Interval = [int]$numShotMs.Value
        $screenTimer.Start()
        Write-Log "Auto capture every $([int]$numShotMs.Value) ms." $colorInfo
    } else {
        $screenTimer.Stop()
    }
})
$numShotMs.Add_ValueChanged({ $screenTimer.Interval = [int]$numShotMs.Value })

$btnKeyBack.Add_Click({ Send-Key -KeyCode 4 })
$btnKeyHome.Add_Click({ Send-Key -KeyCode 3 })
$btnKeyRecents.Add_Click({ Send-Key -KeyCode 187 })
$btnKeyPower.Add_Click({ Send-Key -KeyCode 26 })
$btnKeyVolUp.Add_Click({ Send-Key -KeyCode 24 })
$btnKeyVolDown.Add_Click({ Send-Key -KeyCode 25 })
$btnSendText.Add_Click({ Send-Text })
$txtSendText.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Return') {
        $eventArgs.SuppressKeyPress = $true
        Send-Text
    }
})

$picScreen.Add_MouseDown({
    param($sender, $eventArgs)
    $script:pressPoint = Convert-ToDevicePoint -X $eventArgs.X -Y $eventArgs.Y
    $script:pressTime = Get-Date
})

$picScreen.Add_MouseUp({
    param($sender, $eventArgs)

    $start = $script:pressPoint
    $script:pressPoint = $null

    # right button = Back, thumb buttons = Recents / notification panel
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        Send-Key -KeyCode 4
        return
    }
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton1) {
        Send-Key -KeyCode 187
        return
    }
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton2) {
        Show-Notifications
        return
    }

    if (-not $start) { return }
    $end = Convert-ToDevicePoint -X $eventArgs.X -Y $eventArgs.Y
    if (-not $end) { return }

    $held = if ($script:pressTime) { ((Get-Date) - $script:pressTime).TotalMilliseconds } else { 0 }
    $distance = [Math]::Sqrt([Math]::Pow($end.X - $start.X, 2) + [Math]::Pow($end.Y - $start.Y, 2))

    if ($distance -gt 12) {
        Send-Swipe -X1 $start.X -Y1 $start.Y -X2 $end.X -Y2 $end.Y -Duration ([int][Math]::Max(120, $held))
    } elseif ($held -gt 500) {
        # holding still = long press: a swipe that does not move
        Send-Swipe -X1 $start.X -Y1 $start.Y -X2 $start.X -Y2 $start.Y -Duration 600
    } else {
        Send-Tap -X $start.X -Y $start.Y
    }
})

$btnRotationOn.Add_Click({ Set-DeviceToggle -Feature 'rotation' -Enabled $true })
$btnRotationOff.Add_Click({ Set-DeviceToggle -Feature 'rotation' -Enabled $false })
$btnLocationOn.Add_Click({ Set-DeviceToggle -Feature 'location' -Enabled $true })
$btnLocationOff.Add_Click({ Set-DeviceToggle -Feature 'location' -Enabled $false })
$btnBtOn.Add_Click({ Set-DeviceToggle -Feature 'bluetooth' -Enabled $true })
$btnBtOff.Add_Click({ Set-DeviceToggle -Feature 'bluetooth' -Enabled $false })
$btnWifiOn.Add_Click({ Set-DeviceToggle -Feature 'wifi' -Enabled $true })
$btnWifiOff.Add_Click({ Set-DeviceToggle -Feature 'wifi' -Enabled $false })
$btnSaverOn.Add_Click({ Set-DeviceToggle -Feature 'saver' -Enabled $true })
$btnSaverOff.Add_Click({ Set-DeviceToggle -Feature 'saver' -Enabled $false })
$btnRingVibeOn.Add_Click({ Set-DeviceToggle -Feature 'ringvibe' -Enabled $true })
$btnRingVibeOff.Add_Click({ Set-DeviceToggle -Feature 'ringvibe' -Enabled $false })
$btnHapticsOn.Add_Click({ Set-DeviceToggle -Feature 'haptics' -Enabled $true })
$btnHapticsOff.Add_Click({ Set-DeviceToggle -Feature 'haptics' -Enabled $false })
$btnDevOn.Add_Click({ Set-DeviceToggle -Feature 'devopts' -Enabled $true })
$btnDevOff.Add_Click({ Set-DeviceToggle -Feature 'devopts' -Enabled $false })
$btnDevOpen.Add_Click({
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('settings', 'put', 'global', 'development_settings_enabled', '1')
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS')
    Write-Log $result.Text $colorInfo
    Wait-Pumped -Milliseconds 900
    Update-Capture -Quiet
})
$btnTapsOn.Add_Click({ Set-DeviceToggle -Feature 'showtaps' -Enabled $true })
$btnTapsOff.Add_Click({ Set-DeviceToggle -Feature 'showtaps' -Enabled $false })
$btnAwakeOn.Add_Click({ Set-DeviceToggle -Feature 'stayawake' -Enabled $true })
$btnAwakeOff.Add_Click({ Set-DeviceToggle -Feature 'stayawake' -Enabled $false })

$btnTorch.Add_Click({ Switch-Torch })
$btnBuzz.Add_Click({ Send-Buzz })
$btnReadToggles.Add_Click({ Show-ToggleStates })

$btnImeList.Add_Click({ Update-ImeList })
$btnImeDisable.Add_Click({ Set-ImeState -Action 'disable' })
$btnImeEnable.Add_Click({ Set-ImeState -Action 'enable' })
$btnImeDefault.Add_Click({ Set-ImeDefault })
$btnImeReset.Add_Click({ Reset-ImeList })

$btnLogcatStart.Add_Click({ Start-Logcat })
$btnLogcatStop.Add_Click({ Stop-Logcat })
$btnLogcatClear.Add_Click({ Clear-Logcat })
$btnLogcatSave.Add_Click({ Save-Logcat })
$script:logcatFilterTimer = New-Object System.Windows.Forms.Timer
$script:logcatFilterTimer.Interval = 350
$script:logcatFilterTimer.Add_Tick({
    $script:logcatFilterTimer.Stop()
    Show-LogcatFiltered
})

$txtLogcatFilter.Add_TextChanged({
    # wait for the typing to settle rather than redrawing on every key
    $script:logcatFilterTimer.Stop()
    $script:logcatFilterTimer.Start()
})

$cmbLogcatLevel.Add_SelectedIndexChanged({
    # the level is a start-up argument, so restart the stream to apply it
    if ($script:logcatProcess -and -not $script:logcatProcess.HasExited) {
        Stop-Logcat -Quiet
        Start-Logcat
    }
})
$btnShellStart.Add_Click({ Start-LiveShell })
$btnShellStop.Add_Click({ Stop-LiveShell })
$btnShellClear.Add_Click({ $txtShellOut.Clear() })
$btnShellSend.Add_Click({ Send-ShellLine })

$cmbShellPreset.Add_SelectedIndexChanged({
    if ($cmbShellPreset.SelectedIndex -le 0) { return }
    $txtShellIn.Text = "$($cmbShellPreset.SelectedItem)"
    $cmbShellPreset.SelectedIndex = 0
    $null = $txtShellIn.Focus()
    $txtShellIn.SelectionStart = $txtShellIn.TextLength
})

$txtShellIn.Add_KeyDown({
    param($sender, $eventArgs)

    switch ($eventArgs.KeyCode) {
        'Return' {
            $eventArgs.SuppressKeyPress = $true
            Send-ShellLine
        }
        'Up' {
            if ($script:shellHistory.Count -eq 0) { return }
            $eventArgs.SuppressKeyPress = $true
            if ($script:shellHistoryIndex -gt 0) { $script:shellHistoryIndex-- }
            $txtShellIn.Text = $script:shellHistory[$script:shellHistoryIndex]
            $txtShellIn.SelectionStart = $txtShellIn.TextLength
        }
        'Down' {
            if ($script:shellHistory.Count -eq 0) { return }
            $eventArgs.SuppressKeyPress = $true
            if ($script:shellHistoryIndex -lt $script:shellHistory.Count - 1) {
                $script:shellHistoryIndex++
                $txtShellIn.Text = $script:shellHistory[$script:shellHistoryIndex]
            } else {
                $script:shellHistoryIndex = $script:shellHistory.Count
                $txtShellIn.Clear()
            }
            $txtShellIn.SelectionStart = $txtShellIn.TextLength
        }
    }
})

# ------------------------------------------------------------- automation ----

$script:automationRules = @()
$script:automationLoading = $false

function Update-AutomationTab {
    # the rules as the file has them now, and whether AndroidDC starts with Windows
    $script:automationLoading = $true
    try {
        $keep = if ($lstAutoRules.SelectedItems.Count -gt 0) { "$($lstAutoRules.SelectedItems[0].Tag)" } else { '' }
        $script:automationRules = @(Read-AutomationRules)
        $problem = Get-AutomationReadError
        if ($problem) { Write-Log "Automation: the rules file could not be read: $problem" $colorBad }
        # the tab says how many rules there are, so they show from the Advanced tab too
        $tabAutomation.Text = if ($script:automationRules.Count -gt 0) { "Automation ($($script:automationRules.Count))" } else { 'Automation' }
        $lstAutoRules.BeginUpdate()
        try {
            $lstAutoRules.Items.Clear()
            foreach ($rule in $script:automationRules) {
                $item = New-Object System.Windows.Forms.ListViewItem($(if ($rule.Enabled) { 'on' } else { 'off' }))
                $null = $item.SubItems.Add($rule.Name)
                $null = $item.SubItems.Add($rule.Serial)
                $item.Tag = $rule.Serial
                $item.ToolTipText = Get-AutomationRuleSummary -Rule $rule
                $null = $lstAutoRules.Items.Add($item)
            }
        } finally {
            $lstAutoRules.EndUpdate()
        }
        foreach ($item in $lstAutoRules.Items) { if ("$($item.Tag)" -eq $keep) { $item.Selected = $true } }
        if ($lstAutoRules.SelectedItems.Count -eq 0 -and $lstAutoRules.Items.Count -gt 0) { $lstAutoRules.Items[0].Selected = $true }

        $startup = Get-AutomationStartup
        $chkAutoStart.Checked = [bool]$startup
        if ($startup -eq 'nova') { $rdoAutoNova.Checked = $true } elseif ($startup -eq 'classic') { $rdoAutoClassic.Checked = $true }
    } finally {
        $script:automationLoading = $false
    }
    Show-AutomationRule
}

function Get-AutomationSelectedRule {
    if ($lstAutoRules.SelectedItems.Count -eq 0) { return $null }
    return (Get-AutomationRule -Rules $script:automationRules -Serial "$($lstAutoRules.SelectedItems[0].Tag)")
}

function Show-AutomationRule {
    # the selected rule's actions ticked; nothing to tick without a rule
    $was = $script:automationLoading
    $script:automationLoading = $true
    try {
        $rule = Get-AutomationSelectedRule
        $ids = @()
        $app = ''
        if ($rule) {
            foreach ($entry in @($rule.Actions)) {
                $ids += $entry.Id
                if ($entry.Id -eq 'app') { $app = $entry.Value }
            }
        }
        for ($i = 0; $i -lt $clbAutoActions.Items.Count; $i++) {
            $clbAutoActions.SetItemChecked($i, ($ids -contains $script:automationActionIds[$i]))
        }
        $txtAutoApp.Text = $app
        $chkAutoRuleOn.Checked = ($null -ne $rule -and $rule.Enabled)
        foreach ($control in @($clbAutoActions, $txtAutoApp, $chkAutoRuleOn, $btnAutoRun, $btnAutoRemove)) {
            $control.Enabled = ($null -ne $rule)
        }
        $lblAutoHint.Text = if ($rule) { "$($rule.Name): " + (Get-AutomationRuleSummary -Rule $rule) } else {
            'Select a phone in the device list, then "Add the selected phone".' }
        $toolTip.SetToolTip($lblAutoHint, $lblAutoHint.Text)
    } finally {
        $script:automationLoading = $was
    }
}

function Save-AutomationTabRule {
    # ItemCheck comes before the tick changes, so the item being changed is passed in
    param([int]$ChangedIndex = -1, [bool]$ChangedValue = $false)

    if ($script:automationLoading) { return }
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }

    $actions = @()
    for ($i = 0; $i -lt $clbAutoActions.Items.Count; $i++) {
        $ticked = if ($i -eq $ChangedIndex) { $ChangedValue } else { $clbAutoActions.GetItemChecked($i) }
        if (-not $ticked) { continue }
        $id = $script:automationActionIds[$i]
        $actions += [PSCustomObject]@{ Id = $id; Value = $(if ($id -eq 'app') { $txtAutoApp.Text.Trim() } else { '' }) }
    }
    $rule.Actions = $actions
    $rule.Enabled = $chkAutoRuleOn.Checked
    if (Save-AutomationRules -Rules $script:automationRules) {
        $item = $lstAutoRules.SelectedItems[0]
        $item.Text = if ($rule.Enabled) { 'on' } else { 'off' }
        $item.ToolTipText = Get-AutomationRuleSummary -Rule $rule
        $lblAutoHint.Text = "$($rule.Name): " + $item.ToolTipText
        $toolTip.SetToolTip($lblAutoHint, $lblAutoHint.Text)
    }
}

function Add-AutomationTabRule {
    # a rule for the phone selected in the device list, or that phone's rule selected
    $serial = Get-SelectedSerial
    if (-not $serial) { Write-Log 'Select a device first.' $colorWarn; return }

    $rules = @(Read-AutomationRules)
    $problem = Get-AutomationReadError
    if ($problem) { Write-Log "Automation: the rules file could not be read: $problem" $colorBad; return }
    if (-not (Get-AutomationRule -Rules $rules -Serial $serial)) {
        $model = $lstDevices.SelectedItems[0].SubItems[2].Text -replace '_', ' '
        $name = if ($model -and $model -ne '-') { $model } else { $serial }
        $rules += [PSCustomObject]@{ Serial = $serial; Name = $name; Enabled = $true; Actions = @() }
        if (-not (Save-AutomationRules -Rules $rules)) { return }
        Write-Log "Automation: a rule for $name ($serial). Tick what should happen when it is plugged in." $colorGood
    }
    Update-AutomationTab
    foreach ($item in $lstAutoRules.Items) { $item.Selected = ("$($item.Tag)" -eq $serial) }
}

function Remove-AutomationTabRule {
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }
    $rules = @($script:automationRules | Where-Object { $_.Serial -ne $rule.Serial })
    if (Save-AutomationRules -Rules $rules) { Write-Log "Automation: removed the rule for $($rule.Name)." $colorInfo }
    Update-AutomationTab
}

function Invoke-AutomationTabRule {
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }
    if (@($rule.Actions).Count -eq 0) { Write-Log 'Automation: this rule has no actions yet.' $colorWarn; return }
    if ($script:busy -gt 0) { Write-Log 'Wait for the running command to finish.' $colorWarn; return }
    Invoke-AutomationRule -Rule $rule -Enter { param($Serial) Enter-AutomationDevice -Serial $Serial } `
        -Leave { param($State) Exit-AutomationDevice -State $State }
}

function Set-AutomationTabStartup {
    if ($script:automationLoading) { return }
    $window = if (-not $chkAutoStart.Checked) { '' } elseif ($rdoAutoNova.Checked) { 'nova' } else { 'classic' }
    if (-not (Set-AutomationStartup -Window $window)) {
        # show what is really there, not what was asked for
        $script:automationLoading = $true
        $chkAutoStart.Checked = [bool](Get-AutomationStartup)
        $script:automationLoading = $false
    }
}

function Enter-AutomationDevice {
    # selects the rule's phone so the actions act on it alone; $false when that
    # phone is not ready in the list. Returns what Exit-AutomationDevice puts back.
    param([string]$Serial)

    $found = $false
    foreach ($item in $lstDevices.Items) {
        if ($item.Text -eq $Serial -and $item.SubItems[4].Text -eq 'device') { $found = $true }
    }
    if (-not $found) { return $false }
    $state = [PSCustomObject]@{ All = $chkAll.Checked }
    $chkAll.Checked = $false
    foreach ($item in $lstDevices.Items) { $item.Selected = ($item.Text -eq $Serial) }
    Wait-Pumped -Milliseconds 300
    return $state
}

function Exit-AutomationDevice {
    param($State)
    if ($null -ne $State -and $State -isnot [bool]) { $chkAll.Checked = $State.All }
}

$lstAutoRules.Add_SelectedIndexChanged({ if (-not $script:automationLoading) { Show-AutomationRule } })
$clbAutoActions.Add_ItemCheck({
    param($sender, $eventArgs)
    Save-AutomationTabRule -ChangedIndex $eventArgs.Index -ChangedValue ($eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
})
$chkAutoRuleOn.Add_CheckedChanged({ Save-AutomationTabRule })
$txtAutoApp.Add_TextChanged({ Save-AutomationTabRule })
$btnAutoAdd.Add_Click({ Add-AutomationTabRule })
$btnAutoRemove.Add_Click({ Remove-AutomationTabRule })
$btnAutoRun.Add_Click({ Invoke-AutomationTabRule })
$chkAutoStart.Add_CheckedChanged({ Set-AutomationTabStartup })
# the one that was picked; the one that was left calls too, and is not checked
$rdoAutoClassic.Add_CheckedChanged({ if ($rdoAutoClassic.Checked -and $chkAutoStart.Checked) { Set-AutomationTabStartup } })
$rdoAutoNova.Add_CheckedChanged({ if ($rdoAutoNova.Checked -and $chkAutoStart.Checked) { Set-AutomationTabStartup } })
$tabsAdvanced.Add_SelectedIndexChanged({ if (Test-PageShown -Page $tabAutomation) { Update-AutomationTab } })
$tabs.Add_SelectedIndexChanged({ if (Test-PageShown -Page $tabAutomation) { Update-AutomationTab } })

# minimized means into the tray: off the taskbar, still watching for phones
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and -not (Test-TrayHidden)) { Hide-TrayWindow }
})

# ----------------------------------------------------------------- backup ----
# The tab's own work; the backup itself is shared\Backup.ps1, which the Nova
# window uses as well.

$script:backupPath = ''
$script:backupSource = $null
$script:backupManifest = $null
$script:backupAppRows = @()
# the packages ticked, kept by name and not by row: the find box hides rows,
# and a tick that means "row 12" means another app once one is hidden
$script:backupAppTicked = @{}
$script:backupInsideRows = @()
$script:backupListRows = @()
# what is inside, and the apps, are read when their tab is looked at - a backup
# of forty thousand files would otherwise be read before the box even says
# whose phone it is
$script:backupInsideStale = $true
$script:backupAppsStale = $true
# a phone can hold tens of thousands of files; a list control cannot show them
# all without a long pause, so the rest wait behind the find box
$script:backupInsideMax = 3000

function Set-BackupProgressUi {
    param([string]$Text, [int]$Done, [int]$Total)

    $lblBackupProgress.Text = $Text
    $toolTip.SetToolTip($lblBackupProgress, $Text)
    if ($Total -gt 0 -and $Done -ge 0) {
        if ($prgBackup.Style -ne 'Blocks') { $prgBackup.Style = 'Blocks' }
        $prgBackup.Maximum = $Total
        $prgBackup.Value = [Math]::Max(0, [Math]::Min($Total, $Done))
    } else {
        # how long it will take is not known - reading a zip's index says only
        # how far it has got - so the bar rolls instead of pretending
        if ($prgBackup.Style -ne 'Marquee') { $prgBackup.Style = 'Marquee' }
    }
}

function Set-BackupBusyUi {
    # while a backup or a restore runs, Cancel is the only button that works
    param([bool]$Running)

    $btnBackupCancel.Enabled = $Running
    foreach ($control in @($btnBackupRun, $btnBackupOpen, $btnRestoreFiles, $btnRestoreApps,
        $btnRestoreContacts, $btnBackupSaveCopy, $btnBackupListOpen, $btnBackupWhereBrowse,
        $btnBackupAppsAll, $btnBackupAppsNone)) {
        $control.Enabled = -not $Running
    }
    if (-not $Running) {
        $prgBackup.Style = 'Blocks'
        $prgBackup.Value = 0
    }
}

function Get-BackupTickedParts {
    $parts = @()
    if ($chkBackupFiles.Checked) { $parts += 'files' }
    if ($chkBackupApps.Checked) { $parts += 'apps' }
    if ($chkBackupPersonal.Checked) { $parts += 'personal' }
    if ($chkBackupSettings.Checked) { $parts += 'settings' }
    return $parts
}

function Show-BackupAt {
    # what a backup holds - the .zip it is, or the folder an older one was -
    # the files in it, and its apps against this phone
    param([Alias('Folder')][string]$Path)

    $source = Open-BackupSource -Path $Path
    if ($null -eq $source) {
        Write-Log "That holds no manifest.json, so it is not a backup: $Path" $colorBad
        return $false
    }

    $script:backupSource = $source
    $script:backupPath = $source.Path
    $script:backupManifest = $source.Manifest
    $txtBackupInfo.Text = ((@($source.Path) + @(Get-BackupSummaryLines -Manifest $source.Manifest -Source $source)) -join
        [Environment]::NewLine)

    # the manifest is read here and nothing else; the two lists below read the
    # backup itself, and only when they are looked at
    $script:backupInsideStale = $true
    $script:backupAppsStale = $true
    $script:backupAppTicked = @{}
    $lstBackupApps.Items.Clear()
    $lstBackupInside.Items.Clear()
    $lblBackupInside.Text = 'Open the tab to read what is inside.'
    Update-BackupShownTab
    Update-ListHints
    Write-Log "Backup opened: $($source.Path)" $colorInfo
    return $true
}

function Update-BackupShownTab {
    # fills the tab that is on screen, once, and leaves the others alone
    if ($tabsBackupView.SelectedTab -eq $tabBackupInside -and $script:backupInsideStale) { Update-BackupInside }
    elseif ($tabsBackupView.SelectedTab -eq $tabBackupApps -and $script:backupAppsStale) { Update-BackupApps }
}

function Update-BackupApps {
    # the apps in the opened backup, read against this phone; the ones it does
    # not have are ticked, because those are the ones there is anything to do
    # about
    $script:backupAppRows = @()
    $script:backupAppsStale = $false
    $script:backupAppTicked = @{}
    if (-not $script:backupSource) {
        $lstBackupApps.Items.Clear()
        $lblBackupApps.Text = 'Open a backup to see the apps in it.'
        Update-ListHints
        return
    }

    Set-BackupReadingUi -Running $true
    try {
        $serial = Get-SelectedSerial
        $script:backupAppRows = @(Get-BackupAppRows -Source $script:backupSource -Serial $(if ($serial) { $serial } else { '' }))
        foreach ($row in $script:backupAppRows) {
            if ($row.State -eq 'not on the phone') { $script:backupAppTicked[$row.Package] = $true }
        }
    } finally {
        Set-BackupReadingUi -Running $false
    }
    Show-BackupApps
}

function Show-BackupApps {
    # the rows the find box lets through, with the ticks as they stand
    $find = "$($txtBackupAppFind.Text)".Trim()
    $items = New-Object System.Collections.Generic.List[object]
    $shown = 0
    foreach ($row in $script:backupAppRows) {
        if ($find -and -not (Test-TextContains $row.Package $find) -and -not (Test-TextContains $row.Shown $find)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($row.Shown)
        $null = $item.SubItems.Add($row.Package)
        $null = $item.SubItems.Add($(if ($row.Version) { "version $($row.Version)" } else { $row.Parts }))
        $null = $item.SubItems.Add($row.Size)
        $null = $item.SubItems.Add($(if ($row.State -eq 'on the phone' -and $row.Phone) { "on the phone (version $($row.Phone))" } else { $row.State }))
        # the row itself, so a tick still means this app once the list is filtered
        $item.Tag = $row.Package
        $item.Checked = [bool]$script:backupAppTicked[$row.Package]
        $null = $items.Add($item)
        $shown++
    }

    $lstBackupApps.BeginUpdate()
    try {
        $lstBackupApps.Items.Clear()
        if ($items.Count -gt 0) { $lstBackupApps.Items.AddRange($items.ToArray()) }
    } finally {
        $lstBackupApps.EndUpdate()
    }

    $ticked = @($script:backupAppTicked.Keys).Count
    $missing = @($script:backupAppRows | Where-Object { $_.State -eq 'not on the phone' }).Count
    if ($script:backupAppRows.Count -eq 0) {
        $lblBackupApps.Text = 'This backup holds no apps.'
    } elseif ($find) {
        $lblBackupApps.Text = ('{0} of {1} app(s) shown, {2} ticked' -f $shown, $script:backupAppRows.Count, $ticked)
    } else {
        $lblBackupApps.Text = ('{0} app(s), {1} not on the phone, {2} ticked - press "Install ticked apps"' -f
            $script:backupAppRows.Count, $missing, $ticked)
    }
    $toolTip.SetToolTip($lblBackupApps, $lblBackupApps.Text)
    Update-ListHints
}

function Set-BackupAppTicks {
    # every app the list is showing, ticked or unticked in one go
    param([bool]$On)

    foreach ($item in $lstBackupApps.Items) {
        $package = "$($item.Tag)"
        if (-not $package) { continue }
        if ($On) { $script:backupAppTicked[$package] = $true } else { $null = $script:backupAppTicked.Remove($package) }
        $item.Checked = $On
    }
    Show-BackupApps
}

function Update-BackupInside {
    # every file in the opened backup, read from its index - nothing is unpacked
    $script:backupInsideStale = $false
    $lstBackupInside.BeginUpdate()
    $lstBackupInside.Items.Clear()
    $script:backupInsideRows = @()
    if (-not $script:backupSource) {
        $lstBackupInside.EndUpdate()
        $lblBackupInside.Text = 'Nothing open.'
        Update-ListHints
        return
    }

    Set-BackupReadingUi -Running $true
    try {
        $found = Get-BackupInsideRows -Source $script:backupSource -Filter $txtBackupFind.Text -Limit $script:backupInsideMax
        $script:backupInsideRows = $found.Rows
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($row in $found.Rows) {
            $item = New-Object System.Windows.Forms.ListViewItem($row.What)
            $null = $item.SubItems.Add($row.Path)
            $null = $item.SubItems.Add($row.Size)
            $null = $items.Add($item)
        }
        # AddRange, not Add in a loop: three thousand rows one at a time is a
        # visible pause even inside BeginUpdate
        if ($items.Count -gt 0) { $lstBackupInside.Items.AddRange($items.ToArray()) }

        if ($found.Total -gt $found.Rows.Count) {
            $lblBackupInside.Text = ('{0} file(s), {1} - the first {2} are listed' -f $found.Total,
                (Format-FileSize -Bytes $found.Bytes), $found.Rows.Count)
        } else {
            $lblBackupInside.Text = ('{0} file(s), {1}' -f $found.Total, (Format-FileSize -Bytes $found.Bytes))
        }
    } finally {
        $lstBackupInside.EndUpdate()
        Set-BackupReadingUi -Running $false
    }
    $toolTip.SetToolTip($lblBackupInside, $lblBackupInside.Text)
    Update-ListHints
}

function Set-BackupReadingUi {
    # reading a backup is not a run that can be cancelled, but it can take a
    # moment, and the window says so instead of going quiet
    param([bool]$Running)

    if ($Running) {
        $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
        Set-BackupProgressUi -Text 'Reading the backup ...' -Done -1 -Total -1
    } else {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $prgBackup.Style = 'Blocks'
        $prgBackup.Value = 0
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-BackupList {
    # the backups in the folder the box above says, newest first
    $folder = "$($txtBackupWhere.Text)".Trim()
    $lstBackupList.BeginUpdate()
    $lstBackupList.Items.Clear()
    $script:backupListRows = @(Get-BackupsInFolder -Folder $folder)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($row in $script:backupListRows) {
        $item = New-Object System.Windows.Forms.ListViewItem($row.When)
        $null = $item.SubItems.Add($row.Phone)
        $null = $item.SubItems.Add($row.Holds)
        $null = $item.SubItems.Add($row.Size)
        $null = $item.SubItems.Add($row.State)
        $null = $item.SubItems.Add($row.Name)
        $null = $items.Add($item)
    }
    if ($items.Count -gt 0) { $lstBackupList.Items.AddRange($items.ToArray()) }
    $lstBackupList.EndUpdate()
    Update-BackupListHint -Folder $folder
    Update-ListHints
}

function Update-BackupListHint {
    # what the empty list says depends on why it is empty
    param([string]$Folder)

    $hint = 'No backups yet - take one above, or pick the folder yours are in.'
    if ($Folder -and -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        $hint = 'There is no such folder on this PC.'
    } elseif ($Folder) {
        $hint = 'No backups in that folder - pick another one with Browse.'
    }
    foreach ($item in $script:listHints) {
        if ($item.List -eq $lstBackupList) { $item.Label.Text = $hint }
    }
}

function Set-BackupFolderUi {
    # the folder the list looks in, remembered for both windows
    param([string]$Folder, [switch]$Remember)

    $txtBackupWhere.Text = "$Folder"
    if ($Remember) { $null = Set-BackupFolderPath -Folder $Folder }
    Update-BackupList
}

function Get-BackupListPick {
    # the backup picked in the list, or nothing when none is
    if ($lstBackupList.SelectedIndices.Count -eq 0) { return $null }
    $index = $lstBackupList.SelectedIndices[0]
    if ($index -lt 0 -or $index -ge $script:backupListRows.Count) { return $null }
    return $script:backupListRows[$index]
}

function Start-BackupNow {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $parts = @(Get-BackupTickedParts)
    if ($parts.Count -eq 0) { Write-Log 'Tick what should go into the backup first.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Where should this backup be kept?'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $model = ''
    if ($lstDevices.SelectedItems.Count -gt 0) { $model = $lstDevices.SelectedItems[0].SubItems[2].Text }
    Set-BackupBusyUi -Running $true
    try {
        $manifest = Invoke-PhoneBackup -Serial $serial -Destination $dialog.SelectedPath -Parts $parts -Model $model
    } finally {
        Set-BackupBusyUi -Running $false
    }
    if ($manifest) {
        $null = Show-BackupAt -Path $manifest.Path
        # the list follows the backup just taken
        Set-BackupFolderUi -Folder $dialog.SelectedPath
    }
}

function Open-BackupFile {
    # a backup is one .zip file now; the dialog opens where the last one was
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Open a backup'
    $dialog.Filter = 'Backup (*.zip)|*.zip|Every file (*.*)|*.*'
    # where the last one was opened from, or the folder the list is looking in
    $start = "$($txtBackupWhere.Text)".Trim()
    if ($script:backupPath -and (Test-Path -LiteralPath $script:backupPath)) {
        $start = Split-Path -Parent $script:backupPath
    }
    if ($start -and (Test-Path -LiteralPath $start -PathType Container)) { $dialog.InitialDirectory = $start }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    if (Show-BackupAt -Path $dialog.FileName) {
        # the list follows the backup that was opened
        Set-BackupFolderUi -Folder (Split-Path -Parent $dialog.FileName) -Remember
    }
}

function Select-BackupFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Which folder are your backups kept in?'
    $now = "$($txtBackupWhere.Text)".Trim()
    if ($now -and (Test-Path -LiteralPath $now -PathType Container)) { $dialog.SelectedPath = $now }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Set-BackupFolderUi -Folder $dialog.SelectedPath -Remember
}

function Open-BackupFromList {
    $row = Get-BackupListPick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $row.Path)) {
        Write-Log "That backup is not there any more: $($row.Path)" $colorWarn
        Update-BackupList
        return
    }
    $null = Show-BackupAt -Path $row.Path
    $tabsBackupView.SelectedTab = $tabBackupInside
}

function Show-BackupPickedInExplorer {
    $row = Get-BackupListPick
    if (-not $row) { Write-Log 'Pick a backup in the list first.' $colorWarn; return }
    Show-BackupPathInExplorer -Path $row.Path
}

function Save-BackupPickedFiles {
    # files out of the backup onto this PC, without a phone in it at all
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }
    $entries = @()
    foreach ($index in $lstBackupInside.SelectedIndices) {
        if ($index -ge 0 -and $index -lt $script:backupInsideRows.Count) { $entries += $script:backupInsideRows[$index].Entry }
    }
    if ($entries.Count -eq 0) { Write-Log 'Pick the files to save in the list first.' $colorWarn; return }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Where should these $($entries.Count) file(s) be written?"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Set-BackupBusyUi -Running $true
    try {
        $null = Save-BackupCopy -Source $script:backupSource -Entries $entries -Destination $dialog.SelectedPath
    } finally {
        Set-BackupBusyUi -Running $false
    }
}

function Start-RestoreFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }

    Write-Log 'Restore: reading what the phone already has ...' $colorStep
    $plan = Get-BackupFilePlan -Source $script:backupSource
    if ($plan.Total -eq 0) { Write-Log 'This backup holds no files.' $colorWarn; return }
    $plan = Set-BackupFilePlanState -Plan $plan -Serial $serial

    $mode = 'skip'
    if ($plan.Existing -gt 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$($plan.Existing) of $($plan.Total) file(s) in this backup are already on the phone." +
            [Environment]::NewLine + [Environment]::NewLine +
            'Yes - write over them' + [Environment]::NewLine +
            'No - leave them and send only the rest' + [Environment]::NewLine +
            'Cancel - do nothing',
            'Restore files', 'YesNoCancel', 'Question')
        if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) { Write-Log 'Restore cancelled.' $colorWarn; return }
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { $mode = 'replace' }
    }
    Set-BackupBusyUi -Running $true
    try {
        $null = Restore-BackupFiles -Plan $plan -Serial $serial -OnConflict $mode
    } finally {
        Set-BackupBusyUi -Running $false
    }
}

function Start-RestoreApps {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }

    $rows = @()
    foreach ($row in $script:backupAppRows) {
        if ($script:backupAppTicked[$row.Package]) { $rows += $row }
    }
    if ($rows.Count -eq 0) {
        Write-Log 'Tick the apps to install first - the ones this phone does not have are ticked for you.' $colorWarn
        return
    }
    Set-BackupBusyUi -Running $true
    try {
        $null = Restore-BackupApps -Rows $rows -Serial $serial -Source $script:backupSource
    } finally {
        Set-BackupBusyUi -Running $false
    }
    Update-BackupApps
}

function Update-BackupAppsIfShown {
    # what the phone has changed, so the ticks would be out of date
    # the device list can fill while the window is still being built, before
    # this section of it has run at all
    if (-not (Test-Path 'variable:script:backupSource')) { return }
    if ($tabsBackupView.SelectedTab -eq $tabBackupApps -and $script:backupSource) { Update-BackupApps }
    else { $script:backupAppsStale = $true }
}

function Start-RestoreContacts {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if (-not $script:backupSource) { Write-Log 'Open a backup first.' $colorWarn; return }
    Set-BackupBusyUi -Running $true
    try {
        $null = Restore-BackupContacts -Source $script:backupSource -Serial $serial
    } finally {
        Set-BackupBusyUi -Running $false
    }
}

function Show-BackupPathInExplorer {
    # a file is picked out in its folder; a folder is opened
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Log 'That backup is not there any more.' $colorWarn
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"')
    } else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $Path + '"')
    }
}

function Show-BackupInExplorer {
    if (-not $script:backupPath) { Write-Log 'Open a backup first.' $colorWarn; return }
    Show-BackupPathInExplorer -Path $script:backupPath
}

$btnBackupRun.Add_Click({ Start-BackupNow })
$btnBackupCancel.Add_Click({
    Write-Log 'Stopping ...' $colorWarn
    Stop-BackupRun -Reason 'you cancelled it'
})
$btnBackupOpen.Add_Click({ Open-BackupFile })
$btnRestoreFiles.Add_Click({ Start-RestoreFiles })
$btnRestoreApps.Add_Click({ Start-RestoreApps })
$btnRestoreContacts.Add_Click({ Start-RestoreContacts })
$btnBackupOpenFolder.Add_Click({ Show-BackupInExplorer })
$btnBackupListRefresh.Add_Click({ Update-BackupList })
$btnBackupListOpen.Add_Click({ Open-BackupFromList })
$btnBackupListShow.Add_Click({ Show-BackupPickedInExplorer })
$btnBackupWhereBrowse.Add_Click({ Select-BackupFolder })
$btnBackupSaveCopy.Add_Click({ Save-BackupPickedFiles })
$lstBackupList.Add_DoubleClick({ Open-BackupFromList })
$btnBackupAppsAll.Add_Click({ Set-BackupAppTicks -On $true })
$btnBackupAppsNone.Add_Click({ Set-BackupAppTicks -On $false })
# a tick is kept by package, so filtering the list does not move it to another app
$lstBackupApps.Add_ItemCheck({
    param($eventSender, $eventArgs)
    $item = $lstBackupApps.Items[$eventArgs.Index]
    $package = "$($item.Tag)"
    if (-not $package) { return }
    if ($eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
        $script:backupAppTicked[$package] = $true
    } else {
        $null = $script:backupAppTicked.Remove($package)
    }
})
$txtBackupAppFind.Add_TextChanged({ $backupAppFindTimer.Stop(); $backupAppFindTimer.Start() })
# a path typed in by hand: Enter reads it, and so does leaving the box
$txtBackupWhere.Add_KeyDown({
    param($eventSender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $eventArgs.SuppressKeyPress = $true
        Set-BackupFolderUi -Folder "$($txtBackupWhere.Text)".Trim() -Remember
    }
})
$txtBackupWhere.Add_Leave({
    if ("$($txtBackupWhere.Text)".Trim() -ne "$(Get-BackupFolderPath)") {
        Set-BackupFolderUi -Folder "$($txtBackupWhere.Text)".Trim() -Remember
    }
})
# a tab is filled when it is looked at, not when the backup is opened
$tabsBackupView.Add_SelectedIndexChanged({ Update-BackupShownTab })
# the find box filters as it is typed, like the log's, after the same pause
$txtBackupFind.Add_TextChanged({ $backupFindTimer.Stop(); $backupFindTimer.Start() })

# --- what every button does, on hover ----------------------------------------
# A button whose words cannot say the whole thing says it here: what it acts
# on, what the phone may refuse, and the key that does the same. Written in
# one place so the wording stays of a piece, and so a new button is easy to
# spot as missing.

$toolTip.SetToolTip($btnRefresh, 'Reads the device list again (F5)')
$toolTip.SetToolTip($btnInfo, 'Writes what this phone says about itself to the log')
$toolTip.SetToolTip($btnDeviceCopy, 'Copies the details box to the clipboard')
$toolTip.SetToolTip($btnReadToggles, 'Asks the phone how each of these is set right now')
$toolTip.SetToolTip($btnPhoneCall, 'Dials the number in the box on the phone')
$toolTip.SetToolTip($btnPhoneEnd, 'Ends the call on the phone')
$toolTip.SetToolTip($btnPhoneSms, 'Opens the phone own SMS app with this number; the phone sends it')
$toolTip.SetToolTip($btnStart, 'Gives the selected phone this PC internet, over the cable')
$toolTip.SetToolTip($btnStop, 'Stops the relay and removes the tunnel from the phone')
$toolTip.SetToolTip($btnTest, 'Asks the phone to fetch something, to see whether the tunnel carries traffic. Ping never works through it')
$toolTip.SetToolTip($btnInstallClient, 'Installs the gnirehtet app on the phone; sharing installs it by itself the first time')
$toolTip.SetToolTip($btnUninstallClient, 'Removes the gnirehtet app from the phone')
$toolTip.SetToolTip($btnTetherOn, 'The phone shares its mobile data with this PC. Many phones refuse this from adb, and then the phone settings page is opened instead')
$toolTip.SetToolTip($btnTetherOff, 'Turns USB tethering off again')
$toolTip.SetToolTip($btnTetherSettings, 'Opens the tethering page on the phone screen')
$toolTip.SetToolTip($btnAdapters, 'Lists the network adapters this PC has from the phone (RNDIS), to see whether tethering arrived')
$toolTip.SetToolTip($btnProxyOff, 'Stops the proxy and puts the Windows proxy setting back as it was')
$toolTip.SetToolTip($btnProxyTest, 'Checks that something really answers on that port through the phone')
$toolTip.SetToolTip($btnListDisplays, 'Lists the displays scrcpy can see on this phone')
$toolTip.SetToolTip($btnBrowseRecord, 'Chooses the file a recording is written to')
$toolTip.SetToolTip($btnListenStop, 'Stops playing the phone sound on this PC')
$toolTip.SetToolTip($btnScrcpy, 'Opens a mirror window for every selected phone, with the options above')
$toolTip.SetToolTip($btnScrcpyShare, 'Starts the internet sharing and the mirror together, in that order')
$toolTip.SetToolTip($btnOtg, 'Drives the phone as a USB keyboard and mouse, with no screen. It restarts the adb server, which drops a running tunnel')
$toolTip.SetToolTip($btnScrcpyClose, 'Closes every scrcpy window this program opened')
$toolTip.SetToolTip($btnShowCommand, 'Writes the exact scrcpy command line to the log, to copy and reuse')
$toolTip.SetToolTip($btnConnect, 'Connects to the address in the box, for a phone on Wi-Fi')
$toolTip.SetToolTip($btnDisconnect, 'Disconnects every phone connected over Wi-Fi')
$toolTip.SetToolTip($btnRestartServer, 'Restarts the adb server: the usual cure when another adb fights over it')
$toolTip.SetToolTip($btnInstallApk, 'Installs an .apk, or a split bundle (.apks, .xapk, .apkm)')
$toolTip.SetToolTip($btnScreenshot, 'Saves a picture of the phone screen into your Pictures folder')
$toolTip.SetToolTip($btnScreenToggle, 'Presses the power key: the screen goes on, or off')
$toolTip.SetToolTip($btnReboot, 'Restarts the phone, after asking')
$toolTip.SetToolTip($btnBattery, 'Writes the battery and network lines to the log')
$toolTip.SetToolTip($btnReverseList, 'Lists the adb reverse tunnels that exist at this moment')
$toolTip.SetToolTip($btnImeList, 'Lists the keyboards installed on the phone')
$toolTip.SetToolTip($btnImeEnable, 'Allows the chosen keyboard to be used')
$toolTip.SetToolTip($btnImeDefault, 'Makes the chosen keyboard the one the phone types with')
$toolTip.SetToolTip($btnDnsRead, 'Reads the private DNS setting, and the resolvers actually in use')
$toolTip.SetToolTip($btnDnsApply, 'Writes the chosen private DNS mode to the phone')
$toolTip.SetToolTip($btnHotspotOff, 'Turns the Wi-Fi hotspot off')
$toolTip.SetToolTip($btnHotspotState, 'Reads whether the hotspot and USB tethering are on')
$toolTip.SetToolTip($btnHotspotSettings, 'Opens the hotspot page on the phone screen')
$toolTip.SetToolTip($btnUsbTetherOff, 'Turns USB tethering off, through the phone own settings page')
$toolTip.SetToolTip($btnCapture, 'Takes a fresh picture of the phone screen')
$toolTip.SetToolTip($btnSaveShot, 'Saves the picture on screen to a file')
$toolTip.SetToolTip($btnKeyBack, 'Presses Back on every selected phone')
$toolTip.SetToolTip($btnKeyHome, 'Presses Home on every selected phone')
$toolTip.SetToolTip($btnKeyRecents, 'Opens the recent apps on every selected phone')
$toolTip.SetToolTip($btnKeyPower, 'Presses the power key: the screen goes on, or off')
$toolTip.SetToolTip($btnKeyVolUp, 'Volume up on every selected phone')
$toolTip.SetToolTip($btnKeyVolDown, 'Volume down on every selected phone')
$toolTip.SetToolTip($btnSendText, 'Types the text in the box on the phone, Arabic included')
$toolTip.SetToolTip($btnAppsRefresh, 'Reads the installed apps again (F5)')
$toolTip.SetToolTip($btnAppLaunch, 'Opens the selected app on the phone')
$toolTip.SetToolTip($btnAppStop, 'Force stops the selected app')
$toolTip.SetToolTip($btnAppInfo, 'Opens the app details page on the phone')
$toolTip.SetToolTip($btnAppUninstall, 'Removes the selected app from the phone, after asking')
$toolTip.SetToolTip($btnAppInstall, 'Installs an .apk, or a split bundle (.apks, .xapk, .apkm)')
$toolTip.SetToolTip($btnAppExport, 'Saves this list as a file on the PC')
$toolTip.SetToolTip($btnContactsRefresh, 'Reads the contacts again (F5)')
$toolTip.SetToolTip($btnContactAdd, 'Adds a contact to the phone')
$toolTip.SetToolTip($btnContactEdit, 'Changes the name or number of the selected contact')
$toolTip.SetToolTip($btnContactDelete, 'Deletes the selected contact from the phone, after asking')
$toolTip.SetToolTip($btnContactCall, 'Dials the selected contact on the phone')
$toolTip.SetToolTip($btnContactEndCall, 'Ends the call on the phone')
$toolTip.SetToolTip($btnContactCopy, 'Copies the selected rows to the clipboard')
$toolTip.SetToolTip($btnContactExport, 'Saves every contact as a file on the PC')
$toolTip.SetToolTip($btnSmsRefresh, 'Reads the messages again (F5)')
$toolTip.SetToolTip($btnSmsSend, 'Hands the message to the phone own SMS app, which sends it. Android has no way for adb to send one itself')
$toolTip.SetToolTip($btnSmsCopy, 'Copies the selected messages to the clipboard')
$toolTip.SetToolTip($btnSmsDelete, 'Deletes the selected message from the phone, after asking')
$toolTip.SetToolTip($btnSmsEdit, 'Changes the text kept for this message on the phone')
$toolTip.SetToolTip($btnSmsExport, 'Saves every message as a file on the PC')
$toolTip.SetToolTip($btnCameraList, 'Asks the phone which cameras it has, and fills the list')
$toolTip.SetToolTip($btnCameraBrowse, 'Chooses the file a camera recording is written to')
$toolTip.SetToolTip($btnCameraStart, 'Opens a window showing the phone camera, with the options here')
$toolTip.SetToolTip($btnCameraFront, 'Opens the front camera in a window')
$toolTip.SetToolTip($btnCameraBack, 'Opens the back camera in a window')
$toolTip.SetToolTip($btnCameraStop, 'Closes the camera window')
$toolTip.SetToolTip($btnCameraCommand, 'Writes the exact scrcpy camera command to the log')
$toolTip.SetToolTip($btnFileUp, 'Goes up one folder (Backspace)')
$toolTip.SetToolTip($btnFileGo, 'Opens the folder typed in the path box (Enter)')
$toolTip.SetToolTip($btnFileSearchClear, 'Clears the search and shows the folder again')
$toolTip.SetToolTip($btnFileLocalBrowse, 'Chooses the PC folder that downloads land in')
$toolTip.SetToolTip($btnFileOpenLocal, 'Opens that PC folder in Explorer')
$toolTip.SetToolTip($btnFileUpload, 'Sends files from the PC into the folder open here')
$toolTip.SetToolTip($btnFileNewDir, 'Makes a new folder on the phone')
$toolTip.SetToolTip($btnFileRename, 'Renames the selected file or folder on the phone')
$toolTip.SetToolTip($btnFileDelete, 'Deletes what is selected from the phone, after asking')
$toolTip.SetToolTip($btnFileOpenPhone, 'Opens the selected file on the phone itself')
$toolTip.SetToolTip($btnFileCopyPath, 'Copies the full path on the phone to the clipboard')
$toolTip.SetToolTip($btnWifiOnTab, 'Turns the phone Wi-Fi on')
$toolTip.SetToolTip($btnWifiOffTab, 'Turns the phone Wi-Fi off')
$toolTip.SetToolTip($btnWifiSaved, 'Lists the networks the phone has saved, instead of what it can see')
$toolTip.SetToolTip($btnWifiConnect, 'Joins the selected network, with the password in the box')
$toolTip.SetToolTip($btnWifiStatus, 'Writes the current Wi-Fi connection to the log')
$toolTip.SetToolTip($btnBtOnTab, 'Turns the phone Bluetooth on')
$toolTip.SetToolTip($btnBtOffTab, 'Turns the phone Bluetooth off')
$toolTip.SetToolTip($btnBtRefresh, 'Reads the paired devices again (F5)')
$toolTip.SetToolTip($btnBtCopy, 'Copies the selected rows to the clipboard')
$toolTip.SetToolTip($btnNfcOn, 'Turns NFC on')
$toolTip.SetToolTip($btnNfcOff, 'Turns NFC off')
$toolTip.SetToolTip($btnNfcRefresh, 'Reads the NFC state again (F5)')
$toolTip.SetToolTip($btnNfcSettings, 'Opens the NFC page on the phone screen')
$toolTip.SetToolTip($btnUsersRefresh, 'Reads the users again (F5)')
$toolTip.SetToolTip($btnUserAdd, 'Adds a user to the phone')
$toolTip.SetToolTip($btnUserRename, 'Renames the selected user. Android usually refuses this from adb')
$toolTip.SetToolTip($btnUserRemove, 'Deletes the selected user and everything in it, after asking')
$toolTip.SetToolTip($btnUserSwitcherOn, 'Shows the user switcher on the phone; the users themselves are kept')
$toolTip.SetToolTip($btnUserSettings, 'Opens the users page on the phone screen')
$toolTip.SetToolTip($btnRunningRefresh, 'Reads the running processes again (F5)')
$toolTip.SetToolTip($btnRunningStop, 'Force stops the selected process, after asking')
$toolTip.SetToolTip($btnRunningInfo, 'Opens the app details page on the phone')
$toolTip.SetToolTip($btnRunningCopy, 'Copies the selected rows to the clipboard')
$toolTip.SetToolTip($btnRunningExport, 'Saves this list as a file on the PC')
$toolTip.SetToolTip($btnLogcatStop, 'Stops reading the phone log')
$toolTip.SetToolTip($btnLogcatSave, 'Saves what is on screen to a file')
$toolTip.SetToolTip($btnShellStart, 'Opens a live shell on the phone; it stays open for command after command')
$toolTip.SetToolTip($btnShellStop, 'Closes the live shell')
$toolTip.SetToolTip($btnShellClear, 'Empties this box; nothing on the phone changes')
$toolTip.SetToolTip($btnShellSend, 'Sends the typed line to the phone (Enter)')
$toolTip.SetToolTip($btnClear, 'Empties the log (Ctrl+L)')
$toolTip.SetToolTip($btnSaveLog, 'Saves everything in the log to a file')
$toolTip.SetToolTip($btnRestoreApps, 'Installs the apps ticked in the list, splits included')

# every list says which button fills it while it is empty
Add-ListHint -List $lstDevices -Text 'No phone yet. Plug one in with USB debugging on, then press Refresh.'
Add-ListHint -List $lstApps -Text 'No apps read yet - press Refresh (F5).'
Add-ListHint -List $lstFiles -Text 'Nothing read yet - pick a phone and press Go.'
Add-ListHint -List $lstContacts -Text 'No contacts read yet - press Refresh (F5).'
Add-ListHint -List $lstSms -Text 'No messages read yet - press Refresh (F5).'
Add-ListHint -List $lstRunning -Text 'No processes read yet - press Refresh (F5).'
Add-ListHint -List $lstWifi -Text 'No networks yet - press Scan, or Saved networks.'
Add-ListHint -List $lstBt -Text 'No paired devices read yet - press Refresh (F5).'
Add-ListHint -List $lstUsers -Text 'No users read yet - press Refresh (F5).'
Add-ListHint -List $lstAutoRules -Text 'No rules yet - pick a phone above, then "Add the selected phone".'
Add-ListHint -List $lstBackupApps -Text 'Open a backup to see the apps in it.'
Add-ListHint -List $lstBackupList -Text 'No backups in this folder.'
Add-ListHint -List $lstBackupInside -Text 'Open a backup to see every file inside it.'

# the folder of the last backup, and what is in it, are there from the start
$txtBackupWhere.Text = Get-BackupFolderPath
Update-BackupList

$form.Add_FormClosing({
    Save-Settings
    # the rules are free for the other window once this one is gone
    Close-Automation
    Close-Tray
    if ($script:workRunspace) {
        try { $script:workRunspace.Close(); $script:workRunspace.Dispose() } catch { }
        $script:workRunspace = $null
    }
    $screenTimer.Stop()
    $runningTimer.Stop()
    Stop-AudioListen
    Stop-LiveShell -Quiet
    Stop-Logcat -Quiet
    # Never leave the machine pointing at a proxy that dies with this window.
    Stop-PhoneProxy -Quiet
    if ($script:relayProcess) { Stop-Sharing -Quiet }
})

$form.Add_Shown({
    Write-Log "AndroidDC $appVersion" $colorInfo
    $busyTimer.Start()
    $deviceWatchTimer.Start()
    Write-Log "adb:       $($script:adbPath)" $colorInfo
    Write-Log "gnirehtet: $($script:gnirehtetPath)" $colorInfo
    Write-Log ("scrcpy:    " + $(if ($script:scrcpyPath) { $script:scrcpyPath } else { 'not found' })) $colorInfo
    # laid out at its real size first: a minimized window has no size to lay out by
    try { $splitMain.SplitterDistance = [int]($form.ClientSize.Width * 0.32) } catch { }
    Convert-WindowToIcons
    Update-RightLayout
    Update-ScreenLayout
    Update-ShellLayout
    Update-LogcatLayout
    Update-ToolsLayout
    if ($Minimized) { $form.WindowState = 'Minimized' }
    $null = Invoke-Adb -CommandArguments @('start-server')
    # the rules set before, so they are known without opening their tab
    Write-AutomationOverview -Where 'Advanced > Automation'
    Update-AutomationTab
    # Tab walks the page as it is laid out, and Enter reads the page again
    $null = Set-TabOrder -Container $splitMain.Panel2
    Set-PageEnterKey
    Update-DeviceList
})

# ------------------------------------------------------------------- main ----

$script:adbPath = Resolve-Tool -FileName 'adb.exe'
$script:gnirehtetPath = Resolve-Tool -FileName 'gnirehtet.exe'
$script:scrcpyPath = Resolve-Tool -FileName 'scrcpy.exe'

# One prompt per package. scrcpy carries adb with it, so that download covers
# both; the GUI only starts once the files are really on disk.
if (-not $script:scrcpyPath -or -not $script:adbPath) {
    if (Install-UpstreamPackage -Package 'scrcpy') {
        $script:scrcpyPath = Resolve-Tool -FileName 'scrcpy.exe'
        $script:adbPath = Resolve-Tool -FileName 'adb.exe'
    }
}

if (-not $script:gnirehtetPath) {
    if (Install-UpstreamPackage -Package 'gnirehtet') {
        $script:gnirehtetPath = Resolve-Tool -FileName 'gnirehtet.exe'
    }
}

$missing = @()
if (-not $script:adbPath) { $missing += 'adb.exe' }
if (-not $script:gnirehtetPath) { $missing += 'gnirehtet.exe' }
if ($missing.Count -gt 0) {
    [void][System.Windows.Forms.MessageBox]::Show(
        ($missing -join ' and ') + " not found next to this script nor in PATH." +
        "`r`n`r`nRun get-upstream.ps1 in that folder to download them.",
        'AndroidDC', 'OK', 'Error')
    return
}

# gnirehtet spawns adb itself; point it at the same binary and APK.
$env:ADB = $script:adbPath
$localApk = Join-Path $scriptRoot 'gnirehtet.apk'
if (Test-Path -LiteralPath $localApk -PathType Leaf) {
    $env:GNIREHTET_APK = (Resolve-Path -LiteralPath $localApk).Path
}

Restore-Settings
Initialize-Automation -ProjectRoot $scriptRoot -CountPresent ([bool]$Minimized)
Initialize-Tray -Title 'AndroidDC' -ProjectRoot $scriptRoot -GetHandle { $form.Handle } -OnExit { $form.Close() } `
    -OnOpenRules { $tabs.SelectedTab = $tabAdvanced; $tabsAdvanced.SelectedTab = $tabAutomation }
Initialize-Backup -Progress { param($Text, $Done, $Total) Set-BackupProgressUi -Text $Text -Done $Done -Total $Total }

try {
    [void]$form.ShowDialog()
} finally {
    Stop-PhoneProxy -Quiet
    if ($script:relayProcess) { Stop-Sharing -Quiet }
    foreach ($file in $script:previewFiles) {
        if ($file -and (Test-Path -LiteralPath $file)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($file in @($script:outFile, $script:errFile)) {
        if ($file -and (Test-Path -LiteralPath $file)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($pattern in @("androiddc-$PID.scrcpy-*", "androiddc-$PID.app-*", "androiddc-$PID.camera.*",
            "androiddc-$PID.pull.png", "androiddc-$PID.relay-*")) {
        Get-ChildItem -Path $env:TEMP -Filter $pattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
