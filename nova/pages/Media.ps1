# pages\Media.ps1 - the phone camera streamed to a scrcpy window, and the
# phone's sound (microphone, output, calls) played or recorded on the PC.
# Ported from the "Cam / Mic" tab.

$mediaPage = Register-Page -Key 'media' -Title 'Camera & mic' -Glyph 'E722' -Section 'Workspace' -Xaml 'Media.xaml' `
    -OnShow { Update-MediaButtons } -OnDeviceChanged { Reset-MediaForDevice } -Refresh { Update-CameraList }

$script:audioProcess = $null
$script:cameraProcesses = @()
$script:cameraCount = 0
$script:audioEncoders = @()
# the phone the camera, size and encoder lists were read from
$script:mediaSerial = $null

$script:mediaCameraSizes = @('1920x1080', '1280x720', '3840x2160', '640x480', 'sensor max')
$script:mediaNoCameraYet = 'press "List cameras"'

# ----------------------------------------------------------------- helpers ----

function Set-MediaItems {
    param($Combo, [string[]]$Items)
    $Combo.Items.Clear()
    foreach ($item in $Items) { $null = $Combo.Items.Add($item) }
}

function Join-MediaArguments {
    # one command line for Start-Process, which joins its arguments with
    # spaces and quotes none: a file name with a space would split in two
    param([string[]]$Arguments)
    return (@($Arguments | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' ')
}

function Get-DeviceCapabilityList {
    <#
        Asks scrcpy what this phone actually supports and returns the lines it
        printed. scrcpy writes these lists to stderr and exits, so a plain call
        is enough - there is no session to keep.
    #>
    param([string]$Serial, [string]$Switch)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return @() }

    Write-Log "scrcpy $Switch ..." $colorStep
    $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $Serial, $Switch) -TimeoutMs 60000
    return @($result.Lines | Where-Object { $_ -and $_.Trim() })
}

# ------------------------------------------------------------------ camera ----

function Update-CameraList {
    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Write-Log "Reading the camera list of $serial ..." $colorStep
    $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $serial, '--list-cameras') -TimeoutMs 60000

    $ui.MediaCamera.Items.Clear()
    foreach ($line in @($result.Lines)) {
        # --camera-id=0    (back, 4080x3072, fps={10, 15, 20, 24, 30}, ...)
        if ("$line" -match '--camera-id=(\d+)\s+\((\w+),\s*(\d+x\d+)') {
            $null = $ui.MediaCamera.Items.Add("$($Matches[1])  -  $($Matches[2])  $($Matches[3])")
            Write-Log ("  " + "$line".Trim()) $colorInfo
        }
    }

    if ($ui.MediaCamera.Items.Count -eq 0) {
        $null = $ui.MediaCamera.Items.Add('no camera reported')
        Write-Log 'The device reported no camera (needs Android 12 or newer).' $colorBad
    }
    $ui.MediaCamera.SelectedIndex = 0
    $script:mediaSerial = $serial
}

function Update-CameraSizeList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $lines = Get-DeviceCapabilityList -Serial $serial -Switch '--list-camera-sizes'
    $sizes = @()
    foreach ($line in $lines) {
        foreach ($match in [regex]::Matches($line, '\b(\d{3,5}x\d{3,5})\b')) { $sizes += $match.Groups[1].Value }
    }
    # widest first, so the useful ones are at the top
    $sizes = @($sizes | Sort-Object -Unique | Sort-Object -Property @{
        Expression = { [int](($_ -split 'x')[0]) } } -Descending)

    if ($sizes.Count -eq 0) {
        Write-Log 'scrcpy listed no camera sizes; the fixed choices are still there.' $colorWarn
        foreach ($line in ($lines | Select-Object -Last 3)) { Write-Log ("  " + $line) $colorInfo }
        return
    }

    $keep = $ui.MediaCameraSize.Text
    Set-MediaItems -Combo $ui.MediaCameraSize -Items ($sizes + 'sensor max')
    $ui.MediaCameraSize.Text = $keep
    $script:mediaSerial = $serial
    Write-Log ("$($sizes.Count) camera size(s) reported by $serial.") $colorGood
}

function Get-CameraArguments {
    param([string]$Serial, [string]$Facing)

    $arguments = @('-s', $Serial, '--video-source=camera')

    if ($Facing) {
        $arguments += "--camera-facing=$Facing"
    } elseif ("$($ui.MediaCameraFacing.SelectedItem)" -ne 'by id') {
        $arguments += "--camera-facing=$($ui.MediaCameraFacing.SelectedItem)"
    } else {
        $selected = "$($ui.MediaCamera.SelectedItem)"
        if ($selected -match '^(\d+)') { $arguments += "--camera-id=$($Matches[1])" }
    }

    # scrcpy takes either an explicit size or an aspect ratio, never both
    $ratio = "$($ui.MediaCameraAr.Text)".Trim()
    $size = "$($ui.MediaCameraSize.Text)".Trim()
    if ($ratio -and $ratio -ne '(size)') {
        $arguments += "--camera-ar=$ratio"
    } elseif ($size -and $size -ne 'sensor max') {
        $arguments += "--camera-size=$size"
    }

    $fps = "$($ui.MediaCameraFps.Text)".Trim()
    if ($fps) { $arguments += "--camera-fps=$fps" }

    if ($ui.MediaCameraHighSpeed.IsChecked) { $arguments += '--camera-high-speed' }

    $zoom = "$($ui.MediaCameraZoom.Text)".Trim()
    if ($zoom -and $zoom -ne '1' -and $zoom -match '^[\d.]+$') { $arguments += "--camera-zoom=$zoom" }
    if ($ui.MediaCameraTorch.IsChecked) { $arguments += '--camera-torch' }

    if ($ui.MediaCameraMic.IsChecked) {
        $arguments += '--audio-source=mic'
    } else {
        $arguments += '--no-audio'
    }

    if ($ui.MediaCameraRecord.IsChecked) {
        $file = "$($ui.MediaCameraFile.Text)".Trim()
        if (-not $file) {
            $file = Join-Path ([Environment]::GetFolderPath('MyVideos')) ('camera-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
            $ui.MediaCameraFile.Text = $file
        }
        $arguments += "--record=$file"
    }

    # no spaces in the title: one word is one argument, whatever quotes it
    $title = if ($Facing) { "camera-$Facing" } else { 'camera' }
    $arguments += "--window-title=$title"
    return $arguments
}

function Start-Camera {
    param([string]$Facing)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $arguments = Get-CameraArguments -Serial $serial -Facing $Facing
    Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

    # a file pair per window: a second camera must not find the first one's files locked
    $script:cameraCount++
    $stdout = Join-Path $env:TEMP ("androiddc-nova-$PID.camera$($script:cameraCount).out")
    $stderr = Join-Path $env:TEMP ("androiddc-nova-$PID.camera$($script:cameraCount).err")
    $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList (Join-MediaArguments -Arguments $arguments) -PassThru `
        -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    $script:cameraProcesses += $process
    # Mirroring's Close-Scrcpy closes every scrcpy window, the camera ones too
    if (Get-Variable -Name scrcpyProcesses -Scope Script -ErrorAction SilentlyContinue) { $script:scrcpyProcesses += $process }

    Wait-Pumped -Milliseconds 3000
    $process.Refresh()

    if ($process.HasExited) {
        Write-Log "The camera did not start (exit $($process.ExitCode))." $colorBad
        foreach ($file in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $file) {
                $text = (@(Get-Content -LiteralPath $file -Tail 6) -join [Environment]::NewLine)
                if ($text.Trim()) { Write-Log $text $colorWarn }
            }
        }
    } else {
        Write-Log "Camera streaming (PID $($process.Id), window '$($process.MainWindowTitle)')." $colorGood
    }
}

