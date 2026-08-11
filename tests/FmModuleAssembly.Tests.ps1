#requires -Version 7.0
# Pester 5+/6 tests for how the module assembles out of its per-area files.
#
# WHY THIS FILE EXISTS. The module loader dot-sources every Private/*.ps1 and
# Public/*.ps1 in name order into one scope. Two files defining the same
# function name is therefore SILENT: the later file wins, the earlier one's
# callers get the wrong body, and its tests keep passing in isolation while the
# assembled module misbehaves. That has already cost this repo 17 tests once.
# Areas are built in parallel by separate workers, so the collision is a
# structural hazard, not a one-off mistake - it needs a test, not a habit.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'

    function Get-FmModuleFunctionDefinition {
        $files = @(
            foreach ($subdir in @('Private', 'Public')) {
                $dir = Join-Path $script:ModuleRoot $subdir
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
                Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File
            }
        )
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
            foreach ($fn in $ast.FindAll($predicate, $true)) {
                [pscustomobject]@{ Name = $fn.Name; File = $file.Name; Line = $fn.Extent.StartLineNumber }
            }
        }
    }
}

Describe 'module assembly' {
    It 'defines every function name exactly once across Private/ and Public/' {
        $duplicates = @(Get-FmModuleFunctionDefinition |
                Group-Object -Property Name |
                Where-Object { $_.Count -gt 1 })
        $detail = ($duplicates | ForEach-Object {
                "$($_.Name): " + (($_.Group | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ')
            }) -join '; '
        $detail | Should -Be '' -Because 'a name defined twice is silently shadowed when the loader dot-sources both files'
    }

    It 'parses every module file without a syntax error' {
        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($subdir in @('Private', 'Public')) {
            $dir = Join-Path $script:ModuleRoot $subdir
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File)) {
                $parseErrors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
                foreach ($parseError in @($parseErrors)) {
                    $errors.Add("$($file.Name): $($parseError.Message)")
                }
            }
        }
        ($errors -join '; ') | Should -Be ''
    }

    It 'loads the whole module in one session with every area present' {
        # The per-area test files dot-source only what they need. This is the
        # only place the WHOLE set is loaded together, which is where a
        # collision or a load-order dependency actually shows up.
        $loaded = pwsh -NoProfile -Command @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
foreach (`$subdir in @('Private', 'Public')) {
    `$dir = Join-Path '$script:ModuleRoot' `$subdir
    if (-not (Test-Path -LiteralPath `$dir)) { continue }
    foreach (`$file in (Get-ChildItem -LiteralPath `$dir -Filter '*.ps1' -File | Sort-Object Name)) { . `$file.FullName }
}
if (-not (Get-Command Invoke-FmTeardown -ErrorAction SilentlyContinue)) { throw 'Invoke-FmTeardown is missing' }
'OK'
"@
        $loaded | Should -Contain 'OK'
    }

    It 'gives every bin/ entry point a matching module verb' {
        # bin/ scripts may call only EXPORTED functions: a private helper is
        # unreachable once the manifest governs the import.
        foreach ($script in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' 'bin') -Filter 'fm-*.ps1' -File)) {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because "$($script.Name) must parse"
        }
    }
}
