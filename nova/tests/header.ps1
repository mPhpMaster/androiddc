# The window's own controls - the Mirror button in the header - work from a
# cold start, before any page has been opened.
#
# They used to be wired by the page each one leads to. That held while every
# page was built at startup; from 1.6.0 a page is built when it is opened, and
# the Mirror button then did nothing at all until someone had opened the
# Mirroring page by hand. Nothing caught it, because every other test gets all
# the pages at once - so this one runs the way a person gets the window, with
# the pages lazy.
#
# Nothing is selected in the device list, so Start-Scrcpy stops at "Select at
# least one ready device" instead of starting anything. That refusal is the
# proof: it can only be written by Start-Scrcpy, which lives on a page that was
# never opened.

Say ''
Say '== the header, before any page has been opened =='

function Get-Page { param([string]$Key) foreach ($page in @($script:pages)) { if ($page.Key -eq $Key) { return $page } } return $null }
function Test-Built { param([string]$Key) $page = Get-Page -Key $Key; return ($null -ne $page -and $page.Loaded -and $null -ne $page.Root) }

$mirroring = Get-Page -Key 'mirroring'
Say ("  the window knows of a Mirroring page   {0}" -f (Mark ($null -ne $mirroring)))
Say ("  and it is not built yet   {0}" -f (Mark (-not (Test-Built -Key 'mirroring'))))

# nothing selected and "All devices" off, which is what Get-SelectedSerials
# reads: with nothing picked the only thing that can happen is the refusal
$ui.AllDevices.IsChecked = $false
$ui.DeviceList.SelectedItems.Clear()
Wait-Pumped -Milliseconds 200
Say ("  nothing is selected, so nothing can start   {0}" -f (Mark (
    @(Get-SelectedSerials).Count -eq 0)))

$before = @($script:logLines).Count
$ui.HeaderMirror.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Wait-Pumped -Milliseconds 600
$said = (@($script:logLines) | Select-Object -Skip $before | ForEach-Object { "$($_.Text)" }) -join "`n"

Say ("  pressing Mirror does something: '{0}'   {1}" -f ($said -split "`n")[0], (Mark ("$said".Trim() -ne '')))
Say ("  and what it does is Start-Scrcpy's own answer   {0}" -f (Mark (
    $said -match 'Select at least one ready device|scrcpy\.exe was not found')))
Say ("  which means the Mirroring page was built by the call   {0}" -f (Mark (Test-Built -Key 'mirroring')))
