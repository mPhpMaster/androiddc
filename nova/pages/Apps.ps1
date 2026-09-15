# pages\Apps.ps1 - everything installed on the selected phone, the app's name
# first: launch, open on its own scrcpy display, force stop, app info,
# uninstall, install an APK or a split bundle, and export the list.

# serial -> @{ package = app name }, from scrcpy --list-apps
if (-not (Get-Variable -Name appLabels -Scope Script -ErrorAction SilentlyContinue)) { $script:appLabels = @{} }
# serial -> the user-installed packages when the names were read
if (-not (Get-Variable -Name appLabelsSeen -Scope Script -ErrorAction SilentlyContinue)) { $script:appLabelsSeen = @{} }
$script:appRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
# the phone the rows belong to
$script:appsSerial = $null

$appsPage = Register-Page -Key 'apps' -Title 'Apps' -Glyph 'E71D' -Section 'Workspace' -Xaml 'Apps.xaml' `
    -OnShow { if ($script:appRows.Count -eq 0 -and (Test-AppsDeviceReady)) { Update-AppList } } `
    -OnDeviceChanged {
        $serial = Get-SelectedSerial
        if ($serial -and $serial -eq $script:appsSerial) { return }
        Clear-AppsList
        if ((Test-PageShown -Key 'apps') -and (Test-AppsDeviceReady)) { Update-AppList }
    } `
    -Refresh { Update-AppList }

$ui.AppsList.ItemsSource = $script:appRows

function Test-AppsDeviceReady {
    # a phone is picked and ready - asked without writing to the log
    $first = Get-SelectedDevice
    return ($null -ne $first -and $first.State -eq 'device')
}

function Clear-AppsList {
    $script:appRows.Clear()
    $script:appsSerial = $null
    $ui.AppsCount.Text = 'Refresh reads the apps of the selected phone'
}

function Get-AppLabels {
    <#
        The names of the apps on a phone, from scrcpy --list-apps. pm knows
        packages only, and "com.shiftatinc.worker" tells nobody which app it
        is. scrcpy prints one app per line, the name padded into a column:

             - Nafath | <arabic name>          sa.gov.nic.myid

        A name can hold spaces and even "|", but a package never holds a
        space, so the package is the last word and the name is everything
        before it. Asking takes two to five seconds, so each phone is asked
        once and the answer kept; Update-AppList asks again when the set of
        installed apps has changed.
    #>
    param([string]$Serial, [switch]$Refresh)

    if (-not $Refresh -and $script:appLabels.ContainsKey($Serial)) { return $script:appLabels[$Serial] }

    if (Get-Command Get-DeviceCapabilityList -ErrorAction SilentlyContinue) {
        $lines = @(Get-DeviceCapabilityList -Serial $Serial -Switch '--list-apps')
    } elseif (-not $script:scrcpyPath) {
        Write-Log 'scrcpy.exe not found.' $colorBad
        $lines = @()
    } else {
        # the same call the Cam / Mic page makes, for when that page is not loaded
        Write-Log 'scrcpy --list-apps ...' $colorStep
        $result = Invoke-OffThread -FilePath $script:scrcpyPath -ArgumentList @('-s', $Serial, '--list-apps') -TimeoutMs 60000
        $lines = @($result.Lines | Where-Object { $_ -and $_.Trim() })
    }

    $labels = @{}
    foreach ($line in $lines) {
        # "*" marks an app that came with the phone, "-" one that was installed
        if ($line -match '^\s*[*-]\s+(.*\S)\s+(\S+)\s*$') { $labels[$Matches[2]] = $Matches[1] }
    }
    if ($labels.Count -eq 0) {
        Write-Log 'scrcpy listed no app names on this phone, so packages are shown without them.' $colorWarn
    }
    # kept even when empty, so a phone that cannot answer is not asked on every refresh
    $script:appLabels[$Serial] = $labels
    return $labels
}

function Get-AppsVisibleRows {
    # the rows the list shows: filtered and in its sort order
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:appRows)
    return @($view | ForEach-Object { $_ })
}

function Update-AppsFilter {
    # an app is found by what it is called, not only by its package; the
    # typed text is matched as it is, never as a pattern
    if ($ui.AppsFilter.Text.Trim()) {
        Set-ListFilter -List $ui.AppsList -Accept {
            param($row)
            $filter = $ui.AppsFilter.Text.Trim()
            return ((Test-TextContains $row.Package $filter) -or (Test-TextContains $row.Name $filter))
        }
    } else {
        Set-ListFilter -List $ui.AppsList -Accept $null
    }
    if (-not $script:appsSerial) { return }
    $rows = @(Get-AppsVisibleRows)
    $named = @($rows | Where-Object { $_.Name }).Count
    # only apps with a launcher icon have a name; services and libraries do not
    $ui.AppsCount.Text = "$($rows.Count) packages on $($script:appsSerial), $named of them apps with a name"
}

function Update-AppList {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $scope = if ($ui.AppsSystem.IsChecked) { '' } else { '-3' }
    $listed = (Invoke-DeviceShell -Serial $serial -CommandArguments @(
        "pm list packages --show-versioncode $scope")).Text
    $disabled = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -d')).Text
    $thirdParty = (Invoke-DeviceShell -Serial $serial -CommandArguments @('pm list packages -3')).Text

    # the names are read again only when the installed apps have changed -
    # an install from here, from the Play Store, or anywhere else
    # whole names, compared whole: a search for "package:com.foo" also found
    # it at the start of "package:com.foo.bar", so a system app whose name
    # begins another's took that app's user / disabled label
    $userPackages = @([regex]::Matches($thirdParty, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $disabledPackages = @([regex]::Matches($disabled, 'package:(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $installed = (@($userPackages | Sort-Object) -join ' ')
    $changed = $script:appLabelsSeen.ContainsKey($serial) -and $script:appLabelsSeen[$serial] -ne $installed
    $names = Get-AppLabels -Serial $serial -Refresh:$changed
    $script:appLabelsSeen[$serial] = $installed

    # another phone may have been picked while those were read
    if ((Get-SelectedSerial) -ne $serial) { return }

    $userSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($package in $userPackages) { $null = $userSet.Add($package) }
    $disabledSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($package in $disabledPackages) { $null = $disabledSet.Add($package) }

    $script:appRows.Clear()
    foreach ($line in ($listed -split "`r?`n")) {
        if ($line -notmatch 'package:(\S+)') { continue }
        $package = $Matches[1]
        $version = if ($line -match 'versionCode:(\S+)') { $Matches[1] } else { '' }
        $name = if ($names.ContainsKey($package)) { "$($names[$package])" } else { '' }
        $script:appRows.Add([PSCustomObject]@{
            Name    = $name
            Package = $package
            Version = $version
            Type    = $(if ($userSet.Contains($package)) { 'user' } else { 'system' })
            State   = $(if ($disabledSet.Contains($package)) { 'disabled' } else { 'enabled' })
        })
    }
    $script:appsSerial = $serial
    Update-AppsFilter
    Write-Log "Listed $(@(Get-AppsVisibleRows).Count) packages on $serial." $colorInfo
}

function Get-SelectedPackages {
    return @($ui.AppsList.SelectedItems | ForEach-Object { $_.Package })
}

function Get-LauncherActivity {
    param([string]$Serial, [string]$Package)

    $result = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $Package | tail -1")).Text.Trim()
    if ($result -match '^\S+/\S+$') { return $result }
    return $null
}

function Get-AppsNewDisplaySize {
    # the size in the Mirroring page's new-display box (the original's
    # $txtNewDisplay), when that page is loaded and the box is not empty
    if ($ui.ContainsKey('MirroringNewDisplaySize') -and "$($ui.MirroringNewDisplaySize.Text)".Trim()) {
        return "$($ui.MirroringNewDisplaySize.Text)".Trim()
    }
    return '1920x1080/240'
}

function Start-App {
    param([switch]$NewDisplay)

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    foreach ($package in $packages) {
        if ($NewDisplay) {
            if (-not $script:scrcpyPath) { Write-Log 'scrcpy.exe not found.' $colorBad; return }

            # its own short command rather than the Mirroring settings: those
            # carry a start app, a recording or OTG of their own
            $size = Get-AppsNewDisplaySize
            $arguments = @('-s', $serial, "--new-display=$size", "--start-app=+$package",
                "--window-title=$package")
            Write-Log ('scrcpy ' + ($arguments -join ' ')) $colorStep

            $stdout = Join-Path $env:TEMP ("androiddc-nova-$PID.app-$package.out")
            $stderr = Join-Path $env:TEMP ("androiddc-nova-$PID.app-$package.err")
            $process = Start-Process -FilePath $script:scrcpyPath -ArgumentList $arguments -PassThru `
                -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $null = $process.Handle
            # the Mirroring page's list, so Close scrcpy closes this window too
            if (-not (Get-Variable -Name scrcpyProcesses -Scope Script -ErrorAction SilentlyContinue)) { $script:scrcpyProcesses = @() }
            if ($script:scrcpyProcesses -is [System.Collections.IList] -and -not $script:scrcpyProcesses.IsFixedSize) {
                $null = $script:scrcpyProcesses.Add($process)
            } else {
                $script:scrcpyProcesses += $process
            }
            Wait-Pumped -Milliseconds 2500
            $process.Refresh()

            if ($process.HasExited) {
                Write-Log "scrcpy could not open a display for $package (exit $($process.ExitCode))." $colorBad
                foreach ($file in @($stdout, $stderr)) {
                    if (Test-Path -LiteralPath $file) {
                        $text = (Get-Content -LiteralPath $file -Tail 6) -join [Environment]::NewLine
                        if ($text.Trim()) { Write-Log $text $colorWarn }
                    }
                }
            } else {
                # still alive is not the same as working: read what scrcpy said
                $said = ''
                if (Test-Path -LiteralPath $stdout) { $said = "$(Get-Content -LiteralPath $stdout -Raw)" }
                if ($said -match 'New display: \S+ \(id=(\d+)\)') {
                    $display = $Matches[1]
                    if ($said -match 'Starting app') {
                        Write-Log "$package runs on its own display $display (PID $($process.Id))." $colorGood
                    } else {
                        Write-Log "Display $display opened but $package has not started on it yet." $colorWarn
                        Write-Log 'Unlock the phone: some ROMs refuse to launch an app on a new display while locked.' $colorInfo
                    }
                } else {
                    Write-Log "scrcpy is running (PID $($process.Id)) but has not reported a new display yet." $colorWarn
                    Write-Log 'A virtual display needs Android 11 or newer, and the phone unlocked.' $colorInfo
                }
            }
            continue
        }

        $activity = Get-LauncherActivity -Serial $serial -Package $package
        if (-not $activity) {
            Write-Log "$package has no launcher activity." $colorWarn
            continue
        }

        $result = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'start', '-n', $activity)
        Write-Log ("$package -> " + $result.Text.Trim()) $(if ($result.Text -match 'Error') { $colorBad } else { $colorGood })
    }
}

