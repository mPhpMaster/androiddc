# The Screen page: it opens, the picture fills the page and keeps its aspect
# ratio, a point on the picture maps to the right phone pixel (arithmetic
# only - no tap, swipe, key or text is ever sent), the auto timer never runs
# two captures at once, and nothing runs off the edge at the smallest size.
# With a phone attached it takes screenshots, which only read.

function Test-Near {
    param([double]$Value, [double]$Expected, [double]$Tolerance = 1.5)
    return ([Math]::Abs($Value - $Expected) -le $Tolerance)
}

function New-TestPng {
    # a plain grey PNG of the given size, as bytes
    param([int]$Width, [int]$Height)
    $pixels = New-Object byte[] ($Width * $Height)
    for ($i = 0; $i -lt $pixels.Length; $i++) { $pixels[$i] = [byte](($i % $Width) * 255 / $Width) }
    $source = [System.Windows.Media.Imaging.BitmapSource]::Create($Width, $Height, 96, 96,
        [System.Windows.Media.PixelFormats]::Gray8, $null, $pixels, $Width)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($source))
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)
    $bytes = $stream.ToArray()
    $stream.Dispose()
    return ,$bytes
}

Say '== the page =='
$null = Wait-Idle -Seconds 30
Show-Page -Page 'screen'
$idle = Wait-Idle -Seconds 40
Say ("  opens and settles   {0}" -f (Mark ($idle -and (Test-PageShown -Key 'screen'))))
$names = @('ScreenArea', 'ScreenPicture', 'ScreenCapture', 'ScreenAuto', 'ScreenInterval', 'ScreenSave', 'ScreenClear',
    'ScreenKeyBack', 'ScreenKeyHome', 'ScreenKeyRecents', 'ScreenKeyPower', 'ScreenKeyVolUp', 'ScreenKeyVolDown',
    'ScreenSendBox', 'ScreenSendText', 'ScreenInfo', 'ScreenHint')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  every control is there   {0}" -f (Mark ($missing.Count -eq 0)))
if ($missing.Count) { Say ("    missing: " + ($missing -join ', ')) }
Say ("  the picture stretches Uniform   {0}" -f (Mark ($ui.ScreenPicture.Stretch -eq [System.Windows.Media.Stretch]::Uniform)))
foreach ($function in @('Test-PngFile', 'Get-CaptureBytes', 'Show-CaptureBytes', 'Show-CaptureFile', 'Update-Capture',
        'Get-CaptureInto', 'Convert-ToDevicePoint', 'Send-Tap', 'Send-Swipe', 'Send-Key', 'Send-Text', 'Clear-Capture')) {
    if (-not (Get-Command $function -ErrorAction SilentlyContinue)) { Say "  $function is not defined   FAIL" }
}
$updateCapture = Get-Command Update-Capture
Say ("  Update-Capture keeps its -Quiet switch   {0}" -f (Mark ($updateCapture.Parameters.ContainsKey('Quiet'))))

