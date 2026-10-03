#Requires -Version 5.1

<#
.SYNOPSIS
    AndroidDC Nova - AndroidDC in the friendly-interface design, as a WPF
    desktop application.

.DESCRIPTION
    The same tool as androiddc.ps1 - mirroring, internet sharing in both
    directions, apps, contacts, messages, camera and microphone, files,
    running processes, radios, users, the shell - with a side navigation,
    a device card and an activity log instead of fourteen tabs.

    Windows PowerShell 5.1 and what Windows ships; nothing to install. It
    lives in the nova\ folder of the AndroidDC project and shares that
    folder's adb, scrcpy, gnirehtet and get-upstream.ps1 with the classic
    window (androiddc.ps1). Start it with androiddc-nova.vbs in the project
    folder; the side navigation has a button back to the classic window.

    The parts:
      lib\Core.ps1    running adb without freezing the window, quoting, settings
      lib\Ui.ps1      the window's helpers: pages, log, device list, dialogs
      ui\Theme.xaml   every colour, font and control style
      ui\Shell.xaml   the window around the pages
      pages\*.ps1     one page each, with its .xaml next to it

    Settings are kept in %APPDATA%\AndroidDC\nova-settings.json.

.PARAMETER TestScript
    Runs this script once the window is on screen, then closes the window
    normally, so settings are written the way a person closing it would.
    Used by tests\run.ps1.

.PARAMETER OffScreen
    Opens the window far outside the visible screens.

.PARAMETER SettingsPath
    Another settings file, so a test never touches the real one.
#>

