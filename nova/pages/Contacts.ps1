# pages\Contacts.ps1 - the phone numbers in the contacts provider: read,
# filter, add, edit, delete, copy and export them, and call a number or end
# the call. The provider's answer is read with Split-ContentRows and
# Get-RowValue from pages\Messages.ps1.

$contactsPage = Register-Page -Key 'contacts' -Title 'Contacts' -Glyph 'E77B' -Section 'Personal' `
    -Xaml 'Contacts.xaml' -OnDeviceChanged {
        # the rows belong to the phone they were read from
        $hadRows = $script:contactsRows.Count -gt 0
        Clear-ContactsList
        if ($hadRows -and (Test-PageShown -Key 'contacts') -and (Get-SelectedSerial)) { Update-ContactList }
    } -Refresh { Update-ContactList }

$script:contactsRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$ui.ContactsList.ItemsSource = $script:contactsRows

function Get-ContactsRows {
    # the numbers in a 'content query --uri content://com.android.contacts/data/phones' answer
    param([string]$Text)

    $rows = @()
    foreach ($row in (Split-ContentRows -Text $Text)) {
        $number = Get-RowValue -Row $row -Column 'data1'
        if (-not $number) { continue }
        $rows += [PSCustomObject]@{
            Name      = Get-RowValue -Row $row -Column 'display_name'
            Number    = $number
            ContactId = Get-RowValue -Row $row -Column 'contact_id'
            RawId     = Get-RowValue -Row $row -Column 'raw_contact_id'
        }
    }
    return $rows
}

function Set-ContactsFilterView {
    # kept in script scope: a closure would not see Test-TextContains
    $script:contactsFilterText = $ui.ContactsFilter.Text.Trim()
    if ($script:contactsFilterText) {
        Set-ListFilter -List $ui.ContactsList -Accept {
            param($row)
            (Test-TextContains "$($row.Name)" $script:contactsFilterText) -or (Test-TextContains "$($row.Number)" $script:contactsFilterText)
        }
    } else {
        Set-ListFilter -List $ui.ContactsList -Accept $null
    }
    Update-ContactsCount
}

function Get-ContactsShown {
    # the rows the filter lets through, in the order shown
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:contactsRows)
    return @($view | ForEach-Object { $_ })
}

function Update-ContactsCount {
    if ($script:contactsRows.Count -eq 0) { $ui.ContactsCount.Text = ''; return }
    $shown = @(Get-ContactsShown).Count
    $ui.ContactsCount.Text = if ($shown -eq $script:contactsRows.Count) { "$shown numbers" } else { "$shown of $($script:contactsRows.Count) numbers" }
    if ($script:contactsSerial) { $ui.ContactsCount.Text += " on $script:contactsSerial" }
}

function Clear-ContactsList {
    $script:contactsRows.Clear()
    $script:contactsSerial = $null
    $ui.ContactsCount.Text = ''
}
$script:contactsSerial = $null

function Update-ContactList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $text = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content query --uri content://com.android.contacts/data/phones --projection display_name:data1:contact_id:raw_contact_id')).Text
    if ((Get-SelectedSerial) -ne $serial) { return }

    $script:contactsRows.Clear()
    foreach ($row in (Get-ContactsRows -Text $text)) { $script:contactsRows.Add($row) }
    $script:contactsSerial = $serial
    Set-ContactsFilterView
    Write-Log "Read $(@(Get-ContactsShown).Count) phone numbers from $serial." $colorInfo
}

function Add-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $values = Show-InputDialog -Title 'New contact' -Fields @('Name', 'Number') -OkText 'Add'
    if (-not $values -or -not $values[1].Trim()) { return }

    $name = $values[0].Trim()
    $number = $values[1].Trim()

    $result = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:null --bind account_type:s:null')
    if ($result.Text -match 'Error|Exception') { Write-Log $result.Text $colorBad; return }

    # the row just made is the one with the highest id; the last row of an
    # unsorted query is only whichever the provider happened to return last
    $newest = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        "content query --uri content://com.android.contacts/raw_contacts --projection _id --sort '_id DESC' | head -1")).Text
    if ($newest -notmatch '_id=(\d+)') { Write-Log 'Could not find the new contact row.' $colorBad; return }
    $rawId = $Matches[1]

    # one argument each: a name has spaces, and can have an apostrophe (O'Brien)
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
        '--bind', 'mimetype:s:vnd.android.cursor.item/name', '--bind', "data1:s:$name")
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'insert', '--uri',
        'content://com.android.contacts/data', '--bind', "raw_contact_id:i:$rawId",
        '--bind', 'mimetype:s:vnd.android.cursor.item/phone_v2', '--bind', "data1:s:$number")

    Write-Log "Added $name ($number) to $serial." $colorGood
    Update-ContactList
}

function Edit-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    if ($ui.ContactsList.SelectedItems.Count -eq 0) { Write-Log 'Pick a contact first.' $colorWarn; return }
    $item = $ui.ContactsList.SelectedItems[0]

    $rawId = $item.RawId
    $values = Show-InputDialog -Title 'Edit contact' -Fields @('Name', 'Number') -Values @($item.Name, $item.Number) -OkText 'Save'
    if (-not $values) { return }

    $name = $values[0].Trim()
    $number = $values[1].Trim()

    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri',
        'content://com.android.contacts/data', '--bind', "data1:s:$name",
        '--where', "raw_contact_id=$rawId AND mimetype='vnd.android.cursor.item/name'")
    $null = Invoke-DeviceCommand -Serial $serial -Arguments @('content', 'update', '--uri',
        'content://com.android.contacts/data', '--bind', "data1:s:$number",
        '--where', "raw_contact_id=$rawId AND mimetype='vnd.android.cursor.item/phone_v2'")

    Write-Log "Updated contact $rawId on $serial." $colorGood
    Update-ContactList
}

function Remove-Contact {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $items = @($ui.ContactsList.SelectedItems)
    if ($items.Count -eq 0) { Write-Log 'Pick a contact first.' $colorWarn; return }

    $names = ($items | ForEach-Object { "$($_.Name)  $($_.Number)" }) -join [Environment]::NewLine
    $sure = Show-Confirm -Title 'Delete' -Text ("Delete these contacts from the phone?" + [Environment]::NewLine + $names) -Yes 'Delete' -Danger
    if (-not $sure) { return }

    foreach ($item in $items) {
        $rawId = $item.RawId
        $null = Invoke-DeviceShellText -Serial $serial -Command (
            "content delete --uri content://com.android.contacts/raw_contacts --where ""_id=$rawId""")
        Write-Log "Deleted contact raw id $rawId." $colorWarn
    }
    Update-ContactList
}

function Start-PhoneCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $number = $ui.ContactsDial.Text.Trim()
    if (-not $number -and $ui.ContactsList.SelectedItems.Count -gt 0) { $number = $ui.ContactsList.SelectedItems[0].Number }
    if (-not $number) { Write-Log 'Pick a contact or type a number.' $colorWarn; return }

    $sure = Show-Confirm -Title 'Call' -Text "Call $number from $serial ?" -Yes 'Call'
    if (-not $sure) { return }

    # a number from a contact is often written "050 123 4567"
    $result = Invoke-DeviceCommand -Serial $serial -Arguments @(
        'am', 'start', '-a', 'android.intent.action.CALL', '-d', "tel:$number")
    Write-Log ("call $number -> " + $result.Text.Trim()) $colorInfo
    Wait-Pumped -Milliseconds 1200
    if (Get-Command Update-Capture -ErrorAction SilentlyContinue) { Update-Capture -Quiet }
}

function Stop-PhoneCall {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    # KEYCODE_ENDCALL
    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('input', 'keyevent', '6')
    Write-Log 'Sent the end-call key.' $colorInfo
    Wait-Pumped -Milliseconds 800
    if (Get-Command Update-Capture -ErrorAction SilentlyContinue) { Update-Capture -Quiet }
}

function Get-ContactsExportLines {
    # the rows as the export writes them: a vCard, or CSV
    param($Rows, [switch]$VCard)

    if ($VCard) {
        $lines = @()
        foreach ($row in @($Rows)) {
            $lines += 'BEGIN:VCARD'
            $lines += 'VERSION:3.0'
            $lines += "FN:$($row.Name)"
            $lines += "TEL:$($row.Number)"
            $lines += 'END:VCARD'
        }
        return $lines
    }
    $lines = @('name,number')
    foreach ($row in @($Rows)) {
        $lines += ('"{0}","{1}"' -f ($row.Name -replace '"', "'"), $row.Number)
    }
    return $lines
}

function Export-Contacts {
    $serial = Get-TargetSerial
    if (-not $serial) { return }
    $rows = @(Get-ContactsShown)
    if ($rows.Count -eq 0) { Write-Log 'Refresh the list first.' $colorWarn; return }

    $path = Select-SaveFile -Filter 'CSV (*.csv)|*.csv|vCard (*.vcf)|*.vcf' -FileName ('contacts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if (-not $path) { return }

    Set-Content -LiteralPath $path -Value (Get-ContactsExportLines -Rows $rows -VCard:($path -like '*.vcf')) -Encoding UTF8
    Write-Log "Exported $($rows.Count) contacts to $path" $colorGood
}

# ------------------------------------------------------------------- events ----

$ui.ContactsList.Add_SelectionChanged({
    # so Call, and the same entry on the right mouse button, use the row you picked
    if ($ui.ContactsList.SelectedItems.Count -eq 0) { return }
    $number = $ui.ContactsList.SelectedItems[0].Number
    if ($number) { $ui.ContactsDial.Text = $number }
})
$ui.ContactsRefresh.Add_Click({ Update-ContactList })
$ui.ContactsFilter.Add_TextChanged({
    $ui.ContactsFilterHint.Visibility = if ($ui.ContactsFilter.Text) { 'Collapsed' } else { 'Visible' }
    Set-ContactsFilterView
})
$ui.ContactsFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Update-ContactList }
})
$ui.ContactsDial.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Start-PhoneCall }
})
$ui.ContactsAdd.Add_Click({ Add-Contact })
$ui.ContactsEdit.Add_Click({ Edit-Contact })
$ui.ContactsDelete.Add_Click({ Remove-Contact })
$ui.ContactsCall.Add_Click({ Start-PhoneCall })
$ui.ContactsEndCall.Add_Click({ Stop-PhoneCall })
$ui.ContactsCopy.Add_Click({
    if (Get-Command Copy-MessagesRows -ErrorAction SilentlyContinue) { Copy-MessagesRows -List $ui.ContactsList -Properties @('Name', 'Number') }
    else { Copy-ListSelection -List $ui.ContactsList }
})
$ui.ContactsExport.Add_Click({ Export-Contacts })

Set-ListColumnsSortable -List $ui.ContactsList
Add-ListContextMenu -List $ui.ContactsList -Buttons @($ui.ContactsCall, $ui.ContactsEndCall, $null,
    $ui.ContactsEdit, $ui.ContactsDelete, $null, $ui.ContactsCopy, $ui.ContactsExport)
