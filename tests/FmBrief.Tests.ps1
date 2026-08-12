#requires -Version 7.0
# Brief tests. The generated text is a safety contract, so the whole body is
# compared byte for byte against fixtures captured from bin/fm-brief.sh - the
# same brief must come out of a Linux firstmate and this one.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures/brief'
    # The fixtures were generated with these paths; the comparison substitutes
    # whatever this run resolved, so the test is path- and platform-independent
    # while every other byte still has to match.
    $script:FixtureHome = '/tmp/fm-brief-fixture-home'
    $script:FixtureRoot = '/fm/root'

    # THE SEPARATOR IS THE PLATFORM'S, AND THAT IS DELIBERATE. On Windows these
    # come out `...\bin\fm-herdr-lab.sh`, and a native Windows port emitting a
    # native path is CORRECT: the repo's own rule is Join-Path and never a
    # hard-coded separator, and what the brief carries here is a real local
    # filesystem path on the machine the worker runs on. The byte contract the
    # fixtures exist to defend is the brief's GRAMMAR - its headings, its
    # `FIRSTMATE_OP:` marker, and the `Delivery contract: mode=` line that
    # Get-FmDispatchBriefMode actually parses back. No separator appears in any
    # of that, and nothing anywhere parses a PATH back out of a brief.
    #
    # So the fixture path is rebuilt with Join-Path rather than compared
    # literally - which is what this file already did for the status file, and
    # what its header already claims to do for all of them. It was only ever
    # applied to two of them, so `<root>/bin/...`, `<root>/.agents/...` and
    # `<home>/data/t1/report.md` still carried fixture slashes and failed on
    # Windows 11 while passing here. Every other byte still has to match.
    function Join-FmFixturePath {
        param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][AllowEmptyString()][string]$Relative)
        $result = $Base
        foreach ($segment in @($Relative -split '/' | Where-Object { $_ })) {
            $result = Join-Path $result $segment
        }
        return $result
    }

    # Rewrite every <prefix>/a/b/c under a fixture prefix, longest first so a
    # nested path is never half-substituted by its own parent.
    function Convert-FmFixturePath {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Prefix,
            [Parameter(Mandatory)][string]$Base
        )
        $pattern = [regex]::Escape($Prefix) + '(?:/[A-Za-z0-9._-]+)*'
        $seen = @($([regex]::Matches($Text, $pattern) | ForEach-Object { $_.Value }) |
                Sort-Object -Property Length -Descending -Unique)
        foreach ($match in $seen) {
            $Text = $Text.Replace($match, (Join-FmFixturePath -Base $Base -Relative $match.Substring($Prefix.Length)))
        }
        return $Text
    }

    function Get-ExpectedBrief {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)]$TestHome,
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Id
        )
        $text = [System.IO.File]::ReadAllText((Join-Path $script:FixtureDir "$Name.md"))
        $text = $text.Replace("$script:FixtureHome/state/$Id.status", (Join-Path $TestHome.State "$Id.status"))
        $text = Convert-FmFixturePath -Text $text -Prefix "$script:FixtureHome/data" -Base $TestHome.Data
        $text = Convert-FmFixturePath -Text $text -Prefix $script:FixtureRoot -Base $Root
        return $text
    }
}

