# Contacts on the phone, written in as few calls as the phone will allow.
#
# Measured on the test phone, which is where every number below comes from:
#
#   one adb call                             about 200 ms, whatever it carries
#   ten commands sent together               129 ms for all ten
#   one "content" call                       about 1500 ms - any content call
#   one raw_contacts insert                  1477 ms
#   one data insert                          1546 ms
#   the newest-id query it used to do        1812 ms, once per contact
#
# "content" is a shell script on the phone that runs app_process: a whole Java
# runtime starts for every call, and that is where the 1500 ms goes. A query
# for one row by its id costs the same as one that sorts the whole table.
#
# So there are two separate wins here, and they are not the same win:
#
#   Deleting went one call per contact, and a where clause takes a hundred ids
#   at a time. A phone's worth went from 4.8 minutes to about twenty seconds.
#
#   Adding cannot be won that way: a contact needs three content calls - the
#   row, the name, the number - and no batching makes a Java runtime start
#   faster. Dropping the per-contact id query takes it from about 7.2 s a
#   contact to about 4.5, which for a phone's worth is still over an hour.
#   That is why Send-ContactsAsVcard exists: one file the phone's own Contacts
#   reads, in seconds, at the cost of a tap on the phone.

# How much script one call carries. The whole line reaches adb as one Windows
# argument, Windows stops a command line at 32767 characters all told, and
# base64 adds a third on top. 6000 leaves room to spare either way.
$script:contactChunkChars = 6000

function Get-ContactScriptChunks {
    <#
        Blocks of shell, grouped into as few calls as the line length allows.
        A block is never split across two calls: half of one would leave a
        contact with a row and no name.
    #>
    param([string[]]$Blocks)

    $chunks = New-Object System.Collections.Generic.List[object]
    $now = New-Object System.Collections.Generic.List[string]
    $size = 0
    foreach ($block in $Blocks) {
        $length = "$block".Length + 1
        if ($now.Count -gt 0 -and ($size + $length) -gt $script:contactChunkChars) {
            $null = $chunks.Add(($now -join "`n"))
            $now = New-Object System.Collections.Generic.List[string]
            $size = 0
        }
        $null = $now.Add($block)
        $size += $length
    }
    if ($now.Count -gt 0) { $null = $chunks.Add(($now -join "`n")) }
    return ,$chunks.ToArray()
}

function Get-ContactAnswerLine {
    # one line out of what the phone said, not its whole Java stack
    param([string]$Text)

    foreach ($line in ("$Text" -split "`r?`n")) {
        $said = "$line".Trim()
        if (-not $said) { continue }
        if ($said -like 'at *') { continue }
        if ($said -match 'Exception|Error|Denial') { return $said }
    }
    return ("$Text" -split "`r?`n")[0]
}

# ------------------------------------------------------------- deleting ----

function New-ContactDeleteBlock {
    # one delete, for as many rows as the where clause names: whole contacts
    # (raw_contacts), or single numbers out of one (data)
    param([string[]]$RawIds, [ValidateSet('raw_contacts', 'data')][string]$Table = 'raw_contacts')

    $list = (@($RawIds | ForEach-Object { "$_" -replace '\D', '' } | Where-Object { $_ }) -join ',')
    if (-not $list) { return '' }
    return ("content delete --uri content://com.android.contacts/$Table " +
        '--where ' + (Quote-DeviceArgument "_id IN ($list)"))
}

