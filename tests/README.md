# Tests

[← back to the README](../README.md)

AndroidDC has no unit-test framework: it is tested by running it. `run.ps1` makes a copy of
`androiddc.ps1` with a test spliced into the window's start-up, opens it off screen, lets the
test drive the real controls, closes the window normally and reads the report the test wrote.

```powershell
# the ones that need no phone
powershell -File tests\run.ps1 -Test layout,pane-resize,screenshots

# everything, on one phone - the serial from "adb devices"
powershell -File tests\run.ps1 -Test all -Serial <serial>
```

The serial can also come from the `ANDROIDDC_TEST_SERIAL` environment variable. It is never
written into these files. With several phones attached, the tests only ever select that one.

Reports, screenshots and the settings file each test used go to `%TEMP%\androiddc-tests`. The
exit code is the number of tests that failed or did not finish.

| Test | Needs a phone | What it checks |
|---|---|---|
| `layout` | no | Every control inside its box and none on another, on every page, at the default and the smallest window size |
| `pane-resize` | no | The phone-screen pane follows the window at once, shrinking and growing, with no tab touched in between |
| `screenshots` | no | Pictures of the pages at the smallest size, for a person to look at — the layout test cannot see text cut off inside a label |
| `audio` | yes | The encoder list read from the phone and following the codec, the command line, the file name for each codec, a real *Listen*, the choices remembered |
| `apps` | yes | Names read once and kept, read again when the apps change, a non-ASCII name arriving whole, the filter, the export, *Start app* |
| `root` | yes | The Root page reads the phone on opening, its marks belong to one phone, `jdwp` stops by itself, `emu` explains its silence |
| `logcat-shell` | yes | The live shell answers while logcat runs, after it stops, and after a second run |
| `encoding` | yes | adb read and written as UTF-8: logcat, the live shell both ways, a pull, `jdwp` |
| `device-arguments` | yes | Text a person typed - spaces, `'`, `"`, `; & $`, Arabic, a new line - reaches the phone as one argument, unchanged; the old way is shown splitting it |

## What they do to the phone

Nothing that stays. `audio` captures the phone's sound for a few seconds without saving it.
`root` runs `adb root` only on a retail build, where the phone refuses it; on a userdebug or
eng build it would really restart adbd as root, so there it is skipped. `encoding` pulls
`/system/etc/hosts` to the output folder and deletes it. `device-arguments` only runs `printf`
on the phone and reads the newest contact id; nothing is sent, dialled or written.

## Writing one

A test is a PowerShell fragment that runs inside the window, so it can use every control and
function of `androiddc.ps1`. `run.ps1` gives it:

| | |
|---|---|
| `$TestSerial` | the phone under test, or empty |
| `$TestOutput` | the output folder |
| `Say 'text'` | a line in the report |
| `Mark $condition` | `OK`, or `FAIL` — which is what the harness counts |
| `Select-TestPhone` | selects the phone under test and nothing else |

Put `# needs: phone` on its first line if it needs one. A report line with `FAIL` in it, a
`TRAPPED` line, or a test that never reaches its end fails the run.

Keep test files plain ASCII — CI fails a `.ps1` with any other byte and no BOM — and build a
non-ASCII string from its code points: `-join [char[]](0x0646, 0x0641)`.

Before trusting a check that passes, make it fail once: plant the fault it is meant to catch
and see it reported. A check that cannot fail proves nothing.
