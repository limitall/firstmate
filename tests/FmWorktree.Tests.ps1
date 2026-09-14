#requires -Version 7.0
# Pester 5+/6 tests for worktree isolation.
#
# The isolation tests run against REAL git repositories created in TestDrive,
# because the guarantee they protect is a property of real repositories: a
# mocked `rev-parse` would only prove the mock agrees with itself. The
# treehouse calls are mocked - acquiring a real pooled worktree would mutate
# shared state on this machine.

# The seam stubs below declare their owner's full published parameter list and
# then ignore it, which is the point of the stub: a stub that dropped a name
# would make the caller's by-name invocation throw and its catch would read that
# as "no owner", and a stub declaring no parameters at all would swallow the
# arguments into $args unnoticed. PSReviewUnusedParameter is inverted here.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Test seam stubs must declare their owner''s full published parameter list without using it; see the comment above.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'FmSymlink.TestHelpers.ps1')

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmBackendHerdr.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmWorktree.ps1')

    function New-TestRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $Path)
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.name', 'Test')
        Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'seed'
        $null = Invoke-FmGit -Directory $Path -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $Path -Arguments @('commit', '-q', '-m', 'seed')
        $Path
    }
}

Describe 'Resolve-FmPhysicalPath' {
    It 'resolves a relative path to a fully qualified one' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Resolve-FmPhysicalPath -Path $dir | Should -Be ([System.IO.Path]::GetFullPath($dir))
    }

    It 'resolves an INTERMEDIATE symlinked component, not just the leaf' {
        Set-FmTestSymlinkSkip
        # This is the case that makes a leaf-only resolve compare unequal
        # against an OS-level cwd read and misfire the isolation guard.
        $real = Join-Path $TestDrive 'real'
        New-Item -ItemType Directory -Path (Join-Path $real 'inner') -Force | Out-Null
        $link = Join-Path $TestDrive 'link'
        New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'symlinks are not available here' }
        Resolve-FmPhysicalPath -Path (Join-Path $link 'inner') |
            Should -Be (Join-Path ([System.IO.Path]::GetFullPath($real)) 'inner')
    }

    It 'returns empty for a path that does not exist' {
        Resolve-FmPhysicalPath -Path (Join-Path $TestDrive 'ghost') | Should -Be ''
        Resolve-FmPhysicalPath -Path '' | Should -Be ''
    }

    It 'hands back the raw path when it cannot resolve, for the OrRaw contract' {
        $ghost = Join-Path $TestDrive 'ghost'
        Resolve-FmPhysicalPathOrRaw -Path $ghost | Should -Be $ghost
    }
}

Describe 'Test-FmPathEqual' {
    It 'ignores a trailing separator' {
        Test-FmPathEqual -Left (Join-Path $TestDrive 'a') -Right ((Join-Path $TestDrive 'a') + [System.IO.Path]::DirectorySeparatorChar) |
            Should -BeTrue
    }

    It 'uses the platform case rule' {
        # On Windows two spellings of one path MUST compare equal, or the
        # isolation guard would read them as two different checkouts.
        $expected = [bool]$IsWindows
        Test-FmPathEqual -Left '/Tmp/Thing' -Right '/tmp/thing' | Should -Be $expected
    }

    It 'never treats an empty path as equal to anything' {
        Test-FmPathEqual -Left '' -Right '' | Should -BeFalse
        Test-FmPathEqual -Left '' -Right '/tmp' | Should -BeFalse
    }
}

