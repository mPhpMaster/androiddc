# The Files page. With a phone attached it reads a folder, the volumes and the
# space line, walks up and back through the history - ls and df only. Then,
# with no phone at all: search hits keep the file's own name (the path under
# the search root is only what is shown), the filter box takes [ ] literally,
# and Compress, Extract, Rename, Search and Recent files build the commands
# they should. Those run inside a script block whose own Get-TargetSerial and
# Invoke-DeviceShell replace the real ones - PowerShell looks a function up
# from the caller outward - so nothing reaches a phone. Last, the pictures at
# both sizes, the transfer row and the preview window.

Say '== the page opens =='
$null = Wait-Idle -Seconds 30
Show-Page -Page 'files'
$idle = Wait-Idle -Seconds 60
Say ("  shown and idle   {0}" -f (Mark ((Test-PageShown -Key 'files') -and $idle)))
$names = @('FilesUp', 'FilesPath', 'FilesGo', 'FilesQuick', 'FilesHidden', 'FilesFoldersFirst', 'FilesInfo', 'FilesSearch',
    'FilesSearchHere', 'FilesSearchClear', 'FilesRecent', 'FilesRecentWindow', 'FilesLocal', 'FilesLocalBrowse', 'FilesOpenLocal',
    'FilesList', 'FilesSelectAll', 'FilesSelectNone', 'FilesSelectInvert', 'FilesSpace', 'FilesTransfer', 'FilesProgress',
    'FilesProgressText', 'FilesCancel', 'FilesDownload', 'FilesMoveToPc', 'FilesUpload', 'FilesMoveToPhone', 'FilesNewDir',
    'FilesRename', 'FilesDelete', 'FilesCompress', 'FilesExtract', 'FilesPreview', 'FilesOpenPhone', 'FilesCopyPath')
$missing = @($names | Where-Object { -not $ui.ContainsKey($_) })
Say ("  every control is there ({0} missing)   {1}" -f $missing.Count, (Mark ($missing.Count -eq 0)))
$menu = @($ui.FilesList.ContextMenu.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] } | ForEach-Object { "$($_.Header)" })
Say ("  right-click menu: {0}   {1}" -f ($menu -join ' / '), (Mark ($menu.Count -eq 12)))
$recent = @($ui.FilesRecentWindow.Items | ForEach-Object { "$($_.Content)" }) -join ','
Say ("  recent window choices: {0}   {1}" -f $recent, (Mark ($recent -eq 'today,last 2 days,last week,last 30 days')))

