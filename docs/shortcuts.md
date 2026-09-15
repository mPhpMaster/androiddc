# Keyboard and mouse

[← back to the README](../README.md)

## The phone picture

The picture is not a static image: what you do on it is sent to the phone.

| Action | What the phone gets |
|---|---|
| Left click | A tap at that point |
| Drag | A swipe from where you pressed to where you released |
| Press and hold still (> 500 ms) | A long press |
| Right click | Back (`KEYCODE_BACK`) |
| Mouse button 4 (back thumb button) | Recents (`KEYCODE_APP_SWITCH`) |
| Mouse button 5 (forward thumb button) | Pulls down the notification panel |

The coordinates are scaled from the picture to the real screen, so the click lands where you
see it whatever the window size.

## The file list

| Key or button | What it does |
|---|---|
| `Ctrl` + `A` | Select every row (a plain list view does not do this by itself) |
| `Esc` | Clear the selection |
| `Backspace` | Go up one folder |
| `Alt` + `←` | Back to the previous folder |
| `Alt` + `→` | Forward again |
| Mouse button 4 | Back to the previous folder |
| Mouse button 5 | Forward again |
| Double click | Open a folder, or download a file |
| Right click | The same actions as the buttons below the list |
| Click a column header | Sort by it; click again to reverse |

The history keeps the last 100 folders of the session.

## The icons

Buttons whose meaning is carried by a symbol everybody already reads show that symbol instead
of a word, and the tooltip carries the full sentence. Anything without an obvious symbol keeps
its words, and so does every destructive action that is not a plain delete.

| Icon | Means | Icon | Means |
|---|---|---|---|
| ⟳ | refresh this list | 🗑 | delete |
| 🔍 | search here and below | ✎ | rename or edit |
| ⬇ | download to the PC | ⬆ | upload to the phone |
| ▶ | launch | ⚙ | open that screen on the phone |
| 📷 | screenshot | 💾 | save |
| 📁 | new folder | ⧉ | copy |
| 👁 | preview without saving | ✕ | clear or cancel |
| ＋ | add | − | remove |
| ☎ | call the number in the box | ⏻ | power |
| ↑ | up one folder | ← | back |
| ⌂ | home | ⧉ | recent apps |
| 🔊 / 🔉 | volume up and down | 🗜 | compress |
| 📤 | extract | 🖥 / 📱 | move to the PC, move to the phone |
| ⛔ | this device cannot do it | ✔ | this device can |

The icon font is the one Windows already ships (Segoe Fluent Icons, or Segoe MDL2 Assets on
Windows 10). If a glyph cannot be drawn, that button quietly keeps its words.

## Every list

Right-clicking any list — devices, apps, contacts, SMS, files, running processes, Wi-Fi,
Bluetooth, users — opens a menu with exactly the actions that list's buttons perform. If a
button is disabled, the menu entry is greyed out with it. Right-clicking a row that is not
selected picks it first.

## Text boxes

| Where | Key | What it does |
|---|---|---|
| Path box (Files) | `Enter` | Go to that folder |
| Search box (Files) | `Enter` | Search this folder and everything under it |
| Filter box (Running) | `Enter` | Refresh with that filter |
| Number box (Device) | `Enter` | Call the number |
| Shell box | `Enter` | Send the command |
| Send text (screen pane) | — | Types the text on the phone, Arabic included |

## The window

| Key | What it does, wherever the focus is |
|---|---|
| `F5` | Reads the page on screen again: the app, contact, SMS, file, process, Wi-Fi, Bluetooth, NFC or user list, the Device details, the DNS line or the root checks. On a page with nothing of its own to read, the device list. Ignored while a call is still running |
| `Ctrl` + `1` … `9` | Opens the tab in that place: 1 Device, 2 Tethering, 3 Advanced, 4 Apps, 5 Contacts, 6 SMS, 7 Cam / Mic, 8 Files, 9 Running |
| `Ctrl` + `L` | Empties the log |

| Control | What it does |
|---|---|
| The slim strip at the left edge of the right pane | Folds the phone screen away and narrows the window; press again to restore both |
| The splitter | Drag to give the picture more or less room |
| The bar above the log's buttons | Drag to give the log more or less room; double-click to fold it |
| ▼ / ▲ beside *Save log...* | Folds the log away, or brings it back |

## The icon by the clock

| Action | What it does |
|---|---|
| Left click | Hides the window, or shows it again |
| Minimize button | Hides the window there too, off the taskbar; it keeps watching for phones |
| Right click | *Automation* (the rules that are set, and *Open the rules ...*), *Show the window* or *Hide to the tray*, *Exit* |
| Hover | How many automation rules are on |

The same in both windows. The window's close button still quits the program.

Multiple devices: `Ctrl` + click adds one device to the selection, `Shift` + click takes a
range. Most buttons then act on all of them and the log names each device.
