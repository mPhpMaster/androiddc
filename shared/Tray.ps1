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

function Initialize-Tray {
    # Title: the icon's tooltip. GetHandle: returns the window's handle. OnExit:
    # closes the window the normal way, so its settings are saved.
    param([string]$Title, [string]$ProjectRoot, [scriptblock]$GetHandle, [scriptblock]$OnExit)

    $script:trayTitle = $Title
    $script:trayGetHandle = $GetHandle
    $script:trayOnExit = $OnExit
    try {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $file = if ($ProjectRoot) { Join-Path $ProjectRoot 'assets\androiddc.ico' } else { '' }
        $icon.Icon = if ($file -and (Test-Path -LiteralPath $file)) { New-Object System.Drawing.Icon($file) } else { [System.Drawing.SystemIcons]::Application }
        # a tooltip longer than 63 characters throws
        $icon.Text = if ($Title.Length -gt 63) { $Title.Substring(0, 63) } else { $Title }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $showItem = $menu.Items.Add('Show the window')
        $hideItem = $menu.Items.Add('Hide to the tray')
        $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $exitItem = $menu.Items.Add('Exit')
        $showItem.Font = New-Object System.Drawing.Font($showItem.Font, [System.Drawing.FontStyle]::Bold)
        $showItem.Add_Click({ Show-TrayWindow })
        $hideItem.Add_Click({ Hide-TrayWindow })
        $exitItem.Add_Click({ if ($script:trayOnExit) { Show-TrayWindow; & $script:trayOnExit } })
        # only the one that does something now
        $menu.Add_Opening({
            param($sender, $eventArgs)
            $sender.Items[0].Visible = $script:trayHidden
            $sender.Items[1].Visible = -not $script:trayHidden
        })
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
