# Changelog

[← back to the README](README.md)

## Unreleased

### A backup is one file, and you can see what is in it

* **A backup is a `.zip` now**, not a folder: one file named after the phone and the time, to
  copy, to move, or to put on another drive. The files are still pulled into a folder first -
  that is what adb writes - and the folder is packed and then removed. Photos, video and APKs
  go in as they are rather than being squeezed again, so packing costs minutes, not hours.
* **Restoring reads the `.zip`.** Nothing is unpacked whole: each file is taken out, sent to
  the phone, and dropped again, and an app's APKs come out one app at a time.
* **What is inside** lists every file in the opened backup - which part it belongs to, where it
  was on the phone, how big it is - read from the zip's own index, with a find box over it.
  Pick some lines and *Save a copy ...* writes those files onto this PC: one photo out of a
  backup, with no phone in it at all.
* **My backups** shows one folder - the box at the top says which, *Browse ...* changes it, and
  it starts at wherever your last backup went. The list under it is what is in that folder at
  this moment, newest first: when, which phone, what it holds, its size and the file's name.
  Nothing is remembered about the backups themselves, so one moved into that folder appears and
  one taken out of it is gone, with no list to tidy. Both windows follow the same folder, kept
  in `%APPDATA%\AndroidDCackups.json`.
* **Opening a backup is quick whatever is in it**: the manifest is read and nothing more, so a
  backup of forty thousand photos names its phone at once. *What is inside* and *Apps to
  install* read the backup itself, and only when you look at them, with the bar rolling and a
  count while they do. A backup of six thousand files opened in 39 ms and listed in 1.4 s where
  it used to freeze the window for minutes: an array that grows by `+=` copies itself every
  time, and a phone's worth of files made that thousands of copies.
* **Older backups still open.** A backup kept as a folder - one taken before this, or one whose
  packing was cancelled - opens with *From a folder ...* and behaves the same everywhere.
* Cancel works while it packs, and a stopped pack leaves no half-written `.zip` behind: the
  pulled folder is kept. A drive without room for the packed copy says so and keeps the folder
  as well.
* **The apps in a backup are a list you can read**: what each app is called, its package, the
  version the backup holds, its size, and how it stands against the phone - *not on the phone*,
  *on the phone*, *older on the phone*, *newer on the phone*. The ones the phone lacks come
  first and are ticked for you, the line under the list says how many and which button to press,
  and a find box narrows it by name or package while the ticks stay put. "missing" is gone: it
  said nothing about what to do.
* **A backup writes down what its apps are called**, from `scrcpy --list-apps`, while the phone
  still has them - so a backup read a year later says *WhatsApp*, not `com.whatsapp`, even for
  an app that phone no longer has. Backups taken before this show packages.
* A refused install says what to do: a newer version on the phone has to be removed before an
  older one goes on, and an app signed by someone else has to be removed with its data.
* Smaller things found on the way: a list with no room for its "nothing here yet" line hides it
  instead of leaving it where it last stood, on top of the row above; Nova's Backup page scrolls
  when the window is too short for it, rather than cutting the buttons off the bottom; and the
  bar rolls, instead of sitting at zero, while something is running whose length is not known.
* Two bugs found while doing it: the list of contacts in a backup was read back as one item
  when it held several (so restoring several contacts would have made one), and a JSON list
  read with `@(... | ConvertFrom-Json)` came back as a list of one array.

### The classic window, made easier to live with

* **It opens where you left it**, at the size you left it, maximized if it was. A saved place
  is used only while it still lands on a screen this PC has, so a window cannot come back onto
  a monitor that has been unplugged.
* **Every button says what it does on hover.** 125 of the 190 had nothing; now all of them do,
  and they say what the button acts on, what the phone may refuse, and the key that does the
  same. A test fails if a button ever ships without it.
* **An empty list says which button fills it** instead of sitting there blank - the device
  list, apps, files, contacts, messages, processes, Wi-Fi, Bluetooth, users, the automation
  rules and a backup's apps.
* **The log has a find box.** Type in it and only the lines holding that text are shown; empty
  it and they all come back. The lines themselves are kept either way, and *Clear log* (Ctrl+L)
  empties both.
* **The keyboard reaches more.** `Ctrl`+`0` opens the tenth tab and `Ctrl`+`Shift`+`1`...`9`
  the ones after it, so every tab has a key. `Enter` does the page's reading action - refresh
  the list, go to the folder - and never anything that starts, installs, deletes or sends.
  `Tab` now walks a page the way the page is laid out, down and across, instead of in the
  order the controls happened to be written.
