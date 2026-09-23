# What it runs on your phone

[← back to the README](../README.md)

AndroidDC normally uses ordinary `adb` commands and grants itself nothing. **Start server**
on the FTP page is the exception: it installs a small AndroidDC notification app on the selected
phone so you can stop sharing from that phone. Connecting a phone alone does not install it.
This page lists what the tool runs so you can audit it.

Nothing here happens on its own: each command runs because you pressed the button next to it,
or because you set an automation rule for that phone (see below). The only things that repeat
by themselves are the device list refresh and, if you switch it on, the screen capture.

**Where you typed the text** — an SMS body, a number, a Wi-Fi name or password, a user name,
a contact, *Send text* — the command goes as `adb shell "echo <base64> | base64 -d | sh"`.
Decoded, it is exactly the command listed below, with each thing you typed as one quoted
argument. Sent as plain arguments, adb and the phone's shell split it at every space (an SMS
kept its first word) and read `'` `;` `$` as shell syntax; base64 is the one form neither
Windows nor the phone reinterprets.

## Reading the device

| Purpose | Command |
|---|---|
| Which devices are attached | `adb devices -l` |
| Model, Android version, properties | `adb shell getprop` |
| Battery | `adb shell dumpsys battery` |
| Signal | `adb shell dumpsys telephony.registry` |
| Screen picture | `adb exec-out screencap -p` (streamed, no file on either side) |
| Lock state | `adb shell dumpsys trust` |
| Active network and resolvers | `adb shell dumpsys connectivity` |
| Hardware present | `adb shell pm list features` |

## Touching the screen

| Purpose | Command |
|---|---|
| Tap | `adb shell input tap <x> <y>` |
| Swipe, long press | `adb shell input swipe <x1> <y1> <x2> <y2> <ms>` |
| Keys: back, home, recents, power, volume, end call | `adb shell input keyevent <code>` |
| Typing text | `adb shell input text` (Unicode goes through the clipboard route) |
| Finding a quick-settings tile (torch) | `adb shell uiautomator dump` then a tap at the tile's bounds |

## Settings and toggles

| Purpose | Command |
|---|---|
| Auto-rotate, haptics, show taps, stay awake, developer options | `adb shell settings put system\|global\|secure <key> <value>` |
| Location | `adb shell settings put secure location_mode` |
| Wi-Fi | `adb shell svc wifi enable\|disable` or `cmd wifi set-wifi-enabled` |
| Bluetooth | `adb shell cmd bluetooth_manager enable\|disable` |
| NFC | `adb shell svc nfc enable\|disable` |
| Battery saver | `adb shell cmd power set-mode` / `settings put global low_power` |
| Vibrate once | `adb shell cmd vibrator vibrate` |
| Private DNS | `adb shell settings put global private_dns_mode\|private_dns_specifier` |
| Keyboards | `adb shell ime list\|enable\|disable\|set\|reset` |
| Hotspot | the settings screen driven through `uiautomator`, verified with `dumpsys tethering` |
| USB tethering | `adb shell svc usb setFunctions rndis` |

## Apps

| Purpose | Command |
|---|---|
| List | `adb shell pm list packages --show-versioncode`, with `-3` unless system apps are shown; `pm list packages -d` for the disabled ones and `pm list packages -3` for the ones you installed |
| Names | `scrcpy --list-apps`, once per phone, and again when the installed apps change |
| Launch | `adb shell am start -n <component>` |
| On its own display | `scrcpy --new-display=<size> --start-app=+<package>` |
| Force stop | `adb shell am force-stop <package>` |
| Install | `adb install -r <apk>` |
| Install a split set or a bundle | `adb install-multiple -r <base.apk> <split...>` |
| Uninstall | `adb uninstall <package>` |
| App info screen | `adb shell am start -a android.settings.APPLICATION_DETAILS_SETTINGS` |

## Processes

`adb shell dumpsys activity processes` and `adb shell top -b -n 2 -d 1` to read them,
`am force-stop` or `am kill` to stop one, `am kill-all` for every background process.

## Files

