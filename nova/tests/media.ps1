# The Camera & mic page: it opens, the command lines it would send follow
# every guard of the original (size or aspect, --audio-dup only for output
# and never with recording, encoders only of the chosen codec), the right
# settings are kept and the encoder is not, and nothing runs off the edge.
# Nothing is started: no camera, no audio. With a phone attached, the lists
# are read with scrcpy --list-*, which only reads.

function Test-Has {
    param($Arguments, [string]$Word)
    return (@($Arguments) -contains $Word)
}

Say '== the page =='
$null = Wait-Idle -Seconds 30
Show-Page -Page 'media'
$idle = Wait-Idle -Seconds 30
Say ("  opens and settles   {0}" -f (Mark ($idle -and (Test-PageShown -Key 'media'))))
Say ("  Listen on, Stop audio off, nothing playing   {0}" -f (Mark ($ui.MediaListen.IsEnabled -and -not $ui.MediaListenStop.IsEnabled -and $null -eq $script:audioProcess)))
Say ("  encoder list disabled until the phone is asked   {0}" -f (Mark (-not $ui.MediaAudioEncoder.IsEnabled -and $ui.MediaAudioEncoder.Items.Count -eq 1)))
Say ("  raw is in the codec list   {0}" -f (Mark ($ui.MediaAudioCodec.Items.Contains('raw'))))
Say ("  camera list says to press List cameras   {0}" -f (Mark ("$($ui.MediaCamera.SelectedItem)" -eq 'press "List cameras"')))

Say ''
Say '== file names follow the codec =='
$kinds = @{ 'default' = 'opus'; 'opus' = 'opus'; 'aac' = 'm4a'; 'flac' = 'flac'; 'raw' = 'wav' }
$wrong = @($kinds.Keys | Where-Object { (Get-AudioFileKind -Codec $_) -ne $kinds[$_] })
Say ("  opus/default .opus, aac .m4a, flac .flac, raw .wav   {0}" -f (Mark ($wrong.Count -eq 0)))

Say ''
Say '== encoders of the chosen codec only =='
$keepEncoders = $script:audioEncoders
$script:audioEncoders = @(
    [PSCustomObject]@{ Codec = 'opus'; Name = 'c2.test.opus' },
    [PSCustomObject]@{ Codec = 'aac'; Name = 'c2.test.aac' },
    [PSCustomObject]@{ Codec = 'aac'; Name = 'c2.other.aac' })
$ui.MediaAudioCodec.SelectedItem = 'aac'
$items = @($ui.MediaAudioEncoder.Items)
Say ("  aac offers default + 2 aac encoders   {0}" -f (Mark ($items.Count -eq 3 -and $items -notcontains 'c2.test.opus' -and $ui.MediaAudioEncoder.IsEnabled)))
$ui.MediaAudioEncoder.SelectedItem = 'c2.other.aac'
$ui.MediaAudioCodec.SelectedItem = 'default'
$items = @($ui.MediaAudioEncoder.Items)
Say ("  default means opus, and a mismatched choice goes   {0}" -f (Mark ($items.Count -eq 2 -and $items -contains 'c2.test.opus' -and "$($ui.MediaAudioEncoder.SelectedItem)" -eq 'default')))
$ui.MediaAudioCodec.SelectedItem = 'flac'
Say ("  flac with no flac encoder: disabled again   {0}" -f (Mark (-not $ui.MediaAudioEncoder.IsEnabled)))
$ui.MediaAudioCodec.SelectedItem = 'aac'
$ui.MediaAudioEncoder.SelectedItem = 'c2.test.aac'

Say ''
Say '== the audio command line =='
$ui.MediaAudioSource.SelectedItem = 'output'
$ui.MediaAudioBitrate.Text = '128K'
$ui.MediaAudioBuffer.Text = '50'
$ui.MediaAudioDup.IsChecked = $true
$arguments = Get-AudioArguments -Serial 'SERIAL1'
Say ("  listen: {0}" -f ($arguments -join ' '))
Say ("  codec, encoder, bit rate, buffer and --audio-dup for output   {0}" -f (Mark ((Test-Has $arguments '--audio-codec=aac') -and
    (Test-Has $arguments '--audio-encoder=c2.test.aac') -and (Test-Has $arguments '--audio-bit-rate=128K') -and
    (Test-Has $arguments '--audio-buffer=50') -and (Test-Has $arguments '--audio-dup') -and (Test-Has $arguments '--no-video'))))