function Remove-PhoneContacts {
    <#
        The contacts whose raw ids are given, off the phone.

        One call carried one delete, so clearing a phone was one adb call and
        one Java runtime per contact. Android's provider takes a where clause,
        so a hundred rows go in one.

        It stops between calls, which is what makes Cancel mean anything: the
        window shows one while this is running.
    #>
    param([string]$Serial, [string[]]$RawIds, [int]$PerClause = 100,
        [ValidateSet('raw_contacts', 'data')][string]$Table = 'raw_contacts')

    $ids = @($RawIds | ForEach-Object { "$_" -replace '\D', '' } | Where-Object { $_ })
    if ($ids.Count -eq 0) { return [PSCustomObject]@{ Deleted = 0; Calls = 0; Failed = 0; Stopped = $false } }

    $blocks = New-Object System.Collections.Generic.List[string]
    $counts = New-Object System.Collections.Generic.List[int]
    for ($at = 0; $at -lt $ids.Count; $at += $PerClause) {
        $take = [Math]::Min($PerClause, $ids.Count - $at)
        $null = $blocks.Add((New-ContactDeleteBlock -RawIds @($ids[$at..($at + $take - 1)]) -Table $Table))
        $null = $counts.Add($take)
    }

    $calls = 0
    $failed = 0
    $done = 0
    $block = 0
    foreach ($chunk in (Get-ContactScriptChunks -Blocks $blocks.ToArray())) {
        if (Test-BackupStopped) {
            return [PSCustomObject]@{ Deleted = $done; Calls = $calls; Failed = $failed; Stopped = $true }
        }
        # how many contacts this call carries: a chunk may hold several clauses
        $here = ([regex]::Matches($chunk, '_id IN \(')).Count
        $carried = 0
        for ($i = 0; $i -lt $here; $i++) { $carried += $counts[$block + $i] }
        $block += $here

        $result = Invoke-DeviceShellText -Serial $Serial -Command $chunk
        $calls++
        if ("$($result.Text)" -match 'Error|Exception') { $failed++ } else { $done += $carried }
        Invoke-BackupPump
    }
    return [PSCustomObject]@{ Deleted = $done; Calls = $calls; Failed = $failed; Stopped = $false }
}

function Get-ContactDeleteQuestion {
    <#
        The question asked before contacts are deleted.

        It used to name every one of them. With a phone's worth selected the
        box grew past the screen and took its own buttons with it, so the
        question could not be answered at all. It names a few and counts the
        rest, which is what a person can read anyway.
    #>
    param($Items, [int]$Show = 12)

    $rows = @($Items)
    if ($rows.Count -eq 0) { return 'Delete these contacts from the phone?' }
    $head = $(if ($rows.Count -eq 1) { 'Delete this contact from the phone?' }
        else { "Delete $($rows.Count) contacts from the phone?" })
    $lines = @($rows | Select-Object -First $Show | ForEach-Object {
        $name = "$($_.Name)".Trim()
        $number = "$($_.Number)".Trim()
        if ($name) { "$name  $number" } else { $number }
    })
    if ($rows.Count -gt $Show) { $lines += "... and $($rows.Count - $Show) more" }
    return ($head + [Environment]::NewLine + [Environment]::NewLine + ($lines -join [Environment]::NewLine))
}

# ------------------------------------------------------- the same one twice ----
# What went wrong the first time, so it is not done again. On a phone a
# contact is several raw contacts: the address book's own (a Google account,
# or the phone's), and one more for every app that keeps a copy - WhatsApp,
# Telegram, Meet - each with the same name and number. The first version of
# this treated those as copies of each other, kept whichever was oldest, and
# deleted the rest: often the real Google contact went and a WhatsApp entry
# stayed. Google then deleted it on every phone on that account, and WhatsApp
# dropped its own entry soon after, because the number had left the address
# book. Measured on two phones: 257 and 325 contacts gone.
#
# So now: only the address book is looked at (Test-ContactBookAccount);
# a copy counts only inside one account; a contact holding anything besides a
# name and numbers is never touched; and what is removed is first written as
# a backup the Backup page can open and put back.

function Test-ContactBookAccount {
    <#
        Whether a raw contact is the address book's own: a Google account or
        the phone's contacts. App accounts (WhatsApp, Telegram, Meet, Viber...)
        and the SIM are not, and are neither removed nor counted as a copy.
        Unknown types are left alone too - a type not listed is never deleted.
    #>
    param([string]$Type)

    if (-not "$Type".Trim() -or "$Type" -eq 'null') { return $true }
    return @('com.google', 'com.android.contacts.default', 'vnd.sec.contact.phone', 'com.android.localphone',
        'Local Phone Account', 'com.xiaomi', 'com.oppo.contacts.device', 'com.coloros.contacts.device') -contains "$Type"
}

