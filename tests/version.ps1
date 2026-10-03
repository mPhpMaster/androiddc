# The version, read off the running window rather than out of the file that
# sets it - and compared against the newest heading in the changelog rather
# than against a number written in here, which would have to be edited every
# release and would be wrong exactly when it mattered.
#
# There are two windows and three places each shows it: the splash that stands
# in while it is built, the activity log at startup, and - in Nova - the side
# navigation. A release with the number raised in one and not the other would
# have looked right from whichever one you happened to open.

Say ''
Say '== the version this window shows =='
$changelog = Join-Path $scriptRoot 'CHANGELOG.md'
$heading = @(Select-String -LiteralPath $changelog -Pattern '^## (\d+\.\d+\.\d+)')
Say ("  the changelog's newest release is readable   {0}" -f (Mark ($heading.Count -gt 0)))
$want = $(if ($heading.Count -gt 0) { $heading[0].Matches[0].Groups[1].Value } else { '' })
Say ("  which is {0}" -f $want)

Say ("  the window carries that number   {0}" -f (Mark ("$appVersion" -eq $want -and "$want" -ne '')))

$lines = @($txtLog.Text -split "`r?`n")
$named = @($lines | Where-Object { $_ -match 'AndroidDC \d' })
Say ("  the activity log names the tool and a number   {0}" -f (Mark ($named.Count -gt 0)))
if ($named.Count -gt 0) { Say ('  the line itself: ' + $named[0].Trim()) }
Say ("  and that number is the same one   {0}" -f (Mark (
    $named.Count -gt 0 -and "$want" -and $named[0] -match ('AndroidDC ' + [regex]::Escape($want) + '\s*$'))))

# the splash carries it too, and is the first thing anyone sees
$keep = $env:ANDROIDDC_NO_SPLASH
$env:ANDROIDDC_NO_SPLASH = ''
Show-Splash -Root $scriptRoot -Version $appVersion
$state = Get-SplashState
Close-Splash
$env:ANDROIDDC_NO_SPLASH = $keep
Say ("  the splash shows it as well: '{0}'   {1}" -f $state.Title, (Mark (
    "$want" -and "$($state.Title)" -match ([regex]::Escape($want) + '\s*$'))))

Say ("  and no older number is anywhere on the log   {0}" -f (Mark (
    @($lines | Where-Object { $_ -match 'AndroidDC \d' -and $_ -notmatch [regex]::Escape($want) }).Count -eq 0)))
