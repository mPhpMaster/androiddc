<#
.SYNOPSIS
    Finds controls that are built but never shown, and buttons with nothing
    behind them.

.DESCRIPTION
    The window is built by hand: every control is created, positioned by an
    Update-*Layout function and added to a parent, all in separate places.
    Two mistakes follow from that and neither one raises anything:

      * a control that is created and laid out but never added to a parent -
        it simply is not on screen, and the layout functions go on placing it
        as if it were;
      * a button that is added, captioned and given a tooltip, but never wired
        to a handler - it looks exactly like the working ones and does nothing
        when clicked.

    Both survive a syntax check, both survive startup, and the layout audit
    counts an orphan as a well behaved control that overlaps nothing.

    Only controls created at the top level are the window's own. Anything
    assigned inside a function is that function's local - the helpers that
    build rows use names like $button and $ok, and treating those as window
    controls is what made the first version of this report useless.

    A control reaches the screen through Controls.Add, TabPages.Add or
    Items.Add, so all three count as a parent.

.PARAMETER Path
    Scripts to check. Defaults to every .ps1 at the repository root, found
    from this file's own location. Files that build no controls are skipped.

.EXAMPLE
    powershell -File .github\audit-wiring.ps1
#>
[CmdletBinding()]
param([string[]]$Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $root = Split-Path -Parent $PSScriptRoot
    $Path = @(Get-ChildItem -LiteralPath $root -Filter *.ps1 -File | ForEach-Object { $_.FullName })
}

# these are never on screen, so "not added to a parent" says nothing about them
$notVisual = @('ToolTip', 'Timer', 'ContextMenuStrip', 'OpenFileDialog', 'SaveFileDialog',
    'FolderBrowserDialog', 'Form', 'ImageList', 'ToolStripSeparator', 'ListViewItem',
    'ColumnHeader', 'MouseEventArgs', 'PaintEventArgs')

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
    $text = Get-Content -LiteralPath $file -Raw

    # every name bound inside any function, so top level can be told apart
    $local = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($fn in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        foreach ($node in $fn.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($node.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $null = $local.Add($node.Left.VariablePath.UserPath)
            }
        }
        foreach ($node in $fn.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
            $null = $local.Add($node.Name.VariablePath.UserPath)
        }
        foreach ($node in $fn.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            $null = $local.Add($node.Variable.VariablePath.UserPath)
        }
    }

    $created = @{}
    $line = @{}
    foreach ($node in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $variable = $node.Left.VariablePath.UserPath
        if ($local.Contains($variable)) { continue }
        if ($node.Right.Extent.Text -match 'New-Object\s+System\.Windows\.Forms\.(\w+)') {
            $created[$variable] = $matches[1]
            $line[$variable] = $node.Extent.StartLineNumber
        }
    }
    if ($created.Count -eq 0) { continue }

    $parented = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($match in [regex]::Matches($text, '\.(?:Controls|TabPages|Items)\.Add(?:Range)?\(\s*\$(\w+)')) {
        $null = $parented.Add($match.Groups[1].Value)
    }

    $broken = 0
    foreach ($variable in ($created.Keys | Sort-Object)) {
        $type = $created[$variable]
        if ($notVisual -contains $type) { continue }

        if (-not $parented.Contains($variable)) {
            Write-Host ("::error file={0},line={1}::`${2} is a {3} that is never added to a parent - it is not on screen" -f
                $name, $line[$variable], $variable, $type)
            $broken++
        }
        # any handler counts; a button driven from the mouse or a key is wired
        if ($type -eq 'Button' -and $text -notmatch ([regex]::Escape('$' + $variable) + '\.Add_\w+')) {
            Write-Host ("::error file={0},line={1}::`${2} is a Button with no handler - clicking it does nothing" -f
                $name, $line[$variable], $variable)
            $broken++
        }
    }

    if ($broken -gt 0) { $failed++ } else { Write-Host "ok  $name - $($created.Count) controls, all shown and all wired" }
}

if ($failed -gt 0) { exit 1 }
Write-Host 'ok  every control reaches the screen and every button has a handler'
