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
| `@(@($a, $b), @($c, $d))` | Flattened into four elements, so a list of groups stops being groups | `@( ,@($a, $b), ,@($c, $d) )` |
| `-Parent $x, (New-Thing)` | The comma binds first, so `-Parent` receives an array | Parenthesise each call |
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
entries fire those buttons, so a menu can never drift from the buttons it mirrors. `$null`
inserts a separator, and `Opening` copies each button's `Enabled` state.

The entries raise `Click` directly through reflection rather than calling `PerformClick()`:

```powershell
$method = [System.Windows.Forms.Control].GetMethod('OnClick', 'Instance,NonPublic')
$box = [object[]]::new(1)
$box[0] = [System.EventArgs]::Empty
$null = $method.Invoke($button, $box)
```

`PerformClick()` checks `CanSelect` first, and a control on a tab that is not on screen has
not been created, so the call is dropped in silence. That is why right-clicking a device and
choosing *Mirror with scrcpy* used to do nothing unless the Device tab happened to be open.

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

* **Layout:** walk **every group box**, not only every page, and compare `Bounds.IntersectsWith`
  between children and against `ClientSize`. The target is zero overlaps and zero controls
  outside their box.
* **Wiring:** compare the set of `$x.Add_Click(` handlers against the set of created controls.
  A patch that deletes code can silently take handlers with it; buttons then do nothing and
  the log stays empty.

### Three ways a layout audit lies to you

All three have already hidden a real defect in this project, so they are worth knowing:

**Do not filter on `Visible`.** A control on a tab that has never been shown reports
`Visible = $false`, so an audit that skips invisible controls silently skips most of the
window and reports a confident zero. A three-way overlap in the camera group survived several
"zero overlaps" runs that way. Measure `Bounds` on every child; bounds are correct whether or
not the control has been painted.

**Check inside the boxes, not just the pages.** Controls that overlap each other *inside* a
group box are all still within the page, so a page-level check finds nothing wrong. The camera
overlap was three controls stacked at the same point, entirely inside one group.

**A deliberate shared slot looks exactly like a bug.** Some controls are *meant* to sit on
the same spot, with one visible at a time — the file tab's space line and the transfer row
(`$lblFileSpace` against `$prgFile`, `$lblFileProgress`, `$btnFileCancel`) are one row that
swaps contents while a transfer runs. An audit cannot tell that from a mistake, and it must
not try to guess from `Visible`: that guess is the first lie on this list. Name them instead:

```powershell
$sharedSlots = @(
    ,@($lblFileSpace, $prgFile, $lblFileProgress, $btnFileCancel)
)
```

The leading comma is not a typo. `@(@($a, $b, $c))` is flattened by PowerShell into four
separate elements, and the exception then silently stops matching anything; `,@(...)` keeps
the inner array whole.

The pattern that does work: select every tab and inner tab once so each layout function has
run, then recurse the whole form for containers — `TabPage`, `GroupBox`, `Panel`,
`SplitterPanel` — and compare every child against every sibling. Skip children with
`Dock -ne 'None'`, since filling the parent is legitimate, and let a page with `AutoScroll`
be taller than its viewport. Roughly fifty containers, and a named list of the slots that are
shared on purpose.

**Place a control even while it is hidden.** A control that is positioned only in the branch
that shows it keeps its creation coordinates the rest of the time, which may be on top of
something else. It is invisible, so nobody sees it — but the bounds are real and the next
audit trips over them. Set the bounds every pass; let `Visible` be the only thing that
changes.

`PerformClick()` does nothing on a control whose tab is not selected, so a test that drives a
button on another tab must select that tab first, or raise `OnClick` the way the context menus
do.
