# User guide

[← back to the README](../README.md)

Every tab and every button. The window has three fixed parts:

* the **phone screen** frame on the left, folded away by the slim strip beside it;
* the **device list** at the top right, shared by every tab;
* the **log** at the bottom right, colour coded: steps in blue, good news in green,
  warnings in amber, failures in red. Drag the bar above its buttons to give it more or less
  room, or fold it away with ▼ (double-clicking the bar does the same); the window remembers
  both.

The row above the log says what is running: while an adb call takes longer than a moment, a
moving bar and the command itself appear there, and the pointer shows it is working. On the
right, **Sharing: off** or the phone being shared is the state of the internet sharing only.

The device list follows the cable: plug a phone in, pull one out or accept its RSA prompt, and
the list is read again within a few seconds, without pressing refresh.

On a short window the device list shows two rows instead of four, and the line under it
(battery, signal, screen) ends in "..." when it does not fit - hover it for the whole line.

Actions apply to whatever is selected in the device list. Select several devices with
Ctrl+click or Shift+click and one press acts on all of them.

---

## The phone screen frame

| Control | What it does |
|---|---|
| **Capture** | One screenshot, streamed straight out of `adb exec-out screencap -p`. No file is written |
| **Auto** + interval | Repeats the capture. The default is 2000 ms; one capture costs about 1.4 s, so smaller values simply run back to back |
| **Save** | Writes the picture on screen to a PNG you choose |
| **Clear** | Drops the picture from the window. The phone is not touched |
| **Back / Home / Recents / Power / Vol+ / Vol−** | Key events sent with `input keyevent` |
| text box + **Send text** | Types the text on the phone, Arabic included |
| the slim strip on the frame's right edge | Folds the whole frame away and narrows the window; press again to get it back at the exact width it had |

Clicking the picture sends a tap at the matching point on the phone; dragging sends a swipe;
holding still for more than half a second sends a long press. See [Shortcuts](shortcuts.md)
for the mouse buttons.

---

## Device

The home tab: what the phone is, and the handful of things you do most often.

**Top row** — *Load details + screenshot* reads the device properties into the panel on the
left; *Copy* puts them on the clipboard; **Mirror with scrcpy** starts mirroring immediately
using whatever is configured on the *Advanced* tab, so you never have to go there for a normal
session.

**Quick toggles** — each row is a pair of On/Off buttons applied to every selected device:
auto-rotate, location, Bluetooth, Wi-Fi, battery saver, vibrate on ring, touch haptics, show
taps, stay awake, developer options. The button that matches the phone is tinted blue: the
page reads them when it opens, when you pick another phone, and after every press. A setting
the phone does not report tints neither button. With several phones selected, the tint is the
first one's. Below them: **Torch**, **Buzz** (one vibration), **Read states** (reads them
again and writes them to the log) and **Dev screen** (opens developer options on the phone).

Torch has no supported adb switch on any Android version. AndroidDC opens the quick-settings
panel, finds the torch tile with `uiautomator dump`, taps it, and then verifies the result —
if the ROM moved the tile, the log says so instead of pretending it worked.

**Phone number** — type a number, then:

| Button | What happens |
|---|---|
| **Call** | Confirms, then `am start -a android.intent.action.CALL -d tel:<number>` |
| **Hang up** | Sends `KEYCODE_ENDCALL` |
| **Send SMS...** | Asks for the body, then composes it in the phone's SMS app |
| **Send USSD** | Confirms with a warning, encodes `#` as `%23`, dials the code and re-captures the screen so you can read the operator's answer |
| **Open dialer** | Puts the number in the dialer without calling |

---

## Tethering

Two directions of the same subject, on two inner pages.

### PC → Phone (gnirehtet)

Gives the phone the PC's internet, no root required. Pick a **DNS** (8.8.8.8 by default), a
**port** (31416) and optional **routes**, then **Start sharing**.

| Control | What it does |
|---|---|
| **Start sharing / Stop** | Runs the gnirehtet relay on the PC and the client on the phone |
| **Turn Wi-Fi off while sharing** | So the phone cannot silently fall back to its own network. Turned back on when sharing stops - only on a phone where it was on to begin with |
| **Reinstall client APK** | Pushes `gnirehtet.apk` again before starting |
| **Check internet after start** | Runs the connection test by itself |
| **Open scrcpy after start** | Starts mirroring once the tunnel is up |
| **Test connection** | curl → netcat → `dumpsys connectivity` VALIDATED, in that order |
| **Install / Uninstall client** | Manages the APK on the phone without starting the tunnel |

