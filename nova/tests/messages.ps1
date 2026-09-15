# The Messages page: the SMS provider's answer read into rows, the filter,
# the export lines, the Send button found in a uiautomator dump read as XML,
# and every action that would change the phone run against a made-up serial
# with adb replaced, so each command is recorded and none is sent. With a
# phone attached, only a read of the SMS provider. Nothing personal is
# printed: counts only.

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
$page = Get-Page -Key 'messages'
Say ("  the page is registered under Personal   {0}" -f (Mark ($null -ne $page -and $page.Section -eq 'Personal')))
Show-Page -Page 'messages'
$null = Wait-Idle -Seconds 30
Say ("  opening it reads nothing (the original waited for Refresh)   {0}" -f (Mark ($script:messagesRows.Count -eq 0)))

Say ''
Say '== the provider answer, made up =='
$arabic = -join [char[]](0x0645, 0x0631, 0x062D, 0x0628, 0x0627)
$query = @(
    'Row: 0 _id=11, address=+15550001, date=1700000000000, type=1, body=hello, with a comma, and address=inside',
    'Row: 1 _id=12, address=+15550002, date=1700000500000, type=2, body=two',
    'lines',
    "Row: 2 _id=13, address=Bank, date=1690000000000, type=3, body=$arabic",
    'Row: 3 _id=14, address=+15550003, date=NULL, type=5, body=odd'
) -join "`n"
$parts = @(Split-ContentRows -Text $query)
Say ("  four records, a body with a new line kept in its own   {0}" -f (Mark ($parts.Count -eq 4)))
$rows = @(Get-MessagesRows -Text $query)
Say ("  {0} rows, newest first ({1})   {2}" -f $rows.Count, (($rows | ForEach-Object { $_.Id }) -join ','),
    (Mark ((($rows | ForEach-Object { $_.Id }) -join ',') -eq '12,11,13,14')))
$first = @($rows | Where-Object { $_.Id -eq '11' })[0]
Say ("  a body keeps its commas and 'name=' text   {0}" -f (Mark ($first.Body -eq 'hello, with a comma, and address=inside')))
$second = @($rows | Where-Object { $_.Id -eq '12' })[0]
Say ("  a new line in a body becomes a space   {0}" -f (Mark ($second.Body -eq 'two lines')))
Say ("  directions in / out / draft / other   {0}" -f (Mark ((($rows | Sort-Object Id | ForEach-Object { $_.Direction }) -join ',') -eq 'in,out,draft,5')))
Say ("  Arabic survives   {0}" -f (Mark ((@($rows | Where-Object { $_.Id -eq '13' })[0].Body) -ceq $arabic)))
Say ("  Get-RowValue with no such column is empty   {0}" -f (Mark ((Get-RowValue -Row 'a=1, b=2' -Column 'c') -eq '')))

$script:messagesAll = $rows
$ui.MessagesFilter.Text = 'BANK'
Say ("  the filter, any case: {0} row(s)   {1}" -f $script:messagesRows.Count, (Mark ($script:messagesRows.Count -eq 1)))
$ui.MessagesFilter.Text = '[x'
Say ("  a [ in the filter is text, not a pattern   {0}" -f (Mark ($script:messagesRows.Count -eq 0)))
$ui.MessagesFilter.Text = ''
Say ("  empty filter shows all again, with a count   {0}" -f (Mark ($script:messagesRows.Count -eq 4 -and $ui.MessagesCount.Text -eq '4 messages (newest first)')))
$many = @(1..620 | ForEach-Object { [PSCustomObject]@{ When = ''; Stamp = [long]$_; Direction = 'in'; Address = 'x'; Body = 'y'; Id = "$_" } })
$script:messagesAll = @($many | Sort-Object Stamp -Descending)
Show-MessagesRows
Say ("  at most the newest 500 are listed   {0}" -f (Mark ($script:messagesRows.Count -eq 500 -and $script:messagesRows[0].Id -eq '620')))
$csv = @(Get-MessagesCsvLines -Rows @([PSCustomObject]@{ When = 'w'; Direction = 'in'; Address = '1'; Body = 'say "hi"' }))
Say ("  export: a header and the quotes made safe   {0}" -f (Mark ($csv.Count -eq 2 -and $csv[1] -eq '"w","in","1","say ''hi''"')))