Describe 'Test-FmWorktreeIsolation' {
    BeforeAll {
        $script:primary = New-TestRepo -Path (Join-Path $TestDrive 'primary')
        $script:worktree = Join-Path $TestDrive 'wt-alpha'
        $null = Invoke-FmGit -Directory $script:primary -Arguments @('worktree', 'add', '-q', '-b', 'alpha', $script:worktree)
    }

    It 'accepts a genuine separate worktree of the same repository' {
        $verdict = Test-FmWorktreeIsolation -Worktree $script:worktree -PrimaryCheckout $script:primary
        $verdict.Isolated | Should -BeTrue
        $verdict.Reason | Should -Be ''
    }

    It 'refuses the primary checkout itself' {
        $verdict = Test-FmWorktreeIsolation -Worktree $script:primary -PrimaryCheckout $script:primary
        $verdict.Isolated | Should -BeFalse
        $verdict.Reason | Should -Match 'IS the primary checkout'
    }

    It 'refuses a SUBDIRECTORY of the primary checkout' {
        # A subdirectory resolves fine and is inside a git worktree, so only
        # the "is it the worktree ROOT" leg catches it - which is exactly why
        # that leg exists.
        $sub = Join-Path $script:primary 'src'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $verdict = Test-FmWorktreeIsolation -Worktree $sub -PrimaryCheckout $script:primary
        $verdict.Isolated | Should -BeFalse
        $verdict.Reason | Should -Match 'not a worktree root'
    }

    It 'refuses a directory that is not a git worktree at all' {
        $plain = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        (Test-FmWorktreeIsolation -Worktree $plain -PrimaryCheckout $script:primary).Reason |
            Should -Match 'not inside a git worktree'
    }

    It 'refuses a path that does not exist' {
        (Test-FmWorktreeIsolation -Worktree (Join-Path $TestDrive 'ghost') -PrimaryCheckout $script:primary).Reason |
            Should -Match 'did not resolve'
    }

    It 'stops the task rather than warning, when asserted' {
        { Assert-FmWorktreeIsolation -Worktree $script:primary -PrimaryCheckout $script:primary -Source 'treehouse get --lease' } |
            Should -Throw '*refusing to launch to avoid tangling the primary checkout*'
    }

    It 'returns the verdict when the assertion passes' {
        (Assert-FmWorktreeIsolation -Worktree $script:worktree -PrimaryCheckout $script:primary).Isolated | Should -BeTrue
    }
}

Describe 'New-FmWorktreeLease' {
    BeforeAll {
        $script:project = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path $script:project -Force | Out-Null
        $script:leased = Join-Path $TestDrive 'leased'
        New-Item -ItemType Directory -Path $script:leased -Force | Out-Null
    }
    BeforeEach {
        Mock Assert-FmTreehouseTool { $true }
        # The project has a commit; the no-commit refusal has its own block below.
        Mock Invoke-FmGit { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = "0123abcd`n"; StdErr = ''; Combined = ''; TimedOut = $false } }
    }

    It 'reads the path and lease identity from --json output' {
        $body = @{ path = $script:leased; lease_id = 'L-1'; lease_holder = 'fm-alpha'; name = 'pool-3' } | ConvertTo-Json
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = $body; StdErr = 'banner'; Combined = $body; TimedOut = $false }
        }.GetNewClosure()
        $lease = New-FmWorktreeLease -Project $script:project -LeaseHolder 'fm-alpha' -Confirm:$false
        $lease.Path | Should -Be $script:leased
        $lease.LeaseId | Should -Be 'L-1'
        Should -Invoke Invoke-FmChildProcess -Times 1 -ParameterFilter {
            $ArgumentList -contains '--lease' -and $ArgumentList -contains '--lease-holder'
        }
    }

    It 'falls back to the documented plain --lease contract: stdout is the path' {
        $plain = $script:leased
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = "$plain`n"; StdErr = 'banner'; Combined = $plain; TimedOut = $false }
        }.GetNewClosure()
        (New-FmWorktreeLease -Project $script:project -Confirm:$false).Path | Should -Be $plain
    }

    It 'refuses when treehouse failed' {
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = 'pool exhausted'; Combined = 'pool exhausted'; TimedOut = $false }
        }
        { New-FmWorktreeLease -Project $script:project -Confirm:$false } | Should -Throw '*pool exhausted*'
    }

    It 'refuses when nothing usable was printed' {
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false }
        }
        { New-FmWorktreeLease -Project $script:project -Confirm:$false } |
            Should -Throw '*printed no usable worktree path*'
    }

    It 'refuses when the reported path is not a directory' {
        $body = @{ path = (Join-Path $TestDrive 'ghost-wt'); lease_id = 'L-2' } | ConvertTo-Json
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = $body; StdErr = ''; Combined = $body; TimedOut = $false }
        }.GetNewClosure()
        { New-FmWorktreeLease -Project $script:project -Confirm:$false } | Should -Throw '*not a directory*'
    }
}

