<#
    AndroidDC - the icon by the clock, for both windows.

    While the program runs there is an AndroidDC icon in the notification area.
    A click on it hides the window or shows it again; its menu says the same and
    has Exit. Minimizing the window hides it there too, so it leaves the taskbar
    but keeps watching for phones and running their rules (shared\Automation.ps1).
    A window started with Windows starts there.

    Hidden and shown with ShowWindow, not Form.Hide / Window.Hide: both windows
    run inside ShowDialog, and taking a modal window off screen the framework's
    way ends that dialog - the program would quit instead of hiding.

    Dot-sourced by androiddc.ps1 and nova\androiddc-nova.ps1; each passes how to
    get its window handle and how to close it the normal way.
#>

if (-not ('AndroidDcTrayNative' -as [type])) {
    Add-Type -Namespace '' -Name 'AndroidDcTrayNative' -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsIconic(IntPtr hWnd);
'@
}

$script:trayIcon = $null
$script:trayHidden = $false
$script:trayTold = $false
$script:trayTitle = 'AndroidDC'
$script:trayGetHandle = $null
$script:trayOnExit = $null
$script:trayOnOpenRules = $null
$script:trayRulesItem = $null
$script:trayShowItem = $null
$script:trayHideItem = $null
$script:trayFtpItem = $null
$script:trayGetFtpState = $null
$script:trayOnOpenFtp = $null
$script:trayOnToggleFtp = $null

function Initialize-Tray {
    # Title: the icon's tooltip. GetHandle: returns the window's handle. OnExit:
    # closes the window the normal way, so its settings are saved. OnOpenRules:
    # opens the page where the rules are set.
    param([string]$Title, [string]$ProjectRoot, [scriptblock]$GetHandle, [scriptblock]$OnExit,
        [scriptblock]$OnOpenRules, [scriptblock]$GetFtpState, [scriptblock]$OnOpenFtp,
        [scriptblock]$OnToggleFtp)

    $script:trayTitle = $Title
    $script:trayGetHandle = $GetHandle
    $script:trayOnExit = $OnExit
    $script:trayOnOpenRules = $OnOpenRules
    $script:trayGetFtpState = $GetFtpState
    $script:trayOnOpenFtp = $OnOpenFtp
    $script:trayOnToggleFtp = $OnToggleFtp
    try {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $file = if ($ProjectRoot) { Join-Path $ProjectRoot 'assets\androiddc.ico' } else { '' }
        $icon.Icon = if ($file -and (Test-Path -LiteralPath $file)) { New-Object System.Drawing.Icon($file) } else { [System.Drawing.SystemIcons]::Application }
        $script:trayIcon = $icon
        Update-TrayText

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        # what is set, read from the rules file each time the menu opens: the
        # other window may have changed it
        $script:trayRulesItem = New-Object System.Windows.Forms.ToolStripMenuItem('Automation')
        $null = $menu.Items.Add($script:trayRulesItem)
        if ($script:trayGetFtpState) {
            $script:trayFtpItem = New-Object System.Windows.Forms.ToolStripMenuItem('FTP')
            $null = $menu.Items.Add($script:trayFtpItem)
        }
        $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $script:trayShowItem = $menu.Items.Add('Show the window')
        $script:trayHideItem = $menu.Items.Add('Hide to the tray')
        $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $exitItem = $menu.Items.Add('Exit')
        $script:trayShowItem.Font = New-Object System.Drawing.Font($script:trayShowItem.Font, [System.Drawing.FontStyle]::Bold)
        $script:trayShowItem.Add_Click({ Show-TrayWindow })
        $script:trayHideItem.Add_Click({ Hide-TrayWindow })
        $exitItem.Add_Click({ if ($script:trayOnExit) { Show-TrayWindow; & $script:trayOnExit } })
        $menu.Add_Opening({ Update-TrayMenu })
        Update-TrayMenu
        $icon.ContextMenuStrip = $menu
        $icon.Add_MouseClick({
            param($sender, $eventArgs)
            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-TrayWindow }
        })
        $icon.Visible = $true
        $script:trayIcon = $icon
    } catch {
        $script:trayIcon = $null
        Write-Log ('The icon by the clock could not be added: ' + $_.Exception.Message) $colorWarn
    }
}

function Update-TrayText {
    # the tooltip: the window, and how many rules are on
    if (-not $script:trayIcon) { return }
    $text = $script:trayTitle
    if (Get-Command Get-AutomationOverview -ErrorAction SilentlyContinue) {
        $overview = Get-AutomationOverview
        $text += if ($overview.On -gt 0) { " - $($overview.On) automation rule(s) on" } else { ' - no automation rules on' }
    }
    # a tooltip longer than 63 characters throws
    $script:trayIcon.Text = if ($text.Length -gt 63) { $text.Substring(0, 63) } else { $text }
}

