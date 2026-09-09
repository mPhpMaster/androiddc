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

| Control | What it does |
|---|---|
| The slim strip at the left edge of the right pane | Folds the phone screen away and narrows the window; press again to restore both |
| The splitter | Drag to give the picture more or less room |

Multiple devices: `Ctrl` + click adds one device to the selection, `Shift` + click takes a
range. Most buttons then act on all of them and the log names each device.
