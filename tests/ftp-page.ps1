$tabs.SelectedTab = $tabFtp
$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 300
Say ("FTP tab selected   {0}" -f (Mark ($tabs.SelectedTab -eq $tabFtp)))
Say ("Default login filled   {0}" -f (Mark ($script:classicFtp.Username.Text -eq 'pc' -and $script:classicFtp.Password.Text -eq 'pc123')))
Say ("Stop disabled before starting   {0}" -f (Mark (-not $script:classicFtp.Stop.Enabled)))
if (@(Get-SelectedSerials).Count) {
    $address = $script:classicFtp.Address.Text
    Say ("Address shown before starting ($address)   {0}" -f (Mark ($address -match '^ftp://\d+\.\d+\.\d+\.\d+:2121/$')))
    $script:classicFtp.Port.Text = '2200'
    Say ("Address follows the port   {0}" -f (Mark ($script:classicFtp.Address.Text -match ':2200/$')))
    $script:classicFtp.Port.Text = '2121'
}
$shot = Join-Path $TestOutput 'ftp-classic-min.png'
$bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
try {
    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save($shot, [Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
Say "FTP picture: $shot"
