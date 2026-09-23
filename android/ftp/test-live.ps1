param([string]$Serial, [switch]$Explorer, [switch]$Custom, [switch]$Default)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:adbPath = Join-Path $root 'adb.exe'
if (-not $Serial) {
    $devices = @(& $script:adbPath devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
    if ($devices.Count -ne 1) { throw 'Connect exactly one Android device or pass -Serial.' }
    $Serial = $devices[0]
}

function Invoke-Adb {
    param([string[]]$CommandArguments)
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $script:adbPath @CommandArguments 2>&1)
        return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Text=($lines -join "`n") }
    } finally { $ErrorActionPreference = $before }
}
function Invoke-DeviceShellText {
    param([string]$Serial, [string]$Command)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    return Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', "echo $encoded | base64 -d | sh")
}
function Invoke-DeviceCommand {
    param([string]$Serial, [string[]]$Arguments)
    return Invoke-Adb -CommandArguments (@('-s', $Serial, 'shell') + $Arguments)
}
function Wait-Pumped { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }

. (Join-Path $root 'shared/Ftp.ps1')
$credentials = New-AndroidDcFtpCredentials
$port = 2121
if ($Custom) {
    $credentials.Username = 'custom_user'
    $credentials.Password = 'Custom password 123!'
    $port = 22345
}
if ($Default) { $credentials = Get-AndroidDcFtpDefaultCredentials }
$marker = 'androiddc-ftp-test-' + [Guid]::NewGuid().ToString('N') + '.txt'
$remote = '/AndroidDC-FTP/' + $marker
$started = $null
try {
    $started = Start-AndroidDcRawFtp -Serial $Serial -Username $credentials.Username -Password $credentials.Password -Port $port
    $null = Test-FilesFtpEndpoint -Uri $started.Uri -Username $credentials.Username -Password $credentials.Password
    $wlan = Invoke-DeviceCommand -Serial $Serial -Arguments @('ip', '-f', 'inet', 'addr', 'show', 'wlan0')
    if ($wlan.Text -match 'inet\s+(\d+\.\d+\.\d+\.\d+)' -and $started.Uri.Host -ne $Matches[1]) {
        throw "Server reported $($started.Uri.Host), not the Wi-Fi address $($Matches[1])."
    }
    Write-Host "Server address $($started.Uri.AbsoluteUri)"
    $rejected = $false
    try { $null = Get-RawFtpListing -Uri $started.Uri -Username $credentials.Username -Password 'incorrect-password' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wrong FTP password was accepted.' }

    $content = [Text.Encoding]::UTF8.GetBytes('AndroidDC FTP upload and download test')
    Send-RawFtpFile -Uri $started.Uri -Username $credentials.Username -Password $credentials.Password -RemotePath $remote -Bytes $content
    $listing = @(Get-RawFtpListing -Uri $started.Uri -Username $credentials.Username -Password $credentials.Password -Path '/AndroidDC-FTP')
    if (-not ($listing -match [regex]::Escape($marker))) { throw 'Uploaded file was not listed.' }
    $downloaded = Receive-RawFtpFile -Uri $started.Uri -Username $credentials.Username -Password $credentials.Password -RemotePath $remote
    if ([Convert]::ToBase64String($content) -ne [Convert]::ToBase64String($downloaded)) { throw 'Downloaded content differs from uploaded content.' }
    Write-Host 'FTP authentication, listing, upload and download passed.'
    if ($Explorer) {
        $before = Invoke-DeviceCommand -Serial $Serial -Arguments @('cat', '/data/local/tmp/androiddc-rawftp.log')
        $loginCount = @([regex]::Matches($before.Text, 'SESSION AUTHENTICATED')).Count
        Open-AndroidDcFtpInExplorer -Uri $started.Uri -Username $credentials.Username -Password $credentials.Password
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 500
            $after = Invoke-DeviceCommand -Serial $Serial -Arguments @('cat', '/data/local/tmp/androiddc-rawftp.log')
            $newCount = @([regex]::Matches($after.Text, 'SESSION AUTHENTICATED')).Count
        } until ($newCount -gt ($loginCount + 1) -or $watch.Elapsed.TotalSeconds -gt 12)
        if ($newCount -le ($loginCount + 1)) { throw 'Explorer did not authenticate with the FTP server.' }
        Write-Host 'Explorer authenticated with the FTP server.'
    }
} finally {
    $null = Invoke-DeviceShellText -Serial $Serial -Command "rm -f /sdcard/AndroidDC-FTP/$marker"
    if ($started) { $null = Stop-AndroidDcRawFtp -Serial $Serial }
}
