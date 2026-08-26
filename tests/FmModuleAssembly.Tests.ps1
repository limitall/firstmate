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
# The teardown, delivery, backlog and install areas each wrote one of these
# independently, and they all landed on this file. This is the UNION of all
# four: no check from any of them was dropped in the merge.
#
# The same reasoning covers the other cross-area breaks, each invisible until
# two areas are combined:
#   - a bin/ entry point calling a function the manifest does not export, which
#     works while the entry point dot-sources the module and stops working the
#     moment the manifest governs the import,
#   - a manifest that does not import at all,
#   - a Public file whose functions never reach the exported surface,
#   - a by-name cross-area call whose owner does not declare the parameters the
#     caller passes.
#
# Everything here is derived by parsing the tree, so a new area is covered the
# moment its files exist.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    $script:BinRoot = Join-Path $script:RepoRoot 'bin'
    $script:Manifest = Join-Path $script:ModuleRoot 'Firstmate.psd1'

    function Get-FmModuleScriptFile {
        param([string]$Subdir)
        $dir = Join-Path $script:ModuleRoot $Subdir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
        @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object -Property Name)
    }

    function Get-FmModuleFunctionDefinition {
        $files = @(Get-FmModuleScriptFile -Subdir 'Private') + @(Get-FmModuleScriptFile -Subdir 'Public')
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

    # This file deliberately ANALYSES the module rather than loading it: a
    # collision or a syntax error must be diagnosed as itself, not as a load
    # failure in the test session. So the entry-point runs below use their own
    # child-process helper rather than the module's Invoke-FmChildProcess.
    function Invoke-TestEntryPoint {
        param(
            [Parameter(Mandatory)][string]$Script,
            [string[]]$CliArgs = @(),
            [hashtable]$Environment = @{}
        )
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        # -NonInteractive because this child does NOT inherit its parent's: an
        # entry point that prompts would ask on whatever console the suite was
        # started from, which is the captain's own during an install. See
        # Invoke-FmMachineSuite for the measurement.
        foreach ($a in (@('-NoProfile', '-NonInteractive', '-File', (Join-Path $script:BinRoot $Script)) + $CliArgs)) {
            $psi.ArgumentList.Add([string]$a)
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
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
            foreach ($file in (Get-FmModuleScriptFile -Subdir $subdir)) {
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

    It 'gives every module function the Fm prefix' {
        # Every top-level name lands in one shared scope, so an unprefixed helper
        # from one area is a collision waiting for the next area that wants that
        # word. The prefix is what makes the duplicate check above rare.
        foreach ($definition in $script:Definitions) {
            $definition.Name | Should -Match '^[A-Za-z]+-Fm' -Because "$($definition.File):$($definition.Line)"
        }
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

Describe 'the module manifest' {
    It 'has a manifest and a loader' {
        Test-Path -LiteralPath $script:Manifest -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $script:ModuleRoot -ChildPath 'Firstmate.psm1') -PathType Leaf |
            Should -BeTrue
    }

    It 'imports from the manifest without error' {
        { Import-Module -Name $script:Manifest -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'every function it exports is actually defined in the tree' {
        Import-Module -Name $script:Manifest -Force -ErrorAction Stop
        $defined = @(Get-FmModuleFunctionDefinition).Name
        $exported = @(Get-Command -Module Firstmate -CommandType Function)
        $exported.Count | Should -BeGreaterThan 0
        foreach ($cmd in $exported) {
            $defined | Should -Contain $cmd.Name -Because "$($cmd.Name) is exported"
        }
    }

    It 'exports every top-level function defined in Public/' {
        # The loader discovers the exported set by parsing Public/*.ps1, so a
        # Public file that never reaches the surface means the manifest and the
        # loader disagree.
        Import-Module -Name $script:Manifest -Force -ErrorAction Stop
        $exported = @(Get-Command -Module Firstmate -CommandType Function).Name
        foreach ($file in (Get-FmModuleScriptFile -Subdir 'Public')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
            foreach ($fn in $ast.FindAll($predicate, $false)) {
                $exported | Should -Contain $fn.Name -Because "$($file.Name) is a Public file"
            }
        }
    }
}

Describe 'entry points' {
    BeforeAll {
        Import-Module -Name $script:Manifest -Force -ErrorAction Stop
        $script:Exported = @(Get-Command -Module Firstmate -CommandType Function).Name

        # fm-module-load.ps1 is a shared prelude that entry points dot-source,
        # not an entry point itself.
        $script:EntryPoints = @(Get-ChildItem -LiteralPath $script:BinRoot -Filter 'fm-*.ps1' -File |
                Where-Object { $_.Name -ne 'fm-module-load.ps1' } | Sort-Object -Property Name)
    }

    It 'there is at least one entry point' {
        $script:EntryPoints.Count | Should -BeGreaterThan 0
    }

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
        (Invoke-TestEntryPoint -Script 'fm-merge-local.ps1' -Environment $env_).ExitCode | Should -Be 2

        # 1 = refusal: a real request that this port will not perform.
        (Invoke-TestEntryPoint -Script 'fm-merge-local.ps1' -CliArgs @('ghost') -Environment $env_).ExitCode |
            Should -Be 1
        (Invoke-TestEntryPoint -Script 'fm-promote.ps1' -CliArgs @('sometask') -Environment $env_).ExitCode |
            Should -Be 1

        # 0 = success, and the registry it wrote is readable by the parser.
        $create = Invoke-TestEntryPoint -Script 'fm-project-create.ps1' -Environment $env_ `
            -CliArgs @('notes', '-Description', 'scratch notes')
        $create.ExitCode | Should -Be 0
        $mode = Invoke-TestEntryPoint -Script 'fm-project-mode.ps1' -CliArgs @('notes') -Environment $env_
        $mode.ExitCode | Should -Be 0
        $mode.StdOut.Trim() | Should -Be 'local-only off'

        # A registered local-only project is skipped by the fleet refresh.
        $sync = Invoke-TestEntryPoint -Script 'fm-fleet-sync.ps1' -Environment $env_
        $sync.ExitCode | Should -Be 0
        $sync.StdOut.Trim() | Should -Be 'notes: skipped: local-only project'

        # Removal without the captain's decision refuses; with it, it lands.
        (Invoke-TestEntryPoint -Script 'fm-project-remove.ps1' -CliArgs @('notes') -Environment $env_).ExitCode |
            Should -Be 1
        (Invoke-TestEntryPoint -Script 'fm-project-remove.ps1' -CliArgs @('notes', '-Approved') -Environment $env_).ExitCode |
            Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'projects/notes') | Should -BeFalse
    }

    It 'has an entry point for every delivery and project-management command' {
        foreach ($name in @('fm-merge-local.ps1', 'fm-promote.ps1', 'fm-project-mode.ps1', 'fm-project-add.ps1',
                'fm-project-create.ps1', 'fm-project-remove.ps1', 'fm-fleet-sync.ps1', 'fm-ensure-agents-md.ps1')) {
            Test-Path -LiteralPath (Join-Path $script:BinRoot $name) -PathType Leaf |
                Should -BeTrue -Because "bin/$name is part of this port's command surface"
        }
    }

    It 'resolves the module through the ONE shared prelude in every bin/ entry point' {
        # Three conventions used to be in use - the shared prelude, importing the
        # manifest inline, and an inline dot-source of Private then Public. Two
        # of them looked equivalent and were not: only the prelude puts module/
        # on PSModulePath and publishes the resolved home, so the entry points
        # using the other two worked in the captain's shell and failed in a
        # herdr pane. There is one way now, and this is what keeps it that way.
        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $script:BinRoot -Filter 'fm-*.ps1' -File)) {
            if ($file.Name -eq 'fm-module-load.ps1') { continue }
            $text = [System.IO.File]::ReadAllText($file.FullName)
            if ($text -notmatch "\.\s+\(Join-Path\s+\`$PSScriptRoot\s+'fm-module-load\.ps1'\)\s+-RequiredCommand\s+'[A-Za-z]+-Fm[A-Za-z]+'") {
                $offenders += "$($file.Name): does not dot-source fm-module-load.ps1 with -RequiredCommand"
                continue
            }
            # An entry point that ALSO imports the manifest its own way is back
            # to two mechanisms, and the second one wins whatever the first did.
            if ($text -match '(?m)^\s*Import-Module') {
                $offenders += "$($file.Name): imports the module a second way"
            }
        }
        ($offenders -join '; ') | Should -Be ''
    }

    It 'names a command the module exports in every entry point prelude call' {
        # -RequiredCommand is what decides whether the dot-source fallback fires.
        # A misspelled or renamed name is silent: the manifest import satisfies
        # the call anyway, and the fallback stops covering the partial build it
        # exists for.
        $wrong = @()
        foreach ($file in $script:EntryPoints) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $m = [regex]::Match($text, "fm-module-load\.ps1'\)\s+-RequiredCommand\s+'([A-Za-z]+-Fm[A-Za-z]+)'")
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value
            if ($script:Exported -notcontains $name) { $wrong += "$($file.Name) requires $name, which is not exported" }
            if ($text -notmatch [regex]::Escape($name) + '\s') { $wrong += "$($file.Name) requires $name but never calls it" }
        }
        ($wrong -join '; ') | Should -Be ''
    }

    It 'pins PowerShell 7 and strict mode in every bin/ entry point' {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:BinRoot -Filter 'fm-*.ps1' -File)) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $text | Should -Match '#requires -Version 7\.0' -Because $file.Name
            if ($file.Name -eq 'fm-module-load.ps1') { continue }
            $text | Should -Match 'Set-StrictMode -Version Latest' -Because $file.Name
        }
    }

    It 'every entry point calls only EXPORTED functions' {
        # AGENTS.md: an entry point may only call exported functions, because a
        # private helper becomes unreachable as soon as the manifest governs the
        # import rather than a dot-source fallback. Enumerated from the tree, so
        # a new entry point is covered the moment it exists.
        $unreachable = [System.Collections.Generic.List[string]]::new()
        foreach ($script in $script:EntryPoints) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$null)
            # A helper the entry point DEFINES is not a module call at all, so it
            # needs no export - fm-backlog.ps1's own usage and formatting helpers
            # are the live example. Without this the check reports them as
            # unreachable and the real finding is lost in the noise.
            $ownFunctions = @($ast.FindAll(
                    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                    ForEach-Object { $_.Name })
            $predicate = { param($node) $node -is [System.Management.Automation.Language.CommandAst] }
            $calls = @($ast.FindAll($predicate, $true) |
                    ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $_ -and $_ -match '^[A-Za-z]+-Fm' } |
                    Select-Object -Unique)
            foreach ($call in $calls) {
                if ($ownFunctions -contains $call) { continue }
                if ($script:Exported -notcontains $call) { $unreachable.Add("$($script.Name) calls $call") }
            }
        }
        ($unreachable -join '; ') | Should -Be '' -Because 'only exported functions are reachable through the manifest'
    }
}

Describe 'the two entry points at the repo root' {
    # install.ps1 and start.ps1 are the captain's own commands rather than
    # firstmate's, so they live at the root and not in bin/. They were outside
    # every check above for exactly that reason, which is how install.ps1 came to
    # carry its own second install table - one that named the wrong npm packages
    # for two of the tools and went unnoticed until a real machine ran it.
    BeforeAll {
        Import-Module -Name $script:Manifest -Force -ErrorAction Stop
        $script:RootExported = @(Get-Command -Module Firstmate -CommandType Function).Name
        $script:RootScripts = @('install.ps1', 'start.ps1' | ForEach-Object {
                Get-Item -LiteralPath (Join-Path $script:RepoRoot $_)
            })
    }

    It 'ships both of them' {
        foreach ($script in $script:RootScripts) { $script.Exists | Should -BeTrue }
    }

    It 'parses both of them' {
        foreach ($script in $script:RootScripts) {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because "$($script.Name) must parse"
        }
    }

    It 'resolves the module through the ONE shared prelude, naming a command the module exports' {
        foreach ($script in $script:RootScripts) {
            $text = [System.IO.File]::ReadAllText($script.FullName)
            $match = [regex]::Match($text, "fm-module-load\.ps1'\)\s+-RequiredCommand\s+'([A-Za-z]+-Fm[A-Za-z]+)'")
            if (-not $match.Success) { continue }
            $script:RootExported | Should -Contain $match.Groups[1].Value -Because "$($script.Name) requires it"
        }
    }

    It 'calls only Fm functions the module actually defines' {
        $defined = @($script:Definitions | ForEach-Object { $_.Name })
        $missing = @()
        foreach ($script in $script:RootScripts) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$null)
            foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $call.GetCommandName()
                if (-not $name -or $name -notmatch '^[A-Za-z]+-Fm') { continue }
                if ($defined -notcontains $name) { $missing += "$($script.Name) calls $name" }
            }
        }
        ($missing -join '; ') | Should -Be ''
    }

    It 'pins strict mode in both, and lets NEITHER carry a #requires the wrong shell answers for it' {
        # Both deliberately carry NO #requires. A clean Windows machine opens
        # Windows PowerShell 5.1, where the directive produces "cannot be run
        # because it contained a '#requires' statement" and nothing about what to
        # do next. install.ps1 met that first and has checked $PSVersionTable
        # itself ever since.
        #
        # start.ps1 joined it after the captain's first SUCCESSFUL install: they
        # typed .\start.ps1 in the 5.1 window they had just installed from and
        # got the raw version mismatch, on a machine that already had PowerShell
        # 7 on it. Only the window was wrong, which is something the script can
        # fix, so it checks the version itself and switches shells.
        $install = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'install.ps1'))
        $start = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'start.ps1'))
        # Anchored to the start of a line, which is the only place PowerShell
        # honours the directive; the files talk ABOUT #requires in their own
        # comments, and that prose must not read as the statement itself.
        foreach ($text in @($install, $start)) {
            $text | Should -Not -Match '(?m)^#requires'
            $text | Should -Match '\$PSVersionTable\.PSVersion\.Major -lt 7'
            $text | Should -Match 'Set-StrictMode -Version Latest'
        }
    }

    It 'keeps both parseable by Windows PowerShell 5.1, which is the shell they will meet first' {
        # A version check is useless if the file cannot be parsed to reach it.
        # 5.1 is not present on every machine this repo is developed on, so the
        # check is skipped rather than silently passing where it cannot run.
        $windowsPowerShell = Join-Path $env:WINDIR 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        if (-not ($IsWindows -and (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf))) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        $probe = 'param($Path) $e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$e); if ($e) { $e[0].Message } else { "OK" }'
        $probeFile = Join-Path $TestDrive 'parse-probe.ps1'
        [System.IO.File]::WriteAllText($probeFile, $probe)
        foreach ($name in @('install.ps1', 'start.ps1')) {
            $result = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $probeFile -Path (Join-Path $script:RepoRoot $name)
            ($result -join ' ') | Should -Be 'OK' -Because "$name has to parse under 5.1 to reach its own version check"
        }
    }
}

Describe 'start.ps1 in the shell a clean machine actually opens' {
    # WHY THIS EXISTS. The captain's first SUCCESSFUL install ended on an error.
    # They typed .\start.ps1 in the Windows PowerShell 5.1 window they had just
    # run the installer from, and got
    #
    #     The script 'start.ps1' cannot be run because it contained a "#requires"
    #     statement for Windows PowerShell 7.0.
    #
    # which is accurate, is not firstmate speaking, and says nothing about what
    # to do. The machine was fine - install.ps1 had already put PowerShell 7 on
    # it - and only the window was wrong.
    #
    # So this does not check what start.ps1 SAYS about itself. It RUNS it, on the
    # shell a clean machine opens, and measures what the captain gets.
    #
    # NOTHING IS STARTED HERE. A stub `pwsh` at the front of PATH takes the
    # relaunch, so what is measured is the command start.ps1 builds rather than a
    # bridge and a browser. The second case has no pwsh to find at all.
    BeforeAll {
        $script:WindowsPowerShell = Join-Path $env:WINDIR 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        $script:StartScript = Join-Path $script:RepoRoot 'start.ps1'

        function Test-FiveOneAvailable {
            $IsWindows -and (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf)
        }

        # Runs a command in a real Windows PowerShell 5.1, with the environment
        # this case is about, and hands back everything it printed.
        function Invoke-FiveOne {
            param([Parameter(Mandatory)][string]$Command)
            $output = & $script:WindowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Text     = (@($output | ForEach-Object { [string]$_ }) -join "`n")
            }
        }
    }

    It 'switches to PowerShell 7 and carries the captain arguments across' {
        if (-not (Test-FiveOneAvailable)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        # A stub named pwsh.cmd, which Get-Command -Name 'pwsh' resolves exactly
        # as it resolves the real executable. It prints its arguments and exits,
        # so the relaunch is measured without anything starting.
        $stubDir = Join-Path $TestDrive 'stub-shell'
        $null = New-Item -ItemType Directory -Path $stubDir -Force
        [System.IO.File]::WriteAllText((Join-Path $stubDir 'pwsh.cmd'), "@echo off`r`necho FM-RELAUNCH %*`r`n")

        $result = Invoke-FiveOne -Command "`$env:PATH = '$stubDir;' + `$env:PATH; & '$($script:StartScript)' -Port 9111"

        $result.Text | Should -Not -Match '#requires' -Because 'the raw version mismatch is what this replaced'
        $result.Text | Should -Match 'FIRSTMATE' -Because "the captain must hear firstmate's own voice, not PowerShell's"
        $result.Text | Should -Match 'FM-RELAUNCH' -Because 'it must actually switch shells rather than only explain'
        $result.Text | Should -Match '-File .*start\.ps1'
        $result.Text | Should -Match '-Port 9111' -Because 'the captain arguments have to survive the switch'
    }

    It 'relaunches once and never twice, so a pwsh that is not 7 cannot become a fork bomb' {
        if (-not (Test-FiveOneAvailable)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        # PowerShell 6 is ALSO called pwsh. Without the marker, a machine
        # carrying it resolves a shell still below 7, which arrives back at this
        # guard and relaunches again, with nothing bounding it. The marker is
        # what a child inherits, so this asserts the SECOND arrival refuses -
        # with a stub pwsh present, which is the case that would otherwise spawn.
        $stubDir = Join-Path $TestDrive 'stub-loop'
        $null = New-Item -ItemType Directory -Path $stubDir -Force
        [System.IO.File]::WriteAllText((Join-Path $stubDir 'pwsh.cmd'), "@echo off`r`necho FM-RELAUNCH %*`r`n")

        $result = Invoke-FiveOne -Command ("`$env:PATH = '$stubDir;' + `$env:PATH; " +
            "`$env:FM_SHELL_RELAUNCHED = '1'; & '$($script:StartScript)'")

        $result.Text | Should -Not -Match 'FM-RELAUNCH' -Because 'a second arrival must not spawn a third'
        $result.Text | Should -Match 'stopping rather than doing it again'
        $result.Text | Should -Match 'install\.ps1' -Because 'the captain still needs the way out'
        $result.ExitCode | Should -Be 1
    }

    It 'names the one command that installs PowerShell 7, when there is none to switch to' {
        if (-not (Test-FiveOneAvailable)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        # No pwsh on PATH and nothing in the per-user location install.ps1 uses.
        # That is a machine nobody has set up, not a wrong window, and start.ps1
        # installs NOTHING - install.ps1 is the one thing that installs.
        $emptyLocal = Join-Path $TestDrive 'empty-localappdata'
        $null = New-Item -ItemType Directory -Path $emptyLocal -Force
        $result = Invoke-FiveOne -Command ("`$env:PATH = '$([System.IO.Path]::Combine($env:WINDIR, 'System32'))'; " +
            "`$env:LOCALAPPDATA = '$emptyLocal'; & '$($script:StartScript)'")

        $result.Text | Should -Not -Match '#requires'
        $result.Text | Should -Match 'PowerShell 7 is not on this machine'
        $result.Text | Should -Match 'install\.ps1'
        $result.ExitCode | Should -Be 1 -Because 'nothing started, and a refusal is not a success'
    }
}

Describe 'the first command README gives a newcomer' {
    # WHY THIS EXISTS. Windows ships with script execution switched off, and
    # README's first instruction was a bare `.\install.ps1`. On the captain's
    # clean Windows 11 machine, 2026-08-20, before anything else could go wrong:
    #
    #     .\install.ps1 : File ...\install.ps1 cannot be loaded because running
    #     scripts is disabled on this system.
    #
    # The very first thing our own instructions tell a newcomer to type could
    # not run. So this does not check what README SAYS - it takes the command
    # README gives and RUNS it, on the shell a clean machine actually opens,
    # with scripts disabled exactly as they are out of the box.
    BeforeAll {
        $script:WindowsPowerShell = Join-Path $env:WINDIR 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        $script:ReadmeCommand = ''
        $readme = @([System.IO.File]::ReadAllLines((Join-Path $script:RepoRoot 'README.md')))
        $inBlock = $false
        foreach ($line in $readme) {
            if ($line -match '^```') { if ($inBlock) { break }; $inBlock = $true; continue }
            if ($inBlock -and $line -match 'install\.ps1') { $script:ReadmeCommand = $line.Trim(); break }
        }

        # A Group Policy that pins the execution policy would override the
        # -ExecutionPolicy the tests below pass to their children, and both
        # would then be measuring the policy rather than the command.
        $script:PolicyForced = @(Get-ExecutionPolicy -List |
                Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' }).Count -gt 0

        function Invoke-CleanMachineShell {
            param([Parameter(Mandatory)][string]$Command)
            # -ExecutionPolicy Restricted is what a clean Windows client has, and
            # it is passed to a CHILD process: no machine setting is changed.
            $output = & $script:WindowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Restricted `
                -Command "Set-Location -LiteralPath '$($script:RepoRoot)'; $Command" 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (@($output | ForEach-Object { [string]$_ }) -join "`n") }
        }
    }

    It 'gives one, inside its first code block' {
        $script:ReadmeCommand | Should -Not -BeNullOrEmpty -Because 'README opens with the command a newcomer types first'
    }

    It 'runs it, on a machine where running scripts is disabled' {
        if (-not ($IsWindows -and (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf))) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        if ($script:PolicyForced) {
            Set-ItResult -Skipped -Because 'a Group Policy pins the execution policy, so a child cannot be given the clean-machine one'
            return
        }
        # -DetectOnly -Offline: it must REACH its own work and change nothing,
        # which is the whole claim - not that some error text was different.
        $result = Invoke-CleanMachineShell -Command "$($script:ReadmeCommand) -DetectOnly -Offline"
        $result.Text | Should -Not -Match 'running scripts is disabled'
        $result.Text | Should -Match 'what this machine has'
        $result.Text | Should -Match '-DetectOnly: nothing was installed and nothing was left changed'
        # The location preflight is the first thing that runs, and it is the one
        # part of detection that WRITES - a probe directory it then removes. If
        # that write were refused here, this is where it would surface.
        $result.Text | Should -Not -Match 'THIS CHECKOUT IS SOMEWHERE THE INSTALL CANNOT FINISH'
        $result.ExitCode | Should -Be 0
    }

    It 'and the bare form README used to give really does fail there' {
        # The negative control. Without it this file would keep passing if
        # README regressed AND the policy stopped mattering, and would prove
        # nothing about either.
        if (-not ($IsWindows -and (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf))) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        if ($script:PolicyForced) {
            Set-ItResult -Skipped -Because 'a Group Policy pins the execution policy, so a child cannot be given the clean-machine one'
            return
        }
        $result = Invoke-CleanMachineShell -Command '.\install.ps1 -DetectOnly -Offline'
        $result.Text | Should -Match 'running scripts is disabled'
    }
}

Describe 'cross-area bindings' {
    # WHY THIS EXISTS. Areas bind to each other by NAME at call time:
    #
    #     $cmd = Resolve-FmSessionCommand -Name 'Get-FmMetaValue'
    #     if ($cmd) { return (& $cmd -Path $Path -Key $Key) }
    #
    # If the owner does not declare -Path, that call throws, the caller's catch
    # reads the throw as "no owner", and it takes its degraded path forever
    # while every test still passes. That is exactly how the turn-end guard came
    # to fail OPEN on every turn. Worse, when the owner is a SIMPLE function the
    # call does not even throw: the unmatched arguments land in $args and are
    # dropped, so it succeeds having silently discarded its input.
    #
    # Neither failure conflicts in git and neither fails to compile, so nothing
    # else in this repo can catch them. This reads the call sites out of the AST
    # and checks them against the owners actually present in the tree.
    BeforeAll {
        function Get-FmModuleFunctionSignature {
            $out = @{}
            foreach ($subdir in @('Private', 'Public')) {
                foreach ($file in (Get-FmModuleScriptFile -Subdir $subdir)) {
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                    foreach ($fn in $ast.FindAll(
                            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                        $params = @()
                        $advanced = $false
                        $mandatory = @()
                        $block = $fn.Body.ParamBlock
                        if ($block) {
                            foreach ($attr in $block.Attributes) {
                                if ($attr.TypeName.Name -in 'CmdletBinding', 'CmdletBindingAttribute') { $advanced = $true }
                            }
                            foreach ($p in $block.Parameters) {
                                $name = $p.Name.VariablePath.UserPath
                                $params += $name
                                foreach ($a in $p.Attributes) {
                                    if ($a.TypeName.Name -notin 'Parameter', 'ParameterAttribute') { continue }
                                    $advanced = $true
                                    foreach ($arg in $a.NamedArguments) {
                                        if ($arg.ArgumentName -eq 'Mandatory') { $mandatory += $name }
                                    }
                                }
                            }
                        }
                        $out[$fn.Name] = [pscustomobject]@{
                            Name = $fn.Name; File = $file.Name; Params = $params
                            Advanced = $advanced; Mandatory = $mandatory
                        }
                    }
                }
            }
            $out
        }

        # A resolve may list SEVERAL candidate owners in preference order, and
        # the caller then branches on which one it got:
        #
        #   $owner = Resolve-FmSessionCommand -Name 'Get-FmXObject', 'Get-FmX'
        #   $w = if ($owner.Name -eq 'Get-FmX') { & $owner -AsObject } else { & $owner }
        #
        # Charging -AsObject to BOTH candidates invents a mismatch against the
        # one the branch never passes it to. So when a call sits inside an `if`
        # whose condition names candidates, it is charged only to those; inside
        # the `else`, only to the ones the conditions ruled out.
        function Get-FmGuardedCandidate {
            param($Call, [string[]]$Candidate)
            if ($Candidate.Count -le 1) { return $Candidate }
            $node = $Call
            while ($node.Parent) {
                $parent = $node.Parent
                if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                    $start = $Call.Extent.StartOffset
                    $end = $Call.Extent.EndOffset
                    $ruledOut = @()
                    foreach ($clause in $parent.Clauses) {
                        $named = @($Candidate | Where-Object { $clause.Item1.Extent.Text -match [regex]::Escape("'$_'") })
                        $ruledOut += $named
                        if ($clause.Item2.Extent.StartOffset -le $start -and $end -le $clause.Item2.Extent.EndOffset) {
                            if ($named.Count) { return $named }
                        }
                    }
                    if ($parent.ElseClause -and $ruledOut.Count -and
                        $parent.ElseClause.Extent.StartOffset -le $start -and $end -le $parent.ElseClause.Extent.EndOffset) {
                        $rest = @($Candidate | Where-Object { $ruledOut -notcontains $_ })
                        if ($rest.Count) { return $rest }
                    }
                }
                $node = $parent
            }
            return $Candidate
        }

        # Every `& $var -Foo ...` whose $var came from a Resolve-Fm*Command with
        # a LITERAL owner name. A resolve through a variable name cannot be
        # settled statically and is skipped rather than guessed at.
        function Get-FmByNameCallSite {
            $sites = [System.Collections.Generic.List[object]]::new()
            foreach ($subdir in @('Private', 'Public')) {
                foreach ($file in (Get-FmModuleScriptFile -Subdir $subdir)) {
                    $text = [System.IO.File]::ReadAllText($file.FullName)
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

                    $assigns = @()
                    foreach ($m in [regex]::Matches($text,
                            '\$(?<var>\w+)\s*=\s*Resolve-Fm\w*(?:Command|Owner)\s+-Name\s+(?<names>(''[^'']+''\s*,?\s*)+)')) {
                        $line = ($text.Substring(0, $m.Index) -split "`n").Count
                        $names = @([regex]::Matches($m.Groups['names'].Value, "'([^']+)'") |
                                ForEach-Object { $_.Groups[1].Value })
                        $assigns += [pscustomobject]@{ Var = $m.Groups['var'].Value; Line = $line; Names = $names }
                    }
                    if ($assigns.Count -eq 0) { continue }

                    foreach ($call in $ast.FindAll(
                            { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                        $head = $call.CommandElements[0]
                        if ($head -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                        $var = $head.VariablePath.UserPath
                        $callLine = $call.Extent.StartLineNumber
                        # The NEAREST PRECEDING assignment, not the last one in
                        # the file: FmSessionStart.ps1 reassigns $probe from one
                        # owner to another a few lines apart, and a last-wins map
                        # invents a mismatch that is not there.
                        $bound = @($assigns | Where-Object { $_.Var -eq $var -and $_.Line -le $callLine } |
                                Sort-Object Line | Select-Object -Last 1)
                        if ($bound.Count -eq 0) { continue }
                        $used = @($call.CommandElements |
                                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                                ForEach-Object { $_.ParameterName })
                        if ($used.Count -eq 0) { continue }
                        foreach ($target in (Get-FmGuardedCandidate -Call $call -Candidate $bound[0].Names)) {
                            $sites.Add([pscustomobject]@{
                                    File = $file.Name; Line = $callLine; Target = $target; Used = $used
                                })
                        }
                    }
                }
            }
            $sites
        }

        # Every LITERAL by-name target in the tree, whatever mechanism binds it.
        # Four are in use and each one is a live hazard, so all four are read:
        #   Resolve-Fm*Command / Resolve-Fm*Owner -Name 'X'
        #                                        (the session/bootstrap and
        #                                         teardown seams)
        #   Invoke-FmSeam / Test-FmSeam -Name 'X' (the watcher seam)
        #   -CommandName 'X' / @('X', 'Y')       (the composed-step helpers)
        #   Get-Command -Name X-FmY              (the direct probe)
        #
        # ...Owner was added after a gate shipped bound to two owner names that
        # nothing defined: teardown resolves through Resolve-FmTeardownOwner, so
        # every one of its by-name targets was invisible here - neither checked
        # against the tree nor forced into the registry below.
        function Get-FmByNameTarget {
            $found = [System.Collections.Generic.List[object]]::new()
            $patterns = @(
                "Resolve-Fm\w*(?:Command|Owner)\s+-Name\s+(?<names>('[^']+'\s*,?\s*)+)"
                "Invoke-FmSeam\s+-Name\s+(?<names>'[^']+')"
                "Test-FmSeam\s+-Name\s+(?<names>'[^']+')"
                "-CommandName\s+(?<names>@\(\s*('[^']+'\s*,?\s*)+\)|'[^']+')"
                "Get-Command\s+-Name\s+'?(?<names>[A-Za-z]+-Fm[A-Za-z]+)'?\b"
            )
            foreach ($subdir in @('Private', 'Public')) {
                foreach ($file in (Get-FmModuleScriptFile -Subdir $subdir)) {
                    $text = [System.IO.File]::ReadAllText($file.FullName)
                    foreach ($pattern in $patterns) {
                        foreach ($m in [regex]::Matches($text, $pattern)) {
                            $raw = $m.Groups['names'].Value
                            $names = @([regex]::Matches($raw, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
                            if ($names.Count -eq 0) { $names = @($raw) }
                            $line = ($text.Substring(0, $m.Index) -split "`n").Count
                            foreach ($name in $names) {
                                if ($name -notmatch '^[A-Za-z]+-Fm') { continue }
                                $found.Add([pscustomobject]@{ Name = $name; File = $file.Name; Line = $line })
                            }
                        }
                    }
                }
            }
            $found
        }


    $script:DeclaredAbsentOwner = [ordered]@{
        # --- PREFERRED: a complete local fallback is already in place -----
        'Get-FmBackendName' = 'PREFERRED. Bootstrap prefers a shared backend-area resolver and falls back to FM_BACKEND, then config/backend. docs/session-start.md records the seam.'
        'Get-FmBackendRequiredTool' = 'PREFERRED. Falls back to bootstrap''s own backend/tool table, which covers every backend it knows.'
        'Get-FmBackendKnown' = 'PREFERRED. Falls back to the same local table, so BACKEND_INVALID still names the known set.'
        'Test-FmBackendRequiredToolAvailable' = 'PREFERRED. Falls back to a PATH lookup, which is what the shared owner does anyway.'
        'Set-FmStartupMemoryBudget' = 'PREFERRED. Set-FmBootstrapStartupMemoryBudget materializes and validates config/startup-memory-budget itself.'
        'Test-FmBackendTargetExists' = 'PREFERRED. A generic cross-backend probe would be used first if one were ever published; the digest falls through to Test-FmHerdrTargetExists, which is loaded.'
        'Get-FmComposerState' = 'PREFERRED. The fleet-wide composer-shape classifier. The herdr adapter reports "unknown" rather than growing a private, drift-prone copy of the shape catalogue.'
        'Test-FmCheckRegistered' = 'PREFERRED. Fail-closed: without the check registry Invoke-FmValidatedCheck refuses to execute ANY state check, which is the safe direction; docs/bounded-execution.md.'

        # --- ABSENT: not in this port (AGENTS.md section 14) --------------
        'Get-FmPublicFollowupPending' = 'ABSENT. Relay / X mode. Nothing in this port posts anywhere public, so there are no public commitments to report.'
        'Set-FmXModeArtifact' = 'ABSENT. Relay / X mode: no local relay artifacts are written because nothing here reads them.'
        'Invoke-FmSecondmateLivenessSweep' = 'ABSENT. Remote secondmates: the liveness sweep, convergence and cross-home handoff are not ported.'
        'Invoke-FmSecondmateSync' = 'ABSENT. Remote secondmates: convergence has no cross-home route to converge over.'
        'Invoke-FmSecondmateHandoffResume' = 'ABSENT. Remote secondmates: there is no pending cross-home handoff to retry.'
        'Invoke-FmPendingReplyTick' = 'ABSENT. Remote secondmates: the parent-owned pending-reply reconciliation has no records to reconcile here.'
        'Invoke-FmProceventReconcile' = 'ABSENT. Process-to-event sources. A blocking external wait is a backlog item on this port, never a held turn.'
        'Invoke-FmPrCheckMigrate' = 'ABSENT. The PR-check area. A Windows home has no legacy bash PR checks to neutralize.'
        'Invoke-FmPrCheckMigration' = 'ABSENT. The PR-check area. The watcher treats the migration as done and still refuses any check it cannot authenticate.'
        'Repair-FmPrPollRetirementAll' = 'ABSENT. The PR-check area: there are no retirement receipts to recover after a lost poll.'
        'Publish-FmPrPollRetirement' = 'ABSENT. The PR-check area: no merged-poll retirement receipt is ever published here.'
        'Invoke-FmWatchArm' = 'ABSENT. No automatic watcher arm. The Claude Stop auto-arm stays inert, and Get-FmSupervisionInstructions emits the session-kept foreground protocol instead of promising a mechanism that would not run.'
        'Start-FmStartupNetwork' = 'ABSENT. The deferred network stage. The digest reports NETWORK CHECKS: NOT CONFIRMED and names exactly what is unverified.'
        'Invoke-FmStartupNetworkHarvest' = 'ABSENT. The deferred network stage: there is no bounded worker whose result could be harvested.'
        'Set-FmTraceContextSessionStart' = 'ABSENT. The trace-context library: no state/.trace-context-effective is refreshed at startup.'
        'Test-FmGateAgent' = 'ABSENT. Gate agents belong to the no-mistakes pipeline, which this port refuses by name, so there is no gate agent to exclude.'
        'Test-FmQuotaAxiCompatible' = 'ABSENT. The quota-axi compatibility probe. An installed quota-axi is used as-is; bootstrap raises no incompatibility line for it.'
        'Invoke-FmHerdrSessionCleanup' = 'ABSENT. The stale-herdr-child sweep. Teardown removes its own endpoints; nothing sweeps children an interrupted session left behind.'
    }

        $script:Signatures = Get-FmModuleFunctionSignature
        $script:CallSites = @(Get-FmByNameCallSite)
        $script:ByNameTargets = @(Get-FmByNameTarget)
    }

    # THE REGISTRY OF DELIBERATE ABSENCES.
    #
    # A by-name target with no owner does not conflict in git, does not fail to
    # compile, and dies at RUN time - or worse, does not die at all and silently
    # takes a degraded path forever. Three shipped that way in one night, one of
    # them (Invoke-FmLock) leaving every session on this port read-only.
    #
    # So an absent owner is now a DECISION that has to be written down. Each
    # entry says which of two things it is:
    #
    #   PREFERRED  - the caller carries a complete local fallback and the shared
    #                owner would only be nicer. Nothing is lost while it is absent.
    #   ABSENT     - the capability genuinely is not in this port. The caller
    #                degrades visibly and AGENTS.md section 14 says so.
    #
    # Anything not listed here must be DEFINED. Add a name to this table only
    # after establishing which of the two it is - never to make this test green.
    It 'finds by-name targets at all, so the registry check below is not vacuous' {
        $script:ByNameTargets.Count | Should -BeGreaterThan 40
    }

    It 'gives every by-name target either an owner in the tree or a written reason' {
        $undeclared = [System.Collections.Generic.List[string]]::new()
        foreach ($target in $script:ByNameTargets) {
            if ($script:Signatures.ContainsKey($target.Name)) { continue }
            if ($script:DeclaredAbsentOwner.Contains($target.Name)) { continue }
            $undeclared.Add("$($target.File):$($target.Line) binds $($target.Name), which no file defines")
        }
        ($undeclared | Sort-Object -Unique) -join '; ' | Should -Be '' -Because (
            'a by-name call with no owner dies at run time or silently degrades forever; ' +
            'define the owner, point the call at the owner that already exists under another name, ' +
            'or record the absence and its consequence in $script:DeclaredAbsentOwner')
    }

    It 'keeps the registry honest: no entry for a name the tree now defines' {
        # Without this, a landed owner leaves its excuse behind and the next
        # reader believes a capability is missing that is not.
        $stale = @($script:DeclaredAbsentOwner.Keys | Where-Object { $script:Signatures.ContainsKey($_) })
        ($stale -join ', ') | Should -Be '' -Because 'the owner landed - delete its entry and update AGENTS.md section 14'
    }

    It 'keeps the registry honest: no entry for a name nothing binds' {
        $bound = @($script:ByNameTargets | ForEach-Object { $_.Name } | Select-Object -Unique)
        $orphan = @($script:DeclaredAbsentOwner.Keys | Where-Object { $bound -notcontains $_ })
        ($orphan -join ', ') | Should -Be '' -Because 'nothing asks for it any more - delete the entry rather than carrying a stale excuse'
    }

    It 'classifies every declared absence as PREFERRED or ABSENT, with a reason' {
        foreach ($name in $script:DeclaredAbsentOwner.Keys) {
            $reason = [string]$script:DeclaredAbsentOwner[$name]
            $reason | Should -Match '^(PREFERRED|ABSENT)\.' -Because "$name must say which kind of absence it is"
            $reason.Length | Should -BeGreaterThan 40 -Because "$name needs a reason a reader can act on, not a label"
        }
    }

    It 'finds by-name call sites at all, so the checks below are not vacuous' {
        # A refactor that renames the resolver would otherwise turn every check
        # in this Describe green by finding nothing to check.
        $script:CallSites.Count | Should -BeGreaterThan 20
    }

    It 'passes every by-name owner only parameters that owner declares' {
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($site in $script:CallSites) {
            # An owner that is genuinely absent is a DEGRADATION, which the
            # callers handle on purpose. Only a present owner has a contract to
            # break, so an unported area is not a failure here.
            if (-not $script:Signatures.ContainsKey($site.Target)) { continue }
            $owner = $script:Signatures[$site.Target]
            foreach ($p in $site.Used) {
                # PowerShell binds an unambiguous prefix, so -Path matches Path.
                if (@($owner.Params | Where-Object { $_ -like "$p*" }).Count -gt 0) { continue }
                $how = if ($owner.Advanced) { 'throws, and the caller reads that as "no owner"' }
                else { "is SIMPLE, so -$p lands in `$args and is silently dropped" }
                $bad.Add("$($site.File):$($site.Line) calls $($site.Target) ($($owner.File)) with -$p, which it does not declare - $how")
            }
        }
        ($bad -join '; ') | Should -Be ''
    }

    It 'gives every bootstrap sweep an owner that a no-argument call can reach' {
        # Invoke-FmBootstrapSweep resolves by name and calls with @{} unless the
        # caller passes -Parameters, so an owner with a mandatory parameter is
        # unreachable: the call throws and the sweep silently reports nothing
        # done. Invoke-FmFleetSync is live on this path today.
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($subdir in @('Private', 'Public')) {
            foreach ($file in (Get-FmModuleScriptFile -Subdir $subdir)) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                foreach ($call in $ast.FindAll(
                        { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    if ($call.GetCommandName() -ne 'Invoke-FmBootstrapSweep') { continue }
                    $named = @($call.CommandElements |
                            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                            ForEach-Object { $_.ParameterName })
                    if ($named -contains 'Parameters') { continue }
                    $idx = [array]::IndexOf(@($call.CommandElements | ForEach-Object { $_.Extent.Text }), '-CommandName')
                    if ($idx -lt 0 -or $idx + 1 -ge $call.CommandElements.Count) { continue }
                    $arg = $call.CommandElements[$idx + 1]
                    if ($arg -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                    $target = $arg.Value
                    if (-not $script:Signatures.ContainsKey($target)) { continue }
                    $required = @($script:Signatures[$target].Mandatory)
                    if ($required.Count -gt 0) {
                        $bad.Add("$($file.Name):$($call.Extent.StartLineNumber) sweeps $target, which requires -$($required -join ' -')")
                    }
                }
            }
        }
        ($bad -join '; ') | Should -Be ''
    }
}

Describe 'Only one Firstmate module is ever loaded in a test process' {
    # WHY. `Import-Module <path> -Force` replaces only a module loaded from the
    # SAME path, so a second copy of this repo in one process leaves TWO modules
    # named Firstmate loaded and Pester refuses every `InModuleScope Firstmate`
    # block after that. Comparing a base commit against a branch commit by
    # running both suites back to back in one session - which is the correct way
    # to compare, because privilege context must be held constant - did exactly
    # that, and failed the 40 InModuleScope tests in whichever suite ran second.
    # They read as a regression in the second commit and were nothing of the
    # kind. tests/FmModule.TestHelpers.ps1 owns the fix; this holds it in place.

    It 'imports THIS checkout even when another copy is already loaded' {
        . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
        $decoyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-decoy-' + [guid]::NewGuid().ToString('N'))
        try {
            $decoyModule = Join-Path $decoyRoot 'Firstmate'
            $null = New-Item -ItemType Directory -Path $decoyModule -Force
            Copy-Item -Path (Join-Path $script:ModuleRoot '*') -Destination $decoyModule -Recurse -Force
            Import-Module (Join-Path $decoyModule 'Firstmate.psd1') -Force -ErrorAction Stop

            Import-FmTestModule -TestRoot $PSScriptRoot

            $loaded = @(Get-Module -Name 'Firstmate')
            $loaded.Count | Should -Be 1
            $loaded[0].Path | Should -Be (Join-Path $script:ModuleRoot 'Firstmate.psm1')
            # The point of all of it: InModuleScope has to be usable afterwards.
            { InModuleScope Firstmate { 1 } } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $decoyRoot -Recurse -Force -ErrorAction SilentlyContinue
            Import-FmTestModule -TestRoot $PSScriptRoot
        }
    }

    It 'routes every InModuleScope suite through the helper, so a new suite cannot regress this' {
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -notmatch 'InModuleScope') { continue }
            if ($text -notmatch 'Import-FmTestModule') {
                $bad.Add("$($file.Name) uses InModuleScope but does not import through Import-FmTestModule")
            }
        }
        ($bad -join '; ') | Should -Be ''
    }
}

Describe 'No test silences a cmdlet for the tests that come after it' {
    # WHY. A preference variable is dynamically scoped, so assigning one changes
    # what every cmdlet called from that scope onward does - including cmdlets
    # in other files' functions that the assigning test has never heard of. The
    # dangerous ones are the SILENCERS: $WhatIfPreference makes a cmdlet report
    # an intention and do nothing, which turns a test that meant to prove a
    # write into one that proves nothing and still passes.
    #
    # MEASURED, Pester 6.1.0, 2026-08-21: a bare assignment inside an `It` dies
    # with that `It`, but the SAME line in a `BeforeAll` suppresses every cmdlet
    # in the WHOLE FILE, across every Describe in it. So the bare form is not
    # safe, it is safe-for-now and one refactor away from silent - which is
    # exactly how it reads to whoever adds the next test beside it.
    # docs/windows-e2e-evidence.md section 39 has both measurements.
    #
    # $ErrorActionPreference is deliberately NOT on this list. Around 25 files
    # set it to 'Stop' in their own BeforeAll, which is file setup rather than a
    # silencer: it makes errors terminating, so it surfaces failures instead of
    # hiding them.
    It 'sets a silencing preference only in a scope that ends at the call needing it' {
        $silencers = @('WhatIfPreference', 'ConfirmPreference', 'ProgressPreference',
            'WarningPreference', 'InformationPreference')
        # `& { ... }` is the only form here that ends the scope at the call.
        # `. { ... }` deliberately does not, and a Pester block's own body is
        # kept alive for everything nested under it.
        $scopedToOneCall = {
            param($Node)
            $walk = $Node.Parent
            while ($walk) {
                if ($walk -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $owner = $walk.Parent
                    return ($owner -is [System.Management.Automation.Language.CommandAst] -and
                        $owner.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
                        $owner.CommandElements.Count -gt 0 -and
                        [object]::ReferenceEquals($owner.CommandElements[0], $walk))
                }
                $walk = $walk.Parent
            }
            return $false
        }
        # Every .ps1 here, not only *.Tests.ps1: a shared TestHelpers file is
        # dot-sourced into whichever suite loads it, so one there is worse.
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($assignment in $ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $name = $assignment.Left.VariablePath.UserPath
                if ($name -notin $silencers) { continue }
                if (& $scopedToOneCall $assignment) { continue }
                $bad.Add("$($file.Name):$($assignment.Extent.StartLineNumber) sets `$$name where the tests after it inherit it - wrap the one call that needs it in an & { } block instead")
            }
        }
        ($bad -join '; ') | Should -Be ''
    }
}

Describe 'No test fixture can make Windows talk to the captain' {
    # WHY. A test needs a file Windows will genuinely refuse to launch, so the
    # separation between "not on PATH", "would not start" and "ran and answered"
    # runs its real refusal path. The obvious way to build one - put text in a
    # .exe - is the wrong way. 64-bit Windows reads any non-image content behind
    # an executable extension as an MS-DOS program, finds no NTVDM to run it,
    # and raises the refusal as a HARD ERROR, which is a modal dialog on the
    # interactive desktop:
    #
    #     Unsupported 16-Bit Application
    #     The program or feature "\??\...\fm-unstartable.exe" cannot start or
    #     run due to incompatibility with 64-bit versions of Windows.
    #
    # THREE THINGS MAKE THIS WORTH A LINT RATHER THAN A COMMENT.
    #
    #   - The suite's -NonInteractive switch does NOT cover it. That switch
    #     governs PowerShell's own prompting; this comes from underneath
    #     PowerShell, so every guard this repo has against a test stopping to
    #     ask a question sails straight past it.
    #   - It does not fail the run. The suite goes green and the dialog stays on
    #     the desktop as long as the process that raised it lives - the best
    #     part of an hour for a full run. One is raised per failed launch, twice
    #     over, so the captain gets a STACK of them and dismissing the top one
    #     only uncovers the next.
    #   - An agent cannot see it. A process inherits its parent's error mode and
    #     an agent harness sets SEM_FAILCRITICALERRORS - measured here as
    #     0x8003 - so the dialog is suppressed for the agent and raised for the
    #     captain, whose own shell runs at 0.
    #
    # A reintroduction would therefore be invisible to everything except the
    # captain, which is exactly how this survived once already.
    # docs/windows-e2e-evidence.md section 41 has the measurements.

    BeforeAll {
        . (Join-Path $PSScriptRoot 'FmUnstartable.TestHelpers.ps1')
        # The one file allowed to write these bytes, because it owns the rule.
        # The first test below pins what it actually writes, so the exemption
        # cannot quietly become a hole.
        $script:UnstartableOwner = 'FmUnstartable.TestHelpers.ps1'
        # The extensions Windows hands to the image loader, and so to the DOS
        # fallback behind it. .cmd and .bat are absent on purpose: cmd.exe runs
        # those as text and never reaches the loader.
        $script:ImageExtension = '\.(exe|com|scr|pif)$'
    }

    It 'builds its unstartable fixture empty, which is what keeps the loader quiet' {
        $fixture = New-FmUnstartableFixture -Path (Join-Path $TestDrive 'fm-guard-probe.exe')
        Test-Path -LiteralPath $fixture | Should -BeTrue
        (Get-Item -LiteralPath $fixture).Length | Should -Be 0 `
            -Because 'anything at all behind an executable extension is read as an MS-DOS program and raises a dialog'
    }

    It 'starts nothing elevated, which is the same disease one turn worse' {
        # A CONSENT DIALOG IS EVERYTHING ABOVE PLUS A DECISION. The installer can
        # now raise one - the Visual C++ runtime is the single step here that
        # asks for administrator - and every reason the 16-bit dialog survived a
        # long run of green suites applies to it unchanged: -NonInteractive does
        # not cover it, it does not fail the run, and an agent harness's error
        # mode means the agent "checking" would never see what the captain gets.
        #
        # So the raising is kept to one function and no test may reach it. A test
        # that needs the outcome mocks Start-FmToolElevated, which is what the
        # runtime tests do; Mock's target is an argument rather than a command
        # name, so mocking it is not calling it.
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($command in $ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $line = $command.Extent.StartLineNumber
                if ($command.GetCommandName() -eq 'Start-FmToolElevated') {
                    $bad.Add("$($file.Name):$line calls Start-FmToolElevated - mock it instead; it raises a Windows consent dialog")
                    continue
                }
                # And the underlying verb, whatever it is pointed at.
                $elements = @($command.CommandElements)
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($element.ParameterName.ToLowerInvariant() -ne 'verb') { continue }
                    $argument = if ($element.Argument) { $element.Argument }
                    elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }
                    else { $null }
                    if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $argument.Value -match '^(?i)runas$') {
                        $bad.Add("$($file.Name):$line starts a process elevated - a test must never put a consent dialog on the captain's desktop")
                    }
                }
            }
        }
        ($bad -join '; ') | Should -Be ''
    }

    It 'writes no fixture with an executable extension outside that helper' {
        $writeCommand = @('Set-Content', 'Add-Content', 'Out-File', 'Write-FmTextFileLf', 'Add-FmTextLineLf')
        $writeMember = @('WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'AppendAllLines')
        $pathParameter = @('path', 'literalpath', 'filepath', 'destination')

        # A literal anywhere under this node that NAMES an executable file.
        # ExpandableStringExpressionAst covers "$Tool.exe", whose Value keeps the
        # unexpanded text and so still ends in the extension.
        $namesImage = {
            param($Node)
            if (-not $Node) { return $false }
            @($Node.FindAll({ param($n)
                        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                        $n.Value -match $script:ImageExtension }, $true)).Count -gt 0
        }

        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name)) {
            if ($file.Name -eq $script:UnstartableOwner) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

            # A path that reaches the write through a VARIABLE is the shape that
            # hid one of these in the bridge suite, so one hop is resolved. It is
            # resolved to the MOST RECENT assignment above the write, not to any
            # assignment in the file: `$fake` here names a .cmd in one test and a
            # .exe in another, and a file-wide answer flags the innocent one.
            $assignmentsFor = @{}
            foreach ($assignment in $ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $name = $assignment.Left.VariablePath.UserPath
                if (-not $assignmentsFor.ContainsKey($name)) {
                    $assignmentsFor[$name] = [System.Collections.Generic.List[object]]::new()
                }
                $assignmentsFor[$name].Add([pscustomobject]@{
                        Line       = $assignment.Extent.StartLineNumber
                        NamesImage = [bool](& $namesImage $assignment.Right)
                    })
            }
            $variableNamesImage = {
                param($Name, $Line)
                if (-not $assignmentsFor.ContainsKey($Name)) { return $false }
                $prior = @($assignmentsFor[$Name] | Where-Object { $_.Line -le $Line } | Sort-Object Line)
                if ($prior.Count -eq 0) { return $false }
                return $prior[-1].NamesImage
            }
            $targetsImage = {
                param($Node, $Line)
                if (-not $Node) { return $false }
                if (& $namesImage $Node) { return $true }
                foreach ($reference in $Node.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    if (& $variableNamesImage $reference.VariablePath.UserPath $Line) { return $true }
                }
                return $false
            }

            foreach ($command in $ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ($command.GetCommandName() -notin $writeCommand) { continue }
                $line = $command.Extent.StartLineNumber
                # Only the PATH arguments are inspected. A .exe inside the CONTENT
                # being written is ordinary test data - a recorded command line, a
                # metadata value - and flagging that would make the lint noise.
                $elements = @($command.CommandElements)
                $suspect = $false
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($element.ParameterName.ToLowerInvariant() -notin $pathParameter) { continue }
                        $argument = if ($element.Argument) { $element.Argument }
                        elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }
                        else { $null }
                        if (& $targetsImage $argument $line) { $suspect = $true }
                    } elseif ($i -eq 1 -and (& $targetsImage $element $line)) {
                        # The positional path, as in `Set-Content $p -Value x`.
                        $suspect = $true
                    }
                }
                if ($suspect) {
                    $bad.Add("$($file.Name):$line writes a file with an executable extension - use New-FmUnstartableFixture, which writes it empty so Windows never reads it as a DOS program")
                }
            }

            foreach ($invocation in $ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                if ($invocation.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ($invocation.Member.Value -notin $writeMember) { continue }
                $line = $invocation.Extent.StartLineNumber
                $first = if ($invocation.Arguments -and @($invocation.Arguments).Count -gt 0) { @($invocation.Arguments)[0] } else { $null }
                if (& $targetsImage $first $line) {
                    $bad.Add("$($file.Name):$line writes a file with an executable extension - use New-FmUnstartableFixture, which writes it empty so Windows never reads it as a DOS program")
                }
            }
        }
        ($bad -join '; ') | Should -Be ''
    }
}