function Get-ContactKey {
    <#
        What makes two numbers the same contact: the name, with its spaces
        evened out and its case ignored, and the number with only its digits
        and a leading +. "+92 323 8886800" and "+923238886800" are one; "0532"
        and "+966532" are not, because which country a local number belongs
        to is a guess, and a guess here deletes a contact.
    #>
    param([string]$Name, [string]$Number)

    $who = (("$Name" -replace '\s+', ' ').Trim()).ToLowerInvariant()
    $digits = "$Number".Trim()
    $plus = $digits.StartsWith('+')
    $digits = $digits -replace '\D', ''
    if ($plus) { $digits = '+' + $digits }
    return "$who|$digits"
}

function Get-ContactDuplicates {
    <#
        Which address-book contacts are a second copy of another, out of rows
        that carry Name, Number, RawId, DataId, AccountType and AccountName
        (one row per number, as data/phones answers).

        A raw contact goes only when it is in the address book, holds nothing
        but a name and numbers (-Rich names the ones that hold more), and
        every number it holds is held, under the same name, by another raw
        contact of the same account that stays. The oldest copy (the lowest
        raw id) is the one kept. Rows of any other account are ignored: they
        are not removed and they do not count as the copy that stays.

        A raw contact can also hold the same number twice; the second row of
        that number goes, by its data id.

        Returns Gone (raw ids) and Rows (their rows), Extra (data ids) and
        ExtraRows, and Kept (address-book contacts left).
    #>
    param($Rows, [string[]]$Rich = @())

    # not $rich: PowerShell names are not case-sensitive, and that would be
    # the -Rich parameter itself - measured, as a hashtable cast to an int
    $protected = @{}
    foreach ($id in @($Rich)) { $protected["$id"] = $true }
    $keysOf = @{}
    $holders = @{}
    $rowsOf = @{}
    foreach ($row in @($Rows)) {
        # a phone with no contacts hands back nothing, and @(nothing) is one $null
        if ($null -eq $row) { continue }
        $raw = "$($row.RawId)" -replace '\D', ''
        if (-not $raw -or -not "$($row.Number)".Trim()) { continue }
        $type = $(if ($row.PSObject.Properties['AccountType']) { "$($row.AccountType)" } else { '' })
        $account = $(if ($row.PSObject.Properties['AccountName']) { "$($row.AccountName)" } else { '' })
        if (-not (Test-ContactBookAccount -Type $type)) { continue }
        $key = "$type|$account|" + (Get-ContactKey -Name $row.Name -Number $row.Number)
        if (-not $keysOf.ContainsKey($raw)) {
            $keysOf[$raw] = New-Object 'System.Collections.Generic.HashSet[string]'
            $rowsOf[$raw] = New-Object System.Collections.Generic.List[object]
        }
        $null = $rowsOf[$raw].Add($row)
        if ($keysOf[$raw].Add($key)) {
            if ($holders.ContainsKey($key)) { $holders[$key]++ } else { $holders[$key] = 1 }
        }
    }

    $gone = New-Object System.Collections.Generic.List[string]
    $goneRows = New-Object System.Collections.Generic.List[object]
    # newest first, so each one weighed has the older copies still standing
    foreach ($raw in @($keysOf.Keys | Sort-Object { [long]$_ } -Descending)) {
        if ($protected.ContainsKey($raw)) { continue }
        $spare = $true
        foreach ($key in $keysOf[$raw]) { if ($holders[$key] -lt 2) { $spare = $false; break } }
        if (-not $spare) { continue }
        foreach ($key in $keysOf[$raw]) { $holders[$key]-- }
        $null = $gone.Add($raw)
        foreach ($row in $rowsOf[$raw]) { $null = $goneRows.Add($row) }
    }

    $extra = New-Object System.Collections.Generic.List[string]
    $extraRows = New-Object System.Collections.Generic.List[object]
    $leaving = @{}
    foreach ($raw in $gone) { $leaving[$raw] = $true }
    foreach ($raw in $rowsOf.Keys) {
        if ($leaving.ContainsKey($raw)) { continue }
        $seen = @{}
        $ordered = @($rowsOf[$raw] | Where-Object { $_.PSObject.Properties['DataId'] -and "$($_.DataId)" -match '^\d+$' } |
            Sort-Object { [long]"$($_.DataId)" })
        foreach ($row in $ordered) {
            $key = Get-ContactKey -Name $row.Name -Number $row.Number
            if ($seen.ContainsKey($key)) { $null = $extra.Add("$($row.DataId)"); $null = $extraRows.Add($row) }
            else { $seen[$key] = $true }
        }
    }
    return [PSCustomObject]@{ Gone = $gone.ToArray(); Rows = $goneRows.ToArray()
        Extra = $extra.ToArray(); ExtraRows = $extraRows.ToArray(); Kept = ($keysOf.Count - $gone.Count) }
}

