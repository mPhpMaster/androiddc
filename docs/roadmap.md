# Plan: the icon-first rebuild

[← back to the README](../README.md)

Five phases. Each one ends with the window running and audited, so work can stop between
phases without leaving the tool half rebuilt.

---

## Phase 0 — the right-click bug

**Symptom.** Right-clicking a device and choosing *Mirror with scrcpy* does nothing unless the
*Device* tab is the one on screen. The same is true of every context menu entry whose button
lives on another tab.

**Cause, measured.** `Add-ListContextMenu` calls `PerformClick()` on the button the entry
mirrors. `Button.PerformClick()` checks `CanSelect` first, and a control on a tab that is not
selected is not created, so the call is silently dropped:

```
PerformClick on a hidden tab fired : 0
OnClick by reflection fired        : 1
```

**Fix.** Raise the button's `Click` event directly instead:

```powershell
$method = [System.Windows.Forms.Control].GetMethod('OnClick', 'Instance,NonPublic')
$box = [object[]]::new(1)
$box[0] = [System.EventArgs]::Empty
$null = $method.Invoke($button, $box)
```

One change inside `Add-ListContextMenu`, and all nine menus are fixed at once.

**Done when** every entry of every menu works with a different tab in front, checked by a test
that walks the menus from the *Shell* tab.

*Size: small. Risk: none — it only widens what already works.*

---

## Phase 1 — icons instead of words, right mouse button first

The window has grown to fourteen tabs and roughly a hundred buttons. The captions are what
make it feel crowded, not the number of features.

### Icons

Windows ships **Segoe Fluent Icons** (Windows 11) and **Segoe MDL2 Assets** (Windows 10) —
both are present on this machine, so there is no font to install and no image files to ship.

| Rule | Why |
|---|---|
| Secondary actions become a glyph in a 32×28 button | Refresh, copy, export, open, delete … reads faster as a symbol |
| The one primary action per tab keeps its words | *Start sharing*, *Launch scrcpy*, *Send* — the thing you came for stays obvious |
| Destructive actions keep a word next to the glyph | Delete, Uninstall, Remove user — no one should erase by pattern-matching a picture |
| Every icon keeps its tooltip | The tooltip becomes the label, so nothing is lost |
| A glyph is verified at startup | If the font cannot draw it, that button falls back to text automatically |

Draft set (checked against both fonts before use):
⟳ refresh · ⬇ download · ⬆ upload · 🗑 delete · ✎ rename · 🔍 search · 📁 new folder ·
▶ launch · ⏹ stop · ⧉ copy · ⤓ export · ⚙ settings · ⏻ power · 🔗 connect · ✂ compress ·
👁 preview · ☰ menu

### Right mouse button first

Every list already carries a menu built from its buttons. Phase 1 turns that from a duplicate
into the main route:

* the menus gain the entries that only exist as buttons today;
* the phone picture gets its own menu (Back, Home, Recents, Power, screenshot, save, clear);
* each tab keeps a `☰` button that opens the same menu, for anyone who never right-clicks;
* rows of eight or ten buttons shrink to three or four.

### Layout

`Update-RightLayout` and friends stay the only place that positions anything. Button widths
drop from measured-text to a fixed 32 px for glyph buttons, which removes the width juggling
the file row needs today.

**Done when** every tab fits without crowding at the minimum window size, the layout audit
still reports zero overlaps and zero controls off the page, and every icon button has a
tooltip.

*Size: large. Risk: medium — this touches every tab, so it lands tab by tab, each verified
before the next.*

---

## Phase 2 — the features worth having

All nine, each in the place it belongs.

| # | Feature | Where it goes | What it adds |
|---|---|---|---|
| 1 | **Wireless pairing** — `adb pair HOST:PORT CODE`, `adb mdns services` | *Advanced ▸ Device tools*, Connection group | Pairing with no cable at all (Android 11+). Today the Wi-Fi route needs USB first. A small dialog takes the host, port and six-digit code the phone shows; *Find devices* lists what mDNS advertises |
| 2 | **Live logcat** — `adb logcat` | *Shell* tab becomes two inner pages: **Shell** and **Logcat** | Streaming log with a text filter, a level picker (V/D/I/W/E/F), pause, clear and save. Today only the last 40 lines are read, once |
| 3 | **Split APK install** — `install-multiple`, `install-multi-package` | *Apps* tab, the existing Install button | `.apks`, `.xapk` and `.apkm` are zip files holding several APKs; the current button fails on them. The new one unpacks and installs the set |
| 4 | **Audio options** — `--audio-codec`, `--audio-bit-rate`, `--audio-encoder`, `--audio-dup`, `--no-audio-playback` | *Cam / Mic*, inside the Microphone group | Codec and bit rate for Listen and Record, *play on the phone as well* (`--audio-dup`), and *record without playing* |
| 5 | **Recording controls** — `--record-format`, `--record-orientation`, `--time-limit` | *Advanced ▸ Mirroring*, next to Record | Choose mp4/mkv/opus/flac, rotate the recording, and stop by itself after N seconds |
| 6 | **Orientation** — `--orientation`, `--capture-orientation`, `--display-orientation` | *Advanced ▸ Mirroring* | Rotate the mirror on the PC without touching the phone |
| 7 | **Virtual display polish** — `--display-ime-policy`, `--no-vd-system-decorations`, `--no-vd-destroy-content` | *Advanced ▸ Mirroring*, with the new-display size | Fixes the keyboard appearing on the wrong screen when an app runs in its own window |
| 8 | **Real lists from the phone** — `--list-encoders`, `--list-camera-sizes`, `--list-apps` | Refresh glyph beside each dropdown it fills | The codec, camera size and app pickers stop being fixed lists and show what this device actually supports |
| 9 | **Bug report** — `adb bugreport` | *Advanced ▸ Device tools*, Device group | One click, a save dialog, a progress bar and a cancel — it takes minutes, so it reuses the transfer row built for downloads |

