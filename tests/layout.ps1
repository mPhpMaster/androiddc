# Every control inside its box and none on top of another, on every page, at
# the default window size and at the smallest the window allows.
#
# Measures Bounds on every child with no Visible filter: a control on a page
# that is not on screen reports Visible = false, and filtering on it once hid
# most of the window from this audit.

if ($TestSerial) { Select-TestPhone }

# Controls that share one slot on purpose and are shown one at a time.
# The leading comma stops @() flattening the inner list into loose controls.
$sharedSlots = @(
    ,@($lblFileSpace, $prgFile, $lblFileProgress, $btnFileCancel)
)

function Test-SharedSlot {
    param($First, $Second)
    foreach ($slot in $sharedSlots) {
        $hasFirst = $false
        $hasSecond = $false
        foreach ($control in $slot) {
            if ($control -eq $First) { $hasFirst = $true }
            if ($control -eq $Second) { $hasSecond = $true }
        }
        if ($hasFirst -and $hasSecond) { return $true }
    }
    return $false
}

function Invoke-LayoutAudit {
    # every page shown once, or its layout function has never run on a real size
    foreach ($page in $tabs.TabPages) {
        $tabs.SelectedTab = $page
        Wait-Pumped -Milliseconds 240
        foreach ($inner in @($tabsTethering, $tabsAdvanced, $tabsRadios, $tabsShell)) {
            if ($inner.Parent -eq $page) {
                foreach ($sub in $inner.TabPages) { $inner.SelectedTab = $sub; Wait-Pumped -Milliseconds 200 }
            }
        }
    }
    $tabs.SelectedTab = $tabs.TabPages[0]
    Wait-Pumped -Milliseconds 300

    $containers = New-Object System.Collections.Generic.List[object]
    function Add-Containers {
        param($Parent, [string]$Path)
        foreach ($child in $Parent.Controls) {
            $label = if ($child.Text) { $child.Text } else { $child.GetType().Name }
            if ($label.Length -gt 28) { $label = $label.Substring(0, 28) }
            $here = "$Path/$label"
            if ($child -is [System.Windows.Forms.GroupBox] -or $child -is [System.Windows.Forms.TabPage] -or
                $child -is [System.Windows.Forms.Panel] -or $child -is [System.Windows.Forms.SplitterPanel]) {
                $containers.Add(@($here, $child))
            }
            if ($child.Controls.Count -gt 0) { Add-Containers -Parent $child -Path $here }
        }
    }
    Add-Containers -Parent $form -Path ''

    $overlaps = 0
    $outside = 0
    foreach ($entry in $containers) {
        $path = $entry[0]
        $box = $entry[1]
        $kids = @($box.Controls)
        for ($i = 0; $i -lt $kids.Count; $i++) {
            for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                # a docked control legitimately covers the whole client area
                if ($kids[$i].Dock -ne 'None' -or $kids[$j].Dock -ne 'None') { continue }
                if ($kids[$i].Bounds.IntersectsWith($kids[$j].Bounds) -and -not (Test-SharedSlot $kids[$i] $kids[$j])) {
                    $overlaps++
                    Say ("  FAIL overlap {0}: '{1}' {2} vs '{3}' {4}" -f $path, $kids[$i].Text, $kids[$i].Bounds, $kids[$j].Text, $kids[$j].Bounds)
                }
            }
        }
        foreach ($child in $kids) {
            if ($child.Dock -ne 'None') { continue }
            # a page that scrolls may be taller than its viewport, never wider.
            # Not every container has AutoScroll, and StrictMode throws on a
            # property that is not there.
            $scrolls = $false
            if ($box.PSObject.Properties['AutoScroll']) { $scrolls = [bool]$box.AutoScroll }
            $tooWide = $child.Bounds.Right -gt $box.ClientSize.Width
            $tooTall = (-not $scrolls) -and ($child.Bounds.Bottom -gt $box.ClientSize.Height)
            if ($tooWide -or $tooTall -or $child.Bounds.X -lt 0 -or $child.Bounds.Y -lt 0) {
                $outside++
                Say ("  FAIL outside {0}: '{1}' {2} (box {3} x {4})" -f $path, $child.Text, $child.Bounds,
                    $box.ClientSize.Width, $box.ClientSize.Height)
            }
        }
    }
    return @($containers.Count, $overlaps, $outside)
}