function Stop-Camera {
    $stopped = 0
    foreach ($process in @($script:cameraProcesses)) {
        try {
            if (-not $process.HasExited) { $process.Kill(); $stopped++ }
        } catch { }
    }
    $script:cameraProcesses = @()
    Write-Log "Stopped $stopped camera window(s)." $colorInfo
}

# ------------------------------------------------------------------- audio ----

function Update-AudioCodecList {
    # the audio half of Update-EncoderList; the video half is Mirroring's
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $lines = Get-DeviceCapabilityList -Serial $serial -Switch '--list-encoders'
    # scrcpy prints one line per encoder, in the shape
    #     --audio-codec=opus --audio-encoder=c2.android.opus.encoder   (sw)
    $audio = @()
    $encoders = @()
    foreach ($line in $lines) {
        if ($line -match '--video-codec=') { continue }
        if ($line -match '--audio-codec=(\S+)\s+--audio-encoder=(\S+)') {
            $codec = $Matches[1]
            $name = $Matches[2]
            $audio += $codec
            # an alias is the same encoder under a second name: offer it once
            if ($line -notmatch 'alias for') {
                $encoders += [PSCustomObject]@{ Codec = $codec; Name = $name }
            }
        } elseif ($line -match '--audio-codec=(\S+)') {
            $audio += $Matches[1]
        }
    }
    $audio = @($audio | Sort-Object -Unique)

    if ($audio.Count -eq 0) {
        Write-Log 'scrcpy listed no encoders; the fixed choices are still there.' $colorWarn
        foreach ($line in ($lines | Select-Object -Last 3)) { Write-Log ("  " + $line) $colorInfo }
        return
    }

    $keep = "$($ui.MediaAudioCodec.SelectedItem)"
    $script:audioEncoders = $encoders
    Set-MediaItems -Combo $ui.MediaAudioCodec -Items (@('default') + $audio)
    # raw is not an encoder, so the phone never lists it - yet scrcpy
    # accepts it, and a refresh must not take a working choice away
    if (-not $ui.MediaAudioCodec.Items.Contains('raw')) { $null = $ui.MediaAudioCodec.Items.Add('raw') }
    $ui.MediaAudioCodec.SelectedIndex = [Math]::Max(0, $ui.MediaAudioCodec.Items.IndexOf($keep))
    Update-AudioEncoderChoices
    $script:mediaSerial = $serial
    Write-Log ("audio codecs on this phone: " + ($audio -join ', ')) $colorGood
    Write-Log ("audio encoders: " + (($encoders | ForEach-Object { $_.Name }) -join ', ')) $colorGood
}

