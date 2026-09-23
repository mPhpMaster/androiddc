Say '== FTP page =='
Show-Page -Page 'ftp'
Wait-Pumped -Milliseconds 250
$names = @('FtpUsername','FtpPassword','FtpPort','FtpGenerate','FtpStart','FtpStop','FtpAddress','FtpExplorer','FtpTest','FtpCopy','FtpStatus')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  controls available   {0}" -f (Mark ($missing.Count -eq 0)))
Say ("  random login filled   {0}" -f (Mark ($ui.FtpUsername.Text -and $ui.FtpPassword.Text.Length -ge 8)))
Say ("  stop disabled before starting   {0}" -f (Mark (-not $ui.FtpStop.IsEnabled)))
foreach ($size in @('default','min')) {
    Set-WindowSize -Size $size
    $outside = @(Get-OutsideElements -Root (Get-Page -Key 'ftp').Root)
    Say ("  $size layout ({0} outside)   {1}" -f $outside.Count, (Mark ($outside.Count -eq 0)))
    Say ("  $size picture: {0}" -f (Save-WindowPicture -Name "ftp-$size"))
}
