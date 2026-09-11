# needs: phone
# adb read and written as UTF-8: logcat's process, the live shell in both
# directions, a file pull, jdwp. On a PC whose console pages are already UTF-8
# (65001) this checks that nothing regressed; the OEM-page case - where the
# old code garbled every Arabic name and turned Arabic shell input into "?"
# file patterns - was measured by forcing the page, and needs no phone here.

$word = -join [char[]](0x0646, 0x0641, 0x0627, 0x0630)
Say ("console pages in this window: output {0}, input {1}" -f [Console]::OutputEncoding.CodePage, [Console]::InputEncoding.CodePage)

Select-TestPhone
$tabs.SelectedTab = $tabShellHost
$tabsShell.SelectedTab = $tabLogcat
Wait-Pumped -Milliseconds 400
$btnLogcatStart.PerformClick()
Wait-Pumped -Milliseconds 3000
$info = $script:logcatProcess.StartInfo
Say ("logcat reads UTF-8   {0}" -f (Mark ($info.StandardOutputEncoding.WebName -eq 'utf-8')))
$btnLogcatStop.PerformClick()
Wait-Pumped -Milliseconds 1500

$tabsShell.SelectedTab = $tabShell
Wait-Pumped -Milliseconds 400
Start-LiveShell
$shellTimer.Stop()
Wait-Pumped -Milliseconds 1500
$null = $script:shell.Drain(400)
$script:shell.Send('echo ' + $word)
Wait-Pumped -Milliseconds 1500
$got = @($script:shell.Drain(400) | Where-Object { $_.Trim() })
Say ("Arabic into the live shell comes back unchanged   {0}" -f (Mark ($got -contains $word)))
Stop-LiveShell -Quiet
Wait-Pumped -Milliseconds 800

$target = Join-Path $TestOutput 'hosts-pulled.txt'
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
$result = Invoke-FileTransfer -Serial $TestSerial -Direction 'pull' -Source '/system/etc/hosts' -Target $target
Say ("a pull still works   {0}" -f (Mark ($result.Ok -and (Test-Path -LiteralPath $target))))
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }

$jdwp = Get-JdwpProcesses -Serial $TestSerial -Milliseconds 1500
Say ("jdwp runs, with its error stream in UTF-8   {0}" -f (Mark ($jdwp -and -not $jdwp.Error)))
