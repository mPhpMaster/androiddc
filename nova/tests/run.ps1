<#
.SYNOPSIS
    Runs AndroidDC Nova's tests: the real program, off screen, with a test inside.

.DESCRIPTION
    Each test is a script run by androiddc-nova.ps1 -TestScript once the
    window is on screen, with tests\common.ps1 loaded first. The program
    closes itself normally when the test ends. Settings go to a file under
    %TEMP%, never the real one. A test reports lines ending in OK or FAIL;
    FAIL and TEST TRAPPED are counted, case-sensitively.

    With a phone attached, tests only read from it.

.PARAMETER Test
    Test names without .ps1, or 'all'.

.EXAMPLE
    powershell -File tests\run.ps1 -Test shell,apps
#>
[CmdletBinding()]
param(
    [string[]]$Test = @('all'),
    [int]$Timeout = 300,
    # load only these pages (e.g. Apps,Running); every page when empty
    [string]$Pages = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$program = Join-Path $root 'androiddc-nova.ps1'
$work = Join-Path $env:TEMP 'androiddc-nova-tests'
if (-not (Test-Path -LiteralPath $work)) { $null = New-Item -ItemType Directory -Path $work }

$Test = @($Test | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$available = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File |
    # audit.ps1 checks the files without starting the program, and ends in exit:
    # run inside the window it would close it abruptly instead of normally
    Where-Object { @('run.ps1', 'common.ps1', 'audit.ps1') -notcontains $_.Name } | ForEach-Object { $_.BaseName } | Sort-Object)
if ($Test -contains 'all') { $Test = $available }
foreach ($name in $Test) {
    if ($available -notcontains $name) { throw "no test called '$name' - there are: $($available -join ', ')" }
}

$results = @()
foreach ($name in $Test) {
    $wrapper = Join-Path $work "run-$name.ps1"
    $common = (Join-Path $PSScriptRoot 'common.ps1').Replace("'", "''")
    $body = (Join-Path $PSScriptRoot "$name.ps1").Replace("'", "''")
    Set-Content -LiteralPath $wrapper -Encoding UTF8 -Value @"
. '$common'
. '$body'
Say 'TEST DONE'
"@
    $settings = Join-Path $work "settings-$name.json"
    if (Test-Path -LiteralPath $settings) { Remove-Item -LiteralPath $settings -Force }
    $log = Join-Path $work "$name.out"

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $log `
        -RedirectStandardError (Join-Path $work "$name.err") -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -STA -File `"$program`" -OffScreen -SettingsPath `"$settings`" -TestScript `"$wrapper`"" +
            $(if ($Pages) { " -Pages $Pages" } else { '' }))
    $finished = $process.WaitForExit($Timeout * 1000)

    $lines = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log -Encoding UTF8) } else { @() }
    $errors = if (Test-Path -LiteralPath (Join-Path $work "$name.err")) { @(Get-Content -LiteralPath (Join-Path $work "$name.err")) } else { @() }
    $failures = @($lines | Where-Object { $_ -cmatch '\bFAIL\b|TEST TRAPPED' })
    $done = @($lines | Where-Object { $_ -match '^TEST DONE' }).Count -gt 0

    $result = 'passed'
    if (-not $finished) { $result = 'did not finish (window left running, not killed)' }
    elseif (-not $done) { $result = 'did not reach the end' }
    elseif ($failures.Count -gt 0) { $result = "$($failures.Count) failed" }

    Write-Host ''
    Write-Host ("===== {0}: {1} =====" -f $name, $result)
    foreach ($line in $lines) { Write-Host $line }
    foreach ($line in @($errors | Select-Object -First 15)) { Write-Host "  stderr: $line" }
    $results += [PSCustomObject]@{ Test = $name; Result = $result }
}

Write-Host ''
Write-Host 'Summary'
foreach ($entry in $results) { Write-Host ("  {0,-14} {1}" -f $entry.Test, $entry.Result) }
Write-Host "Pictures and output: $work"
exit @($results | Where-Object { $_.Result -ne 'passed' }).Count