function Get-PhoneContactRows {
    # every number in the phone's contacts with the account it is in, read
    # fresh rather than off a list a filter may have cut
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection _id:raw_contact_id:account_type:account_name:data1:display_name')).Text
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in (Split-BackupRows -Text $text)) {
        $number = Get-BackupRowValue -Row $row -Column 'data1'
        if (-not $number) { continue }
        $null = $rows.Add([PSCustomObject]@{
            Name = (Get-BackupRowValue -Row $row -Column 'display_name')
            Number = $number
            RawId = (Get-BackupRowValue -Row $row -Column 'raw_contact_id')
            DataId = (Get-BackupRowValue -Row $row -Column '_id')
            AccountType = (Get-BackupRowValue -Row $row -Column 'account_type')
            AccountName = (Get-BackupRowValue -Row $row -Column 'account_name') })
    }
    return $rows.ToArray()
}

function Get-PhoneContactRichIds {
    <#
        The raw contacts that hold anything besides a name, numbers and the
        group they are in - an email, a photo, a note with text in it, a
        birthday, an address.
        Removing one of those would lose that, so they are never removed.
    #>
    param([string]$Serial)

    # data1 last: a note may hold commas, and the last column takes the rest of the row
    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data --projection raw_contact_id:mimetype:data1')).Text
    $plain = @('vnd.android.cursor.item/name', 'vnd.android.cursor.item/phone_v2', 'vnd.android.cursor.item/group_membership')
    $rich = @{}
    foreach ($row in (Split-BackupRows -Text $text)) {
        $type = Get-BackupRowValue -Row $row -Column 'mimetype'
        if ($plain -contains $type) { continue }
        # Google keeps an empty note and an empty nickname on every contact -
        # measured, 459 of each on 459 contacts - so an empty row holds
        # nothing to lose. A photo keeps its picture elsewhere than data1.
        $value = "$(Get-BackupRowValue -Row $row -Column 'data1')".Trim()
        if ($type -ne 'vnd.android.cursor.item/photo' -and (-not $value -or $value -eq 'NULL')) { continue }
        $id = Get-BackupRowValue -Row $row -Column 'raw_contact_id'
        if ($id) { $rich[$id] = $true }
    }
    return @($rich.Keys)
}

function Get-PhoneContactPlan {
    # the plan for one phone, read off the phone itself
    param([string]$Serial)

    return Get-ContactDuplicates -Rows (Get-PhoneContactRows -Serial $Serial) -Rich (Get-PhoneContactRichIds -Serial $Serial)
}

function Get-ContactDuplicateQuestion {
    # what is about to go, in words: a few by name, the rest counted
    param($Plan, [int]$Show = 10, [string]$SavedTo = '')

    $nl = [Environment]::NewLine
    $rows = @(@($Plan.Rows) + @($Plan.ExtraRows))
    $lines = @($rows | Select-Object -First $Show | ForEach-Object {
        $name = "$($_.Name)".Trim()
        $number = "$($_.Number)".Trim()
        if ($name) { "$name  $number" } else { $number }
    })
    if ($rows.Count -gt $Show) { $lines += "... and $($rows.Count - $Show) more" }
    $what = @()
    if (@($Plan.Gone).Count -gt 0) {
        $what += "$(@($Plan.Gone).Count) contact(s) are a second copy of another one in the same account - the same name and the same number."
    }
    if (@($Plan.Extra).Count -gt 0) {
        $what += "$(@($Plan.Extra).Count) number(s) are saved twice inside the same contact."
    }
    $text = (($what -join $nl) + $nl + 'One of each stays; the copies go. WhatsApp, Telegram and SIM entries are ' +
        'not touched, and a contact with an email, a photo or a note is kept.' + $nl + $nl + ($lines -join $nl))
    if ($SavedTo) { $text += $nl + $nl + "What goes is saved first, as a backup you can put back: $SavedTo" }
    return $text
}