Say ''
Say '== the Send button in a dump, read as XML =='
$arabicSend = -join [char[]](0x0625, 0x0631, 0x0633, 0x0627, 0x0644)
$head = "UI hierchary dumped to: /sdcard/_sms_ui.xml`n<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=`"0`">"
$dump = $head +
    '<node index="0" text="Send it later &gt; soon" clickable="false" bounds="[0,0][100,100]" />' +
    '<node index="1" text="a draft: he said &quot;&gt;" resource-id="com.app:id/compose" clickable="true" bounds="[0,1700][800,1900]" />' +
    ('<node index="2" text="" content-desc="' + $arabicSend + '" clickable="true" bounds="[900,1800][1000,1900]" />') +
    '</hierarchy>'
$point = Find-SendButton -Serial 'none' -Dump $dump
Say ("  the Arabic button, not the draft that quotes a '>'   {0}" -f (Mark ($null -ne $point -and $point.X -eq 950 -and $point.Y -eq 1850)))
$dump = $head + '<node index="0" text="" resource-id="com.app:id/send_message_button" clickable="true" bounds="[10,20][30,60]"><node index="0" text="SEND" clickable="false" bounds="[0,0][1,1]" /></node></hierarchy>'
$point = Find-SendButton -Serial 'none' -Dump $dump
Say ("  an English one by its id   {0}" -f (Mark ($null -ne $point -and $point.X -eq 20 -and $point.Y -eq 40)))
$point = Find-SendButton -Serial 'none' -Dump ($head + '<node text="Reply" clickable="true" bounds="[0,0][2,2]" /></hierarchy>')
Say ("  none there: nothing tapped   {0}" -f (Mark ($null -eq $point)))
$point = Find-SendButton -Serial 'none' -Dump '<node text="Send" clickable="true" bounds="[0,0][4,4]" />'
Say ("  a dump cut short still finds it   {0}" -f (Mark ($null -ne $point -and $point.X -eq 2)))

Say ''
Say '== actions, against a made-up serial =='
$sendDump = $head + ('<node index="2" text="" content-desc="' + $arabicSend + '" clickable="true" bounds="[900,1800][1000,1900]" />') + '</hierarchy>'
Enable-TestMocks
try {
    Say ("  the mock is in place   {0}" -f (Mark ((Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial')))
    $script:mockReply = {
        param([string]$Line)
        if ($Line -match 'uiautomator dump') { return $sendDump }
        if ($Line -match '^content query --uri content://sms') { return $query }
        return ''
    }

    $number = '050 123 4567'
    $body = "It's `"fine`" `$HOME `;&| $arabic`nsecond line"

    $script:mockConfirm = $false
    Reset-TestRecord
    Send-Sms -Number $number -Body $body
    Say ("  Send asks first; No sends nothing   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockAdb.Count -eq 0 -and $script:mockText.Count -eq 0)))
    Say ("  -Number and -Body are put into the boxes   {0}" -f (Mark ($ui.MessagesTo.Text -eq $number -and $ui.MessagesBody.Text -ceq $body)))

    $script:mockConfirm = $true
    $ui.MessagesAutoSend.IsChecked = $true
    Reset-TestRecord
    $ui.MessagesTo.Text = ''
    $ui.MessagesBody.Text = ''
    Send-Sms -Number $number -Body $body
    $sent = @($script:mockText)
    $words = if ($sent.Count -gt 0) { Split-TestShellWords $sent[0] } else { @() }
    Say ("  the question names the number   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockAsked[0] -match [regex]::Escape($number))))
    Say ("  the screen is woken first   {0}" -f (Mark ($script:mockAdb.Count -gt 0 -and $script:mockAdb[0] -eq 'input keyevent 224')))
    Say ("  the intent arrives whole: number, body with quotes, Arabic, a new line   {0}" -f
        (Mark (Test-SameWords $words @('am', 'start', '-a', 'android.intent.action.SENDTO', '-d', "sms:$number",
            '--es', 'sms_body', $body, '--ez', 'exit_on_sent', 'true'))))
    Say ("  the Send button is tapped in its middle   {0}" -f (Mark ($script:mockAdb -contains 'input tap 950 1850')))

    # the boxes are used when nothing is passed
    $ui.MessagesTo.Text = '12345'
    $ui.MessagesBody.Text = 'from the boxes'
    $ui.MessagesAutoSend.IsChecked = $false
    Reset-TestRecord
    Send-Sms
    $words = if ($script:mockText.Count -gt 0) { Split-TestShellWords $script:mockText[0] } else { @() }
    Say ("  without -Number / -Body the boxes are sent   {0}" -f (Mark ($words.Count -ge 9 -and $words[5] -eq 'sms:12345' -and $words[8] -eq 'from the boxes')))
    Say ("  auto-send off: no dump, no tap   {0}" -f (Mark (@($script:mockAdb | Where-Object { $_ -match 'uiautomator|input tap' }).Count -eq 0)))
    $ui.MessagesAutoSend.IsChecked = $true
    Reset-TestRecord
    $ui.MessagesBody.Text = '   '
    Send-Sms
    Say ("  an empty body is refused before the question   {0}" -f (Mark ($script:mockAsked.Count -eq 0 -and $script:mockAdb.Count -eq 0)))

    # edit and delete need a picked row
    $script:messagesAll = @([PSCustomObject]@{ When = 'w'; Stamp = [long]1; Direction = 'in'; Address = '1'; Body = 'old body'; Id = '77' })
    Show-MessagesRows
    $ui.MessagesList.SelectedItems.Clear()
    $ui.MessagesList.SelectedItems.Add($script:messagesRows[0])
    $script:mockInput = @("new body, with 'quotes' and `"more`"")
    Reset-TestRecord
    Edit-Sms
    $words = if ($script:mockText.Count -gt 0) { Split-TestShellWords $script:mockText[0] } else { @() }
    Say ("  Edit body sends the whole new body, not its first letter   {0}" -f
        (Mark (Test-SameWords $words @('content', 'update', '--uri', 'content://sms', '--bind', "body:s:$($script:mockInput[0])", '--where', '_id=77'))))
    $script:mockInput = $null
    Reset-TestRecord
    Edit-Sms
    Say ("  a cancelled edit sends nothing   {0}" -f (Mark ($script:mockText.Count -eq 0)))

    $ui.MessagesList.SelectedItems.Clear()
    $ui.MessagesList.SelectedItems.Add($script:messagesRows[0])
    $script:mockConfirm = $false
    Reset-TestRecord
    Remove-Sms
    Say ("  Delete asks; No deletes nothing   {0}" -f (Mark ($script:mockAsked.Count -eq 1 -and $script:mockAdb.Count -eq 0)))
    $script:mockConfirm = $true
    $ui.MessagesList.SelectedItems.Clear()
    $ui.MessagesList.SelectedItems.Add($script:messagesRows[0])
    Reset-TestRecord
    Remove-Sms
    Say ("  Yes deletes that id   {0}" -f (Mark ($script:mockAdb -contains 'content delete --uri content://sms/77')))

    Say ("  no command reached a real phone   {0}" -f (Mark ($script:mockLeaks.Count -eq 0)))
} finally {
    Disable-TestMocks
    $script:mockInput = $null
}
Say ("  the real functions are back   {0}" -f (Mark (-not ((Get-Command Get-TargetSerial).ScriptBlock.ToString() -match 'mockSerial'))))
$ui.MessagesTo.Text = ''
$ui.MessagesBody.Text = ''

