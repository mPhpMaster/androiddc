# Advanced > Automation: the actions a rule can hold, the rules file, telling a
# phone that was just plugged in from one that was already there, and the
# start-with-Windows entry. No phone needed and nothing is sent to one: the
# phones here are made up. run.ps1 points the rules file, the Run key and the
# mutex at test copies, so the user's own are never read or written.

$realRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
function Get-RealRunValue {
    try { return "$((Get-ItemProperty -LiteralPath $realRunKey -Name 'AndroidDC' -ErrorAction Stop).AndroidDC)" } catch { return '<none>' }
}
$realBefore = Get-RealRunValue

Say '== where it writes =='
Say ("  rules file is the test's: {0}   {1}" -f (Split-Path -Leaf $script:automationFile),
    (Mark ($script:automationFile -like "$env:TEMP*" -and $script:automationFile -notlike "$env:APPDATA*")))
Say ("  Run key is the test's   {0}" -f (Mark ($script:automationRunKey -eq 'HKCU:\Software\AndroidDC-tests\Run')))

Say ''
Say '== the actions =='
$actions = @(Get-AutomationActionList)
$ids = @($actions | ForEach-Object { $_.Id })
Say ("  {0} actions, every id once   {1}" -f $actions.Count, (Mark ($actions.Count -ge 30 -and @($ids | Sort-Object -Unique).Count -eq $ids.Count)))
$missing = @($actions | Where-Object { $_.Command -and -not (Get-Command $_.Command -ErrorAction SilentlyContinue) } | ForEach-Object { $_.Command })
Say ("  every function they call is in this window{0}   {1}" -f $(if ($missing) { ' - missing: ' + ($missing -join ', ') } else { '' }), (Mark ($missing.Count -eq 0)))
Say ("  wake comes first, before the actions that tap the phone   {0}" -f (Mark ($ids[0] -eq 'wake')))
Say ("  the checklist has one line per action   {0}" -f (Mark ($clbAutoActions.Items.Count -eq $actions.Count)))

Say ''
Say '== the rules file =='
$one = [PSCustomObject]@{ Serial = 'A1'; Name = 'Phone A'; Enabled = $true
    Actions = @([PSCustomObject]@{ Id = 'usb-tether-on'; Value = '' }) }
$saved = Save-AutomationRules -Rules @($one)
$json = Get-Content -LiteralPath $script:automationFile -Raw
$back = @(Read-AutomationRules)
Say ("  one rule with one action is saved as lists   {0}" -f (Mark ($saved -and $json -match '"Rules":\s*\[' -and $json -match '"Actions":\s*\[')))
Say ("  and read back the same   {0}" -f (Mark ($back.Count -eq 1 -and $back[0].Serial -eq 'A1' -and @($back[0].Actions).Count -eq 1 -and $back[0].Actions[0].Id -eq 'usb-tether-on')))
$empty = Save-AutomationRules -Rules @()
Say ("  no rules: an empty list   {0}" -f (Mark ($empty -and @(Read-AutomationRules).Count -eq 0)))

Set-Content -LiteralPath $script:automationFile -Value '{ not json' -Encoding UTF8
$broken = @(Read-AutomationRules)
$refused = Save-AutomationRules -Rules @($one)
$still = Get-Content -LiteralPath $script:automationFile -Raw
Say ("  a file that cannot be read gives no rules and says why   {0}" -f (Mark ($broken.Count -eq 0 -and (Get-AutomationReadError))))
Say ("  and is not overwritten   {0}" -f (Mark (-not $refused -and $still -match 'not json')))
Remove-Item -LiteralPath $script:automationFile -Force
$null = Read-AutomationRules

Say ''
Say '== plugged in, or already there =='
function New-Phone { param([string]$Serial, [string]$State = 'device') [PSCustomObject]@{ Serial = $Serial; State = $State; Model = 'm'; Link = 'usb' } }
$null = Save-AutomationRules -Rules @(
    [PSCustomObject]@{ Serial = 'B2'; Name = 'B'; Enabled = $true; Actions = @([PSCustomObject]@{ Id = 'wake'; Value = '' }) },
    [PSCustomObject]@{ Serial = 'C3'; Name = 'C'; Enabled = $false; Actions = @([PSCustomObject]@{ Id = 'wake'; Value = '' }) },
    [PSCustomObject]@{ Serial = 'D4'; Name = 'D'; Enabled = $true; Actions = @() })
