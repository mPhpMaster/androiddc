# AndroidDC FTP integration. The server runs through app_process, while the
# optional AndroidDC companion shows a persistent notification and Stop action.

function ConvertTo-FilesFtpUri {
    param([string]$Address)
    $uri = $null
    if (-not [Uri]::TryCreate($Address.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'ftp' -or -not $uri.Host -or $uri.Port -lt 1 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $Address -match '[\r\n"]') {
        throw 'Enter an FTP address such as ftp://192.168.1.20:2121/.'
    }
    return $uri
}

function Read-RawFtpReply {
    param([IO.StreamReader]$Reader)
    $first = $Reader.ReadLine()
    if ($null -eq $first -or $first -notmatch '^(\d{3})([ -])') { throw "Invalid FTP reply: $first" }
    $code = [int]$Matches[1]
    $lines = @($first)
    if ($Matches[2] -eq '-') {
        do {
            $line = $Reader.ReadLine()
            if ($null -eq $line) { throw 'FTP connection closed during a multiline reply.' }
            $lines += $line
        } until ($line -match "^$code ")
    }
    return [PSCustomObject]@{ Code = $code; Text = ($lines -join "`n") }
}

function Send-RawFtpCommand {
    param([IO.StreamWriter]$Writer, [IO.StreamReader]$Reader, [string]$Command, [int[]]$Expected)
    $Writer.WriteLine($Command); $Writer.Flush()
    $reply = Read-RawFtpReply -Reader $Reader
    if ($Expected -notcontains $reply.Code) {
        $label = if ($Command.StartsWith('PASS ')) { 'PASS' } else { $Command }
        throw "FTP command '$label' failed: $($reply.Text)"
    }
    return $reply
}

function Open-RawFtpSession {
    param([Uri]$Uri, [string]$Username, [string]$Password)
    if (-not $Username -or -not $Password) { throw 'FTP credentials are required.' }
    $client = New-Object Net.Sockets.TcpClient
    $reader = $null; $writer = $null
    try {
        $client.ReceiveTimeout = 7000; $client.SendTimeout = 7000
        $client.Connect($Uri.DnsSafeHost, $Uri.Port)
        $stream = $client.GetStream()
        $utf8 = New-Object Text.UTF8Encoding($false)
        $reader = New-Object IO.StreamReader($stream, $utf8, $false, 1024, $true)
        $writer = New-Object IO.StreamWriter($stream, $utf8, 1024, $true)
        $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
        $hello = Read-RawFtpReply -Reader $reader
        if ($hello.Code -ne 220) { throw "FTP server did not become ready: $($hello.Text)" }
        $null = Send-RawFtpCommand $writer $reader ("USER " + $Username) @(331)
        $null = Send-RawFtpCommand $writer $reader ("PASS " + $Password) @(230)
        $null = Send-RawFtpCommand $writer $reader 'TYPE I' @(200)
        return [PSCustomObject]@{ Client=$client; Reader=$reader; Writer=$writer; Greeting=$hello.Text }
    } catch {
        if ($writer) { $writer.Dispose() }
        if ($reader) { $reader.Dispose() }
        $client.Dispose()
        throw
    }
}

function Close-RawFtpSession {
    param($Session)
    if (-not $Session) { return }
    try { $null = Send-RawFtpCommand $Session.Writer $Session.Reader 'QUIT' @(221) } catch {}
    $Session.Writer.Dispose(); $Session.Reader.Dispose(); $Session.Client.Dispose()
}

function Get-RawFtpListing {
    param([Uri]$Uri, [string]$Username, [string]$Password, [string]$Path = '/')
    $session = $null
    try {
        $session = Open-RawFtpSession -Uri $Uri -Username $Username -Password $Password
        if ($Path -ne '/') { $null = Send-RawFtpCommand $session.Writer $session.Reader ("CWD " + $Path) @(250) }
        $pasv = Send-RawFtpCommand $session.Writer $session.Reader 'PASV' @(227)
        if ($pasv.Text -notmatch '\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)') { throw 'FTP server returned an invalid PASV address.' }
        $dataHost = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
        $dataPort = ([int]$Matches[5] * 256) + [int]$Matches[6]
        $data = New-Object Net.Sockets.TcpClient($dataHost, $dataPort)
        try {
            $null = Send-RawFtpCommand $session.Writer $session.Reader 'LIST' @(125,150)
            $dataReader = New-Object IO.StreamReader($data.GetStream(), (New-Object Text.UTF8Encoding($false)))
            try { $listing = $dataReader.ReadToEnd() } finally { $dataReader.Dispose() }
        } finally { $data.Dispose() }
        $done = Read-RawFtpReply -Reader $session.Reader
        if ($done.Code -ne 226) { throw $done.Text }
        return @($listing -split '\r?\n' | Where-Object { $_ })
    } finally { Close-RawFtpSession $session }
}

function Receive-RawFtpFile {
    param([Uri]$Uri, [string]$Username, [string]$Password, [string]$RemotePath)
    $session = $null
    try {
        $session = Open-RawFtpSession -Uri $Uri -Username $Username -Password $Password
        $pasv = Send-RawFtpCommand $session.Writer $session.Reader 'PASV' @(227)
        if ($pasv.Text -notmatch '\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)') { throw 'FTP server returned an invalid PASV address.' }
        $dataHost = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
        $dataPort = ([int]$Matches[5] * 256) + [int]$Matches[6]
        $data = New-Object Net.Sockets.TcpClient($dataHost, $dataPort)
        try {
            $null = Send-RawFtpCommand $session.Writer $session.Reader ("RETR " + $RemotePath) @(125,150)
            $memory = New-Object IO.MemoryStream
            try { $data.GetStream().CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
        } finally { $data.Dispose() }
        $done = Read-RawFtpReply -Reader $session.Reader
        if ($done.Code -ne 226) { throw $done.Text }
        return ,$bytes
    } finally { Close-RawFtpSession $session }
}

function Send-RawFtpFile {
    param([Uri]$Uri, [string]$Username, [string]$Password, [string]$RemotePath, [byte[]]$Bytes)
    $session = $null
    try {
        $session = Open-RawFtpSession -Uri $Uri -Username $Username -Password $Password
        $pasv = Send-RawFtpCommand $session.Writer $session.Reader 'PASV' @(227)
        if ($pasv.Text -notmatch '\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)') { throw 'FTP server returned an invalid PASV address.' }
        $dataHost = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
        $dataPort = ([int]$Matches[5] * 256) + [int]$Matches[6]
        $data = New-Object Net.Sockets.TcpClient($dataHost, $dataPort)
        try {
            $null = Send-RawFtpCommand $session.Writer $session.Reader ("STOR " + $RemotePath) @(125,150)
            $data.GetStream().Write($Bytes, 0, $Bytes.Length)
        } finally { $data.Dispose() }
        $done = Read-RawFtpReply -Reader $session.Reader
        if ($done.Code -ne 226) { throw $done.Text }
    } finally { Close-RawFtpSession $session }
}

function Test-FilesFtpEndpoint {
    param([Uri]$Uri, [string]$Username, [string]$Password)
    $rows = @(Get-RawFtpListing -Uri $Uri -Username $Username -Password $Password)
    return "AndroidDC raw FTP is ready. Listed $($rows.Count) item(s) from the phone."
}

function New-AndroidDcFtpCredentials {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 24
        $rng.GetBytes($bytes)
        $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return [PSCustomObject]@{ Username = 'androiddc_' + $token.Substring(0, 8); Password = $token.Substring(8) }
    } finally { $rng.Dispose() }
}

function Get-AndroidDcFtpDefaultCredentials {
    return [PSCustomObject]@{ Username = 'pc'; Password = '123' }
}

# The address the server will have, shown before it starts. $null when the phone has no Wi-Fi address.
function Get-AndroidDcFtpPreviewAddress {
    param([string]$Serial, [string]$Port)
    if (-not $Serial) { return $null }
    $ip = $null
    $address = Invoke-DeviceCommand -Serial $Serial -Arguments @('ip', '-f', 'inet', 'addr', 'show', 'wlan0')
    if ($address.Text -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { $ip = $Matches[1] }
    if (-not $ip) {
        $route = Invoke-DeviceCommand -Serial $Serial -Arguments @('ip', 'route')
        if ($route.Text -match 'wlan0.+src\s+(\d+\.\d+\.\d+\.\d+)') { $ip = $Matches[1] }
    }
    if (-not $ip) { return $null }
    $number = 0
    if (-not [int]::TryParse($Port, [ref]$number)) { $number = 2121 }
    return "ftp://${ip}:$number/"
}

function Assert-AndroidDcFtpSettings {
    param([string]$Username, [string]$Password, [int]$Port)
    if ($Username -notmatch '^[A-Za-z0-9_.-]{1,64}$') { throw 'Username must be 1-64 letters, numbers, dots, underscores or dashes.' }
    if ($Password.Length -lt 1 -or $Password.Length -gt 128 -or $Password -match '[\x00-\x1f\x7f]') { throw 'Password must be 1-128 characters without control characters.' }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Port must be between 1024 and 65535.' }
}

function Open-AndroidDcFtpInExplorer {
    param([Uri]$Uri, [string]$Username, [string]$Password)
    $null = Test-FilesFtpEndpoint -Uri $Uri -Username $Username -Password $Password
    $builder = [UriBuilder]::new($Uri)
    $builder.UserName = $Username
    $builder.Password = $Password
    Start-Process -FilePath explorer.exe -ArgumentList $builder.Uri.AbsoluteUri
}

function Get-RawFtpDexPath {
    $ftpRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'android\ftp'
    $dex = Join-Path $ftpRoot 'out\classes.dex'
    $sources = Get-ChildItem (Join-Path $ftpRoot 'src') -Filter '*.java' -Recurse
    if (-not (Test-Path $dex) -or ($sources | Where-Object { $_.LastWriteTimeUtc -gt (Get-Item $dex).LastWriteTimeUtc })) {
        $build = Join-Path $ftpRoot 'build.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dex)) { throw 'Could not build the AndroidDC raw FTP server.' }
    }
    return $dex
}

function Get-AndroidDcFtpSavedPath {
    param([string]$Serial)
    $directory = Join-Path $env:LOCALAPPDATA 'AndroidDC\Ftp'
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Serial))
    return Join-Path $directory (([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()) + '.json')
}

function Save-AndroidDcFtpLogin {
    param([string]$Serial, [string]$Username, [string]$Password)
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $saved = [PSCustomObject]@{ Username = $Username; Password = ConvertFrom-SecureString $secure }
    $saved | ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-AndroidDcFtpSavedPath $Serial) -Encoding UTF8
}

