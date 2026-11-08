# needs: phone
# Cam / Mic, "As a PC camera": the box sits between the camera buttons and
# the audio box without overlapping, the camera choice follows the camera box
# above, and a real start turns on "AndroidDC Camera" with the phone's picture
# (an app opening it sees the phone), then a stop turns it off.
# The phone's camera streams for a few seconds; nothing on the phone changes.
# Skips the start when the camera is not registered on this PC.

Select-TestPhone
$tabs.SelectedTab = $tabCamera
Wait-Pumped -Milliseconds 500
Update-CamMicLayout
Wait-Pumped -Milliseconds 200

Say '== the box =='
Say ("below the camera buttons, above the audio box   {0}" -f (Mark (($grpPcCamera.Top -ge $btnCameraStart.Bottom) -and
    ($grpAudio.Top -ge $grpPcCamera.Bottom))))
Say ("Use on, Stop off   {0}" -f (Mark ($btnPcCameraStart.Enabled -and -not $btnPcCameraStop.Enabled)))
$inside = $true
foreach ($control in @($btnPcCameraStart, $btnPcCameraStop, $chkPcCameraMirror, $lblPcCameraHint)) {
    if ($control.Right -gt $grpPcCamera.ClientSize.Width -or $control.Bottom -gt $grpPcCamera.ClientSize.Height) { $inside = $false; Say "  outside: $($control.Text)" }
}
Say ("everything inside the box   {0}" -f (Mark $inside))
$overlap = ($btnPcCameraStop.Right -gt $chkPcCameraMirror.Left) -or ($btnPcCameraStart.Right -gt $btnPcCameraStop.Left)
Say ("buttons and Mirror side by side   {0}" -f (Mark (-not $overlap)))

Say ''
Say '== which camera =='
$keepFacing = "$($cmbCameraFacing.SelectedItem)"
$cmbCameraFacing.SelectedItem = 'back'
$choice = Get-PcCameraChoice
Say ("a facing picks by facing   {0}" -f (Mark ($choice.Facing -eq 'back' -and -not $choice.Id)))
$cmbCameraFacing.SelectedItem = 'by id'
$null = $cmbCamera.Items.Add('2  -  front  1920x1080')
$cmbCamera.SelectedItem = '2  -  front  1920x1080'
$choice = Get-PcCameraChoice
Say ("by id takes the listed id   {0}" -f (Mark ($choice.Id -eq '2' -and -not $choice.Facing)))
$cmbCamera.Items.Remove('2  -  front  1920x1080')
$cmbCamera.SelectedIndex = 0
$cmbCameraFacing.SelectedItem = $keepFacing

Say ''
Say '== a real start =='
$state = Get-VCamState
Say ("state: need '{0}'" -f $state.Need)
if (-not $state.Ready) {
    Say 'not ready on this PC - the start is skipped'
} else {
    $cmbCameraFacing.SelectedItem = 'front'
    Start-PcCamera
    Say ("on: Use off, Stop on   {0}" -f (Mark ((Test-VCamRunning) -and -not $btnPcCameraStart.Enabled -and $btnPcCameraStop.Enabled)))
    $peek = @(& (Join-Path $state.Folder 'AndroidDC.VCamHost.exe') peek 2>&1 | ForEach-Object { "$_" })
    Say ("an app sees the phone: {0}   {1}" -f ($peek -join ' '), (Mark ($LASTEXITCODE -eq 0)))
    $btnPcCameraStop.PerformClick()
    Wait-Pumped -Milliseconds 500
    Say ("off: Use on, Stop off   {0}" -f (Mark (-not (Test-VCamRunning) -and $btnPcCameraStart.Enabled -and -not $btnPcCameraStop.Enabled)))
    $cmbCameraFacing.SelectedItem = $keepFacing
}
