# The phone-screen pane follows the window at once, with no tab touched in
# between. It was once laid out on Panel1's Resize, before the docked group
# inside it had its new size, so after a shrink "Send text" sat past the edge.

function Test-Pane {
    param([string]$When)
    $w = $grpScreen.ClientSize.Width
    $h = $grpScreen.ClientSize.Height
    $out = @($grpScreen.Controls | Where-Object { $_.Bounds.Right -gt $w -or $_.Bounds.Bottom -gt $h })
    $need = [System.Windows.Forms.TextRenderer]::MeasureText($lblScreenHint.Text, $lblScreenHint.Font,
        (New-Object System.Drawing.Size(($w - 16), 10000)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
    Say ("{0}: pane {1} x {2}" -f $When, $w, $h)
    Say ("  Send text ends at {0} of {1}   {2}" -f $btnSendText.Bounds.Right, $w, (Mark ($btnSendText.Bounds.Right -le $w)))
    Say ("  controls past the pane: {0}   {1}" -f $out.Count, (Mark ($out.Count -eq 0)))
    Say ("  hint {0} px tall, its text needs {1}   {2}" -f $lblScreenHint.Height, $need, (Mark ($lblScreenHint.Height -ge $need)))
    Say ("  picture ends at {0}, hint starts at {1}   {2}" -f $picScreen.Bounds.Bottom, $lblScreenHint.Top,
        (Mark ($picScreen.Bounds.Bottom -lt $lblScreenHint.Top)))
    return @($btnSendText.Bounds, $lblScreenHint.Bounds, $picScreen.Bounds)
}

Wait-Pumped -Milliseconds 800
$startSize = $form.Size
$first = Test-Pane -When ("as opened ({0} x {1})" -f $form.Width, $form.Height)

$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 600
$null = Test-Pane -When 'straight after shrinking to the minimum'

$form.Size = $startSize
Wait-Pumped -Milliseconds 600
$back = Test-Pane -When 'straight after growing back'
Say ("  back where it started: {0}" -f (Mark ($back[0] -eq $first[0] -and $back[1] -eq $first[1] -and $back[2] -eq $first[2])))
