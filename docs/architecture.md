# Architecture

[← back to the README](../README.md)

For anyone changing the code. The classic window is a single PowerShell script with a WinForms
user interface — no build step, no modules, no dependencies beyond what Windows already has.
The Nova window is WPF in PowerShell, one file per page; its own rules are in
[`nova/CONTRACT.md`](../nova/CONTRACT.md).

## What the two windows share

`shared\` holds what both windows dot-source, so it is written once:

| File | What it does |
|---|---|
| `Automation.ps1` | Starting with Windows (one `AndroidDC` value under the user's Run key), the actions a rule can hold, the rules file `%APPDATA%\AndroidDC\automation.json`, telling a phone that was just plugged in from one that was already there, and a named mutex so only one window runs the rules |
| `Tray.ps1` | The icon by the clock: hiding and showing the window, its menu, and the list of rules in that menu |
| `Backup.ps1` | A backup of the phone on this PC — pulling `/sdcard` folder by folder, the APK of each installed app, contacts, messages and the call log, a settings snapshot — and putting one back: which files the phone already has (one `find` per folder, not one per file), installing an app with its splits, adding the contacts it lacks. `adb backup` is not used; Android 12 and newer return almost nothing for it |

Nothing in `shared\` touches a control. An action calls the window's own function by name —
both windows use the same names, `Set-UsbTethering`, `Start-Scrcpy` and the rest — and each
window passes a script block that selects the rule's phone first. The files are written at
once, not when a window closes, because the other window reads them. Tests point
`ANDROIDDC_AUTOMATION_FILE`, `ANDROIDDC_RUN_KEY` and `ANDROIDDC_AUTOMATION_MUTEX` at copies of
their own.

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
| `$rich.SelectedText = ''` on a **read-only RichTextBox** | Ignored in silence: no exception, no change, and a benchmark of it looks wonderfully fast | Clear `ReadOnly`, edit, set it back. A plain `TextBox` does honour it — the two controls differ |
| `Test-MessageBox (a, b, c)` in command syntax | Same precedence trap: one string, not three arguments | Use a method call, or pass named parameters |
| `$null` to a P/Invoke `string` | Marshalled as `""`, so `FindWindow(null, title)` finds nothing | `[NullString]::Value` |
| `$home`, `$input`, `$args` | Reserved; assignment fails | Any other name |
| `adb exec-out cat '<path>'` | `exec-out` passes arguments through verbatim, so the quotes stay in the name | Quote for the Windows parser instead: `"<path>"` |
| `adb shell` with several arguments | Joined with spaces and split again by the device shell: `printf [%s] a 'b c'` prints `[a][b][c]`, and an SMS body kept its first word | Text a person typed goes through `Invoke-DeviceCommand`. A path in a fixed command: `Quote-DeviceArgument`; for redirection send one whole string |
| A `"` inside an argument to a native program (Windows PowerShell 5.1) | Dropped: `'say "hi"'` reaches adb as `'say hi'` | `Invoke-DeviceCommand` sends the line as base64, which neither side parses |
| `Register-ObjectEvent` on a live adb stream (logcat) | Afterwards no asynchronous read completes on any adb process started later — the live shell went silent until restart. Not the volume: the same subscription on 20000 lines from `cmd` leaves reads working | Read the stream in a C# class on .NET's own threads: `LineReader`, like `LiveShell` |
| `$process.StandardInput.WriteLine($text)` | Encoded in the console's input code page; .NET Framework has no `StandardInputEncoding`. On an OEM page Arabic becomes `?`, which the phone's shell expands as a file pattern | Write `[Text.Encoding]::UTF8.GetBytes($text + "`n")` to `StandardInput.BaseStream` |
| `Form.CanFocus` in a window started from a hidden process (both launchers start one) | False, because `IsWindowVisible` is false there although the window is on screen — the device watch that waited for it never ran | Ask the one thing that matters: `IsWindowEnabled`, which a dialog or message box turns off |
| `$form.Hide()` / `$window.Hide()` on a window inside `ShowDialog` | Ends the dialog, so the program quits instead of going to the tray | `ShowWindow(handle, SW_HIDE)` and `SW_RESTORE` / `SW_SHOW` (`shared\Tray.ps1`) |
| `$list \| ConvertTo-Json` with one rule in the list | The pipe unrolls a one-item array, and the file holds an object where a list was meant | `ConvertTo-Json -InputObject $object -Depth 6` |
| Cutting a folder prefix off `$file.FullName` when the two came from different calls | `%TEMP%` is handed out in its 8.3 form (`LONGNA~1`) and `Resolve-Path` answers the long one (`LongNameHere`); the lengths differ, so every relative path lost its first letters — `files\Pictures\a.jpg` became `iles/Pictures/a.jpg`, and a restore would have written that | Take one spelling for both: `$root = (Get-Item ...).FullName`, then walk **that** and cut **that** |
| `New-Item -Path <registry key> -Force` on a key that exists | Recreates the key, and every value under it goes — the user's whole Run key | Create a key only after `Test-Path` says it is not there |
| `$lblDns = New-Object ...Label` a second time | The name now means the new control only. The first still exists and shows, but nothing can place or wire it by name: the tunnel page's DNS label was never laid out and sat 6 px above its row | One name per control. `audit-wiring.ps1` fails the build on a reused name |

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

