# The Contacts page: the contacts provider's answer read into rows, the
# filter, the export lines, the dial box, and every action that would change
# the phone (add, edit, delete, call, end call) run against a made-up serial
# with adb replaced, so each command is recorded and none is sent. With a
# phone attached, only a read of the contacts provider. Nothing personal is
# printed: counts only. Needs the Messages page (Split-ContentRows).

# ----------------------------------------------------------- the mock ----
$script:mockSerial = 'MOCK-SERIAL'
$script:mockAdb = New-Object System.Collections.ArrayList
$script:mockText = New-Object System.Collections.ArrayList
$script:mockAsked = New-Object System.Collections.ArrayList
$script:mockLeaks = New-Object System.Collections.ArrayList
$script:mockConfirm = $true
$script:mockInput = $null
$script:mockReply = { param([string]$Line) '' }
$script:mockOriginals = @{}

function Enable-TestMocks {
    foreach ($name in @('Invoke-Adb', 'Invoke-DeviceShellText', 'Get-TargetSerial', 'Show-Confirm', 'Show-InputDialog')) {
        $script:mockOriginals[$name] = (Get-Item "function:$name").ScriptBlock
    }
    Set-Item -Path 'function:script:Invoke-Adb' -Value {
        param([string[]]$CommandArguments, [int]$TimeoutMs = 180000)
        $all = @($CommandArguments)
        if ($all.Count -ge 3 -and $all[0] -eq '-s' -and $all[1] -eq $script:mockSerial) {
            $line = ($all | Select-Object -Skip 3) -join ' '
            $null = $script:mockAdb.Add($line)
            $lines = @(@(& $script:mockReply $line) | ForEach-Object { "$_" -split "`n" })
            return [PSCustomObject]@{ ExitCode = 0; Lines = $lines; Text = ($lines -join "`n") }
        }
        if ($all -contains 'shell' -or $all -contains 'exec-out') {
            $null = $script:mockLeaks.Add('adb')
            return [PSCustomObject]@{ ExitCode = -1; Lines = @(); Text = '' }
        }
        return (& $script:mockOriginals['Invoke-Adb'] -CommandArguments $CommandArguments -TimeoutMs $TimeoutMs)
    }
    Set-Item -Path 'function:script:Invoke-DeviceShellText' -Value {
        param([string]$Serial, [string]$Command)
        if ($Serial -ne $script:mockSerial) { $null = $script:mockLeaks.Add('text'); return [PSCustomObject]@{ ExitCode = -1; Lines = @(); Text = '' } }
        $null = $script:mockText.Add($Command)
        $lines = @(@(& $script:mockReply $Command) | ForEach-Object { "$_" -split "`n" })
        return [PSCustomObject]@{ ExitCode = 0; Lines = $lines; Text = ($lines -join "`n") }
    }
    Set-Item -Path 'function:script:Get-TargetSerial' -Value { return $script:mockSerial }
    Set-Item -Path 'function:script:Show-Confirm' -Value {
        param([string]$Title, [string]$Text, [string]$Yes = 'OK', [string]$No = 'Cancel', [switch]$Danger)
        $null = $script:mockAsked.Add("$Title|$Text")
        return [bool]$script:mockConfirm
    }
    Set-Item -Path 'function:script:Show-InputDialog' -Value {
        param([string]$Title, [string[]]$Fields, [string[]]$Values, [string]$Hint, [string[]]$Secret = @(),
            [string[]]$Multiline = @(), [string]$OkText = 'OK')
        $null = $script:mockAsked.Add($Title)
        if ($null -eq $script:mockInput) { return $null }
        return @($script:mockInput)
    }
}

function Disable-TestMocks {
    foreach ($name in @($script:mockOriginals.Keys)) { Set-Item -Path "function:script:$name" -Value $script:mockOriginals[$name] }
}

function Reset-TestRecord {
    $script:mockAdb.Clear(); $script:mockText.Clear(); $script:mockAsked.Clear()
}

