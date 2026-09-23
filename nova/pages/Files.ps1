# pages\Files.ps1 - a file manager for the phone: browse, search, recent files,
# download and upload with a progress bar and a real Cancel, moves that verify
# the copy before deleting the original, new folder / rename / delete, tar.gz
# packing and unpacking on the phone itself, and a preview that saves nothing.

# ------------------------------------------------------------------ state ----

$script:previewFiles = @()
$script:transferCancelled = $false
$script:filePath = '/sdcard'
$script:fileBack = New-Object System.Collections.ArrayList
$script:fileForward = New-Object System.Collections.ArrayList
$script:fileNavigating = $false
$script:fileRows = @()
$script:fileSortColumn = 0
$script:fileSortDescending = $false
$script:fileFoldersFirst = $true
$script:fileSearchResults = $false
$script:fileItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
# the phone the list on screen belongs to
$script:filesSerial = $null

$filesPage = Register-Page -Key 'files' -Title 'Files' -Glyph 'E8B7' -Section 'Workspace' -Xaml 'Files.xaml' `
    -OnShow { Show-FilesPage } -OnDeviceChanged { Update-FilesForDevice } -Refresh { Update-FileList }

# -------------------------------------------------------------- the list ----

function Join-DevicePath {
    param([string]$Parent, [string]$Child)

    if ($Parent.EndsWith('/')) { return "$Parent$Child" }
    return "$Parent/$Child"
}

function Update-FileList {
    param([string]$Path)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if (-not $Path) { $Path = $ui.FilesPath.Text.Trim() }
    if (-not $Path) { $Path = '/sdcard' }

    # a trailing slash makes ls list the contents of a symlinked dir (/sdcard)
    # instead of the link entry itself
    $listPath = if ($Path.EndsWith('/')) { $Path } else { "$Path/" }
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('ls', '-la', (Quote-DeviceArgument $listPath))
    if ($result.Text -match 'Permission denied' -and $result.Text -notmatch '(?m)^[dlbcps-][rwxsStT-]{9}\s+') {
        Write-Log "Permission denied: $Path (adb shell cannot read it)" $colorBad
        return
    }
    if ($result.Text -match 'No such file' -and $result.Text -notmatch '(?m)^[dlbcps-][rwxsStT-]{9}\s+') {
        Write-Log "No such path: $Path" $colorBad
        return
    }

    if ($result.Text -match 'Permission denied') {
        Write-Log "Some entries in $Path are protected by Android; showing readable entries." $colorWarn
    }
    # remember where we came from, unless this is a refresh or a history jump
    if (-not $script:fileNavigating -and $script:filePath -and $script:filePath -ne $Path) {
        $null = $script:fileBack.Add($script:filePath)
        while ($script:fileBack.Count -gt 100) { $script:fileBack.RemoveAt(0) }
        $script:fileForward.Clear()
    }

    $ui.FilesPath.Text = $Path
    $script:filePath = $Path
    $script:filesSerial = $serial

    $rows = @()
    foreach ($line in ($result.Text -split "`r?`n")) {
        $line = $line.TrimEnd()
        if (-not $line -or $line -like 'total *') { continue }

        # drwxrws--- 3 u0_a242 media_rw 3452 2023-12-08 02:26 name with spaces
        if ($line -notmatch '^([dlbcps-][rwxsStT-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$') {
            continue
        }

        $permissions = $Matches[1]
        $owner = $Matches[2]
        $size = [long]$Matches[4]
        $stamp = "$($Matches[5]) $($Matches[6])"
        $name = $Matches[7]

        $isLink = $permissions.StartsWith('l')
        if ($isLink -and $name -match '^(.*?) -> (.*)$') { $name = $Matches[1] }
        $isDirectory = $permissions.StartsWith('d')

        if ($name -eq '.' -or $name -eq '..') { continue }
        if (-not $ui.FilesHidden.IsChecked -and $name.StartsWith('.')) { continue }

        $extension = ''
        if (-not $isDirectory) {
            $dot = $name.LastIndexOf('.')
            if ($dot -gt 0 -and $dot -lt ($name.Length - 1)) {
                $extension = $name.Substring($dot + 1).ToUpperInvariant()
            }
        }

        $rows += [PSCustomObject]@{
            Name        = $name
            Label       = $name
            Path        = (Join-DevicePath -Parent $Path -Child $name)
            IsDirectory = $isDirectory
            IsLink      = $isLink
            Extension   = $extension
            Size        = $size
            Stamp       = $stamp
            Permissions = $permissions
            Owner       = $owner
        }
    }

    $script:fileRows = $rows
    $script:fileSearchResults = $false
    Show-FileRows
    Show-FileSpace -Serial $serial -Path $Path
}

function Get-FilesGlyph {
    # the symbol in front of a name: folder, link, or what kind of file
    param($Row)

    if ($Row.IsDirectory) { return [string][char]0xE8B7 }
    if ($Row.IsLink) { return [string][char]0xE71B }
    $kind = $Row.Extension.ToLowerInvariant()
    if (@('png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico', 'heic') -contains $kind) { return [string][char]0xEB9F }
    if (@('mp4', 'mkv', '3gp', 'webm', 'avi', 'mov') -contains $kind) { return [string][char]0xE714 }
    if (@('mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac', 'amr') -contains $kind) { return [string][char]0xE8D6 }
    if (@('zip', 'tar', 'gz', 'tgz', 'bz2', 'tbz', '7z', 'rar', 'apk') -contains $kind) { return [string][char]0xF012 }
    return [string][char]0xE8A5
}

function Show-FileRows {
    $rows = $script:fileRows

    # numbers must sort as numbers, dates as dates, names case-insensitively
    $key = switch ($script:fileSortColumn) {
        1 { { $_.Extension } }
        2 { { $_.Size } }
        3 { { $_.Stamp } }
        4 { { $_.Permissions } }
        5 { { $_.Owner } }
        default { { $_.Label.ToLowerInvariant() } }
    }

    $filter = $ui.FilesSearch.Text.Trim()
    if ($filter -and -not $script:fileSearchResults) {
        $rows = @($rows | Where-Object { Test-TextContains $_.Label $filter })
    }

    if ($script:fileFoldersFirst) {
        $rows = @($rows | Sort-Object @{ Expression = { -not $_.IsDirectory } },
            @{ Expression = $key; Descending = $script:fileSortDescending })
    } else {
        $rows = @($rows | Sort-Object -Property @{ Expression = $key } -Descending:$script:fileSortDescending)
    }

    # the arrow on the column that sorts: down for descending, up for ascending
    $arrow = if ($script:fileSortDescending) { ' ' + [char]0x2193 } else { ' ' + [char]0x2191 }
    $headers = @('NAME', 'TYPE', 'SIZE', 'MODIFIED', 'PERMISSIONS', 'OWNER')
    $columns = $ui.FilesList.View.Columns
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $columns[$i].Header = $headers[$i] + $(if ($i -eq $script:fileSortColumn) { $arrow } else { '' })
    }

    $folderBrush = Get-Resource 'Brand'
    $linkBrush = Get-Resource 'MutedText'
    $fileBrush = Get-Resource 'Ink'
    $script:fileItems.Clear()
    $index = 0
    foreach ($row in $rows) {
        $brush = if ($row.IsDirectory) { $folderBrush } elseif ($row.IsLink) { $linkBrush } else { $fileBrush }
        $script:fileItems.Add([PSCustomObject]@{
            Index       = $index
            Tag         = $row
            Label       = $row.Label
            Glyph       = (Get-FilesGlyph -Row $row)
            Brush       = $brush
            Type        = $(if ($row.IsDirectory) { '<dir>' } else { $row.Extension })
            SizeText    = $(if ($row.IsDirectory) { '' } else { Format-FileSize -Bytes $row.Size })
            Stamp       = $row.Stamp
            Permissions = $row.Permissions
            Owner       = $row.Owner
        })
        $index++
    }
    if ($null -eq $ui.FilesList.ItemsSource) { $ui.FilesList.ItemsSource = $script:fileItems }

    $directories = @($rows | Where-Object { $_.IsDirectory }).Count
    $files = $rows.Count - $directories
    $ui.FilesInfo.Text = "$directories dirs, $files files"
    $ui.FilesInfo.ToolTip = $ui.FilesInfo.Text
}

function Set-FilesSortColumn {
    # a click on a column header: the same column reverses, another starts fresh
    param([int]$Column)

    if ($Column -lt 0) { return }
    if ($script:fileSortColumn -eq $Column) {
        $script:fileSortDescending = -not $script:fileSortDescending
    } else {
        $script:fileSortColumn = $Column
        # names read best A-Z, sizes and dates biggest/newest first
        $script:fileSortDescending = ($Column -eq 1 -or $Column -eq 2)
    }
    Show-FileRows
}

function Set-FileSelection {
    param([ValidateSet('all', 'none', 'invert')][string]$Mode = 'all')

    if ($script:fileItems.Count -eq 0) { return }

    switch ($Mode) {
        'none' { $ui.FilesList.UnselectAll() }
        'invert' {
            $was = @{}
            foreach ($item in @($ui.FilesList.SelectedItems)) { $was[$item.Index] = $true }
            $ui.FilesList.UnselectAll()
            foreach ($item in @($script:fileItems)) {
                if (-not $was.ContainsKey($item.Index)) { $null = $ui.FilesList.SelectedItems.Add($item) }
            }
        }
        default { $ui.FilesList.SelectAll() }
    }

    # keep the keyboard on the list, so Ctrl+A and the arrows carry on working
    if ($ui.FilesList.IsVisible) { $null = $ui.FilesList.Focus() }
    Write-Log "$($ui.FilesList.SelectedItems.Count) of $($script:fileItems.Count) item(s) selected." $colorInfo
}

function Invoke-FileHistory {
    # the mouse back/forward buttons walk the folders visited in this session
    param([ValidateSet('back', 'forward')][string]$Direction)

    # plain assignment, not "$x = if (...) { $list }" - that form unrolls the
    # ArrayList into a fixed size array and RemoveAt then throws
    if ($Direction -eq 'back') {
        $from = $script:fileBack
        $to = $script:fileForward
    } else {
        $from = $script:fileForward
        $to = $script:fileBack
    }

    if ($from.Count -eq 0) {
        Write-Log "No folder to go $Direction to." $colorInfo
        return
    }

    $target = "$($from[$from.Count - 1])"
    $current = $script:filePath
    $from.RemoveAt($from.Count - 1)

    $script:fileNavigating = $true
    try { Update-FileList -Path $target } finally { $script:fileNavigating = $false }

    if ($script:filePath -eq $target) {
        $null = $to.Add($current)
    } else {
        # the folder is gone or unreadable - leave the history as it was
        $null = $from.Add($target)
    }
}

function Split-DevicePath {
    # the folder an entry actually lives in (search hits are not in view)
    param([string]$Path)

    $index = $Path.TrimEnd('/').LastIndexOf('/')
    if ($index -le 0) { return '/' }
    return $Path.Substring(0, $index)
}

function Get-DeviceFileBytes {
    # read a file straight out of adb, without leaving a copy on this PC
    param([string]$Serial, [string]$Path, [int]$TimeoutMs = 30000)

    # exec-out hands the argument to the device as it stands - no shell re-parse
    # there - so the quoting that matters is the one Windows itself removes
    $bytes = Get-AdbBytes -Arguments ("-s $Serial exec-out cat " + '"' + ($Path -replace '"', '\"') + '"') -TimeoutMs $TimeoutMs
    # the comma keeps PowerShell from unrolling the array into single bytes
    return ,$bytes
}

function Show-FileSpace {
    # how full the volume under the current folder is
    param([string]$Serial, [string]$Path)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('df', '-h', (Quote-DeviceArgument $Path))).Text
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+%)\s+(\S+)\s*$') {
            $ui.FilesSpace.Text = "space here: $($Matches[2]) used of $($Matches[1])   |   $($Matches[3]) free   |   $($Matches[4]) full   |   volume $($Matches[5])"
            return
        }
    }
    $ui.FilesSpace.Text = ''
}

function Update-FileVolumes {
    # put every mounted volume in the jump list, so storage can be browsed
    param([string]$Serial)

    if (-not $Serial) { return }
    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('sm', 'list-volumes')).Text
    $paths = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*emulated;(\d+)\s+mounted') { $paths += "/storage/emulated/$($Matches[1])" }
        elseif ($line -match '^\s*public:(\S+)\s+mounted\s+(\S+)') { $paths += "/storage/$($Matches[2])" }
    }
    foreach ($path in $paths) {
        if (-not $ui.FilesQuick.Items.Contains($path)) { $null = $ui.FilesQuick.Items.Add($path) }
    }
}

function Get-SelectedFiles {
    # in the order the list shows them, whatever order they were clicked in
    $rows = @()
    foreach ($item in @($ui.FilesList.SelectedItems | Sort-Object -Property Index)) {
        if ($item.Tag) {
            $rows += [PSCustomObject]@{
                Name        = $item.Tag.Name
                IsDirectory = $item.Tag.IsDirectory
                Path        = $item.Tag.Path
            }
        }
    }
    return $rows
}

# -------------------------------------------------------------- archives ----

function Compress-DeviceFiles {
    param([string]$ArchiveName)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick what to pack first.' $colorWarn; return }

    $folder = Split-DevicePath -Path $rows[0].Path
    $suggested = if ($rows.Count -eq 1) { "$($rows[0].Name).tar.gz" } else { 'archive.tar.gz' }
    $name = $ArchiveName
    if (-not $name) {
        $answer = Show-InputDialog -Title 'Compress' -Hint "Name of the archive, made inside`n$folder" `
            -Fields @('Archive name') -Values @($suggested) -OkText 'Compress'
        if ($null -eq $answer) { return }
        $name = "$(@($answer)[0])"
    }
    if (-not "$name".Trim()) { return }
    $name = $name.Trim()
    if ($name -notmatch '\.(tar\.gz|tgz|tar)$') { $name += '.tar.gz' }

    # the phone has tar and gzip but no zip, so a tarball it is. Entries from
    # one folder go in by name; search hits from several go in by their path
    # from /, since no one folder holds them all.
    $target = Join-DevicePath -Parent $folder -Child $name
    $oneFolder = @($rows | Where-Object { (Split-DevicePath -Path $_.Path) -ne $folder }).Count -eq 0
    $base = if ($oneFolder) { $folder } else { '/' }
    $arguments = @('tar', '-czf', (Quote-DeviceArgument $target), '-C', (Quote-DeviceArgument $base))
    foreach ($row in $rows) {
        $entry = if ($oneFolder) { $row.Name } else { $row.Path.TrimStart('/') }
        $arguments += (Quote-DeviceArgument $entry)
    }

    Write-Log "Packing $($rows.Count) item(s) into $target ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
    if ($result.Text -match 'denied|No such|Error|cannot') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }

    $size = Get-DeviceFileSize -Serial $serial -Path $target
    if ($size -gt 0) {
        Write-Log "Made $name ($(Format-FileSize -Bytes $size))." $colorGood
    } else {
        Write-Log "tar said nothing but $name is not there." $colorBad
    }
    Update-FileList
}

