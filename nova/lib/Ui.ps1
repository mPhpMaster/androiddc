<#
    AndroidDC Nova - the window's own helpers.

    Loading XAML and giving every named element a name in $ui, the page
    registry and the side navigation, the activity log, the device list and
    its header, dialogs and the toast, context menus, the busy strip, and the
    keys that work anywhere. Pages build on these; see CONTRACT.md.
#>

$script:ui = @{}
$script:app = $null
$script:window = $null
$script:pages = New-Object System.Collections.ArrayList
# A page is expensive to build - eighteen of them were three of the six seconds
# this window took to open - so each one waits until it is opened. What it says
# about itself is read from its own first lines, without running the file, so
# the side navigation is whole from the start.
$script:pageFiles = @{}          # key -> the file that builds that page
$script:pageOfFunction = @{}     # a function's name -> the page that defines it
$script:currentPage = $null
$script:cleanups = New-Object System.Collections.ArrayList
$script:logLines = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:deviceRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:deviceSignature = ''
$script:devicesReadOnce = $false
$script:logHeight = 190.0
$script:logFolded = $false
$script:statusSerial = $null
$script:restorePage = ''
# true once the window has opened its first page; from then on a page change is saved
$script:pageSaveReady = $false
$script:keepWindowPlace = $true
# the phone the three numbers at the foot were read from; reading one that was
# never assigned is an error under Set-StrictMode
$script:loadSerial = $null
$script:lastBattery = $null
$script:lastSignal = $null
$script:lastScreen = $null
$script:dialogAnswer = $null
$script:toastTimer = $null

# The log colours, by name. Pages ported from androiddc.ps1 pass these exactly
# as they did there: Write-Log 'text' $colorWarn.
$colorInfo = 'info'
$colorStep = 'step'
$colorGood = 'good'
$colorWarn = 'warn'
$colorBad = 'bad'

# ------------------------------------------------------------------- XAML ----

function Get-Resource {
    param([string]$Key)
    return $script:app.FindResource($Key)
}

function Import-Xaml {
    <#
        Parses a XAML file and puts every x:Name it declares into $ui. Names
        live in one table for the whole window, so a second element with the
        same name stops the program at startup instead of silently hiding
        the first. Names inside templates belong to the template, not the
        page, and FindName does not return them.
    #>
    param([string]$Path)

    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try {
        $root = [Windows.Markup.XamlReader]::Parse($text)
    } catch {
        throw "$(Split-Path -Leaf $Path): $($_.Exception.InnerException.Message) $($_.Exception.Message)"
    }
    foreach ($match in [regex]::Matches($text, '\bx:Name="([A-Za-z_][A-Za-z0-9_]*)"')) {
        $name = $match.Groups[1].Value
        $element = $root.FindName($name)
        if ($null -eq $element) { continue }
        if ($script:ui.ContainsKey($name) -and -not [object]::ReferenceEquals($script:ui[$name], $element)) {
            throw "x:Name '$name' in $(Split-Path -Leaf $Path) is already used elsewhere in the window"
        }
        $script:ui[$name] = $element
    }
    return $root
}

function Initialize-Ui {
    if ([System.Windows.Application]::Current) {
        $script:app = [System.Windows.Application]::Current
    } else {
        $script:app = New-Object System.Windows.Application
        $script:app.ShutdownMode = 'OnExplicitShutdown'
    }

    $theme = [Windows.Markup.XamlReader]::Parse(
        [IO.File]::ReadAllText((Join-Path $scriptRoot 'ui\Theme.xaml'), [Text.Encoding]::UTF8))

    # the design's own faces, when fonts\ holds them; Windows' Segoe otherwise
    $fonts = Join-Path $scriptRoot 'fonts'
    if (Test-Path -LiteralPath $fonts) {
        $base = New-Object System.Uri ((Resolve-Path -LiteralPath $fonts).Path.TrimEnd('\') + '\')
        # Remove + Add with the base object: assigned through the indexer, PowerShell
        # stores its wrapper around the FontFamily, and every element using the
        # key then failed with "'./#DM Sans, ...' is not a valid value"
        if (Get-ChildItem -LiteralPath $fonts -Filter 'SpaceGrotesk*' -ErrorAction SilentlyContinue) {
            $family = New-Object System.Windows.Media.FontFamily($base, './#Space Grotesk, Segoe UI Variable Display, Segoe UI')
            $theme.Remove('DisplayFont')
            $theme.Add('DisplayFont', $family.PSObject.BaseObject)
        }
        if (Get-ChildItem -LiteralPath $fonts -Filter 'DMSans*' -ErrorAction SilentlyContinue) {
            # Google's static DM Sans files carry "DM Sans 14pt" as their family
            # name (its optical size), and WPF finds the three weights only by that
            $family = New-Object System.Windows.Media.FontFamily($base, './#DM Sans 14pt, Segoe UI Variable Text, Segoe UI')
            $theme.Remove('BodyFont')
            $theme.Add('BodyFont', $family.PSObject.BaseObject)
        }
    }
    $script:app.Resources.MergedDictionaries.Add($theme)

    $script:window = Import-Xaml -Path (Join-Path $scriptRoot 'ui\Shell.xaml')
    # the project's own icon; nova\ has none of its own
    foreach ($folder in @($scriptRoot, $script:toolsRoot)) {
        $icon = Join-Path $folder 'assets\androiddc.ico'
        if (Test-Path -LiteralPath $icon) {
            try { $script:window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $icon)) } catch { }
            break
        }
    }

    $ui.LogList.ItemsSource = $script:logLines
    $ui.DeviceList.ItemsSource = $script:deviceRows
    $ui.SideVersion.Text = $script:appVersion
    # the way back to the classic window, only where that window is
    $ui.SideClassic.Visibility = if (Test-Path -LiteralPath (Get-ClassicLauncher) -PathType Leaf) { 'Visible' } else { 'Collapsed' }
}

function Get-ClassicLauncher {
    return (Join-Path $script:toolsRoot 'androiddc.vbs')
}

function Switch-ToClassic {
    # the same tool in the classic window: start it, then close this one the
    # normal way, so this window's settings are written
    $launcher = Get-ClassicLauncher
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-Log 'The classic window is not here: androiddc.vbs was not found in the project folder.' $colorWarn
        return
    }
    Write-Log 'Opening the classic AndroidDC window and closing this one ...' $colorStep
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $launcher + '"')
    $script:window.Close()
}

# ------------------------------------------------------------------ pages ----

function Register-Page {
    <#
        Adds a page: its XAML goes into the page area, hidden, and it gets a
        place in the side navigation under its section. OnShow runs each time
        it is opened, OnDeviceChanged each time another phone is picked
        (whether the page is on screen or not), Refresh is what F5 does there.
    #>
    param(
        [string]$Key, [string]$Title, [string]$Glyph,
        [ValidateSet('Workspace', 'Personal', 'Connect', 'System')][string]$Section,
        [string]$Xaml,
        [scriptblock]$OnShow, [scriptblock]$OnDeviceChanged, [scriptblock]$Refresh
    )

    $root = Import-Xaml -Path (Join-Path $scriptRoot "pages\$Xaml")
    $root.Visibility = 'Collapsed'
    $null = $ui.PageHost.Children.Add($root)

    $page = Get-Page -Key $Key
    if ($null -eq $page) {
        $page = [PSCustomObject]@{
            Key = $Key; Title = $Title; Glyph = $Glyph; Section = $Section; Root = $root
            OnShow = $OnShow; OnDeviceChanged = $OnDeviceChanged; Refresh = $Refresh; Nav = $null
            Loaded = $true
        }
        $null = $script:pages.Add($page)
        return $page
    }
    # a place was kept for it in the navigation before this file ran, and the
    # navigation item points at that very object: it is filled, not replaced
    $page.Root = $root
    $page.OnShow = $OnShow
    $page.OnDeviceChanged = $OnDeviceChanged
    $page.Refresh = $Refresh
    $page.Loaded = $true
    return $page
}

