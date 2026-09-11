<#
.SYNOPSIS
    Downloads the two upstream packages this project is built on:
    scrcpy (win64) and gnirehtet (rust, win64).

.DESCRIPTION
    Both come from the official Genymobile releases on GitHub. Every archive is
    checked against SHA256 before anything is unpacked: first against the hashes
    pinned in this script, and for any other version against the SHA256SUMS.txt
    published in the same release.

    The project's own files (androiddc.ps1, gnirehtet-share.ps1, their
    launchers, README.md, LICENSE, INDEX.md, .gitignore) are never overwritten.

.PARAMETER Destination
    Where the files end up. Defaults to the folder this script sits in.

.PARAMETER ScrcpyVersion
    scrcpy release tag without the leading v. Default 4.1.

.PARAMETER GnirehtetVersion
    gnirehtet release tag without the leading v. Default 2.5.1, which is what
    the binaries in this folder came from.

.PARAMETER GetScrcpy
.PARAMETER GetGnirehtet
    Name the package you want. Either one on its own means "this package and
    nothing else".

.PARAMETER SkipScrcpy
.PARAMETER SkipGnirehtet
    The other way round: leave one of the two alone.

.PARAMETER OnlyMissing
    Look in the destination first and download just the package whose files are
    not there. If both are complete nothing is downloaded at all.

.PARAMETER Force
    Replace files that are already in the destination. Without it, existing
    files are left alone and reported as "already there".

.PARAMETER KeepArchives
    Keep the downloaded .zip files instead of deleting them at the end. Only
    the archives this run used are ever deleted, whatever else is in the folder.

.PARAMETER CacheFolder
    Where the archives are downloaded to. Defaults to a temp folder. An archive
    that is already there with the right hash is not downloaded again.

.EXAMPLE
    .\get-upstream.ps1
    Fills the current folder with scrcpy 4.1 and gnirehtet 2.5.1.

.EXAMPLE
    .\get-upstream.ps1 -Destination D:\tools\scrcpy -SkipGnirehtet -Force

.EXAMPLE
    .\get-upstream.ps1 -GetScrcpy -OnlyMissing
    Downloads scrcpy, and only if it is not already in the folder.

.EXAMPLE
    .\get-upstream.ps1 -OnlyMissing
    Downloads whichever of the two is not already in the folder, and nothing
    else. This is what the GUI runs when a tool turns up missing at startup.
#>

[CmdletBinding()]
param(
    [string]$Destination = $PSScriptRoot,
    [string]$ScrcpyVersion = '4.1',
    [string]$GnirehtetVersion = '2.5.1',
    [switch]$GetScrcpy,
    [switch]$GetGnirehtet,
    [switch]$SkipScrcpy,
    [switch]$SkipGnirehtet,
    [Alias('Missing')]
    [switch]$OnlyMissing,
    [switch]$Force,
    [switch]$KeepArchives,
    [string]$CacheFolder
)

$ErrorActionPreference = 'Stop'

# naming a package is the same as skipping the other one
if ($GetScrcpy -or $GetGnirehtet) {
    $SkipScrcpy = -not $GetScrcpy
    $SkipGnirehtet = -not $GetGnirehtet
}

# --- known good hashes ------------------------------------------------------
# Copied from the SHA256SUMS.txt of each release. A version that is not listed
# here is verified against the SHA256SUMS.txt downloaded next to it.
$knownHashes = @{
    'scrcpy-win64-v4.1.zip'           = '5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db'
    'gnirehtet-rust-win64-v2.5.1.zip' = '7f5b1063e7895182aa60def1437e50363c3758144088dcd079037bb7c3c46a1c'
    'gnirehtet-rust-win64-v2.5.zip'   = '9f6d7700368f45d2fa43923324660eca9f879e837e10fc45d8d975273eae4755'
}

# files that belong to this project and must survive whatever we unpack
$protected = @(
    'androiddc.ps1', 'androiddc.vbs',
    'gnirehtet-gui.ps1', 'gnirehtet-gui.vbs',
    'gnirehtet-share.ps1', 'gnirehtet-share.bat',
    'get-upstream.bat', 'get-upstream.ps1',
    'README.md', 'LICENSE', 'INDEX.md', '.gitignore'
)

