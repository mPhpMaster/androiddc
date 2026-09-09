# User guide

[← back to the README](../README.md)

Every tab and every button. The window has three fixed parts:

* the **phone screen** frame on the left, folded away by the slim strip beside it;
* the **device list** at the top right, shared by every tab;
* the **log** at the bottom right, colour coded: steps in blue, good news in green,
  warnings in amber, failures in red.

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
taps, stay awake, developer options. Below them: **Torch**, **Buzz** (one vibration),
**Read states** (asks the phone what each of those is right now) and **Dev screen** (opens
developer options on the phone).

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
| **Turn Wi-Fi off while sharing** | So the phone cannot silently fall back to its own network |
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

Two inner pages holding everything you do not need every day.

### Mirroring (scrcpy)

The full scrcpy surface: max size, bit rate, fps, video codec, display id, new virtual
display and its size, start-app, fullscreen, borderless, always on top, screen off, stay
awake, no audio, view only, power off on close, no screensaver, keyboard/mouse/gamepad mode
(`uhid`, `aoa`, `disabled`), OTG, recording, and a free-text box for any other flag.

* **Launch scrcpy** starts a window per selected device.
* **Share internet + scrcpy** starts the tunnel and the mirror together.
* **OTG** talks to the phone as a USB keyboard/mouse without a screen. It restarts the adb
  server, which drops an active tunnel — AndroidDC warns first and rebuilds it afterwards.
* **Show command** prints the exact `scrcpy` command line to the log, so you can reuse it.

### Device tools (adb)

| Group | Controls |
|---|---|
| Connection | `adb tcpip 5555`, connect box, disconnect, restart server, list reverse tunnels, kill stray relays, repair tunnel |
| Device | install APK, screenshot, screen on/off, reboot, battery |
| Private DNS | mode (automatic / off / custom hostname), hostname box, **Read DNS**, **AD** (fills in AdGuard), **Apply**, and a line showing the resolvers actually in use |
| Keyboard (IME) | list, enable, disable, set default, reset |
| Hotspot | Wi-Fi hotspot on/off, read its state, open the settings screen, USB tether on/off |

The DNS line refreshes by itself when you open the tab or pick another device.

---

## Apps

Everything installed, with package name, label and paths.

*Launch*, *Own scrcpy window* (opens the app on its own virtual display), *Force stop*,
*App info*, *Uninstall*, *Install APK...*, *Export list...*

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
or **Record audio...** to write it to a file. This direction only: Android gives no way to
push PC audio into the phone's speaker.

## Files

A file manager for the phone.

| Row | Controls |
|---|---|
| Path | Up, path box, Go, jump list (including every mounted volume), *hidden*, *folders first*, item count |
| Search | filter box, **Search here** (recursive, uses `find -L`), Clear, **Recent files** with a window of today / 2 days / week / 30 days |
| Under the list | **Select all**, **None**, **Invert**, the PC folder, Browse, Open folder |
| Actions | Download, Move to PC, Upload..., Move to phone, New folder, Rename, Delete, Open on phone, Copy path, **Compress**, **Extract**, **Preview** |

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

## Wi-Fi

State line, **Wi-Fi on/off**, **Scan**, **Saved networks**, the list (SSID, security, signal,
BSSID, saved id), a password box with *show*, **Connect**, **Forget**, **Status**, and
**Wi-Fi settings** to open that screen on the phone.

Joining a saved network needs no password. Joining a new one does — type it in the box first.

## Bluetooth

State line, **Bluetooth on/off**, **Refresh**, the paired list (name, address, bond) and
**Copy address**. Pairing and connecting happen on the phone: Android exposes no adb command
for either, and the tab says so rather than offering a button that cannot work.

## NFC

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

A live `adb shell` with history. *Start shell*, *Stop*, *Clear*, a command box and *Send*.
Output streams into the window as it arrives.