There is no unit-test framework here; the program is tested by running it. The tests are in
[`tests/`](../tests/README.md), which lists each one and whether it needs a phone, and
`tests\run.ps1` runs them; Nova's are in `nova\tests\`. This is how the classic harness works,
and why:

1. Copy `androiddc.ps1`, replace the window title with a marker, splice a test script into
   `$form.Add_Shown` with a **literal** `String.Replace` (a regex replacement would expand
   `$_` inside the test into the whole file), and position the window off screen.
2. Point the copy's `$settingsPath` at a scratch file, seeded from the real one. The window
   saves on close, so a test that changes a setting would otherwise write it into your real
   settings.
3. Let the test drive the real controls — `PerformClick()`, or `OnKeyDown` / `OnMouseUp`
   through reflection with a plain `[object[]]` argument array. With two phones attached,
   select the test phone **by serial**, never by its position in the list.
4. Have it write a report file, then read that — and treat a locked file as "still
   writing", not as an error. Letting that throw once killed the harness before it could
   close the window, and left two test windows running.
5. Close the window with `WM_CLOSE`, the message the title-bar X sends. **Never kill it:**
   settings are only written by a normal close, and a killed window also skips everything
   `FormClosing` cleans up.

**Every replacement must match exactly once.** `String.Replace` replaces *every* occurrence
and says nothing. Two anchors in this file are not unique, and the first harness hit both
without anyone noticing:

| Anchor | Also appears in | What the silent second hit did |
|---|---|---|
| `$script:adbPath = Resolve-Tool ...` | the download-if-missing branch | planted the test's path override there too |
| `    Update-DeviceList })` | the gnirehtet *Install client* and *Uninstall client* handlers | spliced the whole test into both buttons, so clicking either one mid-test would have started the test again inside itself |

Count the matches before replacing, and stop if the count is not one.

**Delete the previous report before starting.** A harness that waits for the test's "done"
line finds the one the last run left behind, at once, and closes the window before the new
test has begun. It happened twice in one session: one run printed the old report as though it
were new, the other closed the window halfway through the test.

Two checks worth repeating after any edit:

* **Layout:** walk **every group box**, not only every page, and compare `Bounds.IntersectsWith`
  between children and against `ClientSize` — **at the default size and again at the
  minimum size**. The target is zero overlaps and zero controls outside their box. Measured
  on 2026-09-10 it is met at 1420 × 900, and since 2026-09-11 at 1120 × 700 too; see
  the correction in the [roadmap](roadmap.md). What made the minimum size fit, and what to
  keep doing in a layout function: a row that can run out of its box wraps — `Set-ButtonFlow`
  for buttons, `Set-CheckRow` for check boxes — and the box takes its height from what is in
  it (`Get-ControlsBottom`), moving everything below it down by the difference. A page whose
  content is taller than about 250 px sets `AutoScroll`, since that is all a page gets at the
  smallest window.
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

### Two code pages, and a PC where both were UTF-8

