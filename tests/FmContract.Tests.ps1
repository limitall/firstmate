#requires -Version 7.0
# Pester 5+/6 tests for the instruction surface: the operating contract and the
# skills.
#
# TWO DIFFERENT THINGS ARE TESTED HERE, AND ONLY ONE OF THEM IS CODE.
#
# The first is the mechanism - reading front matter, recognising the placeholder
# a Windows clone leaves in place of a symlink, repairing it, and reporting all
# of that. Those tests run against fixtures under TestDrive and are ordinary.
#
# The second is THE REAL CHECKOUT'S OWN SURFACE. A checkout whose AGENTS.md is
# build memory rather than a job description, or whose skills tree lost a
# description line, is broken in exactly the way that no command failure would
# reveal - the captain finds it by noticing the session does not behave like
# firstmate. So the tree itself is asserted, not just the code that reads it.
#
# The placeholder tests deliberately construct the placeholder BY HAND rather
# than by asking git to produce one, because the failure being guarded against
# is a property of the bytes on disk, and a test that needed a
# core.symlinks=false clone could not run on the development platform at all.

# ---------------------------------------------------------------------------
# THE CHECKOUT'S SURFACE IS SAMPLED AT DISCOVERY, BEFORE ANY TEST RUNS.
#
# Pester discovers every file before it runs anything, so this executes while the
# tree is still exactly as the developer left it.
#
# MEASURED, and the reason it exists: a full `Invoke-Pester -Path ./tests` run
# leaves CLAUDE.md and .claude/skills changed in the checkout it ran in, while
# every one of the 42 files run INDIVIDUALLY leaves them untouched. The fault is
# therefore an interaction across files, it is silent when it happens, and it
# surfaced as eight failures that all looked like the doctor being broken.
#
# Sampling here lets the drift test below report that mutation as its own
# finding, which separates "this checkout is broken" from "the suite broke this
# checkout" - two very different bugs that until now produced identical output.
# ---------------------------------------------------------------------------
$script:SurfaceAtStart = $(
    $surfaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    [pscustomobject]@{
        ContractChars = $(try { ([System.IO.File]::ReadAllText((Join-Path $surfaceRoot 'CLAUDE.md'))).Length } catch { 0 })
        SkillsLinked  = Test-Path -LiteralPath (Join-Path $surfaceRoot '.claude/skills')
        SkillCount    = @(Get-ChildItem -LiteralPath (Join-Path $surfaceRoot '.agents/skills') `
                -Directory -ErrorAction SilentlyContinue).Count
    }
)

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # A minimal but REAL checkout shape: a contract that carries the identity
    # marker, its mirror, and one loadable skill. Everything a test wants to
    # break, it breaks from here, so each test names exactly one fault.
    function New-TestSurface {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A Pester fixture builder: it writes only into TestDrive.')]
        [CmdletBinding()]
        param([switch]$NoClaudeSkillsLink)

        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $skills = Join-Path $root '.agents' 'skills'
        New-Item -ItemType Directory -Path (Join-Path $skills 'sample-skill') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.claude') -Force | Out-Null

        $contract = @(
            '# Firstmate'
            ''
            'You are the first mate.'
            'The user is the captain.'
            ('padding. ' * 400)
        ) -join "`n"
        Write-FmTextFileLf -Path (Join-Path $root 'AGENTS.md') -Text $contract
        Write-FmTextFileLf -Path (Join-Path $root 'CLAUDE.md') -Text $contract

        Write-FmTextFileLf -Path (Join-Path $skills 'sample-skill' 'SKILL.md') -Text (@(
                '---'
                'name: sample-skill'
                'description: A sample skill used by the suite.'
                'user-invocable: true'
                'metadata:'
                '  internal: true'
                '---'
                ''
                '# sample-skill'
            ) -join "`n")

        if (-not $NoClaudeSkillsLink) {
            $null = Set-FmClaudeSkillsLink -RepoRoot $root -Confirm:$false
        }
        $root
    }
}

Describe 'reading a skill' {
    It 'reads name, description and user-invocable out of the front matter' {
        $root = New-TestSurface
        $skills = @(Get-FmSkillDefinition -RepoRoot $root)
        $skills.Count | Should -Be 1
        $skills[0].Name | Should -Be 'sample-skill'
        $skills[0].Description | Should -Be 'A sample skill used by the suite.'
        $skills[0].UserInvocable | Should -BeTrue
        $skills[0].Problem | Should -Be ''
    }

    It 'folds a >- description across its continuation lines' {
        # The real skills use this shape, and a reader that stopped at the `>-`
        # would report every one of them as having no description - which is the
        # exact fault the description check exists to catch, produced by the
        # checker itself.
        $root = New-TestSurface
        $path = Join-Path $root '.agents' 'skills' 'sample-skill' 'SKILL.md'
        Write-FmTextFileLf -Path $path -Text (@(
                '---'
                'name: sample-skill'
                'description: >-'
                '  First line of the trigger.'
                '  Second line of the trigger.'
                'user-invocable: false'
                'metadata:'
                '  internal: true'
                '---'
            ) -join "`n")
        $skills = @(Get-FmSkillDefinition -RepoRoot $root)
        $skills[0].Description | Should -Be 'First line of the trigger. Second line of the trigger.'
        $skills[0].UserInvocable | Should -BeFalse
        $skills[0].Problem | Should -Be ''
    }

    It 'does not fold a nested mapping into the previous key' {
        $root = New-TestSurface
        $skills = @(Get-FmSkillDefinition -RepoRoot $root)
        # `metadata:` and its indented `internal: true` sit right after
        # user-invocable; a reader that folded them would corrupt the value.
        $skills[0].Description | Should -Not -Match 'internal'
    }

    It 'reports a skill with no description as one that will not load' {
        $root = New-TestSurface
        $path = Join-Path $root '.agents' 'skills' 'sample-skill' 'SKILL.md'
        Write-FmTextFileLf -Path $path -Text "---`nname: sample-skill`n---`n"
        $skills = @(Get-FmSkillDefinition -RepoRoot $root)
        $skills[0].Problem | Should -Match 'description'
    }

    It 'reports a missing SKILL.md, absent front matter, and an unterminated block' {
        $root = New-TestSurface
        $dir = Join-Path $root '.agents' 'skills' 'sample-skill'
        $path = Join-Path $dir 'SKILL.md'

        Remove-Item -LiteralPath $path
        (Get-FmSkillDefinition -RepoRoot $root)[0].Problem | Should -Be 'no SKILL.md'

        Write-FmTextFileLf -Path $path -Text "# sample-skill`nno front matter here`n"
        (Get-FmSkillDefinition -RepoRoot $root)[0].Problem | Should -Be 'no YAML front matter'

        Write-FmTextFileLf -Path $path -Text "---`nname: sample-skill`ndescription: x`n"
        (Get-FmSkillDefinition -RepoRoot $root)[0].Problem | Should -Be 'unterminated YAML front matter'
    }

    It 'reports a front-matter name that disagrees with its directory' {
        # Invocable under one spelling and documented under the other.
        $root = New-TestSurface
        $path = Join-Path $root '.agents' 'skills' 'sample-skill' 'SKILL.md'
        Write-FmTextFileLf -Path $path -Text "---`nname: other-name`ndescription: x`n---`n"
        (Get-FmSkillDefinition -RepoRoot $root)[0].Problem | Should -Match 'does not match the directory'
    }
}

Describe 'the .claude/skills link' {
    It 'recognises the text git leaves when it cannot create the symlink' {
        $root = New-TestSurface -NoClaudeSkillsLink
        $link = Join-Path $root '.claude' 'skills'
        # MEASURED shape: a small regular file whose whole content is the link
        # target. 17 bytes for this one.
        [System.IO.File]::WriteAllText($link, '../.agents/skills')

        Test-FmSkillsLinkPlaceholder -Path $link | Should -BeTrue
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'placeholder'
    }

    It 'recognises the backslash spelling of that placeholder too' {
        $root = New-TestSurface -NoClaudeSkillsLink
        $link = Join-Path $root '.claude' 'skills'
        [System.IO.File]::WriteAllText($link, '..\.agents\skills')
        Test-FmSkillsLinkPlaceholder -Path $link | Should -BeTrue
    }

    It 'does not mistake a real file for the placeholder' {
        $root = New-TestSurface -NoClaudeSkillsLink
        $link = Join-Path $root '.claude' 'skills'
        # Multi-line, and not naming the tree: the two things the narrow test
        # requires, each of which alone must disqualify it.
        [System.IO.File]::WriteAllText($link, "notes about skills`nmore notes`n")
        Test-FmSkillsLinkPlaceholder -Path $link | Should -BeFalse
        [System.IO.File]::WriteAllText($link, 'something/else')
        Test-FmSkillsLinkPlaceholder -Path $link | Should -BeFalse
    }

    It 'reports missing when nothing is there' {
        $root = New-TestSurface -NoClaudeSkillsLink
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'missing'
    }

    It 'repairs a placeholder and reports the kind it actually created' {
        $root = New-TestSurface -NoClaudeSkillsLink
        $link = Join-Path $root '.claude' 'skills'
        [System.IO.File]::WriteAllText($link, '../.agents/skills')

        $result = Set-FmClaudeSkillsLink -RepoRoot $root -Confirm:$false
        $result.Action | Should -Be 'updated'
        $result.Kind | Should -BeIn @('symlink', 'junction', 'copy')
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -BeIn @('symlink', 'materialized')
        Test-Path -LiteralPath (Join-Path $link 'sample-skill' 'SKILL.md') | Should -BeTrue
    }

    It 'is idempotent: a second run reports already and changes nothing' {
        $root = New-TestSurface
        $first = Get-FmClaudeSkillsLinkState -RepoRoot $root
        $result = Set-FmClaudeSkillsLink -RepoRoot $root -Confirm:$false
        $result.Action | Should -Be 'already'
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be $first
    }

    It 'produces a working surface through the copy rung specifically' {
        # The rung a stock non-elevated Windows machine most likely lands on.
        # Forced, because the host running the suite may allow a stronger one and
        # would otherwise never exercise this path.
        $root = New-TestSurface -NoClaudeSkillsLink
        $result = Set-FmClaudeSkillsLink -RepoRoot $root -Strategy Copy -Confirm:$false
        $result.Kind | Should -Be 'copy'
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'materialized'
        (Get-FmInstructionSurface -RepoRoot $root).Healthy | Should -BeTrue
    }

    It 're-syncs a copy that has fallen behind the real tree' {
        # The one hazard a copy has and a link does not.
        $root = New-TestSurface -NoClaudeSkillsLink
        $null = Set-FmClaudeSkillsLink -RepoRoot $root -Strategy Copy -Confirm:$false

        $newSkill = Join-Path $root '.agents' 'skills' 'later-skill'
        New-Item -ItemType Directory -Path $newSkill -Force | Out-Null
        Write-FmTextFileLf -Path (Join-Path $newSkill 'SKILL.md') `
            -Text "---`nname: later-skill`ndescription: Added after the copy was made.`n---`n"

        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'drifted'
        $null = Set-FmClaudeSkillsLink -RepoRoot $root -Strategy Copy -Confirm:$false
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'materialized'
    }

    It 'refuses rather than guessing when there is no skills tree to link to' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $result = Set-FmClaudeSkillsLink -RepoRoot $root -Confirm:$false
        $result.Action | Should -Be 'skipped'
        $result.Detail | Should -Match 'NOT RUN'
    }

    It 'honours -WhatIf without writing' {
        $root = New-TestSurface -NoClaudeSkillsLink
        $result = Set-FmClaudeSkillsLink -RepoRoot $root -WhatIf
        $result.Action | Should -Be 'skipped'
        Get-FmClaudeSkillsLinkState -RepoRoot $root | Should -Be 'missing'
    }
}

Describe 'the doctor reports a broken identity rather than leaving it to be noticed' {
    It 'passes every instruction check on a healthy surface' {
        $root = New-TestSurface
        $checks = @(Get-FmContractCheck -RepoRoot $root)
        @($checks | Where-Object { $_.Status -ne 'ok' }) | Should -BeNullOrEmpty
        @($checks | ForEach-Object { $_.Name }) | Should -Be @(
            'operating contract', 'contract for Claude', 'skills', 'skills for Claude')
    }

    It 'calls every one of them REQUIRED, so a broken identity is unhealthy and not a warning' {
        $root = New-TestSurface
        @(Get-FmContractCheck -RepoRoot $root | Where-Object { -not $_.Required }) | Should -BeNullOrEmpty
    }

    It 'reports an AGENTS.md that is build memory rather than a job description' {
        # The bug this whole area exists for: present, readable, useful markdown,
        # and not the first mate's instructions. A presence check would pass.
        $root = New-TestSurface
        Write-FmTextFileLf -Path (Join-Path $root 'AGENTS.md') -Text (@(
                '# Project agent memory'
                ''
                'PowerShell 7 only. Read the bash original first.'
                ('padding. ' * 400)
            ) -join "`n")
        $check = @(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'operating contract' })[0]
        $check.Status | Should -Be 'missing'
        $check.Detail | Should -Match 'operating contract'
    }

    It 'reports an absent and a stub contract' {
        $root = New-TestSurface
        Write-FmTextFileLf -Path (Join-Path $root 'AGENTS.md') -Text "# Firstmate`nYou are the first mate.`n"
        (@(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'operating contract' })[0]).Status |
            Should -Be 'missing'

        Remove-Item -LiteralPath (Join-Path $root 'AGENTS.md')
        (@(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'operating contract' })[0]).Status |
            Should -Be 'missing'
    }

    It 'reports a CLAUDE.md that is the placeholder git left behind' {
        $root = New-TestSurface
        [System.IO.File]::WriteAllText((Join-Path $root 'CLAUDE.md'), 'AGENTS.md')
        $check = @(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'contract for Claude' })[0]
        $check.Status | Should -Be 'missing'
        $check.Fix | Should -Match 'fm-setup'
    }

    It 'reports two genuinely different files as a conflict setup will not overwrite' {
        $root = New-TestSurface
        Write-FmTextFileLf -Path (Join-Path $root 'CLAUDE.md') -Text ('# Something else entirely' + "`n" + ('x ' * 300))
        $check = @(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'contract for Claude' })[0]
        $check.Status | Should -Be 'missing'
        $check.Fix | Should -Match 'by hand'
    }

    It 'reports a skills tree that will not load, naming the skill and the reason' {
        $root = New-TestSurface
        Write-FmTextFileLf -Path (Join-Path $root '.agents' 'skills' 'sample-skill' 'SKILL.md') `
            -Text "---`nname: sample-skill`n---`n"
        $check = @(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'skills' })[0]
        $check.Status | Should -Be 'missing'
        $check.Detail | Should -Match 'sample-skill'
        $check.Detail | Should -Match 'description'
    }

    It 'reports an empty and an absent skills tree' {
        $root = New-TestSurface
        Remove-Item -LiteralPath (Join-Path $root '.agents' 'skills' 'sample-skill') -Recurse -Force
        (@(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'skills' })[0]).Status |
            Should -Be 'missing'

        Remove-Item -LiteralPath (Join-Path $root '.agents') -Recurse -Force
        (@(Get-FmContractCheck -RepoRoot $root | Where-Object { $_.Name -eq 'skills' })[0]).Status |
            Should -Be 'missing'
    }

    It 'reports zero loadable skills when .claude/skills is the placeholder' {
        # The whole point: the contract is fine, every command works, and the
        # session has no procedures.
        $root = New-TestSurface -NoClaudeSkillsLink
        [System.IO.File]::WriteAllText((Join-Path $root '.claude' 'skills'), '../.agents/skills')
        $checks = @(Get-FmContractCheck -RepoRoot $root)
        (@($checks | Where-Object { $_.Name -eq 'operating contract' })[0]).Status | Should -Be 'ok'
        (@($checks | Where-Object { $_.Name -eq 'skills' })[0]).Status | Should -Be 'ok'
        $link = @($checks | Where-Object { $_.Name -eq 'skills for Claude' })[0]
        $link.Status | Should -Be 'missing'
        $link.Detail | Should -Match 'ZERO skills'
    }
}

