# pages\Clipboard.ps1 - what is copied here and on the phone, kept together.
# The sharing itself is ..\shared\Clipboard.ps1, which the classic window uses
# as well (Advanced > Clipboard); this page turns it on, sends and fetches on
# demand, and shows everything that moved.

$clipboardPage = Register-Page -Key 'clipboard' -Title 'Clipboard' -Glyph 'E8C8' -Section 'Workspace' `
    -Xaml 'Clipboard.xaml' -OnShow { Update-ClipboardPage } -OnDeviceChanged { Update-ClipboardPage } `
    -Refresh { Update-ClipboardPage; Update-ClipboardPageList }

# the watch only runs while sharing is on; it is made here so that a page that
# was never opened still has it
$script:clipboardTimer = $null

function Test-ClipboardShared {
    # shared\Clipboard.ps1 was found and loaded
    return [bool](Get-Command Start-ClipboardShare -ErrorAction SilentlyContinue)
}

function Update-ClipboardPage {
    if (-not (Test-ClipboardShared)) {
        $ui.ClipboardState.Text = 'shared\Clipboard.ps1 is not in the project folder: nothing can be shared from here.'
        foreach ($name in @('ClipboardStart', 'ClipboardStop', 'ClipboardSend', 'ClipboardTake')) {
            $ui[$name].IsEnabled = $false
        }
        return
    }
    $shares = @(Get-ClipboardShares)
    $on = $shares.Count -gt 0
    $ui.ClipboardStart.IsEnabled = -not $on
    $ui.ClipboardStop.IsEnabled = $on
    if (-not $on) {
        $ui.ClipboardState.Text = 'Not sharing.'
        Update-ClipboardHeader
        return
    }
    $words = @()
    foreach ($share in $shares) {
        $who = $(if ("$($share.Model)") { "$($share.Model)" } else { $share.Serial })
        $words += "$who ($($share.Route))"
    }
    $ui.ClipboardState.Text = 'Sharing with ' + ($words -join ', ')
    Update-ClipboardHeader
}

function Update-ClipboardHeader {
    # the pill in the header: on, off, or gone when there is no phone
    $device = Get-SelectedDevice
    if (-not $device -or $device.State -ne 'device' -or -not (Test-ClipboardShared)) {
        $ui.PillClipboard.Visibility = 'Collapsed'
        return
    }
    if (Test-ClipboardSharing) {
        Set-StatusPill $ui.PillClipboard $ui.PillClipboardText 'clipboard on' 'ok'
        $ui.PillClipboardGlyph.Foreground = Get-Resource 'Success'
        $ui.PillClipboard.ToolTip = 'Sharing the clipboard. Click to open the page, right-click to stop.'
    } else {
        Set-StatusPill $ui.PillClipboard $ui.PillClipboardText 'clipboard off' 'plain'
        $ui.PillClipboardGlyph.Foreground = Get-Resource 'MutedText'
        $ui.PillClipboard.ToolTip = 'Click to open the Clipboard page. Right-click to start sharing with the phones picked.'
    }
}

function Invoke-ClipboardHeaderToggle {
    # the right-click on the pill: on when it is off, off when it is on
    if (Test-ClipboardSharing) { Stop-ClipboardPageSharing } else { Start-ClipboardPageSharing }
}

function Update-ClipboardPageList {
    $ui.ClipboardList.ItemsSource = @(Get-ClipboardEvents)
}

function Start-ClipboardPageSharing {
    if (-not (Test-ClipboardShared)) { return }
    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    $started = 0
    foreach ($serial in $serials) {
        $model = ''
        foreach ($row in @($script:deviceRows)) { if ($row.Serial -eq $serial) { $model = "$($row.Model)" } }
        if (Start-ClipboardShare -Serial $serial -Model $model) { $started++ }
    }
    if ($started -eq 0) { Update-ClipboardPage; return }

    # the first turn only learns what is already on this PC's clipboard
    $null = Invoke-ClipboardTick -Quiet
    if (-not $script:clipboardTimer) {
        $script:clipboardTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:clipboardTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $script:clipboardTimer.Add_Tick({
            if ($script:busy -gt 0) { return }
            if (-not (Test-ClipboardSharing)) {
                $script:clipboardTimer.Stop()
                Update-ClipboardPage
                return
            }
            $events = @(Invoke-ClipboardTick)
            if ($events.Count -gt 0) { Update-ClipboardPageList }
            if (-not (Test-ClipboardSharing)) { Update-ClipboardPage }
        })
    }
    $script:clipboardTimer.Start()
    Update-ClipboardPage
    Show-Toast -Text 'Clipboard sharing is on' -Color 'good'
}

function Stop-ClipboardPageSharing {
    if ($script:clipboardTimer) { $script:clipboardTimer.Stop() }
    Stop-AllClipboardShares
    Update-ClipboardPage
}

function Send-ClipboardPageNow {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $one = Send-ClipboardToPhone -Serial $serial -TypeWhenShut:([bool]$ui.ClipboardType.IsChecked)
    if ($one) { Update-ClipboardPageList }
}

function Receive-ClipboardPageNow {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $one = Receive-ClipboardFromPhone -Serial $serial
    if ($one) { Update-ClipboardPageList }
}

function Copy-ClipboardPageRow {
    $one = $ui.ClipboardList.SelectedItem
    if (-not $one) { Write-Log 'Pick a line in the list first.' $colorWarn; return }
    if (Set-ClipboardHere -Text $one.Text) {
        Write-Log "Clipboard: $($one.Chars) character(s) put back on this PC." $colorGood
        Show-Toast -Text 'Back on this PC' -Color 'good'
    }
}

# ------------------------------------------------------------------ events ----

$ui.ClipboardStart.Add_Click({ Start-ClipboardPageSharing })
$ui.ClipboardStop.Add_Click({ Stop-ClipboardPageSharing })
$ui.ClipboardSend.Add_Click({ Send-ClipboardPageNow })
$ui.ClipboardTake.Add_Click({ Receive-ClipboardPageNow })
$ui.ClipboardCopy.Add_Click({ Copy-ClipboardPageRow })
$ui.ClipboardClear.Add_Click({ Clear-ClipboardEvents; Update-ClipboardPageList })
$ui.ClipboardList.Add_MouseDoubleClick({ Copy-ClipboardPageRow })
$ui.PillClipboard.Add_MouseLeftButtonUp({ Show-Page -Page 'clipboard' })
$ui.PillClipboard.Add_MouseRightButtonUp({ Invoke-ClipboardHeaderToggle })

# the watch holds a scrcpy connection open while it runs: it goes with the window
Register-Cleanup {
    if ($script:clipboardTimer) { try { $script:clipboardTimer.Stop() } catch { } }
    if (Get-Command Stop-AllClipboardShares -ErrorAction SilentlyContinue) { Stop-AllClipboardShares }
}

Update-ClipboardPage
