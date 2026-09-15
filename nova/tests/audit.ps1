<#
.SYNOPSIS
    Checks the shape of AndroidDC Nova without starting it.

.DESCRIPTION
    What would otherwise only show when a person clicks something, or not at all:

      * every .ps1 parses, and is plain ASCII or carries a BOM;
      * every .xaml is well-formed XML;
      * no function is defined twice - pages are dot-sourced into one scope,
        so a second definition silently replaces the first;
      * every x:Name on a page starts with the page's name, so two pages
        cannot claim the same name (the window stops at startup if they do);
      * no absolute path of a PC is written into a file.

    Run directly, not through tests\run.ps1:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\audit.ps1
    It exits with the number of problems found.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$problems = 0
function Report([string]$Text) { Write-Host "  FAIL $Text"; $script:problems++ }

$scripts = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '\\fonts\\' })
$xamls = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.xaml -File)
Write-Host ("read {0} scripts and {1} XAML files" -f $scripts.Count, $xamls.Count)
if ($scripts.Count -eq 0 -or $xamls.Count -eq 0) { Report 'found nothing to check - wrong folder?' }

Write-Host '== scripts parse, ASCII or BOM =='
$definitions = @{}
foreach ($file in $scripts) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) { Report "$relative does not parse: $(@($errors)[0].Message) (line $(@($errors)[0].Extent.StartLineNumber))" }

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $high = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($high -gt 0 -and -not $bom) { Report "$relative has $high non-ASCII bytes and no BOM" }

    # only the program's own files share one scope; tests define helpers of their own
    if ($relative -notlike 'tests\*') {
        foreach ($function in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            $name = $function.Name.ToLowerInvariant()
            if (-not $definitions.ContainsKey($name)) { $definitions[$name] = @() }
            $definitions[$name] += "$relative line $($function.Extent.StartLineNumber)"
        }
    }
}

Write-Host '== no function defined twice =='
foreach ($name in ($definitions.Keys | Sort-Object)) {
    if ($definitions[$name].Count -gt 1) { Report ("{0} is defined {1} times: {2}" -f $name, $definitions[$name].Count, ($definitions[$name] -join '; ')) }
}

Write-Host '== XAML is well-formed, page names carry the page prefix =='
$names = @{}
foreach ($file in $xamls) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    try { $null = [xml]$text } catch { Report "$relative is not well-formed: $($_.Exception.Message)"; continue }

    $page = if ($relative -like 'pages\*') { [IO.Path]::GetFileNameWithoutExtension($file.Name) } else { $null }
    foreach ($match in [regex]::Matches($text, '\bx:Name="([A-Za-z_][A-Za-z0-9_]*)"')) {
        $name = $match.Groups[1].Value
        # template parts (Bd, PART_...) are local to their template
        $inTemplate = $text.LastIndexOf('<ControlTemplate', $match.Index) -gt $text.LastIndexOf('</ControlTemplate>', $match.Index)
        if ($inTemplate) { continue }
        if ($page -and -not $name.StartsWith($page)) { Report "$relative names '$name', which does not start with '$page'" }
        if ($names.ContainsKey($name)) { Report "x:Name '$name' is in both $($names[$name]) and $relative" } else { $names[$name] = $relative }
    }
}

Write-Host '== no absolute path of a PC =='
$pattern = '[A-Za-z]:\\(Users|scrcpy|W\\|laragon)|\\AppData\\Local\\Temp\\claude'
foreach ($file in @($scripts + $xamls + @(Get-ChildItem -LiteralPath $root -Filter *.md -File))) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $hits = @(Select-String -LiteralPath $file.FullName -Pattern $pattern)
    foreach ($hit in $hits) { Report "$relative line $($hit.LineNumber) holds a local path" }
}

Write-Host ''
if ($problems -eq 0) { Write-Host 'audit: no problems' } else { Write-Host "audit: $problems problem(s)" }
exit $problems
