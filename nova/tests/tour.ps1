# Every page and every inner tab with the whole program loaded: each one opens
# without an error in the log, nothing sticks out on the right, and a picture
# of each is saved at the default and the smallest size. Opening a page only
# reads from the phone.

$expected = @('overview', 'screen', 'mirroring', 'apps', 'files', 'media', 'messages', 'contacts',
    'tethering', 'radios', 'tools', 'running', 'users', 'shell')
$loaded = @($script:pages | ForEach-Object { $_.Key })
$missing = @($expected | Where-Object { $loaded -notcontains $_ })
Say ("{0} page(s) loaded: {1}   {2}" -f $loaded.Count, ($loaded -join ', '), (Mark ($missing.Count -eq 0)))
foreach ($key in $missing) { Say "  FAIL missing page: $key" }

$null = Wait-Idle -Seconds 40

function Get-InnerTabs {
    # the TabControls inside a page, found through the visual tree
    param($Root)
    $found = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if ($node -is [System.Windows.Controls.TabControl]) { $found += $node; continue }
        if ($node -is [System.Windows.DependencyObject]) {
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
                if ($child -is [System.Windows.DependencyObject]) { $queue.Enqueue($child) }
            }
        }
    }
    return $found
}

foreach ($size in @('default', 'min')) {
    Say ''
    Say "== $size size =="
    Set-WindowSize $size
    foreach ($page in @(Get-PagesInNavOrder)) {
        $before = $script:logLines.Count
        Show-Page -Page $page
        $null = Wait-Idle -Seconds 60
        $tabs = @(Get-InnerTabs -Root $page.Root)
        $views = if ($tabs.Count -gt 0) { @(0..($tabs[0].Items.Count - 1)) } else { @(-1) }
        foreach ($index in $views) {
            $label = $page.Key
            if ($index -ge 0) {
                $tabs[0].SelectedIndex = $index
                $null = Wait-Idle -Seconds 60
                $label = "$($page.Key)-$index"
            }
            $null = Save-WindowPicture "tour-$size-$label"
            $outside = @(Get-OutsideElements -Root $page.Root)
            foreach ($line in $outside) { Say "    $line" }
            Say ("  {0,-14} nothing sticks out   {1}" -f $label, (Mark ($outside.Count -eq 0)))
        }
        # an exception inside a page's OnShow is logged as "<Title>: <message>" in red
        $errors = @(@($script:logLines) | Select-Object -Skip $before | Where-Object {
            $_.Kind -eq 'bad' -and $_.Text -like "$($page.Title):*" })
        foreach ($line in $errors) { Say "    $($line.Text)" }
        Say ("  {0,-14} opened without an error   {1}" -f $page.Key, (Mark ($errors.Count -eq 0)))
    }
}
Show-Page -Page 'overview'
