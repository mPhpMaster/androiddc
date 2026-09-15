# AndroidDC Nova

AndroidDC in the friendly-interface design, as a Windows desktop application. The same tool as
`androiddc.ps1` - mirroring, internet sharing in both directions, apps, contacts and messages,
camera and microphone, files, running processes, radios, users and the shell - behind a side
navigation, a device card and an activity log instead of fourteen tabs.

It is a WPF application hosted in Windows PowerShell 5.1: nothing to install, nothing to build.

[< back to the project README](../README.md)

## Start it

1. Turn on **USB debugging** on the phone and plug it in.
2. Double-click **`androiddc-nova.vbs`** in the project folder (one level up from this one).

Both windows are the same tool and share the project folder's adb, scrcpy and gnirehtet.
`androiddc.vbs` opens the classic window; **Classic window** at the bottom of the side
navigation closes this one and opens that one, and the classic window's **Open Nova window**
does the reverse. If a tool is missing, the program offers to fetch it with the project's
`get-upstream.ps1` from the official releases.

## The window

* **Side navigation** - the pages, grouped: *Workspace* (Overview, Screen, Mirroring, Apps,
  Files, Camera & mic), *Personal* (Messages, Contacts), *Connect* (Tethering, Radios) and
  *System* (Tools, Running, Users, Shell, Automation). `Ctrl`+`1`...`9` open the first nine.
* **Automation** - start with Windows, minimized, and what a given phone does each time it is
  plugged in. The rules and the start-up entry are the classic window's too
  (`..\shared\Automation.ps1`, `%APPDATA%\AndroidDC\automation.json`); see the user guide's
  *Advanced > Automation*.
* **Device card** - the phone the pages act on, its battery, signal and screen. Click the name
  to pick another, or several with `Ctrl`/`Shift`; a double-click picks one and closes the
  list, on whatever page is open. The list follows the cable by itself.
* The window opens on the page you used last, which is remembered as soon as you open it.
* **Activity log** - every step, colour coded; drag its top edge, or fold it away. Above it, the
  command that is running and the state of the internet sharing.
* `F5` reads the page on screen again. `Ctrl`+`L` empties the log.
* **The icon by the clock** - a click hides the window there or brings it back, and minimizing
  hides it too. Its menu lists the automation rules that are set, and the log lists them at
  startup.

Settings are kept in `%APPDATA%\AndroidDC\nova-settings.json`, apart from the classic
window's `settings.json`, so switching never mixes them.

## The parts

| Path | What it is |
|---|---|
| `androiddc-nova.ps1` | Starts everything: loads the parts, the pages, the tools and the settings |
| `..\androiddc-nova.vbs` | The launcher to double-click, in the project folder |
| `lib\Core.ps1` | adb off the window's thread, quoting for the phone's shell, settings, device state |
| `lib\Ui.ps1` | Pages and navigation, the log, the device card, dialogs, lists, the busy strip, keys |
| `ui\Theme.xaml` | Every colour, font and control style |
| `ui\Shell.xaml` | The window around the pages |
| `pages\` | One page each: `<Page>.ps1` and `<Page>.xaml` |
| `..\shared\Automation.ps1` | Start with Windows and the rules per phone, loaded by both windows |
| `..\shared\Tray.ps1` | The icon by the clock: a click hides or shows the window, minimizing hides it there, the menu has Exit |
| `tests\` | `run.ps1` runs the real program off screen with a test inside; `audit.ps1` checks the files without starting it |
| `CONTRACT.md` | How a page is built, and which page owns what |
| `fonts\` | The design's typefaces from Google Fonts, under the SIL Open Font License (`OFL-*.txt`): DM Sans 400 / 500 / 600 for text, Space Grotesk 500 / 600 / 700 for titles. Without the folder, Segoe UI takes their place |

## Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\audit.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 -Test all
```

With a phone attached, the tests only read from it.
