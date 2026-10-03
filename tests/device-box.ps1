# The two lines under the device list: the make of the phone picked, what it is
# doing with itself, and the clipboard line at the right of them.
#
# The make and the colours are worked out here with no phone involved. With a
# phone attached the readings are taken from it, which is read-only; the
# clipboard line is pressed, and that does share with the phone for a moment.

Say '== the make of a phone =='
foreach ($row in @(
        @{ Maker = 'Xiaomi';  Model = '23108RN04Y'; Want = 'Xiaomi';  Letter = 'M' }
        @{ Maker = 'samsung'; Model = 'SM-S911B';   Want = 'Samsung'; Letter = 'S' }
        @{ Maker = '';        Model = 'SM-S911B';   Want = 'Samsung'; Letter = 'S' }
        @{ Maker = 'Google';  Model = 'Pixel 8';    Want = 'Google';  Letter = 'G' }
        @{ Maker = 'Apple';   Model = 'iPhone 15';  Want = 'Apple';   Letter = 'A' }
        @{ Maker = 'OnePlus'; Model = 'CPH2581';    Want = 'OnePlus'; Letter = '1' })) {
    $make = Get-DeviceMake -Model $row.Model -Serial 'ABC123' -Maker $row.Maker
    Say ("  {0,-9} {1,-11} -> {2}   {3}" -f $row.Maker, $row.Model, $(if ($make) { $make.Name } else { '<none>' }),
        (Mark ($null -ne $make -and $make.Name -eq $row.Want -and $make.Letter -eq $row.Letter)))
}
$unknown = Get-DeviceMake -Model 'QX9000' -Serial 'ABC123' -Maker 'Acme'
Say ("  a make nobody here knows stays unknown   {0}" -f (Mark ($null -eq $unknown)))
Say ("  and the model alone is still enough when there is no maker   {0}" -f (Mark (
    (Get-DeviceMake -Model 'Redmi Note 13').Name -eq 'Xiaomi')))

Say ''
Say '== the colour is the number =='
Say ("  nothing read: {0}   {1}" -f (Get-LoadColor -Percent -1).Name, (Mark (
    (Get-LoadColor -Percent -1) -eq [System.Drawing.Color]::DimGray)))
Say ("  69 and 70 are not the same colour   {0}" -f (Mark (
    (Get-LoadColor -Percent 69) -ne (Get-LoadColor -Percent 70))))
Say ("  89 and 90 are not either   {0}" -f (Mark (
    (Get-LoadColor -Percent 89) -ne (Get-LoadColor -Percent 90))))
Say ("  and 95 is the loudest of the three   {0}" -f (Mark (
    (Get-LoadColor -Percent 95).R -gt (Get-LoadColor -Percent 50).R -and
    (Get-LoadColor -Percent 95) -ne (Get-LoadColor -Percent 75))))

Say ''
Say '== the clipboard line =='
Stop-ClipboardSharing
Say ("  it starts off, and says so: '{0}'   {1}" -f $lblClipLink.Text, (Mark ($lblClipLink.Text -eq 'clipboard off')))
Say ("  it says what a click and a right-click do   {0}" -f (Mark (
    $toolTip.GetToolTip($lblClipLink) -match 'Right-click')))

Say ''
Say '== with the phone that is plugged in =='
if (-not $TestSerial) {
    Say '  SKIPPED - no phone attached right now'
} else {
    Select-TestPhone
    Update-DeviceList
    Wait-Pumped -Milliseconds 1500
    Select-TestPhone
    Update-DeviceStatus
    Say ("  the square has something in it: '{0}' ({1})   {2}" -f $lblDeviceMark.Text,
        $toolTip.GetToolTip($lblDeviceMark), (Mark ("$($lblDeviceMark.Text)" -ne '')))
    Update-DeviceLoadUi -Force
    Say ("  '{0}'  '{1}'  '{2}'" -f $lblDeviceCpu.Text, $lblDeviceRam.Text, $lblDeviceGpu.Text)
    Say ("  the three readings are there   {0}" -f (Mark (
        $lblDeviceCpu.Text -match '^CPU ' -and $lblDeviceRam.Text -match '^RAM ' -and
        $lblDeviceGpu.Text -match '^GPU ')))
    Say ("  the memory says how much of how much   {0}" -f (Mark (
        $lblDeviceRam.Text -match '^RAM (\d+% of [\d.]+ [KMGT]?B|-)$')))
    Say ("  a phone that will not say its GPU says that   {0}" -f (Mark (
        $lblDeviceGpu.Text -match '^GPU (\d+%|not readable)$')))

    # the two gestures of the clipboard line, by the names its handler calls
    $tabs.SelectedTab = $tabDevice
    Show-ClipboardPage
    Wait-Pumped -Milliseconds 200
    Say ("  a click opens the page: {0} / {1}   {2}" -f $tabs.SelectedTab.Text, $tabsAdvanced.SelectedTab.Text,
        (Mark ($tabs.SelectedTab -eq $tabAdvanced -and $tabsAdvanced.SelectedTab -eq $tabClipboard)))
    Say ("  and opening it starts nothing   {0}" -f (Mark (-not (Test-ClipboardSharing))))
    Switch-ClipboardSharing
    Wait-Pumped -Milliseconds 600
    Say ("  a right-click starts it: '{0}'   {1}" -f $lblClipLink.Text, (Mark (
        (Test-ClipboardSharing) -and $lblClipLink.Text -match '^clipboard on')))
    Switch-ClipboardSharing
    Wait-Pumped -Milliseconds 400
    Say ("  and another stops it: '{0}'   {1}" -f $lblClipLink.Text, (Mark (
        (-not (Test-ClipboardSharing)) -and $lblClipLink.Text -eq 'clipboard off')))
}