* **The device list's `Client` column is called `gnirehtet`**, which is what it is about.
* **The Connection box on Device tools was twelve controls deep.** The three that are only
  reached for when something is stuck - list reverse tunnels, kill stray relays, repair
  tunnel - are their own box now, *When something is stuck*.
* **Shorter tab captions**: *Mirroring*, *More options*, *Device tools*, *PC -> Phone*,
  *Phone -> PC*. The words in brackets repeated what each page says in its first line, and the
  strip was the first thing to run out of room on a small window.
* Reading several phones at once says which phone of how many in the busy strip.

## 1.3.0

### A backup of the phone, and putting one back

* **Advanced > Backup** in the classic window, the **Backup** page in Nova. Tick what goes in -
  phone files, the apps' APK files, contacts with messages and the call log, the settings and
  app list - choose a folder, and it writes one folder per backup, named after the phone and
  the time, with `manifest.json` saying what is in it. Plain files: no archive, no password,
  nothing to unpack.
* **What cannot be in it, and why.** Android does not let adb read what is inside an app -
  chats, game saves, an app's own settings - without root, and `adb backup` has returned almost
  nothing since Android 12. `Android/data` and `Android/obb` are closed for the same reason;
  `Android/media`, where messaging apps keep pictures, is taken.
* **Putting it back**: open a backup and the window says what it holds. *Restore files* asks
  first when the phone already has some of them - write over them, send only the rest, or stop.
  Apps are listed with the ones this phone lacks ticked, and each is installed in one call,
  splits included. *Restore contacts* adds the ones the phone does not have, matched by name
  and number; messages and the call log are saved to read but never written back, because
  Android has no way for adb to write them.
* **It can be stopped, and it says what happened.** A **Cancel** button next to the progress
  bar stops a backup or a restore where it is - adb is killed mid-file, and what was already
  done stays. The bar fills as a folder is pulled, named and sized, because the size of the
  folder on the phone is read first. A phone that is unplugged halfway is noticed at once and
  the run ends there rather than failing file after file. Whatever ends it - finished,
  cancelled, or the phone gone - the log says so and a notification appears by the clock, and
  a backup that did not finish is marked *not complete* in its manifest and where it is opened.
* `tests/backup.ps1` and `nova/tests/backup.ps1` check the parts, the folder name, the row
  parser, a backup folder read back and which files a phone already has - against a made-up
  phone, so nothing is sent to a real one.

## 1.2.2

* **`start-menu.vbs`** puts both windows in the Start menu: *AndroidDC* and *AndroidDC Nova*,
  with the AndroidDC icon, under *All apps*. Windows keeps *Pin to Start* for the user, so the
  message it ends with says where that is. Run it again after moving the folder. CI checks it
  points at both launchers.
* **`start-menu-remove.vbs`** does the reverse: it removes those two shortcuts and touches
  nothing else. `start-menu.vbs /remove` does the same. Both, their switches and their
  messages are in *Command line*.
* **Nova no longer jumps to Overview.** A double-click on a phone in the device list opened
  Overview from whatever page was on screen; it now only picks the phone and closes the list.
  *Load details* on Overview still reads the phone there.
* **Nova remembers its page at once.** The page on screen was written only when the window
  closed normally, so a window Windows ended at sign-out - one in the tray, say - opened again
  on an older page. It is now written each time the page changes.

## 1.2.1

### The rules set before, seen without looking for them

* At startup the log says what is set: how many rules, how many are on, each rule's phone
  and actions, whether AndroidDC starts with Windows, and where that is set.
* The icon by the clock has an **Automation** entry at the top of its menu. It lists the same
  thing, read from the rules file each time the menu opens, so a change made in the other
  window shows too. A click on a rule, or on *Open the rules ...*, shows the window at the
  rules page. The icon's tooltip counts the rules that are on.
* The classic *Advanced > Automation* tab and Nova's *Automation* entry in the side navigation
  carry the number of rules, e.g. **Automation (2)**.

### Documentation

* Every page caught up with 1.2: `-Minimized` in the command line, start with Windows and the
  icon by the clock in getting started, rules in *What it runs on your phone*, three new
  troubleshooting sections (a rule that did not run, the icon out of sight, not starting with
  Windows), the shared folder and four new PowerShell traps in the architecture, and the icon's
  clicks in *Keyboard and mouse*.

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