function Expand-DeviceArchive {
    param([string]$Into)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles | Where-Object { -not $_.IsDirectory })
    if ($rows.Count -eq 0) { Write-Log 'Pick an archive first.' $colorWarn; return }

    $archive = $rows[0]
    $folder = Split-DevicePath -Path $archive.Path
    $lower = $archive.Name.ToLowerInvariant()

    $target = $Into
    if (-not $target) {
        $answer = Show-InputDialog -Title 'Extract' -Hint "Unpack $($archive.Name) into which folder on the phone?" `
            -Fields @('Folder on the phone') -Values @($folder) -OkText 'Extract'
        if ($null -eq $answer) { return }
        $target = "$(@($answer)[0])"
    }
    if (-not "$target".Trim()) { return }
    $target = $target.Trim()

    if ($lower.EndsWith('.zip') -or $lower.EndsWith('.apk')) {
        $arguments = @('unzip', '-o', (Quote-DeviceArgument $archive.Path), '-d', (Quote-DeviceArgument $target))
    } elseif ($lower.EndsWith('.tar.gz') -or $lower.EndsWith('.tgz')) {
        $arguments = @('tar', '-xzf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $target))
    } elseif ($lower.EndsWith('.tar.bz2') -or $lower.EndsWith('.tbz')) {
        $arguments = @('tar', '-xjf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $target))
    } elseif ($lower.EndsWith('.tar')) {
        $arguments = @('tar', '-xf', (Quote-DeviceArgument $archive.Path), '-C', (Quote-DeviceArgument $target))
    } elseif ($lower.EndsWith('.gz')) {
        $plain = Join-DevicePath -Parent $target -Child ($archive.Name -replace '\.gz$', '')
        $arguments = @('gzip', '-dc', (Quote-DeviceArgument $archive.Path), '>', (Quote-DeviceArgument $plain))
    } else {
        Write-Log "$($archive.Name) is not a kind of archive the phone can open (zip, tar, tar.gz, tar.bz2, gz)." $colorWarn
        return
    }

    # the folder only once the archive is known to be one the phone can open
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('mkdir', '-p', (Quote-DeviceArgument $target))

    Write-Log "Unpacking $($archive.Name) into $target ..." $colorStep
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
    if ($result.Text -match 'denied|cannot|Error|No such') {
        Write-Log $result.Text.Trim() $colorBad
        return
    }
    Write-Log "Unpacked $($archive.Name)." $colorGood
    Update-FileList -Path $target
}

# --------------------------------------------------------------- preview ----

function Show-DeviceFilePreview {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles | Where-Object { -not $_.IsDirectory })
    if ($rows.Count -eq 0) { Write-Log 'Pick a file to look at.' $colorWarn; return }

    $row = $rows[0]
    $extension = ''
    $dot = $row.Name.LastIndexOf('.')
    if ($dot -gt 0) { $extension = $row.Name.Substring($dot + 1).ToLowerInvariant() }

    $pictures = @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico')
    $texts = @('txt', 'log', 'json', 'xml', 'csv', 'md', 'ini', 'conf', 'html', 'htm', 'js', 'css', 'sh', 'prop')
    $media = @('mp4', 'mkv', '3gp', 'webm', 'avi', 'mov', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac')

    $size = Get-DeviceFileSize -Serial $serial -Path $row.Path
    if ($pictures -contains $extension -or $texts -contains $extension) {
        if ($size -gt 25MB) {
            Write-Log "$($row.Name) is $(Format-FileSize -Bytes $size) - too big to show in the window." $colorWarn
            return
        }
        Write-Log "Reading $($row.Name) from the phone ..." $colorStep
        $bytes = Get-DeviceFileBytes -Serial $serial -Path $row.Path
        if (-not $bytes -or $bytes.Length -eq 0) { Write-Log "Could not read $($row.Name)." $colorBad; return }
        # exec-out carries cat's complaint on the same stream as the file:
        # shown as the file, a denied read looked like its contents
        if ($bytes.Length -lt 400) {
            $said = [System.Text.Encoding]::UTF8.GetString($bytes).Trim()
            if ($said -match '^cat: .*(Permission denied|No such file)') {
                Write-Log "Could not read $($row.Name): $said" $colorBad
                return
            }
        }

        if ($pictures -contains $extension) {
            Show-PreviewWindow -Title $row.Name -Bytes $bytes
        } else {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            Show-PreviewWindow -Title $row.Name -Text $text
        }
        Write-Log "Showed $($row.Name) ($(Format-FileSize -Bytes $bytes.Length)); nothing was saved on this PC." $colorGood
        return
    }

    if ($media -contains $extension) {
        # no codec inside this window, so the player needs a file to open;
        # it goes to the temp folder and is removed when the app closes
        Write-Log "Video and sound need a player, so $($row.Name) is copied to the temp folder first." $colorInfo
        $temp = Join-Path $env:TEMP ("androiddc-nova-$PID.preview." + $row.Name)
        $result = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', $row.Path, $temp)
        if (-not (Test-Path -LiteralPath $temp)) { Write-Log $result.Text.Trim() $colorBad; return }
        $script:previewFiles += $temp
        Start-Process -FilePath $temp
        Write-Log "Opened $($row.Name) in the default player." $colorGood
        return
    }

    Write-Log "$($row.Name) is not a picture, a text or a media file - use Download instead." $colorWarn
}

function New-FilesPreviewWindow {
    # the preview's window, built but not shown: a picture or a text, from memory
    param([string]$Title, [byte[]]$Bytes, [string]$Text)

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="700" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        Background="{StaticResource Cloud}" Foreground="{StaticResource Ink}"
        FontFamily="{StaticResource BodyFont}" FontSize="13" UseLayoutRounding="True">
  <DockPanel Margin="14">
    <TextBlock x:Name="PreviewNote" DockPanel.Dock="Top" Style="{StaticResource MutedLine}" Margin="2,0,0,10"
               Text="Read straight from the phone into memory - nothing was saved on this PC."/>
    <Border Style="{StaticResource CardPanel}" Padding="8">
      <Grid x:Name="PreviewHost"/>
    </Border>
  </DockPanel>
</Window>
'@
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $window.Title = "$Title  (from the phone, not saved)"
    if ($script:window -and $script:window.IsVisible) { $window.Owner = $script:window } else { $window.WindowStartupLocation = 'CenterScreen' }
    $hostGrid = $window.FindName('PreviewHost')

    if ($Bytes) {
        $stream = New-Object System.IO.MemoryStream(, $Bytes)
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.StreamSource = $stream
            $bitmap.EndInit()
            $bitmap.Freeze()
        } catch {
            Write-Log "That file is not a picture the PC can read." $colorBad
            return $null
        } finally {
            $stream.Dispose()
        }
        $image = New-Object System.Windows.Controls.Image
        $image.Source = $bitmap
        $image.Stretch = 'Uniform'
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, 'HighQuality')
        $null = $hostGrid.Children.Add($image)
        $window.Title = "$Title  -  $($bitmap.PixelWidth)x$($bitmap.PixelHeight)  (from the phone, not saved)"
    } else {
        $box = New-Object System.Windows.Controls.TextBox
        $box.Style = Get-Resource 'Console'
        $box.BorderThickness = New-Object System.Windows.Thickness(0)
        $box.Text = $Text
        $null = $hostGrid.Children.Add($box)
    }
    return $window
}

function Show-PreviewWindow {
    param([string]$Title, [byte[]]$Bytes, [string]$Text)

    $window = if ($Bytes) { New-FilesPreviewWindow -Title $Title -Bytes $Bytes } else { New-FilesPreviewWindow -Title $Title -Text $Text }
    if ($null -eq $window) { return }
    $null = $window.ShowDialog()
}

# ------------------------------------------------------------ navigation ----

function Show-RecentFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $chosen = $ui.FilesRecentWindow.SelectedItem
    $words = if ($chosen) { "$($chosen.Content)" } else { 'today' }
    $days = switch ($words) {
        'last 2 days'  { 2 }
        'last week'    { 7 }
        'last 30 days' { 30 }
        default        { 1 }
    }

    # the whole shared storage, not just the folder on screen
    $root = '/sdcard'
    Write-Log "Looking for files changed in the last $days day(s) across $root ..." $colorStep

    $command = "find -L $root -type f -mtime -$days -exec ls -lad {} + 2>/dev/null | head -400"
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @($command)

    $rows = @(ConvertFrom-LsOutput -Text $result.Text -Root $root)
    $script:fileRows = $rows
    $script:fileSearchResults = $true
    $script:filesSerial = $serial

    # newest first is the only order that makes sense here
    $script:fileSortColumn = 3
    $script:fileSortDescending = $true
    $script:fileFoldersFirst = $false
    $ui.FilesFoldersFirst.IsChecked = $false
    Show-FileRows

    $ui.FilesInfo.Text = "$($rows.Count) recent"
    Write-Log "$($rows.Count) file(s) changed in the last $days day(s)." $(if ($rows.Count) { $colorGood } else { $colorWarn })
}

function ConvertFrom-LsOutput {
    param([string]$Text, [string]$Root)

    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $line = $line.TrimEnd()
        if ($line -notmatch '^([dlbcps-][rwxsStT-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$') {
            continue
        }

        $permissions = $Matches[1]
        $owner = $Matches[2]
        $size = [long]$Matches[4]
        $stamp = "$($Matches[5]) $($Matches[6])"
        $full = $Matches[7]
        if ($full -match '^(.*?) -> (.*)$') { $full = $Matches[1] }

        $name = $full.Substring($full.LastIndexOf('/') + 1)
        $isDirectory = $permissions.StartsWith('d')

        $extension = ''
        if (-not $isDirectory) {
            $dot = $name.LastIndexOf('.')
            if ($dot -gt 0 -and $dot -lt ($name.Length - 1)) { $extension = $name.Substring($dot + 1).ToUpperInvariant() }
        }

        $shown = $full
        if ($Root -and $full.StartsWith($Root)) { $shown = $full.Substring($Root.TrimEnd('/').Length).TrimStart('/') }

        # Name is the file's own name, as in a folder listing; the path under
        # the search root is only what the list shows. With the relative path
        # as its name, Move to PC looked for dest\DCIM/Camera/x.jpg, found
        # nothing, and never deleted the phone copy; Rename and Compress went
        # to folders that do not exist.
        $rows += [PSCustomObject]@{
            Name        = $name
            Label       = $shown
            Path        = $full
            IsDirectory = $isDirectory
            IsLink      = $permissions.StartsWith('l')
            Extension   = $extension
            Size        = $size
            Stamp       = $stamp
            Permissions = $permissions
            Owner       = $owner
        }
    }
    return $rows
}

function Search-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $query = $ui.FilesSearch.Text.Trim()
    if (-not $query) { Write-Log 'Type something to search for first.' $colorWarn; return }

    $root = $script:filePath
    Write-Log "Searching '$query' under $root ..." $colorStep

    # one ls line per hit, so the same parser can be reused
    $command = "find -L " + (Quote-DeviceArgument $root) + " -iname " + (Quote-DeviceArgument "*$query*") +
        " -exec ls -lad {} + 2>/dev/null | head -400"
    # typed text: as base64, so a " in the query is not dropped on the way
    $result = Invoke-DeviceShellText -Serial $serial -Command $command

    $rows = @(ConvertFrom-LsOutput -Text $result.Text -Root $root)

    $script:fileRows = $rows
    $script:fileSearchResults = $true
    $script:filesSerial = $serial
    Show-FileRows
    $ui.FilesInfo.Text = "$($rows.Count) hits"
    Write-Log "$($rows.Count) match(es) for '$query'." $(if ($rows.Count) { $colorGood } else { $colorWarn })
}

function Open-FileEntry {
    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { return }

    if ($rows[0].IsDirectory) {
        Update-FileList -Path $rows[0].Path
    } else {
        Save-DeviceFiles
    }
}

function Set-FileParent {
    $current = $script:filePath
    if (-not $current -or $current -eq '/') { return }
    $parent = $current.TrimEnd('/')
    $index = $parent.LastIndexOf('/')
    $parent = if ($index -le 0) { '/' } else { $parent.Substring(0, $index) }
    Update-FileList -Path $parent
}

function Invoke-FilesListKey {
    # the keys of the file list; true when the key was used
    param([System.Windows.Input.Key]$Key, [System.Windows.Input.ModifierKeys]$Modifiers)

    # compared as numbers and members, as Invoke-WindowKey does
    $none = [int]$Modifiers -eq 0
    $control = $Modifiers -eq [System.Windows.Input.ModifierKeys]::Control
    $alt = $Modifiers -eq [System.Windows.Input.ModifierKeys]::Alt
    if ($control -and $Key -eq [System.Windows.Input.Key]::A) { Set-FileSelection -Mode all; return $true }
    if ($none -and $Key -eq [System.Windows.Input.Key]::Escape) { Set-FileSelection -Mode none; return $true }
    if ($alt -and $Key -eq [System.Windows.Input.Key]::Left) { Invoke-FileHistory -Direction back; return $true }
    if ($alt -and $Key -eq [System.Windows.Input.Key]::Right) { Invoke-FileHistory -Direction forward; return $true }
    if ($none -and $Key -eq [System.Windows.Input.Key]::Back) { Set-FileParent; return $true }
    return $false
}

function Test-FilesRowHit {
    # whether a mouse event happened on a row, not on a header or a scroll bar
    param($Source)

    $node = $Source
    while ($null -ne $node) {
        if ($node -is [System.Windows.Controls.ListViewItem]) { return $true }
        if ($node -is [System.Windows.Controls.GridViewColumnHeader] -or $node -is [System.Windows.Controls.Primitives.ScrollBar]) { return $false }
        if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        } elseif ($node -is [System.Windows.FrameworkContentElement]) {
            $node = $node.Parent
        } else {
            $node = $null
        }
    }
    return $false
}

# ------------------------------------------------------------- transfers ----

function Show-TransferRow {
    param([switch]$Off)

    $running = -not $Off
    $ui.FilesTransfer.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }
    $ui.FilesCancel.IsEnabled = $running
    $ui.FilesSpace.Visibility = if ($running) { 'Collapsed' } else { 'Visible' }
    if (-not $running) {
        $ui.FilesProgress.IsIndeterminate = $false
        $ui.FilesProgress.Value = 0
        $ui.FilesProgressText.Text = ''
    }
}

function Invoke-FileTransfer {
    <#
        One adb pull or push with a progress bar and a Cancel that really stops
        it. adb prints no progress at all when its output is redirected, so the
        bar measures the destination instead: the local file for a pull, the
        file on the phone for a push.
    #>
    param(
        [string]$Serial,
        [ValidateSet('pull', 'push')][string]$Direction,
        [string]$Source,
        [string]$Target,
        [long]$Size = -1,
        [string]$Caption = ''
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = "-s $Serial $Direction " + ('"' + $Source + '" "' + $Target + '"')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # adb writes UTF-8. Left unset, .NET decodes a redirected stream with the
    # console code page, and on a PC still on an OEM page (437, 720, ...) an
    # Arabic file name in adb's messages came back garbled - measured.
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { return [PSCustomObject]@{ Ok = $false; Text = 'adb did not start'; Cancelled = $false } }

    # both streams are read as they come, so a chatty adb never blocks on a full pipe
    $errorRead = $process.StandardError.ReadToEndAsync()
    $outputRead = $process.StandardOutput.ReadToEndAsync()

    if ($script:busy -eq 0) { $script:busyWhat = "adb $Direction $Source" }
    $script:busy++
    $cancelled = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPoll = 0
    $done = 0

    try {
        while (-not $process.HasExited) {
            Invoke-Pump
            Start-Sleep -Milliseconds 60

            if ($script:transferCancelled) {
                try { $process.Kill() } catch { }
                $cancelled = $true
                break
            }

            # a pull grows a file here, so ask the file system; a push grows a
            # file over there, so ask the phone, but not too often
            if ($Direction -eq 'pull') {
                if (Test-Path -LiteralPath $Target -PathType Leaf) {
                    try { $done = (Get-Item -LiteralPath $Target).Length } catch { }
                }
            } elseif (($watch.ElapsedMilliseconds - $lastPoll) -gt 700) {
                $lastPoll = $watch.ElapsedMilliseconds
                $remote = Get-DeviceFileSize -Serial $Serial -Path $Target
                if ($remote -gt 0) { $done = $remote }
            }

            if ($Size -gt 0) {
                $share = [Math]::Min(1000, [int](1000 * $done / $Size))
                $ui.FilesProgress.IsIndeterminate = $false
                $ui.FilesProgress.Value = [Math]::Max(0, $share)
                $ui.FilesProgressText.Text = ('{0}  {1} of {2}  ({3}%)' -f $Caption,
                    (Format-FileSize -Bytes $done), (Format-FileSize -Bytes $Size), [int]($share / 10))
            } else {
                $ui.FilesProgress.IsIndeterminate = $true
                $ui.FilesProgressText.Text = ('{0}  {1} so far' -f $Caption, (Format-FileSize -Bytes $done))
            }
        }
        $null = $process.WaitForExit(3000)
    } finally {
        $script:busy--
        if ($script:busy -lt 0) { $script:busy = 0 }
        $ui.FilesProgress.IsIndeterminate = $false
    }

    $text = ''
    try {
        if ($errorRead.Wait(3000)) { $text += $errorRead.Result }
        if ($outputRead.Wait(3000)) { $text += $outputRead.Result }
    } catch { }
    $text = $text.Trim()
    $code = if ($process.HasExited) { $process.ExitCode } else { -1 }
    $process.Dispose()

    if ($cancelled) {
        # a half written file helps nobody
        if ($Direction -eq 'pull') {
            if (Test-Path -LiteralPath $Target -PathType Leaf) {
                Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            }
        } else {
            $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('rm', '-f', (Quote-DeviceArgument $Target))
        }
        Write-Log "Cancelled, and the half written copy was removed." $colorWarn
        return [PSCustomObject]@{ Ok = $false; Text = 'cancelled'; Cancelled = $true }
    }

    $ui.FilesProgress.Value = $ui.FilesProgress.Maximum
    return [PSCustomObject]@{ Ok = ($code -eq 0); Text = $text; Cancelled = $false }
}

function Select-FilesUploadSources {
    # the Open dialog with a title of its own: what happens to the files is said there
    param([string]$Title)

    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = $Title
    $folder = $ui.FilesLocal.Text.Trim()
    if ($folder -and (Test-Path -LiteralPath $folder)) { $dialog.InitialDirectory = $folder }
    if ($dialog.ShowDialog($script:window)) { return @($dialog.FileNames) }
    return @()
}

function Save-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something in the list first.' $colorWarn; return }

    $destination = $ui.FilesLocal.Text.Trim()
    if (-not $destination) { Write-Log 'Set the PC folder first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $destination)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
    }

    $script:transferCancelled = $false
    Show-TransferRow
    try {
        $index = 0
        foreach ($row in $rows) {
            $index++
            if ($script:transferCancelled) { break }

            Write-Log "pull $($row.Path) ..." $colorStep
            $size = if ($row.IsDirectory) { -1 } else { Get-DeviceFileSize -Serial $serial -Path $row.Path }
            $target = Join-Path $destination $row.Name
            $caption = if ($rows.Count -gt 1) { "$index/$($rows.Count)  $($row.Name)" } else { $row.Name }

            $result = Invoke-FileTransfer -Serial $serial -Direction 'pull' -Source $row.Path `
                -Target $target -Size $size -Caption $caption
            if ($result.Cancelled) { break }
            Write-Log ("  " + $result.Text) $(if ($result.Ok) { $colorGood } else { $colorBad })
        }
    } finally {
        Show-TransferRow -Off
    }
}