# --- small helpers ----------------------------------------------------------

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "   $Text" -ForegroundColor DarkGray }
function Write-Good { param([string]$Text) Write-Host "   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "   $Text" -ForegroundColor Yellow }

function Get-Sha256 {
    # .NET rather than Get-FileHash: when this script is started from
    # PowerShell 7 the child Windows PowerShell inherits a PSModulePath in
    # which Get-FileHash and Expand-Archive cannot be found
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLower()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Expand-Zip {
    param([string]$Archive, [string]$Folder)

    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Folder)
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Save-Download {
    # streamed, so the progress bar means something on a slow line
    param([string]$Uri, [string]$OutFile)

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = 'get-upstream.ps1'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 120000

    $response = $request.GetResponse()
    $total = $response.ContentLength
    $name = Split-Path $Uri -Leaf
    $source = $response.GetResponseStream()
    $target = [System.IO.File]::Create($OutFile)
    try {
        $buffer = New-Object byte[] 262144
        $done = 0
        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $target.Write($buffer, 0, $read)
            $done += $read
            if ($total -gt 0) {
                Write-Progress -Activity "Downloading $name" `
                    -Status ("{0} of {1}" -f (Format-Size $done), (Format-Size $total)) `
                    -PercentComplete ([int](100 * $done / $total))
            }
        }
    } finally {
        $target.Dispose(); $source.Dispose(); $response.Dispose()
        Write-Progress -Activity "Downloading $name" -Completed
    }
    return (Get-Item -LiteralPath $OutFile).Length
}

function Get-ExpectedHash {
    # the pinned hash if we have one, otherwise the release's own SHA256SUMS.txt
    param([string]$AssetName, [string]$SumsUri)

    if ($knownHashes.ContainsKey($AssetName) -and $knownHashes[$AssetName]) {
        Write-Note 'expected hash: pinned in this script'
        return $knownHashes[$AssetName]
    }

    Write-Note 'expected hash: reading the SHA256SUMS.txt of that release'
    try {
        $client = New-Object System.Net.WebClient
        $client.Headers.Add('User-Agent', 'get-upstream.ps1')
        $sums = $client.DownloadString($SumsUri)
    } catch {
        Write-Warn "could not read SHA256SUMS.txt ($($_.Exception.Message))"
        return $null
    }
    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $AssetName) {
            return $Matches[1].ToLower()
        }
    }
    Write-Warn "$AssetName is not listed in SHA256SUMS.txt"
    return $null
}

function Get-Package {
    # downloads one archive, checks it, unpacks it into a temp folder and
    # returns the folder that actually holds the files
    param(
        [string]$Label,
        [string]$AssetName,
        [string]$DownloadUri,
        [string]$SumsUri,
        [string]$WorkFolder
    )

    Write-Step $Label
    Write-Note $DownloadUri

    $archive = Join-Path $CacheFolder $AssetName
    # the only archives the clean-up at the end may delete
    $script:usedArchives += $archive
    $expected = Get-ExpectedHash -AssetName $AssetName -SumsUri $SumsUri

    $needDownload = $true
    if (Test-Path -LiteralPath $archive) {
        $have = Get-Sha256 -Path $archive
        if ($expected -and $have -eq $expected) {
            Write-Good "already downloaded and verified: $archive"
            $needDownload = $false
        } else {
            Write-Note 'the cached copy does not match, downloading again'
            Remove-Item -LiteralPath $archive -Force
        }
    }

    if ($needDownload) {
        try {
            $size = Save-Download -Uri $DownloadUri -OutFile $archive
        } catch [System.Net.WebException] {
            # a half written file would only confuse the next run
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 404) {
                throw "$AssetName does not exist on GitHub. Check the version number - the releases are listed at the project page."
            }
            throw "Download of $AssetName failed: $($_.Exception.Message)"
        }
        Write-Note ("downloaded {0}" -f (Format-Size $size))

        $have = Get-Sha256 -Path $archive
        if ($expected) {
            if ($have -ne $expected) {
                Remove-Item -LiteralPath $archive -Force
                throw "SHA256 mismatch for $AssetName. Expected $expected, got $have. The download was deleted."
            }
            Write-Good 'SHA256 verified'
        } else {
            Write-Warn "no reference hash available, the file hashes to $have"
        }
    }

    # unpack, then step into the single top folder both archives use
    $unpack = Join-Path $WorkFolder ([System.IO.Path]::GetFileNameWithoutExtension($AssetName))
    if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $unpack -Force
    Expand-Zip -Archive $archive -Folder $unpack

    $entries = @(Get-ChildItem -LiteralPath $unpack -Force)
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { return $entries[0].FullName }
    return $unpack
}

