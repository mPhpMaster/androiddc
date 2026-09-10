# Troubleshooting

[← back to the README](../README.md)

The log at the bottom right is the first place to look: every action writes what it ran and
what came back.

## The device list is empty

| Check | How |
|---|---|
| Is the cable a data cable? | A charge-only cable shows nothing at all |
| Is USB debugging on? | Settings → Developer options |
| Was the computer authorised? | Unlock the phone; the *Allow USB debugging?* dialog must be accepted |
| Does adb see it outside AndroidDC? | `.\adb.exe devices -l` in the folder |
| Is another adb running? | A different adb version (Android Studio, another tool) fights over the server — press **Restart adb server** on *Advanced → Device tools* |

A device shown as `unauthorized` means the prompt was never accepted. `offline` usually clears
with a replug or **Restart adb server**.

## Nothing happens when I press a button

* Almost every action needs a **device selected** in the list and, for lists, **a row
  selected**. The log says which one is missing.
* Actions that need scrcpy say so if `scrcpy.exe` is not in the folder — run
  `get-upstream.ps1`.
* If the whole window is unresponsive rather than one button, see below.

## "Own scrcpy window" opens nothing

That button asks scrcpy for a **virtual display** and starts the app on it.

* It needs **Android 11 or newer** and **an unlocked phone**. Some ROMs refuse to launch an
  app on a new display while the lock screen is up.
* The log now names the display it got, for example
  `com.example runs on its own display 61 (PID 7484)`. If it says the display opened but the
  app did not start, unlock the phone and press again.
* The size box next to it (`1920x1080/240`) is the display's resolution and dpi. Very large
  values fail on weaker devices; try `1280x720/213`.

## The window freezes

It should not: adb work runs on a background runspace while the message loop keeps going. If
it does freeze:

* A phone that has stopped answering makes a command wait for its timeout (180 s by default).
  Unplug it and the call ends.
* `adb kill-server` from another program while a command is in flight has the same effect.

## Sharing says it started but the phone has no internet

1. Press **Test connection**. Do not use ping — see [Limits](limits.md).
2. Turn on **Turn Wi-Fi off while sharing**: a phone that keeps Wi-Fi may route around the
   tunnel and look broken.
3. Press **Reinstall client APK**, then start again.
4. **Kill stray relays** clears a relay left behind by an earlier run that still holds the
   port.
5. If you used OTG in between, press **Repair tunnel**.

## The hotspot switch does not stick

The phone's own settings screen is driven for this. It fails when:

* the phone is locked, or the settings screen is in another user or second space;
* the ROM renamed the switch, in which case the log says the tile was not found.

Open the hotspot screen on the phone and flip it there; the state line still reports it
correctly afterwards.

## The picture is stale or black

* Press **Capture** once by hand. If the log shows a timeout, the phone is busy or asleep.
* A phone that is asleep returns a black frame. Press **Power** in the screen pane first.
* Some apps (banking, DRM video) blank their own window in screenshots. That is the app's
  choice, not a fault here.

## Files: a folder is empty although the phone shows files

* `/sdcard` is a symbolic link, so listings use a trailing slash. If you typed a path by hand,
  make sure it exists exactly as written.
* Folders under `/data` belong to apps and adb may not read them — the log says
  `Permission denied` rather than showing an empty folder.
* Search uses `find -L`, which follows links; a search that returns nothing usually means the
  pattern, not the path, is wrong.

## get-upstream.ps1 fails

| Message | Meaning |
|---|---|
| `... does not exist on GitHub` | The version number is wrong; check the project's releases page |
| `SHA256 mismatch` | The download was damaged or tampered with; it is deleted, run again |
| `could not read SHA256SUMS.txt` | No network, or that release has no checksum file; the archive hash is printed so you can check it yourself |

Behind a proxy, set `$env:HTTPS_PROXY` before running it.

## Recovering settings

Settings live in `%APPDATA%\AndroidDC\settings.json`. Delete that file to start clean; the
next run recreates it with defaults. A file left by an older name is copied over once, so
nothing is lost when upgrading.

## The live shell shows nothing after Logcat has run

Update to the current version. In earlier versions, once the *Logcat* page had been started the
live shell on the *Shell* page stopped answering: it said it was connected, took commands, and
printed nothing — while logcat ran and after it was stopped, until AndroidDC was restarted.
Commands run from other pages were not affected, and neither was adb itself.

The cause was how logcat's output was read: through a PowerShell event subscription. Once that
subscription had carried a live adb logcat stream, no asynchronous read completed on any adb
process started afterwards, and the live shell is one. Logcat is now read by a small C# class,
the way the live shell already was.

## Arabic text shows as odd characters, or a shell command with Arabic does something else

Update to the current version. Earlier versions decoded what adb and scrcpy print with the
Windows console code page, and wrote what you type into the live shell in that page too. On a
PC whose console is still on an OEM page (437, 720 …) that meant:

* app names, contact names, log lines and file names in Arabic arrived as box-drawing
  characters;
* Arabic typed into the live shell reached the phone as `?` marks, which the phone's shell
  reads as a file pattern — `echo` followed by four Arabic letters printed four-letter file
  names instead. A command that deletes or moves files could have touched other files.

The current version reads and writes adb's UTF-8 directly and no longer depends on the code
page. None of this showed on a PC with *Use Unicode UTF-8 for worldwide language support*
switched on, which is why it went unnoticed.

To see which page your console uses: `[Console]::OutputEncoding.CodePage` in Windows
PowerShell. `65001` is UTF-8.

## Reporting a bug

Please include:

* what you pressed and what the log said (the **Save log** button writes it to a file);
* `adb.exe --version` and `scrcpy.exe --version`;
* the phone's model and `ro.build.version.release`;
* whether the phone was locked or unlocked at the time.
