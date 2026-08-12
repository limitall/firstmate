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
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Test seam stubs must declare their owner''s full published parameter list without using it; see the comment above.')]
param()
BeforeAll {
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
    BeforeEach { Mock Assert-FmTreehouseTool { $true } }

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
    It 'refuses to reset over uncommitted work in a pooled worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'dirty')
        Set-Content -LiteralPath (Join-Path $repo 'scratch.txt') -Value 'unlanded'
        Mock Invoke-FmGit {
            param($Directory, $Arguments)
            switch ($Arguments[0]) {
                'status' { return [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = "?? scratch.txt`n"; StdErr = ''; Combined = ''; TimedOut = $false } }
                'reset' { throw 'must never reset over unlanded work' }
                default { return [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = 'x'; StdErr = ''; Combined = ''; TimedOut = $false } }
            }
        }
        Mock Get-FmGitDefaultBranch { 'main' }
        Mock Get-FmGitOutput { 'deadbeef' }
        { Update-FmWorktreeBase -Worktree $repo -Confirm:$false } | Should -Throw '*refusing to discard uncommitted work*'
    }

    It 'refuses when origin cannot be fetched, rather than launching from a stale base' {
        Mock Invoke-FmGit {
            [pscustomobject]@{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = 'no origin'; Combined = ''; TimedOut = $false }
        }
        { Update-FmWorktreeBase -Worktree (Join-Path $TestDrive 'anything') -Confirm:$false } |
            Should -Throw '*could not fetch origin*'
    }

    It 'refuses when the reset did not land the expected commit' {
        Mock Invoke-FmGit { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false } }
        Mock Get-FmGitDefaultBranch { 'main' }
        $script:calls = 0
        Mock Get-FmGitOutput { $script:calls++; if ($script:calls -eq 1) { 'expected-sha' } else { 'other-sha' } }
        { Update-FmWorktreeBase -Worktree (Join-Path $TestDrive 'anything') -Confirm:$false } |
            Should -Throw "*is at 'other-sha', not current*"
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
