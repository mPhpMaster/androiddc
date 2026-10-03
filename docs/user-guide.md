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

## The log, and finding things in it

Everything the program does is written at the bottom right, with the time. The **Find** box
beside *Clear log* shows only the lines holding what you type - a package name, a serial, the
word `refused` - and emptying the box brings them all back. The lines are kept whatever the box
says; *Clear log*, or `Ctrl`+`L`, is what throws them away.

A list that has never been read says which button fills it, rather than looking like a list
with nothing in it.

---

## Device

The home tab: what the phone is, and the handful of things you do most often.

**Top row** — *Load details + screenshot* reads the device properties into the panel on the
left; *Copy* puts them on the clipboard; **Mirror with scrcpy** starts mirroring immediately
using whatever is configured on the *Advanced* tab, so you never have to go there for a normal
session. **Open Nova window** closes this window (saving its settings) and opens the same tool
in the Nova design; Nova's *Classic window* button brings you back.

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

Five inner pages holding everything you do not need every day.

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
| Factory reset and formatting | **Factory reset**, **Format the memory**, and a Cancel of their own |

The DNS line, and the line saying what there is to erase, refresh by themselves when you open
the tab or pick another device.

**Pair over Wi-Fi** is the cable-free route on Android 11 and newer. On the phone open
*Developer options → Wireless debugging → Pair device with pairing code*, type the address and
the six digits it shows, and AndroidDC pairs and then offers to connect. The pairing port and
the debugging port are different numbers on that same screen; it asks for both.

#### Factory reset and formatting

Two buttons, for any Android phone, at the bottom of the page. Both ask twice - a question
saying what will go, and then the word `FORMAT` typed out - and neither runs while a backup or
a restore is running.

Unlike everything else on this page, these two act on **one phone**: the one picked in the
device list, named by model and serial in the question, never on everything selected.

**Factory reset** puts the phone back to how it left the factory: apps, accounts, messages,
photos, settings. The question also says what backup of *this* phone this PC has and how old it
is, which is the one thing a program on this side of the cable can still help with.

What happens then depends on the phone, and the log says which it was:

* it asks the phone to erase itself (`android.intent.action.FACTORY_RESET`). A phone that takes
  it erases itself at once and restarts as new;
* most phones refuse, because adb's shell does not hold `MASTER_CLEAR`. The phone's own reset
  screen is then opened for you, and the last tap - plus the screen lock - happens on the
  phone. That is Android's rule, not a shortcoming here: a PC that could wipe a phone over a
  cable without anybody touching the phone would be a hole.

A memory card is not part of a factory reset. It has its own button.

**Format the memory** formats the memory card in the phone, by handing the job to Android's own
storage manager (`sm format`), which unmounts the card, writes a new empty filesystem and mounts
it again. This one adb *is* allowed to do: its shell holds `MOUNT_FORMAT_FILESYSTEMS`. The new
filesystem has a new serial, so the card appears at a new path afterwards, and the line on the
page says where.

* Where Android refuses even that, it offers to delete every file and folder on the card
  instead, which needs no permission beyond what adb already has. The card keeps the filesystem
  it has and ends up empty either way.
* With **no card in the phone**, it offers to empty the phone's own storage instead - photos,
  videos, downloads, documents, everything under `/sdcard` that Android lets adb reach. Apps,
  accounts and settings stay; *Factory reset* is what clears those.
* Emptying is done name by name from the top level, so the log says what went, and **Cancel**
  is answered between names. What has already gone does not come back.

Nothing is ever claimed without being checked: a format is verified by reading the volume back
and counting the files on it, and an erase by counting what is left. A refusal is reported as a
refusal.

> Take a backup first. There is no undoing either of these, and the backup page is the other
> half of this one: back up, erase, restore.

