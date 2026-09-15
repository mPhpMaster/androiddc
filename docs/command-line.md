# Command line

[← back to the README](../README.md)

Two scripts work without the window, and both windows take one switch of their own.

---

## The windows: -Minimized

```powershell
.\androiddc.vbs -Minimized
.\androiddc-nova.vbs -Minimized
```

| Parameter | What it does |
|---|---|
| `-Minimized` | Starts with the window hidden in the tray (the icon by the clock). A phone that is already plugged in runs its automation rule as if it had just been plugged in |

This is what the *Start with Windows* entry runs. Both launchers pass whatever they are given on
to their script, so the same works on `androiddc.ps1` and `nova\androiddc-nova.ps1` directly.
Nova also has `-OffScreen`, `-SettingsFile`, `-PageNames` and `-TestScript`, which exist for
its tests (`nova\tests\run.ps1`).

---

## start-menu.vbs and start-menu-remove.vbs

Put both windows in the Start menu, or take them out again. Double-click either one, or:

```powershell
.\start-menu.vbs [/remove] [/quiet] [/folder:<path>]
.\start-menu-remove.vbs [/quiet] [/folder:<path>]
```

| Parameter | What it does |
|---|---|
| (none) | `start-menu.vbs` adds *AndroidDC* and *AndroidDC Nova* to the Start menu, or updates them; `start-menu-remove.vbs` removes them |
| `/remove` | `start-menu.vbs` removes them instead, the same as `start-menu-remove.vbs` |
| `/quiet` | No message at the end |
| `/folder:<path>` | Another folder instead of the Start menu's *Programs* folder, for testing |

The shortcuts are `%APPDATA%\Microsoft\Windows\Start Menu\Programs\AndroidDC.lnk` and
`AndroidDC Nova.lnk`. Each runs `wscript.exe` on its launcher in this folder, uses
`assets\androiddc.ico`, and starts in this folder. They show under *All apps*; Windows keeps
*Pin to Start* for you. Removing touches nothing but those two files. After moving the folder,
run `start-menu.vbs` again.

The messages they show:

| Script | Message |
|---|---|
| `start-menu.vbs` | *In the Start menu now, under All apps: AndroidDC, AndroidDC Nova. To keep one on the first page of Start, right-click it there and choose Pin to Start.* When a launcher is missing it adds *Not found in this folder, so not added:* and its name, and exits with code 1 |
| `start-menu.vbs /remove` | *Removed from the Start menu:* and the names, or *AndroidDC was not in the Start menu.* |
| `start-menu-remove.vbs` | *Removed from the Start menu:* and the names, then *start-menu.vbs puts them back.*, or *AndroidDC was not in the Start menu, so there was nothing to remove.* |

---

## get-upstream.ps1

Downloads the two upstream packages AndroidDC is built on, checks them and unpacks them.

```powershell
.\get-upstream.ps1 [-Destination <path>] [-ScrcpyVersion <v>] [-GnirehtetVersion <v>]
                   [-GetScrcpy] [-GetGnirehtet] [-SkipScrcpy] [-SkipGnirehtet]
                   [-OnlyMissing] [-Force] [-KeepArchives] [-CacheFolder <path>]
```

| Parameter | Default | What it does |
|---|---|---|
| `-Destination` | the script's own folder | Where the files end up |
| `-ScrcpyVersion` | `4.1` | Release tag without the leading `v` |
| `-GnirehtetVersion` | `2.5.1` | Release tag without the leading `v` |
| `-GetScrcpy` | — | This package and nothing else |
| `-GetGnirehtet` | — | This package and nothing else |
| `-SkipScrcpy` | — | Leave scrcpy alone |
| `-SkipGnirehtet` | — | Leave gnirehtet alone |
| `-OnlyMissing` | — | Look first; download only what is not already there, and never write over what is |
| `-Force` | — | Replace files that already exist |
| `-KeepArchives` | — | Keep the `.zip` files instead of deleting them |
| `-CacheFolder` | `%TEMP%\upstream-downloads` | Where archives are downloaded; a verified copy there is reused |

`get-upstream.bat` is a double-click wrapper that passes everything through.

### How it verifies

Every archive is checked against SHA256 **before** anything is unpacked:

1. The hash pinned in the script, for the default versions.
2. Otherwise the `SHA256SUMS.txt` published in the same GitHub release.

A mismatch deletes the download and stops with an error. The hashing and unzipping use .NET
directly rather than `Get-FileHash` and `Expand-Archive`, so the script still works when it is
started from PowerShell 7 (a child Windows PowerShell inherits a module path in which those
two cmdlets cannot be found).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Everything asked for is in place |
| `1` | Something is still missing, or a download failed |

### Examples

```powershell
# a fresh checkout
.\get-upstream.ps1

# repair only what is gone, leave the rest untouched
.\get-upstream.ps1 -OnlyMissing

# just scrcpy, if it is not already here (what the window runs for you)
.\get-upstream.ps1 -GetScrcpy -OnlyMissing

# an older scrcpy, into another folder, keeping the zip
.\get-upstream.ps1 -GetScrcpy -ScrcpyVersion 3.3.4 -Destination D:\tools\old -KeepArchives
```

The files it never touches, whatever you ask: `androiddc.ps1`, `androiddc.vbs`,
`gnirehtet-share.ps1`, `gnirehtet-share.bat`, `get-upstream.ps1`, `get-upstream.bat`,
`README.md`, `LICENSE`, `INDEX.md`, `.gitignore`.

---

## gnirehtet-share.ps1

Reverse tethering with no window: give a phone the PC's internet from a script or a shortcut.

```powershell
.\gnirehtet-share.ps1 [-Serial <serial>] [-Dns <servers>] [-Port <n>] [-Routes <cidr>]
                      [-All] [-Reinstall] [-StopOnly] [-ListDevices]
                      [-DisableWifi] [-PauseOnError]
```

| Parameter | Default | What it does |
|---|---|---|
| `-Serial` | the only connected device | Which device to serve |
| `-Dns` | `8.8.8.8` | DNS handed to the phone; several are comma separated |
| `-Port` | `31416` | Relay port on the PC (1024–65535) |
| `-Routes` | — | Limit the tunnel to these CIDR routes |
| `-All` | — | Every connected device (`gnirehtet autorun`) |
| `-Reinstall` | — | Push the client APK again first |
| `-StopOnly` | — | Stop a running tunnel and exit |
| `-ListDevices` | — | Print what adb sees and exit |
| `-DisableWifi` | — | Turn the phone's Wi-Fi off so it cannot slip back to its own network; turned back on at exit only if it was on |
| `-PauseOnError` | — | Keep the console open when something fails |

`gnirehtet-share.bat` runs it with `-PauseOnError` and forwards your arguments, so it can be
double-clicked.

```powershell
# the usual case
.\gnirehtet-share.ps1

# one device, Cloudflare DNS, Wi-Fi off
.\gnirehtet-share.ps1 -Serial ABC123DEF456 -Dns 1.1.1.1 -DisableWifi

# everything that is plugged in
.\gnirehtet-share.ps1 -All

# stop
.\gnirehtet-share.ps1 -StopOnly
```

Remember that this tunnel carries TCP and UDP only — see [Limits](limits.md).
