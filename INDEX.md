# AndroidDC - file index

27 files at the top level, plus docs\ and assets\. `backups\` is deliberately left out of this index and is
ignored by git (see `.gitignore`).

The upstream half of this folder (scrcpy 4.1 and gnirehtet 2.5.1) can be fetched
again at any time with `get-upstream.ps1`, and is kept out of git on purpose.

Settings live outside this folder, in `%APPDATA%\AndroidDC\settings.json`
(a file left by the older name is carried over on first run).

## Written for this project

| File | Size | Modified | What it is |
|---|---:|---|---|
| `androiddc.ps1` | 341 KB, 8281 lines | 2026-09-09 | The main tool: a WinForms control panel for phones over ADB. Fourteen tabs - Device (details, quick toggles, call/SMS/USSD, one-click scrcpy), Tethering (both directions), Advanced (mirroring + device tools), Apps, Contacts, SMS, Cam / Mic, Files, Running, Wi-Fi, Bluetooth, NFC, Users, Shell. Every list has the same actions on the right mouse button. All adb work runs on a background runspace so the window never freezes. |
| `androiddc.vbs` | 344 B | 2026-09-10 | Launcher: runs the program hidden, with `-NoProfile -ExecutionPolicy Bypass`. **This is the file to double-click.** |
| `README.md` | 6 KB | 2026-09-10 | What the project is, how to start it, and the limits Android imposes. Written for GitHub. |
| `docs\` | 8 pages | 2026-09-10 | The full documentation: getting-started, user-guide, shortcuts, command-line, what-it-runs, limits, troubleshooting, architecture. |
| `assets\` | 10 files | 2026-09-10 | The logo: `androiddc.svg` (source), `wordmark.png` (README banner), `androiddc.ico` (window icon) and PNGs from 16 to 512 px. |
| `LICENSE` | 12 KB | 2026-09-10 | Apache License 2.0 for AndroidDC itself. |
| `gnirehtet-share.ps1` | 12 KB, 411 lines | 2026-09-07 | The command-line reverse-tethering script. Parameters: `-Serial -Dns -Port -Routes -All -Reinstall -StopOnly -ListDevices -DisableWifi -PauseOnError`. |
| `gnirehtet-share.bat` | 118 B | 2026-09-07 | Launcher for the script above, adds `-PauseOnError` and forwards your arguments. |
| `get-upstream.ps1` | 15 KB | 2026-09-09 | Downloads the two upstream packages below from the official GitHub releases, checks each archive against SHA256, unpacks it here and never touches the files above. `-OnlyMissing` fetches only what is absent - that is what the GUI runs when it finds a tool missing at startup. Also `-ScrcpyVersion` / `-GnirehtetVersion` / `-Destination` / `-Force` / `-SkipScrcpy` / `-SkipGnirehtet` / `-KeepArchives` / `-CacheFolder`. |
| `get-upstream.bat` | 97 B | 2026-09-09 | Double-click launcher for the script above; passes any arguments straight through. |

## Reverse tethering (gnirehtet 2.5.1, upstream files)

| File | Size | Modified | What it is |
|---|---:|---|---|
| `gnirehtet.exe` | 2.9 MB | 2023-07-09 | The relay/client. Carries the PC's internet to the phone over adb. TCP and UDP only - ICMP is not tunnelled, so ping never works through it. |
| `gnirehtet.apk` | 23 KB | 2023-07-09 | The app installed on the phone; it opens the VPN service on that side. |
| `gnirehtet-run.cmd` | 28 B | 2023-07-09 | `gnirehtet.exe run` then `pause` - the plain upstream one-shot launcher. |

## scrcpy 4.1 (upstream files)

| File | Size | What it is |
|---|---:|---|
| `scrcpy.exe` | 704 KB | Mirrors and controls the Android screen. |
| `scrcpy-server` | 716 KB | The Java side, pushed to the phone on every run. Not a PC executable. |
| `scrcpy-noconsole.vbs` | 212 B | Starts scrcpy with no console window, passing your arguments through. |
| `adb.exe` | 8.1 MB | Android Debug Bridge - every device command in this folder goes through it. |
| `open_a_terminal_here.bat` | 5 B | `@cmd` - opens a command prompt in this folder. |
| `LICENSE.txt` | 11 KB | Apache License 2.0 (scrcpy). |
| `scrcpy.png` | 6.4 KB | Window / app icon. |
| `disconnected.png` | 4.6 KB | Placeholder scrcpy shows when the device drops. |

## Libraries (needed by scrcpy.exe / adb.exe - do not delete)

| File | Size | Used by |
|---|---:|---|
| `SDL3.dll` | 5.1 MB | The scrcpy window, input and rendering. |
| `avcodec-62.dll` | 8.2 MB | FFmpeg - video/audio decoding. |
| `avformat-62.dll` | 707 KB | FFmpeg - container handling / recording. |
| `avutil-60.dll` | 1015 KB | FFmpeg - shared helpers. |
| `swresample-6.dll` | 137 KB | FFmpeg - audio resampling. |
| `libusb-1.0.dll` | 222 KB | USB access, needed for OTG / AOA mode. |
| `AdbWinApi.dll` | 106 KB | adb - Windows USB layer. |
| `AdbWinUsbApi.dll` | 72 KB | adb - WinUSB driver layer. |

## Not indexed

`backups\` - older copies of the scripts plus assorted one-off helpers
(`filemanager.vbs`, `phone-on-display22.*`, `reset-phone-display.*`, `talkie.*`,
`upx.vbs`, `usbvivo.bat`, `vivo.bat`) and the dated snapshot
`backups\20260909-132721\`. Listed in `.gitignore`.

## SHA256 (first 16 hex characters)

```
957e46b8615f7af5  adb.exe
120bef587119c6cb  AdbWinApi.dll
6ca69a2ca0e31309  AdbWinUsbApi.dll
a12b9c1974f57c49  androiddc.ps1
ea4e1ed6ff774533  androiddc.vbs
7179de2b132e78eb  avcodec-62.dll
7232316acce00371  avformat-62.dll
3d6170dd68549c6f  avutil-60.dll
e394873cd3e2cc3a  disconnected.png
b5e5354ae222bd71  get-upstream.bat
49a0c73a835a4aba  get-upstream.ps1
d6f5fa61274fae5a  gnirehtet-run.cmd
88b3267ed8e61378  gnirehtet-share.bat
1858563e7a5db35d  gnirehtet-share.ps1
c1ac2b869a48e3c8  gnirehtet.apk
d5daefbb48143fbc  gnirehtet.exe
8ec130918a476b0d  libusb-1.0.dll
9f125960b915c243  LICENSE
01c12035bf35af37  LICENSE.txt
843758795a84d0d0  open_a_terminal_here.bat
c167e6078b9eed7b  README.md
3ccda94c161f18ce  scrcpy-noconsole.vbs
deacb991ed250971  scrcpy-server
575ca1284345c7b3  scrcpy.exe
8e8ca237898faa16  scrcpy.png
0619eb2da6032984  SDL3.dll
4cc809d2cd822e18  swresample-6.dll
```

Index written 2026-09-10.