function Copy-Into {
    # copies the unpacked files into the destination and says what it did
    param([string]$From, [string]$To)

    $written = New-Object System.Collections.ArrayList
    $kept = New-Object System.Collections.ArrayList

    foreach ($item in (Get-ChildItem -LiteralPath $From -Recurse -File)) {
        $relative = $item.FullName.Substring($From.Length).TrimStart('\')
        $target = Join-Path $To $relative

        if ($protected -contains (Split-Path $relative -Leaf)) {
            Write-Warn "left alone (belongs to this project): $relative"
            $null = $kept.Add($relative)
            continue
        }

        if ((Test-Path -LiteralPath $target) -and -not $Force) {
            $null = $kept.Add($relative)
            continue
        }

        $parent = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        $null = $written.Add($relative)
    }

    foreach ($name in $written) { Write-Good "wrote $name" }
    if ($kept.Count -gt 0) {
        Write-Note ("already there, kept: {0}" -f ($kept -join ', '))
        if (-not $Force) { Write-Note 'run again with -Force to replace them' }
    }
    return [PSCustomObject]@{ Written = $written.Count; Kept = $kept.Count }
}

# --- go ---------------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# $PSScriptRoot is empty when the script is piped in or dot-sourced oddly. The
# current directory is then the only sensible guess, but it is said out loud
# rather than left for someone to discover after the files land elsewhere.
$guessed = $false
if (-not $Destination) {
    $Destination = (Get-Location).Path
    $guessed = $true
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
if (-not (Test-Path -LiteralPath $Destination)) { $null = New-Item -ItemType Directory -Path $Destination -Force }

if (-not $CacheFolder) { $CacheFolder = Join-Path $env:TEMP 'upstream-downloads' }
if (-not (Test-Path -LiteralPath $CacheFolder)) { $null = New-Item -ItemType Directory -Path $CacheFolder -Force }

Write-Host ''
Write-Host 'Upstream packages for AndroidDC' -ForegroundColor White
Write-Note "destination : $Destination"
if ($guessed) {
    Write-Warn 'that is the current directory, because this script could not tell where it lives'
    Write-Warn 'pass -Destination if the files should go somewhere else'
}
Write-Note "archives    : $CacheFolder"

# what each package has to leave behind to count as present
$scrcpyFiles = @('scrcpy.exe', 'scrcpy-server', 'adb.exe')
$gnirehtetFiles = @('gnirehtet.exe', 'gnirehtet.apk')

function Test-PackagePresent {
    param([string[]]$Files)
    foreach ($name in $Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) { return $false }
    }
    return $true
}

# what the caller asked for, before -OnlyMissing narrows it down
$wantScrcpy = -not $SkipScrcpy
$wantGnirehtet = -not $SkipGnirehtet

if ($OnlyMissing) {
    Write-Step 'What is already here'
    if ($wantScrcpy) {
        if (Test-PackagePresent -Files $scrcpyFiles) {
            Write-Good 'scrcpy    : present, nothing to do'
            $SkipScrcpy = $true
        } else {
            Write-Note 'scrcpy    : missing, will be downloaded'
        }
    }
    if ($wantGnirehtet) {
        if (Test-PackagePresent -Files $gnirehtetFiles) {
            Write-Good 'gnirehtet : present, nothing to do'
            $SkipGnirehtet = $true
        } else {
            Write-Note 'gnirehtet : missing, will be downloaded'
        }
    }

    if ($SkipScrcpy -and $SkipGnirehtet) {
        Write-Step 'Result'
        Write-Good 'Nothing to download.'
        Write-Host ''
        exit 0
    }
}

$work = Join-Path $env:TEMP ('upstream-unpack-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force

$summary = @()
$usedArchives = @()
try {
    if (-not $SkipScrcpy) {
        $asset = "scrcpy-win64-v$ScrcpyVersion.zip"
        $folder = Get-Package -Label "scrcpy $ScrcpyVersion (win64)" -AssetName $asset `
            -DownloadUri "https://github.com/Genymobile/scrcpy/releases/download/v$ScrcpyVersion/$asset" `
            -SumsUri "https://github.com/Genymobile/scrcpy/releases/download/v$ScrcpyVersion/SHA256SUMS.txt" `
            -WorkFolder $work
        $moved = Copy-Into -From $folder -To $Destination
        $summary += [PSCustomObject]@{ Package = "scrcpy $ScrcpyVersion"; Written = $moved.Written; Kept = $moved.Kept }
    }

    if (-not $SkipGnirehtet) {
        $asset = "gnirehtet-rust-win64-v$GnirehtetVersion.zip"
        $folder = Get-Package -Label "gnirehtet $GnirehtetVersion (rust, win64)" -AssetName $asset `
            -DownloadUri "https://github.com/Genymobile/gnirehtet/releases/download/v$GnirehtetVersion/$asset" `
            -SumsUri "https://github.com/Genymobile/gnirehtet/releases/download/v$GnirehtetVersion/SHA256SUMS.txt" `
            -WorkFolder $work
        $moved = Copy-Into -From $folder -To $Destination
        $summary += [PSCustomObject]@{ Package = "gnirehtet $GnirehtetVersion"; Written = $moved.Written; Kept = $moved.Kept }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    # the two archives this run used, never "*.zip": -CacheFolder can be any
    # folder, and pointed at Downloads that wildcard emptied it of every zip
    if (-not $KeepArchives) {
        foreach ($file in $usedArchives) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- did we end up with a working set? --------------------------------------

Write-Step 'Result'
$summary | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

# everything the caller asked for has to be on disk now, downloaded or not
$missing = @()
if ($wantScrcpy) { $missing += @($scrcpyFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf) }) }
if ($wantGnirehtet) { $missing += @($gnirehtetFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf) }) }

if ($missing.Count -gt 0) {
    Write-Warn ("still missing: {0}" -f ($missing -join ', '))
    Write-Warn 'run again with -Force if older copies are in the way'
    Write-Host ''
    exit 1
}

Write-Good 'everything the project needs is in place'
Write-Note 'start it with androiddc.vbs'
Write-Host ''
exit 0