$script:sectionOrder = @('Workspace', 'Personal', 'Connect', 'System')

function Register-PageList {
    <#
        Every page gets a place in the navigation before any of them is built.
        What goes in that place - its name, its glyph, its section - is on the
        page's own Register-Page line, and that line is read here as text.

        Reading source to learn about it is worth saying out loud: it is done
        because the alternative is running all eighteen files, which is the
        three seconds this is here to save. audit.ps1 fails the build if a page
        stops saying those things in a shape this can read.
    #>
    param([string]$Folder, [string[]]$Names)

    foreach ($name in $Names) {
        $file = Join-Path $Folder "$name.ps1"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
        $said = Read-PageDeclaration -Text $text
        if (-not $said) {
            Write-Log "$name does not say what it is in a shape that can be read without running it." $colorWarn
            continue
        }
        $page = [PSCustomObject]@{
            Key = $said.Key; Title = $said.Title; Glyph = $said.Glyph; Section = $said.Section
            Root = $null; OnShow = $null; OnDeviceChanged = $null; Refresh = $null; Nav = $null
            Loaded = $false
        }
        $null = $script:pages.Add($page)
        $script:pageFiles[$said.Key] = $file
        # and which names it brings with it, so that a call to one of them from
        # somewhere else builds this page instead of failing
        foreach ($found in [regex]::Matches($text, '(?m)^function\s+([A-Za-z][A-Za-z0-9-]*)')) {
            $script:pageOfFunction[$found.Groups[1].Value] = $said.Key
        }
    }
}

function Read-PageDeclaration {
    # the four things the navigation needs, off a Register-Page line that may
    # be wrapped over two lines with a backtick
    param([string]$Text)

    $flat = $Text -replace '`\r?\n\s*', ' '
    $at = $flat.IndexOf('Register-Page')
    if ($at -lt 0) { return $null }
    $head = $flat.Substring($at, [Math]::Min(400, $flat.Length - $at))
    # only as far as the first block: a page's own OnDeviceChanged says things
    # like Test-PageShown -Key 'users', and that would answer for the
    # declaration while the declaration itself said nothing
    $block = $head.IndexOf('{')
    if ($block -gt 0) { $head = $head.Substring(0, $block) }
    $said = @{}
    foreach ($what in @('Key', 'Title', 'Glyph', 'Section')) {
        $found = [regex]::Match($head, "-$what\s+'([^']+)'")
        if (-not $found.Success) { return $null }
        $said[$what] = $found.Groups[1].Value
    }
    return [PSCustomObject]@{ Key = $said['Key']; Title = $said['Title']
        Glyph = $said['Glyph']; Section = $said['Section'] }
}

function Request-Page {
    <#
        Builds a page that has not been built yet.

        The file is dot-sourced here, so the functions it defines belong to
        this function - and are copied out to the global scope, which is where
        every other page and the window itself look for them. Its $script:
        variables land in this window's own scope, which is where the file
        would have put them had it been read at startup.
    #>
    param([string]$Key)

    $page = Get-Page -Key $Key
    if ($null -eq $page -or $page.Loaded) { return $page }
    if (-not $script:pageFiles.ContainsKey($Key)) { return $page }

    # marked before it is read, not after: a page whose file throws is said
    # once and not tried again on every click
    $page.Loaded = $true
    $hadFunction = @{}
    foreach ($one in Get-ChildItem function:) { $hadFunction[$one.Name] = $true }
    $hadVariable = @{}
    foreach ($one in Get-Variable -Scope 0) { $hadVariable[$one.Name] = $true }
    try {
        . $script:pageFiles[$Key]
    } catch {
        Write-Log ("The $($page.Title) page could not be built: " + $_.Exception.Message) $colorBad
    }
    foreach ($one in Get-ChildItem function:) {
        if (-not $hadFunction.ContainsKey($one.Name)) {
            Set-Item -Path "function:global:$($one.Name)" -Value $one.ScriptBlock
        }
    }
    # and the variables it set without a scope, which at startup would have
    # been the window's own: $automationPage and its like, which the window
    # reads back later
    foreach ($one in Get-Variable -Scope 0) {
        if (-not $hadVariable.ContainsKey($one.Name)) {
            Set-Variable -Name $one.Name -Value $one.Value -Scope Script
        }
    }
    return $page
}

function Initialize-PageLookup {
    <#
        Pages call each other: the Overview page's buttons alone reach into
        five others. When a name that belongs to a page that has not been built
        is called, the page is built and the call goes through - rather than
        the button saying the name is not recognized.
    #>
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = {
        param($CommandName, $lookup)
        if (-not $script:pageOfFunction.ContainsKey($CommandName)) { return }
        $null = Request-Page -Key $script:pageOfFunction[$CommandName]
        $found = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
        if ($found) {
            $lookup.Command = $found
            $lookup.StopSearch = $true
        }
    }
}

function Get-PagesInNavOrder {
    # as the side navigation lists them: by section, then as registered
    $ordered = @()
    foreach ($section in $script:sectionOrder) { $ordered += @($script:pages | Where-Object { $_.Section -eq $section }) }
    return $ordered
}

function Get-Page {
    # the page, or $null when no page has that key (indexing an empty result throws under StrictMode)
    param([string]$Key)
    foreach ($page in $script:pages) { if ($page.Key -eq $Key) { return $page } }
    return $null
}

function Test-PageShown {
    param([string]$Key)
    return ($null -ne $script:currentPage -and $script:currentPage.Key -eq $Key)
}

function Show-Page {
    param($Page)

    if ($Page -is [string]) { $Page = Get-Page -Key $Page }
    if (-not $Page) { return }
    if (-not $Page.Loaded) { $Page = Request-Page -Key $Page.Key }
    if (-not $Page.Root) { return }
    foreach ($entry in $script:pages) {
        # a page nobody has opened yet has nothing on screen to hide
        if (-not $entry.Root) { continue }
        $entry.Root.Visibility = if ([object]::ReferenceEquals($entry, $Page)) { 'Visible' } else { 'Collapsed' }
    }
    $changed = -not [object]::ReferenceEquals($script:currentPage, $Page)
    $script:currentPage = $Page
    if ($Page.Nav -and -not $Page.Nav.IsChecked) { $Page.Nav.IsChecked = $true }
    # Remembered at once, not only when the window closes: a window that Windows
    # ends at sign-out never closes normally, and it reopened on an old page
    if ($changed -and $script:pageSaveReady) { Save-Settings }
    if ($Page.OnShow -and $script:busy -eq 0) {
        try { & $Page.OnShow } catch { Write-Log ("$($Page.Title): " + $_.Exception.Message) $colorBad }
    }
}

