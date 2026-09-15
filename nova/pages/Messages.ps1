# pages\Messages.ps1 - the SMS provider's messages: read, filter, copy, edit,
# delete and export them, and send a new one through the phone's own SMS app.
# Split-ContentRows and Get-RowValue live here and are used by Contacts too.

$messagesPage = Register-Page -Key 'messages' -Title 'Messages' -Glyph 'E8BD' -Section 'Personal' `
    -Xaml 'Messages.xaml' -OnDeviceChanged {
        # the rows belong to the phone they were read from
        $hadRows = $script:messagesAll.Count -gt 0
        Clear-MessagesList
        if ($hadRows -and (Test-PageShown -Key 'messages') -and (Get-SelectedSerial)) { Update-SmsList }
    } -Refresh { Update-SmsList }

$script:messagesAll = @()
$script:messagesRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$ui.MessagesList.ItemsSource = $script:messagesRows

# ------------------------------------------------------ reading the provider ----

function Split-ContentRows {
    param([string]$Text)

    # 'content query' prints one record per "Row: <n> col=val, col=val",
    # but a body may contain newlines, so split on the row marker itself.
    $rows = @()
    foreach ($chunk in ($Text -split '(?m)^Row:\s+\d+\s+')) {
        if ($chunk.Trim()) { $rows += $chunk }
    }
    return $rows
}

function Get-RowValue {
    param([string]$Row, [string]$Column, [switch]$Last)

    # values are comma separated, but a value may hold commas of its own, so a
    # column ends where the next "name=" begins rather than at the first comma
    if ($Last) {
        if ($Row -match "(?s)$Column=(.*)$") { return $Matches[1].Trim() }
    } else {
        $pattern = '(?s)' + [regex]::Escape($Column) + '=(.*?)(?=,\s+[A-Za-z_][A-Za-z_0-9]*=|$)'
        if ($Row -match $pattern) { return $Matches[1].Trim() }
    }
    return ''
}

function Get-MessagesRows {
    # the messages in a 'content query --uri content://sms' answer, newest first
    param([string]$Text)

    $messages = @()
    foreach ($row in (Split-ContentRows -Text $Text)) {
        $id = Get-RowValue -Row $row -Column '_id'
        $address = Get-RowValue -Row $row -Column 'address'
        $stamp = Get-RowValue -Row $row -Column 'date'
        $type = Get-RowValue -Row $row -Column 'type'
        $body = (Get-RowValue -Row $row -Column 'body' -Last) -replace "`r?`n", ' '
        if (-not $id) { continue }

        $when = ''
        if ($stamp -match '^\d+$') {
            $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$stamp).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        }
        $direction = switch ($type) { '1' { 'in' } '2' { 'out' } '3' { 'draft' } default { $type } }

        $messages += [PSCustomObject]@{
            When      = $when
            Stamp     = $(if ($stamp -match '^\d+$') { [long]$stamp } else { [long]0 })
            Direction = $direction
            Address   = $address
            Body      = $body
            Id        = $id
        }
    }
    return @($messages | Sort-Object -Property Stamp -Descending)
}

function Show-MessagesRows {
    # what was read, through the filter: the newest 500 that match
    $filter = $ui.MessagesFilter.Text.Trim()
    $shown = @($script:messagesAll | Where-Object {
        -not $filter -or (Test-TextContains $_.Address $filter) -or (Test-TextContains $_.Body $filter)
    } | Select-Object -First 500)

    $script:messagesRows.Clear()
    foreach ($message in $shown) { $script:messagesRows.Add($message) }
    $ui.MessagesCount.Text = if ($script:messagesAll.Count -eq 0) { '' } else { "$($script:messagesRows.Count) messages (newest first)" }
}

function Clear-MessagesList {
    $script:messagesAll = @()
    $script:messagesRows.Clear()
    $ui.MessagesCount.Text = ''
}

function Update-SmsList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content query --uri content://sms --projection _id:address:date:type:body')).Text

    # another phone may have been picked while that was read
    if ((Get-SelectedSerial) -ne $serial) { return }
    $script:messagesAll = @(Get-MessagesRows -Text $text)
    Show-MessagesRows
    Write-Log "Read $($script:messagesRows.Count) SMS from $serial." $colorInfo
}

# ------------------------------------------------------------------ sending ----

function Send-Sms {
    <#
        Composes a message in the phone's own SMS app, after a confirmation.
        -Number and -Body are for other pages (Overview's quick SMS); left
        empty, the To and Message boxes on this page are used. Values passed
        in are also put into the boxes, as the original's quick SMS did.
    #>
    param([string]$Number, [string]$Body)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    if ($Number) { $ui.MessagesTo.Text = $Number } else { $Number = $ui.MessagesTo.Text }
    if ($Body) { $ui.MessagesBody.Text = $Body } else { $Body = $ui.MessagesBody.Text }
    $Number = "$Number".Trim()
    $Body = "$Body"
    if (-not $Number -or -not $Body.Trim()) { Write-Log 'Fill in both the number and the message.' $colorWarn; return }

    $sure = Show-Confirm -Title 'Send SMS' -Yes 'Send' -Text (
        "Send this SMS from $serial ?" + [Environment]::NewLine + [Environment]::NewLine +
        "To: $Number" + [Environment]::NewLine + $Body)
    if (-not $sure) { return }

    # Android exposes no shell command that sends an SMS, so the message is
    # composed in the phone's SMS app (Arabic survives: it is an intent extra).
    # The body has spaces, so it goes as one argument, not word by word.
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '224')
    Wait-Pumped -Milliseconds 500
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.SENDTO', '-d', "sms:$Number",
        '--es', 'sms_body', $Body, '--ez', 'exit_on_sent', 'true')

    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text $colorBad; return }
    Write-Log "Composed the message to $Number on the phone." $colorInfo
    Wait-Pumped -Milliseconds 2000

    if (-not $ui.MessagesAutoSend.IsChecked) {
        Update-MessagesCapture
        Write-Log 'Press Send on the phone (or in the picture on the Screen page).' $colorWarn
        return
    }

    $sendButton = Find-SendButton -Serial $serial
    if (-not $sendButton) {
        Update-MessagesCapture
        Write-Log 'Could not find the Send button - tap it in the picture on the Screen page.' $colorWarn
        return
    }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'tap', "$($sendButton.X)", "$($sendButton.Y)")
    Write-Log "Tapped Send at $($sendButton.X),$($sendButton.Y)." $colorGood
    Wait-Pumped -Milliseconds 2000
    Update-MessagesCapture
    Update-SmsList
}

function Update-MessagesCapture {
    # the Screen page's picture, when that page is there
    if (Get-Command Update-Capture -ErrorAction SilentlyContinue) { Update-Capture -Quiet }
}

function Find-SendButton {
    <#
        The middle of the SMS app's Send button, from a uiautomator dump, or
        $null. -Dump takes a dump already read (the tests use it); without it
        the phone is asked for one.
    #>
    param([string]$Serial, [string]$Dump)

    if (-not $PSBoundParameters.ContainsKey('Dump')) {
        $Dump = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            'uiautomator dump /sdcard/_sms_ui.xml >/dev/null 2>&1; cat /sdcard/_sms_ui.xml')).Text
        $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @('rm', '-f', '/sdcard/_sms_ui.xml')
    }

    # "Send" in English or Arabic. The Arabic word is built from its code
    # points, because a .ps1 file without a BOM is read in the PC's ANSI code
    # page: typed in directly, the letters were right only on a UTF-8 PC.
    $arabicSend = -join [char[]](0x0625, 0x0631, 0x0633, 0x0627, 0x0644)
    $sendPattern = '(?i)(send|' + $arabicSend + ')'

    # Read as XML, not with a pattern over the text: an attribute can hold a
    # quote or a ">" (a message draft shown on screen), which cut a node short.
    $candidates = @()
    $start = "$Dump".IndexOf('<?xml')
    if ($start -lt 0) { $start = "$Dump".IndexOf('<hierarchy') }
    $end = "$Dump".LastIndexOf('</hierarchy>')
    $parsed = $false
    if ($start -ge 0 -and $end -gt $start) {
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.LoadXml($Dump.Substring($start, $end - $start + '</hierarchy>'.Length))
            foreach ($node in $document.SelectNodes('//node')) {
                $candidates += [PSCustomObject]@{
                    Clickable = ($node.GetAttribute('clickable') -eq 'true')
                    Words     = (@('text', 'content-desc', 'resource-id') | ForEach-Object { $node.GetAttribute($_) }) -join ' '
                    Bounds    = $node.GetAttribute('bounds')
                }
            }
            $parsed = $true
        } catch {
            $parsed = $false
        }
    }
    if (-not $parsed) {
        # a dump cut off on the way still has most of its nodes
        foreach ($match in [regex]::Matches("$Dump", '<node\b[^>]*>')) {
            $node = $match.Value
            $candidates += [PSCustomObject]@{
                Clickable = ($node -match 'clickable="true"')
                Words     = $node
                Bounds    = $(if ($node -match 'bounds="([^"]*)"') { $Matches[1] } else { '' })
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate.Clickable) { continue }
        if ($candidate.Words -notmatch $sendPattern) { continue }
        if ($candidate.Bounds -match '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') {
            return [PSCustomObject]@{
                X = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
                Y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
            }
        }
    }
    return $null
}

# ------------------------------------------------------ changing the list ----

function Remove-Sms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $items = @($ui.MessagesList.SelectedItems)
    if ($items.Count -eq 0) { Write-Log 'Pick a message first.' $colorWarn; return }

    $sure = Show-Confirm -Title 'Delete SMS' -Text "Delete $($items.Count) message(s) from the phone?" -Yes 'Delete' -Danger
    if (-not $sure) { return }

    foreach ($item in $items) {
        $id = $item.Id
        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @("content delete --uri content://sms/$id")
        if ($result.Text -match 'Exception|denied') {
            Write-Log ("delete $id -> " + $result.Text.Trim()) $colorBad
        } else {
            Write-Log "Deleted message $id." $colorWarn
        }
    }
    Update-SmsList
}

function Edit-Sms {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($ui.MessagesList.SelectedItems.Count -eq 0) { Write-Log 'Pick a message first.' $colorWarn; return }
    $item = $ui.MessagesList.SelectedItems[0]

    $id = $item.Id
    $answer = Show-InputDialog -Title "Edit message $id" -Fields @('Body') -Values @($item.Body) -Multiline @('Body')
    if ($null -eq $answer) { return }
    # an array even for one field; @() keeps this right if that ever changes
    $newBody = @($answer)[0]

    $result = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri', 'content://sms',
        '--bind', "body:s:$newBody", '--where', "_id=$id")
    if ($result.Text -match 'Exception|denied') {
        Write-Log ("edit $id -> " + $result.Text.Trim()) $colorBad
    } else {
        Write-Log "Message $id updated." $colorGood
    }
    Update-SmsList
}

function Get-MessagesCsvLines {
    # the rows as the export writes them
    param($Rows)

    $lines = @('date,direction,number,message')
    foreach ($row in @($Rows)) {
        $lines += ('"{0}","{1}","{2}","{3}"' -f $row.When, $row.Direction, $row.Address, ($row.Body -replace '"', "'"))
    }
    return $lines
}

function Export-Sms {
    if ($script:messagesRows.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $path = Select-SaveFile -Filter 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt' -FileName ('sms-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if (-not $path) { return }

    Set-Content -LiteralPath $path -Value (Get-MessagesCsvLines -Rows $script:messagesRows) -Encoding UTF8
    Write-Log "Exported $($script:messagesRows.Count) messages to $path" $colorGood
}

function Copy-MessagesRows {
    # chosen columns of the selected rows, tab separated; Contacts uses it too
    param($List, [string[]]$Properties)

    $rows = @($List.SelectedItems)
    if ($rows.Count -eq 0) { Write-Log 'Nothing selected.' $colorWarn; return }
    $lines = foreach ($row in $rows) { (@($Properties | ForEach-Object { "$($row.$_)" }) -join "`t") }
    [System.Windows.Clipboard]::SetText((@($lines) -join [Environment]::NewLine))
    Write-Log "Copied $($rows.Count) row(s) to the clipboard." $colorInfo
}

