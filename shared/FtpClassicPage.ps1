# Classic's FTP tab. All transfer and server operations live in Ftp.ps1.

function New-ClassicFtpLabel {
    param([Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 150)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, 22)
    $Parent.Controls.Add($label)
    return $label
}

function New-ClassicFtpButton {
    param([Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.SetBounds($X, $Y, $Width, 30)
    $Parent.Controls.Add($button)
    return $button
}

function Initialize-ClassicFtpPage {
    param([Windows.Forms.TabPage]$Tab)
    $script:classicFtp = @{}
    $script:classicFtp.Serial = $null
    $script:classicFtp.Uri = $null
    $script:classicFtp.ActiveUsername = $null
    $script:classicFtp.ActivePassword = $null

    $settings = New-Object Windows.Forms.GroupBox
    $settings.Text = 'Connection'
    $settings.SetBounds(14, 12, 650, 150)
    $Tab.Controls.Add($settings)

    $null = New-ClassicFtpLabel $settings 'Username' 14 30 85
    $script:classicFtp.Username = New-Object Windows.Forms.TextBox
    $script:classicFtp.Username.SetBounds(105, 26, 235, 26)
    $settings.Controls.Add($script:classicFtp.Username)
    $null = New-ClassicFtpLabel $settings 'Password' 14 65 85
    $script:classicFtp.Password = New-Object Windows.Forms.TextBox
    $script:classicFtp.Password.SetBounds(105, 61, 235, 26)
    $settings.Controls.Add($script:classicFtp.Password)
    $null = New-ClassicFtpLabel $settings 'Port' 365 30 50
    $script:classicFtp.Port = New-Object Windows.Forms.TextBox
    $script:classicFtp.Port.SetBounds(420, 26, 90, 26)
    $script:classicFtp.Port.Text = '2121'
    $settings.Controls.Add($script:classicFtp.Port)

    $script:classicFtp.Generate = New-ClassicFtpButton $settings 'Generate new login' 14 109 155
    $script:classicFtp.Start = New-ClassicFtpButton $settings 'Start server' 182 109 112
    $script:classicFtp.Stop = New-ClassicFtpButton $settings 'Stop server' 307 109 112

    $access = New-Object Windows.Forms.GroupBox
    $access.Text = 'Phone address'
    $access.SetBounds(14, 170, 650, 145)
    $Tab.Controls.Add($access)
    $script:classicFtp.Address = New-Object Windows.Forms.TextBox
    $script:classicFtp.Address.SetBounds(14, 27, 620, 26)
    $script:classicFtp.Address.ReadOnly = $true
    $script:classicFtp.Address.Text = 'Select a phone to see its address.'
    $access.Controls.Add($script:classicFtp.Address)
    $script:classicFtp.Explorer = New-ClassicFtpButton $access 'Open in Explorer' 14 67 130
    $script:classicFtp.Test = New-ClassicFtpButton $access 'Test connection' 157 67 122
    $script:classicFtp.Copy = New-ClassicFtpButton $access 'Copy address' 292 67 112
    $script:classicFtp.Status = New-ClassicFtpLabel $access 'Select a phone, then start the server.' 14 112 620
    $script:classicFtp.Status.AutoEllipsis = $true

    $null = New-ClassicFtpLabel $Tab 'FTP is unencrypted. Use a trusted network and stop the server when finished.' 18 320 640
    $defaults = Get-AndroidDcFtpDefaultCredentials
    $script:classicFtp.Username.Text = $defaults.Username
    $script:classicFtp.Password.Text = $defaults.Password

    $script:classicFtp.Port.Add_TextChanged({
        $ui = $script:classicFtp
        if (-not $ui.Uri -and $ui.Address.Text -match '^ftp://([^:/]+):\d*/$') {
            $ui.Address.Text = "ftp://$($Matches[1]):$($ui.Port.Text.Trim())/"
        }
    })
    $script:classicFtp.Generate.Add_Click({
        $generated = New-AndroidDcFtpCredentials
        $script:classicFtp.Username.Text = $generated.Username
        $script:classicFtp.Password.Text = $generated.Password
    })
    $script:classicFtp.Start.Add_Click({ Invoke-ClassicFtpAction -Action Start })
    $script:classicFtp.Stop.Add_Click({ Invoke-ClassicFtpAction -Action Stop })
    $script:classicFtp.Test.Add_Click({ Invoke-ClassicFtpAction -Action Test })
    $script:classicFtp.Explorer.Add_Click({ Invoke-ClassicFtpAction -Action Explorer })
    $script:classicFtp.Copy.Add_Click({ Invoke-ClassicFtpAction -Action Copy })
    Update-ClassicFtpPage
}

# Before the server runs, the address box shows where it will be: the phone's Wi-Fi IP and the port.
function Update-ClassicFtpAddress {
    $ui = $script:classicFtp
    if ($ui.Uri) { return }
    $serial = @(Get-SelectedSerials)[0]
    $address = $null
    try { $address = Get-AndroidDcFtpPreviewAddress -Serial $serial -Port $ui.Port.Text } catch {}
    $ui.Address.Text = if ($address) { $address }
        elseif ($serial) { 'The phone has no Wi-Fi address. Connect it to the same network as this PC.' }
        else { 'Select a phone to see its address.' }
}

function Update-ClassicFtpPage {
    $running = $null -ne $script:classicFtp.Uri
    foreach ($key in @('Username','Password','Port','Generate','Start')) { $script:classicFtp[$key].Enabled = -not $running }
    foreach ($key in @('Stop','Test','Explorer','Copy')) { $script:classicFtp[$key].Enabled = $running }
}

function Invoke-ClassicFtpAction {
    param([ValidateSet('Start','Stop','Test','Explorer','Copy')][string]$Action)
    $ui = $script:classicFtp
    $ui.Status.Text = 'Working...'
    $ui.Start.Enabled = $false
    $ui.Stop.Enabled = $false
    try {
        switch ($Action) {
            'Start' {
                $serial = Get-TargetSerial
                if (-not $serial) { throw 'Select a phone first.' }
                $port = 0
                if (-not [int]::TryParse($ui.Port.Text, [ref]$port)) { throw 'Enter a valid port number.' }
                $username = $ui.Username.Text
                $password = $ui.Password.Text
                $started = Start-AndroidDcRawFtp -Serial $serial -Username $username -Password $password -Port $port
                $ui.Serial = $serial
                $ui.Uri = $started.Uri
                $ui.ActiveUsername = $username
                $ui.ActivePassword = $password
                $ui.Address.Text = $started.Uri.AbsoluteUri
                $null = Test-FilesFtpEndpoint -Uri $started.Uri -Username $username -Password $password
                $ui.Status.Text = 'Server ready. Open it in Explorer to browse and transfer files.'
            }
            'Stop' {
                $ui.Status.Text = Stop-AndroidDcRawFtp -Serial $ui.Serial
                $ui.Serial = $null
                $ui.Uri = $null
                $ui.ActiveUsername = $null
                $ui.ActivePassword = $null
                Update-ClassicFtpAddress
            }
            'Test' { $ui.Status.Text = Test-FilesFtpEndpoint -Uri $ui.Uri -Username $ui.ActiveUsername -Password $ui.ActivePassword }
            'Explorer' {
                Open-AndroidDcFtpInExplorer -Uri $ui.Uri -Username $ui.ActiveUsername -Password $ui.ActivePassword
                $ui.Status.Text = 'Opened the phone in Windows File Explorer.'
            }
            'Copy' {
                [Windows.Forms.Clipboard]::SetText($ui.Uri.AbsoluteUri)
                $ui.Status.Text = 'Address copied.'
            }
        }
    } catch { $ui.Status.Text = $_.Exception.Message }
    finally { Update-ClassicFtpPage }
}
