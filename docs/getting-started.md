# Getting started

[← back to the README](../README.md)

## 1. Prepare the phone

1. Open **Settings → About phone** and tap **Build number** seven times. The phone says you
   are now a developer.
2. Open **Settings → System → Developer options** and turn on **USB debugging**.
3. Plug the phone into the PC with a cable that carries data (a charge-only cable will not
   show the device).
4. The phone shows *Allow USB debugging?* — tick **Always allow from this computer** and
   accept. If the prompt never appears, unlock the screen and replug.

Some manufacturers hide extra switches behind the same screen. On Xiaomi/Redmi you also need
**USB debugging (Security settings)** for anything that taps the screen, and MIUI asks you to
sign in before it lets you turn it on. On Vivo and Oppo the switch is called **USB debugging**
inside **Additional settings → Developer options**.

## 2. Get the program

```powershell
git clone https://github.com/<you>/androiddc.git
cd androiddc
.\get-upstream.ps1
```

`get-upstream.ps1` downloads two packages from their official GitHub releases, checks each
archive against SHA256 and unpacks it into the folder:

| Package | Files it brings |
|---|---|
| scrcpy (win64) | `scrcpy.exe`, `scrcpy-server`, `adb.exe`, SDL and FFmpeg DLLs |
| gnirehtet (rust, win64) | `gnirehtet.exe`, `gnirehtet.apk` |

They are not committed to the repository: they belong to their own projects, they are ~28 MB,
and a fresh copy is one command away. See [Command line](command-line.md) for every switch.

If you skip this step, AndroidDC notices at startup, asks once per missing package whether it
should download it, waits for the download to finish and then opens.

## 3. Start it

There are two windows over the same tool; start whichever you prefer:

* **`androiddc.vbs`** - the classic window, with tabs.
* **`androiddc-nova.vbs`** - the Nova window, with a side navigation and cards
  ([its README](../nova/README.md)).

Either launcher runs its PowerShell script with `-NoProfile -ExecutionPolicy Bypass
-WindowStyle Hidden`, so no console window appears and your execution policy is left alone.
To change your mind later, **Open Nova window** on the classic *Device* tab, or **Classic
window** at the bottom of Nova's side navigation, closes one and opens the other.

To see a script's own output while developing, run it directly instead:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\androiddc.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\nova\androiddc-nova.ps1
```

## 4. First run

1. The **Devices** list at the top fills by itself. Every connected device shows its serial,
   link (usb or tcp), model, Android version, state and whether an adb client is attached.
2. Click a device. The status line under the list reads its battery percentage and signal.
3. Press **Load details + screenshot** on the *Device* tab, or double-click the device row.
4. The picture of the phone appears in the left pane. **Click it to tap** the phone, drag to
   swipe, right-click for Back — see [Shortcuts](shortcuts.md).

Select several devices with Ctrl+click or Shift+click; most actions then apply to all of them.

## 5. Connect over Wi-Fi instead of a cable

1. Keep the cable plugged in for a moment.
2. Go to **Advanced → Device tools** and press **adb tcpip 5555**.
3. Read the phone's IP from **Device** details (or Settings → About → Status).
4. Type `<ip>:5555` in the connect box and press **Connect**.
5. Unplug the cable. The device stays in the list with link `tcp`.

Wi-Fi mirroring is slower than USB and the picture may stutter on a busy network. Everything
else behaves the same.

## Where things are kept

| What | Where |
|---|---|
| Your settings | `%APPDATA%\AndroidDC\settings.json` (classic) and `nova-settings.json` (Nova) |
| Temporary captures, recordings, previews | `%TEMP%\androiddc-<pid>.*`, removed when the program closes |
| Downloaded archives | `%TEMP%\upstream-downloads`, removed unless `-KeepArchives` |

Nothing is written to the phone unless you ask for it.