$logBefore = $script:logLines.Count
$arguments = Get-AudioArguments -Serial 'SERIAL1' -ToFile
Say ("  recording: no --audio-dup, and the log says why   {0}" -f (Mark (-not (Test-Has $arguments '--audio-dup') -and $script:logLines.Count -gt $logBefore)))
$ui.MediaAudioSource.SelectedItem = 'mic'
$arguments = Get-AudioArguments -Serial 'SERIAL1'
Say ("  mic source: no --audio-dup   {0}" -f (Mark (-not (Test-Has $arguments '--audio-dup') -and (Test-Has $arguments '--audio-source=mic'))))
$ui.MediaAudioBuffer.Text = 'abc'
$ui.MediaAudioBitrate.Text = 'default'
$ui.MediaAudioCodec.SelectedItem = 'default'
$arguments = Get-AudioArguments -Serial 'SERIAL1'
Say ("  default codec, default bit rate and a non-number buffer send nothing   {0}" -f (Mark (@($arguments | Where-Object { $_ -match '^--audio-(codec|encoder|bit-rate|buffer)=' }).Count -eq 0)))
$script:audioEncoders = $keepEncoders
Update-AudioEncoderChoices
$ui.MediaAudioDup.IsChecked = $false
$ui.MediaAudioBuffer.Text = ''

Say ''
Say '== the camera command line =='
$null = $ui.MediaCamera.Items.Add('2  -  front  1920x1080')
$ui.MediaCamera.SelectedItem = '2  -  front  1920x1080'
$ui.MediaCameraFacing.SelectedItem = 'by id'
$ui.MediaCameraSize.Text = '1280x720'
$ui.MediaCameraAr.Text = '(size)'
$ui.MediaCameraZoom.Text = '1'
$arguments = Get-CameraArguments -Serial 'SERIAL1'
Say ("  camera: {0}" -f ($arguments -join ' '))
Say ("  by id, the size, no zoom, no audio, one-word title   {0}" -f (Mark ((Test-Has $arguments '--camera-id=2') -and
    (Test-Has $arguments '--camera-size=1280x720') -and -not (@($arguments) -match '^--camera-zoom') -and
    (Test-Has $arguments '--no-audio') -and (Test-Has $arguments '--window-title=camera'))))
$ui.MediaCameraAr.Text = '4:3'
$ui.MediaCameraZoom.Text = '2'
$ui.MediaCameraTorch.IsChecked = $true
$ui.MediaCameraMic.IsChecked = $true
$arguments = Get-CameraArguments -Serial 'SERIAL1' -Facing 'front'
Say ("  an aspect ratio replaces the size; zoom, torch, mic, facing   {0}" -f (Mark ((Test-Has $arguments '--camera-ar=4:3') -and
    -not (@($arguments) -match '^--camera-size') -and (Test-Has $arguments '--camera-zoom=2') -and (Test-Has $arguments '--camera-torch') -and
    (Test-Has $arguments '--audio-source=mic') -and (Test-Has $arguments '--camera-facing=front') -and
    -not (@($arguments) -match '^--camera-id') -and (Test-Has $arguments '--window-title=camera-front'))))
$ui.MediaCameraAr.Text = '(size)'
$ui.MediaCameraZoom.Text = '1'
$ui.MediaCameraTorch.IsChecked = $false
$ui.MediaCameraMic.IsChecked = $false
$ui.MediaCamera.Items.Remove('2  -  front  1920x1080')
$ui.MediaCamera.SelectedIndex = 0
$line = Join-MediaArguments -Arguments @('-s', 'X', '--record=C:\a b\c.mp4', '--no-audio')
Say ("  a file name with a space stays one argument   {0}" -f (Mark ($line -eq '-s X "--record=C:\a b\c.mp4" --no-audio')))

Say ''
Say '== settings =='
$kept = @($script:settingHandlers | ForEach-Object { $_.Name } | Where-Object { $_ -like 'Media.*' })
$expected = @('Media.AudioSource', 'Media.AudioCodec', 'Media.AudioBitrate', 'Media.AudioDup', 'Media.AudioBuffer')
Say ("  kept: {0}   {1}" -f ($kept -join ', '), (Mark ((@($expected | Where-Object { $kept -notcontains $_ }).Count -eq 0))))
Say ("  the encoder is not kept   {0}" -f (Mark (@($kept | Where-Object { $_ -match 'Encoder' }).Count -eq 0)))

Say ''
Say '== the phone lists (scrcpy --list-*, reads only) =='
$first = Get-SelectedDevice
if ($null -eq $first -or $first.State -ne 'device' -or -not $script:scrcpyPath) {
    Say '  no ready phone or no scrcpy - skipped'
} else {
    Update-CameraList
    $null = Wait-Idle -Seconds 60
    Say ("  List cameras: {0} entr(ies)   {1}" -f $ui.MediaCamera.Items.Count, (Mark ($ui.MediaCamera.Items.Count -ge 1 -and "$($ui.MediaCamera.SelectedItem)" -ne 'press "List cameras"')))
    Update-CameraSizeList
    $null = Wait-Idle -Seconds 60
    Say ("  Sizes: {0} choice(s), sensor max last   {1}" -f $ui.MediaCameraSize.Items.Count, (Mark ("$(@($ui.MediaCameraSize.Items)[-1])" -eq 'sensor max')))
    Update-AudioCodecList
    $null = Wait-Idle -Seconds 60
    $codecs = @($ui.MediaAudioCodec.Items)
    Say ("  Codecs: {0}   {1}" -f ($codecs -join ', '), (Mark ($codecs -contains 'raw' -and $codecs[0] -eq 'default')))
    $codec = "$($ui.MediaAudioCodec.SelectedItem)"; if ($codec -eq 'default') { $codec = 'opus' }
    $expectedCount = 1 + @($script:audioEncoders | Where-Object { $_.Codec -eq $codec }).Count
    Say ("  encoders offered for {0}: {1}   {2}" -f $codec, ($ui.MediaAudioEncoder.Items.Count - 1), (Mark ($ui.MediaAudioEncoder.Items.Count -eq $expectedCount -and $ui.MediaAudioEncoder.IsEnabled -eq ($expectedCount -gt 1))))
}

