#requires -Version 7.0
# Pester 5+/6 tests for the project-clone refresh.
#
# Every test drives REAL git repositories: an "upstream" bare-ish repo and a
# clone of it in a fixture projects dir. Fleet sync's whole value is what it
# refuses to do to a repository in an awkward state, and that can only be shown
# against git's own answers - a mocked merge-base would prove nothing.
#
# The expected strings are the bash strings. They are a contract: a session-start
# refresh relays them and other tooling matches on them.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function Invoke-TestGit {
        param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string[]]$Arguments)
        $result = Invoke-FmGit -Directory $Directory -Arguments $Arguments
        if (-not $result.Ok) { throw "git $($Arguments -join ' ') failed in $Directory`: $($result.StdErr)" }
        $result
    }

    function New-TestCommit {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
        Set-Content -LiteralPath (Join-Path $Path $Name) -Value $Name
        $null = Invoke-TestGit -Directory $Path -Arguments @('add', '-A')
        $null = Invoke-TestGit -Directory $Path -Arguments @('commit', '-q', '-m', $Name)
    }

    # An upstream repository plus a clone of it under <root>/projects/<name>.
    function New-TestFleet {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Name = 'thing')
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $projects = Join-Path $root 'projects'
        New-Item -ItemType Directory -Path $projects -Force | Out-Null
        $upstream = Join-Path $root 'upstream'
        New-Item -ItemType Directory -Path $upstream -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $upstream)
        $null = Invoke-TestGit -Directory $upstream -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-TestGit -Directory $upstream -Arguments @('config', 'user.name', 'Test')
        # A non-bare upstream cannot receive a push to its checked-out branch,
        # so upstream commits are made here and the clone fetches them.
        New-TestCommit -Path $upstream -Name 'seed.txt'

        $clone = Join-Path $projects $Name
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('clone', '-q', '--', $upstream, $clone)
        $null = Invoke-TestGit -Directory $clone -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-TestGit -Directory $clone -Arguments @('config', 'user.name', 'Test')

        [pscustomobject]@{
            Root     = $root
            Projects = $projects
            Upstream = $upstream
            Clone    = $clone
            Name     = $Name
            Registry = Join-Path $root 'projects.md'
        }
    }

    function Set-TestRegistry {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([Parameter(Mandatory)]$Fleet, [Parameter(Mandatory)][string]$Mode)
        [System.IO.File]::WriteAllText($Fleet.Registry,
            "# Projects`n`n- $($Fleet.Name) [$Mode] - fixture (added 2026-01-01)`n")
    }
}

Describe 'Get-FmFleetSyncKnob' {
    It 'keeps the default when the override is unusable, rather than removing the bound' {
        Get-FmFleetSyncKnob -Value '' -Default 3 | Should -Be 3
        Get-FmFleetSyncKnob -Value 'lots' -Default 3 | Should -Be 3
        Get-FmFleetSyncKnob -Value '1.5' -Default 3 | Should -Be 3
        Get-FmFleetSyncKnob -Value '7' -Default 3 | Should -Be 7
        Get-FmFleetSyncKnob -Value '1.5' -Default 1 -AllowFraction | Should -Be 1.5
    }
}

Describe 'Test-FmFleetSyncPackedRefsLockError' {
    It 'matches the packed-refs lock race wherever git prefixes it' {
        Test-FmFleetSyncPackedRefsLockError -Text "error: could not delete reference refs/x: Unable to create '/r/.git/packed-refs.lock': File exists" |
            Should -BeTrue
    }

    It 'does not match other File exists errors' {
        Test-FmFleetSyncPackedRefsLockError -Text "fatal: Unable to create '/r/.git/index.lock': File exists" | Should -BeFalse
        Test-FmFleetSyncPackedRefsLockError -Text '' | Should -BeFalse
    }
}