function Update-TrayMenu {
    # Show or Hide, whichever does something now, and the rules as they are set
    if ($script:trayShowItem) { $script:trayShowItem.Visible = $script:trayHidden }
    if ($script:trayHideItem) { $script:trayHideItem.Visible = -not $script:trayHidden }
    Update-TrayFtpMenu
    $rulesItem = $script:trayRulesItem
    if (-not $rulesItem) { return }
    if (-not (Get-Command Get-AutomationOverview -ErrorAction SilentlyContinue)) { $rulesItem.Visible = $false; return }

    $overview = Get-AutomationOverview
    $rulesItem.Text = $overview.Title
    $rulesItem.DropDownItems.Clear()
    foreach ($line in $overview.Lines) {
        $shown = if ($line.Length -gt 110) { $line.Substring(0, 107) + '...' } else { $line }
        $entry = $rulesItem.DropDownItems.Add($shown)
        $entry.ToolTipText = $line
        $entry.Add_Click({ Open-TrayRules })
    }
    if ($overview.Count -eq 0) {
        $none = $rulesItem.DropDownItems.Add('No phone has a rule yet')
        $none.Enabled = $false
    }
    $null = $rulesItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $open = $rulesItem.DropDownItems.Add('Open the rules ...')
    $open.Font = New-Object System.Drawing.Font($open.Font, [System.Drawing.FontStyle]::Bold)
    $open.Add_Click({ Open-TrayRules })
    Update-TrayText
}

function Update-TrayFtpMenu {
    if (-not $script:trayFtpItem -or -not $script:trayGetFtpState) { return }
    $state = try { & $script:trayGetFtpState } catch { 'No phone' }
    if (@('Running', 'Off') -notcontains $state) { $state = 'No phone' }
    $script:trayFtpItem.Text = "FTP: $($state.ToLowerInvariant())"
    $script:trayFtpItem.DropDownItems.Clear()
    $open = $script:trayFtpItem.DropDownItems.Add('Open FTP page')
    $open.Add_Click({ Open-TrayFtp })
    $toggle = $script:trayFtpItem.DropDownItems.Add($(if ($state -eq 'Running') { 'Stop server ...' } else { 'Start server ...' }))
    $toggle.Enabled = $state -ne 'No phone'
    $toggle.Add_Click({ Invoke-TrayFtpToggle })
}

function Open-TrayFtp {
    Show-TrayWindow
    if ($script:trayOnOpenFtp) { & $script:trayOnOpenFtp }
}

function Invoke-TrayFtpToggle {
    Show-TrayWindow
    if ($script:trayOnToggleFtp) { & $script:trayOnToggleFtp }
    Update-TrayFtpMenu
}

function Open-TrayRules {
    # the window on screen, at the page where the rules are set
    Show-TrayWindow
    if ($script:trayOnOpenRules) { & $script:trayOnOpenRules }
}

function Get-TrayHandle {
    if (-not $script:trayGetHandle) { return [IntPtr]::Zero }
    try { return [IntPtr](& $script:trayGetHandle) } catch { return [IntPtr]::Zero }
}

function Test-TrayHidden {
    # true while the window is hidden in the tray
    return $script:trayHidden
}

function Hide-TrayWindow {
    # off the screen and off the taskbar; the program keeps running
    if (-not $script:trayIcon) { return }
    $handle = Get-TrayHandle
    if ($handle -eq [IntPtr]::Zero) { return }
    $null = [AndroidDcTrayNative]::ShowWindow($handle, 0)   # SW_HIDE
    $script:trayHidden = $true
    if (-not $script:trayTold) {
        # said once a session: a window that vanished looks like one that quit
        $script:trayTold = $true
        Show-TrayBalloon -Title $script:trayTitle -Text 'Still running here. Click the icon to show the window again.'
    }
}

function Show-TrayWindow {
    # back on screen as it was - restored if it had been minimized - and in front
    $handle = Get-TrayHandle
    if ($handle -eq [IntPtr]::Zero) { return }
    if ([AndroidDcTrayNative]::IsIconic($handle)) {
        $null = [AndroidDcTrayNative]::ShowWindow($handle, 9)   # SW_RESTORE
    } else {
        $null = [AndroidDcTrayNative]::ShowWindow($handle, 5)   # SW_SHOW
    }
    $null = [AndroidDcTrayNative]::SetForegroundWindow($handle)
    $script:trayHidden = $false
}

function Switch-TrayWindow {
    if ($script:trayHidden) { Show-TrayWindow } else { Hide-TrayWindow }
}

function Show-TrayBalloon {
    # a notification from the tray icon; false when there is no icon
    param([string]$Title, [string]$Text)

    if (-not $script:trayIcon) { return $false }
    try {
        $script:trayIcon.ShowBalloonTip(6000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
        return $true
    } catch {
        return $false
    }
}

function Close-Tray {
    # when the window closes: an icon left behind stays until the mouse passes over it
    if ($script:trayIcon) {
        try { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } catch { }
        $script:trayIcon = $null
    }
}
