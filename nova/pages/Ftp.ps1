. (Join-Path $script:toolsRoot 'shared\Ftp.ps1')

$ftpPage = Register-Page -Key 'ftp' -Title 'FTP' -Glyph 'E8B7' -Section 'Workspace' -Xaml 'Ftp.xaml' `
    -OnShow { Restore-FtpPage; Update-FtpAddress; Update-FtpPage } -OnDeviceChanged { Restore-FtpPage; Update-FtpAddress; Update-FtpPage } `
    -Refresh { Restore-FtpPage; Update-FtpAddress; Update-FtpPage }

$script:ftpSerial = $null
$script:ftpUri = $null
$script:ftpUsername = $null
$script:ftpPassword = $null

function Update-FtpHeader {
    $device = Get-SelectedDevice
    $running = $false
    if ($device -and $device.State -eq 'device') {
        try { $running = $null -ne (Get-AndroidDcRawFtpStatus -Serial $device.Serial) } catch {}
    }
    if ($running) { Set-StatusPill $ui.PillFtp $ui.PillFtpText 'FTP running' 'ok' }
    else { $ui.PillFtp.Visibility = 'Collapsed' }
}

function Restore-FtpPage {
    $device = Get-SelectedDevice
    $serial = if ($device -and $device.State -eq 'device') { $device.Serial } else { $null }
    $status = if ($serial) { try { Get-AndroidDcRawFtpStatus -Serial $serial } catch { $null } }
    if (-not $status) {
        $script:ftpSerial = $null; $script:ftpUri = $null
        $script:ftpUsername = $null; $script:ftpPassword = $null
        if ($serial) { $ui.FtpStatus.Text = 'Server is stopped.' }
    } elseif ($script:ftpSerial -ne $serial -or -not $script:ftpUri) {
        $saved = Get-AndroidDcFtpSavedLogin -Serial $serial
        $script:ftpSerial = $serial; $script:ftpUri = $status.Uri
        $script:ftpUsername = if ($saved) { $saved.Username } else { $null }
        $script:ftpPassword = if ($saved) { $saved.Password } else { $null }
        $ui.FtpAddress.Text = $status.Uri.AbsoluteUri
        $ui.FtpPort.Text = [string]$status.Uri.Port
        if ($saved) { $ui.FtpUsername.Text = $saved.Username; $ui.FtpPassword.Text = $saved.Password }
        $ui.FtpStatus.Text = if ($saved) { 'FTP server is already running on this phone.' }
            else { 'FTP is running. The login is unavailable on this PC; you can stop it or remove the companion.' }
    }
    if ($status) { Set-StatusPill $ui.PillFtp $ui.PillFtpText 'FTP running' 'ok' }
    else { $ui.PillFtp.Visibility = 'Collapsed' }
}

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
    $ui.FtpExplorer.IsEnabled = $running -and $null -ne $script:ftpUsername
    $ui.FtpTest.IsEnabled = $running -and $null -ne $script:ftpUsername
    $ui.FtpCopy.IsEnabled = $running
    $ui.FtpRemoveCompanion.IsEnabled = $null -ne (Get-SelectedDevice)
}

function Invoke-NovaFtpAction {
    param([ValidateSet('Start','Stop','Test','Explorer','Copy','Remove')][string]$Action)
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
            'Remove' {
                $serial = Get-TargetSerial
                if (-not $serial) { throw 'Select a phone first.' }
                $ui.FtpStatus.Text = Remove-AndroidDcFtpCompanion -Serial $serial
                $script:ftpSerial = $null; $script:ftpUri = $null
                $script:ftpUsername = $null; $script:ftpPassword = $null
                Update-FtpAddress
            }
        }
    } catch { $ui.FtpStatus.Text = $_.Exception.Message }
    finally { Update-FtpPage; Update-FtpHeader }
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
$ui.FtpRemoveCompanion.Add_Click({ Invoke-NovaFtpAction -Action Remove })
Update-FtpPage