$phone = @($script:deviceRows | Where-Object { $_.State -eq 'device' }) | Select-Object -First 1
Say ''
Say '== reading a phone (ls, df, sm list-volumes) =='
if ($null -eq $phone) {
    Say '  no phone attached - the reads are skipped'
} else {
    Say ("  /sdcard listed: {0} row(s), '{1}'   {2}" -f $script:fileItems.Count, $ui.FilesInfo.Text,
        (Mark ($script:filePath -eq '/sdcard' -and $script:fileItems.Count -gt 0)))
    Say ("  space line: {0}   {1}" -f $ui.FilesSpace.Text, (Mark ($ui.FilesSpace.Text -like 'space here: * used of *volume *')))
    $volumes = @($ui.FilesQuick.Items | Where-Object { "$_" -like '/storage/*' })
    Say ("  jump list has the volumes: {0}   {1}" -f ($volumes -join ', '), (Mark ($volumes.Count -ge 1)))
    $firstRows = @($script:fileItems | Select-Object -First 3)
    $dirsFirst = @($script:fileItems | ForEach-Object { $_.Tag.IsDirectory })
    $lastDir = [array]::LastIndexOf([object[]]$dirsFirst, $true)
    $firstFile = [array]::IndexOf([object[]]$dirsFirst, $false)
    Say ("  folders first   {0}" -f (Mark ($firstFile -lt 0 -or $lastDir -lt $firstFile)))

    $folder = @($script:fileItems | Where-Object { $_.Tag.IsDirectory -and -not $_.Tag.Name.StartsWith('.') }) | Select-Object -First 1
    if ($folder) {
        Update-FileList -Path $folder.Tag.Path
        Say ("  into {0}   {1}" -f $folder.Tag.Path, (Mark ($script:filePath -eq $folder.Tag.Path -and $ui.FilesPath.Text -eq $folder.Tag.Path)))
        $handled = Invoke-FilesListKey -Key ([System.Windows.Input.Key]::Back) -Modifiers ([System.Windows.Input.ModifierKeys]::None)
        Say ("  Backspace goes up to {0}   {1}" -f $script:filePath, (Mark ($handled -and $script:filePath -eq '/sdcard')))
        $handled = Invoke-FilesListKey -Key ([System.Windows.Input.Key]::Left) -Modifiers ([System.Windows.Input.ModifierKeys]::Alt)
        Say ("  Alt+Left goes back to {0}   {1}" -f $script:filePath, (Mark ($handled -and $script:filePath -eq $folder.Tag.Path)))
        $handled = Invoke-FilesListKey -Key ([System.Windows.Input.Key]::Right) -Modifiers ([System.Windows.Input.ModifierKeys]::Alt)
        Say ("  Alt+Right forward to {0}   {1}" -f $script:filePath, (Mark ($handled -and $script:filePath -eq '/sdcard')))
    }
    Update-FileList -Path '/sdcard/NoSuchFolderHere-nova-test'
    Say ("  a missing folder leaves the list where it was   {0}" -f (Mark ($script:filePath -eq '/sdcard')))

    Set-FileSelection -Mode all
    $all = $ui.FilesList.SelectedItems.Count
    Set-FileSelection -Mode none
    $none = $ui.FilesList.SelectedItems.Count
    $null = $ui.FilesList.SelectedItems.Add($script:fileItems[0])
    Set-FileSelection -Mode invert
    Say ("  select all {0}, none {1}, invert one {2} of {3}   {4}" -f $all, $none, $ui.FilesList.SelectedItems.Count, $script:fileItems.Count,
        (Mark ($all -eq $script:fileItems.Count -and $none -eq 0 -and $ui.FilesList.SelectedItems.Count -eq ($script:fileItems.Count - 1))))
    $handled = Invoke-FilesListKey -Key ([System.Windows.Input.Key]::Escape) -Modifiers ([System.Windows.Input.ModifierKeys]::None)
    Say ("  Esc clears the selection   {0}" -f (Mark ($handled -and $ui.FilesList.SelectedItems.Count -eq 0)))

    $before = $script:fileItems.Count
    Set-FilesSortColumn -Column 2
    $sizes = @($script:fileItems | Where-Object { -not $_.Tag.IsDirectory } | ForEach-Object { $_.Tag.Size })
    $sorted = @($sizes | Sort-Object -Descending)
    Say ("  sorting by size puts the biggest first, header '{0}'   {1}" -f $ui.FilesList.View.Columns[2].Header,
        (Mark ((($sizes -join ',') -eq ($sorted -join ',')) -and $script:fileItems.Count -eq $before)))
    Set-FilesSortColumn -Column 0
}