function Get-AndroidDcFtpSavedLogin {
    param([string]$Serial)
    $path = Get-AndroidDcFtpSavedPath $Serial
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $secure = ConvertTo-SecureString $saved.Password
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        return [PSCustomObject]@{ Username = $saved.Username; Password = $password }
    } catch { return $null }
}

function Get-AndroidDcRawFtpStatus {
    param([string]$Serial)
    if (-not $Serial) { return $null }
    $probe = 'for pid in $(pidof app_process 2>/dev/null); do if cat "/proc/$pid/cmdline" 2>/dev/null | tr "\000" " " | grep -q "com.androiddc.RawFtpServer"; then echo RUNNING; break; fi; done'
    $process = Invoke-DeviceShellText -Serial $Serial -Command $probe
    if ($process.ExitCode -ne 0 -or $process.Text -notmatch '(?m)^RUNNING\s*$') { return $null }
    $log = Invoke-DeviceCommand -Serial $Serial -Arguments @('cat', '/data/local/tmp/androiddc-rawftp.log')
    if ($log.Text -notmatch '(?m)^READY ftp://([^/\s]+)/') { return $null }
    return [PSCustomObject]@{ Uri = [Uri]("ftp://" + $Matches[1] + '/'); Log = $log.Text }
}

function Get-AndroidDcFtpCompanionApk {
    $directory = Join-Path (Split-Path $PSScriptRoot -Parent) 'android\ftp\companion'
    $apk = Join-Path $directory 'out\androiddc-ftp-control.apk'
    $source = Join-Path $directory 'src\com\androiddc\ftpcontrol\FtpControlService.java'
    $manifest = Join-Path $directory 'AndroidManifest.xml'
    if (-not (Test-Path $apk) -or (Get-Item $source).LastWriteTimeUtc -gt (Get-Item $apk).LastWriteTimeUtc -or
        (Get-Item $manifest).LastWriteTimeUtc -gt (Get-Item $apk).LastWriteTimeUtc) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $directory 'build.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apk)) { throw 'Could not build the AndroidDC FTP phone companion.' }
    }
    return $apk
}

