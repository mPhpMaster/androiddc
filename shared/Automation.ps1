<#
    AndroidDC - what both windows share for automation.

    Two things live here, and neither touches a control:

      * starting with Windows: one value under the user's Run key, pointing at
        androiddc.vbs or androiddc-nova.vbs with -Minimized;
      * rules: "when this phone is plugged in, do these things", kept in
        %APPDATA%\AndroidDC\automation.json so the classic window and Nova
        read and write the same rules.

    Dot-sourced by androiddc.ps1 and by nova\androiddc-nova.ps1. The actions
    call the windows' own functions by name - both windows use the same names
    (Set-UsbTethering, Start-Scrcpy, ...) - and act on the selected phone, so
    each window passes a script block that selects the rule's phone first.

    Only one window runs rules at a time: the first to take a named mutex.
    Tests point ANDROIDDC_AUTOMATION_FILE, ANDROIDDC_RUN_KEY and
    ANDROIDDC_AUTOMATION_MUTEX somewhere else, so they never touch the real
    rules, the real Run key, or a window the user has open.
#>

$script:automationFile = if ($env:ANDROIDDC_AUTOMATION_FILE) { $env:ANDROIDDC_AUTOMATION_FILE } else {
    Join-Path $env:APPDATA 'AndroidDC\automation.json' }