# the real device watch would read the real list over these made-up ones
$deviceWatchTimer.Stop()
$keptSeen = $script:automationSeen
$script:automationQueue.Clear()

Initialize-Automation -ProjectRoot $scriptRoot -CountPresent $false
$script:automationPrimed = $false
$script:automationSeen = @()
$first = @(Register-AutomationArrivals -Devices @((New-Phone 'A1'), (New-Phone 'B2')))
Say ("  opened by hand: phones already there are not arrivals   {0}" -f (Mark ($first.Count -eq 0 -and $script:automationQueue.Count -eq 0)))
$next = @(Register-AutomationArrivals -Devices @((New-Phone 'A1'), (New-Phone 'B2'), (New-Phone 'C3' 'unauthorized')))
Say ("  a phone waiting for its RSA prompt is not ready yet   {0}" -f (Mark ($next.Count -eq 0)))
$accepted = @(Register-AutomationArrivals -Devices @((New-Phone 'A1'), (New-Phone 'C3'), (New-Phone 'D4')))
Say ("  accepted C3 and new D4 arrive; B2 left   {0}" -f (Mark (($accepted -join ',') -eq 'C3,D4' -and $script:automationSeen -notcontains 'B2')))
Say ("  C3's rule is off and D4's has nothing: none queued   {0}" -f (Mark ($script:automationQueue.Count -eq 0)))
$again = @(Register-AutomationArrivals -Devices @((New-Phone 'A1'), (New-Phone 'B2')))
Say ("  B2 plugged in again: queued once   {0}" -f (Mark (($again -join ',') -eq 'B2' -and @($script:automationQueue).Count -eq 1 -and $script:automationQueue[0] -eq 'B2')))
Say ("  this window runs the rules (it holds the test mutex)   {0}" -f (Mark (Test-AutomationOwner)))

$script:automationQueue.Clear()
Initialize-Automation -ProjectRoot $scriptRoot -CountPresent $true
$script:automationPrimed = $false
$script:automationSeen = @()
$boot = @(Register-AutomationArrivals -Devices @((New-Phone 'B2')))
Say ("  started with Windows: a phone already there runs its rule   {0}" -f (Mark ($boot.Count -eq 1 -and $script:automationQueue.Count -eq 1)))
$script:automationQueue.Clear()
Initialize-Automation -ProjectRoot $scriptRoot -CountPresent $false

Say ''
Say '== running a rule =='
$script:testLeft = 'not called'
$rule = [PSCustomObject]@{ Serial = 'Z9'; Name = 'Z'; Enabled = $true; Actions = @([PSCustomObject]@{ Id = 'no-such-action'; Value = '' }) }
Invoke-AutomationRule -Rule $rule -Enter { param($Serial) $false } -Leave { param($State) $script:testLeft = "called with $State" }
Say ("  a phone not in the list runs nothing, and the selection is still put back   {0}" -f (Mark ($script:testLeft -eq 'called with False' -and -not $script:automationRunning)))
$logBefore = $txtLog.Text.Length
Invoke-AutomationRule -Rule $rule -Enter { param($Serial) [PSCustomObject]@{ All = $false } } -Leave { param($State) $script:testLeft = 'put back' }
$said = $txtLog.Text.Substring($logBefore)
Say ("  an unknown action is skipped and the rule still ends   {0}" -f (Mark ($said -match "unknown action 'no-such-action'" -and $said -match 'Z done' -and $script:testLeft -eq 'put back')))
Say ("  the made-up phone is not in the list, so Enter says so   {0}" -f (Mark ((Enter-AutomationDevice -Serial 'Z9') -eq $false)))
$script:automationSeen = $keptSeen
$deviceWatchTimer.Start()