Say ''
Say '== as a PC camera =='
Say ("  Use on, Stop off, nothing running   {0}" -f (Mark ($ui.MediaVCamStart.IsEnabled -and -not $ui.MediaVCamStop.IsEnabled -and -not (Test-VCamRunning))))
Say ("  Camera offers Front, Back, As picked above; Front first   {0}" -f (Mark ((@($ui.MediaVCamWhich.Items) -join ',') -eq 'Front,Back,As picked above' -and "$($ui.MediaVCamWhich.SelectedItem)" -eq 'Front')))
$choice = Get-PcCameraChoice
Say ("  Front picks the front camera   {0}" -f (Mark ($choice.Facing -eq 'front' -and -not $choice.Id)))
$ui.MediaVCamWhich.SelectedItem = 'Back'
$choice = Get-PcCameraChoice
Say ("  Back picks the back camera, nothing starts while off   {0}" -f (Mark ($choice.Facing -eq 'back' -and -not $choice.Id -and -not (Test-VCamRunning))))
$ui.MediaVCamWhich.SelectedItem = 'As picked above'
$keepFacing = "$($ui.MediaCameraFacing.SelectedItem)"
$ui.MediaCameraFacing.SelectedItem = 'back'
$choice = Get-PcCameraChoice
Say ("  a facing picks by facing   {0}" -f (Mark ($choice.Facing -eq 'back' -and -not $choice.Id)))
$ui.MediaCameraFacing.SelectedItem = 'by id'
$null = $ui.MediaCamera.Items.Add('2  -  front  1920x1080')
$ui.MediaCamera.SelectedItem = '2  -  front  1920x1080'
$choice = Get-PcCameraChoice
Say ("  by id takes the listed id   {0}" -f (Mark ($choice.Id -eq '2' -and -not $choice.Facing)))
$ui.MediaCamera.Items.Remove('2  -  front  1920x1080')
$ui.MediaCamera.SelectedIndex = 0
$choice = Get-PcCameraChoice
$first = Get-SelectedDevice
if ("$($ui.MediaCamera.SelectedItem)" -notmatch '^\d') {
    Say ("  nothing listed: the front camera   {0}" -f (Mark ($choice.Facing -eq 'front' -and -not $choice.Id)))
}
$ui.MediaCameraFacing.SelectedItem = $keepFacing
$state = Get-VCamState
Say ("  state: need '{0}'" -f $state.Need)
if ($state.Ready -and $null -ne $first -and $first.State -eq 'device') {
    # streams the phone camera for a few seconds; nothing on the phone changes
    $ui.MediaVCamWhich.SelectedItem = 'Front'
    Start-PcCamera
    Say ("  on: Use off, Stop on   {0}" -f (Mark ((Test-VCamRunning) -and -not $ui.MediaVCamStart.IsEnabled -and $ui.MediaVCamStop.IsEnabled)))
    $peek = @(& (Join-Path $state.Folder 'AndroidDC.VCamHost.exe') peek 2>&1 | ForEach-Object { "$_" })
    Say ("  an app sees the phone: {0}   {1}" -f ($peek -join ' '), (Mark ($LASTEXITCODE -eq 0)))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ui.MediaVCamWhich.SelectedItem = 'Back'
    Say ("  Back while on: switched in {0} ms, still on   {1}" -f $watch.ElapsedMilliseconds, (Mark ((Test-VCamRunning) -and $script:vcamCamera.Facing -eq 'back' -and $script:pcCameraShown -eq 1)))
    $peek = @(& (Join-Path $state.Folder 'AndroidDC.VCamHost.exe') peek 2>&1 | ForEach-Object { "$_" })
    Say ("  an app sees the back camera: {0}   {1}" -f ($peek -join ' '), (Mark ($LASTEXITCODE -eq 0)))
    $ui.MediaVCamWhich.SelectedItem = 'Front'
    Say ("  Front again   {0}" -f (Mark ((Test-VCamRunning) -and $script:vcamCamera.Facing -eq 'front')))
    Stop-PcCamera
    Say ("  off: Use on, Stop off   {0}" -f (Mark (-not (Test-VCamRunning) -and $ui.MediaVCamStart.IsEnabled -and -not $ui.MediaVCamStop.IsEnabled)))
} else {
    Say '  not registered here, or no ready phone - the start is skipped'
}

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "media-$size"))
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'media').Root)
    Say ("  {0}: nothing past the right edge   {1}" -f $size, (Mark ($outside.Count -eq 0)))
    foreach ($entry in $outside) { Say "    $entry" }
}
Set-WindowSize 'default'