function Complete-Shell {
    # the side navigation, in registration order, grouped by section
    $navStyle = Get-Resource 'NavItem'
    $capsStyle = Get-Resource 'Caps'
    $first = $true
    foreach ($section in $script:sectionOrder) {
        $inSection = @($script:pages | Where-Object { $_.Section -eq $section })
        if ($inSection.Count -eq 0) { continue }

        $caption = New-Object System.Windows.Controls.TextBlock
        $caption.Text = $section.ToUpperInvariant()
        $caption.Style = $capsStyle
        $caption.Margin = New-Object System.Windows.Thickness(8, $(if ($first) { 0 } else { 14 }), 0, 6)
        $null = $ui.NavHost.Children.Add($caption)
        $first = $false

        foreach ($page in $inSection) {
            $item = New-Object System.Windows.Controls.RadioButton
            $item.Style = $navStyle
            $item.GroupName = 'nav'
            $item.Content = $page.Title
            $item.Tag = [string][char][Convert]::ToInt32($page.Glyph, 16)
            $item.DataContext = $page
            $item.Add_Checked({
                param($sender, $eventArgs)
                if (-not [object]::ReferenceEquals($script:currentPage, $sender.DataContext)) { Show-Page -Page $sender.DataContext }
            })
            $page.Nav = $item
            $null = $ui.NavHost.Children.Add($item)
        }
    }

    Initialize-ShellEvents
}

function Register-Cleanup {
    # runs when the window closes, before settings are saved
    param([scriptblock]$Action)
    $null = $script:cleanups.Add($Action)
}

# -------------------------------------------------------------------- log ----

function Write-Log {
    param([string]$Message, [string]$Color = 'info')

    $key = switch ($Color) {
        'step' { 'Brand' } 'good' { 'Success' } 'warn' { 'Warning' } 'bad' { 'Danger' } default { 'Border' }
    }
    $brush = Get-Resource $key
    $last = $null
    foreach ($line in ($Message -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        # the time as a clock shows it; InvariantCulture so it is AM/PM on
        # every Windows, not the local word for it in a page written in English
        $last = [PSCustomObject]@{
            Time = (Get-Date).ToString('h:mm:ss tt', [System.Globalization.CultureInfo]::InvariantCulture)
            Text = $line; Brush = $brush; Kind = $Color }
        $script:logLines.Add($last)
    }
    # the log keeps the newest 3000 lines; the oldest go first
    while ($script:logLines.Count -gt 3000) { $script:logLines.RemoveAt(0) }
    if ($last -and $ui.ContainsKey('LogList')) { $ui.LogList.ScrollIntoView($last) }
}

function Get-LogText {
    return (@($script:logLines | ForEach-Object { "$($_.Time)  $($_.Text)" }) -join [Environment]::NewLine)
}

# ---------------------------------------------------------------- devices ----

function Get-SelectedDevice {
    # the first picked row, or $null. Not @(...)[0]: under StrictMode indexing an
    # empty array throws, and the selection is empty while the list is re-read.
    foreach ($row in $ui.DeviceList.SelectedItems) { return $row }
    return $null
}

function Get-SelectedSerial {
    $first = (Get-SelectedDevice)
    if ($null -eq $first) { return $null }
    return $first.Serial
}

function Get-SelectedSerials {
    # the ready ones among the phones picked; "All devices" picks every ready one
    if ($ui.AllDevices.IsChecked) {
        return @($script:deviceRows | Where-Object { $_.State -eq 'device' } | ForEach-Object { $_.Serial })
    }
    return @($ui.DeviceList.SelectedItems | Where-Object { $_.State -eq 'device' } | ForEach-Object { $_.Serial })
}

function Get-TargetSerial {
    $first = (Get-SelectedDevice)
    if ($null -eq $first) {
        Write-Log 'Select a device first.' $colorWarn
        return $null
    }
    if ($first.State -ne 'device') {
        Write-Log "Device $($first.Serial) is not ready ($($first.State))." $colorBad
        return $null
    }
    return $first.Serial
}

function Update-DeviceList {
    $previous = @($ui.DeviceList.SelectedItems | ForEach-Object { $_.Serial })
    $found = @(Get-AdbDevices)
    $script:deviceSignature = Get-DeviceSignature -Devices $found
    $script:devicesReadOnce = $true
    # a phone that just became ready gets its rule queued (the Automation page)
    if (Get-Command Register-AutomationArrivals -ErrorAction SilentlyContinue) {
        $null = Register-AutomationArrivals -Devices $found
    }

    $rows = @()
    foreach ($device in $found) {
        $installed = '-'
        $release = '-'
        $name = $device.Model -replace '_', ' '
        $maker = ''
        if ($device.State -eq 'device') {
            # the name people know the phone by, when the ROM says it ("Redmi Note 13"
            # rather than "23108RN04Y"); the model code otherwise
            # the name and the make in one trip: a model code like 23108RN04Y
            # says nothing about either
            $said = @((Invoke-DeviceShell -Serial $device.Serial -CommandArguments @(
                'getprop ro.product.marketname; getprop ro.product.vendor.marketname; ' +
                'getprop ro.product.manufacturer')).Lines | ForEach-Object { "$_".Trim() })
            $market = @(@($said)[0..1] | Where-Object { $_ }) | Select-Object -First 1
            if ($market) { $name = $market }
            if (@($said).Count -gt 2) { $maker = "$(@($said)[2])" }
            $check = Invoke-DeviceShell -Serial $device.Serial -CommandArguments @('pm', 'list', 'packages', $script:packageName)
            $installed = if ($check.Text -match [regex]::Escape("package:$script:packageName")) { 'yes' } else { 'no' }
            $release = (Invoke-DeviceShell -Serial $device.Serial -CommandArguments @('getprop', 'ro.build.version.release')).Text.Trim()
            if (-not $release) { $release = '-' }
        }
        $rows += [PSCustomObject]@{
            Serial = $device.Serial; Link = $device.Link; Model = $name
            Android = $release; State = $device.State; Client = $installed; Maker = $maker
        }
    }

    $script:deviceRows.Clear()
    foreach ($row in $rows) { $script:deviceRows.Add($row) }
    foreach ($row in $script:deviceRows) {
        if ($previous -contains $row.Serial) { $null = $ui.DeviceList.SelectedItems.Add($row) }
    }
    if ($ui.DeviceList.SelectedItems.Count -eq 0 -and $script:deviceRows.Count -gt 0) { $ui.DeviceList.SelectedIndex = 0 }

    $ready = @($script:deviceRows | Where-Object { $_.State -eq 'device' }).Count
    $ui.SideDevices.Text = if ($script:deviceRows.Count -eq $ready) { "$ready" } else { "$ready of $($script:deviceRows.Count)" }
    if ($script:deviceRows.Count -eq 0) {
        Write-Log 'No device detected. Plug the phone in, enable USB debugging and accept the RSA prompt.' $colorWarn
        Update-DeviceHeader
    }
}

function Test-DeviceListChanged {
    # a phone plugged in, pulled out, or one whose RSA prompt was just accepted
    return ((Get-DeviceSignature -Devices @(Get-AdbDevices)) -ne $script:deviceSignature)
}

function Set-StatusPill {
    # a pill in the header: its text, and a tone - ok, warn or plain
    param($Pill, $TextBlock, [string]$Text, [string]$Tone = 'plain')

    if (-not $Text) { $Pill.Visibility = 'Collapsed'; return }
    $Pill.Visibility = 'Visible'
    $TextBlock.Text = $Text
    switch ($Tone) {
        'ok' { $Pill.Background = Get-Resource 'SuccessSoft'; $TextBlock.Foreground = Get-Resource 'Success' }
        'warn' { $Pill.Background = Get-Resource 'WarningSoft'; $TextBlock.Foreground = Get-Resource 'Warning' }
        default { $Pill.Background = Get-Resource 'Muted'; $TextBlock.Foreground = Get-Resource 'MutedText' }
    }
}

# Get-DeviceMake and Get-DeviceLoad are in shared\DeviceFacts.ps1, because the
# classic window shows the same two readings in its own way.
function Update-DeviceMark {
    # the square beside the phone's name: its make, or the plain phone glyph
    param($Device)

    $make = $null
    if ($Device -and (Get-Command Get-DeviceMake -ErrorAction SilentlyContinue)) {
        $maker = $(if ($Device.PSObject.Properties['Maker']) { "$($Device.Maker)" } else { '' })
        $make = Get-DeviceMake -Model "$($Device.Model)" -Serial "$($Device.Serial)" -Maker $maker
    }
    if (-not $make) {
        $ui.DeviceMarkLetter.Visibility = 'Collapsed'
        $ui.DeviceMarkGlyph.Visibility = 'Visible'
        $ui.DeviceMarkBox.Background = Get-Resource 'Surface'
        $ui.DeviceMarkBox.ToolTip = $null
        return
    }
    $ui.DeviceMarkGlyph.Visibility = 'Collapsed'
    $ui.DeviceMarkLetter.Text = $make.Letter
    $ui.DeviceMarkLetter.Visibility = 'Visible'
    try {
        $ui.DeviceMarkBox.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($make.Color))
    } catch {
        $ui.DeviceMarkBox.Background = Get-Resource 'Brand'
    }
    $ui.DeviceMarkBox.ToolTip = $make.Name
}

