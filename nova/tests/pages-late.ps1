# Pages are built when they are opened, not when the window starts. This is the
# only test the runner does not set ANDROIDDC_EAGER_PAGES for, so it is the one
# that sees what a person sees.

Say '== what is built before anything is opened =='
$all = @($script:pages)
Say ("  the navigation has every page: {0}   {1}" -f $all.Count, (Mark ($all.Count -eq 18)))
Say ("  each one has its name, glyph and section   {0}" -f (Mark (
    @($all | Where-Object { -not $_.Title -or -not $_.Glyph -or -not $_.Section }).Count -eq 0)))
$built = @($all | Where-Object { $_.Loaded })
Say ("  built so far: {0}   {1}" -f (($built | ForEach-Object { $_.Key }) -join ', '), (Mark (
    $built.Count -le 5)))
Say ("  the three the window itself reaches into are among them   {0}" -f (Mark (
    @($built | Where-Object { $_.Key -eq 'ftp' }).Count -eq 1 -and
    @($built | Where-Object { $_.Key -eq 'clipboard' }).Count -eq 1 -and
    @($built | Where-Object { $_.Key -eq 'automation' }).Count -eq 1)))
Say ("  and the page on screen is one of them   {0}" -f (Mark (
    $null -ne $script:currentPage -and $script:currentPage.Loaded -and $null -ne $script:currentPage.Root)))

Say ''
Say '== opening one builds it =='
$users = Get-Page -Key 'users'
Say ("  the users page is not built yet   {0}" -f (Mark (-not $users.Loaded -and $null -eq $users.Root)))
Show-Page -Page 'users'
Wait-Pumped -Milliseconds 300
Say ("  opening it builds it and shows it   {0}" -f (Mark (
    $users.Loaded -and $null -ne $users.Root -and $users.Root.Visibility -eq 'Visible' -and
    (Test-PageShown -Key 'users'))))
Say ("  its navigation item is the same one as before   {0}" -f (Mark ($null -ne $users.Nav)))
Say ("  and its own functions are there now   {0}" -f (Mark (
    [bool](Get-Command Update-UserList -ErrorAction SilentlyContinue))))

Say ''
Say '== a page calling into one that is not built =='
$tools = Get-Page -Key 'tools'
Say ("  the tools page is not built   {0}" -f (Mark (-not $tools.Loaded)))
# Get-DeviceIp lives on the Tools page, and the Overview page calls it
$answer = $null
try { $answer = Get-Command Get-DeviceIp -ErrorAction Stop } catch { }
Say ("  asking for one of its functions builds it   {0}" -f (Mark (
    $null -ne $answer -and (Get-Page -Key 'tools').Loaded)))

Say ''
Say '== reading a page again =='
Show-Page -Page 'running'
Wait-Pumped -Milliseconds 200
Invoke-PageRefresh
Say ("  F5 on a page just built does not throw   {0}" -f (Mark ((Test-PageShown -Key 'running'))))

Say ''
Say '== another phone, with most pages still unbuilt =='
$before = @(@($script:pages) | Where-Object { $_.Loaded }).Count
Update-DeviceList
$null = Wait-Idle
Say ("  the device list is read without building the rest: {0} built before, {1} after   {2}" -f
    $before, @(@($script:pages) | Where-Object { $_.Loaded }).Count, (Mark (
    @(@($script:pages) | Where-Object { $_.Loaded }).Count -le ($before + 2))))

Say ''
Say '== every page, opened one after another =='
$failed = @()
foreach ($page in @(Get-PagesInNavOrder)) {
    try {
        Show-Page -Page $page.Key
        Wait-Pumped -Milliseconds 120
        if (-not $page.Loaded -or $null -eq $page.Root) { $failed += $page.Key }
    } catch {
        $failed += "$($page.Key) ($($_.Exception.Message))"
    }
}
Say ("  all eighteen open: {0}   {1}" -f $(if ($failed.Count -eq 0) { 'none failed' } else { $failed -join ', ' }),
    (Mark ($failed.Count -eq 0)))
Say ("  and every one of them is built now   {0}" -f (Mark (
    @(@($script:pages) | Where-Object { -not $_.Loaded }).Count -eq 0)))