[CmdletBinding()]
param(
    [string]$TestScript,
    [switch]$OffScreen,
    # Not $SettingsPath: that is $script:settingsPath, which lib\Core.ps1 sets
    # to the real file - the parameter was overwritten and tests wrote there.
    [Alias('SettingsPath')]
    [string]$SettingsFile,
    # only these pages (names as in pages\, comma separated); every page when empty.
    # Not called $Pages: variable names ignore case, so that was $script:pages,
    # the page registry - and its [string[]] type turned the registry into a
    # fixed-size array the first time a page was added.
    [Alias('Pages')]
    [string[]]$PageNames,
    # started with Windows (the Automation page): the window opens minimized,
    # and a phone that is already plugged in runs its rule as if just plugged
    [switch]$Minimized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# the folder picker and the picture handling still come from here
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptRoot 'lib\Core.ps1')
# the little window that says this is coming: the six seconds it stands in for
# start here. A test window, an off-screen one and one opening minimized have
# nobody waiting on them.
$splashScript = Join-Path $script:toolsRoot 'shared\Splash.ps1'
if (Test-Path -LiteralPath $splashScript -PathType Leaf) {
    . $splashScript
    Show-Splash -Root $script:toolsRoot -Version $script:appVersion `
        -Quiet:([bool]$TestScript -or [bool]$OffScreen -or [bool]$Minimized)
    Update-Splash -Text 'Reading the parts ...' -Percent 10
}
if (-not (Get-Command Update-Splash -ErrorAction SilentlyContinue)) {
    # Nova on its own, without the project folder: the calls below are still
    # written plainly rather than guarded one by one
    function Update-Splash { param([string]$Text, [int]$Percent = -1) }
    function Close-Splash { }
}
. (Join-Path $scriptRoot 'lib\Ui.ps1')
# starting with Windows and the rules per phone, shared with the classic window;
# Nova on its own, without the project folder, simply has no Automation page
$automationScript = Join-Path $script:toolsRoot 'shared\Automation.ps1'
if (Test-Path -LiteralPath $automationScript -PathType Leaf) { . $automationScript }
# the make of a phone, and how busy it is
$factsScript = Join-Path $script:toolsRoot 'shared\DeviceFacts.ps1'
if (Test-Path -LiteralPath $factsScript -PathType Leaf) { . $factsScript }
# the icon by the clock, the same as the classic window's
$trayScript = Join-Path $script:toolsRoot 'shared\Tray.ps1'
if (Test-Path -LiteralPath $trayScript -PathType Leaf) { . $trayScript }
# backing the phone up to this PC, and putting a backup back
$backupScript = Join-Path $script:toolsRoot 'shared\Backup.ps1'
if (Test-Path -LiteralPath $backupScript -PathType Leaf) { . $backupScript }
# formatting a memory card, and asking the phone to reset itself
$eraseScript = Join-Path $script:toolsRoot 'shared\Erase.ps1'
if (Test-Path -LiteralPath $eraseScript -PathType Leaf) { . $eraseScript }
# the clipboard shared between this PC and the phones
$clipboardScript = Join-Path $script:toolsRoot 'shared\Clipboard.ps1'
if (Test-Path -LiteralPath $clipboardScript -PathType Leaf) { . $clipboardScript }
if ($SettingsFile) { $script:settingsPath = $SettingsFile }
# a window far off screen is not a place to remember
$script:keepWindowPlace = -not $OffScreen

Update-Splash -Text 'Building the window ...' -Percent 25
Initialize-Ui

# The pages, in the order the side navigation lists them within each section.
# A page that is not written yet is simply not there.
$pageList = @('Overview', 'Screen', 'Mirroring', 'Apps', 'Files', 'Ftp', 'Clipboard', 'Media',
    'Messages', 'Contacts', 'Tethering', 'Radios', 'Tools', 'Running', 'Users', 'Shell', 'Automation', 'Backup')
$pageCount = $pageList.Count
$pageNumber = 0
# "-Pages a,b" through -File arrives as one string
$onlyPages = @($PageNames | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Every page at once, or each one when it is first opened. Building all
# eighteen was three of the six seconds this window took to open, so the
# second is what a person gets; the first is for the tests, which call into
# pages without opening them, and for a run told which pages to have.
$eagerPages = ($onlyPages.Count -gt 0) -or [bool]$env:ANDROIDDC_EAGER_PAGES
if ($eagerPages) {
    foreach ($pageName in $pageList) {
        if ($onlyPages.Count -gt 0 -and $onlyPages -notcontains $pageName) { continue }
        $pageNumber++
        Update-Splash -Text "Loading the $($pageName.ToLowerInvariant()) page ..." `
            -Percent (30 + [int](60.0 * $pageNumber / $pageCount))
        $pageFile = Join-Path $scriptRoot "pages\$pageName.ps1"
        if (Test-Path -LiteralPath $pageFile -PathType Leaf) { . $pageFile }
    }
} else {
    Update-Splash -Text 'Reading what the pages are ...' -Percent 60
    Register-PageList -Folder (Join-Path $scriptRoot 'pages') -Names $pageList
    Initialize-PageLookup
    # The three the window itself reaches into: the header's FTP and clipboard
    # pills, and the rule count on the Automation item. Everything else is
    # built when it is opened - or when something calls into it.
    foreach ($needed in @('ftp', 'clipboard', 'automation')) {
        Update-Splash -Text 'Building the window ...' -Percent 80
        $null = Request-Page -Key $needed
    }
}

Complete-Shell

# ------------------------------------------------------------------ tools ----

$script:adbPath = Resolve-Tool -FileName 'adb.exe'
$script:gnirehtetPath = Resolve-Tool -FileName 'gnirehtet.exe'
$script:scrcpyPath = Resolve-Tool -FileName 'scrcpy.exe'

# scrcpy carries adb with it, so that download covers both
if (-not $script:scrcpyPath -or -not $script:adbPath) {
    if (Install-UpstreamPackage -Package 'scrcpy') {
        $script:scrcpyPath = Resolve-Tool -FileName 'scrcpy.exe'
        $script:adbPath = Resolve-Tool -FileName 'adb.exe'
    }
}
if (-not $script:gnirehtetPath) {
    if (Install-UpstreamPackage -Package 'gnirehtet') { $script:gnirehtetPath = Resolve-Tool -FileName 'gnirehtet.exe' }
}
if (-not $script:adbPath) {
    # nothing of this program is on screen yet except the splash, and it is on
    # top of everything: a question behind it is a program that looks stuck
    Close-Splash
    [void][System.Windows.MessageBox]::Show(
        "adb.exe was not found in`r`n$($script:toolsRoot)`r`nnor in PATH.`r`n`r`nRun get-upstream.ps1 in that folder to download it.",
        $script:appName, 'OK', 'Error')
    return
}