Describe 'New-FmBrief generated text' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Root = Join-Path $script:TestHome.Path 'firstmate-root'
        [void](New-Item -ItemType Directory -Path $script:Root -Force)
        $env:FM_ROOT_OVERRIDE = $script:Root
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'matches the bash scaffolder for <Fixture>' -ForEach @(
        @{ Fixture = 'ship-no-mistakes'; Params = @{ Repo = 'acme/widget'; Mode = 'no-mistakes' } }
        @{ Fixture = 'ship-direct-pr'; Params = @{ Repo = 'acme/widget'; Mode = 'direct-PR' } }
        @{ Fixture = 'ship-local-only'; Params = @{ Repo = 'acme/widget'; Mode = 'local-only' } }
        @{ Fixture = 'ship-direct-pr-herdr'; Params = @{ Repo = 'acme/widget'; Mode = 'direct-PR'; HerdrLab = $true } }
        @{ Fixture = 'scout'; Params = @{ Repo = 'acme/widget'; Scout = $true } }
        @{ Fixture = 'scout-herdr'; Params = @{ Repo = 'acme/widget'; Scout = $true; HerdrLab = $true } }
        @{ Fixture = 'secondmate-projects'; Params = @{ Secondmate = $true; Project = @('proj-a', 'proj-b') } }
        @{ Fixture = 'secondmate-no-projects'; Params = @{ Secondmate = $true; NoProjects = $true; Charter = 'Own the release domain.'; Scope = 'Release and packaging work.' } }
    ) {
        $callArgs = $Params.Clone()
        $callArgs['Id'] = 't1'
        $result = New-FmBrief @callArgs
        $result.ExitCode | Should -Be 0
        $actual = [System.IO.File]::ReadAllText($result.Path)
        $expected = Get-ExpectedBrief -Name $Fixture -TestHome $script:TestHome -Root $script:Root -Id 't1'
        $actual | Should -BeExactly $expected
    }

    It 'writes LF-only UTF-8 with no BOM' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR'
        $bytes = [System.IO.File]::ReadAllBytes($result.Path)
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        @($bytes | Where-Object { $_ -eq 13 }).Count | Should -Be 0
        $bytes[-1] | Should -Be 10
    }

    It 'keeps the worktree-isolation assertion in every ship brief' -ForEach @(
        @{ Mode = 'no-mistakes' }, @{ Mode = 'direct-PR' }, @{ Mode = 'local-only' }
    ) {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode $Mode
        $text = [System.IO.File]::ReadAllText($result.Path)
        $text | Should -Match '\*\*Verify isolation before anything else\.\*\*'
        $text | Should -Match 'git rev-parse --show-toplevel'
        $text | Should -Match 'blocked: launched in primary checkout, not an isolated worktree'
        $text | Should -Match "Delivery contract: mode=$([regex]::Escape($Mode))"
    }

    It 'carries the loud Herdr declaration when the lab contract was not requested' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR'
        $text = [System.IO.File]::ReadAllText($result.Path)
        $text | Should -Match '# Herdr lifecycle declaration - NOT ENABLED'
        $text | Should -Match 'HARD SAFETY GATE'
        $text | Should -Not -Match '# Herdr isolation - HARD SAFETY CONTRACT'
    }

    It 'carries the hard Herdr isolation contract when it was requested' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR' -HerdrLab
        $text = [System.IO.File]::ReadAllText($result.Path)
        $text | Should -Match '# Herdr isolation - HARD SAFETY CONTRACT'
        $text | Should -Match 'fm-herdr-lab\.sh'
        $text | Should -Not -Match 'NOT ENABLED'
    }

    It 'keeps the keyed resolution rule in the status protocol' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR'
        $text = [System.IO.File]::ReadAllText($result.Path)
        $text | Should -Match 'stays open until a `resolved` line carrying its exact key lands'
        $text | Should -Match 'a later `done:` or `working:` line never closes it'
    }
}

Describe 'New-FmBrief refusals' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'refuses to overwrite an existing brief' {
        (New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR').ExitCode | Should -Be 0
        $second = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'direct-PR'
        $second.ExitCode | Should -Be 1
        ($second.Messages -join "`n") | Should -Match 'already exists'
    }

    It 'refuses an unknown delivery mode rather than defaulting' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'whatever'
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match '-Mode must be one of no-mistakes, direct-PR, local-only'
        Test-Path -LiteralPath (Join-Path $script:TestHome.Data 't1/brief.md') | Should -BeFalse
    }

    It 'refuses a registry policy used as a task mode' {
        $result = New-FmBrief -Id 't1' -Repo 'acme/widget' -Mode 'no-mistakes-prod-only'
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'registry policy, not a task mode'
    }

    It 'refuses a secondmate charter with neither projects nor -NoProjects' {
        $result = New-FmBrief -Id 't1' -Secondmate
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'requires at least one project'
    }

    It 'refuses -NoProjects combined with a project list' {
        $result = New-FmBrief -Id 't1' -Secondmate -NoProjects -Project @('proj-a')
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'cannot be combined with a project list'
    }

    It 'refuses a task id that is not a single path component' {
        (New-FmBrief -Id '../escape' -Repo 'acme/widget' -Mode 'direct-PR').ExitCode | Should -Be 1
    }

    It 'has no yolo input at all' {
        (Get-Command New-FmBrief).Parameters.Keys | Should -Not -Contain 'Yolo'
    }
}