# ------------------------------------------------------------------- events ----

$ui.MessagesRefresh.Add_Click({ Update-SmsList })
$ui.MessagesFilter.Add_TextChanged({
    $ui.MessagesFilterHint.Visibility = if ($ui.MessagesFilter.Text) { 'Collapsed' } else { 'Visible' }
    Show-MessagesRows
})
$ui.MessagesFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Update-SmsList }
})
$ui.MessagesSend.Add_Click({ Send-Sms })
$ui.MessagesCopy.Add_Click({ Copy-MessagesRows -List $ui.MessagesList -Properties @('When', 'Address', 'Body') })
$ui.MessagesDelete.Add_Click({ Remove-Sms })
$ui.MessagesEdit.Add_Click({ Edit-Sms })
$ui.MessagesExport.Add_Click({ Export-Sms })

Set-ListColumnsSortable -List $ui.MessagesList
Add-ListContextMenu -List $ui.MessagesList -Buttons @($ui.MessagesEdit, $ui.MessagesCopy, $null, $ui.MessagesDelete, $ui.MessagesExport)
Register-Setting -Name 'Messages.AutoSend' -Get { [bool]$ui.MessagesAutoSend.IsChecked } -Set { param($v) $ui.MessagesAutoSend.IsChecked = [bool]$v }