Say ''
Say '== tap mapping (arithmetic only, nothing is sent) =='
# a portrait phone in a wide box: bars left and right
$p = Convert-ToDevicePoint -X 283 -Y 173 -BoxWidth 566 -BoxHeight 346 -ImageWidth 1080 -ImageHeight 2400
Say ("  centre of a letterboxed portrait -> {0},{1}   {2}" -f $p.X, $p.Y, (Mark ($p -and (Test-Near $p.X 540 2) -and (Test-Near $p.Y 1200 2))))
$p = Convert-ToDevicePoint -X 10 -Y 10 -BoxWidth 566 -BoxHeight 346 -ImageWidth 1080 -ImageHeight 2400
Say ("  a click on the bar beside it is ignored   {0}" -f (Mark ($null -eq $p)))
# ratio = 346/2400; shown width 155.7; left bar 205.15
$ratio = 346 / 2400
$left = (566 - 1080 * $ratio) / 2
$p = Convert-ToDevicePoint -X ($left + 0.2) -Y 345.9 -BoxWidth 566 -BoxHeight 346 -ImageWidth 1080 -ImageHeight 2400
Say ("  the picture's bottom-left corner -> {0},{1}   {2}" -f $p.X, $p.Y, (Mark ($p -and $p.X -le 2 -and $p.Y -ge 2397)))
$p = Convert-ToDevicePoint -X ($left + 1080 * $ratio / 4) -Y (346 / 4) -BoxWidth 566 -BoxHeight 346 -ImageWidth 1080 -ImageHeight 2400
Say ("  a quarter in -> {0},{1}   {2}" -f $p.X, $p.Y, (Mark ($p -and (Test-Near $p.X 270 2) -and (Test-Near $p.Y 600 2))))
# a landscape picture in the same box: bars above and below
$ratio = [Math]::Min(566 / 2400, 346 / 1080)
$top = (346 - 1080 * $ratio) / 2
$p = Convert-ToDevicePoint -X 566 -Y 173 -BoxWidth 566 -BoxHeight 346 -ImageWidth 2400 -ImageHeight 1080
Say ("  right edge of a landscape picture -> {0},{1}   {2}" -f $p.X, $p.Y, (Mark ($p -and $p.X -eq 2399 -and (Test-Near $p.Y 540 2))))
$p = Convert-ToDevicePoint -X 300 -Y ($top - 1) -BoxWidth 566 -BoxHeight 346 -ImageWidth 2400 -ImageHeight 1080
Say ("  a click on the bar above it is ignored   {0}" -f (Mark ($null -eq $p)))

Say ''
Say '== never two captures at once =='
$count = $script:captureCount
$script:capturing = $true
Update-Capture -Quiet
$script:capturing = $false
Say ("  Update-Capture returns while one is running   {0}" -f (Mark ($script:captureCount -eq $count -and $script:busy -eq 0)))

$ui.ScreenInterval.Text = '100'
$milliseconds = Update-ScreenInterval
Say ("  the interval keeps its limits (100 -> {0})   {1}" -f $milliseconds, (Mark ($milliseconds -eq 500 -and $ui.ScreenInterval.Text -eq '500')))
$ui.ScreenAuto.IsChecked = $true
$started = $script:screenTimer.IsEnabled
$script:busy++
$count = $script:captureCount
Wait-Pumped -Milliseconds 1400
$skipped = ($script:captureCount -eq $count)
$script:busy--
$ui.ScreenAuto.IsChecked = $false
$null = Wait-Idle -Seconds 30
Say ("  Auto starts the timer, which skips while busy   {0}" -f (Mark ($started -and $skipped)))
Say ("  unticking Auto stops it   {0}" -f (Mark (-not $script:screenTimer.IsEnabled)))
$ui.ScreenInterval.Text = '2000'
$null = Update-ScreenInterval

