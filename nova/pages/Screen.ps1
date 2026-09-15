# pages\Screen.ps1 - the phone screen: a screenshot that fills the page, the
# phone's keys, typing on the phone, and clicks on the picture sent back as
# taps, swipes and long presses. Ported from the "Phone screen" frame.

$screenPage = Register-Page -Key 'screen' -Title 'Screen' -Glyph 'E7F4' -Section 'Workspace' -Xaml 'Screen.xaml' `
    -OnShow { Show-ScreenPage } -OnDeviceChanged { Update-ScreenForDevice } -Refresh { Update-Capture }

# the picture on screen: the frozen bitmap, the PNG bytes it came from (Save
# writes those unchanged), and the phone it belongs to
$script:captureImage = $null
$script:captureBytes = $null
$script:captureSize = $null
$script:captureSerial = $null
$script:capturing = $false
$script:captureCount = 0
$script:screenPressPoint = $null
$script:screenPressTime = $null

# ------------------------------------------------------------- the picture ----

function Test-ScreenPngHeader {
    # the first four bytes of every PNG: 89 50 4E 47
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 8) { return $false }
    return ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47)
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
                return (Test-ScreenPngHeader -Bytes $header)
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
    # the PNG adb writes to stdout, read into memory; $null when it is not a PNG
    param([string]$Serial)

    $bytes = Get-AdbBytes -Arguments "-s $Serial exec-out screencap -p" -TimeoutMs 20000
    if (-not (Test-ScreenPngHeader -Bytes $bytes)) { return $null }
    # the comma keeps a byte[] whole
    return ,$bytes
}

function ConvertTo-ScreenBitmap {
    # a frozen WPF bitmap from PNG bytes; the stream is not kept
    param([byte[]]$Bytes)

    $stream = New-Object System.IO.MemoryStream(,$Bytes)
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
    } finally {
        $stream.Dispose()
    }
    return $bitmap
}

function Set-ScreenPicture {
    param([byte[]]$Bytes, [string]$Serial)

    $bitmap = ConvertTo-ScreenBitmap -Bytes $Bytes
    $script:captureImage = $bitmap
    $script:captureBytes = $Bytes
    $script:captureSize = [PSCustomObject]@{ Width = $bitmap.PixelWidth; Height = $bitmap.PixelHeight }
    $script:captureSerial = $Serial
    $ui.ScreenPicture.Source = $bitmap
    $ui.ScreenEmpty.Visibility = 'Collapsed'
    return $bitmap
}

function Show-CaptureBytes {
    param([byte[]]$Bytes, [string]$Serial)

    $bitmap = Set-ScreenPicture -Bytes $Bytes -Serial $Serial
    $script:captureCount++
    $ui.ScreenInfo.Text = "$($bitmap.PixelWidth)x$($bitmap.PixelHeight)  $Serial  #$($script:captureCount)"
}

function Show-CaptureFile {
    param([string]$Path, [string]$Serial)

    # read into memory so the PNG file stays unlocked and can be overwritten
    # by the next capture; adb may hold it a few more milliseconds after it exits
    $bytes = $null
    foreach ($attempt in 1..5) {
        try { $bytes = [System.IO.File]::ReadAllBytes($Path); break } catch { Wait-Pumped -Milliseconds 150 }
    }
    if ($null -eq $bytes) {
        Write-Log 'Could not read the capture (the file was still busy).' $colorWarn
        return
    }
    $bitmap = Set-ScreenPicture -Bytes $bytes -Serial $Serial
    $ui.ScreenInfo.Text = "$($bitmap.PixelWidth)x$($bitmap.PixelHeight)  $Serial"
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
    if ($null -ne $bytes) {
        Show-CaptureBytes -Bytes $bytes -Serial $Serial
        if (-not $Quiet) { Write-Log "Captured the screen of $Serial." $colorInfo }
        return
    }

    # some ROMs refuse exec-out: fall back to a file on the phone and pull it
    if (-not $Quiet) { Write-Log 'exec-out gave no PNG, falling back to screencap + pull ...' $colorWarn }
    $file = Join-Path $env:TEMP "androiddc-nova-$PID.pull.png"
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

function Clear-Capture {
    # drop the picture on screen without touching the phone
    param([switch]$Quiet)

    $ui.ScreenPicture.Source = $null
    $ui.ScreenEmpty.Visibility = 'Visible'
    $script:captureImage = $null
    $script:captureBytes = $null
    $script:captureSize = $null
    $ui.ScreenInfo.Text = ''
    if (-not $Quiet) { Write-Log 'Cleared the picture.' $colorInfo }
}

function Convert-ToDevicePoint {
    <#
        A point on the picture area to a pixel on the phone, or $null outside
        the picture. The Image stretches Uniform: it keeps the aspect ratio and
        centres the picture, leaving bars left and right or above and below.
        The sizes default to the live ones; a test passes its own.
    #>
    param([double]$X, [double]$Y, [double]$BoxWidth = -1, [double]$BoxHeight = -1,
        [int]$ImageWidth = 0, [int]$ImageHeight = 0)

    if ($ImageWidth -le 0 -or $ImageHeight -le 0) {
        if (-not $script:captureImage) { return $null }
        $ImageWidth = $script:captureImage.PixelWidth
        $ImageHeight = $script:captureImage.PixelHeight
    }
    if ($BoxWidth -lt 0) { $BoxWidth = $ui.ScreenArea.ActualWidth }
    if ($BoxHeight -lt 0) { $BoxHeight = $ui.ScreenArea.ActualHeight }
    if ($BoxWidth -le 0 -or $BoxHeight -le 0 -or $ImageWidth -le 0 -or $ImageHeight -le 0) { return $null }

    $ratio = [Math]::Min($BoxWidth / $ImageWidth, $BoxHeight / $ImageHeight)
    $shownWidth = $ImageWidth * $ratio
    $shownHeight = $ImageHeight * $ratio
    $offsetX = ($BoxWidth - $shownWidth) / 2
    $offsetY = ($BoxHeight - $shownHeight) / 2

    if ($X -lt $offsetX -or $X -gt ($offsetX + $shownWidth)) { return $null }
    if ($Y -lt $offsetY -or $Y -gt ($offsetY + $shownHeight)) { return $null }

    $deviceX = [int][Math]::Floor(($X - $offsetX) / $ratio)
    $deviceY = [int][Math]::Floor(($Y - $offsetY) / $ratio)
    return [PSCustomObject]@{
        X = [Math]::Max(0, [Math]::Min($ImageWidth - 1, $deviceX))
        Y = [Math]::Max(0, [Math]::Min($ImageHeight - 1, $deviceY))
    }
}

# ------------------------------------------------------------ to the phone ----

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
    $text = $ui.ScreenSendBox.Text
    if ($text.Trim() -eq '') { return }

    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    # 'input text' takes %s for a space; every other character - ' & ( ; -
    # has to reach it untouched by the phone's shell, so it goes as one argument
    $escaped = $text -replace ' ', '%s'
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('input', 'text', $escaped)
    Write-Log "typed on $serial : $text" $colorInfo
    $ui.ScreenSendBox.Clear()
    Wait-Pumped -Milliseconds 400
    Update-Capture -Quiet
}

function Show-ScreenNotifications {
    # what Show-Notifications (Overview) does, for when that page is not loaded
    $serial = if ($script:captureSerial) { $script:captureSerial } else { Get-TargetSerial }
    if (-not $serial) { return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('cmd', 'statusbar', 'expand-notifications')
    Write-Log "opened the notification panel on $serial" $colorInfo
    Wait-Pumped -Milliseconds 700
    Update-Capture -Quiet
}

# ----------------------------------------------------------- page and timer ----

function Update-ScreenInterval {
    # the auto interval, kept within 500..30000 ms and given to the timer
    $milliseconds = Get-NumberValue -Box $ui.ScreenInterval -Default 2000 -Minimum 500 -Maximum 30000
    $script:screenTimer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    return $milliseconds
}

function Test-ScreenDeviceReady {
    $first = Get-SelectedDevice
    return ($null -ne $first -and $first.State -eq 'device')
}

function Show-ScreenPage {
    # a picture of the phone that is picked, unless it is already on screen
    if (-not (Test-ScreenDeviceReady)) { return }
    if ($script:captureImage -and $script:captureSerial -eq (Get-SelectedSerial)) { return }
    Update-Capture -Quiet
}

function Update-ScreenForDevice {
    # another phone: the picture of the old one must not take its taps
    $serial = Get-SelectedSerial
    if ($script:captureSerial -and $script:captureSerial -eq $serial) { return }
    if ($script:captureImage -or $script:captureSerial) {
        Clear-Capture -Quiet
        $ui.ScreenInfo.Text = 'no capture yet'
        $script:captureSerial = $null
    }
    if ((Test-PageShown -Key 'screen') -and (Test-ScreenDeviceReady)) { Update-Capture -Quiet }
}

$script:screenTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:screenTimer.Interval = [TimeSpan]::FromMilliseconds(2000)
$script:screenTimer.Add_Tick({
    # a capture takes over a second: never start another one on top of it
    if ($script:busy -gt 0 -or $script:capturing) { return }
    if (-not (Test-PageShown -Key 'screen')) { return }
    $script:screenTimer.Stop()
    try { Update-Capture -Quiet } finally { if ($ui.ScreenAuto.IsChecked) { $script:screenTimer.Start() } }
})

# ------------------------------------------------------------------ events ----

$ui.ScreenCapture.Add_Click({ Update-Capture })
$ui.ScreenSave.Add_Click({
    if ($null -eq $script:captureBytes) { Write-Log 'Capture something first.' $colorWarn; return }
    $path = Select-SaveFile -Filter 'PNG (*.png)|*.png' -FileName ('android-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    if (-not $path) { return }
    [System.IO.File]::WriteAllBytes($path, $script:captureBytes)
    Write-Log "Saved to $path" $colorGood
})
$ui.ScreenClear.Add_Click({ Clear-Capture })

$ui.ScreenAuto.Add_Checked({
    $milliseconds = Update-ScreenInterval
    $script:screenTimer.Start()
    Write-Log "Auto capture every $milliseconds ms." $colorInfo
})
$ui.ScreenAuto.Add_Unchecked({ $script:screenTimer.Stop() })
$ui.ScreenInterval.Add_LostFocus({ $null = Update-ScreenInterval })
$ui.ScreenInterval.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; $null = Update-ScreenInterval }
})

$ui.ScreenKeyBack.Add_Click({ Send-Key -KeyCode 4 })
$ui.ScreenKeyHome.Add_Click({ Send-Key -KeyCode 3 })
$ui.ScreenKeyRecents.Add_Click({ Send-Key -KeyCode 187 })
$ui.ScreenKeyPower.Add_Click({ Send-Key -KeyCode 26 })
$ui.ScreenKeyVolUp.Add_Click({ Send-Key -KeyCode 24 })
$ui.ScreenKeyVolDown.Add_Click({ Send-Key -KeyCode 25 })
$ui.ScreenSendText.Add_Click({ Send-Text })
$ui.ScreenSendBox.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) {
        $eventArgs.Handled = $true
        Send-Text
    }
})

$ui.ScreenArea.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    $position = $eventArgs.GetPosition($sender)
    $script:screenPressPoint = Convert-ToDevicePoint -X $position.X -Y $position.Y
    $script:screenPressTime = Get-Date
    # the release still arrives here when the drag ends outside the picture
    $null = $sender.CaptureMouse()
    $eventArgs.Handled = $true
})

$ui.ScreenArea.Add_MouseUp({
    param($sender, $eventArgs)

    $button = $eventArgs.ChangedButton
    $eventArgs.Handled = $true

    # right button = Back, thumb buttons = Recents / notification panel
    if ($button -eq [System.Windows.Input.MouseButton]::Right) { Send-Key -KeyCode 4; return }
    if ($button -eq [System.Windows.Input.MouseButton]::XButton1) { Send-Key -KeyCode 187; return }
    if ($button -eq [System.Windows.Input.MouseButton]::XButton2) {
        if (Get-Command Show-Notifications -ErrorAction SilentlyContinue) { Show-Notifications } else { Show-ScreenNotifications }
        return
    }
    if ($button -ne [System.Windows.Input.MouseButton]::Left) { return }

    $sender.ReleaseMouseCapture()
    $start = $script:screenPressPoint
    $script:screenPressPoint = $null
    if (-not $start) { return }
    $position = $eventArgs.GetPosition($sender)
    $end = Convert-ToDevicePoint -X $position.X -Y $position.Y
    if (-not $end) { return }

    $held = if ($script:screenPressTime) { ((Get-Date) - $script:screenPressTime).TotalMilliseconds } else { 0 }
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

# the interval is remembered; Auto is not, so nothing captures by itself at start
Register-Setting -Name 'Screen.Interval' -Get { $ui.ScreenInterval.Text } -Set { param($v) $ui.ScreenInterval.Text = "$v"; $null = Update-ScreenInterval }
Register-Cleanup { $script:screenTimer.Stop() }