function Split-TestShellWords {
    # the words sh makes of a line: single quotes, double quotes, backslash
    param([string]$Line)
    $words = New-Object System.Collections.ArrayList
    $word = New-Object System.Text.StringBuilder
    $inWord = $false
    $quote = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote -eq [char]39) {
            if ($c -eq [char]39) { $quote = [char]0 } else { $null = $word.Append($c) }
            continue
        }
        if ($quote -eq [char]34) {
            if ($c -eq [char]34) { $quote = [char]0 }
            elseif ($c -eq [char]92 -and $i + 1 -lt $Line.Length -and ('$`"\').Contains([string]$Line[$i + 1])) { $i++; $null = $word.Append($Line[$i]) }
            else { $null = $word.Append($c) }
            continue
        }
        if ($c -eq [char]39 -or $c -eq [char]34) { $quote = $c; $inWord = $true; continue }
        if ($c -eq [char]92 -and $i + 1 -lt $Line.Length) { $i++; $null = $word.Append($Line[$i]); $inWord = $true; continue }
        if ([char]::IsWhiteSpace($c)) {
            if ($inWord) { $null = $words.Add($word.ToString()); $null = $word.Clear(); $inWord = $false }
            continue
        }
        $null = $word.Append($c)
        $inWord = $true
    }
    if ($inWord) { $null = $words.Add($word.ToString()) }
    return ,@($words)
}

function Test-SameWords {
    param($Got, $Want)
    $sep = [string][char]0x1F
    return (@($Got).Count -eq @($Want).Count -and (@($Got) -join $sep) -ceq (@($Want) -join $sep))
}

# ------------------------------------------------------------- startup ----
Say '== startup =='
$idle = Wait-Idle -Seconds 60
Say ("  idle after the first reads   {0}" -f (Mark $idle))
$page = Get-Page -Key 'contacts'
Say ("  the page is registered under Personal   {0}" -f (Mark ($null -ne $page -and $page.Section -eq 'Personal')))
Say ("  the Messages page is loaded for the provider reader   {0}" -f (Mark ([bool](Get-Command Split-ContentRows -ErrorAction SilentlyContinue))))
Show-Page -Page 'contacts'
$null = Wait-Idle -Seconds 30

Say ''
Say '== the provider answer, made up =='
$arabic = -join [char[]](0x0645, 0x0631, 0x062D, 0x0628, 0x0627)
$query = @(
    'Row: 0 display_name=Test Person, data1=050 123 4567, contact_id=5, raw_contact_id=6',
    'Row: 1 display_name=Smith, Jane, data1=+15550002, contact_id=7, raw_contact_id=8',
    "Row: 2 display_name=$arabic, data1=+15550003, contact_id=9, raw_contact_id=10",
    'Row: 3 display_name=No Number, data1=, contact_id=11, raw_contact_id=12'
) -join "`n"
$rows = @(Get-ContactsRows -Text $query)
Say ("  {0} numbers, the one without a number left out   {1}" -f $rows.Count, (Mark ($rows.Count -eq 3)))
Say ("  a name with a comma is kept whole   {0}" -f (Mark ($rows[1].Name -eq 'Smith, Jane' -and $rows[1].RawId -eq '8')))
Say ("  Arabic survives   {0}" -f (Mark ($rows[2].Name -ceq $arabic)))

$script:contactsRows.Clear()
foreach ($row in $rows) { $script:contactsRows.Add($row) }
$ui.ContactsFilter.Text = 'smith'
Say ("  the filter, any case: {0} shown   {1}" -f @(Get-ContactsShown).Count, (Mark (@(Get-ContactsShown).Count -eq 1)))
$ui.ContactsFilter.Text = '555000'
Say ("  by number too: {0} shown, '{1}'   {2}" -f @(Get-ContactsShown).Count, $ui.ContactsCount.Text, (Mark (@(Get-ContactsShown).Count -eq 2 -and $ui.ContactsCount.Text -eq '2 of 3 numbers')))
$ui.ContactsFilter.Text = ''
Say ("  empty filter shows all   {0}" -f (Mark (@(Get-ContactsShown).Count -eq 3)))

