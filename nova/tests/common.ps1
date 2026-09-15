# What every test can use. A test runs inside the real program: run.ps1 starts
# androiddc-nova.ps1 off screen with -TestScript, so every page, helper and
# control is loaded exactly as a person would get it, and the window is then
# closed normally - never killed, or settings would not be written.

$TestOut = Join-Path $env:TEMP 'androiddc-nova-tests'
if (-not (Test-Path -LiteralPath $TestOut)) { $null = New-Item -ItemType Directory -Path $TestOut }

function Say {
    param([string]$Text)
    Write-Host $Text
}

function Mark {
    # the word run.ps1 counts: OK, or FAIL (case-sensitive)
    param([bool]$Ok)
    if ($Ok) { return 'OK' }
    return 'FAIL'
}

function Wait-Idle {
    # until nothing is running, or the time is up; true when idle
    param([int]$Seconds = 30)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Wait-Pumped -Milliseconds 300
    while ($script:busy -gt 0 -and $watch.Elapsed.TotalSeconds -lt $Seconds) { Wait-Pumped -Milliseconds 200 }
    return ($script:busy -eq 0)
}

function Save-WindowPicture {
    # a PNG of the whole window, under %TEMP%\androiddc-nova-tests; returns its path
    param([string]$Name)

    $script:window.UpdateLayout()
    Wait-Pumped -Milliseconds 200
    $width = [int]$script:window.ActualWidth
    $height = [int]$script:window.ActualHeight
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($script:window.Content)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $TestOut "$Name.png"
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Close() }
    return $path
}

function Set-WindowSize {
    # 'min' or 'default'
    param([string]$Size)

    if ($Size -eq 'min') {
        $script:window.Width = $script:window.MinWidth
        $script:window.Height = $script:window.MinHeight
    } else {
        $script:window.Width = 1440
        $script:window.Height = 920
    }
    Wait-Pumped -Milliseconds 500
}

function Get-OutsideElements {
    <#
        Named elements of a page that stick out past the right edge of the
        page area - what a layout that does not fit the smallest window
        looks like. Elements inside a ScrollViewer are measured against it.
    #>
    param($Root)

    # not $host: that name is PowerShell's own and cannot be assigned
    $pageArea = $ui.PageHost
    $limit = $pageArea.ActualWidth
    $outside = @()
    foreach ($name in @($ui.Keys)) {
        $element = $ui[$name]
        if ($element -isnot [System.Windows.FrameworkElement] -or -not $element.IsVisible) { continue }
        if (-not $Root.IsAncestorOf($element)) { continue }
        try {
            $point = $element.TransformToAncestor($pageArea).Transform((New-Object System.Windows.Point(0, 0)))
        } catch { continue }
        if ($point.X + $element.ActualWidth -gt $limit + 1) { $outside += ('{0} ends at {1:N0} of {2:N0}' -f $name, ($point.X + $element.ActualWidth), $limit) }
    }
    return $outside
}