Describe 'Test-FmFleetSyncStaleLock' {
    # Provably stale = old enough AND proof that nothing holds it. This area
    # owns only the age half; the holder verdict is the teardown area's
    # Test-FmTeardownGitLockHeld, and 'free' is the only verdict that proves
    # anything. Every other answer leaves the lock alone, which is the bash
    # rule (no lsof, no proof) carried over intact.
    It 'calls a young lock live even when nothing holds it' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Set-Content -LiteralPath $lock -Value 'lock'
        Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds 3600 | Should -BeFalse
    }

    It 'calls an old lock provably stale only when the holder probe says free' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Set-Content -LiteralPath $lock -Value 'lock'
        (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        Mock Test-FmTeardownGitLockHeld { 'free' }
        Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds 30 | Should -BeTrue
    }

    It 'leaves an old lock alone when the holder probe says held, or cannot tell' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Set-Content -LiteralPath $lock -Value 'lock'
        (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        foreach ($verdict in @('held', 'unknown', 'absent')) {
            Mock Test-FmTeardownGitLockHeld { $verdict }.GetNewClosure()
            Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds 30 |
                Should -BeFalse -Because "'$verdict' is not proof that the lock is free"
        }
    }

    It 'treats a throwing holder probe as unknown rather than as free' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Set-Content -LiteralPath $lock -Value 'lock'
        (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        Mock Test-FmTeardownGitLockHeld { throw 'probe exploded' }
        Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds 30 | Should -BeFalse
    }

    It 'never claims proof on a POSIX host, where an exclusive open proves nothing' {
        # Advisory locking: a live git process holding the lock still lets an
        # exclusive open through, so this must not read as "provably stale".
        # Exercised against the real probe, not a mock.
        if ($IsWindows) { Set-ItResult -Skipped -Because 'this is the POSIX rule' }
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Set-Content -LiteralPath $lock -Value 'lock'
        (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds 30 | Should -BeFalse
    }

    It 'calls a missing lock not-stale, so nothing is removed on a guess' {
        Test-FmFleetSyncStaleLock -Path (Join-Path $TestDrive 'no-such-lock') -AgeSeconds 1 | Should -BeFalse
    }
}

