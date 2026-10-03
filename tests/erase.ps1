# Advanced > Device tools > Factory reset and formatting: what the volume list
# is read as, the guard in front of rm -rf, a card formatted, refused and left
# unmounted, a phone that takes the factory reset broadcast and one that
# refuses it, the sentence about the backup there is, and the buttons.
#
# adb is made up for every one of these. Nothing here runs a format or a reset
# on a real phone - there is no safe way to test that twice - so the calls are
# caught and compared instead, which is where the mistakes would be anyway.

$work = Join-Path $TestOutput 'erase-work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work
$work = (Get-Item -LiteralPath $work).FullName

$script:asked = New-Object System.Collections.Generic.List[string]
$script:answers = @{}
# the longest pattern that fits wins, so a general 'rm -rf*' never hides a
# particular one
$fakeShell = {
    param($Serial, $CommandArguments)
    $command = (@($CommandArguments) -join ' ')
    $null = $script:asked.Add($command)
    $text = ''
    foreach ($key in @($script:answers.Keys | Sort-Object -Property Length -Descending)) {
        if ($command -like $key) { $text = $script:answers[$key]; break }
    }
    return [PSCustomObject]@{ Lines = @("$text" -split "`n"); Text = $text; ExitCode = 0 }
}
# the comma keeps the answer an array: returned bare, none of them is $null
# and one of them is a bare string, and .Count fails on either
function Get-Asked { param([string]$Like) return ,@($script:asked | Where-Object { $_ -like $Like }) }

Say '== what the phone says it has =='
$script:answers = @{
    'sm list-volumes all' = "emulated;999 mounted null`nprivate mounted null`npublic:179,1 mounted A1B2C3D4E5F6`nemulated;0 mounted null"
    'df -k*A1B2*'         = "Filesystem     1K-blocks     Used Available Use% Mounted on`n/dev/fuse      124852220 54631048  70221172  44% /storage/A1B2C3D4E5F6"
}
$volumes = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    @(Get-DeviceVolumes -Serial 'ABC123') }
$card = @($volumes | Where-Object { $_.Kind -eq 'public' })[0]
$own = @($volumes | Where-Object { $_.Id -eq 'emulated;0' })[0]
Say ("  {0} volume(s): {1}" -f $volumes.Count, ((@($volumes | ForEach-Object { $_.Id })) -join ', '))
Say ("  the card is {0} and its files are at {1}   {2}" -f $card.Id, $card.Path, (Mark (
    $volumes.Count -eq 4 -and $card.Id -eq 'public:179,1' -and $card.Path -eq '/storage/A1B2C3D4E5F6')))
Say ("  the phone's own storage is /sdcard   {0}" -f (Mark ($own.Path -eq '/sdcard')))
Say ("  and emulated;999, which is no one's storage, has no path   {0}" -f (Mark (
    (@($volumes | Where-Object { $_.Id -eq 'emulated;999' })[0]).Path -eq '')))

# @( ) around the block as well: a block that hands back a one-item array has
# it unrolled into the one object, and the count of it cannot be asked for
$cards = @(& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    @(Get-DeviceCards -Serial 'ABC123') })
Say ("  as one line: {0}" -f (Get-DeviceCardWords -Card $cards[0]))
Say ("  how big it is and how full comes from df   {0}" -f (Mark (
    $cards.Count -eq 1 -and $cards[0].Total -eq ([long]124852220 * 1024) -and $cards[0].Mounted -and
    (Get-DeviceCardWords -Card $cards[0]) -match 'of it in use')))
Say ("  no card at all says so   {0}" -f (Mark (
    (Get-DeviceCardWords -Card $null) -eq 'no memory card in this phone')))

# a ROM without sm: the card is still where Android puts it
$script:answers = @{
    'sm list-volumes all' = ''
    'ls -1 /storage'      = "A1B2C3D4E5F60789`nemulated`nself"
    'df -k*'              = "Filesystem 1K-blocks Used Available Use% Mounted on`n/dev/fuse 100 40 60 40% /storage/A1B2C3D4E5F60789"
}
$fallback = @(& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    @(Get-DeviceCards -Serial 'ABC123') })
Say ("  without sm it is found by its name: {0}   {1}" -f (@($fallback | ForEach-Object { $_.Path }) -join ','), (Mark (
    $fallback.Count -eq 1 -and $fallback[0].Path -eq '/storage/A1B2C3D4E5F60789')))