function Invoke-PageRefresh {
    # what F5 does, and what the logo does when Overview is already on screen:
    # the page's own Refresh, or the device list for a page that has none
    if ($script:busy -gt 0) { return }
    if ($script:currentPage -and $script:currentPage.Refresh) { & $script:currentPage.Refresh }
    else { Update-DeviceList }
}

function Update-DeviceHeader {
    # the title and the line under it, from the list alone - no trip to the phone
    $first = (Get-SelectedDevice)
    $count = @($ui.DeviceList.SelectedItems).Count
    Update-DeviceMark -Device $first
    if ($null -eq $first) {
        $ui.DeviceTitle.Text = if ($script:deviceRows.Count -eq 0) { 'No device' } else { 'Pick a device' }
        $ui.DeviceSubtitle.Text = if ($script:deviceRows.Count -eq 0) { 'Plug a phone in with USB debugging on' } else { "$($script:deviceRows.Count) attached" }
        foreach ($pill in @('PillBattery', 'PillSignal', 'PillScreen', 'PillFtp', 'PillClipboard')) { $ui[$pill].Visibility = 'Collapsed' }
        return
    }
    $ui.DeviceTitle.Text = $first.Model
    $parts = @()
    if ($first.Android -and $first.Android -ne '-') { $parts += "Android $($first.Android)" }
    $parts += $first.Link.ToUpperInvariant()
    $parts += $first.Serial
    if ($first.State -ne 'device') { $parts += $first.State }
    if ($count -gt 1) { $parts += "+$($count - 1) more selected" }
    if ($ui.AllDevices.IsChecked) { $parts += 'all devices' }
    # a middle dot between the parts; built from its code point, this file stays ASCII
    $ui.DeviceSubtitle.Text = $parts -join ('  ' + [char]0x00B7 + '  ')
}

function Get-LoadBrush {
    # what a number of that size should look like: quiet until it is worth
    # looking at, orange when it is busy, red when it is nearly full
    param([int]$Percent)

    if ($Percent -lt 0) { return (Get-Resource 'MutedText') }
    if ($Percent -ge 90) { return (Get-Resource 'Danger') }
    if ($Percent -ge 70) { return (Get-Resource 'Warning') }
    return (Get-Resource 'Ink')
}

function Update-DeviceLoad {
    # the three lines at the foot of the side bar, read on their own slow timer
    param([switch]$Force)

    $first = (Get-SelectedDevice)
    if ($null -eq $first -or $first.State -ne 'device') {
        foreach ($row in @('SideCpuRow', 'SideRamRow', 'SideGpuRow')) { $ui[$row].Visibility = 'Collapsed' }
        $script:loadSerial = $null
        return
    }
    if (-not $Force -and $script:busy -gt 0) { return }
    if (-not (Get-Command Get-DeviceLoad -ErrorAction SilentlyContinue)) { return }
    $serial = $first.Serial
    $load = Get-DeviceLoad -Serial $serial
    if ((Get-SelectedSerial) -ne $serial) { return }
    $script:loadSerial = $serial

    $ui.SideCpu.Text = $(if ("$($load.Cpu)") { $load.Cpu } else { '-' })
    $ui.SideRam.Text = $(if ("$($load.Ram)") { $load.Ram } else { '-' })
    $ui.SideGpu.Text = $load.Gpu
    foreach ($row in @('SideCpuRow', 'SideRamRow', 'SideGpuRow')) { $ui[$row].Visibility = 'Visible' }
    # the colour is the number: a phone with no memory left, or a processor at
    # full stretch, explains half of what then goes slowly
    $ui.SideCpu.Foreground = Get-LoadBrush -Percent $load.CpuUsed
    $ui.SideRam.Foreground = Get-LoadBrush -Percent $load.RamUsed
    $ui.SideGpu.Foreground = Get-LoadBrush -Percent $load.GpuUsed
}

function Update-DeviceStatus {
    # battery, signal and screen for the header pills; one phone, the first picked
    Update-DeviceHeader
    $first = (Get-SelectedDevice)
    if ($null -eq $first -or $first.State -ne 'device') {
        foreach ($pill in @('PillBattery', 'PillSignal', 'PillScreen', 'PillFtp', 'PillClipboard')) { $ui[$pill].Visibility = 'Collapsed' }
        $ui.SideScreenRow.Visibility = 'Collapsed'
        $script:statusSerial = $null
        return
    }
    $serial = $first.Serial
    $battery = Get-BatteryInfo -Serial $serial
    $signal = Get-SignalInfo -Serial $serial
    $screen = Get-DeviceScreenState -Serial $serial
    # another phone may have been picked while those were read
    if ((Get-SelectedSerial) -ne $serial) { return }
    $script:statusSerial = $serial
    $script:lastBattery = $battery
    $script:lastSignal = $signal
    $script:lastScreen = $screen

    $level = if ($null -ne $battery.Level) { "$($battery.Level)%" } else { '?' }
    $batteryText = "$level  $($battery.Status)"
    $tone = if ($null -ne $battery.Level -and $battery.Level -le 15 -and $battery.Status -ne 'charging') { 'warn' } else { 'plain' }
    Set-StatusPill $ui.PillBattery $ui.PillBatteryText $batteryText $tone
    $ui.PillBattery.ToolTip = $battery.Line

    $signalText = if ($signal.NoSim) { 'no SIM' } elseif ($null -ne $signal.Level) { "$($signal.Network -replace ',.*$', '')  $($signal.Level)/4" } else { 'signal unknown' }
    Set-StatusPill $ui.PillSignal $ui.PillSignalText $signalText 'plain'
    $ui.PillSignal.ToolTip = $signal.Line

    $screenWords = @()
    if ($null -ne $screen.ScreenOn) { $screenWords += $(if ($screen.ScreenOn) { 'screen on' } else { 'screen off' }) }
    if ($null -ne $screen.Locked) { $screenWords += $(if ($screen.Locked) { 'locked' } else { 'unlocked' }) }
    # a phone that is locked or dark explains half the things that then fail
    $screenTone = if ($screen.Locked -or ($null -ne $screen.ScreenOn -and -not $screen.ScreenOn)) { 'warn' } else { 'ok' }
    Set-StatusPill $ui.PillScreen $ui.PillScreenText ($screenWords -join ', ') $screenTone
    # and at the foot of the side bar, where it is read from every page
    # "screen on, unlocked" beside a label that already says Screen is twice the
    # same word, and twice the width the side bar has
    $ui.SideScreen.Text = $(if ($screenWords.Count -gt 0) { ($screenWords -join ', ') -replace 'screen ', '' } else { '-' })
    $ui.SideScreen.ToolTip = ($screenWords -join ', ')
    $ui.SideScreen.Foreground = $(if ($screenTone -eq 'warn') { Get-Resource 'Warning' } else { Get-Resource 'Ink' })
    $ui.SideScreenRow.Visibility = 'Visible'
    if (Get-Command Update-FtpHeader -ErrorAction SilentlyContinue) { Update-FtpHeader }
    if (Get-Command Update-ClipboardHeader -ErrorAction SilentlyContinue) { Update-ClipboardHeader }
    # the three numbers under these, read now rather than when their own timer
    # next comes round - a phone just picked should not show the last one's
    if ($serial -ne $script:loadSerial) { Update-DeviceLoad }
}