Say ''
Say '== no phone from here: the rows and the commands =='
$savedRows = $script:fileRows
$savedSearch = $script:fileSearchResults
& {
    $script:filesSent = @()
    function Get-TargetSerial { 'NOVA-TEST' }
    function Invoke-DeviceShell { param([string]$Serial, [string[]]$CommandArguments)
        $script:filesSent += , @($CommandArguments)
        [PSCustomObject]@{ ExitCode = 0; Lines = @(); Text = '' } }
    function Invoke-DeviceShellText { param([string]$Serial, [string]$Command)
        $script:filesSent += , @($Command)
        [PSCustomObject]@{ ExitCode = 0; Lines = @(); Text = $script:filesLs } }
    function Invoke-Adb { param([string[]]$CommandArguments, [int]$TimeoutMs)
        $script:filesSent += , @($CommandArguments)
        [PSCustomObject]@{ ExitCode = 1; Lines = @('mocked'); Text = 'mocked' } }
    function Get-DeviceFileSize { param([string]$Serial, [string]$Path) 1024 }
    function Update-FileList { param([string]$Path) }

    $script:filesLs = @(
        '-rw-rw---- 1 u0_a1 media_rw 2048 2026-09-10 10:00 /sdcard/DCIM/Camera/IMG_1.jpg',
        '-rw-rw---- 1 u0_a1 media_rw 4096 2026-09-10 11:00 /sdcard/Download/IMG [1].jpg',
        'drwxrwx--- 2 u0_a1 media_rw 3452 2026-09-10 12:00 /sdcard/Download/sub dir',
        '-rw-rw---- 1 u0_a1 media_rw 9000 2026-09-10 13:00 /sdcard/Download/old logs.tar.gz',
        '-rw-rw---- 1 u0_a1 media_rw 900 2026-09-10 14:00 /sdcard/Download/notes.txt.gz'
    ) -join "`n"

    Say '  -- a search hit keeps its own name'
    $rows = @(ConvertFrom-LsOutput -Text $script:filesLs -Root '/sdcard')
    $hit = $rows[0]
    Say ("  Name {0}, shown as {1}   {2}" -f $hit.Name, $hit.Label,
        (Mark ($hit.Name -eq 'IMG_1.jpg' -and $hit.Label -eq 'DCIM/Camera/IMG_1.jpg' -and $hit.Path -eq '/sdcard/DCIM/Camera/IMG_1.jpg')))
    Say ("  a folder hit is a folder, a file has its type   {0}" -f (Mark ($rows[2].IsDirectory -and $rows[2].Extension -eq '' -and $hit.Extension -eq 'JPG')))

    $script:fileRows = $rows
    $script:fileSearchResults = $true
    $ui.FilesSearch.Text = ''
    Show-FileRows
    $item = @($script:fileItems | Where-Object { $_.Tag.Path -eq $hit.Path })[0]
    Say ("  the list shows the path under the root   {0}" -f (Mark ($item -and $item.Label -eq 'DCIM/Camera/IMG_1.jpg')))
    $ui.FilesList.UnselectAll()
    $null = $ui.FilesList.SelectedItems.Add($item)
    $picked = @(Get-SelectedFiles)[0]
    # adb pull into a folder writes <folder>\<file name>: that is where Move to PC
    # looks for the copy before it deletes the phone's
    $local = Join-Path $TestOut $picked.Name
    Say ("  Move to PC checks ...\{0}   {1}" -f (Split-Path -Leaf $local), (Mark ($local -eq (Join-Path $TestOut 'IMG_1.jpg'))))

    Say '  -- the filter box takes brackets as they are typed'
    $script:fileSearchResults = $false
    $ui.FilesSearch.Text = '[1]'
    Show-FileRows
    $shown = @($script:fileItems | ForEach-Object { $_.Label })
    Say ("  '[1]' finds 'Download/IMG [1].jpg' and nothing else   {0}" -f (Mark ($shown.Count -eq 1 -and $shown[0] -eq 'Download/IMG [1].jpg')))
    $failed = $false
    try { $ui.FilesSearch.Text = '['; Show-FileRows } catch { $failed = $true }
    Say ("  a lone '[' is just a character   {0}" -f (Mark (-not $failed -and $script:fileItems.Count -eq 1)))
    $ui.FilesSearch.Text = ''
    Show-FileRows

    Say '  -- Compress: one folder'
    $script:fileSearchResults = $true
    Show-FileRows
    $ui.FilesList.UnselectAll()
    # clicked in the opposite order to the list: the command still follows the list
    foreach ($it in @($script:fileItems)[($script:fileItems.Count - 1)..0]) {
        if ($it.Tag.Path -like '/sdcard/Download/*' -and $it.Tag.Name -notlike '*.gz') { $null = $ui.FilesList.SelectedItems.Add($it) }
    }
    $script:filesSent = @()
    Compress-DeviceFiles -ArchiveName 'pack'
    $tar = @($script:filesSent | Where-Object { $_[0] -eq 'tar' }) | Select-Object -First 1
    $entries = @(Get-SelectedFiles | ForEach-Object { "'" + $_.Name + "'" })
    $want = @('tar', '-czf', "'/sdcard/Download/pack.tar.gz'", '-C', "'/sdcard/Download'") + $entries
    # folders come first in the list
    Say ("  by name, in the list's order: {0}   {1}" -f ($entries -join ' '), (Mark (($entries -join ' ') -eq "'sub dir' 'IMG [1].jpg'")))
    Say ("  {0}   {1}" -f ($tar -join ' '), (Mark ($tar -and (($tar -join '|') -eq ($want -join '|')))))

    Say '  -- Compress: hits from two folders'
    $ui.FilesList.SelectAll()
    $script:filesSent = @()
    Compress-DeviceFiles -ArchiveName 'pack.tgz'
    $tar = @($script:filesSent | Where-Object { $_[0] -eq 'tar' }) | Select-Object -First 1
    $selected = @(Get-SelectedFiles)
    $entries = @($selected | ForEach-Object { "'" + $_.Path.TrimStart('/') + "'" })
    $want = @('tar', '-czf', ("'" + (Split-DevicePath -Path $selected[0].Path) + "/pack.tgz'"), '-C', "'/'") + $entries
    Say ("  {0}   {1}" -f ($tar -join ' '), (Mark ($tar -and (($tar -join '|') -eq ($want -join '|')))))

    Say '  -- Extract'
    foreach ($case in @(
            @('old logs.tar.gz', "tar|-xzf|'/sdcard/Download/old logs.tar.gz'|-C|'/sdcard/Unpacked'"),
            @('notes.txt.gz', "gzip|-dc|'/sdcard/Download/notes.txt.gz'|>|'/sdcard/Unpacked/notes.txt'"))) {
        $ui.FilesList.UnselectAll()
        $null = $ui.FilesList.SelectedItems.Add(@($script:fileItems | Where-Object { $_.Tag.Name -eq $case[0] })[0])
        $script:filesSent = @()
        Expand-DeviceArchive -Into '/sdcard/Unpacked'
        $mkdir = @($script:filesSent | Where-Object { $_[0] -eq 'mkdir' }) | Select-Object -First 1
        $run = @($script:filesSent | Where-Object { $_[0] -ne 'mkdir' }) | Select-Object -First 1
        Say ("  {0}: {1}   {2}" -f $case[0], ($run -join ' '),
            (Mark ($run -and ($run -join '|') -eq $case[1] -and $mkdir -and ($mkdir -join '|') -eq "mkdir|-p|'/sdcard/Unpacked'")))
    }
    # the rows were drawn again since: pick the picture's row as it is now
    $item = @($script:fileItems | Where-Object { $_.Tag.Path -eq $hit.Path }) | Select-Object -First 1
    $ui.FilesList.UnselectAll()
    $null = $ui.FilesList.SelectedItems.Add($item)
    $script:filesSent = @()
    Expand-DeviceArchive -Into '/sdcard/Unpacked'
    Say ("  the picture is picked ({0} row)   {1}" -f $ui.FilesList.SelectedItems.Count, (Mark ($ui.FilesList.SelectedItems.Count -eq 1)))
    Say ("  a picture is not unpacked, and no folder is made for it   {0}" -f (Mark ($script:filesSent.Count -eq 0)))

    Say '  -- Rename a search hit, in its own folder'
    $script:filesSent = @()
    Rename-DeviceFile -NewName 'IMG_2.jpg'
    $mv = @($script:filesSent | Where-Object { $_[0] -eq 'mv' }) | Select-Object -First 1
    Say ("  {0}   {1}" -f ($mv -join ' '),
        (Mark ($mv -and ($mv -join '|') -eq "mv|'/sdcard/DCIM/Camera/IMG_1.jpg'|'/sdcard/DCIM/Camera/IMG_2.jpg'")))

    Say '  -- Search here and Recent files'
    $script:filePath = '/sdcard'
    $ui.FilesSearch.Text = "it's [1]"
    $script:filesSent = @()
    Search-DeviceFiles
    $find = "$(@($script:filesSent)[0])"
    Say ("  {0}   {1}" -f $find, (Mark ($find -eq "find -L '/sdcard' -iname '*it'\''s [1]*' -exec ls -lad {} + 2>/dev/null | head -400")))
    Say ("  {0} hits, info '{1}'   {2}" -f $script:fileItems.Count, $ui.FilesInfo.Text, (Mark ($ui.FilesInfo.Text -eq '5 hits')))
    $ui.FilesSearch.Text = ''
    $ui.FilesRecentWindow.SelectedIndex = 2
    $script:filesSent = @()
    Show-RecentFiles
    $find = "$(@(@($script:filesSent)[0])[0])"
    Say ("  {0}   {1}" -f $find, (Mark ($find -eq 'find -L /sdcard -type f -mtime -7 -exec ls -lad {} + 2>/dev/null | head -400')))
    Say ("  recent: newest first, folders first off   {0}" -f
        (Mark ($script:fileSortColumn -eq 3 -and $script:fileSortDescending -and -not $ui.FilesFoldersFirst.IsChecked)))
    $ui.FilesRecentWindow.SelectedIndex = 0
    $ui.FilesFoldersFirst.IsChecked = $true
    $script:fileSortColumn = 0
    $script:fileSortDescending = $false
}
$sentLeft = @(Get-Command Invoke-DeviceShell -CommandType Function).Count -eq 1 -and
    (Get-Command Get-TargetSerial).ScriptBlock.ToString() -notmatch 'NOVA-TEST'
