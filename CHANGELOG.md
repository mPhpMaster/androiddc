# Changelog

[← back to the README](README.md)

## 1.0.0

The first release. One window on Windows that drives Android devices over plain `adb`, with
scrcpy and gnirehtet fetched from their official releases by `get-upstream.ps1`.

### What is in it

* **Device** - details, a live screenshot you can tap and swipe, quick toggles, call / SMS /
  USSD, one-click mirroring.
* **Tethering** - the PC's internet to the phone (gnirehtet), and the phone's to the PC over
  USB or a proxy.
* **Advanced** - every scrcpy option including virtual display, OTG, recording format, time
  limit and orientation; wireless pairing, mDNS discovery, bug report, private DNS, input
  methods, hotspot; a Root / recovery page marked against the real device.
* **Apps** - by name as well as package, launch, stop, uninstall, split APK bundles.
* **Contacts, SMS, Cam / Mic, Files, Running, Wi-Fi, Bluetooth, NFC, Users, Shell** - see the
  [user guide](docs/user-guide.md).
* Every list has its actions on the right mouse button; symbols replace words where a symbol
  is already known; every page fits the smallest window (1120 x 700).

### Fixed before release

Found by a review of the whole code, each checked against a phone:

* Text you type reaches the phone whole. adb and the phone's shell split arguments at spaces,
  and Windows PowerShell drops `"` inside them: an SMS body kept its first word, a Wi-Fi
  network or password with a space failed, a name with an apostrophe broke the command. Such
  text now travels as one quoted argument, encoded in base64
  ([what it runs](docs/what-it-runs.md)).
* *Turn Wi-Fi off while sharing* no longer turns Wi-Fi on at the end on a phone where it was
  off before; the same for `gnirehtet-share.ps1 -DisableWifi`.
* `get-upstream.ps1 -CacheFolder` deletes only the archives it used, not every `.zip` in that
  folder.
* Apps labelled user / system and enabled / disabled by whole package name, not by prefix.
* Search and *Recent files* hits: *Move to PC* deletes the phone copy once the PC copy is
  verified, and *Rename* and *Compress* work on them, from one folder or several.
* Filter boxes take `[ ]` and `*` literally.
* Wi-Fi networks sorted by signal strength as a number, and each saved network listed once:
  Android 15 prints a network once per security type it accepts, under the same id. Two saved
  networks whose names differ only in case ("KAIF 5G", "Kaif 5G") are two rows, not one.
* A new contact's details go to the row just created.
* Logcat no longer silences the live shell; adb output is read as UTF-8 on any code page.

### Checks

CI parses every script, keeps them ASCII or BOM, fails on a variable read before it is set, on
a control that is never shown or a button with no handler, and on a hardcoded path. `tests\`
runs the real window against a phone: eleven tests - see [tests/README.md](tests/README.md).
