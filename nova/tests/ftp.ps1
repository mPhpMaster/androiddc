Say '== FTP page =='
Show-Page -Page 'ftp'
Wait-Pumped -Milliseconds 250
$names = @('FtpUsername','FtpPassword','FtpPort','FtpGenerate','FtpStart','FtpStop','FtpAddress','FtpExplorer','FtpTest','FtpCopy','FtpStatus')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  controls available   {0}" -f (Mark ($missing.Count -eq 0)))
Say ("  default login filled   {0}" -f (Mark ($ui.FtpUsername.Text -eq 'pc' -and $ui.FtpPassword.Text -eq 'pc123')))
Say ("  stop disabled before starting   {0}" -f (Mark (-not $ui.FtpStop.IsEnabled)))
if (Get-SelectedDevice) {
    Say ("  address shown before starting ({0})   {1}" -f $ui.FtpAddress.Text, (Mark ($ui.FtpAddress.Text -match '^ftp://\d+\.\d+\.\d+\.\d+:2121/$')))
    $ui.FtpPort.Text = '2200'
    Say ("  address follows the port   {0}" -f (Mark ($ui.FtpAddress.Text -match ':2200/$')))
    $ui.FtpPort.Text = '2121'
}
foreach ($size in @('default','min')) {
    Set-WindowSize -Size $size
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'ftp').Root)
    Say ("  $size layout ({0} outside)   {1}" -f $outside.Count, (Mark ($outside.Count -eq 0)))
    Say ("  $size picture: {0}" -f (Save-WindowPicture -Name "ftp-$size"))
}
