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
        Which contacts are a second copy of another, out of rows that carry
        Name, Number and RawId (one row per number, as data/phones answers).

        A contact goes only when every number it holds, under the same name,
        is also held by a contact that stays - so one with a number of its own
        is never touched, whatever else it repeats. The oldest copy (the lowest
        raw id) is the one kept.

        A contact can also hold the same number twice - measured on a phone
        with 943 numbers: once the copies were gone, 214 numbers were still
        there twice, every one inside a single contact. Deleting the contact
        cannot fix that, so the second row of the number goes instead, by its
        data id (rows without a DataId are left alone).

        Returns Gone (raw ids) and Rows (their rows), Extra (data ids) and
        ExtraRows, and Kept (how many contacts are left).
    #>
    param($Rows)

    $keysOf = @{}
    $holders = @{}
    $rowsOf = @{}
    foreach ($row in @($Rows)) {
        $raw = "$($row.RawId)" -replace '\D', ''
        if (-not $raw -or -not "$($row.Number)".Trim()) { continue }
        $key = Get-ContactKey -Name $row.Name -Number $row.Number
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
    # every number in the phone's contacts, read fresh rather than off a list a filter may have cut
    param([string]$Serial)

    $text = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection _id:display_name:data1:raw_contact_id')).Text
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in (Split-BackupRows -Text $text)) {
        $number = Get-BackupRowValue -Row $row -Column 'data1'
        if (-not $number) { continue }
        $null = $rows.Add([PSCustomObject]@{
            Name = (Get-BackupRowValue -Row $row -Column 'display_name')
            Number = $number
            RawId = (Get-BackupRowValue -Row $row -Column 'raw_contact_id')
            DataId = (Get-BackupRowValue -Row $row -Column '_id') })
    }
    return $rows.ToArray()
}

function Get-ContactDuplicateQuestion {
    # what is about to go, in words: a few by name, the rest counted
    param($Plan, [int]$Show = 10)

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
        $what += "$(@($Plan.Gone).Count) contact(s) are a second copy of another one - the same name and the same number."
    }
    if (@($Plan.Extra).Count -gt 0) {
        $what += "$(@($Plan.Extra).Count) number(s) are saved twice inside the same contact."
    }
    return (($what -join $nl) + $nl + 'One of each stays; the copies go. A contact with any number of its own is kept, ' +
        'even when it repeats others.' + $nl + $nl + ($lines -join $nl))
}

function Remove-PhoneContactDuplicates {
    # the plan carried out: the spare contacts, then the spare numbers
    param([string]$Serial, $Plan)

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
