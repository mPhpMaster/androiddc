# Limits

[← back to the README](../README.md)

Everything here was tried on real phones and refused by Android, not left out for lack of
effort. Each entry says what happens instead.

## Ping never works through gnirehtet

gnirehtet relays **TCP and UDP only**. Ping is ICMP, which it does not carry, so
`ping 8.8.8.8` fails on the phone even while the browser loads pages perfectly.

*Instead:* the **Test connection** button asks for a real page (curl, then netcat, then
`dumpsys connectivity` looking for `VALIDATED`). Use that to decide whether the tunnel works.

## OTG restarts the adb server

`scrcpy --otg` talks to the phone as a USB device, and to do that it kills and restarts the
adb server. Any reverse tunnel dies with it.

*Instead:* AndroidDC warns before starting OTG and rebuilds the tunnel afterwards with
`adb reverse` directly — `gnirehtet tunnel` hangs after an adb restart, so it is not used
there. **Repair tunnel** on the *Advanced* tab does the same by hand.

## A user cannot be renamed from adb

`pm rename-user` exists but needs the `MANAGE_USERS` permission, which belongs to the system.
The shell user holds `CREATE_USERS`, so adding, removing and switching users work, and only
renaming is refused:

```
java.lang.SecurityException: You need MANAGE_USERS permission to: rename users
```

*Instead:* the button reports exactly that and offers **User settings**, which opens the
screen on the phone where the rename is allowed.

## Bluetooth cannot be paired or connected

Android exposes `cmd bluetooth_manager enable|disable|wait-for-state` and nothing else. There
is no supported command that pairs a device or connects to one already paired.

*Instead:* the tab turns the radio on and off and lists the paired devices with their
addresses, and **Bluetooth settings** opens that screen on the phone.

## There is no command that sends an SMS

No Android release exposes one to the shell.

*Instead:* AndroidDC opens the phone's own SMS app with the number and the body already
filled in (`android.intent.action.SENDTO` with an `sms_body` extra, which keeps Arabic
intact) and the message is sent from there.

## PC audio cannot be pushed to the phone speaker

Audio travels phone → PC only. Android has no route in the other direction that does not
involve installing an app on the phone.

*Instead:* the *Cam / Mic* tab streams the phone's microphone or its output to the PC, and
records it if you want.

## The phone has no `zip`

Android ships `tar`, `gzip`, `gunzip`, `bzip2` and `unzip`, but no `zip`.

*Instead:* **Compress** makes a `.tar.gz` on the phone. **Extract** reads `.zip`, `.tar`,
`.tar.gz`, `.tar.bz2` and `.gz`, so archives that arrive from elsewhere still open.

## Torch has no adb switch

There is no supported command for the flashlight on any Android version.

*Instead:* AndroidDC opens the quick-settings panel, locates the torch tile with
`uiautomator dump`, taps its centre, and then verifies the state. If the ROM moved or removed
the tile, the log says the tile was not found rather than claiming success.

## Hotspot is driven through the settings screen

Same reason: no stable command. The switch is found and tapped through UI automation, then
confirmed with `dumpsys tethering` (`Type: TETHERING_WIFI`). The hotspot **password cannot be
read** — the phone masks it on that screen.

This also means the hotspot cannot be changed from a second space or a secondary user, because
the settings screen belongs to the user that owns it.

## USB tethering is often blocked

`svc usb setFunctions rndis` returns without error on many phones and simply does nothing,
because the manufacturer restricts it to the settings UI.

*Instead:* **Open settings on phone** takes you straight to the tethering screen, and the
status line reports what Windows actually sees on its side.

## Screen capture costs about 1.4 seconds

That is what `screencap` takes on the devices tested, most of it on the phone. Auto capture
therefore defaults to 2000 ms; smaller intervals simply run one capture after another.

*Instead:* for anything live, mirror with scrcpy — that is a video stream, not a series of
screenshots.

## Windows cannot be told a connection is metered

There is no supported API for it.

*Instead:* the *Tethering* tab offers to open `ms-settings:network-ethernet` so you can set
it yourself, rather than claiming to have done it.

## Root, remount and recovery need a build you do not have

`adb root`, `unroot`, `remount`, `disable-verity` and `enable-verity` only work on a
`userdebug` or `eng` build. A retail phone answers `adbd cannot run as root in production
builds`. `sideload` needs the phone in recovery, and `emu` needs an emulator.

*Instead:* the *Advanced → Root / recovery* page lists them all, reads `ro.build.type`,
`ro.debuggable`, `ro.secure` and the shell uid from the phone in front of you, and marks each
one ✔ or ⛔ for that device. Nothing is hidden and nothing is pretended: a checkbox will let
you press them anyway, and the phone's refusal is printed as it came.

## Installing can be refused by the phone, not the file

A split bundle installs correctly and the phone can still say no:

* `INSTALL_FAILED_USER_RESTRICTED` — MIUI and ColorOS keep *Install via USB* switched off,
  and MIUI wants an account signed in before it can be turned on.
* `INSTALL_FAILED_NO_MATCHING_ABIS` — the splits are built for another CPU.
* `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — a different signing key than the copy installed.

*Instead:* each of those is translated into a sentence in the log rather than left as a code.

## A locked phone limits what works

Taps, swipes and app launches on a new display are refused while the lock screen is up, and
some ROMs also hide the quick-settings tiles. Unlock the phone first; AndroidDC reads the lock
state from `dumpsys trust` and says so when it matters.
