# needs: phone
# Cam / Mic audio: the encoder list read from the phone and following the
# codec, the command line, the file name that suits the codec, a real Listen
# with the chosen encoder, and the choices remembered across a restart.
# Listen captures the phone's output audio for a few seconds; nothing is saved.

function Show-Items { param($Combo) (@($Combo.Items) | ForEach-Object { "$_" }) -join ', ' }

Select-TestPhone
$tabs.SelectedTab = $tabCamera
Wait-Pumped -Milliseconds 500

Say '== before the phone is asked =='
Say ("encoders: {0}   enabled={1}   {2}" -f (Show-Items $cmbAudioEncoder), $cmbAudioEncoder.Enabled,
    (Mark (-not $cmbAudioEncoder.Enabled)))

Say ''
Say '== asked from this page =='
$btnAudioEncoders.PerformClick()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt 40 -and @($script:audioEncoders).Count -eq 0) { Wait-Pumped -Milliseconds 500 }
Say ("{0} encoder(s) after {1:N1} s   {2}" -f @($script:audioEncoders).Count, $watch.Elapsed.TotalSeconds, (Mark (@($script:audioEncoders).Count -gt 0)))
$codecs = @($cmbAudioCodec.Items | ForEach-Object { "$_" })
Say ("codecs: {0}" -f ($codecs -join ', '))
Say ("  raw still offered after the refresh: {0}" -f (Mark ($codecs -contains 'raw')))
$aliases = @($script:audioEncoders | Where-Object { $_.Name -like 'OMX.*' })
Say ("  aliases left out: {0}" -f (Mark ($aliases.Count -eq 0)))

Say ''
Say '== the encoder list follows the codec =='
foreach ($codec in @('default', 'opus', 'aac', 'flac', 'raw')) {
    if (-not $cmbAudioCodec.Items.Contains($codec)) { Say ("  {0,-8} not offered by this phone" -f $codec); continue }
    $cmbAudioCodec.SelectedItem = $codec
    Wait-Pumped -Milliseconds 150
    $offered = @($cmbAudioEncoder.Items | ForEach-Object { "$_" } | Where-Object { $_ -ne 'default' })
    $want = if ($codec -eq 'default') { 'opus' } else { $codec }
    $wrong = @($offered | Where-Object { $n = $_; -not @($script:audioEncoders | Where-Object { $_.Name -eq $n -and $_.Codec -eq $want }).Count })
    Say ("  {0,-8} -> [{1}]   {2}" -f $codec, ($offered -join ', '), (Mark ($wrong.Count -eq 0)))
}

Say ''
Say '== the command line =='
$cmbAudioSource.SelectedItem = 'output'
$pick = $null
foreach ($codec in @('aac', 'opus', 'flac')) {
    if (-not $cmbAudioCodec.Items.Contains($codec)) { continue }
    $cmbAudioCodec.SelectedItem = $codec
    Wait-Pumped -Milliseconds 150
    $encoder = @($cmbAudioEncoder.Items | ForEach-Object { "$_" } | Where-Object { $_ -ne 'default' })[0]
    if ($encoder) { $pick = @($codec, $encoder); break }
}
if (-not $pick) {
    Say 'SKIPPED - the phone offers no encoder for aac, opus or flac'
} else {
    $cmbAudioEncoder.SelectedItem = $pick[1]
    $cmbAudioBitrate.Text = '128K'
    $txtAudioBuffer.Text = '80'
    $chkAudioDup.Checked = $true
    $listen = @(Get-AudioArguments -Serial $TestSerial)
    Say ("listen: {0}" -f ($listen -join ' '))
    foreach ($want in @("--audio-codec=$($pick[0])", "--audio-encoder=$($pick[1])", '--audio-bit-rate=128K', '--audio-buffer=80', '--audio-dup')) {
        Say ("   {0,-44} {1}" -f $want, (Mark ($listen -contains $want)))
    }
    $record = @(Get-AudioArguments -Serial $TestSerial -ToFile)
    Say ("   --audio-dup dropped when recording          {0}" -f (Mark ($record -notcontains '--audio-dup')))
    $cmbAudioCodec.SelectedItem = 'default'
    Wait-Pumped -Milliseconds 150
    $plain = @(Get-AudioArguments -Serial $TestSerial)
    Say ("   default forces no codec and no encoder       {0}" -f (Mark (-not ($plain -match '^--audio-(codec|encoder)='))))
}

