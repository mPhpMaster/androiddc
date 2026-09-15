# Changelog

[← back to the README](README.md)

## 1.2.0

### Automation, in both windows

* **Start with Windows**: AndroidDC can start when you sign in, minimized, in the classic window
  or in Nova. It is one value under your own Run key (`HKCU\...\Run`, named `AndroidDC`),
  pointing at the launcher with `-Minimized`; switching it off removes that value and nothing
  else.
* **Rules per phone**: pick a phone, switch on what should happen when it is plugged in - share
  the phone's internet with the PC (USB tethering), share the PC's with the phone, the adb
  proxy, the hotspot, adb over Wi-Fi, mirroring, a camera, the phone's sound, a screenshot,
  waking the screen, Wi-Fi / Bluetooth / NFC, stay awake, auto-rotate, location, battery saver,
  vibrate, open an app, logcat, a Windows notification. The actions run in that order, on that
  phone only, one after another, and **Run now** tries a rule without unplugging.
* The rules are kept in `%APPDATA%\AndroidDC\automation.json` and written at once, so both
  windows see the same rules. Only one window runs them at a time. A window opened by hand, or
  by the other window's switch button, does not run the rules again for phones that were
  already plugged in; a window started with Windows does.
* Classic: **Advanced > Automation**. Nova: the **Automation** page under System.
* **An icon by the clock** while AndroidDC runs, in both windows. A click on it hides the window
  or shows it again; its menu has *Show the window*, *Hide to the tray* and *Exit*. Minimizing
  hides the window there too - off the taskbar, still watching for phones and running their
  rules - and a window started with Windows starts there. The first time it hides, a
  notification says it is still running. The close button still closes the program.
* The device list now follows the cable while the window is minimized or behind other windows
  too - still not while one of its own questions is waiting.
* Both launchers pass their arguments on to the script.
* `tests/automation.ps1` and `nova/tests/automation.ps1`: the rules file (a one-rule list stays a
  list, a broken file is not overwritten), plugged in versus already there, the start-up entry
  against a test key - the real Run key and rules are never touched.

## 1.1.0

### A second window: Nova

* **AndroidDC Nova** (`androiddc-nova.vbs`, the code in `nova/`) is the same tool in a newer
  design: a side navigation grouped into Workspace, Personal, Connect and System, a device card
  with battery, signal and screen, a card per task, and an activity log that can be dragged or
  folded. It is WPF hosted in Windows PowerShell 5.1 - still nothing to install.
* Every feature of the classic window is there, page by page: Overview (battery, temperature
  and memory, quick toggles that show the phone's state, phone number), Screen, Mirroring,
  Apps, Files, Camera & mic, Messages, Contacts, Tethering, Radios, Tools, Running, Users and
  Shell. `F5`, `Ctrl`+`1`...`9` and `Ctrl`+`L` work there too.
* The two windows share the project's adb, scrcpy and gnirehtet and keep their settings apart
  (`nova-settings.json`). **Open Nova window** on the classic *Device* tab and **Classic
  window** in Nova close one and open the other, the normal way, so settings are saved.
* Nova's typefaces, DM Sans and Space Grotesk, ship in `nova/fonts/` under the SIL Open Font
  License.
* `nova/tests/` runs the real Nova window off screen: a test per page, and a tour that opens
  every page and inner tab at the default and the smallest size. CI also runs
  `nova/tests/audit.ps1` (no function defined twice, well-formed XAML, page-prefixed names).

### The classic window

* At the smallest window every page has room again. The log took a fixed share of the height
  and left the Files list about 40 px - not one row. Its height can now be dragged by the bar
  above its buttons, or the log folded away; the window remembers both. A short window also
  gives the device list two rows instead of four.
* Wi-Fi, Bluetooth and NFC are one tab, **Radios**. As three tabs of their own, fourteen in
  all, Users and Shell fell off the tab strip at the smallest window.
* The device list's columns share the width it has, so *Client* no longer hides behind a
  scroll bar.
* The battery and signal line stays on one line and ends in "..." when it does not fit; its
  tooltip holds the whole of it.
* The quick toggles show what the phone is doing: the On or Off button that matches it is
  tinted, read when the Device page opens, when another phone is picked and after each press.
  The ten settings are read in one trip to the phone instead of ten.
* A strip above the log names the adb call that is running, with a moving bar, once it takes
  longer than a moment. Before, a click that took seconds looked like one that did nothing.
* The label at the bottom right says **Sharing: off** instead of *Stopped*, which read as the
  state of the whole program. A bug report no longer empties it when it finishes.
* The device list follows the cable: a phone plugged in, pulled out or authorised is noticed
  within a few seconds, without pressing refresh.
* Keys that work anywhere in the window: `F5` reads the page on screen again, `Ctrl`+`1`…`9`
  open a tab, `Ctrl`+`L` empties the log.

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
* When a phone refuses to install the sharing client over USB (`INSTALL_FAILED_USER_RESTRICTED`,
  seen on Xiaomi), the log says which setting allows it.
* Sharing can be started again right after it was stopped. Each start used the same log files,
  and a process the stopped relay had left behind still held them, so the new start failed with
  "being used by another process". Every start has its own files now.
* Logcat no longer silences the live shell; adb output is read as UTF-8 on any code page.

### Checks

CI parses every script, keeps them ASCII or BOM, fails on a variable read before it is set, on
a control that is never shown or a button with no handler, and on a hardcoded path. `tests\`
runs the real window against a phone: eleven tests - see [tests/README.md](tests/README.md).
