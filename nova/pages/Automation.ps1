# pages\Automation.ps1 - starting with Windows, and what happens when a given
# phone is plugged in. The rules (%APPDATA%\AndroidDC\automation.json) and the
# start-up entry are shared with the classic window; the work itself is in
# ..\shared\Automation.ps1, which androiddc-nova.ps1 loads before the pages.
# Selecting the rule's phone for the actions is Enter-AutomationDevice in lib\Ui.ps1.

$script:automationRuleRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:automationRules = @()
$script:automationLoading = $false
$script:automationBoxes = @()

$automationPage = Register-Page -Key 'automation' -Title 'Automation' -Glyph 'E945' -Section 'System' -Xaml 'Automation.xaml' `
    -OnShow { Update-AutomationPage } -Refresh { Update-AutomationPage }

$ui.AutomationRules.ItemsSource = $script:automationRuleRows

function Test-AutomationShared {
    # shared\Automation.ps1 was found and loaded
    return [bool](Get-Command Read-AutomationRules -ErrorAction SilentlyContinue)
}

function Update-AutomationPage {
    # the rules as the file has them now, and whether AndroidDC starts with Windows
    if (-not (Test-AutomationShared)) {
        $ui.AutomationHint.Text = 'shared\Automation.ps1 is not in the project folder: no rules and no start with Windows.'
        foreach ($name in @('AutomationStartup', 'AutomationAdd', 'AutomationRun', 'AutomationRemove', 'AutomationEnabled', 'AutomationApp')) {
            $ui[$name].IsEnabled = $false
        }
        return
    }

    $script:automationLoading = $true
    try {
        $keep = if ($null -ne $ui.AutomationRules.SelectedItem) { $ui.AutomationRules.SelectedItem.Serial } else { '' }
        $script:automationRules = @(Read-AutomationRules)
        $problem = Get-AutomationReadError
        if ($problem) { Write-Log "Automation: the rules file could not be read: $problem" $colorBad }

        $script:automationRuleRows.Clear()
        foreach ($rule in $script:automationRules) {
            $row = [PSCustomObject]@{ On = $(if ($rule.Enabled) { 'on' } else { 'off' }); Name = $rule.Name; Serial = $rule.Serial }
            $script:automationRuleRows.Add($row)
            if ($rule.Serial -eq $keep) { $ui.AutomationRules.SelectedItem = $row }
        }
        if ($null -eq $ui.AutomationRules.SelectedItem -and $script:automationRuleRows.Count -gt 0) { $ui.AutomationRules.SelectedIndex = 0 }

        $startup = Get-AutomationStartup
        $ui.AutomationStartup.IsChecked = [bool]$startup
        if ($startup -eq 'classic') { $ui.AutomationStartClassic.IsChecked = $true }
        elseif ($startup -eq 'nova') { $ui.AutomationStartNova.IsChecked = $true }
    } finally {
        $script:automationLoading = $false
    }
    Show-AutomationRule
}

function Get-AutomationSelectedRule {
    $row = $ui.AutomationRules.SelectedItem
    if ($null -eq $row) { return $null }
    return (Get-AutomationRule -Rules $script:automationRules -Serial $row.Serial)
}

function Show-AutomationRule {
    # the selected rule's actions switched on; nothing to switch without a rule
    $was = $script:automationLoading
    $script:automationLoading = $true
    try {
        $rule = Get-AutomationSelectedRule
        $ids = @()
        $app = ''
        if ($rule) {
            foreach ($entry in @($rule.Actions)) {
                $ids += $entry.Id
                if ($entry.Id -eq 'app') { $app = $entry.Value }
            }
        }
        foreach ($box in $script:automationBoxes) {
            $box.IsChecked = ($ids -contains "$($box.Tag)")
            $box.IsEnabled = ($null -ne $rule)
        }
        $ui.AutomationApp.Text = $app
        $ui.AutomationEnabled.IsChecked = ($null -ne $rule -and $rule.Enabled)
        foreach ($name in @('AutomationApp', 'AutomationEnabled', 'AutomationRun', 'AutomationRemove')) {
            $ui[$name].IsEnabled = ($null -ne $rule)
        }
        $ui.AutomationHint.Text = if ($rule) { "$($rule.Name) ($($rule.Serial)): " + (Get-AutomationRuleSummary -Rule $rule) } else {
            'Pick a phone in the device list, then Add the selected phone, and switch on what should happen each time it is plugged in.' }
        $ui.AutomationHint.ToolTip = $ui.AutomationHint.Text
    } finally {
        $script:automationLoading = $was
    }
}

function Save-AutomationPageRule {
    # written at once: the classic window reads the same file
    if ($script:automationLoading) { return }
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }

    $actions = @()
    foreach ($box in $script:automationBoxes) {
        if (-not $box.IsChecked) { continue }
        $id = "$($box.Tag)"
        $actions += [PSCustomObject]@{ Id = $id; Value = $(if ($id -eq 'app') { $ui.AutomationApp.Text.Trim() } else { '' }) }
    }
    $rule.Actions = $actions
    $rule.Enabled = [bool]$ui.AutomationEnabled.IsChecked
    if (-not (Save-AutomationRules -Rules $script:automationRules)) { return }

    $script:automationLoading = $true
    try {
        foreach ($row in $script:automationRuleRows) {
            if ($row.Serial -eq $rule.Serial) { $row.On = $(if ($rule.Enabled) { 'on' } else { 'off' }) }
        }
        # the rows are plain objects: the list only shows the new word when asked again
        $ui.AutomationRules.Items.Refresh()
        $ui.AutomationHint.Text = "$($rule.Name) ($($rule.Serial)): " + (Get-AutomationRuleSummary -Rule $rule)
        $ui.AutomationHint.ToolTip = $ui.AutomationHint.Text
    } finally {
        $script:automationLoading = $false
    }
}

function Add-AutomationPageRule {
    # a rule for the phone picked in the device list, or that phone's rule picked
    if (-not (Test-AutomationShared)) { return }
    $device = Get-SelectedDevice
    if ($null -eq $device) { Write-Log 'Select a device first.' $colorWarn; return }

    $rules = @(Read-AutomationRules)
    $problem = Get-AutomationReadError
    if ($problem) { Write-Log "Automation: the rules file could not be read: $problem" $colorBad; return }
    if (-not (Get-AutomationRule -Rules $rules -Serial $device.Serial)) {
        $name = if ($device.Model) { "$($device.Model)" } else { $device.Serial }
        $rules += [PSCustomObject]@{ Serial = $device.Serial; Name = $name; Enabled = $true; Actions = @() }
        if (-not (Save-AutomationRules -Rules $rules)) { return }
        Write-Log "Automation: a rule for $name ($($device.Serial)). Switch on what should happen when it is plugged in." $colorGood
    }
    Update-AutomationPage
    foreach ($row in $script:automationRuleRows) { if ($row.Serial -eq $device.Serial) { $ui.AutomationRules.SelectedItem = $row } }
}

function Remove-AutomationPageRule {
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }
    $rules = @($script:automationRules | Where-Object { $_.Serial -ne $rule.Serial })
    if (Save-AutomationRules -Rules $rules) { Write-Log "Automation: removed the rule for $($rule.Name)." $colorInfo }
    Update-AutomationPage
}

function Invoke-AutomationPageRule {
    $rule = Get-AutomationSelectedRule
    if (-not $rule) { return }
    if (@($rule.Actions).Count -eq 0) { Write-Log 'Automation: this rule has no actions yet.' $colorWarn; return }
    if ($script:busy -gt 0) { Write-Log 'Wait for the running command to finish.' $colorWarn; return }
    Invoke-AutomationRule -Rule $rule -Enter { param($Serial) Enter-AutomationDevice -Serial $Serial } `
        -Leave { param($State) Exit-AutomationDevice -State $State }
}