function Test-Fits {
    # what the overlap audit cannot see: a tab strip that scrolls hides whole
    # pages, and a list can be inside its box yet too short to show a row
    # every check says FAIL with the reason if it throws: without this, an
    # error here was swallowed and its lines were simply missing from the report
    foreach ($strip in @($tabs, $tabsTethering, $tabsAdvanced, $tabsRadios, $tabsShell)) {
        try {
            $last = $strip.GetTabRect($strip.TabCount - 1)
            Say ("  tabs from '{0}': the last ends at {1} of {2}   {3}" -f $strip.TabPages[0].Text, $last.Right,
                $strip.ClientSize.Width, (Mark ($last.Right -le $strip.ClientSize.Width)))
        } catch {
            Say ("  FAIL tabs from '{0}': {1}" -f $strip.TabPages[0].Text, $_.Exception.Message)
        }
    }

    try {
        $columns = 0
        foreach ($column in $lstDevices.Columns) { $columns += $column.Width }
        Say ("  device columns {0} px in a list {1} px wide   {2}" -f $columns, $lstDevices.ClientSize.Width,
            (Mark ($columns -le $lstDevices.ClientSize.Width)))
        Say ("  device status line {0} px tall (one line)   {1}" -f $lblDeviceStatus.Height, (Mark ($lblDeviceStatus.Height -le 22)))
    } catch {
        Say ("  FAIL device list checks: {0}" -f $_.Exception.Message)
    }

    try {
        $tabs.SelectedTab = $tabFiles
        Wait-Pumped -Milliseconds 300
        # a header and six rows of 17 px
        Say ("  Files list {0} px tall   {1}" -f $lstFiles.ClientSize.Height, (Mark ($lstFiles.ClientSize.Height -ge 126)))
    } catch {
        Say ("  FAIL Files list check: {0}" -f $_.Exception.Message)
    }

    $before = $tabs.Height
    Switch-LogPane
    Wait-Pumped -Milliseconds 300
    Say ("  log folded: pages {0} -> {1} px, log hidden {2}   {3}" -f $before, $tabs.Height, (-not $txtLog.Visible),
        (Mark ($tabs.Height -ge ($before + 60) -and -not $txtLog.Visible)))
    $folded = Invoke-LayoutAudit
    $tabs.SelectedTab = $tabFiles
    Say ("  folded: {0} overlaps, {1} outside   {2}" -f $folded[1], $folded[2], (Mark ($folded[1] -eq 0 -and $folded[2] -eq 0)))
    Switch-LogPane
    Wait-Pumped -Milliseconds 300
    Say ("  unfolded again: pages {0} px, log shown {1}   {2}" -f $tabs.Height, $txtLog.Visible,
        (Mark ($tabs.Height -eq $before -and $txtLog.Visible)))

    # dragged as far as it goes, the pages still keep their share
    $script:logHeight = 5000
    Update-RightLayout
    Say ("  log dragged to 5000: log {0} px, pages {1} px   {2}" -f $txtLog.Height, $tabs.Height, (Mark ($tabs.Height -ge 300)))
    $script:logHeight = 150
    Update-RightLayout
    Say ("  log dragged to 150: log {0} px   {1}" -f $txtLog.Height, (Mark ($txtLog.Height -eq 150)))
    $script:logHeight = 0
    Update-RightLayout
    $tabs.SelectedTab = $tabs.TabPages[0]
    Wait-Pumped -Milliseconds 300
}

Say ("== default size {0} x {1} ==" -f $form.Width, $form.Height)
$first = Invoke-LayoutAudit
Say ("{0} containers: {1} overlaps, {2} outside   {3}" -f $first[0], $first[1], $first[2], (Mark ($first[1] -eq 0 -and $first[2] -eq 0)))
Test-Fits

$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 800
Say ''
Say ("== minimum size {0} x {1} ==" -f $form.Width, $form.Height)
$second = Invoke-LayoutAudit
Say ("{0} containers: {1} overlaps, {2} outside   {3}" -f $second[0], $second[1], $second[2], (Mark ($second[1] -eq 0 -and $second[2] -eq 0)))
Test-Fits
