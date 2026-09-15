# The Radios page: Wi-Fi, Bluetooth and NFC. The saved-network rules (one row
# per id, SSIDs compared with case, strongest first by the number) are checked
# on made-up lists; every action that would change the phone is run against a
# made-up serial with adb replaced, so each command is recorded and none is
# sent. With a phone attached, only reads: its saved networks, the scan
# results it already has, the Bluetooth and NFC dumps, pm list features.
# Nothing personal is printed: counts only.

# ----------------------------------------------------------- the mock ----
$script:mockSerial = 'MOCK-SERIAL'
$script:mockAdb = New-Object System.Collections.ArrayList
$script:mockText = New-Object System.Collections.ArrayList
$script:mockAsked = New-Object System.Collections.ArrayList
$script:mockLeaks = New-Object System.Collections.ArrayList
$script:mockConfirm = $true
$script:mockInput = $null
$script:mockReply = { param([string]$Line) '' }
$script:mockOriginals = @{}

function Enable-TestMocks {
    foreach ($name in @('Invoke-Adb', 'Invoke-DeviceShellText', 'Get-TargetSerial', 'Show-Confirm', 'Show-InputDialog')) {
        $script:mockOriginals[$name] = (Get-Item "function:$name").ScriptBlock
    }
    Set-Item -Path 'function:script:Invoke-Adb' -Value {
        param([string[]]$CommandArguments, [int]$TimeoutMs = 180000)
        $all = @($CommandArguments)
        if ($all.Count -ge 3 -and $all[0] -eq '-s' -and $all[1] -eq $script:mockSerial) {
            $line = ($all | Select-Object -Skip 3) -join ' '
            $null = $script:mockAdb.Add($line)
            $lines = @(@(& $script:mockReply $line) | ForEach-Object { "$_" -split "`n" })
            return [PSCustomObject]@{ ExitCode = 0; Lines = $lines; Text = ($lines -join "`n") }
        }
        if ($all -contains 'shell' -or $all -contains 'exec-out') {
            # a command for a real phone while the mock is on: stopped and counted
            $null = $script:mockLeaks.Add('adb')
            return [PSCustomObject]@{ ExitCode = -1; Lines = @(); Text = '' }
        }
        return (& $script:mockOriginals['Invoke-Adb'] -CommandArguments $CommandArguments -TimeoutMs $TimeoutMs)
    }
    Set-Item -Path 'function:script:Invoke-DeviceShellText' -Value {
        param([string]$Serial, [string]$Command)
        if ($Serial -ne $script:mockSerial) { $null = $script:mockLeaks.Add('text'); return [PSCustomObject]@{ ExitCode = -1; Lines = @(); Text = '' } }
        $null = $script:mockText.Add($Command)
        $lines = @(@(& $script:mockReply $Command) | ForEach-Object { "$_" -split "`n" })
        return [PSCustomObject]@{ ExitCode = 0; Lines = $lines; Text = ($lines -join "`n") }
    }
    Set-Item -Path 'function:script:Get-TargetSerial' -Value { return $script:mockSerial }
    Set-Item -Path 'function:script:Show-Confirm' -Value {
        param([string]$Title, [string]$Text, [string]$Yes = 'OK', [string]$No = 'Cancel', [switch]$Danger)
        $null = $script:mockAsked.Add("$Title|$Text")
        return [bool]$script:mockConfirm
    }
    Set-Item -Path 'function:script:Show-InputDialog' -Value {
        param([string]$Title, [string[]]$Fields, [string[]]$Values, [string]$Hint, [string[]]$Secret = @(),
            [string[]]$Multiline = @(), [string]$OkText = 'OK')
        $null = $script:mockAsked.Add($Title)
        if ($null -eq $script:mockInput) { return $null }
        return @($script:mockInput)
    }
}

function Disable-TestMocks {
    foreach ($name in @($script:mockOriginals.Keys)) { Set-Item -Path "function:script:$name" -Value $script:mockOriginals[$name] }
}

function Reset-TestRecord {
    $script:mockAdb.Clear(); $script:mockText.Clear(); $script:mockAsked.Clear()
}