**While a backup or a restore runs**, the line under the bar says what is being carried, then
how much of it there is - *1.2 GB of 4.0 GB, 2.8 GB to go* - then how long it has been going and
how long is left, with the time of day it should finish by: *4 min gone, about 9 minutes left,
done by 6:52 AM*. A run that counts apps rather than bytes says *7 of 20, 13 to go*. The whole
line is on the tooltip, so a narrow window loses the end of it and nothing else.

### While it opens

Both windows take seconds to build - the classic one about three and a half,
Nova about six, most of which is reading its eighteen pages - so a small window
appears about a third of a second in and says where it has got to: *Building
the pages ...*, *Loading the contacts page ...*, *Looking for adb, scrcpy and
gnirehtet ...*. The bar is moved along those steps, not spun, and the window
goes the moment the real one is on screen and laid out.

Starting minimized with Windows shows no splash: there is nothing to wait for.

### What the device box says

Under the device list, two lines about the phone picked:

* **The square** is its make - a letter in the make's own colour, from what the phone says it is
  made by. A make this does not know keeps the plain phone glyph. Hovering it names the make.
* **The first line** is its battery, its network and signal, and whether its screen is on and
  unlocked. It turns orange when the phone is locked or dark, because that explains half of
  what then fails.
* **The second line** is what the phone is doing with itself: **CPU**, **RAM** and **GPU**. Each
  one is coloured by its own number - quiet below 70%, orange from 70, red from 90 - so a phone
  with nothing left is obvious without reading it. Most phones will not let adb read the GPU at
  all, and then it says *not readable* rather than nothing. These are read every six seconds,
  and never while something else is using adb.
* **At the right of that line** is the clipboard: *clipboard off*, or *clipboard on*. Click it
  to open the Clipboard page, right-click it to start or stop sharing with the phones picked.

Nova shows the same things: the make beside the phone's name at the top, and the readings at the
foot of the side bar, with the clipboard as a pill in the header.

### Clipboard

What you copy on the phone and what you copy on this PC, kept together, with a list of
everything that moved. Nova has the same page under *Workspace*.

**Turn it on** with *Start sharing*: every phone selected in the device list is asked which way
it can go, and the line under the buttons says what each one answered.

| What the phone can do | What sharing does |
|---|---|
| Its clipboard service answers (nearly every phone) | Both ways. The phone is asked every second and a half, and anything new on this PC is put onto it |
| Its shell has `cmd clipboard` too | The same, by the shorter road |
| Neither, but scrcpy is here | Only what you copy **on the phone**, and only if scrcpy's own listener fires - on the phone this was written against it never did |
| Nothing at all | It says so rather than sitting quiet |

**Text only.** A picture or a file does not cross, either way. Android does not put the file on
the clipboard: it puts a `content://` link to it, which means nothing on this side of the cable.
When you copy one on the phone the list says what kind it was - *image/png* - rather than going
quiet. For files and pictures, use the file pages, FTP, or the backup page.

**Sending by hand.** *Send this PC's clipboard* puts what is here onto the phone picked in the
list. If a phone will not take a clipboard from adb at all, ticking *Type it when the phone will
not take it* types the text into whatever has the cursor on the phone instead - that is not the
clipboard, and the list says `typed` rather than pretending otherwise. *Take the phone's* reads
the other way.

Very long clipboards are carried too: a few thousand characters become a few thousand words of
command, which goes down adb's own input instead of its command line. Past 64 KB it says so
rather than sending half.

In Nova the header shows **clipboard on** or **clipboard off** beside the FTP indicator: click it
to open this page, right-click it to start or stop sharing with the phones picked.

**The monitor** is the list: the time, the phone, which way it went, how it got there, how many
characters, and the text as one line. Double-click a line, or press *Copy this line*, to put it
back on this PC's clipboard.

> What was copied is kept in the window and nowhere else. The activity log is told the length
> only, because a log can be saved to a file and a clipboard can hold a password. Closing the
> window ends the sharing and the list.

**Why Android makes this awkward.** Since Android 10 only the app in front, or the keyboard,
may read or set the clipboard - for *apps*. The shell that adb gives out is not an app, and the
phone's own clipboard service will answer it: that is the road this takes, asking the service
directly for the clip and handing it a new one.