$csv = @(Get-ContactsExportLines -Rows @([PSCustomObject]@{ Name = 'Say "Hi"'; Number = '1' }))
Say ("  CSV export: header and quotes made safe   {0}" -f (Mark ($csv.Count -eq 2 -and $csv[1] -eq '"Say ''Hi''","1"')))
$vcf = @(Get-ContactsExportLines -Rows $rows -VCard)
Say ("  vCard export: five lines a contact   {0}" -f (Mark ($vcf.Count -eq 15 -and $vcf[2] -eq 'FN:Test Person' -and $vcf[3] -eq 'TEL:050 123 4567')))

$ui.ContactsDial.Text = ''
$ui.ContactsList.SelectedItem = $script:contactsRows[1]
Wait-Pumped -Milliseconds 100
Say ("  picking a contact puts its number in the dial box   {0}" -f (Mark ($ui.ContactsDial.Text -eq '+15550002')))

Say ''
Say '== actions, against a made-up serial =='
Enable-TestMocks
try {
    Say ("  the mock is in place   {0}" -f (Mark ((Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial')))
    $script:mockReply = {
        param([string]$Line)
        if ($Line -match "_id DESC") { return 'Row: 0 _id=4242' }
        if ($Line -match '^content query --uri content://com.android.contacts/data/phones') { return $query }
        return ''
    }

    $name = "O'Brien `"Jr`" `$HOME $arabic"
    $number = '050 123 4567'
    $script:mockInput = @("  $name  ", $number)
    Reset-TestRecord
    Add-Contact
    $sent = @($script:mockText)
    Say ("  Add finds the new row with --sort '_id DESC'   {0}" -f (Mark (@($script:mockAdb | Where-Object { $_ -match "--sort '_id DESC' \| head -1" }).Count -eq 1)))
    $nameWords = if ($sent.Count -ge 1) { Split-TestShellWords $sent[0] } else { @() }
    $phoneWords = if ($sent.Count -ge 2) { Split-TestShellWords $sent[1] } else { @() }
    Say ("  the name arrives whole, on the new row   {0}" -f (Mark (Test-SameWords $nameWords @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', 'raw_contact_id:i:4242', '--bind', 'mimetype:s:vnd.android.cursor.item/name', '--bind', "data1:s:$name"))))
    Say ("  the number arrives whole, spaces and all   {0}" -f (Mark (Test-SameWords $phoneWords @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', 'raw_contact_id:i:4242', '--bind', 'mimetype:s:vnd.android.cursor.item/phone_v2', '--bind', "data1:s:$number"))))

    $script:mockInput = $null
    Reset-TestRecord
    Add-Contact
    Say ("  a cancelled Add sends nothing   {0}" -f (Mark ($script:mockAdb.Count -eq 0 -and $script:mockText.Count -eq 0)))

    $script:contactsRows.Clear()
    foreach ($row in $rows) { $script:contactsRows.Add($row) }
    $ui.ContactsList.SelectedItems.Clear()
    $ui.ContactsList.SelectedItems.Add($script:contactsRows[0])
    $script:mockInput = @($name, $number)
    Reset-TestRecord
    Edit-Contact
    $words = if ($script:mockText.Count -ge 1) { Split-TestShellWords $script:mockText[0] } else { @() }
    Say ("  Edit: the where clause with its quotes arrives whole   {0}" -f (Mark (Test-SameWords $words @('content', 'update', '--uri',
        'content://com.android.contacts/data', '--bind', "data1:s:$name", '--where', "raw_contact_id=6 AND mimetype='vnd.android.cursor.item/name'"))))
    $script:mockInput = $null

    $script:contactsRows.Clear()
    foreach ($row in $rows) { $script:contactsRows.Add($row) }
    $ui.ContactsList.SelectedItems.Clear()
    $ui.ContactsList.SelectedItems.Add($script:contactsRows[1])
    $script:mockConfirm = $false
    Reset-TestRecord
    Remove-Contact
    Say ("  Delete asks; No deletes nothing   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockText.Count -eq 0)))
    $script:mockConfirm = $true
    Reset-TestRecord
    Remove-Contact
    $words = if ($script:mockText.Count -ge 1) { Split-TestShellWords $script:mockText[0] } else { @() }
    Say ("  Yes deletes that raw contact   {0}" -f (Mark (Test-SameWords $words @('content', 'delete', '--uri',
        'content://com.android.contacts/raw_contacts', '--where', '_id=8'))))

    $ui.ContactsList.SelectedItems.Clear()
    $ui.ContactsDial.Text = $number
    $script:mockConfirm = $false
    Reset-TestRecord
    Start-PhoneCall
    Say ("  Call asks; No calls nobody   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockText.Count -eq 0)))
    $script:mockConfirm = $true
    Reset-TestRecord
    Start-PhoneCall
    $words = if ($script:mockText.Count -ge 1) { Split-TestShellWords $script:mockText[0] } else { @() }
    Say ("  Yes: the number with spaces arrives whole   {0}" -f (Mark (Test-SameWords $words @('am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$number"))))
    $ui.ContactsDial.Text = ''
    Reset-TestRecord
    Start-PhoneCall
    Say ("  no number: refused before the question   {0}" -f (Mark ($script:mockAsked.Count -eq 0 -and $script:mockText.Count -eq 0)))

    Reset-TestRecord
    Stop-PhoneCall
    Say ("  End call sends KEYCODE_ENDCALL   {0}" -f (Mark ($script:mockAdb -contains 'input keyevent 6')))

    Say ("  no command reached a real phone   {0}" -f (Mark ($script:mockLeaks.Count -eq 0)))
} finally {
    Disable-TestMocks
    $script:mockInput = $null
}
Say ("  the real functions are back   {0}" -f (Mark (-not ((Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial'))))

Say ''
Say '== the phone, reads only =='
$serial = Get-SelectedSerial
$ready = $null -ne $serial -and @($script:deviceRows | Where-Object { $_.Serial -eq $serial -and $_.State -eq 'device' }).Count -gt 0
if (-not $ready) {
    Say '  SKIPPED - no phone attached'
} else {
    Clear-ContactsList
    Update-ContactList
    $numbers = @($script:contactsRows | Where-Object { -not $_.Number }).Count
    Say ("  read {0} number(s), every row with a number and a raw id   {1}" -f $script:contactsRows.Count,
        (Mark ($numbers -eq 0 -and @($script:contactsRows | Where-Object { -not $_.RawId }).Count -eq 0)))
    Clear-ContactsList
}

Say ''
Say '== the pictures (made-up rows) =='
Clear-ContactsList
foreach ($row in @(
        [PSCustomObject]@{ Name = 'Test Person'; Number = '+15550001'; ContactId = '5'; RawId = '6' },
        [PSCustomObject]@{ Name = 'Another Test'; Number = '+15550002'; ContactId = '7'; RawId = '8' },
        [PSCustomObject]@{ Name = "Test $arabic"; Number = '+15550003'; ContactId = '9'; RawId = '10' })) {
    $script:contactsRows.Add($row)
}
Set-ContactsFilterView
$ui.ContactsDial.Text = '+15550001'
$ui.DeviceTitle.Text = 'Test phone'
$ui.DeviceSubtitle.Text = 'made-up rows for the picture'
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    $script:logLines.Clear()
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "contacts-$size"))
    $outside = @(Get-OutsideElements -Root $page.Root)
    Say ("  {0}: nothing sticks out   {1}" -f $size, (Mark ($outside.Count -eq 0)))
    foreach ($entry in $outside) { Say "      $entry" }
    $listHeight = $ui.ContactsList.ActualHeight
    Say ("  {0}: the list keeps {1:N0} px   {2}" -f $size, $listHeight, (Mark ($listHeight -ge 100)))
}
Clear-ContactsList
$ui.ContactsDial.Text = ''
