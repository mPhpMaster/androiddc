# Regression checks run extracted production functions with a fake phone.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
foreach ($source in @('androiddc.ps1', 'nova/pages/Files.ps1')) {
    & {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $source), [ref]$tokens, [ref]$errors)
        if ($errors) { throw "$source does not parse" }
        foreach ($name in @('Update-FileList', 'Open-FileEntry', 'Join-DevicePath')) {
            $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            Invoke-Expression $node.Extent.Text
        }
        function Get-TargetSerial { 'fake' }
        function Quote-DeviceArgument { param($Text) $Text }
        function Write-Log { param($Text, $Color) }
        function Show-FileRows { }
        function Show-FileSpace { param($Serial,$Path) }
        function Invoke-DeviceShell { param($Serial,$CommandArguments) [pscustomobject]@{Text=$script:listing;ExitCode=1} }
        $colorBad = ''; $colorWarn = ''
        $txtFilePath = [pscustomobject]@{Text='/sdcard'}
        $chkFileHidden = [pscustomobject]@{Checked=$true}
        $ui = @{FilesPath=[pscustomobject]@{Text='/sdcard'};FilesHidden=[pscustomobject]@{IsChecked=$true}}
        $script:filePath='/sdcard'; $script:fileNavigating=$false
        $script:fileBack=New-Object Collections.ArrayList
        $script:fileForward=New-Object Collections.ArrayList
        $script:fileRows=@()
        $script:listing="ls: /protected: Permission denied`ndrwxr-xr-x 2 root root 4096 2026-09-22 10:00 system`nlrwxrwxrwx 1 root root 21 2026-09-22 10:00 sdcard -> /storage/self/primary"
        Update-FileList -Path '/'
        if ($script:filePath -ne '/' -or $script:fileRows.Count -ne 2) { throw "$source lost readable entries on partial permission error" }
        $script:listing='ls: /data/private/: Permission denied'
        Update-FileList -Path '/data/private'
        if ($script:filePath -ne '/' -or $script:fileRows.Count -ne 2) { throw "$source replaced the current view after access failure" }
        function Get-SelectedFiles { [pscustomobject]@{IsDirectory=$script:isDirectory;Path='/sdcard'} }
        function Update-FileList { param($Path) $script:opened=$Path }
        function Save-DeviceFiles { $script:downloaded=$true }
        $script:isDirectory=$true; $script:opened=''; $script:downloaded=$false
        Open-FileEntry
        if ($script:opened -ne '/sdcard' -or $script:downloaded) { throw "$source downloaded a directory" }
        $script:isDirectory=$false; $script:opened=''; $script:downloaded=$false
        Open-FileEntry
        if ($script:opened -or -not $script:downloaded) { throw "$source treated a file as a directory" }
        Write-Host "OK $source : partial listing, denied path, directory and file opening"
    }
}

. (Join-Path $root 'shared/Ftp.ps1')
$first = New-AndroidDcFtpCredentials
$second = New-AndroidDcFtpCredentials
if ($first.Username -eq $second.Username -or $first.Password -eq $second.Password) { throw 'FTP credentials were reused.' }
Assert-AndroidDcFtpSettings -Username $first.Username -Password $first.Password -Port 2121
$defaults = Get-AndroidDcFtpDefaultCredentials
Assert-AndroidDcFtpSettings -Username $defaults.Username -Password $defaults.Password -Port 2121
foreach ($settings in @(
    @{ Username='anonymous'; Password=''; Port=2121 },
    @{ Username='invalid user'; Password=$first.Password; Port=2121 },
    @{ Username=$first.Username; Password=$first.Password; Port=21 }
)) {
    $rejected = $false
    try { Assert-AndroidDcFtpSettings @settings } catch { $rejected = $true }
    if (-not $rejected) { throw 'FTP accepted invalid credentials or port.' }
}
Write-Host 'OK generated FTP credentials and input validation'
