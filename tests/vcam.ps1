<#
    The virtual camera (shared\VirtualCamera.ps1, windows\vcam).

    Without a phone: the state check, the host's command line, and the
    host's own self-test (camera listed, test pattern, 30 fps, the shared
    picture). With -Serial: the phone's camera feeds it through Start-VCam,
    the camera is listed while on, and gone after Stop-VCam.

    Registering the camera needs one administrator prompt; -Register allows it.
    The phone is only read: its camera streams, nothing on it changes.

        powershell -File tests\vcam.ps1 [-Serial <serial>] [-CameraId 1] [-Register]
#>
param([string]$Serial, [string]$CameraId = '', [switch]$Register)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failed = 0
function Mark([bool]$ok) { if ($ok) { 'ok' } else { $script:failed++; 'FAILED' } }
function Wait-Pumped { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
. (Join-Path $root 'shared\VirtualCamera.ps1')

'== the command line =='
$arguments = Get-VCamArguments -Serial 'SERIAL1' -CameraId '1' -Size '1280x720' -Mirror
"  " + ($arguments -join ' ')
"  run, serial, adb, server, camera id, size, mirror   {0}" -f (Mark (($arguments[0] -eq 'run') -and ($arguments -contains 'SERIAL1') -and
    ($arguments -contains '--camera-id') -and ($arguments -contains '1280x720') -and ($arguments -contains '--mirror') -and
    (Test-Path -LiteralPath $arguments[($arguments.IndexOf('--adb') + 1)])))
$arguments = Get-VCamArguments -Serial 'SERIAL1' -Facing 'front'
"  facing instead of an id   {0}" -f (Mark (($arguments -contains '--camera-facing') -and -not ($arguments -contains '--camera-id')))

'== what is needed =='
$state = Get-VCamState
"  need: '{0}'  {1}" -f $state.Need, $state.Message
if ($state.Need -eq 'register' -and $Register) {
    "  registering (administrator prompt) ..."
    $null = Register-VCam -Dll $state.Dll
    $state = Get-VCamState
}
"  ready   {0}" -f (Mark $state.Ready)
if (-not $state.Ready) { "RESULT fail ($failed)"; exit 1 }

'== the host self-test =='
$host_ = Join-Path $state.Folder 'AndroidDC.VCamHost.exe'
$out = @(& $host_ selftest 2>&1 | ForEach-Object { "$_" })
$out | ForEach-Object { "  $_" }
"  self-test passes   {0}" -f (Mark ($LASTEXITCODE -eq 0))

if ($Serial) {
    '== the phone camera through Start-VCam =='
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Start-VCam -Serial $Serial -CameraId $CameraId -Facing $(if ($CameraId) { '' } else { 'front' })
    "  {0} ({1} ms)" -f $result.Message, $watch.ElapsedMilliseconds
    "  on and fed   {0}" -f (Mark $result.Ok)
    Start-Sleep -Seconds 6
    $list = @(& $host_ list 2>&1 | ForEach-Object { "$_" })
    "  listed while on   {0}" -f (Mark ([bool]($list -match 'AndroidDC Camera')))
    $peek = @(& $host_ peek 2>&1 | ForEach-Object { "$_" })
    "  " + ($peek -join ' ')
    "  an app opening it now sees the phone   {0}" -f (Mark ($LASTEXITCODE -eq 0))
    "  still running   {0}" -f (Mark (Test-VCamRunning))
    $stopped = Stop-VCam
    Start-Sleep -Seconds 2
    $list = @(& $host_ list 2>&1 | ForEach-Object { "$_" })
    "  stopped, and gone from the list   {0}" -f (Mark ($stopped -and -not ($list -match 'AndroidDC Camera')))
}

if ($failed) { "RESULT fail ($failed)"; exit 1 } else { 'RESULT pass'; exit 0 }
