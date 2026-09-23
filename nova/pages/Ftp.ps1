. (Join-Path $script:toolsRoot 'shared\Ftp.ps1')

$ftpPage = Register-Page -Key 'ftp' -Title 'FTP' -Glyph 'E8B7' -Section 'Workspace' -Xaml 'Ftp.xaml' `
    -OnShow { Update-FtpAddress; Update-FtpPage } -OnDeviceChanged { Update-FtpAddress; Update-FtpPage } `
    -Refresh { Update-FtpAddress; Update-FtpPage }

$script:ftpSerial = $null
$script:ftpUri = $null
$script:ftpUsername = $null
$script:ftpPassword = $null

# Before the server runs, the address box shows where it will be: the phone's Wi-Fi IP and the port.
function Update-FtpAddress {
    if ($script:ftpUri) { return }
    $device = Get-SelectedDevice
    $serial = if ($device -and $device.State -eq 'device') { $device.Serial }
    $address = $null
    try { $address = Get-AndroidDcFtpPreviewAddress -Serial $serial -Port $ui.FtpPort.Text } catch {}
    $ui.FtpAddress.Text = if ($address) { $address }
        elseif ($serial) { 'The phone has no Wi-Fi address. Connect it to the same network as this PC.' }
        else { 'Select a phone to see its address.' }
}

function Update-FtpPage {
    $running = $null -ne $script:ftpUri
    $ui.FtpUsername.IsEnabled = -not $running
    $ui.FtpPassword.IsEnabled = -not $running
    $ui.FtpPort.IsEnabled = -not $running
    $ui.FtpGenerate.IsEnabled = -not $running
    $ui.FtpStart.IsEnabled = -not $running
    $ui.FtpStop.IsEnabled = $running
    $ui.FtpExplorer.IsEnabled = $running
    $ui.FtpTest.IsEnabled = $running
    $ui.FtpCopy.IsEnabled = $running
}

function Invoke-NovaFtpAction {
    param([ValidateSet('Start','Stop','Test','Explorer','Copy')][string]$Action)
    $ui.FtpStatus.Text = 'Working...'
    $ui.FtpStart.IsEnabled = $false
    $ui.FtpStop.IsEnabled = $false
    try {
        switch ($Action) {
            'Start' {
                $serial = Get-TargetSerial
                if (-not $serial) { throw 'Select a phone first.' }
                $port = 0
                if (-not [int]::TryParse($ui.FtpPort.Text, [ref]$port)) { throw 'Enter a valid port number.' }
                $username = $ui.FtpUsername.Text
                $password = $ui.FtpPassword.Text
                $started = Start-AndroidDcRawFtp -Serial $serial -Username $username -Password $password -Port $port
                $script:ftpSerial = $serial
                $script:ftpUri = $started.Uri
                $script:ftpUsername = $username
                $script:ftpPassword = $password
                $ui.FtpAddress.Text = $started.Uri.AbsoluteUri
                $null = Test-FilesFtpEndpoint -Uri $started.Uri -Username $username -Password $password
                $ui.FtpStatus.Text = 'Server ready. Open it in Explorer to browse and transfer files.'
            }
            'Stop' {
                $ui.FtpStatus.Text = Stop-AndroidDcRawFtp -Serial $script:ftpSerial
                $script:ftpSerial = $null
                $script:ftpUri = $null
                $script:ftpUsername = $null
                $script:ftpPassword = $null
                Update-FtpAddress
            }
            'Test' {
                $ui.FtpStatus.Text = Test-FilesFtpEndpoint -Uri $script:ftpUri -Username $script:ftpUsername -Password $script:ftpPassword
            }
            'Explorer' {
                Open-AndroidDcFtpInExplorer -Uri $script:ftpUri -Username $script:ftpUsername -Password $script:ftpPassword
                $ui.FtpStatus.Text = 'Opened the phone in Windows File Explorer.'
            }
            'Copy' {
                [Windows.Clipboard]::SetText($script:ftpUri.AbsoluteUri)
                $ui.FtpStatus.Text = 'Address copied.'
            }
        }
    } catch { $ui.FtpStatus.Text = $_.Exception.Message }
    finally { Update-FtpPage }
}

$defaults = Get-AndroidDcFtpDefaultCredentials
$ui.FtpUsername.Text = $defaults.Username
$ui.FtpPassword.Text = $defaults.Password
$ui.FtpPort.Add_TextChanged({
    if (-not $script:ftpUri -and $ui.FtpAddress.Text -match '^ftp://([^:/]+):\d*/$') {
        $ui.FtpAddress.Text = "ftp://$($Matches[1]):$($ui.FtpPort.Text.Trim())/"
    }
})
$ui.FtpGenerate.Add_Click({
    $generated = New-AndroidDcFtpCredentials
    $ui.FtpUsername.Text = $generated.Username
    $ui.FtpPassword.Text = $generated.Password
})
$ui.FtpStart.Add_Click({ Invoke-NovaFtpAction -Action Start })
$ui.FtpStop.Add_Click({ Invoke-NovaFtpAction -Action Stop })
$ui.FtpTest.Add_Click({ Invoke-NovaFtpAction -Action Test })
$ui.FtpExplorer.Add_Click({ Invoke-NovaFtpAction -Action Explorer })
$ui.FtpCopy.Add_Click({ Invoke-NovaFtpAction -Action Copy })
Update-FtpPage