| Purpose | Command |
|---|---|
| List a folder | `adb shell ls -la <path>/` |
| Search | `adb shell find -L <path> -iname <pattern>` |
| Recent files | `adb shell find -L /sdcard -newermt <date>` |
| Free space | `adb shell df -h <path>` |
| Volumes | `adb shell sm list-volumes` |
| Download | `adb pull` |
| Upload | `adb push` |
| Rename, delete, new folder | `adb shell mv` / `rm` / `mkdir -p` |
| Compress | `adb shell tar -czf <archive> -C <folder> <names>`; search hits from several folders: `-C / <paths>` |
| Extract | `adb shell unzip -o` or `tar -xzf` or `gzip -dc` |
| Preview | `adb exec-out cat <path>` into memory, nothing written to disk |
| Open on the phone | `adb shell am start -a android.intent.action.VIEW -d file://…` |
| Make the gallery notice a change | `adb shell content call --uri content://media --method scan_file` |

## Phone FTP

| Action | What runs or changes |
|---|---|
| Preview and recover a running server | Read the phone's Wi-Fi address, check for AndroidDC's `app_process` server, and read its FTP log under `/data/local/tmp` |
| Start server | Build the Java DEX and companion APK if absent, `adb install -r` the companion on the selected phone, grant its notification permission, push the DEX and temporary login to `/data/local/tmp`, then launch the server with `app_process` |
| Share files | The server exposes `/sdcard` through authenticated FTP and creates `/sdcard/AndroidDC-FTP/connection-test.txt` |
| Stop from the phone | The notification's **Stop FTP** action sends a local stop request to the server; sharing ends but the companion remains installed |
| Stop from the PC | Kill AndroidDC's server process and stop the companion's foreground service |
| Uninstall FTP phone app | Stop the server, `adb uninstall` the companion, and clear AndroidDC's temporary FTP files; uploaded user files remain |

## Phone, contacts, messages

| Purpose | Command |
|---|---|
| Call | `adb shell am start -a android.intent.action.CALL -d tel:<number>` |
| Dialer only | `… -a android.intent.action.DIAL` |
| Hang up | `adb shell input keyevent 6` |
| USSD | the CALL intent with `#` written as `%23` |
| Contacts | `adb shell content query\|insert\|update\|delete --uri content://com.android.contacts/…` |
| SMS list | `adb shell content query --uri content://sms` |
| Send SMS | `adb shell am start -a android.intent.action.SENDTO -d sms:<number> --es sms_body <text>`, then the phone's own app sends it |

## Radios and users

| Purpose | Command |
|---|---|
| Wi-Fi scan and networks | `adb shell cmd wifi start-scan\|list-scan-results\|list-networks` |
| Join / forget | `adb shell cmd wifi connect-network <ssid> <type> [<password>]`, `forget-network <id>` |
| Bluetooth paired list | `adb shell dumpsys bluetooth_manager` |
| NFC state | `adb shell dumpsys nfc` |
| Users | `adb shell pm list users`, `am get-current-user`, `am switch-user`, `pm create-user`, `pm remove-user`, `pm get-max-users` |
| Multi-user switch | `adb shell settings put global user_switcher_enabled 0\|1` |

## The device log

`adb logcat -v time *:<LEVEL>` runs as a long-lived process while the Logcat page is on, and
`adb logcat -c` empties the buffer if you hold Shift on Clear.

## Camera and audio

| Purpose | Command |
|---|---|
| Camera as the video source | `scrcpy --video-source=camera`, with `--camera-facing=front` or `back`, or `--camera-id=<id>` |
| Camera picture, when set | `--camera-ar=<ratio>` *or* `--camera-size=<WxH>` (scrcpy takes one, never both), `--camera-fps=<n>`, `--camera-zoom=<x>` when it is not 1, `--camera-high-speed`, `--camera-torch` |
| Camera sound | `--audio-source=mic` with *mic* ticked, otherwise `--no-audio` |
| Listen | `scrcpy --no-video --no-window --audio-source=<source>` |
| Record audio | `scrcpy --no-video --no-playback --audio-source=<source> --record=<file>` |
| Audio options, when set | `--audio-codec=<codec>`, `--audio-encoder=<name>`, `--audio-bit-rate=<rate>`, `--audio-buffer=<ms>`, and `--audio-dup` for *Listen* with the `output` source only |

## Asking the phone what it supports

`scrcpy --list-encoders`, `scrcpy --list-camera-sizes`, `scrcpy --list-cameras`,
`scrcpy --list-displays` and `scrcpy --list-apps` fill the dropdowns from the device instead
of a fixed list.

## Root and recovery

