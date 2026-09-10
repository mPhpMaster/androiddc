<#
.SYNOPSIS
    Finds variables that are read but never assigned.

.DESCRIPTION
    The tool runs under Set-StrictMode, so reading a name that was never set is
    a terminating error - not a warning. It happens at the moment the user
    clicks the button, which is the worst possible time to find out.

    Two things produce that name: a typo, and a rename that missed one place.
    Both read identically to the parser, and neither shows up in a syntax
    check, which is why "every .ps1 parses" is not enough on its own.

    This walks the syntax tree instead of running anything, so it needs no
    device, no window and no Windows-only assemblies beyond the parser.

    One rule carries the whole check: only a bare variable on the left of an
    assignment creates it.

        $x = 1          creates $x
        $x.Text = 'a'   reads $x - the property is what is assigned
        $x[0] = 1       reads $x

    Counting the last two as assignments is what let a missed rename through
    when this was first tried: $btnFoo.Text = '...' quietly declared the typo
    to be a definition of itself.

.PARAMETER Path
    Scripts to check. Defaults to every .ps1 beside the repository root,
    worked out from this file's own location - nothing here knows where the
    project lives on any particular machine.

.EXAMPLE
    powershell -File .github\audit-variables.ps1
#>
[CmdletBinding()]
param([string[]]$Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $root = Split-Path -Parent $PSScriptRoot
    # the repository root and this folder; backups\ is not part of the project
    $Path = @(Get-ChildItem -LiteralPath $root -Filter *.ps1 -File) +
            @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File) |
            ForEach-Object { $_.FullName }
}

# PowerShell's own names. The last row is what the engine hands an -Action
# block of Register-ObjectEvent; those are bound for us, not by us.
$builtin = @('_', 'args', 'input', 'this', 'PSItem', 'null', 'true', 'false', 'Error', 'Host',
    'PSScriptRoot', 'MyInvocation', 'PID', 'PSVersionTable', 'ErrorActionPreference', 'PSCommandPath',
    'HOME', 'PWD', 'ExecutionContext', 'StackTrace', 'LASTEXITCODE', 'PSBoundParameters', 'PSCmdlet',
    'OFS', 'env', 'Matches', 'VerbosePreference', 'WarningPreference', 'ProgressPreference',
    'Event', 'EventArgs', 'EventSubscriber', 'Sender', 'SourceEventArgs', 'SourceArgs')

function Add-AssignmentTarget {
    # only a bare variable on the left creates a name; see the comment above
    param($Node, $Names)

    while ($Node -is [System.Management.Automation.Language.AttributedExpressionAst]) { $Node = $Node.Child }

    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($element in $Node.Elements) { Add-AssignmentTarget -Node $element -Names $Names }
        return
    }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $inner = $Node.Pipeline.PipelineElements[0]
        if ($inner -is [System.Management.Automation.Language.CommandExpressionAst]) {
            Add-AssignmentTarget -Node $inner.Expression -Names $Names
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $null = $Names.Add(($Node.VariablePath.UserPath -replace '^(script|global|local|private):', ''))
    }
}

$failed = 0
foreach ($file in $Path) {
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    $name = Split-Path -Leaf $file
    if (@($errors).Count -gt 0) {
        Write-Host "::error file=$name::$(@($errors).Count) parse error(s) - fix those first"
        $failed++
        continue
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        Add-AssignmentTarget -Node $node.Left -Names $names
    }
    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $null = $names.Add($node.Variable.VariablePath.UserPath)
    }
    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        $null = $names.Add($node.Name.VariablePath.UserPath)
    }
    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        # Set-Variable 'x' and [ref]$x both fill a name the parser cannot see
        $command = $node.GetCommandName()
        if ($command -in 'Set-Variable', 'New-Variable') {
            $first = @($node.CommandElements | Select-Object -Skip 1 -First 1)[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $null = $names.Add($first.Value)
            }
        }
        foreach ($element in $node.CommandElements) {
            if ($element -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $element.Type.TypeName.Name -eq 'ref') {
                foreach ($target in $element.FindAll(
                        { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    $null = $names.Add(($target.VariablePath.UserPath -replace '^(script|global|local|private):', ''))
                }
            }
        }
    }

    $unknown = @{}
    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $bare = $node.VariablePath.UserPath -replace '^(script|global|local|private):', ''
        if ($node.VariablePath.UserPath -like 'env:*') { continue }
        if ($builtin -contains $bare) { continue }
        if ($names.Contains($bare)) { continue }
        if (-not $unknown.ContainsKey($bare)) { $unknown[$bare] = @() }
        $unknown[$bare] += $node.Extent.StartLineNumber
    }

    if ($unknown.Count -eq 0) {
        Write-Host "ok  $name"
        continue
    }
    $failed++
    foreach ($bare in ($unknown.Keys | Sort-Object)) {
        $lines = @($unknown[$bare])
        Write-Host ("::error file={0},line={1}::`${2} is read but never assigned (line(s) {3})" -f
            $name, $lines[0], $bare, (($lines | Select-Object -First 6) -join ', '))
    }
}

if ($failed -gt 0) { exit 1 }
Write-Host 'ok  every variable that is read is assigned somewhere'