function Update-AudioEncoderChoices {
    <#
        scrcpy refuses an encoder that does not produce the chosen codec, so
        only the matching ones are offered. "default" leaves the choice to the
        phone. Before the phone has been asked there is nothing to offer, and
        the list stays disabled rather than pretending.
    #>
    $codec = "$($ui.MediaAudioCodec.SelectedItem)"
    if ($codec -eq 'default') { $codec = 'opus' }   # scrcpy's own default

    $keep = "$($ui.MediaAudioEncoder.SelectedItem)"
    $names = @('default')
    foreach ($encoder in @($script:audioEncoders)) {
        if ($encoder.Codec -eq $codec) { $names += $encoder.Name }
    }
    Set-MediaItems -Combo $ui.MediaAudioEncoder -Items $names
    $ui.MediaAudioEncoder.SelectedIndex = [Math]::Max(0, $ui.MediaAudioEncoder.Items.IndexOf($keep))
    $ui.MediaAudioEncoder.IsEnabled = ($ui.MediaAudioEncoder.Items.Count -gt 1)
}

function Get-AudioFileKind {
    <#
        scrcpy picks the container from the file name, and each container
        takes only some codecs - an .opus file cannot hold aac. So the name
        offered for a recording follows the codec. .mka takes all of them.
    #>
    param([string]$Codec)

    switch ($Codec) {
        'aac' { return 'm4a' }
        'flac' { return 'flac' }
        'raw' { return 'wav' }
        default { return 'opus' }   # opus, and "default", which is opus
    }
}

function Get-AudioArguments {
    <#
        The scrcpy command line for Listen and Record, built without starting
        anything, so what gets sent can be checked on its own. A choice that
        cannot apply is dropped with a line in the log saying why.
    #>
    param([string]$Serial, [switch]$ToFile)

    $source = "$($ui.MediaAudioSource.SelectedItem)"
    $arguments = @('-s', $Serial, '--no-video', "--audio-source=$source")

    $codec = "$($ui.MediaAudioCodec.SelectedItem)"
    if ($codec -and $codec -ne 'default') { $arguments += "--audio-codec=$codec" }

    $encoder = "$($ui.MediaAudioEncoder.SelectedItem)"
    if ($encoder -and $encoder -ne 'default') { $arguments += "--audio-encoder=$encoder" }

    $rate = "$($ui.MediaAudioBitrate.Text)".Trim()
    if ($rate -and $rate -ne 'default') { $arguments += "--audio-bit-rate=$rate" }

    $buffer = "$($ui.MediaAudioBuffer.Text)".Trim()
    if ($buffer -match '^\d+$') { $arguments += "--audio-buffer=$buffer" }

    if ($ui.MediaAudioDup.IsChecked) {
        # --audio-dup needs the output source, and needs playback left on:
        # scrcpy refuses it outright while recording, which turns playback off
        if ($ToFile) {
            Write-Log "'keep playing on the phone' cannot be used while recording; recording without it." $colorWarn
        } elseif ($source -ne 'output') {
            Write-Log "'keep playing on the phone' works with the output source only, not '$source'." $colorWarn
        } else {
            $arguments += '--audio-dup'
        }
    }

    return $arguments
}