Say ("  the stand-ins are gone again   {0}" -f (Mark $sentLeft))
$script:fileRows = $savedRows
$script:fileSearchResults = $savedSearch
Show-FileRows

Say ''
Say '== the picture =='
$root = $filesPage.Root
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "files-$size"))
    $outside = @(Get-OutsideElements -Root $root)
    Say ("  {0}: page area {1:N0} x {2:N0}, nothing sticks out ({3})   {4}" -f $size, $ui.PageHost.ActualWidth, $ui.PageHost.ActualHeight,
        ($outside -join '; '), (Mark ($outside.Count -eq 0)))
    # a row is about 31 px and the header 33
    $rowsFit = [Math]::Floor(($ui.FilesList.ActualHeight - 33) / 31)
    Say ("  {0}: the list is {1:N0} px tall, room for {2} rows (at least 5)   {3}" -f $size, $ui.FilesList.ActualHeight, $rowsFit, (Mark ($rowsFit -ge 5)))
    $bar = $ui.FilesCopyPath.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
    Say ("  {0}: the action bar ends at {1:N0}, bottom {2:N0} of {3:N0}   {4}" -f $size, ($bar.X + $ui.FilesCopyPath.ActualWidth),
        ($bar.Y + $ui.FilesCopyPath.ActualHeight), $root.ActualHeight, (Mark (($bar.Y + $ui.FilesCopyPath.ActualHeight) -le $root.ActualHeight + 1)))
}