Describe 'New-FmWorktreeLease on a repository with no commits' {
    It 'refuses before asking treehouse, naming the missing commit rather than a missing origin' {
        # Exactly what New-FmProject creates. treehouse's own refusal for it
        # names 'refs/remotes/origin/main', a remote the project never had.
        $empty = Join-Path $TestDrive 'empty-project'
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $empty)
        Mock Assert-FmTreehouseTool { $true }
        # git runs for real; a real treehouse would build a pool on this machine.
        Mock Invoke-FmGit {
            $stdout = & git -C $Directory @Arguments 2>$null
            [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); ExitCode = $LASTEXITCODE; StdOut = ($stdout -join "`n"); StdErr = ''; Combined = ''; TimedOut = $false }
        }
        Mock Invoke-FmChildProcess -ParameterFilter { $FilePath -eq 'treehouse' } { throw 'treehouse must not be asked for a copy of an empty repository' }
        { New-FmWorktreeLease -Project $empty -Confirm:$false } | Should -Throw "*has no commits yet*"
    }
}

Describe 'Remove-FmWorktreeLease' {
    BeforeEach { Mock Assert-FmTreehouseTool { $true } }

    It 'releases conditionally on the exact lease identity' {
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false }
        }
        Remove-FmWorktreeLease -Path '/wt/alpha' -IfLeaseId 'L-1' -Confirm:$false | Should -BeTrue
        Should -Invoke Invoke-FmChildProcess -Times 1 -ParameterFilter {
            $ArgumentList -contains '--if-lease-id' -and $ArgumentList -contains 'L-1'
        }
    }

    It 'reports a failed release rather than claiming one' {
        Mock Invoke-FmChildProcess {
            [pscustomobject]@{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = 'lease held by another holder'; Combined = ''; TimedOut = $false }
        }
        Remove-FmWorktreeLease -Path '/wt/alpha' -IfLeaseId 'L-1' -Confirm:$false -WarningAction SilentlyContinue |
            Should -BeFalse
    }
}