Say ''
Say '== start with Windows =='
$wroteClassic = Set-AutomationStartup -Window 'classic'
$value = "$((Get-ItemProperty -LiteralPath $script:automationRunKey -Name 'AndroidDC').AndroidDC)"
Say ("  classic: '{0}'   {1}" -f $value, (Mark ($wroteClassic -and $value -match '\\androiddc\.vbs" -Minimized$' -and (Get-AutomationStartup) -eq 'classic')))
$wroteNova = Set-AutomationStartup -Window 'nova'
Say ("  nova   {0}" -f (Mark ($wroteNova -and (Get-AutomationStartup) -eq 'nova')))
$removed = Set-AutomationStartup -Window ''
Say ("  off: the value is gone   {0}" -f (Mark ($removed -and (Get-AutomationStartup) -eq '')))
Remove-Item -LiteralPath 'HKCU:\Software\AndroidDC-tests' -Recurse -Force -ErrorAction SilentlyContinue
Say ("  the real Run key was not touched   {0}" -f (Mark ((Get-RealRunValue) -eq $realBefore)))

Say ''
Say '== the tab =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabAutomation
Wait-Pumped -Milliseconds 400
$null = Save-AutomationRules -Rules @([PSCustomObject]@{ Serial = 'E5'; Name = 'Phone E'; Enabled = $true; Actions = @() })
Update-AutomationTab
Say ("  one rule listed and selected, its checklist enabled   {0}" -f (Mark ($lstAutoRules.Items.Count -eq 1 -and $lstAutoRules.SelectedItems.Count -eq 1 -and $clbAutoActions.Enabled)))
$wakeAt = [Array]::IndexOf($script:automationActionIds, 'wake')
$appAt = [Array]::IndexOf($script:automationActionIds, 'app')
$clbAutoActions.SetItemChecked($wakeAt, $true)
$clbAutoActions.SetItemChecked($appAt, $true)
$txtAutoApp.Text = 'com.example.app'
$stored = @(Read-AutomationRules)[0]
Say ("  ticking saves at once: {0}   {1}" -f (Get-AutomationRuleSummary -Rule $stored),
    (Mark (@($stored.Actions).Count -eq 2 -and $stored.Actions[0].Id -eq 'wake' -and $stored.Actions[1].Value -eq 'com.example.app')))
$chkAutoRuleOn.Checked = $false
Say ("  switched off: saved and shown   {0}" -f (Mark (-not @(Read-AutomationRules)[0].Enabled -and $lstAutoRules.Items[0].Text -eq 'off')))
Remove-AutomationTabRule
Say ("  removed: no rules, nothing to tick   {0}" -f (Mark (@(Read-AutomationRules).Count -eq 0 -and $lstAutoRules.Items.Count -eq 0 -and -not $clbAutoActions.Enabled)))
# the watch's own condition, in a window started from a hidden process as the
# launcher starts it; Form.CanFocus was false here and the watch never ran
Say ("  no question is waiting, so the device watch runs   {0}" -f (Mark ([AndroidDcNative]::IsWindowEnabled($form.Handle))))
# and it really ticks: a stale signature makes the next tick read the list again
# (adb devices and getprop only), which puts the real signature back
$real = Get-DeviceSignature -Devices @(Get-AdbDevices)
$script:deviceSignature = 'a list that is not there'
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while ($script:deviceSignature -ne $real -and $watch.Elapsed.TotalSeconds -lt 15) { Wait-Pumped -Milliseconds 200 }
Say ("  and it really ticks: the list was read again after {0:N1} s   {1}" -f $watch.Elapsed.TotalSeconds, (Mark ($script:deviceSignature -eq $real)))
$tabs.SelectedTab = $tabDevice
Wait-Pumped -Milliseconds 300

Say ''
Say '== the icon by the clock =='
$handle = $form.Handle
Say ("  there, with Automation, FTP, Show, Hide and Exit   {0}" -f (Mark ($null -ne $script:trayIcon -and $script:trayIcon.Visible -and $null -ne $script:trayFtpItem -and $script:trayIcon.ContextMenuStrip.Items.Count -eq 7)))