Say ''
Say '== the guard in front of rm -rf =='
$throughs = @()
foreach ($root in @('/', '/sdcard', '/storage', '/storage/emulated', '/storage/self', '/data', '/system',
        '/mnt', '', '/storage/x/../../data', '/tmp/x', 'C:\Windows')) {
    if (Test-DeviceErasablePath -Path $root) { $throughs += "'$root'" }
}
Say ("  every root and every path off the phone is refused{0}   {1}" -f
    $(if ($throughs) { ': ' + ($throughs -join ', ') + ' got through' } else { '' }), (Mark ($throughs.Count -eq 0)))
Say ("  a card and a folder on the phone are allowed   {0}" -f (Mark (
    (Test-DeviceErasablePath -Path '/storage/45C6-8077') -and (Test-DeviceErasablePath -Path '/sdcard/DCIM'))))

Say ''
Say '== emptying a card =='
$script:asked.Clear()
$script:answers = @{
    "ls -A1 '/storage/45C6-8077'*" = ".`$Trash`$`nDCIM`nDownload`nAndroid"
    "find '/storage/45C6-8077'*"   = '0'
    'rm -rf*'                      = ''
}
$cleared = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Start-BackupRun
    $one = Clear-DeviceFiles -Serial 'ABC123' -Path '/storage/45C6-8077' -Caption 'Erasing the card:'
    Complete-BackupRun
    $one }
$removals = (Get-Asked -Like 'rm -rf*')
Say ("  it removed {0} name(s), {1} file(s) left, ok={2}   {3}" -f $cleared.Gone, $cleared.Left, $cleared.Ok, (Mark (
    $cleared.Asked -eq 4 -and $cleared.Gone -eq 4 -and $cleared.Left -eq 0 -and $cleared.Ok)))
Say ("  a name with a `$ in it is one word to the phone: {0}   {1}" -f $removals[0], (Mark (
    $removals[0] -eq "rm -rf '/storage/45C6-8077/.`$Trash`$' 2>&1")))
Say ("  and the folder itself is never removed   {0}" -f (Mark (
    (Get-Asked -Like "rm -rf '/storage/45C6-8077' *").Count -eq 0)))

$script:answers["rm -rf '/storage/45C6-8077/Android'*"] = 'rm: Android: Permission denied'
$script:answers["find '/storage/45C6-8077'*"] = '12'
$part = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Start-BackupRun
    $one = Clear-DeviceFiles -Serial 'ABC123' -Path '/storage/45C6-8077'
    Complete-BackupRun
    $one }
Say ("  what the phone would not let go is counted, not claimed: refused {0}, {1} left, ok={2}   {3}" -f
    $part.Refused, $part.Left, $part.Ok, (Mark ($part.Refused -eq 1 -and $part.Left -eq 12 -and -not $part.Ok)))

$script:asked.Clear()
$stopped = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Start-BackupRun
    Stop-BackupRun -Reason 'you cancelled it'
    $one = Clear-DeviceFiles -Serial 'ABC123' -Path '/storage/45C6-8077'
    Complete-BackupRun
    $one }
Say ("  Cancel is answered between names, before the first one   {0}" -f (Mark (
    $stopped.Stopped -and $stopped.Gone -eq 0 -and (Get-Asked -Like 'rm -rf*').Count -eq 0)))
Say ("  a path the guard refuses removes nothing   {0}" -f (Mark (
    -not (& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
        (Clear-DeviceFiles -Serial 'ABC123' -Path '/sdcard').Ok }))))

Say ''
Say '== formatting a card =='
$script:asked.Clear()
$script:answers = @{
    'sm format public:179,1'     = ''
    'sm list-volumes all'        = "public:179,1 mounted AAAA-BBBB`nemulated;0 mounted null"
    "find '/storage/AAAA-BBBB'*" = '0'
    'df -k*'                     = ''
}
$formatted = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Format-DeviceCard -Serial 'ABC123' -Volume 'public:179,1' }
Say ("  the phone is asked once: {0}" -f ((Get-Asked -Like 'sm format*') -join ', '))
Say ("  afterwards it is at {0} with {1} file(s) on it   {2}" -f $formatted.Path, $formatted.Left, (Mark (
    $formatted.Ok -and $formatted.Path -eq '/storage/AAAA-BBBB' -and $formatted.Left -eq 0 -and
    (Get-Asked -Like 'sm format*').Count -eq 1)))

