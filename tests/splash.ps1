# The little window both programs put up while they build themselves.
#
# It is shown for real here, for a fraction of a second, because a splash that
# is only ever tested with its own switch turned off is not tested at all. The
# runner sets ANDROIDDC_NO_SPLASH for every test, so this one puts that aside
# and back again.

Say '== when it is not wanted =='
Say ("  the runner's switch keeps it away   {0}" -f (Mark (
    $(Show-Splash -Root $PSScriptRoot; $shown = Test-SplashShown; Close-Splash; -not $shown))))
$keep = $env:ANDROIDDC_NO_SPLASH
$env:ANDROIDDC_NO_SPLASH = ''
Show-Splash -Root 'G:\no-such-folder' -Quiet
Say ("  and so does -Quiet, which is what a minimized start passes   {0}" -f (Mark (-not (Test-SplashShown))))

Say ''
Say '== what it says while it waits =='
Show-Splash -Root $scriptRoot -Version '9.9.9'
$state = Get-SplashState
Say ("  it opens at '{0}', {1}%   {2}" -f $state.Text, $state.Percent, (Mark (
    (Test-SplashShown) -and $state.Text -eq 'Starting ...' -and $state.Percent -eq 0)))
Update-Splash -Text 'Building the pages ...' -Percent 35
$state = Get-SplashState
Say ("  it moves: '{0}', {1}%   {2}" -f $state.Text, $state.Percent, (Mark (
    $state.Text -eq 'Building the pages ...' -and $state.Percent -ge 34 -and $state.Percent -le 36)))
Update-Splash -Percent 150
Say ("  a number past the end stops at 100: {0}%   {1}" -f (Get-SplashState).Percent,
    (Mark ((Get-SplashState).Percent -eq 100)))
Update-Splash -Percent -5
Say ("  a number below nothing means 'leave it where it is': {0}%   {1}" -f (Get-SplashState).Percent,
    (Mark ((Get-SplashState).Percent -eq 100)))
Update-Splash -Text 'Still here ...'
Say ("  so a step can say something without the bar moving   {0}" -f (Mark (
    (Get-SplashState).Text -eq 'Still here ...' -and (Get-SplashState).Percent -eq 100)))

Say ''
Say '== and when it has nothing left to stand in for =='
Close-Splash
Say ("  it goes   {0}" -f (Mark (-not (Test-SplashShown) -and $null -eq (Get-SplashState))))
Close-Splash
Update-Splash -Text 'nobody is listening' -Percent 50
Say ("  closing twice, and talking to one that is gone, are both quiet   {0}" -f (Mark (
    -not (Test-SplashShown))))

# a folder with no assets in it: no icon, but still a window
Show-Splash -Root 'G:\no-such-folder'
Say ("  no icon beside the script is not a reason to go without it   {0}" -f (Mark (Test-SplashShown)))
Close-Splash
$env:ANDROIDDC_NO_SPLASH = $keep
Say ("  the runner's switch is back   {0}" -f (Mark ("$($env:ANDROIDDC_NO_SPLASH)" -eq "$keep")))