$script:automationRunKey = if ($env:ANDROIDDC_RUN_KEY) { $env:ANDROIDDC_RUN_KEY } else {
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
$script:automationRunName = 'AndroidDC'
$script:automationMutexName = if ($env:ANDROIDDC_AUTOMATION_MUTEX) { $env:ANDROIDDC_AUTOMATION_MUTEX } else {
    'Local\AndroidDC.Automation' }

$script:automationMutex = $null
$script:automationOwner = $false
$script:automationProjectRoot = $null
$script:automationCountPresent = $false
$script:automationPrimed = $false
# the ready serials at the last list read, so a phone that just arrived is told apart
$script:automationSeen = @()
$script:automationQueue = New-Object System.Collections.ArrayList
$script:automationRunning = $false
$script:automationNotifier = $null

function Initialize-Automation {
    # ProjectRoot: the folder with the launchers and assets\. CountPresent: phones
    # already attached at the first read count as plugged in - true when the
    # window was started with Windows, so a phone left in the cable still gets
    # its rule; a window opened by hand, or by the other window's switch button,
    # does not run the rules again for phones that were already there.
    param([string]$ProjectRoot, [bool]$CountPresent)

    $script:automationProjectRoot = $ProjectRoot
    $script:automationCountPresent = $CountPresent
}

# ---------------------------------------------------------------- actions ----

function Get-AutomationActionList {
    # Every action a rule can hold. Command is the window function it needs; a
    # window that does not have it (a Nova test that loads a few pages) says so
    # instead of failing. Run gets the serial and the action's value.
    if ($script:automationActionList) { return $script:automationActionList }

    # A rule runs its actions in this order, so waking the screen comes first:
    # USB tethering and the hotspot fall back to tapping the phone's settings,
    # which needs the screen on.
    $list = @(
        [PSCustomObject]@{ Id = 'wake'; Group = 'Screen'; Command = 'Invoke-DeviceShell'
            Label = 'Wake the screen'
            Run = { param($Serial, $Value)
                $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('input', 'keyevent', '224')
                Write-Log "Woke the screen of $Serial." $colorInfo } }

        [PSCustomObject]@{ Id = 'usb-tether-on'; Group = 'Internet'; Command = 'Set-UsbTethering'
            Label = "Share the phone's internet with the PC (USB tethering on)"
            Run = { param($Serial, $Value) Set-UsbTethering -On $true } }
        [PSCustomObject]@{ Id = 'usb-tether-off'; Group = 'Internet'; Command = 'Set-UsbTethering'
            Label = 'USB tethering off'
            Run = { param($Serial, $Value) Set-UsbTethering -On $false } }
        [PSCustomObject]@{ Id = 'share-pc'; Group = 'Internet'; Command = 'Start-Sharing'
            Label = "Share the PC's internet with the phone (gnirehtet)"
            Run = { param($Serial, $Value) Start-Sharing } }
        [PSCustomObject]@{ Id = 'phone-proxy'; Group = 'Internet'; Command = 'Start-PhoneProxy'
            Label = "Use the phone's data on the PC through the adb proxy"
            Run = { param($Serial, $Value) Start-PhoneProxy } }
        [PSCustomObject]@{ Id = 'hotspot-on'; Group = 'Internet'; Command = 'Set-Hotspot'
            Label = 'Wi-Fi hotspot on'
            Run = { param($Serial, $Value) Set-Hotspot -On $true } }
        [PSCustomObject]@{ Id = 'hotspot-off'; Group = 'Internet'; Command = 'Set-Hotspot'
            Label = 'Wi-Fi hotspot off'
            Run = { param($Serial, $Value) Set-Hotspot -On $false } }
        [PSCustomObject]@{ Id = 'wireless-adb'; Group = 'Internet'; Command = 'Enable-WirelessAdb'
            Label = 'adb over Wi-Fi (tcpip 5555, then connect)'
            Run = { param($Serial, $Value) Enable-WirelessAdb } }

        [PSCustomObject]@{ Id = 'mirror'; Group = 'Screen'; Command = 'Start-Scrcpy'
            Label = 'Mirror the screen (scrcpy, with the Mirroring options)'
            Run = { param($Serial, $Value) Start-Scrcpy } }
        [PSCustomObject]@{ Id = 'camera-back'; Group = 'Screen'; Command = 'Start-Camera'
            Label = 'Back camera in a window'
            Run = { param($Serial, $Value) Start-Camera -Facing 'back' } }
        [PSCustomObject]@{ Id = 'camera-front'; Group = 'Screen'; Command = 'Start-Camera'
            Label = 'Front camera in a window'
            Run = { param($Serial, $Value) Start-Camera -Facing 'front' } }
        [PSCustomObject]@{ Id = 'audio'; Group = 'Screen'; Command = 'Start-AudioListen'
            Label = "Play the phone's sound on the PC"
            Run = { param($Serial, $Value) Start-AudioListen } }
        [PSCustomObject]@{ Id = 'screenshot'; Group = 'Screen'; Command = 'Get-OneScreenshot'
            Label = 'Save a screenshot to Pictures'
            Run = { param($Serial, $Value) Get-OneScreenshot -Serial $Serial } }

        [PSCustomObject]@{ Id = 'wifi-on'; Group = 'Radios'; Command = 'Set-WifiRadio'
            Label = 'Wi-Fi on'; Run = { param($Serial, $Value) Set-WifiRadio -On $true } }
        [PSCustomObject]@{ Id = 'wifi-off'; Group = 'Radios'; Command = 'Set-WifiRadio'
            Label = 'Wi-Fi off'; Run = { param($Serial, $Value) Set-WifiRadio -On $false } }
        [PSCustomObject]@{ Id = 'bluetooth-on'; Group = 'Radios'; Command = 'Set-BluetoothRadio'
            Label = 'Bluetooth on'; Run = { param($Serial, $Value) Set-BluetoothRadio -On $true } }
        [PSCustomObject]@{ Id = 'bluetooth-off'; Group = 'Radios'; Command = 'Set-BluetoothRadio'
            Label = 'Bluetooth off'; Run = { param($Serial, $Value) Set-BluetoothRadio -On $false } }
        [PSCustomObject]@{ Id = 'nfc-on'; Group = 'Radios'; Command = 'Set-NfcRadio'
            Label = 'NFC on'; Run = { param($Serial, $Value) Set-NfcRadio -On $true } }
        [PSCustomObject]@{ Id = 'nfc-off'; Group = 'Radios'; Command = 'Set-NfcRadio'
            Label = 'NFC off'; Run = { param($Serial, $Value) Set-NfcRadio -On $false } }

        [PSCustomObject]@{ Id = 'stayawake-on'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Stay awake while charging on'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'stayawake' -Enabled $true } }
        [PSCustomObject]@{ Id = 'stayawake-off'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Stay awake while charging off'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'stayawake' -Enabled $false } }
        [PSCustomObject]@{ Id = 'rotation-on'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Auto-rotate on'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'rotation' -Enabled $true } }
        [PSCustomObject]@{ Id = 'rotation-off'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Auto-rotate off'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'rotation' -Enabled $false } }
        [PSCustomObject]@{ Id = 'location-on'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Location on'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'location' -Enabled $true } }
        [PSCustomObject]@{ Id = 'location-off'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Location off'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'location' -Enabled $false } }
        [PSCustomObject]@{ Id = 'saver-on'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Battery saver on'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'saver' -Enabled $true } }
        [PSCustomObject]@{ Id = 'saver-off'; Group = 'Settings'; Command = 'Set-DeviceToggle'
            Label = 'Battery saver off'; Run = { param($Serial, $Value) Set-DeviceToggle -Feature 'saver' -Enabled $false } }

        [PSCustomObject]@{ Id = 'app'; Group = 'Other'; Command = 'Get-LauncherActivity'
            Label = 'Open an app (its package name below)'
            Run = { param($Serial, $Value) Start-AutomationApp -Serial $Serial -Package $Value } }
        [PSCustomObject]@{ Id = 'buzz'; Group = 'Other'; Command = 'Send-Buzz'
            Label = 'Vibrate the phone'; Run = { param($Serial, $Value) Send-Buzz } }
        [PSCustomObject]@{ Id = 'logcat'; Group = 'Other'; Command = 'Start-Logcat'
            Label = 'Start logcat'; Run = { param($Serial, $Value) Start-Logcat } }
        [PSCustomObject]@{ Id = 'notify'; Group = 'Other'; Command = ''
            Label = 'A Windows notification that the phone is connected'
            Run = { param($Serial, $Value) Show-AutomationNotice -Title 'AndroidDC' -Text "$Value is connected." } }
    )
    $script:automationActionList = $list
    return $list
}
$script:automationActionList = $null

function Get-AutomationAction {
    param([string]$Id)
    foreach ($action in (Get-AutomationActionList)) { if ($action.Id -eq $Id) { return $action } }
    return $null
}

function Start-AutomationApp {
    # the same launch the Apps page does, for a package named in the rule
    param([string]$Serial, [string]$Package)

    $Package = "$Package".Trim()
    if ($Package -notmatch '^[A-Za-z][\w]*(\.[\w]+)+$') {
        Write-Log "Automation: '$Package' is not a package name (like com.example.app)." $colorWarn
        return
    }
    $activity = Get-LauncherActivity -Serial $Serial -Package $Package
    if (-not $activity) { Write-Log "$Package has no launcher activity on $Serial." $colorWarn; return }
    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('am', 'start', '-n', $activity)
    Write-Log ("$Package -> " + $result.Text.Trim()) $(if ($result.Text -match 'Error') { $colorBad } else { $colorGood })
}

function Show-AutomationNotice {
    # a balloon from the notification area; the icon stays until the window closes
    param([string]$Title, [string]$Text)

    # from the window's own icon by the clock when there is one (shared\Tray.ps1)
    if ((Get-Command Show-TrayBalloon -ErrorAction SilentlyContinue) -and (Show-TrayBalloon -Title $Title -Text $Text)) { return }
    try {
        if (-not $script:automationNotifier) {
            $notifier = New-Object System.Windows.Forms.NotifyIcon
            $icon = if ($script:automationProjectRoot) { Join-Path $script:automationProjectRoot 'assets\androiddc.ico' } else { '' }
            $notifier.Icon = if ($icon -and (Test-Path -LiteralPath $icon)) { New-Object System.Drawing.Icon($icon) } else { [System.Drawing.SystemIcons]::Information }
            $notifier.Text = 'AndroidDC'
            $script:automationNotifier = $notifier
        }
        $script:automationNotifier.Visible = $true
        $script:automationNotifier.ShowBalloonTip(6000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        Write-Log ('Automation: the notification could not be shown: ' + $_.Exception.Message) $colorWarn
    }
}

function Close-Automation {
    # when the window closes: the notification icon goes, and the rules are free
    # for the other window to run
    if ($script:automationNotifier) {
        try { $script:automationNotifier.Visible = $false; $script:automationNotifier.Dispose() } catch { }
        $script:automationNotifier = $null
    }
    if ($script:automationMutex) {
        if ($script:automationOwner) { try { $script:automationMutex.ReleaseMutex() } catch { } }
        try { $script:automationMutex.Dispose() } catch { }
        $script:automationMutex = $null
        $script:automationOwner = $false
    }
}

# ------------------------------------------------------------------ rules ----

function ConvertTo-AutomationRule {
    # one rule, whatever the file held: missing fields get their defaults
    param($Source)

    $actions = @()
    if ($Source.PSObject.Properties['Actions']) {
        foreach ($entry in @($Source.Actions)) {
            if ($null -eq $entry) { continue }
            $id = if ($entry -is [string]) { $entry } elseif ($entry.PSObject.Properties['Id']) { "$($entry.Id)" } else { '' }
            if (-not $id) { continue }
            $value = if ($entry -isnot [string] -and $entry.PSObject.Properties['Value']) { "$($entry.Value)" } else { '' }
            $actions += [PSCustomObject]@{ Id = $id; Value = $value }
        }
    }
    $serial = if ($Source.PSObject.Properties['Serial']) { "$($Source.Serial)" } else { '' }
    $name = if ($Source.PSObject.Properties['Name'] -and "$($Source.Name)") { "$($Source.Name)" } else { $serial }
    $enabled = if ($Source.PSObject.Properties['Enabled']) { [bool]$Source.Enabled } else { $true }
    return [PSCustomObject]@{ Serial = $serial; Name = $name; Enabled = $enabled; Actions = $actions }
}

function Read-AutomationRules {
    # every rule in the file; none when there is no file yet. A file that cannot
    # be read is reported once and left alone, so a typo does not wipe it.
    $script:automationReadError = ''
    if (-not (Test-Path -LiteralPath $script:automationFile -PathType Leaf)) { return @() }
    try {
        $data = Get-Content -LiteralPath $script:automationFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $script:automationReadError = $_.Exception.Message
        return @()
    }
    if ($null -eq $data -or -not $data.PSObject.Properties['Rules']) { return @() }
    $rules = @()
    foreach ($entry in @($data.Rules)) {
        if ($null -eq $entry) { continue }
        $rule = ConvertTo-AutomationRule -Source $entry
        if ($rule.Serial) { $rules += $rule }
    }
    return $rules
}
$script:automationReadError = ''

function Get-AutomationReadError {
    # why the rules file could not be read the last time, or ''
    return $script:automationReadError
}

function Save-AutomationRules {
    # written at once, not when the window closes: the other window reads the same file
    param($Rules)

    if ($script:automationReadError) {
        Write-Log ("Automation: $($script:automationFile) could not be read, so it is not overwritten: " +
            $script:automationReadError) $colorBad
        return $false
    }
    $folder = Split-Path -Parent $script:automationFile
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
    $list = @(@($Rules) | Where-Object { $null -ne $_ } | ForEach-Object {
        [ordered]@{ Serial = $_.Serial; Name = $_.Name; Enabled = [bool]$_.Enabled
            Actions = @(@($_.Actions) | ForEach-Object { [ordered]@{ Id = $_.Id; Value = "$($_.Value)" } }) }
    })
    # -InputObject, not a pipe: a pipe unrolls a one-rule list into one object
    $json = ConvertTo-Json -InputObject ([ordered]@{ Version = 1; Rules = $list }) -Depth 6
    try {
        [System.IO.File]::WriteAllText($script:automationFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Log ('Automation: the rules could not be saved: ' + $_.Exception.Message) $colorBad
        return $false
    }
}

function Get-AutomationRule {
    param($Rules, [string]$Serial)
    foreach ($rule in @($Rules)) { if ($null -ne $rule -and $rule.Serial -eq $Serial) { return $rule } }
    return $null
}

function Get-AutomationRuleSummary {
    # the actions of a rule in a few words, for the list
    param($Rule)

    $labels = @()
    foreach ($entry in @($Rule.Actions)) {
        $action = Get-AutomationAction -Id $entry.Id
        $text = if ($action) { $action.Label } else { "$($entry.Id) (unknown)" }
        if ($entry.Id -eq 'app' -and $entry.Value) { $text = "Open $($entry.Value)" }
        $labels += $text
    }
    if ($labels.Count -eq 0) { return 'nothing yet' }
    return ($labels -join '; ')
}

# ------------------------------------------------------ start with Windows ----

function Get-AutomationStartup {
    # 'classic', 'nova', or '' when AndroidDC does not start with Windows
    try {
        $value = (Get-ItemProperty -LiteralPath $script:automationRunKey -Name $script:automationRunName -ErrorAction Stop).($script:automationRunName)
    } catch {
        return ''
    }
    if ("$value" -match 'androiddc-nova\.vbs') { return 'nova' }
    if ("$value" -match 'androiddc\.vbs') { return 'classic' }
    return ''
}

function Set-AutomationStartup {
    # Window '' removes the entry. Only this program's own value is written or
    # removed; nothing else under the key is read or changed.
    param([ValidateSet('', 'classic', 'nova')][string]$Window)

    if (-not $Window) {
        try {
            if ($null -ne (Get-ItemProperty -LiteralPath $script:automationRunKey -Name $script:automationRunName -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -LiteralPath $script:automationRunKey -Name $script:automationRunName -ErrorAction Stop
            }
            Write-Log 'AndroidDC no longer starts with Windows.' $colorInfo
            return $true
        } catch {
            Write-Log ('Could not remove the start-with-Windows entry: ' + $_.Exception.Message) $colorBad
            return $false
        }
    }

    $launcherName = if ($Window -eq 'nova') { 'androiddc-nova.vbs' } else { 'androiddc.vbs' }
    $launcher = Join-Path "$script:automationProjectRoot" $launcherName
    if (-not $script:automationProjectRoot -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-Log "Cannot start with Windows: $launcherName was not found in the project folder." $colorBad
        return $false
    }
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $command = '"' + $wscript + '" "' + $launcher + '" -Minimized'
    try {
        # created only when it is not there: -Force on a key that exists would empty it
        if (-not (Test-Path -LiteralPath $script:automationRunKey)) { $null = New-Item -Path $script:automationRunKey -Force }
        Set-ItemProperty -LiteralPath $script:automationRunKey -Name $script:automationRunName -Value $command -ErrorAction Stop
        $which = if ($Window -eq 'nova') { 'the Nova window' } else { 'the classic window' }
        Write-Log "AndroidDC starts with Windows, minimized, in $which." $colorGood
        return $true
    } catch {
        Write-Log ('Could not write the start-with-Windows entry: ' + $_.Exception.Message) $colorBad
        return $false
    }
}

# ------------------------------------------------------------------ runner ----

function Test-AutomationOwner {
    # true when this window runs the rules: the first window to ask takes a named
    # mutex and keeps it until it closes; another window asks again on each read
    if ($script:automationOwner) { return $true }
    try {
        if (-not $script:automationMutex) {
            $script:automationMutex = New-Object System.Threading.Mutex($false, $script:automationMutexName)
        }
        $script:automationOwner = $script:automationMutex.WaitOne(0)
    } catch {
        # a window that ended without releasing it leaves it abandoned - and ours
        $inner = $_.Exception
        while ($inner -and $inner -isnot [System.Threading.AbandonedMutexException]) { $inner = $inner.InnerException }
        $script:automationOwner = ($null -ne $inner)
    }
    return $script:automationOwner
}

function Register-AutomationArrivals {
    # Called with what adb reported on every read of the device list. Returns the
    # serials that just became ready and queues those with a rule that is on.
    param($Devices)

    $ready = @(@($Devices) | Where-Object { $null -ne $_ -and $_.State -eq 'device' } | ForEach-Object { "$($_.Serial)" })
    $arrived = @($ready | Where-Object { $script:automationSeen -notcontains $_ })
    $script:automationSeen = $ready
    if (-not $script:automationPrimed) {
        $script:automationPrimed = $true
        if (-not $script:automationCountPresent) { return @() }
    }
    if ($arrived.Count -eq 0 -or -not (Test-AutomationOwner)) { return $arrived }

    $rules = @(Read-AutomationRules)
    foreach ($serial in $arrived) {
        $rule = Get-AutomationRule -Rules $rules -Serial $serial
        if ($null -eq $rule -or -not $rule.Enabled -or @($rule.Actions).Count -eq 0) { continue }
        if ($script:automationQueue -notcontains $serial) { $null = $script:automationQueue.Add($serial) }
    }
    return $arrived
}

function Invoke-AutomationQueue {
    # the next queued phone's rule, if nothing else is running; called from the
    # windows' device watch
    param([scriptblock]$Enter, [scriptblock]$Leave)

    if ($script:automationRunning -or $script:automationQueue.Count -eq 0 -or $script:busy -gt 0) { return }
    $serial = "$($script:automationQueue[0])"
    $script:automationQueue.RemoveAt(0)
    if ($script:automationSeen -notcontains $serial) { return }
    $rule = Get-AutomationRule -Rules @(Read-AutomationRules) -Serial $serial
    if ($null -eq $rule -or -not $rule.Enabled) { return }
    Invoke-AutomationRule -Rule $rule -Enter $Enter -Leave $Leave
}

function Invoke-AutomationRule {
    # every action of one rule, in order. Enter selects the rule's phone (and
    # returns what Leave needs to put back); one failing action does not stop
    # the ones after it.
    param($Rule, [scriptblock]$Enter, [scriptblock]$Leave)

    if ($script:automationRunning) { Write-Log 'Automation: a rule is already running.' $colorWarn; return }
    $script:automationRunning = $true
    $state = $null
    try {
        $actions = @($Rule.Actions)
        Write-Log ("Automation: $($Rule.Name) ($($Rule.Serial)) - $($actions.Count) action(s).") $colorStep
        $state = & $Enter $Rule.Serial
        if ($state -is [bool] -and -not $state) {
            Write-Log "Automation: $($Rule.Serial) is not in the device list, nothing was run." $colorWarn
            return
        }
        foreach ($entry in $actions) {
            $action = Get-AutomationAction -Id $entry.Id
            if (-not $action) { Write-Log "Automation: unknown action '$($entry.Id)', skipped." $colorWarn; continue }
            if ($action.Command -and -not (Get-Command $action.Command -ErrorAction SilentlyContinue)) {
                Write-Log "Automation: '$($action.Label)' is not available in this window, skipped." $colorWarn
                continue
            }
            $value = if ($entry.Id -eq 'notify' -and -not $entry.Value) { $Rule.Name } else { "$($entry.Value)" }
            Write-Log "Automation: $($action.Label)" $colorStep
            try {
                & $action.Run $Rule.Serial $value
            } catch {
                Write-Log ("Automation: '$($action.Label)' failed: " + $_.Exception.Message) $colorBad
            }
        }
        Write-Log "Automation: $($Rule.Name) done." $colorGood
    } finally {
        if ($Leave) { try { & $Leave $state } catch { } }
        $script:automationRunning = $false
    }
}
