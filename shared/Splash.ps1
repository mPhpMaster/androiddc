<#
    AndroidDC - the little window that says it is coming.

    Both windows take seconds to build, and until now there was nothing on
    screen for them. Measured on the machine this was written on:

      the classic window   3.5 s before it appears, 5.5 s before the device
                           list is in - 2.1 s of that is building its 530
                           controls
      Nova                 6.3 s before it appears, of which 5 s is reading
                           its eighteen pages

    So the bar here is not a decoration that spins while something unknown
    happens: each window says where it has got to, and the steps are the ones
    that were measured. It is a WinForms form in both windows - Nova loads
    WinForms anyway, and starting WPF is part of what is being waited for.

    Nothing here is allowed to stop the program: a splash that will not open
    is a splash that is not shown, and the window carries on without it.

    Dot-sourced by both windows, before anything else they load.
#>

$script:splashForm = $null
$script:splashLabel = $null
$script:splashBar = $null

function Show-Splash {
    <#
        The window, centred and on top, with the program's own icon when the
        assets folder is beside the script. Skipped when the program is
        starting minimized - there is nothing to wait for then - and when a
        test runner has asked for no splash.
    #>
    param([string]$Root, [string]$Version = '', [switch]$Quiet)

    if ($Quiet) { return }
    if ($env:ANDROIDDC_NO_SPLASH) { return }
    if ($script:splashForm) { return }

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size(420, 150)
        $form.BackColor = [System.Drawing.Color]::White
        $form.TopMost = $true
        # not in the taskbar: the window being waited for will be there soon
        # enough, and two entries for one program is one too many
        $form.ShowInTaskbar = $false

        # a hairline edge, because a white rectangle on a white desktop is not
        # a window
        $edge = New-Object System.Windows.Forms.Panel
        $edge.Dock = 'Fill'
        $edge.BackColor = [System.Drawing.Color]::White
        $edge.BorderStyle = 'FixedSingle'
        $form.Controls.Add($edge)

        $picture = New-Object System.Windows.Forms.PictureBox
        $picture.SizeMode = 'Zoom'
        $picture.Location = New-Object System.Drawing.Point(24, 26)
        $picture.Size = New-Object System.Drawing.Size(48, 48)
        $edge.Controls.Add($picture)
        # the .png, not the .ico: the icon file holds one 256 px frame, and
        # asking it for 48 and turning that into a bitmap gives coloured noise
        $pictureFile = Join-Path $Root (Join-Path 'assets' 'icon-48.png')
        if (Test-Path -LiteralPath $pictureFile -PathType Leaf) {
            try { $picture.Image = [System.Drawing.Image]::FromFile($pictureFile) } catch { }
        }
        $iconFile = Join-Path $Root (Join-Path 'assets' 'androiddc.ico')
        if (Test-Path -LiteralPath $iconFile -PathType Leaf) {
            try { $form.Icon = New-Object System.Drawing.Icon($iconFile) } catch { }
        }

        $name = New-Object System.Windows.Forms.Label
        $name.Text = 'AndroidDC'
        $name.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $name.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $name.Location = New-Object System.Drawing.Point(88, 24)
        $name.Size = New-Object System.Drawing.Size(300, 30)
        $edge.Controls.Add($name)

        $what = New-Object System.Windows.Forms.Label
        $what.Text = $(if ("$Version") { "Device Control  $Version" } else { 'Device Control' })
        $what.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
        $what.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $what.Location = New-Object System.Drawing.Point(90, 54)
        $what.Size = New-Object System.Drawing.Size(300, 18)
        $edge.Controls.Add($what)

        # Two panels rather than a ProgressBar, and not because of how it
        # looks: a themed bar is drawn by Windows outside the control, so
        # DrawToBitmap hands back an empty track and no test can see where it
        # had got to. It is also not a Marquee - the steps are measured, so
        # the bar says how far along this is, not merely that it is alive.
        $track = New-Object System.Windows.Forms.Panel
        $track.BackColor = [System.Drawing.Color]::FromArgb(228, 231, 236)
        $track.Location = New-Object System.Drawing.Point(24, 92)
        $track.Size = New-Object System.Drawing.Size(370, 8)
        $edge.Controls.Add($track)

        $bar = New-Object System.Windows.Forms.Panel
        $bar.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
        $bar.Location = New-Object System.Drawing.Point(0, 0)
        $bar.Size = New-Object System.Drawing.Size(0, 8)
        $track.Controls.Add($bar)

        $line = New-Object System.Windows.Forms.Label
        $line.Text = 'Starting ...'
        $line.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
        $line.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
        $line.AutoEllipsis = $true
        $line.Location = New-Object System.Drawing.Point(24, 108)
        $line.Size = New-Object System.Drawing.Size(370, 18)
        $edge.Controls.Add($line)

        $script:splashForm = $form
        $script:splashLabel = $line
        $script:splashBar = $bar
        $form.Show()
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        $script:splashForm = $null
        $script:splashLabel = $null
        $script:splashBar = $null
    }
}

function Update-Splash {
    <#
        Where the window has got to. The pump is the point: the thread is
        busy building controls, and a label that is set and never drawn is a
        label nobody sees.
    #>
    param([string]$Text, [int]$Percent = -1)

    if (-not $script:splashForm) { return }
    try {
        if ("$Text" -and $script:splashLabel) { $script:splashLabel.Text = $Text }
        # no percentage - which is what the default means - leaves the bar
        # where it was, for a step that says something without advancing
        if ($Percent -ge 0 -and $script:splashBar) {
            $far = [Math]::Max(0, [Math]::Min(100, $Percent))
            $script:splashBar.Width = [int]($script:splashBar.Parent.Width * $far / 100)
        }
        $script:splashForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Close-Splash {
    # when the window it was standing in for is on screen
    if (-not $script:splashForm) { return }
    try {
        $script:splashForm.Close()
        $script:splashForm.Dispose()
    } catch { }
    $script:splashForm = $null
    $script:splashLabel = $null
    $script:splashBar = $null
}

function Test-SplashShown {
    return ($null -ne $script:splashForm)
}

function Get-SplashState {
    # for a test: what it says, and how far along the bar is, in percent
    if (-not $script:splashForm) { return $null }
    $far = 0
    if ($script:splashBar -and $script:splashBar.Parent.Width -gt 0) {
        $far = [int](100.0 * $script:splashBar.Width / $script:splashBar.Parent.Width)
    }
    return [PSCustomObject]@{ Text = "$($script:splashLabel.Text)"; Percent = $far }
}