function Send-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $files = @(Select-FilesUploadSources -Title "Upload to $($script:filePath)")
    if ($files.Count -eq 0) { return }

    $script:transferCancelled = $false
    Show-TransferRow
    try {
        $index = 0
        foreach ($file in $files) {
            $index++
            if ($script:transferCancelled) { break }

            $name = [System.IO.Path]::GetFileName($file)
            $target = Join-DevicePath -Parent $script:filePath -Child $name
            Write-Log "push $file -> $target" $colorStep
            $size = -1
            try { $size = (Get-Item -LiteralPath $file).Length } catch { }
            $caption = if ($files.Count -gt 1) { "$index/$($files.Count)  $name" } else { $name }

            $result = Invoke-FileTransfer -Serial $serial -Direction 'push' -Source $file `
                -Target $target -Size $size -Caption $caption
            if ($result.Cancelled) { break }
            Write-Log ("  " + $result.Text) $(if ($result.Ok) { $colorGood } else { $colorBad })
        }
    } finally {
        Show-TransferRow -Off
    }

    Update-FileList
}

function Get-DeviceFileSize {
    param([string]$Serial, [string]$Path)

    $result = Invoke-DeviceShell -Serial $Serial -CommandArguments @('ls', '-la', (Quote-DeviceArgument $Path))
    if ($result.Text -match '^[dlbcps-][rwxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s') { return [long]$Matches[1] }
    return -1
}

function Move-FilesToPc {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something in the list first.' $colorWarn; return }

    $destination = $ui.FilesLocal.Text.Trim()
    if (-not $destination) { Write-Log 'Set the PC folder first.' $colorWarn; return }
    if (-not (Test-Path -LiteralPath $destination)) { $null = New-Item -ItemType Directory -Path $destination -Force }

    $list = ($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine
    $answer = Show-Confirm -Title 'Move to PC' -Text ("Move to $destination and delete from the phone?" + [Environment]::NewLine + $list) `
        -Yes 'Move' -No 'Cancel' -Danger
    if (-not $answer) { return }

    foreach ($row in $rows) {
        Write-Log "move $($row.Path) -> PC ..." $colorStep
        $remoteSize = if ($row.IsDirectory) { -1 } else { Get-DeviceFileSize -Serial $serial -Path $row.Path }

        $pull = Invoke-Adb -CommandArguments @('-s', $serial, 'pull', $row.Path, $destination)
        if ($pull.ExitCode -ne 0) {
            Write-Log ('  pull failed, nothing deleted: ' + (($pull.Lines | Select-Object -Last 1))) $colorBad
            continue
        }

        # only delete once the copy is really here and the size matches
        $local = Join-Path $destination $row.Name
        if (-not (Test-Path -LiteralPath $local)) {
            Write-Log '  the copy is not on the PC, nothing deleted.' $colorBad
            continue
        }
        if (-not $row.IsDirectory) {
            $localSize = (Get-Item -LiteralPath $local).Length
            if ($remoteSize -ge 0 -and $localSize -ne $remoteSize) {
                Write-Log "  size mismatch (phone $remoteSize, PC $localSize) - nothing deleted." $colorBad
                continue
            }
        }

        if ($row.IsDirectory) { $arguments = @('rm', '-rf', (Quote-DeviceArgument $row.Path)) }
        else { $arguments = @('rm', '-f', (Quote-DeviceArgument $row.Path)) }
        $remove = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
        if ($remove.Text.Trim()) {
            Write-Log ('  delete failed: ' + $remove.Text.Trim()) $colorBad
        } else {
            Write-Log "  moved, phone copy deleted." $colorGood
            $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
                'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $row.Path)
        }
    }

    Update-FileList
}

function Move-FilesToPhone {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $files = @(Select-FilesUploadSources -Title "Move to $($script:filePath) (the PC copy is deleted)")
    if ($files.Count -eq 0) { return }

    $answer = Show-Confirm -Title 'Move to phone' `
        -Text ("Upload these and delete them from this PC?" + [Environment]::NewLine + ($files -join [Environment]::NewLine)) `
        -Yes 'Move' -No 'Cancel' -Danger
    if (-not $answer) { return }

    foreach ($file in $files) {
        $name = [System.IO.Path]::GetFileName($file)
        $target = Join-DevicePath -Parent $script:filePath -Child $name
        Write-Log "move $file -> $target ..." $colorStep

        $push = Invoke-Adb -CommandArguments @('-s', $serial, 'push', $file, $target)
        if ($push.ExitCode -ne 0) {
            Write-Log ('  push failed, the PC file is kept: ' + (($push.Lines | Select-Object -Last 1))) $colorBad
            continue
        }

        $localSize = (Get-Item -LiteralPath $file).Length
        $remoteSize = Get-DeviceFileSize -Serial $serial -Path $target
        if ($remoteSize -ne $localSize) {
            Write-Log "  size mismatch (PC $localSize, phone $remoteSize) - the PC file is kept." $colorBad
            continue
        }

        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $file) {
            Write-Log '  uploaded, but the PC file could not be deleted.' $colorWarn
        } else {
            Write-Log '  moved, PC copy deleted.' $colorGood
        }
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $target)
    }

    Update-FileList
}