Say ''
Say '== the file name follows the codec =='
foreach ($pair in @(@('default', 'opus'), @('opus', 'opus'), @('aac', 'm4a'), @('flac', 'flac'), @('raw', 'wav'))) {
    $kind = Get-AudioFileKind -Codec $pair[0]
    Say ("   {0,-8} -> .{1,-5} {2}" -f $pair[0], $kind, (Mark ($kind -eq $pair[1])))
}

if ($pick) {
    Say ''
    Say '== it runs on the phone with the chosen encoder =='
    $chkAudioDup.Checked = $false
    $cmbAudioCodec.SelectedItem = $pick[0]
    Wait-Pumped -Milliseconds 150
    $cmbAudioEncoder.SelectedItem = $pick[1]
    # scrcpy refuses a bad encoder at once in its log, but only exits when its
    # server connection times out: measured 8.1, 11.4 and 12.3 s. So "still
    # running" means accepted only well after that - 20 s - and a refusal is
    # given 30 s to arrive. With 7 s, as first written, a refused encoder
    # looked exactly like a working one.
    $btnListen.PerformClick()
    Wait-Pumped -Milliseconds 20000
    $alive = $script:audioProcess -and -not $script:audioProcess.HasExited
    Say ("{0} + {1}: still running after 20 s   {2}" -f $pick[0], $pick[1], (Mark $alive))
    $btnListenStop.PerformClick()
    Wait-Pumped -Milliseconds 1500

    # the same signal must be able to fail, or "still running" proves nothing
    $null = $cmbAudioEncoder.Items.Add('c2.nonexistent.encoder')
    $cmbAudioEncoder.SelectedItem = 'c2.nonexistent.encoder'
    $btnListen.PerformClick()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 30 -and $script:audioProcess -and -not $script:audioProcess.HasExited) {
        Wait-Pumped -Milliseconds 250
    }
    $alive = $script:audioProcess -and -not $script:audioProcess.HasExited
    Say ("a made-up encoder is refused: scrcpy gone after {0:N1} s   {1}" -f $watch.Elapsed.TotalSeconds, (Mark (-not $alive)))
    $btnListenStop.PerformClick()
    Wait-Pumped -Milliseconds 1500
    Update-AudioEncoderChoices
}

Say ''
Say '== remembered across a restart =='
$cmbAudioSource.SelectedItem = 'mic-unprocessed'
$cmbAudioCodec.SelectedItem = 'flac'
$cmbAudioBitrate.Text = '196K'
$chkAudioDup.Checked = $true
$txtAudioBuffer.Text = '120'
Save-Settings
$saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
Say ("the encoder is not saved - it belongs to one phone   {0}" -f (Mark ($saved.PSObject.Properties.Name -notcontains 'AudioEncoder')))
$cmbAudioSource.SelectedItem = 'mic'
$cmbAudioCodec.SelectedItem = 'default'
$cmbAudioBitrate.Text = 'default'
$chkAudioDup.Checked = $false
$txtAudioBuffer.Text = ''
Restore-Settings
$back = "{0} {1} {2} {3} {4}" -f $cmbAudioSource.SelectedItem, $cmbAudioCodec.SelectedItem, $cmbAudioBitrate.Text,
    $chkAudioDup.Checked, $txtAudioBuffer.Text
Say ("restored: {0}   {1}" -f $back, (Mark ($back -eq 'mic-unprocessed flac 196K True 120')))