The catch is **which user you ask about**. A phone in its second space is running as another
user, and Owner's clipboard is both empty and unreadable - which looks exactly like a phone that
refuses. The first version of this page asked about Owner and so never worked on a phone in its
second space; it now asks `am get-current-user` first. If you switch spaces while sharing is on,
stop and start it again.

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

### Backup

A copy of the phone on this PC, and putting one back. Nova has the same page, under *System*.

**What can be in a backup**, each part ticked on its own:

| Part | What it holds |
|---|---|
| Phone files | Everything under `/sdcard` that Android lets adb read: photos, videos, downloads, documents, and `Android/media`, where messaging apps keep pictures |
| Memory card | What is on the card in the phone, if there is one. **Off unless you tick it**: a card can hold more than the phone does. Each card goes into a folder of its own name, so two cards never mix |
| Apps | The APK of every app you installed, splits included |
| Contacts, messages, call log | As the phone has them now |
| Settings and the app list | `settings list`, `getprop`, the installed packages and a device report, as text |

**What cannot, and why.** Android does not let adb read what is *inside* an app - chats, game
saves, an app's own settings - unless the phone is rooted. `adb backup`, the old route, has
returned almost nothing since Android 12, and `Android/data` and `Android/obb` have been closed
to adb since Android 11. No tool without root gets past that.

**Which user.** A phone can have more than one person on it - a second user, a guest, the
clone profile that dual apps run in - and Android keeps each one's files apart. The *Back up*
box says who this phone has and lets you pick:

* **the main user (0)**, which is what a backup has always meant, and what it still does by
  default;
* **one of the others**, on its own;
* **every user**.