Describe 'the composed surface report' {
    It 'is healthy only when every part of the surface is loadable' {
        $root = New-TestSurface
        (Get-FmInstructionSurface -RepoRoot $root).Healthy | Should -BeTrue

        [System.IO.File]::WriteAllText((Join-Path $root 'CLAUDE.md'), 'AGENTS.md')
        $surface = Get-FmInstructionSurface -RepoRoot $root
        $surface.Healthy | Should -BeFalse
        $surface.MirrorState | Should -Be 'placeholder'
    }

    It 'lists every skill with its trigger, and marks one that will not load' {
        $root = New-TestSurface
        $lines = (Get-FmInstructionSurface -RepoRoot $root).Lines -join "`n"
        $lines | Should -Match 'sample-skill'
        $lines | Should -Match 'A sample skill used by the suite'

        Write-FmTextFileLf -Path (Join-Path $root '.agents' 'skills' 'sample-skill' 'SKILL.md') `
            -Text "---`nname: sample-skill`n---`n"
        ((Get-FmInstructionSurface -RepoRoot $root).Lines -join "`n") | Should -Match 'WILL NOT LOAD'
    }
}

Describe "this checkout's own instruction surface" {
    # Not a fixture. The real tree, because a first mate that is not one is the
    # failure this area exists to prevent and it cannot be caught anywhere else.

    It 'is healthy' {
        $surface = Get-FmInstructionSurface -RepoRoot $script:RepoRoot
        $problems = @($surface.Skills | Where-Object { $_.Problem } |
                ForEach-Object { "$($_.Name): $($_.Problem)" })
        ($problems -join '; ') | Should -Be ''
        $surface.ContractPresent | Should -BeTrue
        $surface.MirrorState | Should -BeIn @('link', 'mirror')
        $surface.ClaudeSkillsState | Should -BeIn @('symlink', 'materialized')
        $surface.Healthy | Should -BeTrue
    }

    # -ForEach carries the discovery-time sample into the run phase. Pester's two
    # phases do NOT share script scope, so a plain $script: variable set at
    # discovery is simply absent inside an It - measured, as "cannot be retrieved
    # because it has not been set".
    It 'was healthy when this run started' -ForEach @($script:SurfaceAtStart) {
        $_.ContractChars | Should -BeGreaterThan 200 `
            -Because 'the contract must be the real file, not the placeholder a Windows clone leaves'
        $_.SkillsLinked | Should -BeTrue `
            -Because 'a session with no skills cannot do its job'
        $_.SkillCount | Should -BeGreaterThan 0 `
            -Because 'the skills tree must have skills in it'
    }

    It 'is not damaged by running the suite' -ForEach @($script:SurfaceAtStart) {
        # The other half of the canary. When this fails, the run mutated the tree
        # it was testing - which is a fault in the SUITE, not in the checkout, and
        # saying so here stops it being read as a doctor defect.
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $nowChars = try { ([System.IO.File]::ReadAllText((Join-Path $root 'CLAUDE.md'))).Length } catch { 0 }
        $nowLinked = Test-Path -LiteralPath (Join-Path $root '.claude/skills')
        $nowSkills = @(Get-ChildItem -LiteralPath (Join-Path $root '.agents/skills') `
                -Directory -ErrorAction SilentlyContinue).Count

        $nowChars | Should -Be $_.ContractChars `
            -Because 'the suite must not rewrite the contract of the checkout it runs in'
        $nowLinked | Should -Be $_.SkillsLinked `
            -Because 'the suite must not remove the skills link of the checkout it runs in'
        $nowSkills | Should -Be $_.SkillCount `
            -Because 'the suite must not delete skills from the checkout it runs in'
    }

    It 'carries every skill AGENTS.md section 13 names, so no trigger points at nothing' {
        # The dead-pointer direction: a section-13 name with no skill behind it
        # is an instruction the model can never satisfy.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'AGENTS.md'))
        $present = @(Get-FmSkillDefinition -RepoRoot $script:RepoRoot | ForEach-Object { $_.Name })

        $named = @([regex]::Matches($contract, '(?m)^- `(?<name>[a-z0-9-]+)` - load ') |
                ForEach-Object { $_.Groups['name'].Value })
        $named.Count | Should -BeGreaterThan 5
        $missing = @($named | Where-Object { $present -notcontains $_ })
        ($missing -join ', ') | Should -Be ''
    }

    It 'declares a trigger for every skill, so no skill is dead weight' {
        # The other direction. A skill nothing loads costs nothing at runtime and
        # hides a gap: this is what would have caught the whole tree being absent.
        # A captain-invocable skill's trigger is the slash command, so either
        # spelling counts; -like is not usable here because its own escape
        # character is the backtick these names are wrapped in.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'AGENTS.md'))
        $undeclared = @(Get-FmSkillDefinition -RepoRoot $script:RepoRoot |
                Where-Object { -not ($contract.Contains("``$($_.Name)``") -or $contract.Contains("/$($_.Name)")) } |
                ForEach-Object { $_.Name })
        ($undeclared -join ', ') | Should -Be ''
    }

    It 'names only entry points that exist, in the contract and in every skill' {
        # The dead-pointer direction again, for commands rather than skill names.
        # Porting a procedure means retargeting the script it drives; a leftover
        # bin/fm-thing.ps1 that was never ported reads exactly like one that was,
        # and the model finds out by running it. Both surfaces are checked
        # together because a skill is loaded ON TOP of the contract, so a dead
        # pointer in either lands in the same session.
        $files = @((Join-Path $script:RepoRoot 'AGENTS.md')) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.agents/skills') -Recurse -Filter 'SKILL.md' |
                ForEach-Object { $_.FullName })
        $files.Count | Should -BeGreaterThan 10

        $dead = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $text = [System.IO.File]::ReadAllText($file)
            foreach ($m in [regex]::Matches($text, 'bin/(?<script>fm-[a-z0-9-]+\.ps1)')) {
                $named = $m.Groups['script'].Value
                if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot "bin/$named"))) {
                    $dead.Add("$(Split-Path -Leaf (Split-Path -Parent $file))/$(Split-Path -Leaf $file): $named")
                }
            }
        }
        ($dead | Sort-Object -Unique) -join '; ' | Should -Be ''
    }

    It 'counts the gap-recording skills correctly where section 13 states how many there are' {
        # Found by a real claude session reading the shipped contract on the
        # captain's laptop: the sentence said "Four more skills" and then named
        # five. Nothing failed - a miscount in an always-loaded instruction just
        # teaches the model something untrue, and the only reader that had ever
        # checked was the model itself. The stated number and the names beside
        # it are one fact written twice, so the file must agree with itself.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'AGENTS.md'))
        $words = @{ one = 1; two = 2; three = 3; four = 4; five = 5; six = 6; seven = 7; eight = 8; nine = 9; ten = 10 }

        $sentence = [regex]::Match($contract, '(?m)^(?<count>\w+) skills exist only to record a capability this port does not have[^\n]*')
        $sentence.Success | Should -BeTrue -Because 'section 13 must state how many gap-recording skills there are'

        $stated = $words[$sentence.Groups['count'].Value.ToLowerInvariant()]
        $stated | Should -Not -BeNullOrEmpty -Because "'$($sentence.Groups['count'].Value)' must be a number word"

        $named = @([regex]::Matches($sentence.Value, '`(?<name>[a-z0-9-]+)`') |
                ForEach-Object { $_.Groups['name'].Value })
        $stated | Should -Be $named.Count -Because "the contract says $stated and names $($named.Count): $($named -join ', ')"

        # And the names are the same set the not-ported skills themselves declare.
        $declared = @(Get-FmSkillDefinition -RepoRoot $script:RepoRoot |
                Where-Object { $_.Description -match '(?i)NOT AVAILABLE' } |
                ForEach-Object { $_.Name } | Sort-Object)
        (($named | Sort-Object) -join ', ') | Should -Be ($declared -join ', ')
    }

    It 'ports every skill the Linux firstmate loads, present or explicitly absent' {
        # A quiet omission hides a missing capability from the captain, which is
        # the one outcome this port must not produce. A skill whose subject
        # matter is not supported here is kept and says so; it is never dropped.
        $expected = @(
            'afk', 'ahoy', 'ask-user-authority', 'bearings', 'bootstrap-diagnostics',
            'decision-hold-lifecycle', 'diagnostic-reasoning', 'firstmate-codexapp',
            'firstmate-coding-guidelines', 'firstmate-orca', 'fmx-respond', 'harness-adapters',
            'process-event-sources', 'project-management', 'quota-array-dispatch',
            'secondmate-provisioning', 'stow', 'stuck-crewmate-recovery', 'updatefirstmate'
        )
        $present = @(Get-FmSkillDefinition -RepoRoot $script:RepoRoot | ForEach-Object { $_.Name })
        (@($expected | Where-Object { $present -notcontains $_ }) -join ', ') | Should -Be ''
    }

    It 'says plainly, in every not-ported skill, that the capability is absent' {
        # The stub's whole job. One that merely described the Linux machinery
        # would be worse than no skill at all, because it would promise it.
        foreach ($name in @('afk', 'fmx-respond', 'process-event-sources', 'firstmate-orca', 'firstmate-codexapp')) {
            $skill = @(Get-FmSkillDefinition -RepoRoot $script:RepoRoot | Where-Object { $_.Name -eq $name })[0]
            $text = [System.IO.File]::ReadAllText($skill.SkillFile)
            $text | Should -Match '(?i)not (available|ported)' -Because "$name must state the gap outright"
            # The description IS the trigger, so the gap has to be visible
            # without loading the skill at all.
            $skill.Description | Should -Match '(?i)NOT AVAILABLE' -Because "$name's description must name the gap"
        }
    }

    It 'lists every not-ported capability in the always-loaded contract' {
        # Section 14 is what a session knows WITHOUT loading a skill, so it is
        # the only place a gap is guaranteed to be seen.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'AGENTS.md'))
        $section = ($contract -split '## 14\. What this port does not have')[1]
        $section | Should -Not -BeNullOrEmpty
        foreach ($absent in @('no-mistakes', 'Away mode', 'Relay', 'voice channel', 'Remote secondmates')) {
            $section | Should -Match ([regex]::Escape($absent))
        }
    }

    It 'keeps the contract reachable under both names it is read by' {
        foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
            $path = Join-Path $script:RepoRoot $name
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            ([System.IO.File]::ReadAllText($path)) | Should -Match 'You are the first mate\.'
        }
    }

    It 'keeps contributor build memory out of the always-loaded contract' {
        # The whole reason this file was split. If these come back inline,
        # AGENTS.md has started growing into a manual again.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'AGENTS.md'))
        $contributing = Join-Path $script:RepoRoot 'CONTRIBUTING.md'
        Test-Path -LiteralPath $contributing -PathType Leaf | Should -BeTrue
        $contract | Should -Match 'CONTRIBUTING\.md'
        foreach ($buildRule in @('Invoke-ScriptAnalyzer', 'Invoke-Pester', 'PSScriptAnalyzerSettings')) {
            $contract | Should -Not -Match ([regex]::Escape($buildRule)) `
                -Because "$buildRule is contributor guidance and belongs in CONTRIBUTING.md"
        }
        ([System.IO.File]::ReadAllText($contributing)) | Should -Match 'Invoke-Pester'
    }
}
