<#
.SYNOPSIS
    Runs AndroidDC's tests: the real window, driven by a test script.

.DESCRIPTION
    There is no unit-test framework here; the program is tested by running
    it. For each test this makes a copy of androiddc.ps1 with the test spliced
    into $form.Add_Shown, starts it off screen, waits for the test to finish,
    closes the window, and reads the report the test wrote.

    Rules this harness keeps, each learned the hard way:

      * The window is never killed. Settings are only written on a normal
        close, so it is closed with WM_CLOSE - what the title-bar X sends.
      * The real settings file is never touched. The copy reads and writes a
        settings file in the output folder, seeded from the real one.
      * Every text replacement must match exactly once. String.Replace hits
        every occurrence without a word, and two anchors in androiddc.ps1 are
        not unique: this is how a test was once spliced into two buttons too.
      * The previous report is deleted before a run. A leftover "done" line
        was found at once and the window closed before the new test began.
      * A locked report file means "still writing", not an error.

    Nothing about any machine is written into these files: the project is
    found from this script's own location, output goes under %TEMP%, and the
    phone's serial comes from -Serial or ANDROIDDC_TEST_SERIAL.

.PARAMETER Test
    Test names, without .ps1, or 'all'.

.PARAMETER Serial
    The phone to test on. Tests marked "needs: phone" are skipped without one.
    With several phones attached, this is the only one the tests select.

.EXAMPLE
    powershell -File tests\run.ps1 -Test layout,pane-resize

.EXAMPLE
    powershell -File tests\run.ps1 -Test all -Serial <serial from "adb devices">
#>
[CmdletBinding()]
param(
    [string[]]$Test = @('all'),
    [string]$Serial = $env:ANDROIDDC_TEST_SERIAL,
    [int]$Timeout = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'androiddc.ps1'
$output = Join-Path $env:TEMP 'androiddc-tests'
if (-not (Test-Path -LiteralPath $output)) { $null = New-Item -ItemType Directory -Path $output }

# "powershell -File run.ps1 -Test a,b" hands over one string, "a,b": the comma
# only makes an array when PowerShell parses the command line itself
$Test = @($Test | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$available = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File |
    Where-Object { $_.Name -ne 'run.ps1' } | ForEach-Object { $_.BaseName } | Sort-Object)
if ($Test -contains 'all') { $Test = $available }
foreach ($name in $Test) {
    if ($available -notcontains $name) { throw "no test called '$name' - there are: $($available -join ', ')" }
}

function Set-Once {
    # replace exactly one occurrence, or stop
    param([string]$Text, [string]$Old, [string]$New)
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "expected one '$Old' in androiddc.ps1, found $count" }
    return $Text.Replace($Old, $New)
}

