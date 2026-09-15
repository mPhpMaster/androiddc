# The Automation page: it opens and fits, its switches save the rules file at
# once, the start-with-Windows entry is written where run.ps1 points it, and a
# phone that was already there is told apart from one just plugged in. No phone
# is needed and nothing is sent to one; the phones here are made up.

$realRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
function Get-RealRunValue {
    try { return "$((Get-ItemProperty -LiteralPath $realRunKey -Name 'AndroidDC' -ErrorAction Stop).AndroidDC)" } catch { return '<none>' }
}
$realBefore = Get-RealRunValue

Say '== loaded =='
Say ("  shared\Automation.ps1 found in the project folder   {0}" -f (Mark (Test-AutomationShared)))
Say ("  rules file and Run key are the test's   {0}" -f (Mark ($script:automationFile -like "$env:TEMP*" -and $script:automationRunKey -eq 'HKCU:\Software\AndroidDC-tests\Run')))
$actions = @(Get-AutomationActionList)
$missing = @($actions | Where-Object { $_.Command -and -not (Get-Command $_.Command -ErrorAction SilentlyContinue) } | ForEach-Object { $_.Command })
Say ("  {0} actions, every function they call is here{1}   {2}" -f $actions.Count,
    $(if ($missing) { ' - missing: ' + ($missing -join ', ') } else { '' }), (Mark ($actions.Count -ge 30 -and $missing.Count -eq 0)))
Say ("  one switch per action   {0}" -f (Mark ($script:automationBoxes.Count -eq $actions.Count)))

Say ''
Say '== the page =='
$null = Save-AutomationRules -Rules @([PSCustomObject]@{ Serial = 'E5'; Name = 'Phone E'; Enabled = $true; Actions = @() })
Show-Page -Page 'automation'
$null = Wait-Idle
Say ("  one rule listed and selected   {0}" -f (Mark ($script:automationRuleRows.Count -eq 1 -and $null -ne $ui.AutomationRules.SelectedItem)))
$wake = $script:automationBoxes | Where-Object { $_.Tag -eq 'wake' }
$app = $script:automationBoxes | Where-Object { $_.Tag -eq 'app' }
$wake.IsChecked = $true; Save-AutomationPageRule
$app.IsChecked = $true; Save-AutomationPageRule
$ui.AutomationApp.Text = 'com.example.app'
$stored = @(Read-AutomationRules)[0]
Say ("  switching on saves at once: {0}   {1}" -f (Get-AutomationRuleSummary -Rule $stored),
    (Mark (@($stored.Actions).Count -eq 2 -and $stored.Actions[0].Id -eq 'wake' -and $stored.Actions[1].Value -eq 'com.example.app')))
$ui.AutomationEnabled.IsChecked = $false; Save-AutomationPageRule
Wait-Pumped -Milliseconds 200
Say ("  switched off: saved and shown   {0}" -f (Mark (-not @(Read-AutomationRules)[0].Enabled -and $script:automationRuleRows[0].On -eq 'off')))

foreach ($size in @('default', 'min')) {
    Set-WindowSize -Size $size
    $null = Wait-Idle
    $picture = Save-WindowPicture -Name "automation-$size"
    Say "  $size`: $picture"
    $outside = @(Get-OutsideElements -Root $automationPage.Root)
    Say ("  {0}: nothing sticks out{1}   {2}" -f $size, $(if ($outside) { ' - ' + ($outside -join '; ') } else { '' }), (Mark ($outside.Count -eq 0)))
}

Remove-AutomationPageRule
Say ("  removed: no rules, nothing to switch   {0}" -f (Mark (@(Read-AutomationRules).Count -eq 0 -and $script:automationRuleRows.Count -eq 0 -and -not $ui.AutomationEnabled.IsEnabled)))

Say ''
Say '== plugged in, or already there =='
function New-Phone { param([string]$Serial, [string]$State = 'device') [PSCustomObject]@{ Serial = $Serial; State = $State; Model = 'm'; Link = 'usb' } }
$null = Save-AutomationRules -Rules @([PSCustomObject]@{ Serial = 'B2'; Name = 'B'; Enabled = $true; Actions = @([PSCustomObject]@{ Id = 'wake'; Value = '' }) })
$script:deviceWatchTimer.Stop()
$keptSeen = $script:automationSeen
$script:automationQueue.Clear()
Initialize-Automation -ProjectRoot $script:toolsRoot -CountPresent $false
$script:automationPrimed = $false
$script:automationSeen = @()
$first = @(Register-AutomationArrivals -Devices @((New-Phone 'B2')))
$gone = @(Register-AutomationArrivals -Devices @())
$back = @(Register-AutomationArrivals -Devices @((New-Phone 'B2')))
Say ("  already there: nothing; unplugged and plugged again: queued   {0}" -f (Mark ($first.Count -eq 0 -and ($back -join ',') -eq 'B2' -and $script:automationQueue.Count -eq 1)))
Say ("  this window runs the rules (the test mutex)   {0}" -f (Mark (Test-AutomationOwner)))
$script:automationQueue.Clear()
Say ("  a made-up phone cannot be selected   {0}" -f (Mark ((Enter-AutomationDevice -Serial 'B2') -eq $false)))
$script:automationSeen = $keptSeen
$null = Save-AutomationRules -Rules @()
$script:deviceWatchTimer.Start()