function Stop-App {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }
    foreach ($package in $packages) {
        $null = Invoke-DeviceShell -Serial $serial -CommandArguments @('am', 'force-stop', $package)
        Write-Log "force-stop $package" $colorInfo
    }
}

function Show-AppInfo {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    $null = Invoke-DeviceShell -Serial $serial -CommandArguments @(
        'am', 'start', '-a', 'android.settings.APPLICATION_DETAILS_SETTINGS', '-d', "package:$($packages[0])")
    Write-Log "Opened the system page for $($packages[0])." $colorInfo
    Wait-Pumped -Milliseconds 800
    $capture = Get-Command Update-Capture -ErrorAction SilentlyContinue
    if ($capture) {
        if ($capture.Parameters.ContainsKey('Quiet')) { Update-Capture -Quiet } else { Update-Capture }
    }
}

function Uninstall-App {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $packages = @(Get-SelectedPackages)
    if ($packages.Count -eq 0) { Write-Log 'Pick an app in the list first.' $colorWarn; return }

    $answer = Show-Confirm -Title 'Uninstall' -Yes 'Uninstall' -No 'Cancel' -Danger -Text (
        "Uninstall these apps from $serial ?" + [Environment]::NewLine + ($packages -join [Environment]::NewLine))
    if (-not $answer) { return }

    foreach ($package in $packages) {
        $result = Invoke-Adb -CommandArguments @('-s', $serial, 'uninstall', $package)
        Write-Log ("uninstall $package -> " + $result.Text.Trim()) `
            $(if ($result.Text -match 'Success') { $colorGood } else { $colorBad })
    }
    Update-AppList
}

function Get-AppListCsv {
    # the name goes last, so a sheet built on the old four columns still reads;
    # it is quoted, because a name can hold a comma or a quote and the rest cannot
    $lines = @('package,version,type,state,name')
    foreach ($row in @(Get-AppsVisibleRows)) {
        $name = '"' + "$($row.Name)".Replace('"', '""') + '"'
        $lines += ('{0},{1},{2},{3},{4}' -f $row.Package, $row.Version, $row.Type, $row.State, $name)
    }
    return $lines
}

function Export-AppList {
    $count = @(Get-AppsVisibleRows).Count
    if ($count -eq 0) { Write-Log 'Nothing to export.' $colorWarn; return }

    $file = Select-SaveFile -Filter 'CSV (*.csv)|*.csv|Text (*.txt)|*.txt' `
        -FileName ('apps-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if (-not $file) { return }

    Set-Content -LiteralPath $file -Value (Get-AppListCsv) -Encoding UTF8
    Write-Log "Exported $count packages to $file" $colorGood
}

function Install-Apk {
    <#
        Handles the three shapes an Android package arrives in:
          one .apk                     -> adb install -r
          several .apk chosen together -> adb install-multiple (a split app)
          .xapk / .apks / .apkm        -> a zip of splits, unpacked first
        A plain "adb install" fails on the last two, which is what most
        downloads look like today.
    #>
    $serials = @(Get-SelectedSerials)
    if ($serials.Count -eq 0) { Write-Log 'Select at least one ready device.' $colorWarn; return }

    # the Files page's PC folder, when it has one
    $initial = ''
    foreach ($name in @($ui.Keys | Where-Object { $_ -like 'Files*Local*' } | Sort-Object)) {
        if ($ui[$name] -is [System.Windows.Controls.TextBox] -and $ui[$name].Text.Trim()) { $initial = $ui[$name].Text.Trim(); break }
    }
    $chosen = @(Select-OpenFiles -Multiselect -InitialDirectory $initial -Filter (
        'Any Android package (*.apk;*.apks;*.xapk;*.apkm)|*.apk;*.apks;*.xapk;*.apkm|' +
        'Single APK (*.apk)|*.apk|Split bundle (*.apks;*.xapk;*.apkm)|*.apks;*.xapk;*.apkm|All files (*.*)|*.*'))
    if ($chosen.Count -eq 0) { return }

    $unpacked = $null
    try {
        # a bundle is a zip; take every apk out of it
        if ($chosen.Count -eq 1 -and $chosen[0] -match '\.(xapk|apks|apkm)$') {
            $bundle = $chosen[0]
            Write-Log "Unpacking $([System.IO.Path]::GetFileName($bundle)) ..." $colorStep
            $unpacked = Join-Path $env:TEMP ("androiddc-nova-$PID.bundle-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory -Path $unpacked -Force
            try {
                if (-not ('System.IO.Compression.ZipFile' -as [type])) {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                }
                [System.IO.Compression.ZipFile]::ExtractToDirectory($bundle, $unpacked)
            } catch {
                Write-Log "That file is not a readable bundle: $($_.Exception.Message)" $colorBad
                return
            }

            # base.apk first: install-multiple takes the base before its splits
            $chosen = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter *.apk |
                Sort-Object { $_.Name -notlike 'base*' }, Name | ForEach-Object { $_.FullName })
            if ($chosen.Count -eq 0) {
                Write-Log 'The bundle holds no .apk at all - nothing to install.' $colorBad
                return
            }
            Write-Log ("  found $($chosen.Count) apk(s): " + (($chosen | ForEach-Object {
                [System.IO.Path]::GetFileName($_) }) -join ', ')) $colorInfo
        }

        $split = $chosen.Count -gt 1
        foreach ($serial in $serials) {
            if ($split) {
                Write-Log "Installing $($chosen.Count) splits on $serial ..." $colorStep
                $arguments = @('-s', $serial, 'install-multiple', '-r') + $chosen
            } else {
                Write-Log "Installing $([System.IO.Path]::GetFileName($chosen[0])) on $serial ..." $colorStep
                $arguments = @('-s', $serial, 'install', '-r', $chosen[0])
            }

            $result = Invoke-Adb -CommandArguments $arguments
            $text = $result.Text.Trim()
            if ($text -match 'Success') {
                Write-Log "  installed on $serial." $colorGood
            } else {
                Write-Log ("  " + $text) $colorBad
                foreach ($reason in @(Get-InstallRefusalReason -Text $text)) { Write-Log $reason $colorInfo }
            }
        }
    } finally {
        if ($unpacked -and (Test-Path -LiteralPath $unpacked)) {
            Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Update-DeviceList
}

function Get-InstallRefusalReason {
    # what adb's refusal code means, in words; nothing for a code not known here
    param([string]$Text)

    if ($Text -match 'INSTALL_FAILED_INVALID_APK|Split.*required|INSTALL_FAILED_MISSING_SPLIT') {
        return @('  this app is split: pick every apk of the set together, or its .xapk.')
    } elseif ($Text -match 'INSTALL_FAILED_USER_RESTRICTED') {
        return @('  the phone refused, not the file. Turn on "Install via USB" in developer options',
            '  (MIUI and ColorOS keep it off, and MIUI asks for a signed in account first).')
    } elseif ($Text -match 'INSTALL_FAILED_VERSION_DOWNGRADE') {
        return @('  an older version than the one installed; uninstall it first.')
    } elseif ($Text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
        return @('  a different signing key than the installed copy; uninstall it first.')
    } elseif ($Text -match 'INSTALL_FAILED_INSUFFICIENT_STORAGE') {
        return @('  the phone is out of space.')
    } elseif ($Text -match 'INSTALL_FAILED_NO_MATCHING_ABIS') {
        return @('  these splits are built for another CPU than this phone.')
    }
    return @()
}

# ------------------------------------------------------------------ events ----

$ui.AppsRefresh.Add_Click({ Update-AppList })
$ui.AppsFilter.Add_TextChanged({ Update-AppsFilter })
$ui.AppsFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) { $eventArgs.Handled = $true; Update-AppList }
})
# system apps in or out: read again when a list is already there (the names are kept)
$ui.AppsSystem.Add_Click({ if ($script:appsSerial -and $script:busy -eq 0) { Update-AppList } })
$ui.AppsLaunch.Add_Click({ Start-App })
$ui.AppsNewDisplay.Add_Click({ Start-App -NewDisplay })
$ui.AppsStop.Add_Click({ Stop-App })
$ui.AppsInfo.Add_Click({ Show-AppInfo })
$ui.AppsUninstall.Add_Click({ Uninstall-App })
$ui.AppsInstall.Add_Click({ Install-Apk })
$ui.AppsExport.Add_Click({ Export-AppList })
Set-ListColumnsSortable -List $ui.AppsList
Add-ListContextMenu -List $ui.AppsList -Buttons @($ui.AppsLaunch, $ui.AppsNewDisplay, $ui.AppsStop, $null,
    $ui.AppsInfo, $ui.AppsUninstall, $null, $ui.AppsExport)
