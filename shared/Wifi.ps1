<#
    AndroidDC - the saved Wi-Fi passwords on a phone, read without root.

    A saved password is kept behind the system permission READ_WIFI_CREDENTIAL,
    which no installed app can be granted. The adb shell has it, so a small
    program (android\wifipw) run by app_process the way the FTP server and the
    restore writer are asks the Wi-Fi service for the privileged network list,
    which carries the password, and prints one line per network.

    Measured, so this is not a guess:
      Android TV 11 (AI PONT)   23 networks with their passwords, 1.4 s
      vivo Android 13           the call returns null to the shell - the Wi-Fi
                                module moved to a Mainline package and the
                                shell is no longer privileged for this one
                                call. There is no root-free path on 13+.

    So the answer carries a Status: Ok, Unsupported (13+), Masked (a build that
    hands back "*" instead of the key), Empty, NoDex, or Error. The passwords
    live only in the object this returns; nothing here writes them to the log.

    Dot-sourced by both windows.
#>

function Get-WifiPwDex {
    <#
        The reader, built from its source when this PC has the Android SDK and
        otherwise the copy that ships beside it - so reading the passwords does
        not depend on a PC that can build Java. Same shape as Get-RestoreWriterDex.
    #>
    $root = Join-Path (Split-Path $PSScriptRoot -Parent) 'android\wifipw'
    $shipped = Join-Path $root 'WifiPw.dex'
    $built = Join-Path $root 'out\classes.dex'
    $source = Get-Item -LiteralPath (Join-Path $root 'src\com\androiddc\WifiPw.java') -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $built) -and $source -and
        (Get-Item -LiteralPath $built).LastWriteTimeUtc -ge $source.LastWriteTimeUtc) { return $built }
    if ((Test-Path -LiteralPath $shipped) -and -not $source) { return $shipped }
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build.ps1') 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $built)) { return $built }
    } catch { }
    if (Test-Path -LiteralPath $shipped) { return $shipped }
    return ''
}

function Get-SavedWifiPasswords {
    <#
        The saved networks on one phone, each with its password.

        Returns Status, Rows (each @{ Ssid; Password; IsOpen }), Error and
        Count. Status:
          Ok           - rows carry real passwords
          Masked       - the phone answered but every key is hidden as "*"
          Empty         - the list came back holding nothing readable
          Unsupported   - Android 13+: the shell is not privileged for this
          NoDex         - the reader could not be found or built on this PC
          Error         - something else; Error holds the phone's own words

        adb's output comes back UTF-8 (Invoke-Adb forces it), so an Arabic SSID
        stays whole. The passwords are never written to the log here - only
        counts are - and the caller shows them in a window, nothing more.
    #>
    param([string]$Serial)

    $empty = [PSCustomObject]@{ Status = 'Error'; Rows = @(); Error = ''; Count = 0 }

    $dex = Get-WifiPwDex
    if (-not $dex) {
        Write-Log 'Wi-Fi passwords: the reader could not be found or built on this PC.' $colorBad
        $empty.Status = 'NoDex'
        return $empty
    }

    $remote = '/data/local/tmp/androiddc-wifipw.dex'
    $push = Invoke-Adb -CommandArguments @('-s', $Serial, 'push', $dex, $remote)
    if ($push.ExitCode -ne 0) {
        Write-Log ('Wi-Fi passwords: the reader could not be sent to the phone - ' + "$($push.Text)".Trim()) $colorBad
        $empty.Error = "$($push.Text)".Trim()
        return $empty
    }
    try {
        $run = Invoke-DeviceShell -Serial $Serial -CommandArguments @(
            "CLASSPATH=$remote app_process /system/bin com.androiddc.WifiPw 2>&1")
    } finally {
        $null = Invoke-DeviceShell -Serial $Serial -CommandArguments @("rm -f $remote")
    }

    $text = "$($run.Text)"
    $status = ''
    $errMsg = ''
    $rows = New-Object System.Collections.Generic.List[object]
    # only STATUS and NET lines are trusted; an app_process or linker warning
    # on stderr carries neither marker and is passed over
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $line) { continue }
        $f = $line -split "`t"
        if ($f[0] -eq 'STATUS') {
            $status = $(if ($f.Count -ge 2) { $f[1] } else { '' })
            if ($status -eq 'ERROR' -and $f.Count -ge 3) { $errMsg = $f[2] }
        } elseif ($f[0] -eq 'NET' -and $f.Count -ge 2) {
            $pw = $(if ($f.Count -ge 3) { $f[2] } else { '' })
            $null = $rows.Add([PSCustomObject]@{ Ssid = $f[1]; Password = $pw; IsOpen = (-not $pw) })
        }
    }

    $out = [PSCustomObject]@{ Status = 'Error'; Rows = $rows.ToArray(); Error = $errMsg; Count = $rows.Count }
    switch ($status) {
        'OK' {
            # a build that hands the list back but hides every key behind "*"
            $withKey = @($rows | Where-Object { -not $_.IsOpen })
            if ($withKey.Count -gt 0 -and @($withKey | Where-Object { $_.Password -ne '*' }).Count -eq 0) { $out.Status = 'Masked' }
            elseif ($rows.Count -eq 0) { $out.Status = 'Empty' }
            else { $out.Status = 'Ok' }
        }
        'UNSUPPORTED' { $out.Status = 'Unsupported' }
        'EMPTY' { $out.Status = 'Empty' }
        'ERROR' { $out.Status = 'Error' }
        default {
            # no STATUS line at all: the reader did not run (old app_process path,
            # a phone that killed it, or output we could not read)
            if ($rows.Count -gt 0) { $out.Status = 'Ok' }
            else { $out.Status = 'Error'; if (-not $out.Error) { $out.Error = 'the reader did not run on the phone' } }
        }
    }

    $withPw = @($rows | Where-Object { -not $_.IsOpen }).Count
    switch ($out.Status) {
        'Ok' { Write-Log "Wi-Fi passwords: $($rows.Count) saved network(s) read from $Serial, $withPw with a password." $colorGood }
        'Masked' { Write-Log "Wi-Fi passwords: $Serial lists $($rows.Count) network(s) but hides the keys." $colorWarn }
        'Empty' { Write-Log "Wi-Fi passwords: $Serial has no saved network to read." $colorInfo }
        'Unsupported' { Write-Log "Wi-Fi passwords: $Serial (Android 13+) does not let adb read saved passwords without root." $colorWarn }
        'Error' { Write-Log ("Wi-Fi passwords: could not read them - " + $(if ($out.Error) { $out.Error } else { 'unknown' })) $colorBad }
    }
    return $out
}

function Get-WifiPasswordHint {
    # one line under the list, by status: what happened and what, if anything, to do
    param([string]$Status)

    switch ($Status) {
        'Ok' { return 'These are the passwords the phone has saved. They are shown here only - nothing is written to the log or sent anywhere.' }
        'Masked' { return 'This phone lists its saved networks but hides the passwords, even from adb. Reading them would need root.' }
        'Empty' { return 'This phone has no saved Wi-Fi network to read.' }
        'Unsupported' { return 'From Android 13 the saved passwords cannot be read over adb without root: the Wi-Fi service no longer hands them to the shell. It still works on Android 8 to 12 and on Android TV.' }
        'NoDex' { return 'The small reader this needs is not beside the program and could not be built. Reinstall AndroidDC, or build android\wifipw on a PC with the Android SDK.' }
        default { return 'The passwords could not be read from this phone.' }
    }
}