function Install-AndroidDcFtpCompanion {
    param([string]$Serial)
    $apk = Get-AndroidDcFtpCompanionApk
    $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'install', '-r', $apk)
    if ($result.Text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        $null = Invoke-Adb -CommandArguments @('-s', $Serial, 'uninstall', 'com.androiddc.ftpcontrol')
        $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'install', $apk)
    }
    if ($result.ExitCode -ne 0 -or $result.Text -notmatch 'Success') { throw "Could not install the AndroidDC FTP phone companion. $($result.Text)" }
    $permission = Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', 'pm', 'grant', 'com.androiddc.ftpcontrol', 'android.permission.POST_NOTIFICATIONS')
    if ($permission.ExitCode -ne 0 -and $permission.Text -notmatch 'Unknown permission') {
        throw "Could not allow the FTP notification on the phone. $($permission.Text)"
    }
}

function Remove-AndroidDcFtpCompanion {
    param([string]$Serial)
    $null = Stop-AndroidDcRawFtp -Serial $Serial
    $result = Invoke-Adb -CommandArguments @('-s', $Serial, 'uninstall', 'com.androiddc.ftpcontrol')
    if ($result.Text -notmatch 'Success|not installed|Unknown package') { throw "Could not remove the FTP phone companion. $($result.Text)" }
    $clean = Invoke-DeviceShellText -Serial $Serial -Command 'rm -f /data/local/tmp/androiddc-rawftp.dex /data/local/tmp/androiddc-rawftp.log /data/local/tmp/androiddc-rawftp.pid /data/local/tmp/androiddc-rawftp-credentials /sdcard/AndroidDC-FTP/connection-test.txt'
    if ($clean.ExitCode -ne 0) { throw "The FTP app was removed, but temporary FTP files could not be cleared. $($clean.Text)" }
    return 'AndroidDC FTP phone companion removed.'
}

