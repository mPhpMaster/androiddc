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
        foreach ($inner in @($tabsTethering, $tabsAdvanced, $tabsShell)) {
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

Say ("== default size {0} x {1} ==" -f $form.Width, $form.Height)
$first = Invoke-LayoutAudit
Say ("{0} containers: {1} overlaps, {2} outside   {3}" -f $first[0], $first[1], $first[2], (Mark ($first[1] -eq 0 -and $first[2] -eq 0)))

$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 800
Say ''
Say ("== minimum size {0} x {1} ==" -f $form.Width, $form.Height)
$second = Invoke-LayoutAudit
Say ("{0} containers: {1} overlaps, {2} outside   {3}" -f $second[0], $second[1], $second[2], (Mark ($second[1] -eq 0 -and $second[2] -eq 0)))