A user whose files Android keeps shut is still offered, marked *(no files to read)*, because
their app list, settings and contacts can be read even when their storage cannot; the line
beside the box names them. Measured on a phone with three users, where the owner's files and
the clone profile's could be read and a stopped guest's could not, while all three answered
about their apps. The owner's things go exactly where
they always went (`files\`, `personal\`, `settings\`), so every backup taken before this still
opens and restores unchanged; anyone else's go into `users\<id>\` beside them, and *What is
inside* says *Files (user 999)* against each of their files. Putting them back sends each
user's files to that same user, and says how many were left out if that user is not on the
phone any more.

Two things are the phone's rather than a user's, and are taken once however many users you ask
for: **messages and the call log**. Their providers are declared `singleUser`, so Android shows
every user the same ones - measured: user 0 and user 10 both answered with the same 8440 rows.
**Contacts** are per user and are taken per user; a user that is not running cannot answer for
them, and the log says so rather than writing an empty file and calling it done.

**Giving it a name.** The *Call it* box names the backup - *before the update*, *holiday
photos*. The name goes into the file's name and into the backup itself, so the list shows it
even if the file is renamed later. Leave it empty and the phone and the time are name enough.

**Packing, or not.** *Pack into one .zip* is on by default: one file is tidier to keep and to
move. It costs a second pass over everything - measured at about 40% on top of the time the
pull takes - so turning it off is the quickest way to a faster backup. A backup left as a
folder opens, restores and is read exactly the same way, and it can be **brought up to date**
later instead of taken again.

**Taking one.** Tick the parts, press *Back up now ...*, pick a folder. Each backup is **one
`.zip` file** named after the phone and the time, with a `manifest.json` inside it saying what
it holds - one file to copy, to move, or to put on another drive. The files are pulled into a
folder of that same name first, because that is what adb writes; the folder is packed and then
removed. Photos, video and APKs go in as they are rather than being squeezed again, which is
why the packed size is close to the size on the phone.

**Bringing one up to date.** A backup kept as a folder can be refreshed instead of taken
again: pick it in *My backups* and press **Continue / update**. The phone is asked what it
holds and how big each file is, the folder is read for what is already there, and only what is
new or changed comes over. On a phone whose photos have not moved much, that is minutes instead
of an hour.

**If it stops part way.** A backup that is cancelled, or whose phone is unplugged, keeps
everything it already pulled as a folder, and *My backups* marks it **stopped part way**. Pick
that line and press **Continue / update**: the phone is asked what it holds, the folder is read
for what came over, and only the difference is fetched - a file that was cut off halfway is
fetched again, one that arrived whole is left alone. Then it is packed like any other backup.

It needs nothing that was remembered at the time, so it works after closing and reopening the
program, or days later; it only asks that the same phone is the one plugged in, so two phones
never end up in one backup.

**How fast it can be.** Measured on a Redmi 13C over its own cable: one large file came over
at 26 MB/s, a folder of mixed sizes at 14 MB/s. That is the phone's USB 2.0 link, and no
setting here beats it - 30 GB will take around half an hour whatever this program does. What
*can* be saved: the packing pass (about 40% on top), and, on a second backup of the same phone,
everything that has not changed - see *Bringing one up to date* above.

**How long it will take.** Before the files are pulled, each folder on the phone is measured
(`du`), so the line beside the bar can say what is left: *Files: DCIM  -  about 17 minutes left,
done by 15:16*. It is the plainest guess there is - what has been done, divided by how long it
took - so it settles down as it goes and moves when the phone does. The same line appears while
a backup is packed, while one is put back, and while a stopped one is carried on; restoring
knows every file's size from the backup itself, so there is nothing to measure first.

**While it runs.** The bar beside the button fills as each folder is pulled and again as the
backup is packed, and the line above it names what is being copied and how much of it is done.
**Cancel** stops the run where it is: adb is stopped mid-file, and everything already copied
stays. A backup that was stopped is marked *not complete* in its `manifest.json`, and says so
when you open it later. Cancelling while it packs leaves no half-written `.zip` behind - the
pulled folder is kept instead, and opens exactly like a `.zip` does.

**When something goes wrong.** If the phone is unplugged, or adb loses it, the run ends there
instead of failing file after file, and the log says why. Whatever ends the run - finished,
cancelled, or the phone gone - a notification appears by the clock and the log gives the count.

**The backups you have.** *My backups* has a box at the top saying which folder it is looking
in, and a *Browse ...* beside it. It starts at the folder your last backup went to; point it
anywhere - an external drive, a folder of backups from another PC - by typing a path and
pressing Enter, or with *Browse ...*. Both windows follow the same folder, which is remembered
in `%APPDATA%\AndroidDC\backups.json`.

The list under it is what is in that folder at this moment, newest first: when, which phone,
what it holds, how big it is and the file's name. Backups kept as folders - older ones, and
ones whose packing was cancelled - are listed beside the `.zip` files. Nothing is remembered
about them, so a backup moved into that folder appears and one taken out of it is simply gone.

* Double-click a line, or press *Open this one*, to open it.
* **Right-click a line** for the rest of what can be done to that backup:
  * *Show in Explorer* opens the folder with it picked out.
  * *Continue / update* carries it on, or brings it up to date.
  * **Delete ...** removes it from this PC, after asking. There is no undoing it, and the phone
    is not touched. Only something that really is a backup can be deleted this way - a folder
    with no `manifest.json` in it is left alone.
* *Refresh* reads the folder again.

While a backup or a restore is running, that menu is greyed, the same as the buttons are.

**Looking inside one.** *What is inside* lists every file in the opened backup - which part it
belongs to, where it was on the phone, and how big it is - read from the zip's own index, so
nothing is unpacked to show it. The *Find* box narrows the list to the paths holding what you
type. Pick some lines and *Save a copy ...* writes those files out into a folder on this PC:
one photo out of a backup, with no phone in it at all. A backup with tens of thousands of files
lists the first 3000; the find box reaches the rest.

**Opening is quick, whatever is in it.** Opening a backup reads its manifest and stops there,
so the box says whose phone it was at once even for a backup of forty thousand photos. The two
lists under it - *What is inside* and *Apps to install* - read the backup itself, and only when
you look at them; while that happens the bar beside *Back up now* rolls and says how far it has
got.

**Putting one back.** Press *Open a backup ...* and pick the `.zip` file, or open one from the
list. The box then says whose phone it was, when it was taken and what it holds. Nothing is
unpacked whole: each file is taken out of the zip, sent, and dropped again.

* **Restore files** sends them back. When the phone already has some of them it asks first:
  write over them, send only the rest, or stop. Afterwards the gallery is told to look again.
* **Install ticked apps** works on the *Apps to install* tab. That list says, for every app in
  the backup: what it is called, its package, which version the backup holds, how big it is, and
  how it stands against the phone in front of you -

  | It says | What it means | What to do |
  |---|---|---|
  | not on the phone | the backup has it, this phone does not | it is ticked for you; press *Install ticked apps* |
  | on the phone | the same version is there already | nothing |
  | older on the phone | the phone has an earlier version | tick it to bring the phone up to the backup's version |
  | newer on the phone | the phone has moved past the backup | Android refuses to put an older version over a newer one; remove the app on the phone first if you really want the backup's |
  | no phone to compare | no phone is picked | pick one in the device list and the answers appear |

  The apps the phone lacks come first, and the line under the list counts them. The *Find* box
  narrows the list by name or package, and the ticks stay while you look; *Tick all* and *Tick
  none* act on what is shown. Each app is installed in one call, splits included. A phone that
  refuses installs over USB says so in the log - on Xiaomi, Redmi and POCO turn on *Install via
  USB*.

  An app's name comes from the backup itself: it is written down while the phone still has the
  app, so a backup read a year later says *WhatsApp*, not `com.whatsapp`, even for an app that
  phone no longer has. Backups taken before this hold no names, and show packages.
* **Restore contacts** adds the contacts the phone does not have, matched by name and number,
  so running it twice adds nothing twice. Messages and the call log are not put back: Android
  has no way for adb to write them.
* **Show the open one** opens the folder with the backup that is open picked out - the one you
  opened, not whichever line is highlighted in the list. For that one, right-click the line.

Nothing is written to the phone until you press one of those buttons.

### Automation

Two things that happen without a click. Nova has the same page, under *System*, and the two
windows share both.

**Start with Windows.** Tick *Start minimized when I sign in* and pick the classic window or
Nova. That writes one value, `AndroidDC`, under your own Run key
(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`): the launcher with `-Minimized`. Untick
it and that value is removed; nothing else there is touched.