$script:answers['sm format public:179,1'] = 'java.lang.SecurityException: Permission Denial: requires android.permission.MOUNT_FORMAT_FILESYSTEMS'
$refused = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Format-DeviceCard -Serial 'ABC123' -Volume 'public:179,1' }
Say ("  a refusal stays a refusal   {0}" -f (Mark (-not $refused.Ok -and $refused.Refused)))
Say ("  and the log says where to do it instead   {0}" -f (Mark ($txtLog.Text -match 'Settings > Storage')))

$script:answers['sm format public:179,1'] = ''
$script:answers['sm list-volumes all'] = "public:179,1 unmounted null`nemulated;0 mounted null"
$script:answers['sm mount public:179,1'] = ''
$script:asked.Clear()
$quiet = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Format-DeviceCard -Serial 'ABC123' -Volume 'public:179,1' }
Say ("  a card that does not come back gets a mount and then the truth   {0}" -f (Mark (
    $quiet.Ok -and $quiet.Path -eq '' -and (Get-Asked -Like 'sm mount*').Count -eq 1)))
Say ("  nothing to format is refused before anything is run   {0}" -f (Mark (
    -not (& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
        Format-DeviceCard -Serial 'ABC123' -Volume '' }).Ok)))

Say ''
Say '== the whole phone =='
$script:asked.Clear()
$script:answers = @{ 'am broadcast*' = 'Broadcast completed: result=0' }
$wiping = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Reset-DeviceToNew -Serial 'ABC123' }
$sent = (Get-Asked -Like 'am broadcast*')[0]
Say ("  it asks with: {0}" -f $sent)
Say ("  a phone that takes it is erasing itself, and no screen was opened   {0}" -f (Mark (
    $wiping.Wiping -and -not $wiping.Opened -and
    $sent -like '*-a android.intent.action.FACTORY_RESET -p android --receiver-foreground*')))

$script:asked.Clear()
$script:answers = @{
    'am broadcast*' = 'java.lang.SecurityException: Permission Denial: requires android.permission.MASTER_CLEAR'
    'cmd package resolve-activity --brief -a com.android.settings.action.FACTORY_RESET' = "priority=1 preferredOrder=0`ncom.android.settings/.Settings`$FactoryResetActivity"
    'am start*' = 'Starting: Intent'
}
$opened = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Reset-DeviceToNew -Serial 'ABC123' }
Say ("  a phone that refuses it has its own screen opened: {0}   {1}" -f ((Get-Asked -Like 'am start*')[0]), (Mark (
    -not $opened.Wiping -and $opened.Opened -and
    ((Get-Asked -Like 'am start*')[0]) -eq 'am start -a com.android.settings.action.FACTORY_RESET')))
Say ("  and the log says MASTER_CLEAR is why   {0}" -f (Mark ($txtLog.Text -match 'MASTER_CLEAR is a system permission')))

$script:answers = @{ 'am broadcast*' = 'java.lang.SecurityException'; 'cmd package resolve-activity*' = 'No activity found' }
$neither = & { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    Reset-DeviceToNew -Serial 'ABC123' }
Say ("  a phone with no reset screen either says so instead of claiming it worked   {0}" -f (Mark (
    -not $neither.Wiping -and -not $neither.Opened)))

Say ''
Say '== is there a backup of this phone first =='
Say ("  today: {0} / yesterday: {1} / a week: {2} / longer: {3}   {4}" -f
    (Format-EraseAgo -When (Get-Date)), (Format-EraseAgo -When (Get-Date).AddDays(-1)),
    (Format-EraseAgo -When (Get-Date).AddDays(-7)), (Format-EraseAgo -When (Get-Date).AddDays(-200)),
    (Mark ((Format-EraseAgo -When (Get-Date)) -eq 'today' -and
        (Format-EraseAgo -When (Get-Date).AddDays(-1)) -eq 'yesterday' -and
        (Format-EraseAgo -When (Get-Date).AddDays(-7)) -eq '7 days ago' -and
        (Format-EraseAgo -When (Get-Date).AddDays(-200)) -eq 'about 7 months ago')))

