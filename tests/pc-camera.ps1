# needs: phone
# Cam / Mic, "As a PC camera": the box sits between the camera buttons and
# the audio box without overlapping, the camera choice follows the camera box
# above, and a real start turns on "AndroidDC Camera" with the phone's picture
# (an app opening it sees the phone), Back while on switches without turning
# it off, then a stop turns it off.
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
foreach ($control in @($lblPcCameraWhich, $cmbPcCameraWhich, $btnPcCameraStart, $btnPcCameraStop, $chkPcCameraMirror, $lblPcCameraHint)) {
    if ($control.Right -gt $grpPcCamera.ClientSize.Width -or $control.Bottom -gt $grpPcCamera.ClientSize.Height) { $inside = $false; Say "  outside: $($control.Text)" }
}
Say ("everything inside the box   {0}" -f (Mark $inside))
$overlap = ($cmbPcCameraWhich.Right -gt $btnPcCameraStart.Left) -or ($btnPcCameraStop.Right -gt $chkPcCameraMirror.Left) -or ($btnPcCameraStart.Right -gt $btnPcCameraStop.Left)
Say ("Camera, buttons and Mirror side by side   {0}" -f (Mark (-not $overlap)))

Say ''
Say '== which camera =='
Say ("Camera offers Front, Back, As picked above; Front first   {0}" -f (Mark ((@($cmbPcCameraWhich.Items) -join ',') -eq 'Front,Back,As picked above' -and "$($cmbPcCameraWhich.SelectedItem)" -eq 'Front')))
$choice = Get-PcCameraChoice
Say ("Front picks the front camera   {0}" -f (Mark ($choice.Facing -eq 'front' -and -not $choice.Id)))
$cmbPcCameraWhich.SelectedItem = 'Back'
$choice = Get-PcCameraChoice
Say ("Back picks the back camera, nothing starts while off   {0}" -f (Mark ($choice.Facing -eq 'back' -and -not $choice.Id -and -not (Test-VCamRunning))))
$cmbPcCameraWhich.SelectedItem = 'As picked above'
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
    $cmbPcCameraWhich.SelectedItem = 'Front'
    Start-PcCamera
    Say ("on: Use off, Stop on   {0}" -f (Mark ((Test-VCamRunning) -and -not $btnPcCameraStart.Enabled -and $btnPcCameraStop.Enabled)))
    $peek = @(& (Join-Path $state.Folder 'AndroidDC.VCamHost.exe') peek 2>&1 | ForEach-Object { "$_" })
    Say ("an app sees the phone: {0}   {1}" -f ($peek -join ' '), (Mark ($LASTEXITCODE -eq 0)))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $cmbPcCameraWhich.SelectedItem = 'Back'
    Say ("Back while on: switched in {0} ms, still on   {1}" -f $watch.ElapsedMilliseconds, (Mark ((Test-VCamRunning) -and $script:vcamCamera.Facing -eq 'back' -and $script:pcCameraShown -eq 1)))
    $peek = @(& (Join-Path $state.Folder 'AndroidDC.VCamHost.exe') peek 2>&1 | ForEach-Object { "$_" })
    Say ("an app sees the back camera: {0}   {1}" -f ($peek -join ' '), (Mark ($LASTEXITCODE -eq 0)))
    $cmbPcCameraWhich.SelectedItem = 'Front'
    Say ("Front again   {0}" -f (Mark ((Test-VCamRunning) -and $script:vcamCamera.Facing -eq 'front')))
    $btnPcCameraStop.PerformClick()
    Wait-Pumped -Milliseconds 500
    Say ("off: Use on, Stop off   {0}" -f (Mark (-not (Test-VCamRunning) -and $btnPcCameraStart.Enabled -and -not $btnPcCameraStop.Enabled)))
}