Only from the *Root / recovery* page: `adb root`, `unroot`, `remount`, `disable-verity`,
`enable-verity`, `sideload <zip>`, `emu <command>`, `jdwp`, `keygen <file>`, `get-devpath`,
`wait-for-device`. An ordinary phone allows only the last three, so the others stay off until
the page is unlocked. The page reads `getprop ro.build.type`, `ro.debuggable`, `ro.secure` and
`id -u` when it is opened, to say which of them this device would allow. `jdwp` runs for three
seconds and is then stopped, and the ids it printed are named with `adb shell ps -A -o
PID,NAME`. After `root` or `unroot`, `adb wait-for-device` runs before the phone is read again.

## Backing up and restoring

| Purpose | Command |
|---|---|
| What is in internal storage | `adb shell ls -1 /sdcard/`, then `adb pull -a /sdcard/<folder> <here>`, one folder at a time |
| The apps you installed | `adb shell pm list packages -3 --show-versioncode`, `adb shell pm path <package>`, then `adb pull` of each APK. The names come from `scrcpy --list-apps`, and name plus version are written into the backup as `apps\apps.json` |
| Whether the phone has an app already | `adb shell pm list packages --show-versioncode`, compared with what the backup wrote down |
| Contacts, messages, call log | `adb shell content query --uri content://com.android.contacts/data/phones`, the same for `content://sms` and `content://call_log/calls` |
| Settings and the app list | `adb shell settings list system|secure|global`, `getprop`, `pm list packages -3 --show-versioncode`, `pm list packages -s` |
| Which files the phone already has | `adb shell find '/sdcard/<folder>' -type f`, once per folder rather than once per file |
| Sending a file back | `adb push <file> /sdcard/<path>` |
| After sending files | `adb shell content call --uri content://media --method scan_volume --arg external_primary`, so the gallery notices them |
| Installing an app from a backup | `adb install -r <apk>`, or `adb install-multiple -r <base.apk> <split...>` |
| Adding a contact back | `content insert` into `raw_contacts`, then two `content insert` calls into `data`, for the name and the number |

| Packing what was pulled | no adb at all: `System.IO.Compression`, a file at a time, already-packed kinds (`.jpg`, `.mp4`, `.apk`, ...) stored rather than squeezed |
| Reading a backup, and taking one file out | the zip's own index, and one entry at a time - a backup is never unpacked whole. Opening one reads `manifest.json` alone; the index is read when a list of what is inside is asked for |

`adb backup` is **not** used: Android 12 and newer return almost nothing for it. What is inside
an app cannot be read without root, by this or any other tool.

## Automation rules

A rule runs nothing of its own: each action is the same function its button calls, so it runs
the commands listed on this page for that button, on the rule's phone only. It starts when
that phone becomes ready in `adb devices -l`, or when you press *Run now*. Two actions have no
button elsewhere:

| Action | Command |
|---|---|
| Wake the screen | `adb shell input keyevent 224` |
| Open an app | `adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <package>`, then `adb shell am start -n <component>` |

The rules you set are listed in the log at startup and in the menu of the icon by the clock.

## Connection plumbing

`adb tcpip 5555`, `adb connect|disconnect`, `adb kill-server|start-server`, `adb reconnect`,
`adb reverse --list`, `adb pair <host:port> <code>`, `adb mdns check|services`,
`adb bugreport <file>`, and gnirehtet's own `run|start|stop|restart|tunnel|autorun|autostart`.

## What is written on your PC

| What | Where | Removed |
|---|---|---|
| Settings | `%APPDATA%\AndroidDC\settings.json`, and `nova-settings.json` for Nova | Kept on purpose |
| Automation rules | `%APPDATA%\AndroidDC\automation.json`, written when you change a rule | Kept on purpose; delete the file to drop every rule |
| FTP login for reconnection | An encrypted file per phone under `%LOCALAPPDATA%\AndroidDC\Ftp` | Removed by **Stop server** or **Uninstall FTP phone app** on this PC; stopping from the phone leaves the encrypted copy until a later PC action |
| Start with Windows | the value `AndroidDC` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, only when you turn it on | When you turn it off; nothing else under that key is touched |
| scrcpy and app output | `%TEMP%\androiddc-<pid>.*` | When the program closes |
| Media previews | `%TEMP%\androiddc-<pid>.preview.*` | When the program closes |
| Downloads you asked for | The PC folder you chose | Kept, they are yours |

Passwords typed into the Wi-Fi box are passed to `cmd wifi connect-network` and are not saved
anywhere by AndroidDC.
