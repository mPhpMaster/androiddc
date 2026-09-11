# needs: phone
# The live shell keeps answering while logcat runs, after it stops, and after
# a second run. Logcat was once read through Register-ObjectEvent, and from
# then on no asynchronous read completed on any adb process started later:
# the shell took commands and printed nothing until AndroidDC was restarted.

# built from code points: test files are ASCII
$word = -join [char[]](0x0646, 0x0641, 0x0627, 0x0630)

function Test-Shell {
    param([string]$Label)
    Start-LiveShell
    $shellTimer.Stop()   # answers are drained here, not by the window's timer
    Wait-Pumped -Milliseconds 1500
    $null = $script:shell.Drain(400)
    $script:shell.Send('echo ' + $Label)
    $script:shell.Send('echo ' + $word)
    Wait-Pumped -Milliseconds 2500
    $got = @($script:shell.Drain(400) | Where-Object { $_.Trim() })
    Say ("  shell {0}: ascii {1}, arabic {2}   {3}" -f $Label, ($got -contains $Label), ($got -contains $word),
        (Mark (($got -contains $Label) -and ($got -contains $word))))
    Stop-LiveShell -Quiet
    Wait-Pumped -Milliseconds 500
}

Select-TestPhone
$tabs.SelectedTab = $tabShellHost
$tabsShell.SelectedTab = $tabLogcat
Wait-Pumped -Milliseconds 400

$btnLogcatStart.PerformClick()
Wait-Pumped -Milliseconds 4000
$info = $script:logcatProcess.StartInfo
Say ("logcat streams   {0}" -f (Mark ($script:logcatRaw -and $script:logcatRaw.Count -gt 0)))
Say ("logcat reads UTF-8   {0}" -f (Mark ($info.StandardOutputEncoding.WebName -eq 'utf-8' -and $info.StandardErrorEncoding.WebName -eq 'utf-8')))
Say ("no PowerShell subscription behind it   {0}" -f (Mark (@($script:logcatSubs).Count -eq 0)))

$tabsShell.SelectedTab = $tabShell
Wait-Pumped -Milliseconds 400
Test-Shell -Label 'while-logcat-runs'

$tabsShell.SelectedTab = $tabLogcat
Wait-Pumped -Milliseconds 400
$btnLogcatStop.PerformClick()
Wait-Pumped -Milliseconds 1500
Say ("logcat stopped   {0}" -f (Mark ((-not $script:logcatProcess) -and $btnLogcatStart.Enabled)))

$tabsShell.SelectedTab = $tabShell
Wait-Pumped -Milliseconds 400
Test-Shell -Label 'after-logcat'

$tabsShell.SelectedTab = $tabLogcat
Wait-Pumped -Milliseconds 400
$btnLogcatStart.PerformClick()
Wait-Pumped -Milliseconds 3000
$btnLogcatStop.PerformClick()
Wait-Pumped -Milliseconds 1500
$tabsShell.SelectedTab = $tabShell
Wait-Pumped -Milliseconds 400
Test-Shell -Label 'after-a-second-logcat'