Describe 'Update-FmWorktreeBase' {
    # Real repositories, shaped the way a pool slot is: a project checkout, an
    # optional bare origin, and a detached linked worktree that shares the
    # project's refs. Which commit a worker starts on is a property of those
    # refs, so a mocked rev-parse could not show it.
    BeforeAll {
        function New-BaseFixture {
            param([Parameter(Mandatory)][string]$Name, [switch]$NoOrigin)
            $root = Join-Path $TestDrive $Name
            $project = New-TestRepo -Path (Join-Path $root 'project')
            if (-not $NoOrigin) {
                $bare = Join-Path $root 'origin.git'
                $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '--bare', '-b', 'main', $bare)
                $null = Invoke-FmGit -Directory $project -Arguments @('remote', 'add', 'origin', $bare)
                $null = Invoke-FmGit -Directory $project -Arguments @('push', '-q', 'origin', 'main')
                $null = Invoke-FmGit -Directory $project -Arguments @('fetch', '-q', 'origin')
            }
            $seed = Get-FmGitOutput -Directory $project -Arguments @('rev-parse', 'main')
            $worktree = Join-Path $root 'slot'
            $null = Invoke-FmGit -Directory $project -Arguments @('worktree', 'add', '-q', '--detach', $worktree, $seed)
            [pscustomobject]@{ Project = $project; Worktree = $worktree; Seed = $seed }
        }

        # A commit landed on the project's local default branch only, the way
        # a local-only merge lands one.
        function Add-LocalCommit {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Message)
            Set-Content -LiteralPath (Join-Path $Fixture.Project 'README.md') -Value $Message
            $null = Invoke-FmGit -Directory $Fixture.Project -Arguments @('commit', '-q', '-am', $Message)
            Get-FmGitOutput -Directory $Fixture.Project -Arguments @('rev-parse', 'main')
        }

        # A commit that reaches origin's default branch without touching the
        # local one, the way a merged pull request does.
        function Add-OriginCommit {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Message, [string]$Parent = '')
            if (-not $Parent) { $Parent = $Fixture.Seed }
            $sha = Get-FmGitOutput -Directory $Fixture.Project -Arguments @('commit-tree', "$Parent^{tree}", '-p', $Parent, '-m', $Message)
            $null = Invoke-FmGit -Directory $Fixture.Project -Arguments @('push', '-q', '--force', 'origin', "$sha`:refs/heads/main")
            $sha
        }

        function Get-SlotHead {
            param([Parameter(Mandatory)]$Fixture)
            Get-FmGitOutput -Directory $Fixture.Worktree -Arguments @('rev-parse', 'HEAD')
        }
    }

    It 'starts on the local default branch when origin is a stale mirror behind it' {
        # The defect this refresh had: origin/main was reset to, and every
        # worker started behind the work local-only merges had already landed.
        $fixture = New-BaseFixture -Name 'stale-origin'
        $null = Add-LocalCommit -Fixture $fixture -Message 'landed one'
        $landed = Add-LocalCommit -Fixture $fixture -Message 'landed two'
        Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false | Should -BeTrue
        Get-SlotHead -Fixture $fixture | Should -Be $landed
    }

    It 'starts on origin when origin is ahead of the local default branch' {
        $fixture = New-BaseFixture -Name 'origin-ahead'
        $merged = Add-OriginCommit -Fixture $fixture -Message 'merged upstream'
        Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false | Should -BeTrue
        Get-SlotHead -Fixture $fixture | Should -Be $merged
    }

    It 'starts on the local default branch of a project with no origin at all' {
        # What New-FmProject creates. There is nothing remote to be stale
        # against, so the missing remote is not a reason to refuse the spawn.
        $fixture = New-BaseFixture -Name 'no-origin' -NoOrigin
        $landed = Add-LocalCommit -Fixture $fixture -Message 'landed'
        Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false | Should -BeTrue
        Get-SlotHead -Fixture $fixture | Should -Be $landed
    }

    It 'refuses diverged tips, naming how far apart they are, and leaves the slot where it was' {
        $fixture = New-BaseFixture -Name 'diverged'
        $null = Add-LocalCommit -Fixture $fixture -Message 'only local'
        $null = Add-OriginCommit -Fixture $fixture -Message 'only on origin'
        { Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false } |
            Should -Throw "*have diverged*(local is 1 ahead and 1 behind)*refusing to launch from either*"
        Get-SlotHead -Fixture $fixture | Should -Be $fixture.Seed
    }

    It 'refuses uncommitted work before it fetches anything' {
        # The origin is unreachable on purpose: only a clean check that runs
        # first can answer "not clean" here rather than "could not fetch".
        $fixture = New-BaseFixture -Name 'dirty' -NoOrigin
        $null = Invoke-FmGit -Directory $fixture.Project -Arguments @('remote', 'add', 'origin', (Join-Path $TestDrive 'no-such-origin.git'))
        Set-Content -LiteralPath (Join-Path $fixture.Worktree 'scratch.txt') -Value 'unlanded'
        { Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false } |
            Should -Throw '*is not clean; refusing to discard uncommitted work*'
        Get-Content -LiteralPath (Join-Path $fixture.Worktree 'scratch.txt') | Should -Be 'unlanded'
    }

    It 'refuses when a configured origin cannot be fetched, rather than launching from a stale base' {
        $fixture = New-BaseFixture -Name 'unreachable' -NoOrigin
        $null = Invoke-FmGit -Directory $fixture.Project -Arguments @('remote', 'add', 'origin', (Join-Path $TestDrive 'no-such-origin.git'))
        { Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false } |
            Should -Throw '*could not fetch origin*'
        Get-SlotHead -Fixture $fixture | Should -Be $fixture.Seed
    }

    It 'never drags a branch the slot was handed out on to the new base' {
        # Origin moves rather than local main, so the only thing that can keep
        # the branch in place is the detach, not a missing remote.
        $fixture = New-BaseFixture -Name 'on-a-branch'
        $null = Invoke-FmGit -Directory $fixture.Worktree -Arguments @('switch', '-q', '-c', 'fm/earlier-lane')
        $merged = Add-OriginCommit -Fixture $fixture -Message 'merged upstream'
        Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false | Should -BeTrue
        Get-SlotHead -Fixture $fixture | Should -Be $merged
        Get-FmGitOutput -Directory $fixture.Project -Arguments @('rev-parse', 'fm/earlier-lane') | Should -Be $fixture.Seed
        Get-FmGitOutput -Directory $fixture.Worktree -Arguments @('symbolic-ref', '--quiet', 'HEAD') | Should -Be ''
    }

    It 'refuses when the reset did not land the expected commit' {
        $fixture = New-BaseFixture -Name 'reset-lies' -NoOrigin
        $landed = Add-LocalCommit -Fixture $fixture -Message 'landed'
        # Every other git call still runs for real; only the reset reports a
        # success it did not have.
        Mock Invoke-FmGit {
            Invoke-FmChildProcess -FilePath 'git' -ArgumentList (@('-C', $Directory) + $Arguments)
        }
        Mock Invoke-FmGit -ParameterFilter { $Arguments[0] -eq 'reset' } {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false }
        }
        { Update-FmWorktreeBase -Worktree $fixture.Worktree -Confirm:$false } |
            Should -Throw "*is at '$($fixture.Seed)', not current 'main' ('$landed')*"
    }
}

