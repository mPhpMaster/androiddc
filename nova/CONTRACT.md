# How a page is built

AndroidDC Nova is `androiddc.ps1` (the WinForms program in the project folder, `..\`) rebuilt as
a WPF desktop application in the friendly-interface design. **Every feature of the original
stays**: every button, option, confirmation, safety check, log message and the reason behind
it. Only the window changes. When the original does something careful - verifies a copy before
deleting, reads the phone before toggling, refuses a mismatch scrcpy would reject - the page
does the same.

Read these first:

* `lib\Core.ps1` - adb off the window's thread, quoting, settings, device state.
* `lib\Ui.ps1` - pages, log, device list, dialogs, lists, the busy strip.
* `ui\Theme.xaml` - every style key. Use them; never write a colour or a radius into a page.
* `pages\Overview.ps1` / `.xaml` - a complete page, the pattern to follow. It is being written
  at the same time as the other pages; if it is not there yet, the example below and
  `ui\Shell.xaml` show the same conventions.
* The original: `..\androiddc.ps1`, `..\docs\user-guide.md`, `..\docs\architecture.md`
  (read its table of PowerShell traps - they all apply here too).

## Files and ownership

A page is two files: `pages\<Page>.ps1` and `pages\<Page>.xaml`. You write **only** your own
pages' files and your own tests under `tests\`. Never edit `lib\`, `ui\`, `androiddc-nova.ps1`,
this file, or another page. If you need something shared, write it in your page with a
page-prefixed name and say so in your final report.

All pages are dot-sourced into one script scope, so **a function name used twice silently
replaces the first**. Keep the original's function names for the functions you port (they are
unique already), and prefix any new helper with your page name (`Files-...` is wrong, use
`Get-FilesSomething` / `Update-FilesSomething`).

| Page file | Section | Ports from androiddc.ps1 | Owns (functions) |
|---|---|---|---|
| `Overview` | Workspace | the Device tab | `Show-DeviceTab`, `Get-DeviceReport`, toggles (`Set-DeviceToggle`, `Show-ToggleStates`, `ConvertFrom-ToggleOutput`, `Set-ToggleMarks`), `Get-TorchState`, `Switch-Torch`, `Send-Buzz`, `Start-QuickCall`, `Open-QuickDialer`, `Send-QuickSms`, `Send-Ussd`, `Show-Notifications` |
| `Screen` | Workspace | the phone screen frame | `Test-PngFile`, `Get-CaptureBytes`, `Show-CaptureBytes`, `Show-CaptureFile`, `Update-Capture`, `Get-CaptureInto`, `Convert-ToDevicePoint`, `Send-Tap`, `Send-Swipe`, `Send-Key`, `Send-Text`, `Clear-Capture` |
| `Mirroring` | Workspace | Advanced > Mirroring and More scrcpy options | `Get-HidArguments`, `Get-ExtraScrcpyArguments`, `Get-StartAppValue`, `Update-StartAppChoices`, `Get-ScrcpyArguments`, `Get-MoreScrcpyArguments`, `Start-Scrcpy`, `Close-Scrcpy`, `Show-ScrcpyDisplays`, `Update-VideoCodecList` (the video half of `Update-EncoderList`) |
| `Apps` | Workspace | Apps | `Get-AppLabels`, `Update-AppList`, `Get-SelectedPackages`, `Get-LauncherActivity`, `Start-App`, `Stop-App`, `Show-AppInfo`, `Uninstall-App`, `Get-AppListCsv`, `Export-AppList`, `Install-Apk` |
| `Files` | Workspace | Files | every file function (`Join-DevicePath` ... `Open-FileOnPhone`) |
| `Media` | Workspace | Cam / Mic | camera and audio functions, `Get-DeviceCapabilityList`, `Update-AudioEncoderChoices`, `Update-CameraSizeList`, the audio half of `Update-EncoderList` |
| `Messages` | Personal | SMS | `Update-SmsList`, `Send-Sms`, `Find-SendButton`, `Remove-Sms`, `Edit-Sms`, `Export-Sms`, `Split-ContentRows`, `Get-RowValue` |
| `Contacts` | Personal | Contacts | `Update-ContactList`, `Add-Contact`, `Edit-Contact`, `Remove-Contact`, `Start-PhoneCall`, `Stop-PhoneCall`, `Export-Contacts` |
| `Tethering` | Connect | Tethering (both directions) | gnirehtet and proxy functions, `Invoke-Gnirehtet`, `Get-PortOwner`, `Start-Sharing`, `Stop-Sharing`, `Restart-Sharing`, `Test-Connectivity`, `Repair-Tunnel`, `Show-ReverseTunnels`, `Stop-StrayRelays`, the relay output timer |
| `Radios` | Connect | Wi-Fi, Bluetooth, NFC | `Get-RadioFeature`, `Get-WifiConnection`, `Get-BluetoothConnections`, `Get-SignalStrength`, Wi-Fi / Bluetooth / NFC functions |
| `Tools` | System | Advanced > Device tools and Root / recovery | wireless pairing, mDNS, reconnect, bug report, tcpip, connect / disconnect, restart server, `Get-DeviceIp`, screenshot to file, screen on/off, reboot, battery, private DNS, IME, hotspot, `Get-UiDump`, `Test-DeviceLocked`, root / recovery functions |
| `Running` | System | Running | the running-process functions |
| `Users` | System | Users | the user functions, `Open-DeviceSettingsScreen` |
| `Shell` | System | Shell > Shell and Logcat | `LineReader` / `LiveShell` (Add-Type), the shell and logcat functions |

Already provided - **do not redefine**: everything in `lib\Core.ps1` and `lib\Ui.ps1`
(`Invoke-Adb`, `Invoke-DeviceShell`, `Invoke-DeviceShellText`, `Invoke-DeviceCommand`,
`Quote-DeviceArgument`, `Test-TextContains`, `Get-AdbBytes`, `Wait-Pumped`, `Invoke-Pump`,
`Get-AdbDevices`, `Update-DeviceList`, `Get-SelectedSerial`, `Get-SelectedSerials`,
`Get-TargetSerial`, `Get-DeviceScreenState`, `Get-BatteryInfo` (`.Line` replaces
`Get-BatteryLine`), `Get-SignalInfo` (`.Line` replaces `Get-SignalLine`), `Get-MemoryInfo`,
`Format-FileSize`, `Write-Log`, `Show-InputDialog`, `Show-Confirm`, `Show-Notice`, `Show-Choice`,
`Show-Toast`, `Invoke-ButtonClick`, `Add-ListContextMenu`, `Copy-ListSelection`,
`Set-ListFilter`, `Set-ListColumnsSortable`, `Get-NumberValue`, `Select-SaveFile`,
`Select-OpenFiles`, `Select-Folder`, `Set-SharingState`, `Register-Setting`, `Register-Page`,
`Register-Cleanup`, `Test-PageShown`, `Show-Page`, `Get-Resource`).

### Calls between pages

Call another page's function by its name; every page is loaded before any click can happen.
Guard a call to a page that may not be finished yet:

```powershell
if (Get-Command Start-Scrcpy -ErrorAction SilentlyContinue) { Start-Scrcpy }
```

The ones the original makes: Overview > `Update-Capture` (Screen), `Send-Sms` (Messages),
`Get-DeviceIp` (Tools); header Mirror button > `Start-Scrcpy` (Mirroring); Mirroring >
`Start-Sharing` (Tethering, for *Share internet + scrcpy*), `Get-AppLabels` (Apps, for the start
app list); Apps > `Get-ScrcpyArguments` (Mirroring, for *Own scrcpy window*); Tools >
`Install-Apk` (Apps), `Show-ReverseTunnels`, `Stop-StrayRelays`, `Repair-Tunnel`,
`Restart-Sharing` (Tethering); Radios > `Open-DeviceSettingsScreen` (Users). `Set-Running`
becomes `Set-SharingState -Target <text or ''>` plus your own Start/Stop button states.

## The page file

```powershell
# pages\Example.ps1 - what the page is for, in a sentence or two.

$examplePage = Register-Page -Key 'example' -Title 'Example' -Glyph 'E71D' -Section 'Workspace' `
    -Xaml 'Example.xaml' -OnShow { ... } -OnDeviceChanged { ... } -Refresh { Update-ExampleList }

function Update-ExampleList { ... }          # functions first

$ui.ExampleRefresh.Add_Click({ Update-ExampleList })   # then events, one line each where possible
Add-ListContextMenu -List $ui.ExampleList -Buttons @($ui.ExampleOpen, $null, $ui.ExampleDelete)
Register-Setting -Name 'Example.Filter' -Get { $ui.ExampleFilter.Text } -Set { param($v) $ui.ExampleFilter.Text = "$v" }
Register-Cleanup { Stop-ExampleProcess }
```

* `-Glyph` is a Segoe Fluent Icons code point in hex.
* `-OnShow` runs every time the page is opened (reading what the phone is doing, like the
  original did on tab change). `-OnDeviceChanged` runs for **every** page when another phone is
  picked: re-read if `Test-PageShown -Key 'example'`, otherwise clear what belonged to the old
  phone. `-Refresh` is what F5 does on the page.
* Settings: `Register-Setting` with a `Page.Name` key. They are restored after every page is
  registered and saved on a normal close. Keep every setting the original kept.
* Anything started that outlives a click (scrcpy, a relay, audio, logcat, a proxy) is stopped in
  `Register-Cleanup`, as the original did in `FormClosing`.
* Timers: `System.Windows.Threading.DispatcherTimer`; skip a tick while `$script:busy -gt 0`.

## The XAML

Root element, namespaces and nothing else special:

```xml
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
```

* **Every `x:Name` starts with the page name** (`AppsList`, `AppsLaunch`, `FilesPath`). `Import-Xaml`
  stops the program at startup on a duplicate, so a clash shows at once.
* Sections are `Border Style="{StaticResource CardPanel}"` with a `TextBlock Style="{StaticResource
  Caps}"` title in capitals. Group what belongs together, as the original's group boxes did.
* Buttons: default (grey) for most, `Primary` for the one main action of a card, `DangerButton`
  for anything that deletes or cannot be undone, `Ghost` for links, `IconButton` with a glyph
  **only** where the symbol is universally read (refresh, delete, search, copy, settings,
  arrows, play, folder, add, close) - and then a `ToolTip` with the words. Quick actions can use
  `Tile`.
* Options: `CheckBox` (drawn as a switch). One of a few choices: `RadioButton Style="{StaticResource
  Segment}"` inside a `Border Background="{StaticResource Surface}" CornerRadius="10" Padding="3"`,
  or a `ComboBox`. Numbers: a `TextBox` read with `Get-NumberValue`.
* Labels for fields: `TextBlock Style="{StaticResource FieldLabel}"` above the box.
* Lists: `ListView` + `GridView`, headers in capitals, `DisplayMemberBinding="{Binding Name}"`,
  rows as `[PSCustomObject]` in an `ObservableCollection[object]`. Sort with
  `Set-ListColumnsSortable`, filter with `Set-ListFilter`, right-click with `Add-ListContextMenu`.
* Machine text (details, shell, logcat): `TextBox Style="{StaticResource Console}"`.
* Inner pages (Tethering's two directions, Mirroring's two, Tools' two, Radios' three, Shell's two):
  `TabControl` / `TabItem` - already styled as a segmented control.
* Tooltips: everything the original explained in a tooltip or a hint label keeps that text.

### Fitting the window

The window's smallest size is 1180 x 720. The page area is then about **900 px wide and 360 px
tall** (the log can be folded to give more). So:

* Lay out with `Grid` columns, `WrapPanel` and `DockPanel`; never fixed `Canvas` positions.
* A page with a list gives the list the `*` row; everything else `Auto`.
* A page of settings and buttons goes inside a `ScrollViewer` (vertical only) so it scrolls
  rather than cutting off.
* Nothing may stick out on the right at the smallest width. `tests\common.ps1` has
  `Get-OutsideElements` to check it.

## Porting rules

* **WinForms to WPF**: `MessageBox` / `InputBox` > `Show-Confirm` / `Show-Notice` /
  `Show-InputDialog`; `OpenFileDialog` / `SaveFileDialog` / `FolderBrowserDialog` >
  `Select-OpenFiles` / `Select-SaveFile` / `Select-Folder`; `[System.Windows.Forms.Clipboard]` >
  `[System.Windows.Clipboard]`; `Application::DoEvents()` > `Invoke-Pump`; `.Checked` >
  `.IsChecked`; `.Enabled` > `.IsEnabled`; `.Visible` > `.Visibility`; `NumericUpDown.Value` >
  `Get-NumberValue`; `RichTextBox` coloured output > `Console` TextBox (`AppendText`,
  `ScrollToEnd`); `PictureBox` > `Image` with a `BitmapImage` (`CacheOption = OnLoad`, `Freeze()`).
  `Update-*Layout` functions are not ported: WPF layout does that job.
* Keep `Write-Log 'text' $colorStep|$colorGood|$colorWarn|$colorBad|$colorInfo` exactly.
* adb only through the Core functions (never `& adb` on the window's thread). Text a person typed
  goes through `Invoke-DeviceCommand`.
* Every `.ps1` stays plain ASCII: a non-ASCII character is built from its code point
  (`[char]0x0625`). XAML files are UTF-8 and may use `&#x...;` entities.
* No literal path of this PC in any file; derive from `$scriptRoot`.
* `Set-StrictMode -Version Latest` is on: reading a property that is not there, or a variable
  never assigned, throws - and so does **indexing past the end of an array**: `@($list)[0]` on an
  empty list throws "Index was outside the bounds of the array". Use `Get-SelectedDevice` for the
  picked phone, and `foreach (...) { return $_ }` or a `.Count` check elsewhere.
* A parameter of `androiddc-nova.ps1` or a variable in a page must not share a name with a
  `$script:` variable of `lib\` (names ignore case): `$Pages` once became `$script:pages`.
* Event handlers take `param($sender, $eventArgs)`; `$_` is not the event argument.

## Testing a page

Write `tests\<page>.ps1` (see `tests\common.ps1`) and run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 -Test <page> -Pages <Page>[,<OtherPage>]
```

Other pages are being written in the same folder at the same time. `-Pages` loads only the
pages you name, so someone else's half-written page cannot stop your test; a call into a page
that is not loaded must then be guarded with `Get-Command` (see above). The finished app loads
every page.

It must at least: open the page (`Show-Page -Page '<key>'`), wait with `Wait-Idle`, save a picture
at the default and at the smallest size (`Set-WindowSize`, `Save-WindowPicture`), report
`Get-OutsideElements` as OK / FAIL, and check what can be checked without changing anything. Look
at the pictures yourself.

**A phone may be attached. It belongs to the user.** Tests and manual runs may only **read** from
it: `getprop`, `dumpsys`, `settings get`, `pm list`, `ls`, `content query`, `cmd ... list`,
screenshots. Never press or invoke anything that changes the phone - no install, uninstall,
toggle, call, SMS, file write or delete, Wi-Fi join, user change, reboot, sharing start. Never
run `adb kill-server`, `adb reboot`, scrcpy `--otg`, and never end the program with
`Stop-Process`: it is closed normally by the test runner.
