# AndroidDC - file index

32 files at the top level, plus docs\, assets\, tests\, nova\ and shared\. `backups\` is deliberately left out of this index and is
ignored by git (see `.gitignore`).

The upstream half of this folder (scrcpy 4.1 and gnirehtet 2.5.1) can be fetched
again at any time with `get-upstream.ps1`, and is kept out of git on purpose.

Settings live outside this folder, in `%APPDATA%\AndroidDC\settings.json`
(a file left by the older name is carried over on first run); Nova's in `nova-settings.json`
and the rules per phone, shared by both windows, in `automation.json` next to it.

## Written for this project

| File | Size | Modified | What it is |
|---|---:|---|---|
| `androiddc.ps1` | 529 KB, 12358 lines | 2026-09-20 | The main tool: a WinForms control panel for phones over ADB. Twelve tabs - Device, Tethering, Advanced (mirroring, more options, device tools, root/recovery, automation), Apps, Contacts, SMS, Cam / Mic, Files, Running, Radios (Wi-Fi, Bluetooth, NFC), Users, Shell (shell + logcat). Every list has the same actions on the right mouse button. All adb work runs on a background runspace so the window never freezes. |
| `androiddc.vbs` | 561 B | 2026-09-15 | Launcher: runs the program hidden, with `-NoProfile -ExecutionPolicy Bypass`, passing its own arguments on (`-Minimized` from the start-with-Windows entry). **This is the file to double-click.** |
| `androiddc-nova.vbs` | 722 B | 2026-09-15 | Launcher for the Nova window (`nova\androiddc-nova.ps1`), hidden and in STA. Each window has a button that closes it and opens the other. |
| `start-menu.vbs` | 3.2 KB | 2026-09-15 | Adds *AndroidDC* and *AndroidDC Nova* to the Start menu (All apps), with the AndroidDC icon, pointing at the two launchers in this folder. `/remove` takes them out, `/quiet` shows no message, `/folder:<path>` writes elsewhere (tests). Windows keeps *Pin to Start* for the user. |
| `start-menu-remove.vbs` | 1.6 KB | 2026-09-15 | The reverse of the above: removes the two Start menu shortcuts, and nothing else. `/quiet`, `/folder:<path>` as above. |
| `nova\` | 68 files | 2026-09-20 | AndroidDC Nova, the same tool in a newer design: WPF hosted in PowerShell 5.1. `lib\` (adb off the window's thread, the window's helpers), `ui\` (theme and shell), `pages\` (one `.ps1` + `.xaml` per page), `fonts\` (DM Sans, Space Grotesk, OFL), `tests\` (runner, audit, a test per page, a tour of every page), `CONTRACT.md` (how a page is built). |
| `shared\` | 3 files | 2026-09-20 | Loaded by both windows. `Tray.ps1`: the icon by the clock (a click hides or shows the window, minimizing hides it there, Exit in its menu). `Backup.ps1`: a copy of the phone on this PC (files, APK files, contacts, messages, call log, settings) and putting one back. `Automation.ps1`: starting with Windows (one `AndroidDC` value under the user's Run key, the launcher with `-Minimized`), the actions a rule can run, the rules file `%APPDATA%\AndroidDC\automation.json`, telling a phone just plugged in from one already there, and the mutex that lets only one window run the rules. |
| `README.md` | 9.9 KB | 2026-09-20 | What the project is, how to start it, and the limits Android imposes. Written for GitHub. |
| `CHANGELOG.md` | 12 KB | 2026-09-20 | What each release changed, starting with 1.0.0 and what the pre-release review fixed. The version is also `$appVersion` at the top of `androiddc.ps1`, and the log shows it at startup. |
| `docs\` | 9 pages | 2026-09-21 | The full documentation: getting-started, user-guide, shortcuts, command-line, what-it-runs, limits, troubleshooting, architecture, roadmap. |
| `assets\` | 10 files | 2026-09-10 | The logo: `androiddc.svg` (source), `wordmark.png` (README banner), `androiddc.ico` (window icon) and PNGs from 16 to 512 px. |
| `LICENSE` | 12 KB | 2026-09-10 | Apache License 2.0 for AndroidDC itself. |
| `gnirehtet-share.ps1` | 13 KB, 418 lines | 2026-09-11 | The command-line reverse-tethering script. Parameters: `-Serial -Dns -Port -Routes -All -Reinstall -StopOnly -ListDevices -DisableWifi -PauseOnError`. |
| `gnirehtet-share.bat` | 118 B | 2026-09-07 | Launcher for the script above, adds `-PauseOnError` and forwards your arguments. |
| `get-upstream.ps1` | 17 KB | 2026-09-11 | Downloads the two upstream packages below from the official GitHub releases, checks each archive against SHA256, unpacks it here and never touches the files above. `-OnlyMissing` fetches only what is absent - that is what the GUI runs when it finds a tool missing at startup. Also `-ScrcpyVersion` / `-GnirehtetVersion` / `-Destination` / `-Force` / `-SkipScrcpy` / `-SkipGnirehtet` / `-KeepArchives` / `-CacheFolder`. |
| `get-upstream.bat` | 97 B | 2026-09-09 | Double-click launcher for the script above; passes any arguments straight through. |
| `.github\` | 4 files | 2026-09-15 | CI. `workflows\check.yml` runs on every push and pull request: every `.ps1` parses, no variable is read before it is assigned (`audit-variables.ps1`), every control reaches the screen, every button has a handler and no control's name is reused (`audit-wiring.ps1`), both launchers point at a file that exists, `start-menu.vbs` makes shortcuts to both and `start-menu-remove.vbs` removes the same two, Nova's own audit passes (`nova\tests\audit.ps1`), and no absolute developer path appears in a shipped file. `update-index.py` rewrites the numbers in this index. |
| `tests\` | 16 files | 2026-09-20 | The test suite. `run.ps1` runs the real window off screen with a test spliced in, closes it normally and reads its report. Seven tests need no phone (automation - rules, arrivals and the start-up entry against test copies -, layout at both window sizes, the phone-screen pane, screenshots, the Files page's search hits and Compress, the Wi-Fi order, the busy strip, toggle marks, device watch and shortcuts) and six need one (audio, apps, root, logcat and the live shell, UTF-8, text arriving on the phone unchanged). How to run them: `tests\README.md`. |

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
| `scrcpy-server` | 717 KB | The Java side, pushed to the phone on every run. Not a PC executable. |
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
4889cf15676f08f7  .gitattributes
957e46b8615f7af5  adb.exe
120bef587119c6cb  AdbWinApi.dll
6ca69a2ca0e31309  AdbWinUsbApi.dll
68df0901d9efcfb7  androiddc.ps1
574f70700b74dec2  androiddc.vbs
95c311cc87896c05  androiddc-nova.vbs
7179de2b132e78eb  avcodec-62.dll
7232316acce00371  avformat-62.dll
3d6170dd68549c6f  avutil-60.dll
87a9f976876079d5  CHANGELOG.md
e394873cd3e2cc3a  disconnected.png
b5e5354ae222bd71  get-upstream.bat
63f3fa6196d817aa  get-upstream.ps1
d6f5fa61274fae5a  gnirehtet-run.cmd
88b3267ed8e61378  gnirehtet-share.bat
4edefc4b07b79745  gnirehtet-share.ps1
c1ac2b869a48e3c8  gnirehtet.apk
d5daefbb48143fbc  gnirehtet.exe
8ec130918a476b0d  libusb-1.0.dll
9f125960b915c243  LICENSE
01c12035bf35af37  LICENSE.txt
843758795a84d0d0  open_a_terminal_here.bat
6e7c1a8334367e1e  README.md
3ccda94c161f18ce  scrcpy-noconsole.vbs
deacb991ed250971  scrcpy-server
575ca1284345c7b3  scrcpy.exe
8e8ca237898faa16  scrcpy.png
0619eb2da6032984  SDL3.dll
4cc809d2cd822e18  swresample-6.dll
```

Index written 2026-09-21.