# --------------------------------------------------------------- dialogs ----

function New-DialogWindow {
    param([string]$Title, [int]$Width = 460)

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="Height" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="{StaticResource BodyFont}" FontSize="13" Foreground="{StaticResource Ink}">
  <Border Margin="20" Style="{StaticResource CardPanel}" Padding="22,20" Effect="{StaticResource PanelShadow}">
    <StackPanel>
      <TextBlock x:Name="DialogTitle" Style="{StaticResource H1}" FontSize="16" Margin="0,0,0,12" TextWrapping="Wrap"/>
      <ScrollViewer x:Name="DialogScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="DialogBody"/>
      </ScrollViewer>
      <StackPanel x:Name="DialogButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Parse($xaml)
    $dialog.Width = $Width + 40
    # A dialog is as tall as what is in it, and what is in it may be a list of
    # fourteen hundred contacts: it grew past the screen and took its own
    # buttons with it, so the question could not be answered at all. The body
    # scrolls instead, which keeps the title and the buttons where they are.
    $dialog.FindName('DialogScroll').MaxHeight = [int]([System.Windows.SystemParameters]::WorkArea.Height * 0.6)
    $dialog.FindName('DialogTitle').Text = $Title
    if ($script:window -and $script:window.IsVisible) { $dialog.Owner = $script:window } else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $dialog.Add_MouseLeftButtonDown({ param($sender, $eventArgs) try { $sender.DragMove() } catch { } })
    return $dialog
}

function Add-DialogButton {
    param($Dialog, [string]$Text, [string]$Style = '', [scriptblock]$OnClick, [switch]$IsDefault, [switch]$IsCancel)

    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.MinWidth = 96
    $button.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    if ($Style) { $button.Style = Get-Resource $Style }
    $button.IsDefault = [bool]$IsDefault
    $button.IsCancel = [bool]$IsCancel
    if ($OnClick) { $button.Add_Click($OnClick) }
    $null = $Dialog.FindName('DialogButtons').Children.Add($button)
    return $button
}

function Add-DialogText {
    param($Dialog, [string]$Text, [switch]$Muted)

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.TextWrapping = 'Wrap'
    $block.LineHeight = 20
    $block.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    if ($Muted) { $block.Foreground = Get-Resource 'MutedText' }
    $null = $Dialog.FindName('DialogBody').Children.Add($block)
    return $block
}

function Show-Confirm {
    # a question with two answers; true only for the first
    param([string]$Title, [string]$Text, [string]$Yes = 'OK', [string]$No = 'Cancel', [switch]$Danger)

    $dialog = New-DialogWindow -Title $Title
    $null = Add-DialogText -Dialog $dialog -Text $Text
    $script:dialogAnswer = $false
    $null = Add-DialogButton -Dialog $dialog -Text $No -IsCancel -OnClick { param($s, $e) [System.Windows.Window]::GetWindow($s).Close() }
    $style = if ($Danger) { 'DangerButton' } else { 'Primary' }
    $null = Add-DialogButton -Dialog $dialog -Text $Yes -Style $style -IsDefault:(-not $Danger) -OnClick {
        param($s, $e) $script:dialogAnswer = $true; [System.Windows.Window]::GetWindow($s).Close() }
    $null = $dialog.ShowDialog()
    return [bool]$script:dialogAnswer
}

function Show-Notice {
    param([string]$Title, [string]$Text)

    $dialog = New-DialogWindow -Title $Title
    $null = Add-DialogText -Dialog $dialog -Text $Text
    $null = Add-DialogButton -Dialog $dialog -Text 'OK' -Style 'Primary' -IsDefault -IsCancel -OnClick {
        param($s, $e) [System.Windows.Window]::GetWindow($s).Close() }
    $null = $dialog.ShowDialog()
}

function Show-InputDialog {
    <#
        One box per field; returns the texts in field order, or $null when
        cancelled. -Secret names the fields whose text is hidden, -Hint adds
        a grey line above the boxes, -Multiline names fields that take lines.
    #>
    param([string]$Title, [string[]]$Fields, [string[]]$Values, [string]$Hint, [string[]]$Secret = @(),
        [string[]]$Multiline = @(), [string]$OkText = 'OK')

    $dialog = New-DialogWindow -Title $Title
    $body = $dialog.FindName('DialogBody')
    if ($Hint) { $null = Add-DialogText -Dialog $dialog -Text $Hint -Muted }

    $boxes = @()
    for ($i = 0; $i -lt $Fields.Count; $i++) {
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $Fields[$i]
        $label.Style = Get-Resource 'FieldLabel'
        $label.Margin = New-Object System.Windows.Thickness(0, $(if ($i -eq 0) { 0 } else { 10 }), 0, 5)
        $null = $body.Children.Add($label)

        if ($Secret -contains $Fields[$i]) {
            $box = New-Object System.Windows.Controls.PasswordBox
            if ($Values -and $i -lt $Values.Count) { $box.Password = $Values[$i] }
        } else {
            $box = New-Object System.Windows.Controls.TextBox
            if ($Values -and $i -lt $Values.Count) { $box.Text = $Values[$i] }
            if ($Multiline -contains $Fields[$i]) {
                $box.AcceptsReturn = $true
                $box.TextWrapping = 'Wrap'
                $box.MinHeight = 90
                $box.VerticalContentAlignment = 'Top'
            }
        }
        $null = $body.Children.Add($box)
        $boxes += $box
    }

    $script:dialogAnswer = $false
    $null = Add-DialogButton -Dialog $dialog -Text 'Cancel' -IsCancel -OnClick { param($s, $e) [System.Windows.Window]::GetWindow($s).Close() }
    $null = Add-DialogButton -Dialog $dialog -Text $OkText -Style 'Primary' -IsDefault -OnClick {
        param($s, $e) $script:dialogAnswer = $true; [System.Windows.Window]::GetWindow($s).Close() }
    if ($boxes.Count -gt 0) { $dialog.Add_ContentRendered({ param($s, $e) $null = $boxes[0].Focus() }.GetNewClosure()) }
    $null = $dialog.ShowDialog()

    if (-not $script:dialogAnswer) { return $null }
    # the comma keeps a one-field answer an array: returned bare, PowerShell
    # unrolls it into a string, and $answer[0] was then its first letter
    return ,@($boxes | ForEach-Object { if ($_ -is [System.Windows.Controls.PasswordBox]) { $_.Password } else { $_.Text } })
}