# a backup of one phone in a folder of its own, and the folder the list looks in
$taken = (Get-Date).AddDays(-3)
$made = Join-Path $work 'AndroidDC-backup-made'
$null = New-Item -ItemType Directory -Path (Join-Path $made 'files') -Force
Save-BackupText -Path (Join-Path $made 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    Format = 2; Serial = 'ABC123'; Model = 'Redmi 13C'; Android = '15'
    Created = $taken.ToString('yyyy-MM-ddTHH:mm:ss'); Name = 'before the format'
    Parts = @('files', 'apps'); Files = [PSCustomObject]@{ Files = 0; Bytes = 0 }
    Card = $null; Apps = @(); Personal = $null; Settings = @(); Bytes = 0; Complete = $true; Stopped = ''
}))
Set-BackupFolderPath -Folder $work
$note = Get-DeviceBackupNote -Serial 'ABC123'
Say ("  '{0}'" -f $note)
Say ("  it names the one taken of this phone, when, and what it holds   {0}" -f (Mark (
    $note -match '3 days ago' -and $note -match 'before the format' -and $note -match 'files, apps')))
$none = Get-DeviceBackupNote -Serial 'ANOTHER-PHONE'
Say ("  of a phone with no backup here: '{0}'   {1}" -f $none, (Mark ($none -match 'no backup of this phone')))

Say ''
Say '== the two buttons on the device tools page =='
$tabs.SelectedTab = $tabAdvanced
$tabsAdvanced.SelectedTab = $tabTools
Wait-Pumped -Milliseconds 200
Say ("  they are on the tools page, in a box of their own: '{0}'   {1}" -f $grpEraseBox.Text, (Mark (
    $grpEraseBox.Text -eq 'Factory reset and formatting' -and $grpEraseBox.Parent -eq $tabTools -and
    $btnFormatPhone.Parent -eq $grpEraseBox -and $btnFormatCard.Parent -eq $grpEraseBox)))
Say ("  both buttons are there, with hover text, and so is Cancel   {0}" -f (Mark (
    $btnFormatPhone.Text -eq 'Factory reset ...' -and $btnFormatCard.Text -eq 'Format the memory ...' -and
    $toolTip.GetToolTip($btnFormatPhone) -and $toolTip.GetToolTip($btnFormatCard) -and
    $btnEraseCancel.Text -eq 'Cancel' -and -not $btnEraseCancel.Enabled)))
Say ("  nothing in the box sticks out of it   {0}" -f (Mark (
    @($grpEraseBox.Controls | Where-Object {
        $_.Right -gt $grpEraseBox.ClientSize.Width -or $_.Bottom -gt $grpEraseBox.ClientSize.Height }).Count -eq 0)))

# the hint reads the phone it is given, and says what it found
$script:answers = @{
    'sm list-volumes all' = "public:179,1 mounted AAAA-BBBB`nemulated;0 mounted null"
    'df -k*'              = "Filesystem 1K-blocks Used Available Use% Mounted on`n/dev/fuse 61440 20480 40960 34% /storage/AAAA-BBBB"
}
& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    function Get-SelectedSerial { 'ABC123' }
    Update-EraseHint -Force }
Say ("  the hint says: '{0}'" -f $lblErase.Text)
Say ("  it names the card and how full it is   {0}" -f (Mark ($lblErase.Text -match 'Memory card: /storage/AAAA-BBBB')))
$script:answers = @{ 'sm list-volumes all' = ''; 'ls -1 /storage' = "emulated`nself" }
& { function Invoke-DeviceShell { param($Serial, $CommandArguments) & $fakeShell $Serial $CommandArguments }
    function Get-SelectedSerial { 'ABC123' }
    Update-EraseHint -Force }
Say ("  a phone without one: '{0}'   {1}" -f $lblErase.Text, (Mark (
    $lblErase.Text -eq 'No memory card in this phone.')))
& { function Get-SelectedSerial { $null }
    Update-EraseHint -Force }
Say ("  no phone picked: '{0}'   {1}" -f $lblErase.Text, (Mark (
    $lblErase.Text -eq 'Pick a phone in the list to see what it has.')))

Set-EraseBusyUi -Running $true
Say ("  while an erase runs, Cancel is the only one that works   {0}" -f (Mark (
    $btnEraseCancel.Enabled -and -not $btnFormatPhone.Enabled -and -not $btnFormatCard.Enabled)))
Set-EraseBusyUi -Running $false
Say ("  and afterwards they are back   {0}" -f (Mark (
    $btnFormatPhone.Enabled -and $btnFormatCard.Enabled -and -not $btnEraseCancel.Enabled)))

Start-BackupRun
Say ("  a backup already running is told, not interrupted   {0}" -f (Mark (-not (Test-EraseAllowed))))
Complete-BackupRun
Say ("  with nothing running they are allowed   {0}" -f (Mark (Test-EraseAllowed)))
