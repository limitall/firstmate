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
#
# The teardown area and the delivery area each wrote one of these independently,
# and they landed on the same file. This is the UNION of both: no check from
# either was dropped in the merge.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    $script:BinRoot = Join-Path $script:RepoRoot 'bin'

    function Get-FmModuleFunctionDefinition {
        $files = @(
            foreach ($subdir in @('Private', 'Public')) {
                $dir = Join-Path $script:ModuleRoot $subdir
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
                Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name
            }
        )
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
            # $false = do not descend into nested script blocks, which is the
            # loader's own rule (Firstmate.psm1 parses the same way). Only a
            # TOP-LEVEL definition lands in module scope and can shadow another
            # file's; a helper declared inside a function body - `function
            # local:Fail` appears twice in the lifecycle area - is scoped to
            # its enclosing function and shadows nothing. Flagging those would
            # be a false alarm that trains people to ignore this test.
            foreach ($fn in $ast.FindAll($predicate, $false)) {
                # An explicitly local:/private: scoped name cannot shadow
                # anything either, wherever it is declared.
                if ($fn.Name -match '^(local|private):') { continue }
                [pscustomobject]@{
                    Name = $fn.Name
                    File = $file.Name
                    Line = $fn.Extent.StartLineNumber
                }
            }
        }
    }

    $script:Definitions = @(Get-FmModuleFunctionDefinition)
}

Describe 'module assembly' {
    It 'defines every function name exactly once across Private/ and Public/' {
        $duplicates = @($script:Definitions |
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
        # collision or a load-order dependency actually shows up. The commands
        # named below are one per area, so a file that stops loading is named
        # rather than merely counted.
        $loaded = pwsh -NoProfile -Command @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
foreach (`$subdir in @('Private', 'Public')) {
    `$dir = Join-Path '$script:ModuleRoot' `$subdir
    if (-not (Test-Path -LiteralPath `$dir)) { continue }
    foreach (`$file in (Get-ChildItem -LiteralPath `$dir -Filter '*.ps1' -File | Sort-Object Name)) { . `$file.FullName }
}
foreach (`$name in @('Invoke-FmTeardown', 'Invoke-FmMergeLocal', 'Invoke-FmPromote', 'Invoke-FmFleetSync')) {
    if (-not (Get-Command `$name -ErrorAction SilentlyContinue)) { throw "`$name is missing" }
}
'OK'
"@
        $loaded | Should -Contain 'OK'
    }

    It 'gives every Public file at least one Fm function to export' {
        # Deliberately NOT "the file is named after its function": the repo's
        # layout says one Public file per AREA, and some areas use one file per
        # cmdlet instead. Both are legitimate, so the rule worth enforcing is
        # that no Public file is empty or misfiled.
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File)) {
            $names = @($script:Definitions | Where-Object { $_.File -eq $file.Name -and $_.Name -match '^[A-Za-z]+-Fm' })
            $names.Count | Should -BeGreaterThan 0 -Because "$($file.Name) is in Public/ and should define at least one *-Fm* function"
        }
    }

    It 'uses an approved PowerShell verb for every module function' {
        $approved = @(Get-Verb | ForEach-Object { $_.Verb })
        foreach ($def in $script:Definitions) {
            if ($def.Name -notmatch '^([A-Za-z]+)-') { continue }
            $Matches[1] | Should -BeIn $approved -Because "$($def.Name) in $($def.File) must use an approved verb"
        }
    }
}

Describe 'entry points' {
    It 'parses every bin script' {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:BinRoot -Filter '*.ps1' -File)) {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because "$($file.Name) must parse"
        }
    }

    It 'calls only Fm functions the module actually defines' {
        # An entry point that calls a name no area defines fails at RUN time,
        # in front of the captain, with a "not recognized" error. Catch it here.
        # This is also what catches a cross-area rename: areas bind to each
        # other by name, and bin/ is where that binding is least visible.
        $defined = @($script:Definitions | ForEach-Object { $_.Name })
        $missing = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:BinRoot -Filter '*.ps1' -File)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $localFunctions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
            foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $call.GetCommandName()
                if (-not $name) { continue }
                if ($name -notmatch '^[A-Za-z]+-Fm') { continue }
                if ($defined -contains $name) { continue }
                if ($localFunctions -contains $name) { continue }
                $missing += "$($file.Name) calls $name"
            }
        }
        ($missing -join '; ') | Should -Be ''
    }

    It 'maps outcomes to the documented exit codes: 0 success, 1 refusal, 2 usage' {
        # Run as real child processes, because the exit code IS the entry-point
        # contract and it only exists at process boundaries.
        $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'projects')) {
            New-Item -ItemType Directory -Path (Join-Path $home_ $sub) -Force | Out-Null
        }
        $env_ = @{ FM_HOME = $home_; FM_ROOT_OVERRIDE = $home_ }

        # 2 = usage: the command was called with nothing to act on.
        (Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-merge-local.ps1'))).ExitCode | Should -Be 2

        # 1 = refusal: a real request that this port will not perform.
        (Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-merge-local.ps1'), 'ghost')).ExitCode | Should -Be 1
        (Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-promote.ps1'), 'sometask')).ExitCode | Should -Be 1

        # 0 = success, and the registry it wrote is readable by the parser.
        $create = Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-project-create.ps1'), 'notes', '-Description', 'scratch notes')
        $create.ExitCode | Should -Be 0
        $mode = Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-project-mode.ps1'), 'notes')
        $mode.ExitCode | Should -Be 0
        $mode.StdOut.Trim() | Should -Be 'local-only off'

        # A registered local-only project is skipped by the fleet refresh.
        $sync = Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-fleet-sync.ps1'))
        $sync.ExitCode | Should -Be 0
        $sync.StdOut.Trim() | Should -Be 'notes: skipped: local-only project'

        # Removal without the captain's decision refuses; with it, it lands.
        (Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-project-remove.ps1'), 'notes')).ExitCode | Should -Be 1
        (Invoke-FmChildProcess -FilePath 'pwsh' -Environment $env_ -ArgumentList @('-NoProfile', '-File',
            (Join-Path $script:BinRoot 'fm-project-remove.ps1'), 'notes', '-Approved')).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'projects/notes') | Should -BeFalse
    }

    It 'has an entry point for every delivery and project-management command' {
        foreach ($name in @('fm-merge-local.ps1', 'fm-promote.ps1', 'fm-project-mode.ps1', 'fm-project-add.ps1',
                'fm-project-create.ps1', 'fm-project-remove.ps1', 'fm-fleet-sync.ps1', 'fm-ensure-agents-md.ps1')) {
            Test-Path -LiteralPath (Join-Path $script:BinRoot $name) -PathType Leaf |
                Should -BeTrue -Because "bin/$name is part of this port's command surface"
        }
    }
}
