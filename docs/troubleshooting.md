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

## FTP does not start or its notification is missing

* A source checkout needs a JDK and Android SDK platform 35 with build tools to create the phone server and companion APK. A packaged copy needs those generated files included.
* If the phone says installation is not allowed, enable **Install via USB** in its Developer options and approve any prompt on the phone. AndroidDC installs the FTP companion only when you start FTP on that phone.
* Phone and PC need to reach each other on the local network. FTP is unencrypted; use a trusted network.
* Expand the **AndroidDC FTP** notification to see **Stop FTP**. Stopping sharing leaves the phone app installed. Use **Uninstall FTP phone app** on the FTP page to remove it.
* If you reopen AndroidDC while the server is running, select that phone. The FTP page detects it and Nova shows **FTP running** in the header. Login details can be restored only under the Windows account that started it.

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

## Sharing stops at "Install failed"

Starting a share installs the gnirehtet client on the phone the first time. If the log shows
`INSTALL_FAILED_USER_RESTRICTED`, the phone refuses any app installed over USB:

* **Xiaomi, Redmi, POCO:** Settings → Developer options → turn on **Install via USB** (it may ask
  you to sign in to a Mi account), then start again and accept the prompt on the phone.
* Other phones with a similar switch name it *Verify apps over USB* or *USB install*.

The log says this itself when it happens.

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

## A rule did not run when I plugged the phone in

1. **Is the rule there and on?** The log lists every rule at startup, and so does *Automation*
   in the menu of the icon by the clock. A rule that is *off*, or has *nothing to do yet*, runs
   nothing.
2. **Is it that phone?** A rule belongs to one serial. A phone connected over Wi-Fi has a
   different serial (`<ip>:5555`) from the same phone on a cable.
3. **Was the phone already plugged in?** A window you open by hand does not run the rules for
   phones already there, and neither does the one the other window's switch button opens.
   Unplug and plug again, or press *Run now*. Only a window started with Windows runs the rules
   for phones already plugged in.
4. **Is the phone ready?** A phone waiting for its *Allow USB debugging?* prompt is not ready.
   The rule runs once the prompt is accepted.
5. **Is one of AndroidDC's questions open?** While a dialog of this program waits for an
   answer, the device list is not watched.
6. **USB tethering or the hotspot did not switch?** Many phones refuse that from adb, and
   AndroidDC then taps the switch in the phone's settings. That needs the screen on and the
   phone unlocked, so put *Wake the screen* in the rule and unlock the phone.

The log says what each action did, one line per action, starting with `Automation:`.

## I cannot find AndroidDC after minimizing it

Minimizing hides the window in the icon by the clock, not in the taskbar. If Windows has tucked
the icon away, it is under the **^** arrow next to the clock. A click on it shows the window.
Drag it out next to the clock to keep it in sight.

## AndroidDC did not start with Windows

* Look under *Advanced > Automation* (Nova: *Automation*): the box shows what is really
  written, not what was last clicked.
* The entry points at the launcher inside this folder. After moving the folder, turn the box
  off and on again, so the entry points at the new place.
* Windows' *Task Manager > Startup apps* lists it by the program the entry runs, *Microsoft
  Windows Based Script Host* (wscript). A startup app switched off there does not run.

## A backup or a restore did not do what I expected

**Where is my backup?** It is one `.zip` file in the folder you picked, named after the phone
and the time. *Advanced > Backup > My backups* lists what is in that folder; *Show in Explorer*
opens it with the file picked out.

**My backups is empty, or lists the wrong ones.** It shows one folder, the one named in the box
at the top - by default where your last backup went. Point it somewhere else with *Browse ...*,
or type the path and press Enter. A folder that is not there says so instead of listing
nothing quietly.

**I want one file out of a backup, not the whole thing.** Open the backup, go to *What is
inside*, find the file, pick it and press *Save a copy ...*. Nothing goes near a phone.

**It ended as a folder, not a `.zip`.** Either the packing was cancelled, or the drive had no
room for the packed copy - the log says which. What was pulled is all there, and the folder
opens with *From a folder ...* exactly as a `.zip` does. Backups taken before version 1.4.0
are folders too.

**Some folders were refused.** The log names them. `Android/data` and `Android/obb` have been
closed to adb since Android 11, so they are skipped on purpose; anything else refused is
usually a folder the phone keeps for another user or a second space.

**An app is not in the backup.** Only the apps you installed are taken (`pm list packages -3`),
not the ones that came with the phone. An app whose APK the phone will not hand over is named
in the log and skipped.

**What is inside my apps is missing.** It cannot be read without root - chats, game saves, an
app's own settings. `adb backup`, which used to reach some of it, returns almost nothing on
Android 12 and newer. See [What it runs](what-it-runs.md#backing-up-and-restoring).

**Restoring says the files are already there.** That is the question it asks before writing
over anything: *write over them*, *send only the rest*, or *stop*. Nothing is sent until you
answer.

**An app in the list says "not on the phone" - what do I do?** Nothing, if you do not want it:
that line means the backup has the app and this phone does not. Those are ticked for you, so
*Install ticked apps* puts them back. The other answers - *on the phone*, *older on the phone*,
*newer on the phone* - say how the backup's version compares with what the phone has.

**An app refused to install.** The log says what the phone answered, and what to do about it.
`INSTALL_FAILED_USER_RESTRICTED` means installs over USB are blocked - on Xiaomi, Redmi and POCO
turn on *Developer options > Install via USB*. `INSTALL_FAILED_VERSION_DOWNGRADE` means the
phone has a newer version than the backup's, and Android will not put an older one over it:
remove the app on the phone first if you want the backup's version. `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
means the app on the phone was signed by someone else - a different build of the same app -
and removing it takes its data with it.

**Contacts came back but messages did not.** Android has no way for adb to write messages or
the call log. They are saved in the backup (`personal\messages.json`, `calls.json`) to read and
to keep, and contacts are the only part that goes back on a phone.

**The pictures are not in the gallery.** The gallery shows what it has scanned. AndroidDC asks
it to look again after a restore, but some ROMs take their time; opening the gallery once
usually does it.

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

Settings live in `%APPDATA%\AndroidDC\settings.json` (Nova: `nova-settings.json`). Delete that
file to start clean; the next run recreates it with defaults. The automation rules are
`automation.json` in the same folder. If that file cannot be read, AndroidDC says so in the
log and leaves it as it is instead of overwriting it. A file left by an older name is copied over once, so
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
