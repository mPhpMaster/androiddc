# needs: phone
# The Root / recovery page: it reads the phone on opening, its marks belong to
# one phone, jdwp stops by itself, emu explains its silence.
#
# "adb root" is only tried on a retail build ("user"), where the phone refuses
# it and nothing changes. On a userdebug or eng build it would really restart
# adbd as root, so there it is skipped.

$phone = $TestSerial
function Get-RootChecks { ([regex]::Matches($txtLog.Text, [regex]::Escape($phone) + ' : build=')).Count }
function Get-LogTail { param([int]$Count = 3) @($txtLog.Lines | Where-Object { $_.Trim() } | Select-Object -Last $Count) }
function Invoke-SelectionPath {
    # the path a click in the device list takes, without selecting another phone
    foreach ($item in $lstDevices.Items) { $item.Selected = $false }
    Wait-Pumped -Milliseconds 200
    Select-TestPhone
    Wait-Pumped -Milliseconds 1300
}
function Get-Enabled { (@($script:rootButtons | Where-Object { $_.Enabled } | ForEach-Object { $_.Tag.Caption } | Sort-Object)) -join ',' }
$harmless = (@('wait-for-device', 'keygen...', 'get-devpath') | Sort-Object) -join ','

Select-TestPhone
$retail = (Invoke-DeviceShell -Serial $phone -CommandArguments @('getprop', 'ro.build.type')).Text.Trim() -eq 'user'
$emulator = $phone -like 'emulator-*'
Say ("retail build: {0}, emulator: {1}" -f $retail, $emulator)

Say ''
Say '== opened from the inner tab, it reads the phone by itself =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabScrcpy
Wait-Pumped -Milliseconds 400
Reset-RootAvailability
$before = Get-RootChecks
$tabsAdvanced.SelectedTab = $tabRoot
Wait-Pumped -Milliseconds 3000
Say ("'{0}'" -f $lblRootState.Text)
Say ("read once, marks belong to this phone   {0}" -f (Mark (((Get-RootChecks) - $before) -eq 1 -and $script:rootCheckedSerial -eq $phone)))
if ($retail) { Say ("only the harmless three are enabled   {0}" -f (Mark ((Get-Enabled) -eq $harmless))) }

Say ''
Say '== the same phone re-selected, or the list refreshed: nothing read again =='
$before = Get-RootChecks
Invoke-SelectionPath
Update-DeviceList
Wait-Pumped -Milliseconds 2500
Say ("no new read   {0}" -f (Mark (((Get-RootChecks) - $before) -eq 0)))

Say ''
Say '== another phone while the page is hidden: the marks are cleared =='
$tabsAdvanced.SelectedTab = $tabScrcpy
Wait-Pumped -Milliseconds 300
# stand-in for a different phone: the marks claim to come from another serial
$script:rootCheckedSerial = 'ANOTHER-PHONE'
Invoke-SelectionPath
$still = @($script:rootButtons | Where-Object { $_.Enabled -or $_.Text.StartsWith([string][char]0x2714) })
Say ("cleared   {0}" -f (Mark ($lblRootState.Text -eq 'not checked yet' -and $still.Count -eq 0)))

Say ''
Say '== another phone while the page is on screen: read again =='
$tabsAdvanced.SelectedTab = $tabRoot
Wait-Pumped -Milliseconds 3000
$script:rootCheckedSerial = 'ANOTHER-PHONE'
$before = Get-RootChecks
Invoke-SelectionPath
Say ("read again, marks belong to this phone   {0}" -f (Mark (((Get-RootChecks) - $before) -eq 1 -and $script:rootCheckedSerial -eq $phone)))

Say ''
Say '== unlocked =='
$chkRootUnlock.Checked = $true
Wait-Pumped -Milliseconds 200
Say ("everything enabled   {0}" -f (Mark (@($script:rootButtons | Where-Object { -not $_.Enabled }).Count -eq 0)))

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$btnRootJdwp.PerformClick()
Wait-Pumped -Milliseconds 200
Say ("jdwp returned in {0:N1} s - it never ends by itself   {1}" -f $watch.Elapsed.TotalSeconds, (Mark ($watch.Elapsed.TotalSeconds -lt 8)))

$names = Get-DeviceProcessNames -Serial $phone
Say ("ps names pid 1 '{0}'   {1}" -f $names['1'], (Mark ($names.Count -gt 20 -and $names['1'])))

if (-not $emulator) {
    Invoke-RootAction -Arguments @('emu', 'avd name')
    Wait-Pumped -Milliseconds 1500
    Say ("emu on a phone says why it failed   {0}" -f (Mark (((Get-LogTail 2) -join ' ') -match 'a phone has no emulator console')))
}

$before = Get-RootChecks
$btnRootDevPath.PerformClick(); Wait-Pumped -Milliseconds 1500
$btnRootWaitDevice.PerformClick(); Wait-Pumped -Milliseconds 1500
Say ("the harmless ones read nothing again after them   {0}" -f (Mark (((Get-RootChecks) - $before) -eq 0)))

if ($retail) {
    $before = Get-RootChecks
    Invoke-RootAction -Arguments @('root')
    Wait-Pumped -Milliseconds 1500
    $tail = (Get-LogTail 4) -join ' / '
    Say ("adb root refused, explained, and the phone read again   {0}" -f
        (Mark ($tail -match 'production builds' -and $tail -match 'exactly as this page warned' -and ((Get-RootChecks) - $before) -eq 1)))
} else {
    Say 'SKIPPED adb root - not a retail build, where it would really restart adbd as root'
}

$chkRootUnlock.Checked = $false
Wait-Pumped -Milliseconds 200
if ($retail) { Say ("locked again: only the harmless three   {0}" -f (Mark ((Get-Enabled) -eq $harmless))) }
