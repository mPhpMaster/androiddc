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
    # the watch that reads the attached phones every couple of seconds is a
    # real phone's worth of adb calls landing in the middle of made-up ones,
    # and this page's last check is that nothing reached a real phone
    if ($script:deviceWatchTimer) { $script:deviceWatchTimer.Stop() }
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
    if ($script:deviceWatchTimer) { $script:deviceWatchTimer.Start() }
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
    # the delete goes as one where clause for every contact picked (a
    # hundred to a call), so one contact is a list of one
    Say ("  Yes deletes that raw contact   {0}" -f (Mark (Test-SameWords @($words | Select-Object -First 6) @('content', 'delete', '--uri',
        'content://com.android.contacts/raw_contacts', '--where', '_id IN (8)'))))

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

    Say ''
    Say '== the same contact twice =='
    # Every row says which account it is in: the first version did not look,
    # treated a WhatsApp entry as a copy of the real contact, and deleted the
    # real one - 257 and 325 contacts off two phones. These rows are that case
    # and the others the rules exist for.
    $g = 'com.google'
    $me = 'someone@example.com'
    $twice = @(
        [PSCustomObject]@{ Name = 'Ali'; Number = '+92 323 8886800'; RawId = '10'; DataId = '100'; AccountType = $g; AccountName = $me },
        # a copy of 10 in the same account, spaces and case aside: it goes
        [PSCustomObject]@{ Name = 'ali '; Number = '+923238886800'; RawId = '11'; DataId = '110'; AccountType = $g; AccountName = $me },
        # WhatsApp's own entry for the same person: never a copy, never deleted
        [PSCustomObject]@{ Name = 'Ali'; Number = '+923238886800'; RawId = '5'; DataId = '50'; AccountType = 'com.whatsapp'; AccountName = 'WhatsApp' },
        # the only real contact for Sara, next to WhatsApp's older entry: stays
        [PSCustomObject]@{ Name = 'Sara'; Number = '0501111111'; RawId = '30'; DataId = '300'; AccountType = $g; AccountName = $me },
        [PSCustomObject]@{ Name = 'Sara'; Number = '0501111111'; RawId = '6'; DataId = '60'; AccountType = 'com.whatsapp'; AccountName = 'WhatsApp' },
        # the same name and number in the phone's own contacts: another account, so not a copy
        [PSCustomObject]@{ Name = 'Sara'; Number = '0501111111'; RawId = '31'; DataId = '310'; AccountType = ''; AccountName = '' },
        # a copy that holds an email as well (named in -Rich): kept
        [PSCustomObject]@{ Name = 'Ali'; Number = '+923238886800'; RawId = '12'; DataId = '120'; AccountType = $g; AccountName = $me },
        # one contact holding a number twice: its second row goes
        [PSCustomObject]@{ Name = 'Mona'; Number = '0533'; RawId = '20'; DataId = '200'; AccountType = $g; AccountName = $me },
        [PSCustomObject]@{ Name = 'Mona'; Number = '053-3'; RawId = '20'; DataId = '201'; AccountType = $g; AccountName = $me },
        # which country a local number is would be a guess: it stays
        [PSCustomObject]@{ Name = 'Mona'; Number = '+966533'; RawId = '21'; DataId = '210'; AccountType = $g; AccountName = $me })
    $plan = Get-ContactDuplicates -Rows $twice -Rich @('12')
    Say ("  contacts that go: {0}; numbers that go: {1}; address-book contacts that stay: {2}" -f (@($plan.Gone) -join ','),
        (@($plan.Extra) -join ','), $plan.Kept)
    # 12 stays for its email and holds the same number in the same account, so
    # 10 has nothing of its own either
    Say ("  the copies in the same account go, and only they   {0}" -f (Mark ((@($plan.Gone | Sort-Object) -join ',') -eq '10,11')))
    Say ("  a WhatsApp entry is neither deleted nor counted as the copy that stays   {0}" -f (Mark (
        @($plan.Gone | Where-Object { $_ -in @('5', '6', '30') }).Count -eq 0)))
    Say ("  the same contact in another account is not a copy   {0}" -f (Mark (
        @($plan.Gone | Where-Object { $_ -in @('30', '31') }).Count -eq 0)))
    Say ("  a contact holding more than a name and numbers is kept   {0}" -f (Mark (@($plan.Gone) -notcontains '12')))
    Say ("  a number twice inside one contact loses its second row, not the contact   {0}" -f (Mark (
        (@($plan.Extra) -join ',') -eq '201')))
    $onlyApps = Get-ContactDuplicates -Rows @($twice[2], $twice[4], $twice[3])
    Say ("  a phone with no contacts at all: nothing to do, and no error   {0}" -f (Mark (
        @((Get-ContactDuplicates -Rows @()).Gone).Count -eq 0 -and @((Get-ContactDuplicates -Rows $null).Gone).Count -eq 0)))
    Say ("  with only app entries beside it, the real contact is never the one to go   {0}" -f (Mark (
        @($onlyApps.Gone).Count -eq 0 -and @($onlyApps.Extra).Count -eq 0)))
    Say ("  an account type nobody listed is left alone: {0}   {1}" -f ((@('com.google', '', 'com.whatsapp', 'org.telegram.messenger',
        'USIM Account', 'something.new') | ForEach-Object { "$_=$(Test-ContactBookAccount -Type $_)" }) -join ' '), (Mark (
        (Test-ContactBookAccount -Type 'com.google') -and (Test-ContactBookAccount -Type '') -and
        -not (Test-ContactBookAccount -Type 'com.whatsapp') -and -not (Test-ContactBookAccount -Type 'org.telegram.messenger') -and
        -not (Test-ContactBookAccount -Type 'USIM Account') -and -not (Test-ContactBookAccount -Type 'something.new'))))
    Say ("  the question counts both kinds and says apps are not touched   {0}" -f (Mark (
        (Get-ContactDuplicateQuestion -Plan $plan) -match '2 contact\(s\) are a second copy of another one in the same account' -and
        (Get-ContactDuplicateQuestion -Plan $plan) -match '1 number\(s\) are saved twice' -and
        (Get-ContactDuplicateQuestion -Plan $plan) -match 'WhatsApp, Telegram and SIM entries are not touched')))

    $answer = (@(for ($i = 0; $i -lt $twice.Count; $i++) {
        $row = $twice[$i]
        "Row: $i _id=$($row.DataId), raw_contact_id=$($row.RawId), account_type=$($row.AccountType), account_name=$($row.AccountName), data1=$($row.Number), display_name=$($row.Name)"
    }) -join "`n")
    # what the data table says beyond names and numbers: 12 has an email, and
    # every contact has the empty note Google keeps on all of them
    $kinds = (@(
        'Row: 0 raw_contact_id=12, mimetype=vnd.android.cursor.item/email_v2, data1=ali@example.com',
        'Row: 1 raw_contact_id=11, mimetype=vnd.android.cursor.item/note, data1=NULL',
        'Row: 2 raw_contact_id=10, mimetype=vnd.android.cursor.item/nickname, data1=') -join "`n")
    $script:mockReply = {
        param([string]$Line)
        if ($Line -match '^content query --uri content://com.android.contacts/data/phones') { return $answer }
        if ($Line -match '^content query --uri content://com.android.contacts/data --projection raw_contact_id:mimetype') { return $kinds }
        if ($Line -match 'getprop ro.product.model') { return 'Test Phone' }
        return ''
    }
    $read = Get-PhoneContactPlan -Serial $script:mockSerial
    Say ("  read off the phone: an email keeps 12, an empty note does not keep 11   {0}" -f (Mark (
        (@($read.Gone | Sort-Object) -join ',') -eq '10,11' -and (@($read.Extra) -join ',') -eq '201')))

    # where the copy of what goes is written: a folder of the test's own
    $saveRoot = Join-Path $env:TEMP ('androiddc-removed-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $saveRoot -Force
    $null = Set-BackupFolderPath -Folder $saveRoot
    try {
        $script:mockConfirm = $false
        Reset-TestRecord
        Remove-ContactDuplicates
        Say ("  Remove duplicates asks; No deletes nothing and saves nothing   {0}" -f (Mark (
            $script:mockAsked.Count -eq 1 -and $script:mockText.Count -eq 0 -and
            @(Get-ChildItem -LiteralPath $saveRoot).Count -eq 0)))
        $script:mockConfirm = $true
        Reset-TestRecord
        Remove-ContactDuplicates
        $sentAll = ($script:mockText -join ' | ')
        Say ("  Yes: '{0}'" -f $sentAll)
        Say ("  the copy goes as a contact and the spare number as a data row, a call each   {0}" -f (Mark (
            $script:mockText.Count -eq 2 -and
            $sentAll -match 'content delete --uri content://com\.android\.contacts/raw_contacts --where .?_id IN \(11,10\)' -and
            $sentAll -match 'content delete --uri content://com\.android\.contacts/data --where .?_id IN \(201\)')))
        $savedFolder = @(Get-ChildItem -LiteralPath $saveRoot -Directory | Select-Object -First 1)
        $savedRows = @()
        $removedRows = @()
        if ($savedFolder.Count -gt 0) {
            $read = (Get-Content -LiteralPath (Join-Path $savedFolder[0].FullName 'personal\contacts.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
            $savedRows = @($read)
            $read = (Get-Content -LiteralPath (Join-Path $savedFolder[0].FullName 'removed.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
            $removedRows = @($read)
        }
        # the whole address book: the 8 rows of Google and the phone's own
        # contacts, not the 2 WhatsApp ones and not just the 3 that go
        Say ("  the whole address book was saved first, as a backup: {0}   {1}" -f $(if ($savedFolder.Count) { $savedFolder[0].Name } else { 'nothing' }), (Mark (
            $savedFolder.Count -eq 1 -and $savedFolder[0].Name -like "AndroidDC-backup-before-removing-duplicates-Test-Phone-$script:mockSerial-*" -and
            $savedRows.Count -eq 8 -and @($savedRows | Where-Object { $_.AccountType -eq 'com.whatsapp' }).Count -eq 0 -and
            @($savedRows | Where-Object { $_.AccountType -eq 'com.google' -and $_.AccountName -eq $me }).Count -eq 7)))
        Say ("  each number says which contact it was in, so a contact goes back whole   {0}" -f (Mark (
            @($savedRows | Where-Object { $_.Group -eq '20' }).Count -eq 2)))
        Say ("  and what goes is written down beside it: {0} row(s)   {1}" -f $removedRows.Count, (Mark ($removedRows.Count -eq 3)))
        $checked = @($script:mockAdb | Where-Object { $_ -match '^content query --uri content://com.android.contacts/data/phones' }).Count
        Say ("  the phone is read again after, to check: {0} read(s) of the numbers   {1}" -f $checked, (Mark ($checked -ge 2)))
        $listed = @(Get-BackupsInFolder -Folder $saveRoot)
        Say ("  and the backups list shows it, to open and put back   {0}" -f (Mark ($listed.Count -eq 1)))

        # something gone that should not have: the check finds it and puts it back
        $short = (@($answer -split "`n" | Where-Object { $_ -notmatch 'display_name=Sara' -or $_ -match 'account_type=com.whatsapp' }) -join "`n")
        $script:reads = 0
        $script:mockReply = {
            param([string]$Line)
            if ($Line -match '^content query --uri content://com.android.contacts/data/phones') {
                $script:reads++
                # the first read is the plan; after the delete, Sara's real contacts are gone
                if ($script:reads -eq 1) { return $answer } else { return $short }
            }
            if ($Line -match '^content query --uri content://com.android.contacts/data --projection raw_contact_id:mimetype') { return $kinds }
            if ($Line -match 'getprop ro.product.model') { return 'Test Phone' }
            return ''
        }
        Reset-TestRecord
        $lostRun = & {
            function Restore-BackupContacts { param($Source, $Serial) $script:putBackFrom = "$Source"; [PSCustomObject]@{ Added = 2; Failed = 0; Skipped = 0; Stopped = ''; Error = '' } }
            $script:putBackFrom = ''
            $plan = Get-PhoneContactPlan -Serial $script:mockSerial
            $result = Invoke-ContactDuplicateRemoval -Serial $script:mockSerial -Plan $plan
            [PSCustomObject]@{ Result = $result; From = $script:putBackFrom }
        }
        Say ("  a name and number gone that should not be: found ({0}) and put back from the backup just taken   {1}" -f $lostRun.Result.Lost, (Mark (
            $lostRun.Result.Lost -eq 1 -and $lostRun.Result.PutBack -eq 2 -and $lostRun.From -and $lostRun.From -eq $lostRun.Result.Saved)))
        $script:mockReply = {
            param([string]$Line)
            if ($Line -match '^content query --uri content://com.android.contacts/data/phones') { return $answer }
            if ($Line -match '^content query --uri content://com.android.contacts/data --projection raw_contact_id:mimetype') { return $kinds }
            if ($Line -match 'getprop ro.product.model') { return 'Test Phone' }
            return ''
        }

        # a copy that cannot be written deletes nothing
        Reset-TestRecord
        & {
            function Save-BackupText { param($Path, $Text) throw 'the disk is full' }
            Remove-ContactDuplicates
        }
        Say ("  when the copy cannot be written, nothing is deleted   {0}" -f (Mark ($script:mockText.Count -eq 0)))
    } finally {
        Remove-Item -LiteralPath $saveRoot -Recurse -Force -ErrorAction SilentlyContinue
        $null = Set-BackupFolderPath -Folder ''
    }

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