function Start-AudioListen {
    param([switch]$ToFile)

    if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $source = "$($ui.MediaAudioSource.SelectedItem)"
    $arguments = @(Get-AudioArguments -Serial $serial -ToFile:$ToFile)

    if ($ToFile) {
        $kind = Get-AudioFileKind -Codec "$($ui.MediaAudioCodec.SelectedItem)"
        # the filter for the codec's own kind comes first, so it is the one shown
        $filters = [ordered]@{
            'opus' = 'Opus (*.opus)|*.opus'; 'm4a' = 'MP4 audio (*.m4a)|*.m4a'
            'flac' = 'FLAC (*.flac)|*.flac'; 'wav' = 'WAV (*.wav)|*.wav'
        }
        $parts = @($filters[$kind]) + @($filters.Keys | Where-Object { $_ -ne $kind } | ForEach-Object { $filters[$_] }) +
            @('Matroska audio (*.mka)|*.mka')
        $file = Select-SaveFile -Filter ($parts -join '|') -FileName ("phone-audio-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".$kind")
        if (-not $file) { return }
        $arguments += @('--no-playback', "--record=$file")
    } else {
        $arguments += '--no-window'
    }

    Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep
    $script:audioProcess = Start-Process -FilePath $script:scrcpyPath -ArgumentList (Join-MediaArguments -Arguments $arguments) `
        -NoNewWindow -PassThru
    Update-MediaButtons
    Write-Log "Listening to '$source' on $serial (PID $($script:audioProcess.Id))." $colorGood
    Write-Log 'Android shows a "recording" indicator while the mic is captured.' $colorWarn
}

function Stop-AudioListen {
    if ($script:audioProcess) {
        try { if (-not $script:audioProcess.HasExited) { $script:audioProcess.Kill() } } catch { }
        $script:audioProcess = $null
        Write-Log 'Audio stream stopped.' $colorWarn
    }
    Update-MediaButtons
}

# -------------------------------------------------------------------- page ----

function Update-MediaButtons {
    # Listen while nothing plays, Stop while something does; a stream that
    # ended by itself gives Listen back
    if ($script:audioProcess) {
        $ended = $true
        try { $ended = $script:audioProcess.HasExited } catch { }
        if ($ended) { $script:audioProcess = $null }
    }
    $playing = ($null -ne $script:audioProcess)
    $ui.MediaListen.IsEnabled = -not $playing
    $ui.MediaRecordAudio.IsEnabled = -not $playing
    $ui.MediaListenStop.IsEnabled = $playing
}

function Reset-MediaForDevice {
    # the camera, size and encoder lists belong to the phone they came from
    if (-not $script:mediaSerial -or $script:mediaSerial -eq (Get-SelectedSerial)) { return }
    Set-MediaItems -Combo $ui.MediaCamera -Items @($script:mediaNoCameraYet)
    $ui.MediaCamera.SelectedIndex = 0
    $keep = $ui.MediaCameraSize.Text
    Set-MediaItems -Combo $ui.MediaCameraSize -Items $script:mediaCameraSizes
    $ui.MediaCameraSize.Text = $keep
    $script:audioEncoders = @()
    Update-AudioEncoderChoices
    $script:mediaSerial = $null
}

# the fixed choices, until the phone is asked
Set-MediaItems -Combo $ui.MediaCamera -Items @($script:mediaNoCameraYet)
$ui.MediaCamera.SelectedIndex = 0
Set-MediaItems -Combo $ui.MediaCameraFacing -Items @('by id', 'back', 'front', 'external')
$ui.MediaCameraFacing.SelectedIndex = 0
Set-MediaItems -Combo $ui.MediaCameraSize -Items $script:mediaCameraSizes
$ui.MediaCameraSize.Text = '1920x1080'
Set-MediaItems -Combo $ui.MediaCameraFps -Items @('30', '24', '20', '15', '10')
$ui.MediaCameraFps.Text = '30'
Set-MediaItems -Combo $ui.MediaCameraAr -Items @('(size)', '16:9', '4:3', '1:1')
$ui.MediaCameraAr.Text = '(size)'
Set-MediaItems -Combo $ui.MediaCameraZoom -Items @('1', '2', '3', '5', '10')
$ui.MediaCameraZoom.Text = '1'
Set-MediaItems -Combo $ui.MediaAudioSource -Items @(
    'mic', 'mic-voice-communication', 'mic-unprocessed', 'mic-voice-recognition',
    'output', 'playback', 'voice-call', 'voice-call-uplink', 'voice-call-downlink')
$ui.MediaAudioSource.SelectedIndex = 0
Set-MediaItems -Combo $ui.MediaAudioCodec -Items @('default', 'opus', 'aac', 'flac', 'raw')
$ui.MediaAudioCodec.SelectedIndex = 0
Set-MediaItems -Combo $ui.MediaAudioEncoder -Items @('default')
$ui.MediaAudioEncoder.SelectedIndex = 0
Set-MediaItems -Combo $ui.MediaAudioBitrate -Items @('default', '64K', '128K', '196K', '256K')
$ui.MediaAudioBitrate.Text = 'default'

# ------------------------------------------------------------------ events ----

$ui.MediaCameraList.Add_Click({ Update-CameraList })
$ui.MediaCameraSizes.Add_Click({ Update-CameraSizeList })
$ui.MediaCameraStart.Add_Click({ Start-Camera })
$ui.MediaCameraFront.Add_Click({ Start-Camera -Facing 'front' })
$ui.MediaCameraBack.Add_Click({ Start-Camera -Facing 'back' })
$ui.MediaCameraStop.Add_Click({ Stop-Camera })
$ui.MediaCameraCommand.Add_Click({
    $serial = Get-SelectedSerial
    Write-Log ('scrcpy ' + ((Get-CameraArguments -Serial $serial) -join ' ')) $colorStep
})
$ui.MediaCameraBrowse.Add_Click({
    $file = Select-SaveFile -Filter 'MP4 (*.mp4)|*.mp4|Matroska (*.mkv)|*.mkv' -FileName ('camera-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
    if ($file) {
        $ui.MediaCameraFile.Text = $file
        $ui.MediaCameraRecord.IsChecked = $true
    }
})

$ui.MediaListen.Add_Click({ Start-AudioListen })
$ui.MediaListenStop.Add_Click({ Stop-AudioListen })
$ui.MediaRecordAudio.Add_Click({ Start-AudioListen -ToFile })
$ui.MediaAudioCodecs.Add_Click({ Update-AudioCodecList })
$ui.MediaAudioCodec.Add_SelectionChanged({ Update-AudioEncoderChoices })

# the encoder is deliberately not kept: its names differ from phone to phone,
# and one saved from another phone would make scrcpy fail
Register-Setting -Name 'Media.AudioSource' -Get { "$($ui.MediaAudioSource.SelectedItem)" } -Set {
    param($v) if ($v -and $ui.MediaAudioSource.Items.Contains("$v")) { $ui.MediaAudioSource.SelectedItem = "$v" } }
Register-Setting -Name 'Media.AudioCodec' -Get { "$($ui.MediaAudioCodec.SelectedItem)" } -Set {
    param($v) if ($v -and $ui.MediaAudioCodec.Items.Contains("$v")) { $ui.MediaAudioCodec.SelectedItem = "$v" } }
Register-Setting -Name 'Media.AudioBitrate' -Get { $ui.MediaAudioBitrate.Text } -Set { param($v) if ($v) { $ui.MediaAudioBitrate.Text = "$v" } }
Register-Setting -Name 'Media.AudioDup' -Get { [bool]$ui.MediaAudioDup.IsChecked } -Set { param($v) if ($null -ne $v) { $ui.MediaAudioDup.IsChecked = [bool]$v } }
Register-Setting -Name 'Media.AudioBuffer' -Get { $ui.MediaAudioBuffer.Text } -Set { param($v) if ($null -ne $v) { $ui.MediaAudioBuffer.Text = "$v" } }

Register-Cleanup {
    Stop-AudioListen
    if (@($script:cameraProcesses).Count -gt 0) { Stop-Camera }
}
