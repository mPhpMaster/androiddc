Say '== FTP page =='
Show-Page -Page 'ftp'
Wait-Pumped -Milliseconds 250
$names = @('FtpUsername','FtpPassword','FtpPort','FtpGenerate','FtpStart','FtpStop','FtpAddress','FtpExplorer','FtpTest','FtpCopy','FtpStatus','FtpRemoveCompanion','PillFtp')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  controls available   {0}" -f (Mark ($missing.Count -eq 0)))
if ($script:ftpUri -and $script:ftpUsername) {
    Say ("  running login restored   {0}" -f (Mark ($ui.FtpUsername.Text -eq $script:ftpUsername -and $ui.FtpPassword.Text -eq $script:ftpPassword)))
} elseif (-not $script:ftpUri) {
    Say ("  default login filled   {0}" -f (Mark ($ui.FtpUsername.Text -eq 'pc' -and $ui.FtpPassword.Text -eq '123')))
}
Say ("  stop follows recovered server state   {0}" -f (Mark ($ui.FtpStop.IsEnabled -eq ($null -ne $script:ftpUri))))
if (Get-SelectedDevice) {
    $headerText = if ($script:ftpUri) { 'FTP running' } else { 'FTP off' }
    Say ("  header follows recovered server state   {0}" -f (Mark ($ui.PillFtp.Visibility -eq 'Visible' -and $ui.PillFtpText.Text -eq $headerText)))
}
if (Get-SelectedDevice) {
    $hasAddress = $ui.FtpAddress.Text -match '^ftp://\d+\.\d+\.\d+\.\d+:\d+/$'
    $noWifi = $ui.FtpAddress.Text -like 'The phone has no Wi-Fi address*'
    Say ("  FTP address or network guidance shown ({0})   {1}" -f $ui.FtpAddress.Text, (Mark ($hasAddress -or $noWifi)))
    if (-not $script:ftpUri -and $hasAddress) {
        $ui.FtpPort.Text = '2200'
        Say ("  address follows the port   {0}" -f (Mark ($ui.FtpAddress.Text -match ':2200/$')))
        $ui.FtpPort.Text = '2121'
    }
}
foreach ($size in @('default','min')) {
    Set-WindowSize -Size $size
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'ftp').Root)
    Say ("  $size layout ({0} outside)   {1}" -f $outside.Count, (Mark ($outside.Count -eq 0)))
    Say ("  $size picture: {0}" -f (Save-WindowPicture -Name "ftp-$size"))
}