Say ''
Say '== the picture in the real layout =='
$fake = New-TestPng -Width 90 -Height 200
Say ("  a PNG is recognised by its header   {0}" -f (Mark ((Test-ScreenPngHeader -Bytes $fake) -and -not (Test-ScreenPngHeader -Bytes ([byte[]](1, 2, 3, 4, 5, 6, 7, 8))))))
$keepSerial = $script:captureSerial
$keepBytes = $script:captureBytes
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Show-CaptureBytes -Bytes $fake -Serial 'TEST'
    Wait-Pumped -Milliseconds 400
    $area = $ui.ScreenArea
    $picture = $ui.ScreenPicture
    $ratio = [Math]::Min($area.ActualWidth / 90, $area.ActualHeight / 200)
    $shownWidth = 90 * $ratio
    $shownHeight = 200 * $ratio
    $origin = $picture.TransformToAncestor($area).Transform((New-Object System.Windows.Point(0, 0)))
    $placed = (Test-Near $origin.X (($area.ActualWidth - $shownWidth) / 2) 2) -and (Test-Near $origin.Y (($area.ActualHeight - $shownHeight) / 2) 2) -and
        (Test-Near $picture.ActualWidth $shownWidth 2) -and (Test-Near $picture.ActualHeight $shownHeight 2)
    Say ("  {0}: area {1:N0}x{2:N0}, picture {3:N0}x{4:N0} at {5:N0},{6:N0} - where the mapping expects it   {7}" -f $size,
        $area.ActualWidth, $area.ActualHeight, $picture.ActualWidth, $picture.ActualHeight, $origin.X, $origin.Y, (Mark $placed))
    $p = Convert-ToDevicePoint -X ($area.ActualWidth / 2) -Y ($area.ActualHeight / 2)
    Say ("  {0}: the middle of the area is pixel {1},{2}   {3}" -f $size, $p.X, $p.Y, (Mark ($p -and (Test-Near $p.X 45 1) -and (Test-Near $p.Y 100 1))))
    $p = Convert-ToDevicePoint -X ($origin.X + $picture.ActualWidth - 0.3) -Y ($origin.Y + 0.3)
    Say ("  {0}: the picture's top-right corner is pixel {1},{2}   {3}" -f $size, $p.X, $p.Y, (Mark ($p -and $p.X -ge 88 -and $p.Y -le 1)))
    $p = Convert-ToDevicePoint -X ($origin.X - 3) -Y ($area.ActualHeight / 2)
    Say ("  {0}: just left of the picture is nothing   {1}" -f $size, (Mark ($null -eq $p -or $origin.X -lt 3)))
    # the picture gets the whole page but the control column
    $pageWidth = $ui.PageHost.ActualWidth
    Say ("  {0}: the picture area is {1:N0} of {2:N0} px wide   {3}" -f $size, $area.ActualWidth, $pageWidth, (Mark ($area.ActualWidth -ge $pageWidth - 360)))
}
Clear-Capture -Quiet
$script:captureSerial = $null
Say ("  Clear drops the picture   {0}" -f (Mark ($null -eq $ui.ScreenPicture.Source -and $null -eq $script:captureImage -and $ui.ScreenEmpty.Visibility -eq 'Visible')))

Say ''
Say '== a real screenshot (reads only) =='
Set-WindowSize 'default'
$first = Get-SelectedDevice
if ($null -eq $first -or $first.State -ne 'device') {
    Say '  no ready phone attached - skipped'
} else {
    $serial = $first.Serial
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $bytes = Get-CaptureBytes -Serial $serial
    Say ("  exec-out screencap gave a PNG ({0:N0} KB, {1:N1} s)   {2}" -f $(if ($bytes) { $bytes.Length / 1KB } else { 0 }), $watch.Elapsed.TotalSeconds, (Mark ($null -ne $bytes)))
    if ($null -ne $bytes) {
        # exec-out works on this phone, so Update-Capture will not fall back to a file on it
        $count = $script:captureCount
        Update-Capture -Quiet
        $null = Wait-Idle -Seconds 30
        Say ("  Update-Capture shows it and counts it   {0}" -f (Mark ($script:captureCount -eq $count + 1 -and $null -ne $script:captureImage -and $script:captureSerial -eq $serial)))
        Say ("  the info line names size and count   {0}" -f (Mark ($ui.ScreenInfo.Text -match '^\d+x\d+  \S+  #\d+$')))
        $w = $script:captureImage.PixelWidth; $h = $script:captureImage.PixelHeight
        $p = Convert-ToDevicePoint -X ($ui.ScreenArea.ActualWidth / 2) -Y ($ui.ScreenArea.ActualHeight / 2)
        Say ("  the middle of the page maps to the middle of the phone   {0}" -f (Mark ($p -and (Test-Near $p.X ($w / 2) ($w / 100 + 2)) -and (Test-Near $p.Y ($h / 2) ($h / 100 + 2)))))
    }
}

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "screen-$size"))
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'screen').Root)
    Say ("  {0}: nothing past the right edge   {1}" -f $size, (Mark ($outside.Count -eq 0)))
    foreach ($line in $outside) { Say "    $line" }
}
Set-WindowSize 'default'