**Ping will not work through this tunnel and that is normal.** gnirehtet forwards TCP and UDP
only; ping is ICMP. Use *Test connection*, which asks for a real page instead.

### Phone → PC (tether / proxy)

The opposite direction, for when the PC has no internet.

* **Enable USB tethering** runs `svc usb setFunctions rndis`. Many phones refuse it without
  root, so **Open settings on phone** takes you to the tethering screen to flip it by hand.
* The status line reports what Windows sees: an adapter matching *Remote NDIS*, *Android*,
  *Tether* or *Internet Sharing*.
* **Proxy over ADB** is the fallback: run a proxy app on the phone (Every Proxy, Drony, …),
  set the port here, and *Use phone proxy* forwards it to the PC. *Test proxy* checks it.

---

## Advanced

Four inner pages holding everything you do not need every day.

### Mirroring (scrcpy)

The full scrcpy surface: max size, bit rate, fps, video codec, display id, new virtual
display and its size, start-app (pick one of the phone's apps by name, or type a package),
fullscreen, borderless, always on top, screen off, stay
awake, no audio, view only, power off on close, no screensaver, keyboard/mouse/gamepad mode
(`uhid`, `aoa`, `disabled`), OTG, recording, and a free-text box for any other flag.

* **Launch scrcpy** starts a window per selected device.
* **Share internet + scrcpy** starts the tunnel and the mirror together.
* **OTG** talks to the phone as a USB keyboard/mouse without a screen. It restarts the adb
  server, which drops an active tunnel — AndroidDC warns first and rebuilds it afterwards.
* **Show command** prints the exact `scrcpy` command line to the log, so you can reuse it.

### More scrcpy options

| Group | What it sets |
|---|---|
| Recording | format (mp4 / mkv / m4a / opus / flac / wav), rotation, and a time limit that stops it by itself |
| Orientation | turn the window, or turn what the phone sends (`@` locks it) |
| New display | where the keyboard goes on a virtual display, system bars, and whether the apps keep running when the window closes |
| Window on this PC | x, y, width, height, the frame rate in the log, and a screen-off timeout that applies while mirroring |
| Keyboard and mouse | the shortcut key, mouse bindings, text-instead-of-keycodes, raw keys, key repeat, legacy paste, and what happens to adb and the phone when the window closes |

### Device tools (adb)

| Group | Controls |
|---|---|
| Connection | **Pair over Wi-Fi**, **Find devices** (mDNS), **Reconnect**, **Bug report**, `adb tcpip 5555`, connect box, disconnect, restart server, list reverse tunnels, kill stray relays, repair tunnel |
| Device | install APK, screenshot, screen on/off, reboot, battery |
| Private DNS | mode (automatic / off / custom hostname), hostname box, **Read DNS**, **AD** (fills in AdGuard), **Apply**, and a line showing the resolvers actually in use |
| Keyboard (IME) | list, enable, disable, set default, reset |
| Hotspot | Wi-Fi hotspot on/off, read its state, open the settings screen, USB tether on/off |

The DNS line refreshes by itself when you open the tab or pick another device.

**Pair over Wi-Fi** is the cable-free route on Android 11 and newer. On the phone open
*Developer options → Wireless debugging → Pair device with pairing code*, type the address and
the six digits it shows, and AndroidDC pairs and then offers to connect. The pairing port and
the debugging port are different numbers on that same screen; it asks for both.

### Root / recovery

Eleven adb commands, most of which an ordinary retail phone refuses: `root`, `unroot`,
`remount`, `disable-verity`, `enable-verity`, `sideload`, `emu`, `jdwp`, `keygen`,
`get-devpath` and `wait-for-device`. They are shown rather than hidden, each marked, with a
tooltip saying what it would need.

The page reads `ro.build.type`, `ro.debuggable`, `ro.secure` and the shell uid as soon as it is
opened, from either tab, and marks each row ✔ or ⛔ from that; **Check this device** reads
them again. A retail phone answers `build=user`, and only the harmless three stay on:
`wait-for-device`, `keygen` and `get-devpath`.

The marks belong to one phone. Pick another while the page is open and it is read again; pick
another while it is closed and the marks are cleared, so they are never shown as the answer of
a phone that was not asked. Re-selecting the same phone, or refreshing the list, reads nothing
again.

*I understand — let me try anyway* unlocks the rest for a rooted or userdebug build; the phone
still refuses what it refuses, and the log says so plainly. `root` and `unroot` restart adbd,
so after either one the page waits for the phone to come back and reads it again.

* **jdwp** lists the processes that accept a Java debugger, by name. `adb jdwp` never stops by
  itself, so it is given three seconds; on a retail phone the answer is usually "none".
* **emu** on a phone fails without a word from adb; the log adds that a phone has no emulator
  console.

scrcpy's `--v4l2-sink` is Linux only and is not in the Windows build at all, so it has a note
there instead of a dead button.

---

## Apps

Everything installed. **Name** comes first — "Chrome", "Nafath | نفاذ" — read from the phone
with `scrcpy --list-apps`, because `pm` only knows package names. Asking takes a few seconds,
so each phone is asked once and the names are kept; they are read again by themselves when
the set of installed apps changes, whether from here, the Play Store or anywhere else. Only
apps with a launcher icon have a name; services and libraries show their package alone. The
filter matches the name or the package, and *Export list...* adds the name as a last, quoted
column.

*Launch*, *Own scrcpy window* (opens the app on its own virtual display), *Force stop*,
*App info*, *Uninstall*, *Install APK...*, *Export list...*

**Install** takes `.apk`, and also the split bundles most downloads are today: `.apks`,
`.xapk` and `.apkm`. A bundle is unpacked, `base.apk` goes first and the set is installed with
`install-multiple`. Several `.apk` files can also be picked together as one split set. When a
phone refuses — MIUI's *Install via USB* being off, a signature clash, the wrong CPU — the log
names the reason instead of printing the raw code.

## Contacts

Read from the contacts provider: *Add*, *Edit*, *Delete*, *Call*, *End call*, *Copy*,
*Export all...*, plus a dial box.

## SMS

Conversations read from the SMS provider: *Send*, *Copy*, *Delete*, *Edit body*,
*Export all...*

Android has no shell command that sends an SMS. AndroidDC composes the message in the phone's
own SMS app with the text already filled in — Arabic survives, because it travels as an intent
extra — and the app sends it.

## Cam / Mic

**Camera** — lists what the phone has (`--list-cameras`), then streams the front or back
camera as a video source with a chosen id, facing, size, fps, aspect ratio, high-speed mode
or torch. The phone screen is untouched. Needs Android 12 or newer.

**Microphone / audio** — pick a source (`mic`, `mic-voice-communication`, `output`,
`playback`, `voice-call`, …), then **Listen** to hear it on the PC speakers, **Stop audio**,
or **Record audio...** to write it to a file.

The second row is what gets sent: the **codec**, the **encoder** that produces it, and
**Codecs**, which asks the phone for both. The encoder list only ever offers encoders for the
codec you picked — scrcpy refuses a mismatch — and stays greyed out until the phone has been
asked. `raw` stays in the codec list after a refresh even though no phone lists it: it is not
an encoder, and scrcpy accepts it anyway.

The third row: bit rate, buffer size, and **keep playing on the phone too** (`--audio-dup`),
which needs the `output` source and cannot be combined with recording — scrcpy refuses that
pairing, so AndroidDC says so instead of failing.

**Record audio...** suggests a file name that suits the codec, because scrcpy picks the
container from the name and each container takes only some codecs:

| Codec | Suggested file |
|---|---|
| opus, or *default* | `.opus` |
| aac | `.m4a` — scrcpy refuses aac in an `.opus` file |
| flac | `.flac` |
| raw | `.wav` |

`.mka` takes all four. Source, codec, bit rate, buffer and *keep playing* are remembered
between runs. The encoder is not: encoder names differ from phone to phone, and one saved from
another phone would make scrcpy fail.

**Sizes** and **Codecs** ask the phone what it really supports and fill the dropdowns with the
answer, rather than offering a fixed list. On the test phone that turned five guessed camera
sizes into the 36 it actually has.

This direction only: Android gives no way to push PC audio into the phone's speaker.

## Files

A file manager for the phone.

| Row | Controls |
|---|---|
| Path | Up, path box, Go, jump list (including every mounted volume), *hidden*, *folders first*, item count |
| Search | filter box, **Search here** (recursive, uses `find -L`), Clear, **Recent files** with a window of today / 2 days / week / 30 days |
| Under the list | **Select all**, **None**, **Invert**, the PC folder, Browse, Open folder |
| Actions | Four groups, separated by a rule: moving files (download, move to PC, upload, move to phone), organising them (new folder, rename, delete), archiving them (compress, extract), and opening them (preview, open on phone, copy path) |

A line under the list always shows the space of the volume you are in, for example
`space here: 110G used of 222G | 112G free | 50% full | volume /storage/emulated`.

* **Move to PC** downloads, verifies the copy, then deletes the original from the phone.
  **Move to phone** does the same in reverse.
* **Compress** packs the selection into a `.tar.gz` on the phone itself. The phone has `tar`
  and `gzip` but no `zip`, so that is the format.
* **Extract** unpacks `.zip`, `.tar`, `.tar.gz`, `.tar.bz2` and `.gz` into a folder you name.
* **Preview** shows a picture or a text file **inside the window, without saving anything on
  the PC**. Video and audio need a player, so those are copied to `%TEMP%` first and removed
  when the program closes — the log says so when it happens.

Sort by clicking a column. Right-click any row for the same actions as the buttons.

## Running

What is running right now: process, package, memory, state and kind, read from
`dumpsys activity processes` and `top`.

*Force stop*, *Kill (background)*, *App info*, *Kill all background*, *Copy*, *Export...*,
and a filter box.

## Radios

Wi-Fi, Bluetooth and NFC, one page each under this tab. Opening a page reads what the phone
is doing right away.

### Wi-Fi

State line, **Wi-Fi on/off**, **Scan**, **Saved networks**, the list (SSID, security, signal,
BSSID, saved id), a password box with *show*, **Connect**, **Forget**, **Status**, and
**Wi-Fi settings** to open that screen on the phone.

Joining a saved network needs no password. Joining a new one does — type it in the box first.

### Bluetooth

State line, **Bluetooth on/off**, **Refresh**, the paired list (name, address, bond) and
**Copy address**. Pairing and connecting happen on the phone: Android exposes no adb command
for either, and the tab says so rather than offering a button that cannot work.

### NFC

State read from `dumpsys nfc`, **NFC on/off**, **Refresh**, **NFC settings**, and a box with
the relevant lines of the dump. If the phone has no NFC hardware, the tab reports that.

## Users

Multi-user, for phones that support it.

| Button | What it does |
|---|---|
| **Switch to** | `am switch-user <id>` — the phone screen changes user |
| **Add user** | `pm create-user <name>` |
| **Rename** | Tries `pm rename-user`; Android refuses it from adb (see [Limits](limits.md)) |
| **Remove** | Deletes a user and everything inside it, after a clear warning |
| **Multi-user on / off** | `settings put global user_switcher_enabled 1|0` — hides or shows the switcher, the users themselves are kept |
| **User settings** | Opens that screen on the phone |

The header line reads `2 user(s) of at most 4 | current user: 0 | user switcher: on`.

## Shell

Two pages.

**Shell** — a live `adb shell` with history. *Start shell*, *Stop*, *Clear*, a command box and
*Send*. Output streams into the window as it arrives.

**Logcat** — the device log as it happens. *Start* and *Stop*, a priority level (V/D/I/W/E/F),
a **Contains** filter, **follow** to stay at the newest line, **Clear** (hold Shift to empty
the buffer on the phone as well) and **Save...**.

The filter applies to what is already on screen, not only to lines that arrive next: type into
it and the window is redrawn from the lines held in memory, so everything showing matches.
Clear it and they all come back. The status line says how many of the kept lines match, for
example `465 of 6000 kept lines match 'ActivityManager'`. Filtering happens on this side; the
phone keeps sending everything, so nothing is lost by narrowing the view.

The stream is drained on a timer, so a chatty phone never freezes the window; on a device
emitting roughly 740 lines a second it kept every line. If a log storm ever does outrun it,
the oldest lines are dropped and the status line says how many, rather than the window
stalling to keep up.