function ConvertTo-Quoted {
    # a value for a single-quoted PowerShell string
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

if (-not ('TestWindow' -as [type])) {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class TestWindow {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
}

$realSettings = Join-Path $env:APPDATA 'AndroidDC\settings.json'
$program = Get-Content -LiteralPath $source -Raw
$results = @()

foreach ($name in $Test) {
    $file = Join-Path $PSScriptRoot "$name.ps1"
    $body = Get-Content -LiteralPath $file -Raw

    if ($body -match '(?m)^# needs: phone' -and -not $Serial) {
        Write-Host ("SKIP  {0,-14} needs a phone: pass -Serial or set ANDROIDDC_TEST_SERIAL" -f $name)
        $results += [PSCustomObject]@{ Test = $name; Result = 'skipped' }
        continue
    }

    $title = "AndroidDC test $name"
    $report = Join-Path $output "$name.txt"
    $settings = Join-Path $output "settings-$name.json"
    $copy = Join-Path $output "run-$name.ps1"

    if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force }
    if (Test-Path -LiteralPath $realSettings) { Copy-Item -LiteralPath $realSettings -Destination $settings -Force }
    elseif (Test-Path -LiteralPath $settings) { Remove-Item -LiteralPath $settings -Force }

    # what every test can use
    $prelude = @"
`$TestSerial = $(ConvertTo-Quoted $Serial)
`$TestReport = $(ConvertTo-Quoted $report)
`$TestOutput = $(ConvertTo-Quoted $output)
function Say { param([string]`$Text) for (`$i = 0; `$i -lt 20; `$i++) { try { Add-Content -LiteralPath `$TestReport -Value `$Text -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 50 } } }
function Mark { param([bool]`$Ok, [string]`$Bad = 'FAIL') if (`$Ok) { 'OK' } else { `$Bad } }
function Select-TestPhone {
    # with several phones attached, only the one under test is ever selected
    foreach (`$item in `$lstDevices.Items) { `$item.Selected = (`$item.Text -eq `$TestSerial) }
    Wait-Pumped -Milliseconds 1200
}
trap { Say ('TRAPPED: ' + `$_.Exception.Message); continue }
"@

    $text = $program
    $text = Set-Once $text "'AndroidDC - Android Device Control'" (ConvertTo-Quoted $title)
    # the copy runs from the output folder, so it is told where the tools are
    $text = Set-Once $text "`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path" `
        "`$scriptRoot = $(ConvertTo-Quoted $root)"
    $text = Set-Once $text "`$settingsPath = Join-Path `$env:APPDATA 'AndroidDC\settings.json'" `
        "`$settingsPath = $(ConvertTo-Quoted $settings)"

    # "    Update-DeviceList })" closes three handlers; splice into Add_Shown only
    $shown = $text.IndexOf("`$form.Add_Shown({")
    if ($shown -lt 0 -or $text.IndexOf("`$form.Add_Shown({", $shown + 1) -ge 0) { throw 'expected exactly one $form.Add_Shown({' }
    $anchor = "    Update-DeviceList`r`n})"
    $at = $text.IndexOf($anchor, $shown)
    if ($at -lt 0) { $anchor = "    Update-DeviceList`n})"; $at = $text.IndexOf($anchor, $shown) }
    if ($at -lt 0) { throw 'the end of Add_Shown was not found' }
    $text = $text.Substring(0, $at) + "    Update-DeviceList`r`n" + $prelude + "`r`n" + $body + "`r`nSay 'TEST DONE'`r`n})" +
        $text.Substring($at + $anchor.Length)

    $text = Set-Once $text "[void]`$form.ShowDialog()" `
        "`$form.StartPosition = 'Manual'; `$form.Location = New-Object System.Drawing.Point(-2400, -2000); [void]`$form.ShowDialog()"
    Set-Content -LiteralPath $copy -Value $text -Encoding UTF8

    $before = if (Test-Path -LiteralPath $realSettings) { (Get-FileHash -LiteralPath $realSettings).Hash } else { '' }
    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$copy`"" `
        -RedirectStandardError (Join-Path $output "run-$name.err") -RedirectStandardOutput (Join-Path $output "run-$name.out")

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $done = $false
    while ($watch.Elapsed.TotalSeconds -lt $Timeout -and -not $process.HasExited) {
        if (Test-Path -LiteralPath $report) {
            try { $done = (Get-Content -LiteralPath $report -Raw -ErrorAction Stop) -match '(?m)^TEST DONE' } catch { $done = $false }
        }
        if ($done) { break }
        Start-Sleep -Milliseconds 500
    }

    $closed = $process.HasExited
    if (-not $closed) {
        # [NullString]::Value, not $null: PowerShell would marshal $null as ""
        $handle = [TestWindow]::FindWindow([NullString]::Value, $title)
        if ($handle -ne [IntPtr]::Zero) { [void][TestWindow]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        $closed = $process.WaitForExit(30000)
    }
    $after = if (Test-Path -LiteralPath $realSettings) { (Get-FileHash -LiteralPath $realSettings).Hash } else { '' }

    $lines = if (Test-Path -LiteralPath $report) { @(Get-Content -LiteralPath $report -Encoding UTF8) } else { @() }
    $failures = @($lines | Where-Object { $_ -match '\bFAIL\b|^TRAPPED' })
    $result = 'passed'
    if (-not $done) { $result = 'did not finish' }
    elseif ($failures.Count -gt 0) { $result = "$($failures.Count) failed" }
    if (-not $closed) { $result += ' (window left running, not killed)' }
    if ($after -ne $before) { $result += ' (THE REAL SETTINGS FILE CHANGED)' }

    Write-Host ''
    Write-Host ("===== {0}: {1} =====" -f $name, $result)
    foreach ($line in $lines) { Write-Host $line }
    if (-not $done) {
        Get-Content -LiteralPath (Join-Path $output "run-$name.err") -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Host $_ }
    }
    $results += [PSCustomObject]@{ Test = $name; Result = $result }
}

Write-Host ''
Write-Host 'Summary'
foreach ($entry in $results) { Write-Host ("  {0,-14} {1}" -f $entry.Test, $entry.Result) }
Write-Host ("Reports and screenshots: {0}" -f $output)
$bad = @($results | Where-Object { $_.Result -ne 'passed' -and $_.Result -ne 'skipped' }).Count
exit $bad