Windows PowerShell 5.1, the host `androiddc.vbs` starts, uses two code pages that are easy to
confuse. This project was caught by both on the same day:

| Code page | What it decides | What it broke | Where |
|---|---|---|---|
| the **ANSI** page | how a `.ps1` **without a BOM** is read | the Arabic word for *Send*, typed into `Find-SendButton` | on a 1252 or 1256 PC the letters became other characters, so an Arabic-UI phone's Send button was never found |
| the **console** output page | how a native program's output is decoded — through `& exe`, and through a .NET `Process` whose stream has no encoding set | every Arabic app or contact name, log line and file name | on an OEM page (437, 720 …) they arrived as box-drawing characters |
| the **console** input page | how text written to a `Process`'s stdin is encoded | what is typed into the live shell | every Arabic letter became `?`, and the phone's shell expanded `????` as a file pattern |

None of it showed on the development PC, because its Windows is set to *Use Unicode UTF-8 for
worldwide language support*, which makes every page 65001. With the pages forced to 437, an
app name came back as `┘å┘ü╪º╪░`, and `echo` plus four Arabic letters sent to `adb shell`
printed `acct apex cust data init proc` — the four-letter names in `/`.

The fixes: `androiddc.ps1` is plain ASCII, and a non-ASCII letter is built from its code
points — `-join [char[]](0x0625, …)`. `Invoke-OffThread` decodes as UTF-8 for the call and
then puts the console page back; every program that goes through it writes UTF-8. Every
`ProcessStartInfo` that reads adb as text sets `StandardOutputEncoding` and
`StandardErrorEncoding` to UTF-8. Stdin cannot be set that way — .NET Framework, which Windows
PowerShell runs on, has no `StandardInputEncoding` — so `LiveShell.Send` writes UTF-8 bytes to
the underlying stream itself.

### What CI checks, and how a check passes on nothing

`.github/workflows/check.yml` runs on every push: every `.ps1` must parse, every `.ps1` must
be plain ASCII or carry a BOM, no variable may be read before it is assigned, every control
must reach the screen, every button must have a handler and no control's name may be reused, both launchers must point at a file
that exists, Nova's own audit must pass (`nova\tests\audit.ps1`: no function defined twice,
well-formed XAML, page-prefixed names), and no absolute developer path may appear in a shipped
file.

The path check was itself the best example of the rule above. It was written as

```powershell
$hits = Select-String -Path .\*.ps1, .\docs\*.md -Pattern '...' -ErrorAction SilentlyContinue
```

and **a run that matched no files at all printed `ok nothing hardcoded` and exited 0** — a
green check that had read nothing looks exactly like a clean tree, and `SilentlyContinue`
hides a broken pattern the same way. It now asserts that every glob matched something,
reports how many files it read, and uses `-ErrorAction Stop`.

`.github/audit-variables.ps1` walks the AST for variables that are read but never assigned,
which is what a half-finished rename leaves behind: `$chkExtraArgs` became `$lblExtraArgs`
and one reference stayed, and under `Set-StrictMode` that is a crash the moment a user clicks
the control. The rule it turns on is easy to get backwards:

```powershell
$x = 1           # assigns $x
$x.Text = 'a'    # READS $x - the property is what gets assigned
$x[0] = 1        # READS $x
```

Counting those last two as assignments makes a typo define itself, and `$btnFileCopyPathh.Text = ...`
passes in silence. The way that was caught was not by reading the code but by planting a
deliberate typo and checking the audit failed — the same discipline as asserting an operation
had an effect before trusting its timing.

`.github/audit-wiring.ps1` checks that every control is added to a container and every button
has a handler. It exists because of the sharpest version of this whole family:

> **A layout audit counts a button that is not on the screen as a perfect button.**

A control that was never added to a parent is invisible, yet the `Update-*Layout` functions go
on positioning it, and the overlap audit dutifully reports that it collides with nothing —
which is true, and meaningless. The tool built to find placement defects issues the orphan a
clean bill of health. The `Visible` filter that hid the camera overlap was not a slip; it was
this same shape.

Two more things that the wiring audit taught, both worth keeping:

