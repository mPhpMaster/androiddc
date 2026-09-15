# The window around the pages: it opens, reads the device list, the log and
# the busy strip work, the keys do what they say, the log folds, and nothing
# in the header runs off the edge at the smallest size. Reads only.

Say '== startup =='
$idle = Wait-Idle -Seconds 30
Say ("  idle after the first device read   {0}" -f (Mark $idle))
Say ("  {0} page(s), {1} device(s), log has {2} line(s)   {3}" -f $script:pages.Count, $script:deviceRows.Count,
    $script:logLines.Count, (Mark ($script:logLines.Count -ge 4)))
Say ("  sharing pill says '{0}'   {1}" -f $ui.SharingText.Text, (Mark ($ui.SharingText.Text -eq 'Sharing: off')))

Say ''
Say '== the busy strip =='
$script:busy++
$script:busyWhat = 'adb shell settings get global wifi_on'
Wait-Pumped -Milliseconds 900
Say ("  shown while busy, names '{0}'   {1}" -f $ui.BusyText.Text,
    (Mark ($ui.BusyStrip.Visibility -eq 'Visible' -and $ui.BusyText.Text -eq 'adb shell settings get global wifi_on')))
$script:busy--
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($ui.BusyStrip.Visibility -eq 'Visible' -and $watch.Elapsed.TotalSeconds -lt 20) { Wait-Pumped -Milliseconds 200 }
Say ("  hidden again ({0:N1} s)   {1}" -f $watch.Elapsed.TotalSeconds, (Mark ($ui.BusyStrip.Visibility -ne 'Visible')))
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('settings get global wifi_on'))
$named = Get-BusyText -FilePath 'C:\tools\adb.exe' -ArgumentList @('-s', 'SERIAL1', 'shell', "echo $encoded | base64 -d | sh")
Say ("  names a base64 command as the command   {0}" -f (Mark ($named -eq 'adb shell settings get global wifi_on')))

Say ''
Say '== the log =='
Write-Log 'a step' $colorStep
Write-Log "two`nlines" $colorWarn
$lastTwo = @($script:logLines)[-2..-1] | ForEach-Object { $_.Text }
Say ("  a message with a line break is two lines   {0}" -f (Mark (($lastTwo -join '|') -eq 'two|lines')))
for ($i = 0; $i -lt 3010; $i++) { $script:logLines.Add([PSCustomObject]@{ Time = ''; Text = "x$i"; Brush = $null; Kind = 'info' }) }
Write-Log 'after the flood'
Say ("  capped at 3000 lines ({0})   {1}" -f $script:logLines.Count, (Mark ($script:logLines.Count -eq 3000)))
$handled = Invoke-WindowKey -Key ([System.Windows.Input.Key]::L) -Modifiers ([System.Windows.Input.ModifierKeys]::Control)
Say ("  Ctrl+L empties it   {0}" -f (Mark ($handled -and $script:logLines.Count -eq 0)))
$handled = Invoke-WindowKey -Key ([System.Windows.Input.Key]::A) -Modifiers ([System.Windows.Input.ModifierKeys]::None)
Say ("  a plain A is left alone   {0}" -f (Mark (-not $handled)))

$before = $ui.LogRow.Height.Value
Set-LogFolded -Folded $true
Wait-Pumped -Milliseconds 300
Say ("  folded: log row {0} -> {1}, list hidden   {2}" -f $before, $ui.LogRow.Height.Value,
    (Mark ($ui.LogRow.Height.Value -lt $before -and $ui.LogList.Visibility -eq 'Collapsed')))
Set-LogFolded -Folded $false
Wait-Pumped -Milliseconds 300
Say ("  unfolded: back to {0}   {1}" -f $ui.LogRow.Height.Value, (Mark ($ui.LogRow.Height.Value -eq $before)))

Say ''
Say '== dialogs and helpers =='
$box = New-Object System.Windows.Controls.TextBox
$box.Text = ' 99999 '
Say ("  a number box keeps its limits: {0}   {1}" -f (Get-NumberValue -Box $box -Default 5 -Minimum 1 -Maximum 65535), (Mark ($box.Text -eq '65535')))
$box.Text = 'abc'
Say ("  and falls back to the default: {0}   {1}" -f (Get-NumberValue -Box $box -Default 5), (Mark ($box.Text -eq '5')))

Say ''
Say '== the picture =='
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "shell-$size"))
    $header = $ui.HeaderMirror
    $right = $header.TransformToAncestor($script:window).Transform((New-Object System.Windows.Point(0, 0))).X + $header.ActualWidth
    Say ("  {0}: Mirror button ends at {1:N0} of {2:N0}   {3}" -f $size, $right, $script:window.ActualWidth,
        (Mark ($right -le $script:window.ActualWidth)))
}