function Show-Choice {
    # one of several named answers, or $null
    param([string]$Title, [string]$Text, [string[]]$Choices)

    $dialog = New-DialogWindow -Title $Title
    if ($Text) { $null = Add-DialogText -Dialog $dialog -Text $Text }
    $script:dialogAnswer = $null
    $null = Add-DialogButton -Dialog $dialog -Text 'Cancel' -IsCancel -OnClick { param($s, $e) [System.Windows.Window]::GetWindow($s).Close() }
    foreach ($choice in $Choices) {
        $button = Add-DialogButton -Dialog $dialog -Text $choice -OnClick {
            param($s, $e) $script:dialogAnswer = $s.Content; [System.Windows.Window]::GetWindow($s).Close() }
    }
    $null = $dialog.ShowDialog()
    return $script:dialogAnswer
}

function Show-Toast {
    # the short note at the top right that something worked; the log keeps the detail
    param([string]$Text, [string]$Color = 'good')

    $glyph = switch ($Color) { 'bad' { 0xEA39 } 'warn' { 0xE7BA } 'step' { 0xE946 } default { 0xE930 } }
    $brush = switch ($Color) { 'bad' { 'Danger' } 'warn' { 'Warning' } 'step' { 'Brand' } default { 'Success' } }
    $ui.ToastGlyph.Text = [string][char]$glyph
    $ui.ToastGlyph.Foreground = Get-Resource $brush
    $ui.ToastText.Text = $Text
    $ui.Toast.Visibility = 'Visible'
    $script:toastTimer.Stop()
    $script:toastTimer.Start()
}

function Invoke-ButtonClick {
    # raises Click whether or not the button's page is on screen
    param($Button)
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $Button)))
}

function Get-ButtonCaption {
    <#
        The words for a button: its text, or its tooltip when it shows a glyph.

        A button may carry a panel instead of a word - a glyph beside a label,
        which is how the primary button on several pages is built - and
        "$($Button.Content)" on one of those is the name of its type. The
        Contacts menu opened with 'System.Windows.Controls.StackPanel' where
        'Call' belonged.
    #>
    param($Button)

    $content = $Button.Content
    if ($content -is [System.Windows.Controls.Panel]) {
        # the label beside the glyph, which is the first piece of text on it
        # that is not from the icon font's private range
        foreach ($child in $content.Children) {
            if (-not ($child -is [System.Windows.Controls.TextBlock])) { continue }
            $said = "$($child.Text)"
            if (-not $said) { continue }
            if ([int][char]$said[0] -ge 0xE000) { continue }
            return $said.Replace('...', '').Trim()
        }
        return "$($Button.ToolTip)"
    }
    $words = "$content"
    if ($words -and [int][char]$words[0] -lt 0xE000) { return $words.Replace('...', '').Trim() }
    return "$($Button.ToolTip)"
}

function Add-ListContextMenu {
    # the same actions as the buttons that act on a list, on the right mouse button
    param($List, $Buttons)

    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($button in $Buttons) {
        if ($null -eq $button) {
            $null = $menu.Items.Add((New-Object System.Windows.Controls.Separator))
            continue
        }
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = Get-ButtonCaption -Button $button
        $item.Tag = $button
        $item.Add_Click({ param($sender, $eventArgs) Invoke-ButtonClick -Button $sender.Tag })
        $null = $menu.Items.Add($item)
    }
    $menu.Add_Opened({
        param($sender, $eventArgs)
        foreach ($item in $sender.Items) { if ($item -is [System.Windows.Controls.MenuItem]) { $item.IsEnabled = $item.Tag.IsEnabled } }
    })
    $List.ContextMenu = $menu
}

function Copy-ListSelection {
    # the selected rows of a list, one per line, columns separated by tabs
    param($List)

    $rows = @($List.SelectedItems)
    if ($rows.Count -eq 0) { Write-Log 'Select one or more rows first.' $colorWarn; return }
    $paths = @($List.View.Columns | ForEach-Object {
        if ($_.DisplayMemberBinding) { $_.DisplayMemberBinding.Path.Path } elseif ($_.Header -is [System.Windows.Controls.GridViewColumnHeader] -and $_.Header.Tag) { "$($_.Header.Tag)" } else { $null }
    } | Where-Object { $_ })
    $lines = foreach ($row in $rows) {
        (@($paths | ForEach-Object { if ($row.PSObject.Properties[$_]) { "$($row.$_)" } else { '' } }) -join "`t")
    }
    [System.Windows.Clipboard]::SetText(($lines -join [Environment]::NewLine))
    Write-Log "Copied $($rows.Count) row(s) to the clipboard." $colorInfo
}

function Set-ListFilter {
    # shows only the rows the script block accepts; $null shows every row again
    param($List, [scriptblock]$Accept)

    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($List.ItemsSource)
    if (-not $view) { return }
    if ($Accept) { $view.Filter = [Predicate[object]]$Accept } else { $view.Filter = $null }
}

function Get-NumberValue {
    # a text box used as a number box: the value, kept within its limits and written back
    param($Box, [int]$Default, [int]$Minimum = [int]::MinValue, [int]$Maximum = [int]::MaxValue)

    $value = $Default
    $parsed = 0
    if ([int]::TryParse("$($Box.Text)".Trim(), [ref]$parsed)) { $value = $parsed }
    $value = [Math]::Max($Minimum, [Math]::Min($Maximum, $value))
    if ("$($Box.Text)".Trim() -ne "$value") { $Box.Text = "$value" }
    return $value
}

function Select-SaveFile {
    # a Save As dialog; the chosen path, or $null
    param([string]$Filter = 'All files (*.*)|*.*', [string]$FileName = '', [string]$InitialDirectory = '')

    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = $Filter
    $dialog.FileName = $FileName
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($script:window)) { return $dialog.FileName }
    return $null
}

function Select-OpenFiles {
    # an Open dialog; the chosen paths (one or several), or an empty list
    param([string]$Filter = 'All files (*.*)|*.*', [switch]$Multiselect, [string]$InitialDirectory = '')

    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = $Filter
    $dialog.Multiselect = [bool]$Multiselect
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($script:window)) { return @($dialog.FileNames) }
    return @()
}

function Select-Folder {
    # a folder picker (WPF has none of its own); the chosen folder, or $null
    param([string]$Description = 'Pick a folder', [string]$Selected = '')

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if ($Selected -and (Test-Path -LiteralPath $Selected)) { $dialog.SelectedPath = $Selected }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return $null
}

function Set-ListColumnsSortable {
    # a click on a column header sorts by it; a second click reverses
    param($List)

    $List.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        $header = $eventArgs.OriginalSource
        if ($header -isnot [System.Windows.Controls.GridViewColumnHeader] -or -not $header.Column) { return }
        $binding = $header.Column.DisplayMemberBinding
        $path = if ($binding) { $binding.Path.Path } elseif ($header.Column.Header -is [string]) { $null } else { $null }
        if (-not $path -and $header.Tag) { $path = "$($header.Tag)" }
        if (-not $path) { return }
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($sender.ItemsSource)
        if (-not $view) { return }
        $direction = 'Ascending'
        if ($view.SortDescriptions.Count -gt 0 -and $view.SortDescriptions[0].PropertyName -eq $path -and
            $view.SortDescriptions[0].Direction -eq 'Ascending') { $direction = 'Descending' }
        $view.SortDescriptions.Clear()
        $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($path, $direction)))
    })
}

# ----------------------------------------------------------- busy strip ----