Say ''
Say '== the rules set before, seen without opening their tab =='
Say ("  the log said so at startup   {0}" -f (Mark ($txtLog.Text -match 'Automation: no rules\. Does not start with Windows\.' -and $txtLog.Text -match 'set in Advanced > Automation')))
$null = Save-AutomationRules -Rules @(
    [PSCustomObject]@{ Serial = 'F6'; Name = 'Phone F'; Enabled = $true; Actions = @([PSCustomObject]@{ Id = 'usb-tether-on'; Value = '' }) },
    [PSCustomObject]@{ Serial = 'G7'; Name = 'Phone G'; Enabled = $false; Actions = @([PSCustomObject]@{ Id = 'wake'; Value = '' }) })
$overview = Get-AutomationOverview
Say ("  '{0}'   {1}" -f $overview.Title, (Mark ($overview.Title -eq 'Automation: 2 rule(s), 1 on' -and $overview.Lines.Count -eq 3)))
Say ("  '{0}'   {1}" -f $overview.Lines[1], (Mark ($overview.Lines[1] -match '^Phone F \(F6\) - on: Share the phone' -and $overview.Lines[2] -match '^Phone G \(G7\) - off: Wake the screen')))
Update-TrayMenu
$dropped = @($script:trayRulesItem.DropDownItems | ForEach-Object { $_.Text })
Say ("  the icon's menu lists them: {0}   {1}" -f ($dropped -join ' | '),
    (Mark ($script:trayRulesItem.Text -eq $overview.Title -and $dropped -contains 'Open the rules ...' -and @($dropped | Where-Object { $_ -match '^Phone [FG]' }).Count -eq 2)))
Say ("  its tooltip: '{0}'   {1}" -f $script:trayIcon.Text, (Mark ($script:trayIcon.Text -eq 'AndroidDC - 1 automation rule(s) on')))
Update-AutomationTab
Say ("  the tab: '{0}'   {1}" -f $tabAutomation.Text, (Mark ($tabAutomation.Text -eq 'Automation (2)')))
$tabs.SelectedTab = $tabDevice
Open-TrayRules
Wait-Pumped -Milliseconds 400
Say ("  'Open the rules' opens Advanced > Automation   {0}" -f (Mark ((Test-PageShown -Page $tabAutomation))))
$form.Location = New-Object System.Drawing.Point(-2400, -2000)
$null = Save-AutomationRules -Rules @()
Update-AutomationTab
Say ("  no rules: the tab is plain again   {0}" -f (Mark ($tabAutomation.Text -eq 'Automation')))
$tabs.SelectedTab = $tabDevice
Wait-Pumped -Milliseconds 300
$script:trayTold = $true   # no balloon on the user's screen from a test
Hide-TrayWindow
Wait-Pumped -Milliseconds 400
Say ("  hidden: off screen, and the window is still open   {0}" -f (Mark ((Test-TrayHidden) -and -not [AndroidDcTrayNative]::IsWindowVisible($handle) -and -not $form.IsDisposed)))
Wait-Pumped -Milliseconds 800
Say ("  the device watch goes on while hidden   {0}" -f (Mark ([AndroidDcNative]::IsWindowEnabled($handle))))
Show-TrayWindow
Wait-Pumped -Milliseconds 400
Say ("  shown again   {0}" -f (Mark (-not (Test-TrayHidden) -and [AndroidDcTrayNative]::IsWindowVisible($handle))))
$form.WindowState = 'Minimized'
Wait-Pumped -Milliseconds 600
Say ("  minimized goes into the tray   {0}" -f (Mark ((Test-TrayHidden) -and -not [AndroidDcTrayNative]::IsWindowVisible($handle))))
Show-TrayWindow
Wait-Pumped -Milliseconds 600
Say ("  and comes back restored, not minimized   {0}" -f (Mark ($form.WindowState -eq 'Normal' -and [AndroidDcTrayNative]::IsWindowVisible($handle))))
# the test window lives off screen; put it back there after SW_RESTORE
$form.Location = New-Object System.Drawing.Point(-2400, -2000)
