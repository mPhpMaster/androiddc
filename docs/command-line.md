# Command line

[← back to the README](../README.md)

Two scripts work without the window.

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
| `-DisableWifi` | — | Turn the phone's Wi-Fi off so it cannot slip back to its own network |
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
