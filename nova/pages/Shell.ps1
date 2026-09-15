# pages\Shell.ps1 - a live adb shell that keeps its state between lines, and
# the device log as it happens, with a filter that also applies to the lines
# already on screen.

$shellPage = Register-Page -Key 'shell' -Title 'Shell' -Glyph 'E756' -Section 'System' -Xaml 'Shell.xaml'

# A C# helper owns each process: its stdout/stderr callbacks run on threadpool
# threads, where a PowerShell script block would have no runspace.
if (-not ('LineReader' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public class LineReader {
    // Reads a program's output into a queue on .NET's own threads. Logcat used
    // Register-ObjectEvent for this instead, and once that subscription had
    // carried a live adb logcat stream, no asynchronous read completed on any
    // adb process started afterwards: the live shell showed nothing, before
    // or after logcat was stopped. The same logcat read by this class leaves
    // them working, and so does the same subscription on 20000 lines from cmd.
    private readonly ConcurrentQueue<string> queue = new ConcurrentQueue<string>();
    private Process proc;

    public ConcurrentQueue<string> Queue { get { return queue; } }
    public Process Process { get { return proc; } }

    public bool Start(string exe, string arguments) {
        var info = new ProcessStartInfo(exe, arguments);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        // adb writes UTF-8; unset, a line is decoded with the console page
        info.StandardOutputEncoding = new System.Text.UTF8Encoding(false);
        info.StandardErrorEncoding = new System.Text.UTF8Encoding(false);

        proc = new Process();
        proc.StartInfo = info;
        proc.OutputDataReceived += (sender, e) => { if (e.Data != null) queue.Enqueue(e.Data); };
        proc.ErrorDataReceived += (sender, e) => { if (e.Data != null) queue.Enqueue("! " + e.Data); };

        if (!proc.Start()) { return false; }
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        return true;
    }
}
"@
}

if (-not ('LiveShell' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;

public class LiveShell {
    private Process proc;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();

    public Process Process { get { return proc; } }

    public bool Start(string exe, string arguments) {
        var info = new ProcessStartInfo(exe, arguments);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        // adb writes UTF-8; unset, a reply is decoded with the console page
        info.StandardOutputEncoding = new System.Text.UTF8Encoding(false);
        info.StandardErrorEncoding = new System.Text.UTF8Encoding(false);

        proc = new Process();
        proc.StartInfo = info;
        proc.OutputDataReceived += (sender, e) => { if (e.Data != null) lines.Enqueue(e.Data); };
        proc.ErrorDataReceived += (sender, e) => { if (e.Data != null) lines.Enqueue(e.Data); };

        if (!proc.Start()) { return false; }
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        return true;
    }

    public void Send(string line) {
        if (proc != null && !proc.HasExited) {
            // .NET Framework writes stdin in the console's input code page, and
            // has no StandardInputEncoding to change that. On an OEM page every
            // Arabic letter became '?', and the phone's shell then expanded
            // "????" as a file pattern. adb reads UTF-8, so the bytes go out as
            // UTF-8, with the same line ending as before.
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(line + proc.StandardInput.NewLine);
            proc.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
            proc.StandardInput.BaseStream.Flush();
        }
    }

    public string[] Drain(int max) {
        var result = new List<string>();
        string item;
        while (result.Count < max && lines.TryDequeue(out item)) { result.Add(item); }
        return result.ToArray();
    }

    public bool Running { get { return proc != null && !proc.HasExited; } }

    public void Stop() {
        try {
            if (proc != null && !proc.HasExited) {
                Send("exit");
                if (!proc.WaitForExit(1500)) { proc.Kill(); }
            }
        } catch { }
        proc = null;
    }
}
"@
}

$script:shell = $null
$script:shellHistory = @()
$script:shellHistoryIndex = 0

$script:logcatProcess = $null
$script:logcatReader = $null
$script:logcatQueue = $null
$script:logcatDropped = 0
$script:logcatRaw = New-Object 'System.Collections.Generic.List[string]'
$script:logcatRunningText = 'stopped'

# how long each console box is, kept here: reading .Text copies the whole box
$script:shellConsoleLength = @{}

foreach ($preset in @('presets...', 'getprop ro.product.model', 'ip -f inet addr show wlan0', 'ip route',
        'pm list packages -3', 'dumpsys battery', 'settings get secure default_input_method', 'ime list -a -s',
        'wm size; wm density', 'top -n 1 -b | head -20', 'logcat -d -t 40', 'df -h', 'su')) {
    $null = $ui.ShellPreset.Items.Add($preset)
}
$ui.ShellPreset.SelectedIndex = 0

foreach ($level in @('V  everything', 'D  debug and up', 'I  info and up', 'W  warnings and up', 'E  errors and up', 'F  fatal only')) {
    $null = $ui.ShellLogcatLevel.Items.Add($level)
}
$ui.ShellLogcatLevel.SelectedIndex = 2

# ------------------------------------------------------- console boxes ----

function Get-ShellConsoleLength {
    param($Box)
    if ($script:shellConsoleLength.ContainsKey($Box.Name)) { return [int]$script:shellConsoleLength[$Box.Name] }
    return 0
}

function Add-ShellConsoleText {
    # one append per batch: the box is laid out once, not once per line
    param($Box, [string]$Text, [switch]$Follow)

    if (-not $Text) { return }
    Remove-LogcatHead -Box $Box
    $Box.AppendText($Text)
    $script:shellConsoleLength[$Box.Name] = (Get-ShellConsoleLength -Box $Box) + $Text.Length
    if ($Follow) { $Box.ScrollToEnd() }
}

function Set-ShellConsoleText {
    param($Box, [string]$Text, [switch]$Follow)

    $Box.Text = $Text
    $script:shellConsoleLength[$Box.Name] = $Text.Length
    if ($Follow) { $Box.ScrollToEnd() }
}

function Clear-ShellConsole {
    param($Box)
    $Box.Clear()
    $script:shellConsoleLength[$Box.Name] = 0
}

function Remove-LogcatHead {
    <#
        Drops the oldest text once a box gets long: past 400,000 characters
        the newest 200,000 stay, cut on a line boundary. Assigning Text with
        the second half rebuilds the whole buffer; deleting a selection only
        touches the head. A read-only RichTextBox ignored the delete in
        silence in the WinForms program, so IsReadOnly is lifted for the edit
        here as well, and the test checks that the length really changed.
    #>
    param($Box = $ui.ShellLogcatText, [int]$Limit = 400000, [int]$Keep = 200000)

    $length = Get-ShellConsoleLength -Box $Box
    if ($length -le $Limit) { return }

    $cut = $length - $Keep
    # one copy of the text, and only when a cut is due
    $newline = $Box.Text.IndexOf("`n", $cut)
    $boundary = if ($newline -ge 0) { $newline + 1 } else { $cut }

    $wasReadOnly = $Box.IsReadOnly
    $Box.IsReadOnly = $false
    try {
        $Box.Select(0, $boundary)
        $Box.SelectedText = ''
        $Box.Select($Box.Text.Length, 0)
    } finally {
        $Box.IsReadOnly = $wasReadOnly
    }
    $script:shellConsoleLength[$Box.Name] = $Box.Text.Length
}

# --------------------------------------------------------------- shell ----

function Write-Shell {
    # Color is kept for the callers' sake; the Console box is one colour
    param([string]$Text, [string]$Color = 'info')
    Add-ShellConsoleText -Box $ui.ShellOut -Text ($Text + [Environment]::NewLine) -Follow
}

function Start-LiveShell {
    $serial = Get-TargetSerial
    if (-not $serial) { return }

    Stop-LiveShell -Quiet

    $script:shell = New-Object LiveShell
    if (-not $script:shell.Start($script:adbPath, "-s $serial shell")) {
        Write-Shell 'Could not start adb shell.' $colorBad
        $script:shell = $null
        return
    }

    $ui.ShellStatus.Text = "connected to $serial"
    $ui.ShellStatus.Foreground = Get-Resource 'Success'
    $ui.ShellStop.IsEnabled = $true
    $ui.ShellStart.IsEnabled = $false
    Write-Shell "--- adb -s $serial shell ---" $colorStep
    $script:shellTimer.Start()
    $null = $ui.ShellInput.Focus()
}

function Stop-LiveShell {
    param([switch]$Quiet)

    $script:shellTimer.Stop()
    if ($script:shell) {
        $script:shell.Stop()
        $script:shell = $null
    }

    $ui.ShellStop.IsEnabled = $false
    $ui.ShellStart.IsEnabled = $true
    $ui.ShellStatus.Text = 'not connected'
    $ui.ShellStatus.Foreground = Get-Resource 'MutedText'
    if (-not $Quiet) { Write-Shell '--- session closed ---' $colorWarn }
}

function Send-ShellLine {
    $line = $ui.ShellInput.Text
    if ($line.Trim() -eq '') { return }

    if (-not $script:shell -or -not $script:shell.Running) {
        Write-Shell 'No live shell - press "Start shell" first.' $colorWarn
        return
    }

    Write-Shell "$ $line" $colorStep
    $script:shell.Send($line)

    $script:shellHistory += $line
    $script:shellHistoryIndex = $script:shellHistory.Count
    $ui.ShellInput.Clear()
}

function Step-ShellHistory {
    # Up is -1, Down is +1; true when the key was used
    param([int]$Step)

    if ($script:shellHistory.Count -eq 0) { return $false }
    if ($Step -lt 0) {
        if ($script:shellHistoryIndex -gt 0) { $script:shellHistoryIndex-- }
        $ui.ShellInput.Text = $script:shellHistory[$script:shellHistoryIndex]
    } elseif ($script:shellHistoryIndex -lt $script:shellHistory.Count - 1) {
        $script:shellHistoryIndex++
        $ui.ShellInput.Text = $script:shellHistory[$script:shellHistoryIndex]
    } else {
        $script:shellHistoryIndex = $script:shellHistory.Count
        $ui.ShellInput.Clear()
    }
    $ui.ShellInput.SelectionStart = $ui.ShellInput.Text.Length
    return $true
}

# -------------------------------------------------------------- logcat ----
# adb logcat never ends by itself, so it runs as a real process and its output
# is drained on a timer. Nothing blocks the window, and Stop kills the process.

function Start-Logcat {
    if ($script:logcatProcess -and -not $script:logcatProcess.HasExited) {
        Write-Log 'logcat is already running.' $colorWarn
        return
    }

    $serial = Get-TargetSerial
    if (-not $serial) { return }

    $level = "$($ui.ShellLogcatLevel.SelectedItem)".Substring(0, 1)

    $script:logcatRaw = New-Object 'System.Collections.Generic.List[string]'

    # LineReader reads the stream on .NET's own threads, in UTF-8. It replaced
    # Register-ObjectEvent, which broke every interactive adb process started
    # after it - see the class.
    $reader = New-Object LineReader
    # -v time gives a readable stamp; *:LEVEL is the priority filter
    if (-not $reader.Start($script:adbPath, "-s $serial logcat -v time *:$level")) {
        Write-Log 'adb logcat did not start.' $colorBad
        return
    }
    $script:logcatReader = $reader
    $script:logcatQueue = $reader.Queue
    $script:logcatProcess = $reader.Process
    $script:logcatDropped = 0

    $script:logcatTimer.Start()

    $ui.ShellLogcatStart.IsEnabled = $false
    $ui.ShellLogcatStop.IsEnabled = $true
    $script:logcatRunningText = "running on $serial at level $level"
    $ui.ShellLogcatState.Text = $script:logcatRunningText
    Write-Log "logcat started on $serial (level $level)." $colorGood
}

function Update-LogcatView {
    if (-not $script:logcatQueue) { return }

    $filter = $ui.ShellLogcatFilter.Text.Trim()
    $batch = New-Object System.Text.StringBuilder
    $line = ''
    $taken = 0

    # a busy phone can outrun the window; take a slice per tick and say when
    # lines had to be dropped rather than freezing to keep up
    while ($taken -lt 800 -and $script:logcatQueue.TryDequeue([ref]$line)) {
        $taken++

        # every line is kept unfiltered, capped, so the filter can be changed
        # afterwards and still apply to what is already here
        $script:logcatRaw.Add($line)
        if ($script:logcatRaw.Count -gt 6000) { $script:logcatRaw.RemoveRange(0, 2000) }

        # inline rather than Test-TextContains: this runs for every line
        if ($filter -and $line.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $null = $batch.AppendLine($line)
    }
    # 800 lines every 250 ms is 3200 a second, past anything but a log storm.
    # If even that is outrun, the oldest lines go rather than the window.
    if ($script:logcatQueue.Count -gt 20000) {
        $spare = ''
        while ($script:logcatQueue.Count -gt 10000 -and $script:logcatQueue.TryDequeue([ref]$spare)) {
            $script:logcatDropped++
        }
    }

    if ($batch.Length -gt 0) {
        Add-ShellConsoleText -Box $ui.ShellLogcatText -Text $batch.ToString() -Follow:([bool]$ui.ShellLogcatFollow.IsChecked)
    }

    if ($script:logcatProcess -and $script:logcatProcess.HasExited) {
        Stop-Logcat -Quiet
        $ui.ShellLogcatState.Text = 'stopped: adb ended the stream'
        return
    }
    if ($script:logcatDropped -gt 0) {
        $ui.ShellLogcatState.Text = "running   |   $($script:logcatDropped) line(s) dropped, the phone is louder than the window"
    }
}

function Show-LogcatFiltered {
    # redraw the window from the lines kept in memory, so typing a filter hides
    # what is already on screen too
    if (-not $script:logcatRaw) { return }

    $filter = $ui.ShellLogcatFilter.Text.Trim()

    $matching = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $script:logcatRaw) {
        if ($filter -and $line.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $matching.Add($line)
    }

    # rebuilding the box is the costly operation, so only the newest lines are
    # drawn; the rest stay in the list
    $shown = $matching
    $trimmed = $false
    if ($matching.Count -gt 1200) {
        $shown = $matching.GetRange(($matching.Count - 1200), 1200)
        $trimmed = $true
    }

    $batch = New-Object System.Text.StringBuilder
    foreach ($line in $shown) { $null = $batch.AppendLine($line) }
    Set-ShellConsoleText -Box $ui.ShellLogcatText -Text $batch.ToString() -Follow:([bool]$ui.ShellLogcatFollow.IsChecked)

    if ($filter) {
        $ui.ShellLogcatState.Text = "$($matching.Count) of $($script:logcatRaw.Count) kept lines match '$filter'" +
            $(if ($trimmed) { ' - showing the newest 1200' } else { '' })
    } else {
        $ui.ShellLogcatState.Text = if ($script:logcatProcess) { $script:logcatRunningText } else { 'stopped' }
    }
}

function Stop-Logcat {
    param([switch]$Quiet)

    $script:logcatTimer.Stop()
    if ($script:logcatProcess) {
        try { if (-not $script:logcatProcess.HasExited) { $script:logcatProcess.Kill() } } catch { }
        try { $script:logcatProcess.Dispose() } catch { }
        $script:logcatProcess = $null
    }
    $script:logcatReader = $null

    $ui.ShellLogcatStart.IsEnabled = $true
    $ui.ShellLogcatStop.IsEnabled = $false
    if (-not $Quiet) {
        $ui.ShellLogcatState.Text = 'stopped'
        Write-Log 'logcat stopped.' $colorInfo
    }
}

function Clear-Logcat {
    # -AlsoPhone (Shift held on Clear) empties the ring buffer on the phone too
    param([bool]$AlsoPhone = $false)

    Clear-ShellConsole -Box $ui.ShellLogcatText
    if ($script:logcatRaw) { $script:logcatRaw.Clear() }
    $script:logcatDropped = 0

    if ($AlsoPhone) {
        $serial = Get-TargetSerial
        if ($serial) {
            $null = Invoke-Adb -CommandArguments @('-s', $serial, 'logcat', '-c')
            Write-Log 'The log buffer on the phone was cleared as well.' $colorInfo
        }
    }
}

function Save-Logcat {
    if ((Get-ShellConsoleLength -Box $ui.ShellLogcatText) -eq 0) { Write-Log 'Nothing to save yet.' $colorWarn; return }

    $path = Select-SaveFile -Filter 'Log file (*.log)|*.log|Text (*.txt)|*.txt' `
        -FileName ('logcat-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    if (-not $path) { return }

    Set-Content -LiteralPath $path -Value $ui.ShellLogcatText.Text -Encoding UTF8
    Write-Log "Saved $path." $colorGood
}

# -------------------------------------------------------------- timers ----
# Neither tick runs adb or pumps the window, so they cannot stack on a call in
# flight and keep draining while one runs.

$script:shellTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:shellTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:shellTimer.Add_Tick({
    if (-not $script:shell) { $script:shellTimer.Stop(); return }

    $lines = $script:shell.Drain(400)
    if ($lines.Count -gt 0) { Write-Shell ($lines -join [Environment]::NewLine) }

    if (-not $script:shell.Running) {
        Write-Shell '--- the device closed the shell ---' $colorWarn
        Stop-LiveShell -Quiet
    }
})

$script:logcatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:logcatTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:logcatTimer.Add_Tick({ Update-LogcatView })

$script:logcatFilterTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:logcatFilterTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:logcatFilterTimer.Add_Tick({
    $script:logcatFilterTimer.Stop()
    Show-LogcatFiltered
})

# -------------------------------------------------------------- events ----

$ui.ShellStart.Add_Click({ Start-LiveShell })
$ui.ShellStop.Add_Click({ Stop-LiveShell })
$ui.ShellClear.Add_Click({ Clear-ShellConsole -Box $ui.ShellOut })
$ui.ShellSend.Add_Click({ Send-ShellLine })

$ui.ShellPreset.Add_SelectionChanged({
    if ($ui.ShellPreset.SelectedIndex -le 0) { return }
    $ui.ShellInput.Text = "$($ui.ShellPreset.SelectedItem)"
    $ui.ShellPreset.SelectedIndex = 0
    $null = $ui.ShellInput.Focus()
    $ui.ShellInput.SelectionStart = $ui.ShellInput.Text.Length
})

$ui.ShellInput.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    switch ($eventArgs.Key) {
        'Return' { $eventArgs.Handled = $true; Send-ShellLine }
        'Up' { if (Step-ShellHistory -Step -1) { $eventArgs.Handled = $true } }
        'Down' { if (Step-ShellHistory -Step 1) { $eventArgs.Handled = $true } }
    }
})

$ui.ShellLogcatStart.Add_Click({ Start-Logcat })
$ui.ShellLogcatStop.Add_Click({ Stop-Logcat })
$ui.ShellLogcatClear.Add_Click({
    $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    Clear-Logcat -AlsoPhone $shift
})
$ui.ShellLogcatSave.Add_Click({ Save-Logcat })

$ui.ShellLogcatFilter.Add_TextChanged({
    # wait for the typing to settle rather than redrawing on every key
    $script:logcatFilterTimer.Stop()
    $script:logcatFilterTimer.Start()
})

$ui.ShellLogcatLevel.Add_SelectionChanged({
    # the level is a start-up argument, so restart the stream to apply it
    if ($script:logcatProcess -and -not $script:logcatProcess.HasExited) {
        Stop-Logcat -Quiet
        Start-Logcat
    }
})

Register-Cleanup {
    Stop-LiveShell -Quiet
    Stop-Logcat -Quiet
    $script:logcatFilterTimer.Stop()
}