function Split-TestShellWords {
    # the words sh makes of a line: single quotes, double quotes, backslash
    param([string]$Line)
    $words = New-Object System.Collections.ArrayList
    $word = New-Object System.Text.StringBuilder
    $inWord = $false
    $quote = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote -eq [char]39) {
            if ($c -eq [char]39) { $quote = [char]0 } else { $null = $word.Append($c) }
            continue
        }
        if ($quote -eq [char]34) {
            if ($c -eq [char]34) { $quote = [char]0 }
            elseif ($c -eq [char]92 -and $i + 1 -lt $Line.Length -and ('$`"\').Contains([string]$Line[$i + 1])) { $i++; $null = $word.Append($Line[$i]) }
            else { $null = $word.Append($c) }
            continue
        }
        if ($c -eq [char]39 -or $c -eq [char]34) { $quote = $c; $inWord = $true; continue }
        if ($c -eq [char]92 -and $i + 1 -lt $Line.Length) { $i++; $null = $word.Append($Line[$i]); $inWord = $true; continue }
        if ([char]::IsWhiteSpace($c)) {
            if ($inWord) { $null = $words.Add($word.ToString()); $null = $word.Clear(); $inWord = $false }
            continue
        }
        $null = $word.Append($c)
        $inWord = $true
    }
    if ($inWord) { $null = $words.Add($word.ToString()) }
    return ,@($words)
}

function Test-SameWords {
    param($Got, $Want)
    $sep = [string][char]0x1F
    return (@($Got).Count -eq @($Want).Count -and (@($Got) -join $sep) -ceq (@($Want) -join $sep))
}

# ------------------------------------------------------------- startup ----
Say '== startup =='
$idle = Wait-Idle -Seconds 60
Say ("  idle after the first reads   {0}" -f (Mark $idle))
$page = Get-Page -Key 'radios'
Say ("  the page is registered under Connect   {0}" -f (Mark ($null -ne $page -and $page.Section -eq 'Connect')))
Show-Page -Page 'radios'
$null = Wait-Idle -Seconds 60
Say ("  three inner pages: {0}   {1}" -f (@($ui.RadiosTabs.Items | ForEach-Object { $_.Header }) -join ', '),
    (Mark ($ui.RadiosTabs.Items.Count -eq 3)))

Say ''
Say '== the signal order =='
$signals = @('-60 dBm', 'saved', '-45 dBm', '-100 dBm', '-7 dBm')
$ordered = @($signals | Sort-Object -Property @{ Expression = { Get-SignalStrength $_ } } -Descending)
Say ("  {0}   {1}" -f ($ordered -join ', '), (Mark (($ordered -join ',') -eq '-7 dBm,-45 dBm,-60 dBm,-100 dBm,saved')))
$asText = @($signals | Sort-Object -Descending)
Say ("  (as text it would be: {0})" -f ($asText -join ', '))

Say ''
Say '== saved networks on made-up lists =='
$madeScan = @(
    'BSSID              Frequency      RSSI           Age(sec)     SSID                                 Flags',
    'aa:bb:cc:00:00:01  2437  -60  0.5  Cafe Two  [WPA2-PSK-CCMP][ESS]',
    'aa:bb:cc:00:00:02  5180  -45  0.4  KAIF 5G  [RSN-PSK-CCMP][ESS]',
    'aa:bb:cc:00:00:03  5200  -100  3.1  Far Away  [ESS]',
    'aa:bb:cc:00:00:04  5745  -7  0.2  Next Door  [RSN-SAE-CCMP][ESS]'
) -join "`n"
$madeSaved = @(
    'Network Id      SSID                         Security type',
    '0            KAIF 5G                         wpa2-psk',
    '0            KAIF 5G                         wpa3-sae^',
    '1            Kaif 5G                         wpa2-psk',
    '2            Office Net                      wpa2-psk'
) -join "`n"

$rows = @(Get-RadiosWifiRows -SavedText $madeSaved -Saved)
Say ("  Saved networks: {0} rows for ids 0, 0, 1, 2   {1}" -f $rows.Count, (Mark ($rows.Count -eq 3)))
$ids = @($rows | ForEach-Object { $_.SavedId } | Sort-Object)
Say ("  one row per id ({0})   {1}" -f ($ids -join ','), (Mark (($ids -join ',') -eq '0,1,2')))
$caseRows = @($rows | Where-Object { $_.Ssid -eq 'kaif 5g' })
Say ("  'KAIF 5G' and 'Kaif 5G' stay two rows   {0}" -f (Mark ($caseRows.Count -eq 2 -and ($caseRows[0].Ssid -cne $caseRows[1].Ssid))))