function Save-ContactRemovalBackup {
    <#
        What a removal is about to delete, written first as a backup of its
        own - a folder beside your other backups, holding personal\contacts.json
        with each contact's account - so the Backup page lists it, opens it,
        and Restore contacts puts it back into the account it came from.
        Returns the folder, or '' when it could not be written, in which case
        nothing is deleted.
    #>
    param([string]$Serial, $Plan, [string]$Model = '')

    $rows = @(@($Plan.Rows) + @($Plan.ExtraRows))
    if ($rows.Count -eq 0) { return '' }
    if (-not $Model) {
        $Model = "$((Invoke-DeviceShell -Serial $Serial -CommandArguments @('getprop ro.product.model')).Text)".Trim()
    }
    $root = ''
    if (Get-Command Get-BackupFolderPath -ErrorAction SilentlyContinue) { $root = Get-BackupFolderPath }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        $root = Join-Path $env:APPDATA 'AndroidDC\removed contacts'
    }
    $name = ConvertTo-BackupName -Model $Model -Serial $Serial -Name 'removed duplicates'
    $folder = Join-Path $root $name
    try {
        $contacts = @($rows | ForEach-Object {
            [PSCustomObject]@{ Name = "$($_.Name)"; Number = "$($_.Number)"
                AccountType = "$($_.AccountType)"; AccountName = "$($_.AccountName)" } })
        Save-BackupText -Path (Join-Path $folder 'personal\contacts.json') -Text (ConvertTo-Json -InputObject $contacts -Depth 3)
        Save-BackupText -Path (Join-Path $folder 'manifest.json') -Text (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
            Format = 2; Serial = $Serial; Model = $Model; Android = ''; Created = ([datetime]::Now).ToString('s')
            Name = 'removed duplicates'; Parts = @('personal')
            Personal = [PSCustomObject]@{ Contacts = $contacts.Count; Messages = 0; Calls = 0 }
            Apps = @(); Settings = @(); Bytes = 0; Complete = $true; Stopped = '' }))
    } catch {
        Write-Log ("Remove duplicates: the copy of what goes could not be written, so nothing was deleted - " +
            $_.Exception.Message) $colorBad
        return ''
    }
    return $folder
}

function Remove-PhoneContactDuplicates {
    # the plan carried out, once it is saved: the spare contacts, then the spare numbers
    param([string]$Serial, $Plan, [string]$SavedTo)

    if (-not $SavedTo -or -not (Test-Path -LiteralPath (Join-Path $SavedTo 'personal\contacts.json'))) {
        return [PSCustomObject]@{ Contacts = 0; Numbers = 0; Failed = 1; Stopped = $false }
    }
    $contacts = Remove-PhoneContacts -Serial $Serial -RawIds @($Plan.Gone)
    $numbers = [PSCustomObject]@{ Deleted = 0; Calls = 0; Failed = 0; Stopped = $false }
    if (-not $contacts.Stopped -and @($Plan.Extra).Count -gt 0) {
        $numbers = Remove-PhoneContacts -Serial $Serial -RawIds @($Plan.Extra) -Table 'data'
    }
    return [PSCustomObject]@{ Contacts = $contacts.Deleted; Numbers = $numbers.Deleted
        Failed = ($contacts.Failed + $numbers.Failed); Stopped = ($contacts.Stopped -or $numbers.Stopped) }
}

# -------------------------------------------------- adding, the slow way ----

function New-ContactRowBlock {
    # one bare raw_contacts row; its name and number follow once the id it was
    # given is known
    return ('content insert --uri content://com.android.contacts/raw_contacts ' +
        '--bind account_name:s:null --bind account_type:s:null')
}

