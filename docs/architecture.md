# Architecture

[← back to the README](../README.md)

For anyone changing the code. AndroidDC is a single PowerShell script with a WinForms user
interface — no build step, no modules, no dependencies beyond what Windows already has.

## The shape of the file

`androiddc.ps1` runs top to bottom in five stretches:

| Stretch | What lives there |
|---|---|
| Header and helpers | `$scriptRoot`, `Resolve-Tool`, `Install-UpstreamPackage`, the work runspace |
| Controls | Every control, created in tab order with its initial position |
| Functions | One function per action, named `Verb-Noun` |
| Layout | `Update-*Layout`, the only code allowed to move a control |
| Events | `Add_Click` and friends, each a one-liner calling a function |
| Main | Resolve the tools, restore settings, `ShowDialog`, clean up |

Controls are created with a position, but that position is only a starting point: the layout
functions decide where things really sit.

## Four rules

**1. Layout lives in one place.** `Update-RightLayout`, `Update-ScreenLayout`,
`Update-ToolsLayout`, `Update-DeviceTabLayout`, `Update-RadioLayout` and `Update-ShellLayout`
own every coordinate. Never call `SetBounds` from an event handler. Anchors are not used for
tab pages: a page starts small and grows, so anchor deltas overshoot — that is why the layout
functions run on `SelectedIndexChanged` and on resize.

**2. adb never runs on the UI thread.** A screenshot alone costs more than a second, and the
window used to freeze for it. Work goes through:

* `Get-WorkRunspace` — one background runspace, reused;
* `Invoke-OffThread` — runs an executable there and pumps
  `[System.Windows.Forms.Application]::DoEvents()` until it finishes;
* `Wait-Pumped` — the replacement for `Start-Sleep` on the UI thread;
* `$script:busy` — a counter; timers skip a tick while it is above zero.

Anything that shells out must follow that pattern or the window stops redrawing.

**3. Read bytes from stdout, never through a temp file.** `Get-CaptureBytes` and
`Get-DeviceFileBytes` stream `adb exec-out` straight into a `MemoryStream` with
`CopyToAsync`. PowerShell's `Start-Process -RedirectStandardOutput` keeps a lock on the file
it writes, which crashed the program the first time captures were made asynchronous.

**4. Report what the device said.** If Android refuses something, the log says so. No button
claims success it has not verified — the hotspot checks `dumpsys tethering`, a new display
checks scrcpy's own output, a move checks the copy arrived before deleting the original.

## Things PowerShell does that bite here

| Trap | What happens | What to write instead |
|---|---|---|
| `$x = if (...) { $list }` | An `ArrayList` is unrolled into a fixed-size array, and `RemoveAt` throws | Assign in both branches: `if (...) { $x = $list } else { ... }` |
| `return $bytes` | A `byte[]` is unrolled into single bytes | `return ,$bytes` |
| `@('a', '--flag=' + $x)` | The comma binds tighter than `+`, giving four elements | `"--flag=$x"` |
| `Test-MessageBox (a, b, c)` in command syntax | Same precedence trap: one string, not three arguments | Use a method call, or pass named parameters |
| `$null` to a P/Invoke `string` | Marshalled as `""`, so `FindWindow(null, title)` finds nothing | `[NullString]::Value` |
| `$home`, `$input`, `$args` | Reserved; assignment fails | Any other name |
| `adb exec-out cat '<path>'` | `exec-out` passes arguments through verbatim, so the quotes stay in the name | Quote for the Windows parser instead: `"<path>"` |
| `adb shell` with several arguments | Rebuilt and re-parsed by the device shell | `Quote-DevicePath` each path; for redirection send one whole string |

## Event handlers

Handlers receive their arguments positionally, so write them out:

```powershell
$lstFiles.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq 'A') { ... }
})
```

`$_` is not the event argument inside a WinForms handler in PowerShell.

## Context menus

`Add-ListContextMenu -List $lst -Buttons @($btnA, $btnB, $null, $btnC)` builds a menu whose
entries call `PerformClick()` on those buttons, so a menu can never drift from the buttons it
mirrors. `$null` inserts a separator, and `Opening` copies each button's `Enabled` state.

## Settings

`Save-Settings` and `Restore-Settings` write `%APPDATA%\AndroidDC\settings.json`. Add a key by
adding it to the hash table in `Save-Settings` and a matching `Get-Setting` line in
`Restore-Settings`. A file written by an older name is copied over once on first run.

## Testing

There is no unit-test framework here; the program is tested by running it. The pattern used
during development:

1. Copy `androiddc.ps1`, replace the window title with a marker, splice a test script into
   `$form.Add_Shown` with a **literal** `String.Replace` (a regex replacement would expand
   `$_` inside the test into the whole file), and position the window off screen.
2. Let the test drive the real controls — `PerformClick()`, or `OnKeyDown` / `OnMouseUp`
   through reflection with a plain `[object[]]` argument array.
3. Have it write a report file, then read that.

Two checks worth repeating after any edit:

* **Layout:** for every page, compare `Bounds.IntersectsWith` between children and against
  `ClientSize`. The target is zero overlaps and zero controls off the page.
* **Wiring:** compare the set of `$x.Add_Click(` handlers against the set of created controls.
  A patch that deletes code can silently take handlers with it; buttons then do nothing and
  the log stays empty.

`PerformClick()` does nothing on a control whose tab is not selected — select the tab first.