**Done when** each one has been run against a real device and the log shows what the device
answered, not an assumption.

*Size: large. Risk: low — these are additions, not rewrites.*

---

## Phase 3 — the smaller wins

| Feature | Where |
|---|---|
| `--camera-zoom` | *Cam / Mic*, with the camera options |
| `--window-x/-y/--window-width/--window-height` | *Advanced ▸ Mirroring*, a "window position" row |
| `--screen-off-timeout` | *Advanced ▸ Mirroring*, next to *screen off* |
| `--print-fps` | *Advanced ▸ Mirroring*, a diagnostics checkbox |
| `--shortcut-mod`, `--mouse-bind` | *Advanced ▸ Mirroring*, an "input" row |
| `--prefer-text`, `--raw-key-events`, `--no-key-repeat`, `--legacy-paste` | the same row, behind a *more* toggle |
| `--kill-adb-on-close`, `--no-cleanup`, `--pause-on-exit` | *Advanced ▸ Mirroring*, lifecycle checkboxes |
| `adb reconnect` | *Advanced ▸ Device tools*, Connection — the usual cure for a device stuck `offline` |
| `adb wait-for-device` | used internally after *Reboot*, so the next action does not fail |
| gnirehtet `autostart`, `restart` | *Tethering ▸ PC → Phone*, beside Start |

*Size: medium. Risk: low.*

---

## Phase 4 — the ones that cannot work here, shown anyway

You asked for these to be visible rather than hidden, and marked. They get their own inner
page: **Advanced ▸ Root / recovery**.

Every control on that page is:

* **greyed out** and captioned with a 🚫 marker;
* **explained** by its tooltip — why it cannot run, and what it would need;
* **checked at run time** — the page reads `ro.build.type`, `ro.debuggable` and
  `service.adb.root` when a device is selected and marks each row ✔ *available on this device*
  or ✖ *not available*, instead of guessing;
* **unlockable** by a single checkbox, *"I understand — let me try anyway"*, which enables the
  buttons for someone on a rooted or userdebug build.

| Control | Marked | Why |
|---|---|---|
| `adb root` / `unroot` | 🚫 | Only on `userdebug` or `eng` builds |
| `adb remount` | 🚫 | Needs root and a writable system |
| `adb disable-verity` / `enable-verity` | 🚫 | Needs root; changes verified boot |
| `adb sideload` | 🚫 | The phone must be in recovery, not in Android |
| `adb emu` | 🚫 | Emulator console only |
| `adb jdwp`, `keygen`, `attach`, `detach`, `get-devpath` | 🚫 | Developer plumbing with no use here |
| `scrcpy --v4l2-sink`, `--v4l2-buffer` | 🚫 | Linux only — not built into the Windows scrcpy |

Nothing on the page runs unless it is unlocked, and each one still reports honestly if the
device refuses it.

*Size: medium. Risk: low, as long as the guard rails hold — the page is verified with the
checkbox both off and on.*

---

## Phase 5 — documentation and checks

* `docs/user-guide.md` — the new tabs, pages and the icon legend.
* `docs/shortcuts.md` — a table of every glyph and what it means.
* `docs/what-it-runs.md` — the commands added in phases 2 to 4.
* `docs/limits.md` — a section on root and recovery.
* `README.md` — refreshed feature table.

Two audits run after every phase, as they do now:

1. **Layout** — for each page, no two controls intersect and none falls outside the page, at
   both the default and the minimum window size.
2. **Wiring** — every button has a handler, every handler has a control, and every context
   menu entry fires with another tab in front (the Phase 0 regression).

---

## Order and size

| Phase | Size | Depends on |
|---|---|---|
| 0 — right-click fix | small | — |
| 1 — icons and menus | large | 0 |
| 2 — features worth having | large | 1 for placement |
| 3 — smaller wins | medium | 1 |
| 4 — shown but blocked | medium | 1 |
| 5 — docs and checks | medium | all |

Phase 0 can land immediately and on its own. Phase 1 decides where everything sits, so 2, 3
and 4 follow it rather than fighting it.

## Two decisions before Phase 1

1. **How far do the icons go?** The draft above keeps words on the primary action of each tab
   and on destructive actions. The alternative is icon-only everywhere, which is tidier and
   less forgiving.
2. **Which font?** Segoe Fluent Icons is the Windows 11 set and looks right on this machine;
   Segoe MDL2 Assets is the same idea and also works on Windows 10. Picking MDL2 costs a
   little sharpness on Windows 11 and buys compatibility with older machines.