**A noisy audit is worse than none.** Its first version raised 23 false alarms on a healthy
tree — it counted helper-function locals like `$button` and `$ok` as window controls, and
flagged every `TabPage` because a tab is added with `TabPages.Add`, not `Controls.Add`. A
report like that trains you to ignore the report.

**A green result proves nothing until the check has been seen to fail.** Two defects were
planted — a button built but never added, and a button added but never wired — and the audit
was required to catch both, at their own lines, and nothing else.

### A step can report the error and still go green

Worth its own paragraph because it is the most deceptive form. A `pwsh` step in GitHub Actions
is run roughly as

```powershell
. 'step.ps1'; if ((Test-Path variable:/LASTEXITCODE)) { exit $LASTEXITCODE }
```

so a script whose success path never sets `$LASTEXITCODE` exits 0. Measured here:

| The step | Result |
|---|---|
| writes `::error` and falls off the end | **exit 0 — green, with the error printed underneath** |
| writes `::error` then `exit 1` | exit 1, red |

Every failing branch must `exit 1` explicitly. A check that finds the defect, announces it,
and then fails to stop anything is worse than no check, because the badge says the tree is
fine.

### Working in a checkout someone else is also using

Two people — or two assistants — editing one 10,000-line script in the same folder will
overwrite each other, because the usual edit is *read the whole file, write the whole file*.
Everything below was learned the hard way in this repository.

**Commit early, and push what is finished.** A commit is the only thing that survives someone
else's full-file write. Work that existed only on disk was nearly lost twice here; work that
was committed never was.

**`--amend` and `reset` assume you own `HEAD`.** They do not ask. An `--amend` meant for your
own last commit will happily rewrite somebody else's if they committed while you were working:
the content stays, but it is filed under your message and their commit falls out of the
history. Check `git log -1` first, and if the tip is not yours, **add a correcting commit
instead of rewriting**. `git reflog` finds the original if you have already done it —
`git reset --soft <their-commit>` puts it back untouched.

**The author field will not tell you whose commit it is.** Both sessions here commit as the
same configured git user, so `%an` is identical on every commit. Judge by the subject and the
files touched, not by the name.

**`git add -A` and `commit -a` take what they find, not what you wrote.** Staging is a snapshot
of the whole tree, so a commit made while someone else has a file half-edited will carry their
work under your message. Name the files instead:

```powershell
git commit -- docs/architecture.md      # only this path, whatever else is staged
```

This project managed both directions of that mistake in one day: an `--amend` that rewrote
someone else's commit, and an `add -A` that swallowed someone else's uncommitted edit. In both
cases the content survived and only the attribution was wrong — which is the argument for
fixing it with a note rather than a rewrite, since rewriting a tip that the other person has
already built on costs more than the wrong label.

**Prefer a branch per worker.** One shared branch turns every concurrent edit into a silent
race; separate branches turn the same disagreement into a merge conflict you can see and
resolve. Falling back to comparing file sizes and timestamps is a sign the coordination has
already failed.

### Measure the effect, not the call

A timing number is only worth having if the operation actually happened. Trimming the logcat
box was first measured at 5 ms against 1722 ms for rebuilding it — a 344x win that was not
real. The box is a `RichTextBox` with `ReadOnly = $true`, and such a control **discards an
assignment to `SelectedText` without raising anything**, so the benchmark was timing a
no-op. The give-away was in the same output all along: the length after the "delete" was
unchanged.

With `ReadOnly` lifted for the edit, the honest figures are:

| What | Cost |
|---|---|
| Trim 744k characters down to 200k by deleting the selection | 43–55 ms |
| The same trim by rebuilding: `$box.Text = $box.Text.Substring(...)` | 1722 ms |
| `$box.Text =` with 250k / 500k / 960k characters | 2541 / 7169 / 22576 ms |

So the win is roughly 31x, not 344x — still the difference between a window that answers and
one that does not: under a heavy log stream the UI heartbeat went from **13/40 to 36/40**, and
the box stopped growing without bound (8,416,985 characters after eleven seconds became a
capped 454,119).

Two habits follow from that:

* after timing an operation, assert that it changed what it claims to change;
* find a cut point with `GetFirstCharIndexFromLine`, never by reading `.Text` and searching it
  — reading `.Text` copies the whole box and throws away the saving you came for.
