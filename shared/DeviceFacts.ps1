<#
    AndroidDC - what a phone is, and what it is doing with itself.

    Two readings both windows want and neither owns: the make of the phone,
    worked out from the model name the device list already has, and how busy
    its processors, memory and GPU are. Nothing here touches a control - each
    window asks, and then says it in its own way.

    Dot-sourced by both windows.
#>

function Get-DeviceMake {
    <#
        The make of a phone. Maker is what the phone says of itself -
        ro.product.manufacturer - and it is the thing to go on: this was
        written against a Redmi whose model is "23108RN04Y", which no pattern
        over a model name will ever match. The model and the serial are still
        read, because a phone that is not ready to be asked still has those.

        A letter in the make's own colour, because there are no brand marks to
        show: the icon font has none, and shipping somebody's logo with this is
        not something to do lightly. A make nobody here knows keeps the plain
        phone glyph, which is what every phone had before.
    #>
    param([string]$Model, [string]$Serial = '', [string]$Maker = '')

    $text = "$Maker $Model $Serial".Trim().ToLowerInvariant()
    foreach ($make in @(
            @{ Name = 'Samsung';  Letter = 'S'; Color = '#1428A0'; Match = 'samsung|^sm-|galaxy' }
            @{ Name = 'Xiaomi';   Letter = 'M'; Color = '#FF6900'; Match = 'xiaomi|redmi|poco|^mi\b|mi \d' }
            @{ Name = 'Google';   Letter = 'G'; Color = '#1A73E8'; Match = 'pixel|google' }
            @{ Name = 'OnePlus';  Letter = '1'; Color = '#EB0029'; Match = 'oneplus|^op\d' }
            @{ Name = 'Huawei';   Letter = 'H'; Color = '#CF0A2C'; Match = 'huawei|honor' }
            @{ Name = 'Oppo';     Letter = 'O'; Color = '#046A38'; Match = 'oppo|realme' }
            @{ Name = 'vivo';     Letter = 'V'; Color = '#415FFF'; Match = 'vivo|iqoo' }
            @{ Name = 'Motorola'; Letter = 'M'; Color = '#5C92FA'; Match = 'motorola|moto ' }
            @{ Name = 'Nokia';    Letter = 'N'; Color = '#124191'; Match = 'nokia' }
            @{ Name = 'Sony';     Letter = 'S'; Color = '#111111'; Match = 'sony|xperia' }
            @{ Name = 'LG';       Letter = 'L'; Color = '#A50034'; Match = '^lg[- ]|lg electronics' }
            @{ Name = 'Asus';     Letter = 'A'; Color = '#00539B'; Match = 'asus|zenfone|rog phone' }
            @{ Name = 'Lenovo';   Letter = 'L'; Color = '#E1140A'; Match = 'lenovo' }
            @{ Name = 'Nothing';  Letter = 'N'; Color = '#111111'; Match = 'nothing phone|^a06\d' }
            @{ Name = 'Tecno';    Letter = 'T'; Color = '#0057FF'; Match = 'tecno|infinix|itel' }
            @{ Name = 'Apple';    Letter = 'A'; Color = '#555555'; Match = 'iphone|ipad|apple' })) {
        if ($text -match $make.Match) {
            return [PSCustomObject]@{ Name = $make.Name; Letter = $make.Letter; Color = $make.Color }
        }
    }
    return $null
}

function Get-DeviceLoad {
    <#
        What the phone is doing with itself: how busy its processors are, how
        much of its memory is in use, and - where Android lets adb read it at
        all - its GPU.

        Measured on the phone this was written against: dumpsys cpuinfo ends
        with a TOTAL line, /proc/meminfo is readable, and every GPU file a
        phone might have (kgsl's gpubusy, mali's utilisation, devfreq's load)
        was refused. So the GPU answer is often "not readable", which is said
        rather than left looking broken.
    #>
    param([string]$Serial)

    $answer = [PSCustomObject]@{ Cpu = ''; Ram = ''; Gpu = ''; CpuUsed = -1; RamUsed = -1; GpuUsed = -1 }
    $cpu = (Invoke-DeviceShell -Serial $Serial -CommandArguments @('dumpsys cpuinfo 2>/dev/null | tail -1')).Text
    if ("$cpu" -match '([\d.]+)%\s+TOTAL') {
        $answer.Cpu = "$($Matches[1])%"
        $answer.CpuUsed = [int][Math]::Round([double]$Matches[1])
    }

    $mem = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        "grep -E 'MemTotal|MemAvailable' /proc/meminfo 2>/dev/null")).Text
    $total = 0
    $free = 0
    if ("$mem" -match 'MemTotal:\s+(\d+)') { $total = [long]$Matches[1] }
    if ("$mem" -match 'MemAvailable:\s+(\d+)') { $free = [long]$Matches[1] }
    if ($total -gt 0) {
        $used = $total - $free
        $answer.RamUsed = [int][Math]::Round(100.0 * $used / $total)
        $answer.Ram = "$($answer.RamUsed)% of " + (Format-FileSize -Bytes ([long]$total * 1024))
    }

    # the places a phone keeps its GPU load, tried in turn; most phones refuse
    $gpu = (Invoke-DeviceShell -Serial $Serial -CommandArguments @(
        'cat /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null; ' +
        'cat /sys/class/misc/mali0/device/utilisation 2>/dev/null; ' +
        'cat /sys/class/devfreq/*.mali/load 2>/dev/null')).Text
    foreach ($line in ("$gpu" -split "`r?`n")) {
        $words = "$line".Trim()
        if (-not $words) { continue }
        if ($words -match '^(\d+)\s+(\d+)$') {
            # kgsl: busy and total since the last read
            $busy = [double]$Matches[1]
            $all = [double]$Matches[2]
            if ($all -gt 0) {
                $answer.GpuUsed = [int][Math]::Round(100 * $busy / $all)
                $answer.Gpu = "$($answer.GpuUsed)%"
            }
            break
        }
        if ($words -match '^(\d+)%?$') {
            $answer.Gpu = "$($Matches[1])%"
            $answer.GpuUsed = [int]$Matches[1]
            break
        }
    }
    if (-not $answer.Gpu) { $answer.Gpu = 'not readable' }
    return $answer
}