$rows = @(Get-RadiosWifiRows -ScanText $madeScan -SavedText $madeSaved)
Say ("  scan + saved: {0} rows (the four seen)   {1}" -f $rows.Count, (Mark ($rows.Count -eq 4)))
$kaif = @($rows | Where-Object { $_.Ssid -ceq 'KAIF 5G' })
Say ("  the seen 'KAIF 5G' gets saved id 0, once   {0}" -f (Mark ($kaif.Count -eq 1 -and $kaif[0].SavedId -eq '0')))
$wrongCase = @($rows | Where-Object { $_.SavedId -eq '1' })
Say ("  'Kaif 5G' (id 1) is not put on it   {0}" -f (Mark ($wrongCase.Count -eq 0)))
$order = @($rows | ForEach-Object { Get-SignalStrength $_.Signal })
Say ("  strongest first: {0}   {1}" -f ($order -join ', '), (Mark (($order -join ',') -eq '-7,-45,-60,-100')))
$rows = @(Get-RadiosWifiRows -ScanText '' -SavedText $madeSaved)
Say ("  nothing seen: the saved ones are listed ({0})   {1}" -f $rows.Count, (Mark ($rows.Count -eq 3)))

Say ''
Say '== Bluetooth and NFC dumps, made up =='
$madeBtDump = @(
    'Bluetooth Status',
    '  enabled: true',
    '  state: ON',
    '',
    'Bonded devices:',
    '  00:11:22:33:44:5a [ DUAL ] Test Buds',
    '  66:77:88:99:AA:BB [BR/EDR] Test Car',
    '',
    'A2DP State:',
    '  mCurrentDevice: 00:11:22:33:44:5A'
) -join "`n"
$btRows = @(Get-RadiosBluetoothRows -Dump $madeBtDump)
Say ("  {0} paired, the connected one marked   {1}" -f $btRows.Count,
    (Mark ($btRows.Count -eq 2 -and $btRows[0].Connected -and $btRows[0].Bond -eq 'connected' -and -not $btRows[1].Connected)))
$nfcLines = @(Get-RadiosNfcLines -Dump ("mState=on`nsomething else`nmScreenState=ON_UNLOCKED`n" + (('mState=x' + "`n") * 20)))
Say ("  the NFC box keeps at most 14 lines ({0})   {1}" -f $nfcLines.Count, (Mark ($nfcLines.Count -eq 14)))

