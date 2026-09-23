$tabs.SelectedTab = $tabFtp
$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 300
Say ("FTP tab selected   {0}" -f (Mark ($tabs.SelectedTab -eq $tabFtp)))
Say ("Remove control available   {0}" -f (Mark ($null -ne $script:classicFtp.Remove)))
if ($script:classicFtp.Uri -and $script:classicFtp.ActiveUsername) {
    Say ("Running login restored   {0}" -f (Mark ($script:classicFtp.Username.Text -eq $script:classicFtp.ActiveUsername)))
} elseif (-not $script:classicFtp.Uri) {
    Say ("Random login filled   {0}" -f (Mark ($script:classicFtp.Username.Text -match '^androiddc_[A-Za-z0-9_-]{8}$' -and $script:classicFtp.Password.Text.Length -ge 16)))
}
Say ("Stop follows recovered server state   {0}" -f (Mark ($script:classicFtp.Stop.Enabled -eq ($null -ne $script:classicFtp.Uri))))
if (@(Get-SelectedSerials).Count) {
    $address = $script:classicFtp.Address.Text
    $hasAddress = $address -match '^ftp://\d+\.\d+\.\d+\.\d+:\d+/$'
    Say ("Address or network guidance shown ($address)   {0}" -f (Mark ($hasAddress -or $address -like 'The phone has no Wi-Fi address*')))
    if (-not $script:classicFtp.Uri -and $hasAddress) {
        $script:classicFtp.Port.Text = '2200'
        Say ("Address follows the port   {0}" -f (Mark ($script:classicFtp.Address.Text -match ':2200/$')))
        $script:classicFtp.Port.Text = '2121'
    }
}
$shot = Join-Path $TestOutput 'ftp-classic-min.png'
$bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
try {
    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save($shot, [Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
Say "FTP picture: $shot"