Describe 'Sync-FmProjectClone' {
    It 'fast-forwards a clone that is behind origin' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        New-TestCommit -Path $fleet.Upstream -Name 'newer.txt'
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: synced *..*'
        Test-Path -LiteralPath (Join-Path $fleet.Clone 'newer.txt') | Should -BeTrue
    }

    It 'reports an up-to-date clone as already current' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Contain 'thing: already current'
    }

    It 'skips a local-only project because its registered posture says so' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'local-only'
        @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Be @('thing: skipped: local-only project')
    }

    It 'skips a directory that is not a directory or not a git repo' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        @(Sync-FmProjectClone -Path (Join-Path $fleet.Projects 'ghost') -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Be @('ghost: skipped: not a directory')
        $plain = Join-Path $fleet.Projects 'plain'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        @(Sync-FmProjectClone -Path $plain -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Be @('plain: skipped: not a git repo')
    }

    It 'skips a clone with no origin remote' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('remote', 'remove', 'origin')
        @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Be @('thing: skipped: no origin remote')
    }

    It 'leaves a clone on a non-default branch alone and reports it STUCK with a count' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        New-TestCommit -Path $fleet.Upstream -Name 'newer.txt'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('checkout', '-q', '-b', 'sidequest')
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: STUCK: on branch sidequest, 1 commits behind origin/main - needs attention*'
        Get-FmGitOutput -Directory $fleet.Clone -Arguments @('symbolic-ref', '--short', 'HEAD') | Should -Be 'sidequest'
    }

    It 'leaves a dirty clone alone and says so in the STUCK state' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        New-TestCommit -Path $fleet.Upstream -Name 'newer.txt'
        Set-Content -LiteralPath (Join-Path $fleet.Clone 'scratch.txt') -Value 'uncommitted'
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*STUCK: on branch main with uncommitted changes*'
        Get-Content -LiteralPath (Join-Path $fleet.Clone 'scratch.txt') | Should -Be 'uncommitted'
    }

    It 're-attaches a clean detached HEAD that holds no unique commits, then syncs it' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('checkout', '-q', '--detach', 'HEAD')
        New-TestCommit -Path $fleet.Upstream -Name 'newer.txt'
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: recovered: re-attached main, synced *..*'
        Get-FmGitOutput -Directory $fleet.Clone -Arguments @('symbolic-ref', '--short', 'HEAD') | Should -Be 'main'
    }

    It 'reports a re-attached clone that was already current as recovered, not synced' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('checkout', '-q', '--detach', 'HEAD')
        @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Contain 'thing: recovered: re-attached main (already current)'
    }

    It 'refuses to re-attach a detached HEAD that holds unique commits' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('checkout', '-q', '--detach', 'HEAD')
        New-TestCommit -Path $fleet.Clone -Name 'unique.txt'
        $head = Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD')
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*STUCK: on detached HEAD with unique commits*'
        Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'reports a diverged default branch and never rewrites it' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        New-TestCommit -Path $fleet.Upstream -Name 'theirs.txt'
        New-TestCommit -Path $fleet.Clone -Name 'ours.txt'
        $head = Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD')
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: STUCK: on diverged main, 1 commits behind origin/main - needs attention*'
        Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'prunes a branch whose upstream is gone' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        # A branch on the upstream, tracked here, then deleted upstream.
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', 'landed')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('fetch', '-q', 'origin')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('branch', '--track', 'landed', 'origin/landed')
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', '-D', 'landed')
        @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Contain 'thing: pruned landed'
        (Invoke-FmGit -Directory $fleet.Clone -Arguments @('rev-parse', '--verify', '--quiet', 'refs/heads/landed')).Ok |
            Should -BeFalse
    }

    It 'never prunes a branch that still has a worktree' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', 'inflight')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('fetch', '-q', 'origin')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('branch', '--track', 'inflight', 'origin/inflight')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('worktree', 'add', '-q',
            (Join-Path $fleet.Root 'wt'), 'inflight')
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', '-D', 'inflight')
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        $lines | Should -Not -Contain 'thing: pruned inflight'
        (Invoke-FmGit -Directory $fleet.Clone -Arguments @('rev-parse', '--verify', '--quiet', 'refs/heads/inflight')).Ok |
            Should -BeTrue
    }

    It 'skips pruning entirely when FM_FLEET_PRUNE=0' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', 'landed')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('fetch', '-q', 'origin')
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('branch', '--track', 'landed', 'origin/landed')
        $null = Invoke-TestGit -Directory $fleet.Upstream -Arguments @('branch', '-D', 'landed')
        $previous = $env:FM_FLEET_PRUNE
        try {
            $env:FM_FLEET_PRUNE = '0'
            $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
            $lines | Should -Not -Contain 'thing: pruned landed'
        } finally {
            $env:FM_FLEET_PRUNE = $previous
        }
        (Invoke-FmGit -Directory $fleet.Clone -Arguments @('rev-parse', '--verify', '--quiet', 'refs/heads/landed')).Ok |
            Should -BeTrue
    }

    It 'reports a fetch failure as a benign skip carrying git''s first line' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $null = Invoke-TestGit -Directory $fleet.Clone -Arguments @('remote', 'set-url', 'origin',
            (Join-Path $fleet.Root 'no-such-remote'))
        $lines = @(Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: skipped: fetch failed*'
    }

    It 'changes nothing under -WhatIf' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        New-TestCommit -Path $fleet.Upstream -Name 'newer.txt'
        $head = Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD')
        $null = Sync-FmProjectClone -Path $fleet.Clone -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry -WhatIf
        Get-FmGitOutput -Directory $fleet.Clone -Arguments @('rev-parse', 'HEAD') | Should -Be $head
    }
}

Describe 'Invoke-FmFleetSync' {
    It 'syncs every clone in the projects dir when given no argument' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        $second = Join-Path $fleet.Projects 'other'
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('clone', '-q', '--', $fleet.Upstream, $second)
        $lines = @(Invoke-FmFleetSync -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry)
        ($lines -join "`n") | Should -BeLike '*thing: already current*'
        ($lines -join "`n") | Should -BeLike '*other: already current*'
    }

    It 'syncs one clone by bare name' {
        $fleet = New-TestFleet
        Set-TestRegistry -Fleet $fleet -Mode 'direct-PR'
        @(Invoke-FmFleetSync -Project 'thing' -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Contain 'thing: already current'
    }

    It 'reports a bad single-project argument as a benign skip' {
        $fleet = New-TestFleet
        @(Invoke-FmFleetSync -Project 'nope' -ProjectsDir $fleet.Projects -RegistryPath $fleet.Registry) |
            Should -Be @('nope: skipped: not a directory')
    }

    It 'returns nothing when the home has no projects dir' {
        $empty = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        @(Invoke-FmFleetSync -ProjectsDir $empty) | Should -BeNullOrEmpty
    }
}