**When a phone is plugged in.** Select the phone in the device list and press *Add the selected
phone*. Then tick what should happen each time that phone is plugged in:

| Group | Actions |
|---|---|
| Screen | wake the screen, mirror it (with the Mirroring page's options), back or front camera, the phone's sound on the PC, a screenshot to Pictures |
| Internet | share the phone's internet with the PC (USB tethering on) or turn it off, share the PC's internet with the phone (gnirehtet), the adb proxy, the Wi-Fi hotspot on or off, adb over Wi-Fi |
| Radios | Wi-Fi, Bluetooth, NFC - on or off |
| Settings | stay awake while charging, auto-rotate, location, battery saver - on or off |
| Other | open an app (type its package name, e.g. `com.whatsapp`), vibrate, start logcat, a Windows notification |

* The ticks are saved at once to `%APPDATA%\AndroidDC\automation.json`.
* The actions run one after another, in the order of the list, on that phone alone. The other
  phones stay as they were, and so does *All devices*.
* *Wake the screen* comes first on purpose. Many phones refuse to switch USB tethering or the
  hotspot from adb, and AndroidDC then taps the switch in the phone's settings. That needs the
  screen on and the phone unlocked.
* A failing action is logged, and the ones after it still run.
* *This rule is on* pauses a rule without losing its ticks. *Run now* runs it straight away, to
  try it. *Remove* deletes the rule; the phone itself is not touched.
* A rule runs when its phone becomes ready: plugged in, or its RSA prompt accepted. A window
  that was started with Windows also runs the rules for phones already plugged in. A window you
  open yourself does not, and neither does the one the other window's switch button opens.
* Only one window runs the rules, the first one open, so a phone is never served twice.
* The device list keeps following the cable while the window is minimized. It stops while one
  of AndroidDC's own questions is waiting.

**Seeing what is set.** The rules you set before are shown in three places, so you do not have
to open this page to find them:

* The log, at startup: how many rules there are and how many are on, each phone with its
  actions, and whether AndroidDC starts with Windows.
* The icon by the clock: *Automation* at the top of its menu lists the same, read fresh each
  time the menu opens. A click on a rule opens this page. Hover over the icon to see how many
  rules are on.
* The page's name carries the number: *Automation (2)*.

**The icon by the clock.** While AndroidDC runs, in either window, its icon sits in the
notification area next to the clock. If Windows tucks it away, it is under the ^ arrow.

* A click on the icon hides the window, and another click brings it back.
* Minimizing the window hides it there too. It leaves the taskbar, but it keeps watching for
  phones and running their rules.
* Right-click the icon for *Show the window*, *Hide to the tray* and *Exit*. *Exit* closes the
  program the normal way, so its settings are saved.
* A window started with Windows opens hidden there. The first time a window hides, a
  notification says AndroidDC is still running.
* The window's close button still quits the program.

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

# Phone FTP and filesystem access

Open the separate **FTP** page in Classic or Nova. The default username is `pc`
and the default password is `123`; you can edit either one, choose **Generate new login** for a new
pair, and change the port before choosing **Start server**. The default port is
2121. As soon as a phone is selected, the address box previews its Wi-Fi FTP
address, updated as you type a new port. The first start on a phone installs a
small AndroidDC FTP notification app **on that phone only**. AndroidDC also copies
its Java server to the phone and runs it with `app_process`. Merely connecting a
phone never installs the app. The server shares `/sdcard` and creates the test
file `AndroidDC-FTP/connection-test.txt`.

**Test connection** logs in and requests a passive directory listing.
**Open in Explorer** checks the login and opens the FTP address with the generated
or edited credentials in Windows File Explorer. **Copy address** copies the plain
address. The server requires the displayed username and password. FTP traffic,
including the credentials and file contents, is not encrypted: use a trusted
local network. Phone and PC must be mutually reachable. Closing AndroidDC
does not stop the phone server. When you reopen AndroidDC, it detects a server
still running on the selected phone. Nova shows **FTP running** or **FTP off**
in the header: click that indicator to open the FTP page, or right-click it
to confirm starting or stopping the server.
The AndroidDC icon beside the Windows clock has an **FTP** menu showing the
selected phone's status. From there you can open the FTP page or confirm
starting or stopping the server.
The login is restored on the same Windows account. On another PC, AndroidDC can
detect and stop the server but cannot recover its password.

Choose **Stop server** in AndroidDC, or expand the AndroidDC FTP notification on
the phone and tap **Stop FTP**. Either action stops sharing; the phone app remains
installed for the next use. **Uninstall FTP phone app** first stops sharing, then
removes that app and AndroidDC's temporary FTP files. It does not delete your
own files uploaded to the phone. If the phone refuses installation, enable its
USB installation option in Developer options and approve the phone's prompt.

In a source checkout, the generated server and notification APK are not committed.
The first start needs a JDK and Android SDK platform 35/build tools on the PC,
unless those generated files were packaged with the copy you received.

The Files page starts at `/sdcard`, which is shared internal storage, not
necessarily a removable SD card. The quick-path list also includes `/` (the
filesystem root), `/storage`, `/system`, `/data` and `/sdcard/Android/data`.
Readable entries remain visible when Android denies access to other entries.
Directory links can be opened by double-click. Protected app data remains subject
to Android permissions; neither choosing `/` nor running the FTP server grants root.