function Update-BusyIndicator {
    if ($script:busy -gt 0) {
        # a call that ends within 400 ms is not worth a flicker
        if (-not $script:busySince) { $script:busySince = [DateTime]::Now; return }
        if (([DateTime]::Now - $script:busySince).TotalMilliseconds -lt 400) { return }
        $text = if ($script:busyWhat) { $script:busyWhat } else { 'working ...' }
        $ui.BusyText.Text = $text
        $ui.BusyText.ToolTip = $text
        if ($ui.BusyStrip.Visibility -ne 'Visible') {
            $ui.BusyStrip.Visibility = 'Visible'
            $script:window.Cursor = [System.Windows.Input.Cursors]::AppStarting
        }
        # Cancel belongs to a run that can be stopped between its steps, which
        # is what Start-BackupRun marks. A single adb call is not one of those
        # and gets no button it could not honour: deleting a phone's worth of
        # contacts went on for minutes with no way to stop it.
        $canStop = $(if (Get-Command Test-BackupRunning -ErrorAction SilentlyContinue) { Test-BackupRunning } else { $false })
        $ui.BusyCancel.Visibility = $(if ($canStop) { 'Visible' } else { 'Collapsed' })
    } else {
        $script:busySince = $null
        if ($ui.BusyStrip.Visibility -eq 'Visible') {
            $ui.BusyStrip.Visibility = 'Hidden'
            $ui.BusyCancel.Visibility = 'Collapsed'
            $script:window.Cursor = $null
        }
    }
}

function Set-SharingState {
    # the pill in the log header and the line in the sidebar: the internet sharing only
    param([string]$Target)

    if ($Target) {
        $ui.SharingText.Text = "Sharing: $Target"
        $ui.SharingDot.Fill = Get-Resource 'Success'
        $ui.SharingPill.Background = Get-Resource 'SuccessSoft'
        $ui.SideSharing.Text = 'On'
        $ui.SideSharing.Foreground = Get-Resource 'Success'
    } else {
        $ui.SharingText.Text = 'Sharing: off'
        $ui.SharingDot.Fill = Get-Resource 'MutedText'
        $ui.SharingPill.Background = Get-Resource 'Muted'
        $ui.SideSharing.Text = 'Off'
        $ui.SideSharing.Foreground = Get-Resource 'MutedText'
    }
}

function Set-LogFolded {
    param([bool]$Folded)

    if ($Folded -and -not $script:logFolded -and $ui.LogRow.Height.Value -gt 0) { $script:logHeight = $ui.LogRow.Height.Value }
    $script:logFolded = $Folded
    if ($Folded) {
        $ui.LogRow.Height = New-Object System.Windows.GridLength(46)
        $ui.LogList.Visibility = 'Collapsed'
        $ui.LogSplitter.Visibility = 'Collapsed'
        $ui.LogFold.Content = [string][char]0xE70E
        $ui.LogFold.ToolTip = 'Show the log again'
    } else {
        $ui.LogRow.Height = New-Object System.Windows.GridLength([Math]::Max(120, $script:logHeight))
        $ui.LogList.Visibility = 'Visible'
        $ui.LogSplitter.Visibility = 'Visible'
        $ui.LogFold.Content = [string][char]0xE70D
        $ui.LogFold.ToolTip = 'Fold the log away and give its room to the page'
    }
}

# ------------------------------------------------------------ the keys ----

function Invoke-WindowKey {
    # keys that work wherever the focus is; true when the key was used
    param([System.Windows.Input.Key]$Key, [System.Windows.Input.ModifierKeys]$Modifiers)

    # compared as numbers and members: the enum's text converter does not know
    # "None", so -eq 'None' threw on every F5
    $none = [int]$Modifiers -eq 0
    $control = $Modifiers -eq [System.Windows.Input.ModifierKeys]::Control
    if ($Key -eq [System.Windows.Input.Key]::F5 -and $none) {
        # never on top of a call still running: F5 held down would stack them
        if ($script:busy -gt 0) { return $true }
        Invoke-PageRefresh
        return $true
    }
    if ($control -and $Key -ge [System.Windows.Input.Key]::D1 -and $Key -le [System.Windows.Input.Key]::D9) {
        $index = [int]$Key - [int][System.Windows.Input.Key]::D1
        $ordered = @(Get-PagesInNavOrder)
        if ($index -lt $ordered.Count) { Show-Page -Page $ordered[$index] }
        return $true
    }
    if ($control -and $Key -eq [System.Windows.Input.Key]::L) {
        $script:logLines.Clear()
        return $true
    }
    return $false
}

# ------------------------------------------------------------ automation ----

function Test-DialogOpen {
    # one of this program's dialogs is on screen (a question is waiting there)
    foreach ($other in $script:app.Windows) {
        if (-not [object]::ReferenceEquals($other, $script:window) -and $other.IsVisible) { return $true }
    }
    return $false
}

function Enter-AutomationDevice {
    # selects a rule's phone so the actions act on it alone; $false when that
    # phone is not ready in the list. Returns what Exit-AutomationDevice puts back.
    param([string]$Serial)

    $target = $null
    foreach ($row in $script:deviceRows) { if ($row.Serial -eq $Serial -and $row.State -eq 'device') { $target = $row } }
    if ($null -eq $target) { return $false }
    $state = [PSCustomObject]@{ All = [bool]$ui.AllDevices.IsChecked }
    $ui.AllDevices.IsChecked = $false
    $ui.DeviceList.SelectedItems.Clear()
    $null = $ui.DeviceList.SelectedItems.Add($target)
    Wait-Pumped -Milliseconds 300
    return $state
}

function Exit-AutomationDevice {
    param($State)
    if ($null -ne $State -and $State -isnot [bool]) {
        $ui.AllDevices.IsChecked = $State.All
        Update-DeviceHeader
    }
}

# ---------------------------------------------------------- shell events ----