Say ''
Say '== the transfer row =='
Show-TransferRow
$ui.FilesProgress.Value = 420
$ui.FilesProgressText.Text = '2/3  IMG_20260910_100000.jpg  1.2 MB of 2.9 MB  (42%)'
Wait-Pumped -Milliseconds 300
Say ("  shown in place of the space line   {0}" -f (Mark ($ui.FilesTransfer.IsVisible -and -not $ui.FilesSpace.IsVisible -and $ui.FilesCancel.IsEnabled)))
Say ("  min: {0}" -f (Save-WindowPicture 'files-transfer-min'))
$outside = @(Get-OutsideElements -Root $root)
Say ("  nothing sticks out while it runs ({0})   {1}" -f ($outside -join '; '), (Mark ($outside.Count -eq 0)))
Show-TransferRow -Off
Wait-Pumped -Milliseconds 200
Say ("  gone again, the space line back   {0}" -f (Mark (-not $ui.FilesTransfer.IsVisible -and $ui.FilesSpace.IsVisible -and $ui.FilesProgressText.Text -eq '')))
Set-WindowSize 'default'

Say ''
Say '== the preview window =='
function Save-FilesWindowPicture {
    param($Window, [string]$Name)
    $Window.UpdateLayout()
    Wait-Pumped -Milliseconds 300
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window.Content)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $TestOut "$Name.png"
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Close() }
    return $path
}
# a picture made here, as bytes - the same path a phone's picture takes
$visual = New-Object System.Windows.Media.DrawingVisual
$context = $visual.RenderOpen()
$context.DrawRectangle((Get-Resource 'BrandSoft'), $null, (New-Object System.Windows.Rect(0, 0, 320, 200)))
$context.DrawEllipse((Get-Resource 'Brand'), $null, (New-Object System.Windows.Point(160, 100)), 70, 70)
$context.Close()
$drawn = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(320, 200, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$drawn.Render($visual)
$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($drawn))
$memory = New-Object System.IO.MemoryStream
$encoder.Save($memory)
$png = $memory.ToArray()

$preview = New-FilesPreviewWindow -Title 'drawn.png' -Bytes $png
$preview.Left = -4000; $preview.Top = -3000; $preview.ShowActivated = $false; $preview.WindowStartupLocation = 'Manual'
$preview.Show()
Say ("  picture: '{0}'   {1}" -f $preview.Title, (Mark ($preview.Title -eq 'drawn.png  -  320x200  (from the phone, not saved)')))
Say ("  {0}" -f (Save-FilesWindowPicture -Window $preview -Name 'files-preview-picture'))
$preview.Close()

$bad = New-FilesPreviewWindow -Title 'broken.jpg' -Bytes ([byte[]](1, 2, 3, 4))
Say ("  bytes that are no picture give no window   {0}" -f (Mark ($null -eq $bad)))

$text = "ro.build.version.release=16`nro.product.model=Test`n"
$source = 'a text made here'
if ($phone) {
    # a small text straight from the phone, as Preview reads it: cat into memory
    $bytes = Get-DeviceFileBytes -Serial $phone.Serial -Path '/proc/version'
    if ($bytes -and $bytes.Length -gt 0 -and $bytes.Length -lt 200KB) { $text = [Text.Encoding]::UTF8.GetString($bytes); $source = "/proc/version from the phone, $($bytes.Length) bytes" }
}
$preview = New-FilesPreviewWindow -Title 'build.prop' -Text $text
$preview.Left = -4000; $preview.Top = -3000; $preview.ShowActivated = $false; $preview.WindowStartupLocation = 'Manual'
$preview.Show()
Say ("  text ({0}): '{1}'   {2}" -f $source, $preview.Title, (Mark ($preview.Title -eq 'build.prop  (from the phone, not saved)')))
Say ("  {0}" -f (Save-FilesWindowPicture -Window $preview -Name 'files-preview-text'))
$preview.Close()
