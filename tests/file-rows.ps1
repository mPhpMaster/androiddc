# Files page, no phone: search hits keep the file's own name (the path under
# the search root is only what is shown), the filter box takes [ ] literally,
# and Compress builds a tar command that finds what it packs, from one
# folder or from several. Nothing reaches a phone: the few functions that
# would are replaced inside this test, and PowerShell looks a function up
# from the caller outward, so the page's own code calls these instead.

$script:sent = @()
function Get-TargetSerial { 'TEST' }
function Invoke-DeviceShell { param([string]$Serial, [string[]]$CommandArguments)
    $script:sent += , @($CommandArguments)
    [PSCustomObject]@{ ExitCode = 0; Lines = @(); Text = '' } }
function Get-DeviceFileSize { param([string]$Serial, [string]$Path) 1024 }
function Update-FileList { param([string]$Path) }

$tabs.SelectedTab = $tabFiles
Wait-Pumped -Milliseconds 400

$ls = @(
    '-rw-rw---- 1 u0_a1 media_rw 2048 2026-09-10 10:00 /sdcard/DCIM/Camera/IMG_1.jpg',
    '-rw-rw---- 1 u0_a1 media_rw 4096 2026-09-10 11:00 /sdcard/Download/IMG [1].jpg',
    'drwxrwx--- 2 u0_a1 media_rw 3452 2026-09-10 12:00 /sdcard/Download/sub dir'
) -join "`n"

Say '== a search hit keeps its own name =='
$rows = @(ConvertFrom-LsOutput -Text $ls -Root '/sdcard')
$hit = $rows[0]
Say ("Name {0}, shown as {1}   {2}" -f $hit.Name, $hit.Label,
    (Mark ($hit.Name -eq 'IMG_1.jpg' -and $hit.Label -eq 'DCIM/Camera/IMG_1.jpg' -and $hit.Path -eq '/sdcard/DCIM/Camera/IMG_1.jpg')))

$script:fileRows = $rows
$script:fileSearchResults = $true
$txtFileSearch.Text = ''
Show-FileRows
$item = @($lstFiles.Items | Where-Object { $_.Tag.Path -eq $hit.Path })[0]
Say ("the list shows the path under the root   {0}" -f (Mark ($item -and $item.Text -eq 'DCIM/Camera/IMG_1.jpg')))
$lstFiles.SelectedItems.Clear()
$item.Selected = $true
$picked = @(Get-SelectedFiles)[0]
# adb pull into a folder writes <folder>\<file name>: that is where Move to PC
# looks for the copy before it deletes the phone's
$local = Join-Path $TestOutput $picked.Name
Say ("Move to PC checks {0}   {1}" -f $local, (Mark ($local -eq (Join-Path $TestOutput 'IMG_1.jpg'))))

Say ''
Say '== the filter box takes brackets as they are typed =='
$script:fileSearchResults = $false
$txtFileSearch.Text = '[1]'
Show-FileRows
$shown = @($lstFiles.Items | ForEach-Object { $_.Text })
Say ("'[1]' finds 'Download/IMG [1].jpg' and nothing else   {0}" -f (Mark ($shown.Count -eq 1 -and $shown[0] -eq 'Download/IMG [1].jpg')))
$failed = $false
try { $txtFileSearch.Text = '['; Show-FileRows } catch { $failed = $true }
Say ("a lone '[' is just a character   {0}" -f (Mark (-not $failed -and $lstFiles.Items.Count -eq 1)))
$txtFileSearch.Text = ''
Show-FileRows

Say ''
Say '== Compress: one folder =='
$script:fileSearchResults = $true
Show-FileRows
$lstFiles.SelectedItems.Clear()
foreach ($it in $lstFiles.Items) { if ($it.Tag.Path -like '/sdcard/Download/*') { $it.Selected = $true } }
$script:sent = @()
Compress-DeviceFiles -ArchiveName 'pack'
$tar = @($script:sent | Where-Object { $_[0] -eq 'tar' })[0]
# in the list's order: folders come first
$entries = @($lstFiles.SelectedItems | ForEach-Object { "'" + $_.Tag.Name + "'" })
$want = @('tar', '-czf', "'/sdcard/Download/pack.tar.gz'", '-C', "'/sdcard/Download'") + $entries
Say ("  by name: {0}   {1}" -f ($entries -join ' '), (Mark (($entries -join ' ') -in @("'sub dir' 'IMG [1].jpg'", "'IMG [1].jpg' 'sub dir'"))))
Say ("  {0}   {1}" -f ($tar -join ' '), (Mark ($tar -and (($tar -join '|') -eq ($want -join '|')))))

Say ''
Say '== Compress: hits from two folders =='
foreach ($it in $lstFiles.Items) { $it.Selected = $true }
$script:sent = @()
Compress-DeviceFiles -ArchiveName 'pack'
$tar = @($script:sent | Where-Object { $_[0] -eq 'tar' })[0]
$first = $lstFiles.SelectedItems[0].Tag.Path
$entries = @($lstFiles.SelectedItems | ForEach-Object { "'" + $_.Tag.Path.TrimStart('/') + "'" })
$want = @('tar', '-czf', ("'" + (Split-DevicePath -Path $first) + "/pack.tar.gz'"), '-C', "'/'") + $entries
Say ("  {0}   {1}" -f ($tar -join ' '), (Mark ($tar -and (($tar -join '|') -eq ($want -join '|')))))