function Start-AndroidDcRawFtp {
    param([string]$Serial, [string]$Username, [string]$Password, [int]$Port = 2121)
    Assert-AndroidDcFtpSettings -Username $Username -Password $Password -Port $Port
    Install-AndroidDcFtpCompanion -Serial $Serial
    $stopToken = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
    $dex = Get-RawFtpDexPath
    $remoteDex = '/data/local/tmp/androiddc-rawftp.dex'
    $remoteCredentials = '/data/local/tmp/androiddc-rawftp-credentials'
    $localCredentials = Join-Path ([IO.Path]::GetTempPath()) ('androiddc-ftp-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllText($localCredentials, "$Username`n$Password`n", [Text.UTF8Encoding]::new($false))
        $credentialPush = Invoke-Adb -CommandArguments @('-s', $Serial, 'push', $localCredentials, $remoteCredentials)
        if ($credentialPush.ExitCode -ne 0) { throw 'Could not send FTP credentials to the phone.' }
    } finally { Remove-Item -LiteralPath $localCredentials -Force -ErrorAction SilentlyContinue }
    $stopExisting = 'for pid in $(pidof app_process 2>/dev/null); do if cat "/proc/$pid/cmdline" 2>/dev/null | tr "\000" " " | grep -q "com.androiddc.RawFtpServer"; then kill "$pid" 2>/dev/null || true; fi; done; '
    $command = $stopExisting + "chmod 600 $remoteCredentials || exit 1; mkdir -p /sdcard/AndroidDC-FTP; printf 'AndroidDC raw FTP test file\n' > /sdcard/AndroidDC-FTP/connection-test.txt; " +
        "CLASSPATH=$remoteDex app_process /system/bin com.androiddc.RawFtpServer /sdcard $Port $remoteCredentials $stopToken </dev/null >/data/local/tmp/androiddc-rawftp.log 2>&1 & echo `$! >/data/local/tmp/androiddc-rawftp.pid"
    try {
        $push = Invoke-Adb -CommandArguments @('-s', $Serial, 'push', $dex, $remoteDex)
        if ($push.ExitCode -ne 0) { throw $push.Text }
        $start = Invoke-DeviceShellText -Serial $Serial -Command $command
        if ($start.ExitCode -ne 0) { throw $start.Text }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            Wait-Pumped -Milliseconds 100
            $log = Invoke-DeviceCommand -Serial $Serial -Arguments @('cat', '/data/local/tmp/androiddc-rawftp.log')
        } until ($log.Text -match '(?m)^READY ftp://' -or $watch.ElapsedMilliseconds -gt 7000)
        if ($log.Text -notmatch '(?m)^READY ftp://([^/\s]+)/(?:\s+control=(\d+))') { throw "The phone FTP server did not start. $($log.Text)" }
        $uri = [Uri]("ftp://" + $Matches[1] + '/')
        $controlPort = [int]$Matches[2]
        $service = Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', 'am', 'start-foreground-service', '-n', 'com.androiddc.ftpcontrol/.FtpControlService', '--ei', 'control_port', "$controlPort", '--es', 'stop_token', $stopToken)
        if ($service.ExitCode -ne 0 -or $service.Text -match 'Error|Exception') {
            $null = Stop-AndroidDcRawFtp -Serial $Serial
            throw "Could not show the FTP notification on the phone. $($service.Text)"
        }
        Save-AndroidDcFtpLogin -Serial $Serial -Username $Username -Password $Password
        return [PSCustomObject]@{ Uri = $uri; Log = $log.Text }
    } finally { $null = Invoke-DeviceShellText -Serial $Serial -Command "rm -f $remoteCredentials" }
}

function Stop-AndroidDcRawFtp {
    param([string]$Serial)
    $command = 'for pid in $(pidof app_process 2>/dev/null); do if cat "/proc/$pid/cmdline" 2>/dev/null | tr "\000" " " | grep -q "com.androiddc.RawFtpServer"; then kill "$pid" 2>/dev/null || true; fi; done; rm -f /data/local/tmp/androiddc-rawftp.pid /data/local/tmp/androiddc-rawftp-credentials'
    $result = Invoke-DeviceShellText -Serial $Serial -Command $command
    if ($result.ExitCode -ne 0) { throw $result.Text }
    $null = Invoke-Adb -CommandArguments @('-s', $Serial, 'shell', 'am', 'stopservice', '-n', 'com.androiddc.ftpcontrol/.FtpControlService')
    Remove-Item -LiteralPath (Get-AndroidDcFtpSavedPath $Serial) -Force -ErrorAction SilentlyContinue
    return 'AndroidDC raw FTP server stopped.'
}