Describe 'Get-FmGitDefaultBranch' {
    It 'falls back to a local main when origin/HEAD is unset' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'nodefault')
        Get-FmGitDefaultBranch -Directory $repo | Should -Be 'main'
    }
}

Describe 'New-FmIsolatedWorktree' {
    It 'releases the lease when the isolation check refuses' {
        # The whole point: a refused spawn must leave no worktree reserved to a
        # task that never started.
        Mock New-FmWorktreeLease { [pscustomobject]@{ Path = '/wt/alpha'; LeaseId = 'L-9'; LeaseHolder = ''; Name = ''; Project = '/proj' } }
        Mock Assert-FmWorktreeIsolation { throw 'error: not isolated' }
        Mock Update-FmWorktreeBase { throw 'base refresh must not run after a refusal' }
        Mock Remove-FmWorktreeLease { $true }
        { New-FmIsolatedWorktree -Project '/proj' -Confirm:$false } | Should -Throw '*not isolated*'
        Should -Invoke Remove-FmWorktreeLease -Times 1 -ParameterFilter { $IfLeaseId -eq 'L-9' }
    }

    It 'releases the lease when the pooled base could not be refreshed' {
        Mock New-FmWorktreeLease { [pscustomobject]@{ Path = '/wt/alpha'; LeaseId = 'L-9'; LeaseHolder = ''; Name = ''; Project = '/proj' } }
        Mock Assert-FmWorktreeIsolation { [pscustomobject]@{ Isolated = $true } }
        Mock Update-FmWorktreeBase { throw 'error: not clean' }
        Mock Remove-FmWorktreeLease { $true }
        { New-FmIsolatedWorktree -Project '/proj' -Confirm:$false } | Should -Throw '*not clean*'
        Should -Invoke Remove-FmWorktreeLease -Times 1
    }

    It 'returns the lease when acquisition, isolation and refresh all pass' {
        Mock New-FmWorktreeLease { [pscustomobject]@{ Path = '/wt/alpha'; LeaseId = 'L-9'; LeaseHolder = ''; Name = ''; Project = '/proj' } }
        Mock Assert-FmWorktreeIsolation { [pscustomobject]@{ Isolated = $true } }
        Mock Update-FmWorktreeBase { $true }
        Mock Remove-FmWorktreeLease { throw 'must not release a good lease' }
        (New-FmIsolatedWorktree -Project '/proj' -Confirm:$false).Path | Should -Be '/wt/alpha'
    }

    It 'skips the base refresh when asked' {
        Mock New-FmWorktreeLease { [pscustomobject]@{ Path = '/wt/alpha'; LeaseId = 'L-9'; LeaseHolder = ''; Name = ''; Project = '/proj' } }
        Mock Assert-FmWorktreeIsolation { [pscustomobject]@{ Isolated = $true } }
        Mock Update-FmWorktreeBase { throw 'base refresh must not run when skipped' }
        (New-FmIsolatedWorktree -Project '/proj' -SkipBaseRefresh -Confirm:$false).LeaseId | Should -Be 'L-9'
    }
}