Say ''
Say '== start with Windows =='
$ui.AutomationStartup.IsChecked = $true
$ui.AutomationStartNova.IsChecked = $true
Set-AutomationPageStartup
$value = "$((Get-ItemProperty -LiteralPath $script:automationRunKey -Name 'AndroidDC' -ErrorAction SilentlyContinue).AndroidDC)"
Say ("  on, Nova: '{0}'   {1}" -f $value, (Mark ($value -match '\\androiddc-nova\.vbs" -Minimized$')))
$ui.AutomationStartClassic.IsChecked = $true
Say ("  classic picked: the entry follows   {0}" -f (Mark ((Get-AutomationStartup) -eq 'classic')))
$ui.AutomationStartup.IsChecked = $false
Set-AutomationPageStartup
Say ("  off: the value is gone   {0}" -f (Mark ((Get-AutomationStartup) -eq '')))
Remove-Item -LiteralPath 'HKCU:\Software\AndroidDC-tests' -Recurse -Force -ErrorAction SilentlyContinue
Say ("  the real Run key was not touched   {0}" -f (Mark ((Get-RealRunValue) -eq $realBefore)))
Say ("  no dialog is open, so the device watch runs   {0}" -f (Mark (-not (Test-DialogOpen))))

Say ''
Say '== the icon by the clock =='
$handle = (New-Object System.Windows.Interop.WindowInteropHelper($script:window)).Handle
Say ("  there, with Automation, Show, Hide and Exit   {0}" -f (Mark ($null -ne $script:trayIcon -and $script:trayIcon.Visible -and $script:trayIcon.ContextMenuStrip.Items.Count -eq 6)))

Say ''
Say '== the rules set before, seen without opening their page =='
$logText = Get-LogText
Say ("  the log said so at startup   {0}" -f (Mark ($logText -match 'Automation: no rules\. Does not start with Windows\.' -and $logText -match 'set in the Automation page')))
$null = Save-AutomationRules -Rules @(
    [PSCustomObject]@{ Serial = 'F6'; Name = 'Phone F'; Enabled = $true; Actions = @([PSCustomObject]@{ Id = 'usb-tether-on'; Value = '' }) })
Update-TrayMenu
$dropped = @($script:trayRulesItem.DropDownItems | ForEach-Object { $_.Text })
Say ("  the icon's menu: '{0}' - {1}   {2}" -f $script:trayRulesItem.Text, ($dropped -join ' | '),
    (Mark ($script:trayRulesItem.Text -eq 'Automation: 1 rule(s), 1 on' -and @($dropped | Where-Object { $_ -match '^Phone F \(F6\) - on' }).Count -eq 1)))
Say ("  its tooltip: '{0}'   {1}" -f $script:trayIcon.Text, (Mark ($script:trayIcon.Text -eq 'AndroidDC Nova - 1 automation rule(s) on')))
Update-AutomationNavTitle
Say ("  the side navigation: '{0}'   {1}" -f $automationPage.Nav.Content, (Mark ($automationPage.Nav.Content -eq 'Automation (1)')))
Show-Page -Page 'overview'
Open-TrayRules
Wait-Pumped -Milliseconds 400
Say ("  'Open the rules' opens the Automation page   {0}" -f (Mark (Test-PageShown -Key 'automation')))
$script:window.Left = -4000
$script:window.Top = -3000
$null = Save-AutomationRules -Rules @()
Update-AutomationNavTitle
Say ("  no rules: plain again   {0}" -f (Mark ($automationPage.Nav.Content -eq 'Automation')))
$script:trayTold = $true   # no balloon on the user's screen from a test
Hide-TrayWindow
Wait-Pumped -Milliseconds 500
Say ("  hidden: off screen, and the window is still open   {0}" -f (Mark ((Test-TrayHidden) -and -not [AndroidDcTrayNative]::IsWindowVisible($handle) -and $script:window.IsLoaded)))
Show-TrayWindow
Wait-Pumped -Milliseconds 500
Say ("  shown again   {0}" -f (Mark (-not (Test-TrayHidden) -and [AndroidDcTrayNative]::IsWindowVisible($handle))))
$script:window.WindowState = 'Minimized'
Wait-Pumped -Milliseconds 600
Say ("  minimized goes into the tray   {0}" -f (Mark ((Test-TrayHidden) -and -not [AndroidDcTrayNative]::IsWindowVisible($handle))))
Show-TrayWindow
Wait-Pumped -Milliseconds 600
Say ("  and comes back restored, not minimized   {0}" -f (Mark ($script:window.WindowState -eq 'Normal' -and [AndroidDcTrayNative]::IsWindowVisible($handle))))
$pictureAfter = Save-WindowPicture -Name 'automation-after-tray'
Say ("  it still draws after coming back: {0}   {1}" -f $pictureAfter, (Mark ((Get-Item -LiteralPath $pictureAfter).Length -gt 10000)))
$script:window.Left = -4000
$script:window.Top = -3000