function New-ContactDataBlocks {
    <#
        The name and the number for a row whose id is already known.

        The id used to be asked for once per contact, with
        "--sort '_id DESC' | head -1": 1812 ms every time, measured, and the
        same whatever is asked, because it is a Java runtime starting rather
        than a table being read. It is asked once for a whole batch now.
    #>
    param([string]$RawId, [string]$Name, [string]$Number)

    $blocks = New-Object System.Collections.Generic.List[string]
    if ("$Name") {
        $null = $blocks.Add('content insert --uri content://com.android.contacts/data ' +
            "--bind raw_contact_id:i:$RawId " +
            '--bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:' + (Quote-DeviceArgument $Name))
    }
    $null = $blocks.Add('content insert --uri content://com.android.contacts/data ' +
        "--bind raw_contact_id:i:$RawId " +
        '--bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:' + (Quote-DeviceArgument $Number))
    return ,$blocks.ToArray()
}

function Get-NewestContactIds {
    # the ids of the newest rows, the oldest of them first, which is the order
    # they were made in
    param([string]$Serial, [int]$Count)

    if ($Count -le 0) { return ,@() }
    $text = (Invoke-DeviceShellText -Serial $Serial -Command (
        'content query --uri content://com.android.contacts/raw_contacts --projection _id ' +
        "--sort '_id DESC' | head -$Count")).Text
    $ids = @([regex]::Matches("$text", '_id=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object)
    return ,$ids
}

function Add-PhoneContacts {
    <#
        Contacts onto the phone through its content provider, a batch at a
        time: the rows, then the ids they were given, then every name and
        number at once. Three calls a batch, where it was four per contact.

        This is as quick as writing contacts this way can be, and it is still
        slow - three Java runtimes a contact, about 4.5 s. A phone's worth is
        an hour and more, which is why the vCard way below exists.

        The ids are read back rather than counted on. They do run one after
        another on the phone this was measured on, but a row that failed would
        shift every id after it and put one person's number under another's
        name, so a batch whose count does not match is left alone instead.
    #>
    param([string]$Serial, $Contacts, [int]$Batch = 25, [scriptblock]$Progress)

    $rows = @($Contacts)
    if ($rows.Count -eq 0) { return [PSCustomObject]@{ Added = 0; Calls = 0; Failed = 0; Stopped = $false; Gone = $false } }

    $added = 0
    $failed = 0
    $calls = 0
    for ($at = 0; $at -lt $rows.Count; $at += $Batch) {
        if (Test-BackupStopped) {
            return [PSCustomObject]@{ Added = $added; Calls = $calls; Failed = $failed; Stopped = $true; Gone = $false }
        }
        $take = [Math]::Min($Batch, $rows.Count - $at)
        $some = @($rows[$at..($at + $take - 1)])

        $make = @(1..$take | ForEach-Object { New-ContactRowBlock })
        $result = Invoke-DeviceShellText -Serial $Serial -Command ($make -join "`n")
        $calls++
        if ("$($result.Text)" -match 'device .*not found|device offline|no devices/emulators') {
            return [PSCustomObject]@{ Added = $added; Calls = $calls; Failed = $failed; Stopped = $false; Gone = $true }
        }

        $ids = @(Get-NewestContactIds -Serial $Serial -Count $take)
        $calls++
        if ($ids.Count -ne $take) {
            $failed += $take
            Write-Log "Contacts: the phone made $($ids.Count) of $take rows, so that batch was left alone." $colorWarn
            Invoke-BackupPump
            continue
        }

        $data = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $take; $i++) {
            foreach ($block in (New-ContactDataBlocks -RawId $ids[$i] `
                    -Name "$($some[$i].Name)".Trim() -Number "$($some[$i].Number)".Trim())) {
                $null = $data.Add($block)
            }
        }
        foreach ($chunk in (Get-ContactScriptChunks -Blocks $data.ToArray())) {
            $null = Invoke-DeviceShellText -Serial $Serial -Command $chunk
            $calls++
        }
        $added += $take
        if ($Progress) { & $Progress $added }
        Invoke-BackupPump
    }
    return [PSCustomObject]@{ Added = $added; Calls = $calls; Failed = $failed; Stopped = $false; Gone = $false }
}

# ------------------------------------------------- adding, the vCard way ----
# One file the phone's own Contacts reads. Seconds instead of an hour, at the
# cost of a tap: the phone asks which account to put them in, and writes
# nothing until that is answered.

function ConvertTo-VcardLine {
    # a vCard line, folded at 75 characters the way the format asks
    param([string]$Text)

    if ("$Text".Length -le 75) { return $Text }
    $out = New-Object System.Collections.Generic.List[string]
    $null = $out.Add($Text.Substring(0, 75))
    $at = 75
    while ($at -lt $Text.Length) {
        $take = [Math]::Min(74, $Text.Length - $at)
        $null = $out.Add(' ' + $Text.Substring($at, $take))
        $at += $take
    }
    return ($out -join "`r`n")
}

function ConvertTo-VcardText {
    <#
        The contacts as one vCard file.

        Version 3.0 and UTF-8, which is what Android's own importer reads: the
        names on the test phone are Arabic and go through as themselves. A
        backslash, a semicolon or a comma is punctuation in this format, so
        each one in a name is escaped.
    #>
    param($Contacts)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($contact in @($Contacts)) {
        $number = "$($contact.Number)".Trim()
        if (-not $number) { continue }
        $name = "$($contact.Name)".Trim()
        if (-not $name) { $name = $number }
        $safe = $name -replace '\\', '\\\\' -replace ';', '\;' -replace ',', '\,'
        $null = $out.Add('BEGIN:VCARD')
        $null = $out.Add('VERSION:3.0')
        $null = $out.Add((ConvertTo-VcardLine -Text ('FN:' + $safe)))
        $null = $out.Add((ConvertTo-VcardLine -Text ('N:;' + $safe + ';;;')))
        $null = $out.Add((ConvertTo-VcardLine -Text ('TEL;TYPE=CELL:' + $number)))
        $null = $out.Add('END:VCARD')
    }
    return (($out -join "`r`n") + "`r`n")
}

function Save-ContactVcard {
    # the file itself; no BOM, which Android's importer would read as part of
    # the first field's name
    param($Contacts, [string]$Path)

    $text = ConvertTo-VcardText -Contacts $Contacts
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllBytes($Path, $utf8.GetBytes($text))
    return $Path
}

function Send-ContactsAsVcard {
    <#
        The contacts written as one file, pushed to the phone, and the phone's
        own import screen opened on it. What happens next is on the phone: it
        asks which account to put them in, and writes nothing until that is
        answered.
    #>
    param([string]$Serial, $Contacts, [string]$Folder = '/sdcard/Download')

    $rows = @($Contacts | Where-Object { "$($_.Number)".Trim() })
    if ($rows.Count -eq 0) {
        return [PSCustomObject]@{ Ok = $false; Count = 0; Path = ''; Text = 'there are no numbers in that backup' }
    }

    $local = Join-Path $env:TEMP "androiddc-contacts-$PID.vcf"
    $null = Save-ContactVcard -Contacts $rows -Path $local
    $remote = "$Folder/androiddc-contacts.vcf"
    $push = Invoke-Adb -CommandArguments @('-s', $Serial, 'push', $local, $remote)
    Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    if ("$($push.Text)" -match 'error:|failed to copy|cannot stat') {
        return [PSCustomObject]@{ Ok = $false; Count = $rows.Count; Path = $remote
            Text = (Get-ContactAnswerLine -Text "$($push.Text)") }
    }

    $start = Invoke-DeviceShellText -Serial $Serial -Command (
        'am start -a android.intent.action.VIEW -t text/x-vcard -d ' +
        (Quote-DeviceArgument ('file://' + $remote)))
    $said = "$($start.Text)"
    if ($said -match 'Error|Exception|Permission Denial') {
        return [PSCustomObject]@{ Ok = $false; Count = $rows.Count; Path = $remote
            Text = (Get-ContactAnswerLine -Text $said) }
    }
    return [PSCustomObject]@{ Ok = $true; Count = $rows.Count; Path = $remote; Text = '' }
}