function Initialize-ShellEvents {
    $script:toastTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:toastTimer.Interval = [TimeSpan]::FromMilliseconds(2800)
    $script:toastTimer.Add_Tick({ $script:toastTimer.Stop(); $ui.Toast.Visibility = 'Collapsed' })
    $ui.ToastClose.Add_Click({ $script:toastTimer.Stop(); $ui.Toast.Visibility = 'Collapsed' })

    $script:busyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:busyTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:busyTimer.Add_Tick({ Update-BusyIndicator })

    # picking another phone: wait for the clicks to settle, then read it once
    $script:deviceChangeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:deviceChangeTimer.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:deviceChangeTimer.Add_Tick({
        if ($script:busy -gt 0) { return }
        $script:deviceChangeTimer.Stop()
        Update-DeviceStatus
        foreach ($page in @($script:pages)) {
            # one that has not been built has no rows to clear; it reads the
            # phone that is picked when it is opened
            if (-not $page.Loaded) { continue }
            if (-not $page.OnDeviceChanged) { continue }
            try { & $page.OnDeviceChanged } catch { Write-Log ("$($page.Title): " + $_.Exception.Message) $colorBad }
        }
    })
    $ui.DeviceList.Add_SelectionChanged({
        Update-DeviceHeader
        $script:deviceChangeTimer.Stop()
        $script:deviceChangeTimer.Start()
    })
    $ui.AllDevices.Add_Click({ Update-DeviceHeader })
    $ui.DeviceList.Add_MouseDoubleClick({ $ui.DevicePickerToggle.IsChecked = $false })

    # the list follows the cable: adb devices is cheap, the full read happens
    # only when what it reports has changed. Not while one of this program's
    # dialogs is open - but minimized or behind other windows it keeps watching,
    # so a phone's rule runs when it is plugged in (the Automation page).
    $script:deviceWatchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:deviceWatchTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
    $script:deviceWatchTimer.Add_Tick({
        if ($script:busy -gt 0 -or -not $script:devicesReadOnce -or (Test-DialogOpen)) { return }
        $script:deviceWatchTimer.Stop()
        try {
            if (Test-DeviceListChanged) {
                Write-Log 'The attached devices changed; reading the list again.' $colorStep
                Update-DeviceList
            }
            if (Get-Command Invoke-AutomationQueue -ErrorAction SilentlyContinue) {
                Invoke-AutomationQueue -Enter { param($Serial) Enter-AutomationDevice -Serial $Serial } `
                    -Leave { param($State) Exit-AutomationDevice -State $State }
            }
            $ftpDue = -not $script:ftpLastPoll -or
                ([DateTime]::UtcNow - $script:ftpLastPoll).TotalSeconds -ge 10
            if ((Get-Command Restore-FtpPage -ErrorAction SilentlyContinue) -and
                ($script:ftpUri -or ($ui.PillFtp.Visibility -eq 'Visible' -and $ftpDue))) {
                Restore-FtpPage
                Update-FtpPage
                $script:ftpLastPoll = [DateTime]::UtcNow
            }
        } finally {
            $script:deviceWatchTimer.Start()
        }
    })

    $ui.HeaderRefresh.Add_Click({ Update-DeviceList })
    # the logo: the way back to Overview, and a second press reads it again
    $ui.SideBrand.Add_Click({
        if (Test-PageShown -Key 'overview') { Invoke-PageRefresh } else { Show-Page -Page 'overview' }
    })
    # the program's own icon in place of the letter, when it is beside the script
    $icon = Join-Path $script:toolsRoot 'assets\icon-64.png'
    if (Test-Path -LiteralPath $icon -PathType Leaf) {
        try {
            $image = New-Object System.Windows.Media.Imaging.BitmapImage
            $image.BeginInit()
            $image.UriSource = New-Object System.Uri($icon)
            $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.EndInit()
            $ui.SideBrandImage.Source = $image
            $ui.SideBrandImage.Visibility = 'Visible'
            $ui.SideBrandLetter.Visibility = 'Collapsed'
            # the icon has its own rounded background: a blue square behind it
            # is a square inside a square, and a shadow under both
            $ui.SideBrandBox.Background = [System.Windows.Media.Brushes]::Transparent
            $ui.SideBrandBox.Effect = $null
        } catch { }
    }

    # what the phone is doing with itself: its own timer, slower than the rest
    $script:loadTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:loadTimer.Interval = [TimeSpan]::FromSeconds(6)
    $script:loadTimer.Add_Tick({ Update-DeviceLoad })
    $script:loadTimer.Start()
    $ui.SideClassic.Add_Click({ Switch-ToClassic })
    $ui.DeviceRefresh.Add_Click({ Update-DeviceList })

    <#
        The header's own controls are wired here, where they live.

        They used to be wired by the page each one leads to, which held while
        every page was built at startup. From 1.6.0 a page is built when it is
        opened, and the Mirror button then did nothing at all until someone
        had opened the Mirroring page by hand - there was no handler on it to
        do anything. The pills survived only because their two pages are built
        at startup anyway, for the words on the pills.

        Each handler calls a function that belongs to a page. That is safe
        from anywhere: CommandNotFoundAction builds the page that owns the
        name and the call goes through. audit.ps1 fails the build if a page
        wires one of these again.
    #>
    $ui.HeaderMirror.Add_Click({ Start-Scrcpy })
    $ui.PillClipboard.Add_MouseLeftButtonUp({ Show-Page -Page 'clipboard' })
    $ui.PillClipboard.Add_MouseRightButtonUp({ Invoke-ClipboardHeaderToggle })
    $ui.PillFtp.Add_MouseLeftButtonUp({ Show-Page -Page 'ftp' })
    $ui.PillFtp.Add_MouseRightButtonUp({ Invoke-FtpHeaderToggle })
    $ui.BusyCancel.Add_Click({
        Write-Log 'Stopping ...' $colorWarn
        if (Get-Command Stop-BackupRun -ErrorAction SilentlyContinue) { Stop-BackupRun -Reason 'you cancelled it' }
    })
    $ui.LogClear.Add_Click({ $script:logLines.Clear() })
    $ui.LogSave.Add_Click({
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = 'Log file (*.log)|*.log|Text file (*.txt)|*.txt'
        $dialog.FileName = 'androiddc-nova.log'
        if ($dialog.ShowDialog($script:window)) {
            Set-Content -LiteralPath $dialog.FileName -Value (Get-LogText) -Encoding UTF8
            Write-Log "Log saved to $($dialog.FileName)" $colorGood
        }
    })
    $ui.LogFold.Add_Click({ Set-LogFolded -Folded (-not $script:logFolded) })
    $ui.LogSplitter.Add_DragCompleted({ $script:logHeight = $ui.LogRow.Height.Value })

    $script:window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        $key = if ($eventArgs.Key -eq 'System') { $eventArgs.SystemKey } else { $eventArgs.Key }
        if (Invoke-WindowKey -Key $key -Modifiers ([System.Windows.Input.Keyboard]::Modifiers)) { $eventArgs.Handled = $true }
    })

    $script:window.Add_Closing({
        foreach ($action in @($script:cleanups)) { try { & $action } catch { } }
        Save-Settings
        # the rules are free for the other window once this one is gone
        if (Get-Command Close-Automation -ErrorAction SilentlyContinue) { Close-Automation }
        if (Get-Command Close-Tray -ErrorAction SilentlyContinue) { Close-Tray }
        foreach ($timer in @($script:busyTimer, $script:deviceWatchTimer, $script:deviceChangeTimer, $script:toastTimer)) {
            try { $timer.Stop() } catch { }
        }
        if ($script:workRunspace) {
            try { $script:workRunspace.Close(); $script:workRunspace.Dispose() } catch { }
            $script:workRunspace = $null
        }
    })

    Register-Setting -Name 'LogHeight' -Get { [double]$script:logHeight } -Set { param($v) $script:logHeight = [double]$v }
    Register-Setting -Name 'LogFolded' -Get { [bool]$script:logFolded } -Set { param($v) $script:logFolded = [bool]$v }
    Register-Setting -Name 'LastPage' -Get { if ($script:currentPage) { $script:currentPage.Key } else { '' } } -Set { param($v) $script:restorePage = "$v" }
    Register-Setting -Name 'Window' -Get {
        if (-not $script:keepWindowPlace) { return $null }
        $bounds = if ($script:window.WindowState -eq 'Normal') { $script:window } else { $script:window.RestoreBounds }
        @{ Left = [int]$bounds.Left; Top = [int]$bounds.Top; Width = [int]$bounds.Width; Height = [int]$bounds.Height
           Maximized = ($script:window.WindowState -eq 'Maximized') }
    } -Set {
        param($v)
        if ($null -eq $v -or -not $script:keepWindowPlace) { return }
        # only a place that is still on one of this PC's screens
        $area = [System.Windows.SystemParameters]::VirtualScreenWidth
        if ($v.Width -ge $script:window.MinWidth -and $v.Height -ge $script:window.MinHeight -and $v.Left -lt $area - 100 -and $v.Left -gt -$v.Width + 100 -and $v.Top -ge -10) {
            $script:window.WindowStartupLocation = 'Manual'
            $script:window.Left = $v.Left; $script:window.Top = $v.Top
            $script:window.Width = $v.Width; $script:window.Height = $v.Height
        }
        if ($v.Maximized) { $script:window.WindowState = 'Maximized' }
    }
}