function Set-AutomationPageStartup {
    if ($script:automationLoading -or -not (Test-AutomationShared)) { return }
    $window = if (-not $ui.AutomationStartup.IsChecked) { '' } elseif ($ui.AutomationStartClassic.IsChecked) { 'classic' } else { 'nova' }
    if (-not (Set-AutomationStartup -Window $window)) {
        # show what is really there, not what was asked for
        $script:automationLoading = $true
        $ui.AutomationStartup.IsChecked = [bool](Get-AutomationStartup)
        $script:automationLoading = $false
    }
}

# ------------------------------------------------------------------ events ----

if (Test-AutomationShared) {
    # one switch per action, in the order a rule runs them
    foreach ($automationAction in @(Get-AutomationActionList)) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = "$($automationAction.Group): $($automationAction.Label)"
        $box.Tag = $automationAction.Id
        $box.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $box.Add_Click({ Save-AutomationPageRule })
        $null = $ui.AutomationActions.Children.Add($box)
        $script:automationBoxes += $box
    }
}

$ui.AutomationRules.Add_SelectionChanged({ if (-not $script:automationLoading) { Show-AutomationRule } })
$ui.AutomationEnabled.Add_Click({ Save-AutomationPageRule })
$ui.AutomationApp.Add_TextChanged({ Save-AutomationPageRule })
$ui.AutomationAdd.Add_Click({ Add-AutomationPageRule })
$ui.AutomationRun.Add_Click({ Invoke-AutomationPageRule })
$ui.AutomationRemove.Add_Click({ Remove-AutomationPageRule })
$ui.AutomationStartup.Add_Click({ Set-AutomationPageStartup })
$ui.AutomationStartClassic.Add_Checked({ if ($ui.AutomationStartup.IsChecked) { Set-AutomationPageStartup } })
$ui.AutomationStartNova.Add_Checked({ if ($ui.AutomationStartup.IsChecked) { Set-AutomationPageStartup } })