Say ''
Say '== actions, against a made-up serial =='
Enable-TestMocks
try {
    $check = (Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial'
    Say ("  the mock is in place   {0}" -f (Mark $check))

    $script:mockReply = {
        param([string]$Line)
        if ($Line -eq 'cmd wifi status') { return "Wifi is enabled`nWifi is connected to `"Cafe Two`"`nWifiInfo: SSID: `"Cafe Two`", RSSI: -52, Link speed: 144Mbps, Frequency: 2437MHz, more" }
        if ($Line -eq 'cmd wifi list-scan-results') { return $madeScan }
        if ($Line -eq 'cmd wifi list-networks') { return $madeSaved }
        if ($Line -eq 'pm list features') { return "feature:android.hardware.wifi`nfeature:android.hardware.bluetooth" }
        if ($Line -eq 'dumpsys bluetooth_manager') { return $madeBtDump }
        return ''
    }

    Reset-TestRecord
    Update-WifiList
    Say ("  state line: '{0}'   {1}" -f $ui.RadiosWifiState.Text,
        (Mark ($ui.RadiosWifiState.Text -eq 'Wi-Fi: connected to Cafe Two   (-52 dBm, 144Mbps, 2437MHz)')))
    $joined = @($script:radiosWifiRows | Where-Object { $_.Connected })
    Say ("  the joined network is marked, with the live signal   {0}" -f
        (Mark ($joined.Count -eq 1 -and $joined[0].Shown -eq 'Cafe Two   <- connected' -and $joined[0].SignalShown -eq '-52 dBm')))
    Say ("  nothing scanned without Scan   {0}" -f (Mark (@($script:mockAdb | Where-Object { $_ -match 'start-scan' }).Count -eq 0)))

    $script:radiosFeatures.Remove($script:mockSerial)
    Reset-TestRecord
    $null = Get-RadioFeature -Serial $script:mockSerial
    $null = Get-RadioFeature -Serial $script:mockSerial
    Say ("  pm list features is read once per phone   {0}" -f (Mark ($script:mockAdb.Count -eq 1)))

    # Connect: a name with a space and quotes, a password with a space, a $ and quotes
    $script:radiosWifiRows.Clear()
    $odd = [PSCustomObject]@{ Shown = 'x'; Ssid = "My Home 'Net`" 5G"; Security = '[RSN-PSK-CCMP][ESS]'; Signal = '-50 dBm'
        SignalShown = '-50 dBm'; Strength = -50; Bssid = ''; SavedId = ''; Connected = $false }
    $script:radiosWifiRows.Add($odd)
    $ui.RadiosWifiList.SelectedItem = $odd
    $password = 'p@ss w0rd $1 "x" `id` it''s'
    $ui.RadiosWifiShowPass.IsChecked = $false
    $ui.RadiosWifiPass.Password = $password
    Reset-TestRecord
    Connect-WifiNetwork
    $sent = @($script:mockText)
    $words = if ($sent.Count -gt 0) { Split-TestShellWords $sent[0] } else { @() }
    Say ("  Connect sends one whole command   {0}" -f (Mark ($sent.Count -eq 1)))
    Say ("  the name and password arrive whole   {0}" -f
        (Mark (Test-SameWords $words @('cmd', 'wifi', 'connect-network', $odd.Ssid, 'wpa2', $password))))

    # the password box with "show" hands over the same text
    $ui.RadiosWifiShowPass.IsChecked = $true
    Say ("  'show' keeps the password   {0}" -f (Mark ((Get-RadiosWifiPassword) -ceq $password -and $ui.RadiosWifiPassShown.Visibility -eq 'Visible')))
    $ui.RadiosWifiShowPass.IsChecked = $false
    Say ("  and hiding it again too   {0}" -f (Mark ($ui.RadiosWifiPass.Password -ceq $password)))
    $ui.RadiosWifiPass.Password = ''

    # through the real base64 step: the phone's shell gets exactly that line
    $shellText = $script:mockOriginals['Invoke-DeviceShellText']
    Reset-TestRecord
    $line = if ($sent.Count -gt 0) { $sent[0] } else { 'nothing was sent' }
    $null = & $shellText -Serial $script:mockSerial -Command $line
    $encoded = if ($script:mockAdb.Count -gt 0 -and $script:mockAdb[0] -match '^echo (\S+) \| base64 -d \| sh$') { $Matches[1] } else { '' }
    $decoded = if ($encoded) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) } else { '' }
    Say ("  over base64 the line arrives unchanged   {0}" -f (Mark ($decoded -ceq $sent[0])))

    # a secured network without a password is refused before anything is sent
    $script:radiosWifiRows.Clear()
    $script:radiosWifiRows.Add($odd)
    $ui.RadiosWifiList.SelectedItem = $odd
    Reset-TestRecord
    Connect-WifiNetwork
    Say ("  no password, nothing sent   {0}" -f (Mark ($script:mockText.Count -eq 0 -and $script:mockAdb.Count -eq 0)))

    # Forget asks first; No sends nothing
    $savedRow = [PSCustomObject]@{ Shown = 'Office Net'; Ssid = 'Office Net'; Security = 'wpa2-psk'; Signal = 'saved'
        SignalShown = 'saved'; Strength = -1000; Bssid = ''; SavedId = '2'; Connected = $false }
    $script:radiosWifiRows.Clear()
    $script:radiosWifiRows.Add($savedRow)
    $ui.RadiosWifiList.SelectedItem = $savedRow
    $script:mockConfirm = $false
    Reset-TestRecord
    Remove-WifiNetwork
    Say ("  Forget asks, and No sends nothing   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockAdb.Count -eq 0)))
    $script:mockConfirm = $true
    Reset-TestRecord
    Remove-WifiNetwork
    Say ("  Yes forgets that id   {0}" -f (Mark (@($script:mockAdb | Where-Object { $_ -eq 'cmd wifi forget-network 2' }).Count -eq 1)))

    # the radios: on and off send the command the original sent
    Reset-TestRecord
    Set-BluetoothRadio -On $false
    Say ("  Bluetooth off -> cmd bluetooth_manager disable   {0}" -f (Mark ($script:mockAdb -contains 'cmd bluetooth_manager disable')))
    Say ("  and the list is read again: {0}   {1}" -f $ui.RadiosBtState.Text, (Mark ($ui.RadiosBtState.Text -like 'Bluetooth: on*connected to Test Buds')))
    Reset-TestRecord
    Set-NfcRadio -On $true
    Say ("  NFC on -> svc nfc enable   {0}" -f (Mark ($script:mockAdb -contains 'svc nfc enable')))
    Say ("  no NFC hardware is said so: '{0}'   {1}" -f $ui.RadiosNfcState.Text, (Mark ($ui.RadiosNfcState.Text -eq 'NFC: not present on this device')))

    Reset-TestRecord
    Invoke-ButtonClick -Button $ui.RadiosWifiSettings
    $opened = if (Get-Command Open-DeviceSettingsScreen -ErrorAction SilentlyContinue) { $script:mockAdb -contains 'am start -a android.settings.WIFI_SETTINGS' } else { $script:mockAdb.Count -eq 0 }
    Say ("  Wi-Fi settings goes through the Users page, or says it is missing   {0}" -f (Mark $opened))

    Say ("  no command reached a real phone   {0}" -f (Mark ($script:mockLeaks.Count -eq 0)))
} finally {
    Disable-TestMocks
}
Say ("  the real functions are back   {0}" -f (Mark (-not ((Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial'))))

Say ''
Say '== the phone, reads only =='
$serial = Get-SelectedSerial
$ready = $null -ne $serial -and @($script:deviceRows | Where-Object { $_.Serial -eq $serial -and $_.State -eq 'device' }).Count -gt 0
if (-not $ready) {
    Say '  SKIPPED - no phone attached'
} else {
    Clear-RadiosPage
    Update-WifiList -Saved
    $savedCount = $script:radiosWifiRows.Count
    $savedIds = @($script:radiosWifiRows | ForEach-Object { $_.SavedId })
    Say ("  saved networks: {0}, each id once   {1}" -f $savedCount, (Mark (@($savedIds | Sort-Object -Unique).Count -eq $savedIds.Count)))
    Update-WifiList
    $values = @($script:radiosWifiRows | ForEach-Object { $_.Strength })
    $measured = @($values | Where-Object { $_ -gt -1000 })
    if ($measured.Count -lt 2) {
        Say ("  {0} network(s) listed; SKIPPED order check - fewer than two with a signal" -f $values.Count)
    } else {
        $sorted = @($values | Sort-Object -Descending)
        Say ("  {0} network(s), strongest first, saved-only last   {1}" -f $values.Count, (Mark (($values -join ',') -eq ($sorted -join ','))))
    }
    Update-BluetoothList
    Say ("  Bluetooth read: {0} paired   {1}" -f $script:radiosBtRows.Count, (Mark ($ui.RadiosBtState.Text -like 'Bluetooth:*' -and $ui.RadiosBtState.Text -ne 'Bluetooth: unknown')))
    Update-NfcState
    Say ("  NFC read   {0}" -f (Mark ($ui.RadiosNfcState.Text -ne 'NFC: unknown')))
}

Say ''
Say '== the pictures (made-up rows) =='
Clear-RadiosPage
$ui.RadiosWifiState.Text = 'Wi-Fi: connected to Cafe Two   (-52 dBm, 144Mbps, 2437MHz)'
Show-RadiosWifiRows -Rows @(Get-RadiosWifiRows -ScanText $madeScan -SavedText $madeSaved) -Link ([PSCustomObject]@{ Enabled = $true; Ssid = 'Cafe Two'; Rssi = '-52'; Speed = ''; Frequency = '' })
foreach ($row in $btRows) { $script:radiosBtRows.Add($row) }
$ui.RadiosBtState.Text = 'Bluetooth: on   |   connected to Test Buds'
$ui.DeviceTitle.Text = 'Test phone'
$ui.DeviceSubtitle.Text = 'made-up rows for the picture'

foreach ($tab in @(@('wifi', $ui.RadiosTabWifi), @('bluetooth', $ui.RadiosTabBluetooth), @('nfc', $ui.RadiosTabNfc))) {
    $script:busy++   # opening a tab reads the phone; not for the picture
    $ui.RadiosTabs.SelectedItem = $tab[1]
    $script:busy--
    if ($tab[0] -eq 'nfc') { $ui.RadiosNfcState.Text = 'NFC: on'; $ui.RadiosNfcInfo.Text = "mState=on`nmIsSecureNfcEnabled=false`nmScreenState=ON_UNLOCKED" }
    foreach ($size in @('default', 'min')) {
        Set-WindowSize $size
        $script:logLines.Clear()
        Say ("  {0} {1}: {2}" -f $tab[0], $size, (Save-WindowPicture "radios-$($tab[0])-$size"))
        $outside = @(Get-OutsideElements -Root $page.Root)
        Say ("  {0} {1}: nothing sticks out   {2}" -f $tab[0], $size, (Mark ($outside.Count -eq 0)))
        foreach ($entry in $outside) { Say "      $entry" }
    }
}
$script:busy++
$ui.RadiosTabs.SelectedItem = $ui.RadiosTabWifi
$script:busy--
Clear-RadiosPage