Say ''
Say '== the phone, reads only =='
$serial = Get-SelectedSerial
$ready = $null -ne $serial -and @($script:deviceRows | Where-Object { $_.Serial -eq $serial -and $_.State -eq 'device' }).Count -gt 0
if (-not $ready) {
    Say '  SKIPPED - no phone attached'
} else {
    Clear-MessagesList
    Update-SmsList
    $read = $script:messagesRows.Count
    $ids = @($script:messagesAll | ForEach-Object { $_.Id })
    Say ("  read {0} message(s), each with an id, none twice   {1}" -f $script:messagesAll.Count,
        (Mark (@($ids | Where-Object { -not $_ }).Count -eq 0 -and @($ids | Sort-Object -Unique).Count -eq $ids.Count)))
    $stamps = @($script:messagesRows | ForEach-Object { $_.Stamp })
    Say ("  {0} listed, newest first   {1}" -f $read, (Mark (($stamps -join ',') -eq ((@($stamps | Sort-Object -Descending)) -join ','))))
    Clear-MessagesList
}

Say ''
Say '== the pictures (made-up rows) =='
$script:messagesAll = @(
    [PSCustomObject]@{ When = '2026-09-15 10:02'; Stamp = [long]3; Direction = 'in'; Address = '+15550001'; Body = 'Test message one, a little longer so the column fills up with words'; Id = '3' },
    [PSCustomObject]@{ When = '2026-09-14 18:40'; Stamp = [long]2; Direction = 'out'; Address = '+15550002'; Body = 'Test message two'; Id = '2' },
    [PSCustomObject]@{ When = '2026-09-13 08:15'; Stamp = [long]1; Direction = 'in'; Address = 'Test Bank'; Body = "Test $arabic"; Id = '1' }
)
Show-MessagesRows
$ui.MessagesTo.Text = '+15550001'
$ui.MessagesBody.Text = 'A test message that is not sent'
$ui.DeviceTitle.Text = 'Test phone'
$ui.DeviceSubtitle.Text = 'made-up rows for the picture'
foreach ($size in @('default', 'min')) {
    Set-WindowSize $size
    $script:logLines.Clear()
    Say ("  {0}: {1}" -f $size, (Save-WindowPicture "messages-$size"))
    $outside = @(Get-OutsideElements -Root $page.Root)
    Say ("  {0}: nothing sticks out   {1}" -f $size, (Mark ($outside.Count -eq 0)))
    foreach ($entry in $outside) { Say "      $entry" }
    $listHeight = $ui.MessagesList.ActualHeight
    Say ("  {0}: the list keeps {1:N0} px   {2}" -f $size, $listHeight, (Mark ($listHeight -ge 100)))
}
Clear-MessagesList
$ui.MessagesTo.Text = ''
$ui.MessagesBody.Text = ''