# gnirehtet starts adb itself; point it at the same binary and APK
$env:ADB = $script:adbPath
$localApk = Join-Path $script:toolsRoot 'gnirehtet.apk'
if (Test-Path -LiteralPath $localApk -PathType Leaf) { $env:GNIREHTET_APK = (Resolve-Path -LiteralPath $localApk).Path }

Restore-Settings
Set-LogFolded -Folded $script:logFolded
if (Get-Command Initialize-Automation -ErrorAction SilentlyContinue) {
    Initialize-Automation -ProjectRoot $script:toolsRoot -CountPresent ([bool]$Minimized)
}
if (Get-Command Initialize-Tray -ErrorAction SilentlyContinue) {
    Initialize-Tray -Title $script:appName -ProjectRoot $script:toolsRoot `
        -GetHandle { (New-Object System.Windows.Interop.WindowInteropHelper($script:window)).EnsureHandle() } `
        -OnExit { $script:window.Close() } -OnOpenRules { Show-Page -Page 'automation' } `
        -GetFtpState {
            $device = Get-SelectedDevice
            if (-not $device -or $device.State -ne 'device') { return 'No phone' }
            if (Get-AndroidDcRawFtpStatus -Serial $device.Serial) { return 'Running' }
            return 'Off'
        } `
        -OnOpenFtp { Show-Page -Page 'ftp' } `
        -OnToggleFtp { Invoke-FtpHeaderToggle }
    # minimized means into the tray: off the taskbar, still watching for phones
    $script:window.Add_StateChanged({
        if ($script:window.WindowState -eq 'Minimized' -and -not (Test-TrayHidden)) { Hide-TrayWindow }
    })
}

if ($OffScreen) {
    $script:window.WindowStartupLocation = 'Manual'
    $script:window.WindowState = 'Normal'
    $script:window.Left = -4000
    $script:window.Top = -3000
    $script:window.ShowActivated = $false
}

$script:started = $false
$script:window.Add_ContentRendered({
    if ($script:started) { return }
    $script:started = $true
    # the splash stood in for this window; this window is here now
    if (Get-Command Close-Splash -ErrorAction SilentlyContinue) { Close-Splash }
    # after the first render, not before: a window shown minimized may never render
    if ($Minimized) { $script:window.WindowState = 'Minimized' }

    Write-Log "$($script:appName) $($script:appVersion)" $colorInfo
    Write-Log "adb:       $($script:adbPath)" $colorInfo
    Write-Log ('gnirehtet: ' + $(if ($script:gnirehtetPath) { $script:gnirehtetPath } else { 'not found' })) $colorInfo
    Write-Log ('scrcpy:    ' + $(if ($script:scrcpyPath) { $script:scrcpyPath } else { 'not found' })) $colorInfo
    # the rules set before, so they are known without opening their page
    if (Get-Command Write-AutomationOverview -ErrorAction SilentlyContinue) { Write-AutomationOverview -Where 'the Automation page (System)' }
    if (Get-Command Update-AutomationNavTitle -ErrorAction SilentlyContinue) { Update-AutomationNavTitle }
    $script:busyTimer.Start()
    $null = Invoke-Adb -CommandArguments @('start-server')
    Update-DeviceList
    $script:deviceWatchTimer.Start()

    $opening = if ($script:restorePage) { Get-Page -Key $script:restorePage } else { $null }
    if (-not $opening -and $script:pages.Count -gt 0) { $opening = $script:pages[0] }
    if ($opening) { Show-Page -Page $opening }
    $script:pageSaveReady = $true

    if ($TestScript) {
        try {
            . $TestScript
        } catch {
            Write-Host ('TEST TRAPPED: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
        } finally {
            $script:window.Close()
        }
    }
})

try {
    [void]$script:window.ShowDialog()
} finally {
    foreach ($pattern in @("androiddc-nova-$PID.*")) {
        Get-ChildItem -Path $env:TEMP -Filter $pattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
}
