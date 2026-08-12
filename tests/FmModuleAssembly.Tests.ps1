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
        foreach ($a in (@('-NoProfile', '-File', (Join-Path $script:BinRoot $Script)) + $CliArgs)) {
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

    It 'resolves the module in every bin/ entry point before calling into it' {
        # Three conventions are in use across the areas that have landed - the
        # shared loader, importing the manifest, and an inline dot-source of
        # Private then Public. What matters is that no entry point calls a module
        # function without loading the module at all.
        foreach ($file in @(Get-ChildItem -LiteralPath $script:BinRoot -Filter 'fm-*.ps1' -File)) {
            if ($file.Name -eq 'fm-module-load.ps1') { continue }
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $text | Should -Match "(fm-module-load\.ps1|Import-Module|'module' 'Firstmate')" -Because $file.Name
        }
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
                            '\$(?<var>\w+)\s*=\s*Resolve-Fm\w*Command\s+-Name\s+(?<names>(''[^'']+''\s*,?\s*)+)')) {
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

        $script:Signatures = Get-FmModuleFunctionSignature
        $script:CallSites = @(Get-FmByNameCallSite)
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