# ------------------------------------------------------------ organising ----

function New-DeviceDirectory {
    param([string]$Name)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $folderName = $Name
    if (-not $folderName) {
        $answer = Show-InputDialog -Title 'New folder' -Fields @("New folder inside $($script:filePath):") -Values @('new-folder') -OkText 'Create'
        if ($null -eq $answer) { return }
        $folderName = "$(@($answer)[0])"
    }
    if (-not $folderName.Trim()) { return }

    $target = Join-DevicePath -Parent $script:filePath -Child $folderName.Trim()
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('mkdir', '-p', (Quote-DeviceArgument $target))
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorBad
    } else {
        Write-Log "created $target" $colorGood
    }
    Update-FileList
}

function Rename-DeviceFile {
    param([string]$NewName)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -ne 1) { Write-Log 'Pick exactly one entry to rename.' $colorWarn; return }

    $name = $NewName
    if (-not $name) {
        $answer = Show-InputDialog -Title 'Rename' -Fields @('New name:') -Values @($rows[0].Name) -OkText 'Rename'
        if ($null -eq $answer) { return }
        $name = "$(@($answer)[0])"
    }
    if (-not "$name".Trim() -or $name -eq $rows[0].Name) { return }

    # rename inside the folder the entry actually lives in (search hits differ)
    $parent = $rows[0].Path.Substring(0, $rows[0].Path.LastIndexOf('/'))
    if (-not $parent) { $parent = '/' }
    $target = Join-DevicePath -Parent $parent -Child $name.Trim()
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'mv', (Quote-DeviceArgument $rows[0].Path), (Quote-DeviceArgument $target))
    if ($result.Text.Trim()) {
        Write-Log $result.Text $colorBad
    } else {
        Write-Log "renamed to $name" $colorGood
    }
    Update-FileList
}

