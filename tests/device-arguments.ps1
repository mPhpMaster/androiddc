# needs: phone
# Text a person typed reaches the phone as one argument, exactly as typed:
# spaces, apostrophes, double quotes, shell characters, Arabic, a new line.
# Everything here goes to printf on the phone; nothing is sent, dialled,
# written or changed there. The only other command is a read of the newest
# contact id, the query Add contact uses to find the row it just made.

Select-TestPhone

# printf prints each argument between brackets, so a split shows as [a][b]
function Get-PhoneWords {
    param([string[]]$Words, [switch]$Plain)
    $all = @('printf', '[%s]') + $Words
    $result = if ($Plain) { Invoke-DeviceShell -Serial $TestSerial -CommandArguments $all }
              else { Invoke-DeviceCommand -Serial $TestSerial -Arguments $all }
    return ($result.Lines -join "`n")
}

$arabic = -join [char[]](0x0645, 0x0631, 0x062D, 0x0628, 0x0627)
$samples = @(
    @('SMS body with spaces', 'see you tomorrow'),
    @('apostrophe', "O'Brien"),
    @('double quotes', 'say "hi" now'),
    @('shell characters', 'a;b&c|d$HOME`id`(x)<y>*'),
    @('Arabic', "$arabic $arabic"),
    @('new line', "line one`nline two"),
    @('contact value', "data1:s:O'Brien Smith"),
    @('contact where', "raw_contact_id=7 AND mimetype='vnd.android.cursor.item/name'"),
    @('Wi-Fi password', 'p@ss w0rd $1'),
    @('typed text', 'it''s%s(fine)&ok')
)

Say '== the old way splits: the check below must be able to fail =='
$old = Get-PhoneWords -Plain -Words @('see you tomorrow')
Say ("Invoke-DeviceShell 'see you tomorrow' -> {0}   {1}" -f $old, (Mark ($old -eq '[see][you][tomorrow]')))

Say ''
Say '== each one arrives as one argument, unchanged =='
foreach ($sample in $samples) {
    $got = Get-PhoneWords -Words @($sample[1])
    $want = '[' + $sample[1] + ']'
    Say ("  {0,-22} {1}" -f $sample[0], (Mark ($got -eq $want)))
    if ($got -ne $want) { Say "      sent: $want"; Say "      got : $got" }
}

Say ''
Say '== several arguments keep their places =='
$got = Get-PhoneWords -Words @('one', 'two words', '', "it's")
Say ("  {0}   {1}" -f $got, (Mark ($got -eq "[one][two words][][it's]")))

Say ''
Say '== the newest contact row is the highest id =='
$rows = (Invoke-DeviceShell -Serial $TestSerial -CommandArguments @(
    "content query --uri content://com.android.contacts/raw_contacts --projection _id --sort '_id DESC'")).Text
$ids = @([regex]::Matches($rows, '_id=(\d+)') | ForEach-Object { [long]$_.Groups[1].Value })
if ($ids.Count -eq 0) {
    Say 'SKIPPED - this phone has no contacts to read'
} else {
    $newest = (Invoke-DeviceShell -Serial $TestSerial -CommandArguments @(
        "content query --uri content://com.android.contacts/raw_contacts --projection _id --sort '_id DESC' | head -1")).Text
    $picked = if ($newest -match '_id=(\d+)') { [long]$Matches[1] } else { -1 }
    $highest = ($ids | Measure-Object -Maximum).Maximum
    Say ("  {0} rows, picked {1}, highest {2}   {3}" -f $ids.Count, $picked, $highest, (Mark ($picked -eq $highest)))
}
