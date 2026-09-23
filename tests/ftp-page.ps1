$tabs.SelectedTab = $tabFtp
$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 300
Say ("FTP tab selected   {0}" -f (Mark ($tabs.SelectedTab -eq $tabFtp)))
Say ("Random login filled   {0}" -f (Mark ($script:classicFtp.Username.Text -and $script:classicFtp.Password.Text.Length -ge 8)))
Say ("Stop disabled before starting   {0}" -f (Mark (-not $script:classicFtp.Stop.Enabled)))
$shot = Join-Path $TestOutput 'ftp-classic-min.png'
$bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
try {
    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save($shot, [Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
Say "FTP picture: $shot"