function Remove-DeviceFiles {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something to delete first.' $colorWarn; return }

    $list = ($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine
    $answer = Show-Confirm -Title 'Delete' -Text ('Delete these from the phone? This cannot be undone.' + [Environment]::NewLine + $list) `
        -Yes 'Delete' -No 'Cancel' -Danger
    if (-not $answer) { return }

    foreach ($row in $rows) {
        if ($row.IsDirectory) { $arguments = @('rm', '-rf', (Quote-DeviceArgument $row.Path)) }
        else { $arguments = @('rm', '-f', (Quote-DeviceArgument $row.Path)) }
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments $arguments
        if ($result.Text.Trim()) {
            Write-Log ("$($row.Path): " + $result.Text.Trim()) $colorBad
        } else {
            Write-Log "deleted $($row.Path)" $colorWarn
        }
        # media files linger in MediaStore until it rescans
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
            'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $row.Path)
    }

    Update-FileList
}

function Open-FileOnPhone {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick a file first.' $colorWarn; return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content', 'call', '--uri', 'content://media', '--method', 'scan_file', '--arg', $rows[0].Path)
    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.intent.action.VIEW', '-d', ('file://' + $rows[0].Path))
    Write-Log ($result.Text.Trim()) $colorInfo
    Write-Log 'Android blocks file:// URIs for most apps; the phone may refuse to open it.' $colorWarn
}

function Copy-FilesPaths {
    $rows = @(Get-SelectedFiles)
    if ($rows.Count -eq 0) { Write-Log 'Pick something first.' $colorWarn; return }
    [System.Windows.Clipboard]::SetText((($rows | ForEach-Object { $_.Path }) -join [Environment]::NewLine))
    Write-Log "Copied $($rows.Count) path(s)." $colorInfo
}

# ------------------------------------------------------- page and phone ----

function Show-FilesPage {
    # opening the page reads the volumes, and the folder when the list is not this phone's
    $first = Get-SelectedDevice
    if ($null -eq $first -or $first.State -ne 'device') { return }
    Update-FileVolumes -Serial $first.Serial
    if ($script:filesSerial -ne $first.Serial) { Update-FileList }
}

function Clear-FilesList {
    # what was listed belonged to another phone
    $script:fileRows = @()
    $script:fileSearchResults = $false
    $script:fileItems.Clear()
    $script:fileBack.Clear()
    $script:fileForward.Clear()
    $script:filesSerial = $null
    $ui.FilesInfo.Text = ''
    $ui.FilesSpace.Text = ''
}

function Update-FilesForDevice {
    if ($ui.FilesTransfer.Visibility -eq 'Visible') { return }
    if ($script:filesSerial -and $script:filesSerial -eq (Get-SelectedSerial)) { return }
    if ($script:filesSerial) { Clear-FilesList }
    if (Test-PageShown -Key 'files') { Show-FilesPage }
}

# ----------------------------------------------------------------- events ----

$ui.FilesQuick.Items.Clear()
foreach ($entry in @('go to...', '/', '/sdcard', '/sdcard/Download', '/sdcard/DCIM/Camera', '/sdcard/Pictures', '/sdcard/Movies',
        '/sdcard/Music', '/sdcard/Documents', '/sdcard/Android/media', '/storage', '/sdcard/Android/data', '/data', '/data/local/tmp', '/system')) {
    $null = $ui.FilesQuick.Items.Add($entry)
}
$ui.FilesQuick.SelectedIndex = 0
$ui.FilesLocal.Text = [Environment]::GetFolderPath('MyDocuments')
$ui.FilesList.ItemsSource = $script:fileItems

$ui.FilesGo.Add_Click({ Update-FileList })
$ui.FilesUp.Add_Click({ Set-FileParent })
$ui.FilesDownload.Add_Click({ Save-DeviceFiles })
$ui.FilesUpload.Add_Click({ Send-DeviceFiles })
$ui.FilesNewDir.Add_Click({ New-DeviceDirectory })
$ui.FilesRename.Add_Click({ Rename-DeviceFile })
$ui.FilesDelete.Add_Click({ Remove-DeviceFiles })
$ui.FilesOpenPhone.Add_Click({ Open-FileOnPhone })
$ui.FilesMoveToPc.Add_Click({ Move-FilesToPc })
$ui.FilesMoveToPhone.Add_Click({ Move-FilesToPhone })
$ui.FilesCopyPath.Add_Click({ Copy-FilesPaths })
$ui.FilesCompress.Add_Click({ Compress-DeviceFiles })
$ui.FilesExtract.Add_Click({ Expand-DeviceArchive })
$ui.FilesPreview.Add_Click({ Show-DeviceFilePreview })
$ui.FilesSelectAll.Add_Click({ Set-FileSelection -Mode all })
$ui.FilesSelectNone.Add_Click({ Set-FileSelection -Mode none })
$ui.FilesSelectInvert.Add_Click({ Set-FileSelection -Mode invert })
$ui.FilesSearchHere.Add_Click({ Search-DeviceFiles })
$ui.FilesRecent.Add_Click({ Show-RecentFiles })
$ui.FilesSearchClear.Add_Click({ $ui.FilesSearch.Clear(); Update-FileList })
$ui.FilesLocalBrowse.Add_Click({
    $chosen = Select-Folder -Description 'Where downloads are saved on this PC' -Selected $ui.FilesLocal.Text
    if ($chosen) { $ui.FilesLocal.Text = $chosen }
})
$ui.FilesOpenLocal.Add_Click({
    if (Test-Path -LiteralPath $ui.FilesLocal.Text) { Start-Process explorer.exe $ui.FilesLocal.Text }
})
$ui.FilesCancel.Add_Click({
    $script:transferCancelled = $true
    $ui.FilesCancel.IsEnabled = $false
    Write-Log 'Stopping the transfer ...' $colorWarn
})

$ui.FilesPath.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Update-FileList }
})
$ui.FilesSearch.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Search-DeviceFiles }
})
# instant narrowing of what is already listed
$ui.FilesSearch.Add_TextChanged({ if (-not $script:fileSearchResults) { Show-FileRows } })

# not while settings are put back at startup: no phone has been read yet
$ui.FilesHidden.Add_Checked({ if ($script:devicesReadOnce) { Update-FileList } })
$ui.FilesHidden.Add_Unchecked({ if ($script:devicesReadOnce) { Update-FileList } })
$ui.FilesFoldersFirst.Add_Checked({ $script:fileFoldersFirst = $true; Show-FileRows })
$ui.FilesFoldersFirst.Add_Unchecked({ $script:fileFoldersFirst = $false; Show-FileRows })

$ui.FilesQuick.Add_SelectionChanged({
    if ($ui.FilesQuick.SelectedIndex -le 0) { return }
    $target = "$($ui.FilesQuick.SelectedItem)"
    $ui.FilesQuick.SelectedIndex = 0
    Update-FileList -Path $target
})

$ui.FilesList.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $eventArgs)
    $header = $eventArgs.OriginalSource
    if ($header -isnot [System.Windows.Controls.GridViewColumnHeader] -or $null -eq $header.Column) { return }
    Set-FilesSortColumn -Column $ui.FilesList.View.Columns.IndexOf($header.Column)
})
$ui.FilesList.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    if (Test-FilesRowHit -Source $eventArgs.OriginalSource) { Open-FileEntry }
})
$ui.FilesList.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $key = if ($eventArgs.Key -eq [System.Windows.Input.Key]::System) { $eventArgs.SystemKey } else { $eventArgs.Key }
    if (Invoke-FilesListKey -Key $key -Modifiers ([System.Windows.Input.Keyboard]::Modifiers)) { $eventArgs.Handled = $true }
})
# the two side buttons of the mouse, same as a browser; seen even when a row handled the click
$ui.FilesList.AddHandler([System.Windows.UIElement]::MouseUpEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::XButton1) {
        $eventArgs.Handled = $true
        Invoke-FileHistory -Direction back
    } elseif ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::XButton2) {
        $eventArgs.Handled = $true
        Invoke-FileHistory -Direction forward
    }
}, $true)

Add-ListContextMenu -List $ui.FilesList -Buttons @($ui.FilesPreview, $ui.FilesDownload, $ui.FilesMoveToPc, $null,
    $ui.FilesCompress, $ui.FilesExtract, $null,
    $ui.FilesRename, $ui.FilesDelete, $ui.FilesOpenPhone, $ui.FilesCopyPath, $null,
    $ui.FilesSelectAll, $ui.FilesSelectNone, $ui.FilesSelectInvert)

Register-Setting -Name 'Files.LocalFolder' -Get { $ui.FilesLocal.Text } -Set { param($v) if ("$v".Trim()) { $ui.FilesLocal.Text = "$v" } }
Register-Setting -Name 'Files.Hidden' -Get { [bool]$ui.FilesHidden.IsChecked } -Set { param($v) $ui.FilesHidden.IsChecked = [bool]$v }
Register-Setting -Name 'Files.FoldersFirst' -Get { [bool]$ui.FilesFoldersFirst.IsChecked } -Set { param($v) $ui.FilesFoldersFirst.IsChecked = [bool]$v }
Register-Setting -Name 'Files.RecentWindow' -Get { [int]$ui.FilesRecentWindow.SelectedIndex } -Set {
    param($v) if ([int]$v -ge 0 -and [int]$v -lt $ui.FilesRecentWindow.Items.Count) { $ui.FilesRecentWindow.SelectedIndex = [int]$v } }
Register-Setting -Name 'Files.Path' -Get { $script:filePath } -Set {
    param($v) if ("$v".StartsWith('/')) { $script:filePath = "$v"; $ui.FilesPath.Text = "$v" } }

# video and sound copied for the player are removed at exit
Register-Cleanup {
    foreach ($file in @($script:previewFiles)) {
        if ($file -and (Test-Path -LiteralPath $file)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            Write-Log "Removed the preview copy $file" $colorInfo
        }
    }
}
