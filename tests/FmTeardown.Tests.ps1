#requires -Version 7.0
# Pester 5+/6 tests for teardown - the part of firstmate that must never destroy
# work.
#
# The landed-work tests run against REAL git repositories with a REAL bare
# origin, because every fact they assert is a property of real repositories:
# what `--not --remotes` reports, what `merge-tree --write-tree` produces for a
# squash-merged branch, and whether two commits with the same diff share a
# patch id. A mocked git would only prove the mock agrees with itself, and this
# is the one area where that is not good enough.
#
# gh, treehouse and herdr ARE mocked: they reach the network or mutate shared
# machine state.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmSymlink.TestHelpers.ps1')

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    # THE WHOLE TREE, in the loader's own order, not a hand-picked list.
    #
    # This suite used to load five files. That worked while teardown reached only
    # its immediate neighbours, and stopped working the moment the secondmate
    # retirement gate read that home's own backlog: pulling the backlog area in
    # made Test-FmTeardownTasksAxiBacklog stop taking its local fallback and
    # start calling the compatibility probe, whose own dependency was still not
    # loaded - so eleven UNRELATED teardown tests failed on a missing command.
    # A partial tree does not model anything a real session has; it just picks a
    # different arbitrary set of owners to be absent. Load them all, and stage a
    # genuine absence at the Resolve-Fm*Command seam where a test wants one.
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestOrigin {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester fixtures that build and remove disposable temp repos. -WhatIf on a fixture would leave the test asserting against a repo that was never created.')]
        param([Parameter(Mandatory)][string]$Path)
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '--bare', '-b', 'main', $Path)
        $Path
    }

    function New-TestClone {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester fixtures that build and remove disposable temp repos. -WhatIf on a fixture would leave the test asserting against a repo that was never created.')]
        param([Parameter(Mandatory)][string]$Origin, [Parameter(Mandatory)][string]$Path)
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('clone', '-q', $Origin, $Path)
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.name', 'Test')
        $Path
    }

    function Add-TestCommit {
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$File,
            [Parameter(Mandatory)][string]$Content,
            [string]$Message = 'change'
        )
        Set-Content -LiteralPath (Join-Path $Directory $File) -Value $Content -NoNewline
        $null = Invoke-FmGit -Directory $Directory -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $Directory -Arguments @('commit', '-q', '-m', $Message)
        Get-FmGitOutput -Directory $Directory -Arguments @('rev-parse', 'HEAD')
    }

    # A seeded origin, a project clone of it, and a task worktree on its own
    # branch - the exact shape teardown is handed.
    function New-TestFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester fixtures that build and remove disposable temp repos. -WhatIf on a fixture would leave the test asserting against a repo that was never created.')]
        param([Parameter(Mandatory)][string]$Root, [string]$Branch = 'fm/task')
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $origin = New-TestOrigin -Path (Join-Path $Root 'origin.git')
        $project = New-TestClone -Origin $origin -Path (Join-Path $Root 'project')
        $null = Add-TestCommit -Directory $project -File 'README.md' -Content 'seed' -Message 'seed'
        $null = Invoke-FmGit -Directory $project -Arguments @('push', '-q', '-u', 'origin', 'main')
        $worktree = Join-Path $Root 'wt'
        $null = Invoke-FmGit -Directory $project -Arguments @('worktree', 'add', '-q', '-b', $Branch, $worktree)
        $null = Invoke-FmGit -Directory $worktree -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $worktree -Arguments @('config', 'user.name', 'Test')
        [pscustomobject]@{ Origin = $origin; Project = $project; Worktree = $worktree; Branch = $Branch }
    }

    # Pester 6 has no "call the original" for a filtered mock: an unmatched call
    # is an error unless an unfiltered default exists. These captured originals
    # are what the default mocks delegate to, so mocking `gh` never also mocks
    # `git` - and the git behaviour under test stays real.
    $script:RealChildProcess = ${function:Invoke-FmChildProcess}
    $script:RealInvokeGit = ${function:Invoke-FmGit}
    $script:RealResolveOwner = ${function:Resolve-FmTeardownOwner}

    # A pid that is provably NOT running. 0 is not a safe choice: on Linux it
    # resolves to the kernel scheduler and reads as alive.
    function Get-DeadProcessId {
        $candidate = 999999
        while (Get-Process -Id $candidate -ErrorAction SilentlyContinue) { $candidate-- }
        $candidate
    }

    function New-ChildProcessResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester fixtures that build and remove disposable temp repos. -WhatIf on a fixture would leave the test asserting against a repo that was never created.')]
        param([bool]$Ok = $true, [int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '')
        [pscustomobject]@{
            Ok = $Ok; ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr
            Combined = ($StdOut + $StdErr); TimedOut = $false
        }
    }
}

# =============================================================================
# The stale-git-lock probe
# =============================================================================

Describe 'Test-FmTeardownGitLockHeld' {
    It 'reports an absent lock as absent' {
        Test-FmTeardownGitLockHeld -Path (Join-Path $TestDrive 'nope.lock') | Should -Be 'absent'
        Test-FmTeardownGitLockHeld -Path '' | Should -Be 'unknown'
    }

    It 'answers only where the answer means something' {
        # On Windows an exclusive open that succeeds PROVES no holder. On a
        # POSIX host it proves nothing, so the probe says 'unknown' - which
        # every caller treats exactly like 'held'. Claiming 'free' there would
        # delete a lock a live git is using.
        $lock = Join-Path $TestDrive 'free.lock'
        Set-Content -LiteralPath $lock -Value ''
        $expected = if ($IsWindows) { 'free' } else { 'unknown' }
        Test-FmTeardownGitLockHeld -Path $lock | Should -Be $expected
    }

    It 'reports a lock another handle holds exclusively as held' -Skip:(-not $IsWindows) {
        $lock = Join-Path $TestDrive 'held.lock'
        Set-Content -LiteralPath $lock -Value ''
        $stream = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', [System.IO.FileShare]::None)
        try {
            Test-FmTeardownGitLockHeld -Path $lock | Should -Be 'held'
        } finally {
            $stream.Dispose()
        }
    }
}

Describe 'Get-FmTeardownGitLockPath' {
    BeforeAll { $script:fixture = New-TestFixture -Root (Join-Path $TestDrive 'lockpath') }

    It 'resolves a LINKED worktree lock to the worktree''s own index.lock' {
        # Not the repository's .git/index.lock: a linked worktree has its own,
        # and removing the wrong one would be both useless and dangerous.
        $lock = Get-FmTeardownGitLockPath -Worktree $script:fixture.Worktree
        $lock | Should -Match 'index\.lock$'
        $lock | Should -Match 'worktrees'
        [System.IO.Path]::IsPathRooted($lock) | Should -BeTrue
    }

    It 'returns empty for a directory that is not a git worktree' {
        $plain = Join-Path $TestDrive 'plain-dir'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Get-FmTeardownGitLockPath -Worktree $plain | Should -Be ''
        Get-FmTeardownGitLockPath -Worktree (Join-Path $TestDrive 'ghost') | Should -Be ''
    }
}

Describe 'Test-FmTeardownGitLockStale' {
    BeforeAll {
        $script:lock = Join-Path $TestDrive 'stale.lock'
    }
    BeforeEach {
        Set-Content -LiteralPath $script:lock -Value ''
        # Old enough for the age leg, so each test isolates one other leg.
        [System.IO.File]::SetLastWriteTimeUtc($script:lock, [DateTime]::UtcNow.AddMinutes(-5))
        Mock Test-FmTeardownGitLockHeld { 'free' }
        Mock Test-FmTeardownDirectoryHeld { 'none' }
    }

    It 'is stale only when nothing holds it, nothing holds the worktree, and it is old' {
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeTrue
    }

    It 'is NOT stale when a live process holds the lock' {
        Mock Test-FmTeardownGitLockHeld { 'held' }
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }

    It 'is NOT stale when the holder question cannot be answered' {
        # The fail-safe rule, inherited verbatim from the bash: uncertainty is
        # treated as "live", never as "free".
        Mock Test-FmTeardownGitLockHeld { 'unknown' }
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }

    It 'is NOT stale when the worktree still has processes in custody' {
        Mock Test-FmTeardownDirectoryHeld { 'holders' }
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }

    It 'is NOT stale when custody cannot answer for the worktree' {
        Mock Test-FmTeardownDirectoryHeld { 'unknown' }
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }

    It 'is NOT stale while it is younger than the threshold' {
        # A freshly created lock may belong to a process nothing has reflected
        # yet.
        [System.IO.File]::SetLastWriteTimeUtc($script:lock, [DateTime]::UtcNow)
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }

    It 'is NOT stale when the lock does not exist' {
        Remove-Item -LiteralPath $script:lock -Force
        Test-FmTeardownGitLockStale -LockPath $script:lock -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
        Test-FmTeardownGitLockStale -LockPath '' -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }
}

Describe 'Test-FmTeardownDirectoryHeld' {
    It 'maps custody states to holder verdicts, defaulting to unknown' {
        Mock Get-FmTaskJobProcessId { [pscustomobject]@{ State = 'processes'; Ids = @(4242) } }
        Test-FmTeardownDirectoryHeld -TaskId 'alpha' | Should -Be 'holders'
        Mock Get-FmTaskJobProcessId { [pscustomobject]@{ State = 'empty'; Ids = @() } }
        Test-FmTeardownDirectoryHeld -TaskId 'alpha' | Should -Be 'none'
        Mock Get-FmTaskJobProcessId { [pscustomobject]@{ State = 'not-found'; Ids = @() } }
        Test-FmTeardownDirectoryHeld -TaskId 'alpha' | Should -Be 'unknown'
        Test-FmTeardownDirectoryHeld -TaskId '' | Should -Be 'unknown'
    }
}

Describe 'Test-FmTeardownIndexLockError' {
    It 'matches only the transient index.lock signature' {
        Test-FmTeardownIndexLockError -Text "fatal: Unable to create '/w/.git/index.lock': File exists" | Should -BeTrue
        Test-FmTeardownIndexLockError -Text 'Unable to create "C:\w\.git\worktrees\a\index.lock": File exists' | Should -BeTrue
        Test-FmTeardownIndexLockError -Text 'error: worktree is dirty' | Should -BeFalse
        Test-FmTeardownIndexLockError -Text "Unable to create '/w/.git/config.lock': File exists" | Should -BeFalse
        Test-FmTeardownIndexLockError -Text '' | Should -BeFalse
    }
}

# =============================================================================
# The complete landed-work test
# =============================================================================

Describe 'Test-FmTeardownWorktreeSafety' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:fx = New-TestFixture -Root $script:root
        Mock Invoke-FmChildProcess {
            # A mock body sees only the parameters the CALLER bound, so each
            # optional one is forwarded only when it is actually there.
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmGit {
            $splat = @{ Directory = $Directory; Arguments = $Arguments }
            if ($null -ne $TimeoutSeconds) { $splat['TimeoutSeconds'] = $TimeoutSeconds }
            & $script:RealInvokeGit @splat
        }
    }

    It 'allows a clean worktree with nothing unpushed' {
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'allow'
    }

    It 'REFUSES uncommitted changes - they are never landed' {
        Set-Content -LiteralPath (Join-Path $script:fx.Worktree 'README.md') -Value 'edited'
        $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'REFUSED: worktree .* has uncommitted changes'
        ($verdict.Message -join "`n") | Should -Match 'Commit them'
    }

    It 'REFUSES a staged-but-uncommitted change too' {
        Set-Content -LiteralPath (Join-Path $script:fx.Worktree 'new.txt') -Value 'x'
        $null = Invoke-FmGit -Directory $script:fx.Worktree -Arguments @('add', '-A')
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'refuse'
    }

    It 'lists at most five unpushed commits in the refusal' {
        1..7 | ForEach-Object {
            $null = Add-TestCommit -Directory $script:fx.Worktree -File "f$_.txt" -Content "$_" -Message "commit $_"
        }
        Mock Test-FmTeardownWorkLanded { $false }
        $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
        $verdict.Verdict | Should -Be 'refuse'
        # header line plus exactly five commits, then the remedy line
        $listed = @($verdict.Message | Where-Object { $_ -match '^[0-9a-f]{7,} ' })
        $listed.Count | Should -Be 5
    }

    It 'allows commits that ARE reachable from a remote-tracking branch' {
        # The plain landed case: pushed work needs no PR or content proof at all.
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'pushed.txt' -Content 'pushed'
        $null = Invoke-FmGit -Directory $script:fx.Worktree -Arguments @('push', '-q', 'origin', 'HEAD:refs/heads/pushed')
        Mock Test-FmTeardownWorkLanded { throw 'the landed-work test must not be reached for pushed work' }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'allow'
    }

    It 'REFUSES when the default branch has only PART of the work' {
        # Half a squash-merge is not a landing: merge-tree still adds something.
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'first.txt' -Content 'first'
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'second.txt' -Content 'second'
        $null = Add-TestCommit -Directory $script:fx.Project -File 'first.txt' -Content 'first' -Message 'only the first change'
        $null = Invoke-FmGit -Directory $script:fx.Project -Arguments @('push', '-q', 'origin', 'main')
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 } -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'refuse'
    }

    It 'REFUSES a directory that is not a git repository at all' {
        # No mock: a real non-repo directory makes every git read fail, and an
        # inspection that cannot run refuses exactly like unlanded work.
        $plain = Join-Path $script:root 'not-a-repo'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $verdict = Test-FmTeardownWorktreeSafety -Worktree $plain -Project $script:fx.Project
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'REFUSED: cannot inspect worktree .* for uncommitted changes'
    }

    It 'still REFUSES when a dropping-shaped name is a real change' {
        # `.claude-notes` is NOT the ignored pattern: only `?? .claude/` and the
        # exact turn-end markers are.
        Set-Content -LiteralPath (Join-Path $script:fx.Worktree '.claude-notes') -Value 'real work'
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'refuse'
    }

    It 'does NOT count firstmate''s own dropped-in hook files as uncommitted work' {
        New-Item -ItemType Directory -Path (Join-Path $script:fx.Worktree '.claude') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $script:fx.Worktree '.claude') 'settings.local.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:fx.Worktree '.fm-grok-turnend') -Value ''
        Set-Content -LiteralPath (Join-Path $script:fx.Worktree '.fm-kimi-turnend') -Value ''
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'allow'
    }

    It 'REFUSES commits that are on no remote and have not landed' {
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'work.txt' -Content 'real work'
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 } -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }
        $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'not on any remote and not landed'
        ($verdict.Message -join "`n") | Should -Match 'unpushed commits:'
    }

    It 'allows commits whose CONTENT already landed in the default branch (the squash-merge case)' {
        # The branch's own commit lives on no remote, yet the change is fully in
        # main. Refusing here would block every squash-merge-then-delete flow.
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'feature.txt' -Content 'shipped'
        $null = Add-TestCommit -Directory $script:fx.Project -File 'feature.txt' -Content 'shipped' -Message 'squashed'
        $null = Invoke-FmGit -Directory $script:fx.Project -Arguments @('push', '-q', 'origin', 'main')
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 } -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project).Verdict |
            Should -Be 'allow'
    }

    It 'allows commits contained in a MERGED pull request head' {
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'pr.txt' -Content 'in the pr'
        $head = Get-FmGitOutput -Directory $script:fx.Worktree -Arguments @('rev-parse', 'HEAD')
        Mock Invoke-FmChildProcess {
            New-ChildProcessResult -StdOut ("{""state"":""MERGED"",""headRefOid"":""$head""}")
        } -ParameterFilter { $FilePath -eq 'gh' }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project `
                -PrUrl 'https://github.test/o/r/pull/7').Verdict | Should -Be 'allow'
    }

    It 'REFUSES when the PR is open rather than merged' {
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'pr.txt' -Content 'in the pr'
        $head = Get-FmGitOutput -Directory $script:fx.Worktree -Arguments @('rev-parse', 'HEAD')
        Mock Invoke-FmChildProcess {
            New-ChildProcessResult -StdOut ("{""state"":""OPEN"",""headRefOid"":""$head""}")
        } -ParameterFilter { $FilePath -eq 'gh' }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project `
                -PrUrl 'https://github.test/o/r/pull/7').Verdict | Should -Be 'refuse'
    }

    It 'REFUSES when the gh lookup errors and the content check is inconclusive' {
        # A lookup error must never read as "landed".
        $null = Add-TestCommit -Directory $script:fx.Worktree -File 'pr.txt' -Content 'unlanded'
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 4 -StdErr 'gh: network' } `
            -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }
        (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project `
                -PrUrl 'https://github.test/o/r/pull/7').Verdict | Should -Be 'refuse'
    }

    Context 'local-only mode' {
        It 'REFUSES work not yet merged into the local default branch' {
            $null = Add-TestCommit -Directory $script:fx.Worktree -File 'local.txt' -Content 'local work'
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Mode 'local-only'
            $verdict.Verdict | Should -Be 'refuse'
            ($verdict.Message -join "`n") | Should -Match 'local-only worktree .* has work not yet merged into main'
            ($verdict.Message -join "`n") | Should -Match 'commits not yet on main:'
        }

        It 'allows work already merged into the local default branch' {
            $commit = Add-TestCommit -Directory $script:fx.Worktree -File 'local.txt' -Content 'local work'
            $null = Invoke-FmGit -Directory $script:fx.Project -Arguments @('merge', '--ff-only', '-q', $commit)
            (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Mode 'local-only').Verdict |
                Should -Be 'allow'
        }

        It 'REFUSES a dirty local-only worktree even when its commits are merged' {
            $commit = Add-TestCommit -Directory $script:fx.Worktree -File 'local.txt' -Content 'local work'
            $null = Invoke-FmGit -Directory $script:fx.Project -Arguments @('merge', '--ff-only', '-q', $commit)
            Set-Content -LiteralPath (Join-Path $script:fx.Worktree 'local.txt') -Value 'edited after merge'
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Mode 'local-only'
            $verdict.Verdict | Should -Be 'refuse'
            ($verdict.Message -join "`n") | Should -Match 'uncommitted changes present'
        }

        It 'REFUSES when the default branch cannot be determined' {
            $null = Add-TestCommit -Directory $script:fx.Worktree -File 'local.txt' -Content 'local work'
            Mock Get-FmGitDefaultBranch { '' }
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Mode 'local-only'
            $verdict.Verdict | Should -Be 'refuse'
            ($verdict.Message -join "`n") | Should -Match 'cannot determine default branch'
        }
    }

    Context 'when git itself cannot answer' {
        It 'reports lock-blocked when a git lock explains the failure' {
            Mock Invoke-FmGit { New-ChildProcessResult -Ok $false -ExitCode 128 } -ParameterFilter { $Arguments -contains 'status' }
            $lock = Get-FmTeardownGitLockPath -Worktree $script:fx.Worktree
            New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
            Set-Content -LiteralPath $lock -Value ''
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
            $verdict.Verdict | Should -Be 'lock-blocked'
            ($verdict.Message -join "`n") | Should -Match 'cannot inspect worktree .* for uncommitted changes while git lock'
        }

        It 'REFUSES flatly when nothing explains the failure' {
            Mock Invoke-FmGit { New-ChildProcessResult -Ok $false -ExitCode 128 } -ParameterFilter { $Arguments -contains 'status' }
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
            $verdict.Verdict | Should -Be 'refuse'
            ($verdict.Message -join "`n") | Should -Match 'REFUSED: cannot inspect worktree .* for uncommitted changes'
        }

        It 'REFUSES when the unpushed-commit scan cannot run' {
            Mock Invoke-FmGit { New-ChildProcessResult -Ok $false -ExitCode 128 } -ParameterFilter { $Arguments -contains '--remotes' }
            $verdict = Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project
            $verdict.Verdict | Should -Be 'refuse'
            ($verdict.Message -join "`n") | Should -Match 'for commits not on a remote'
        }
    }

    Context 'carve-outs' {
        It 'skips the test for scout and secondmate kinds, whose gates are elsewhere' {
            Set-Content -LiteralPath (Join-Path $script:fx.Worktree 'README.md') -Value 'dirty'
            (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Kind 'scout').Verdict |
                Should -Be 'allow'
            (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Kind 'secondmate').Verdict |
                Should -Be 'allow'
        }

        It 'skips the test under -Force, which is why -Force needs authority' {
            Set-Content -LiteralPath (Join-Path $script:fx.Worktree 'README.md') -Value 'dirty'
            (Test-FmTeardownWorktreeSafety -Worktree $script:fx.Worktree -Project $script:fx.Project -Force).Verdict |
                Should -Be 'allow'
        }

        It 'allows a worktree that is already gone' {
            (Test-FmTeardownWorktreeSafety -Worktree (Join-Path $TestDrive 'ghost-wt') -Project $script:fx.Project).Verdict |
                Should -Be 'allow'
            (Test-FmTeardownWorktreeSafety -Worktree '' -Project $script:fx.Project).Verdict | Should -Be 'allow'
        }
    }
}

Describe 'patch-id containment' {
    BeforeAll {
        $script:pRoot = Join-Path $TestDrive 'patchid'
        $script:pfx = New-TestFixture -Root $script:pRoot
        # The same diff applied twice from the same base: two different commits
        # with one patch id. This is what survives a rebase or a force-push.
        $script:localCommit = Add-TestCommit -Directory $script:pfx.Worktree -File 'p.txt' -Content 'payload' -Message 'local'
        $null = Add-TestCommit -Directory $script:pfx.Project -File 'p.txt' -Content 'payload' -Message 'rewritten'
        $null = Invoke-FmGit -Directory $script:pfx.Project -Arguments @('push', '-q', 'origin', 'main:refs/heads/prhead')
        $null = Invoke-FmGit -Directory $script:pfx.Project -Arguments @('fetch', '-q', 'origin')
        $script:prHead = Get-FmGitOutput -Directory $script:pfx.Project -Arguments @('rev-parse', 'refs/remotes/origin/prhead')
    }

    It 'gives two commits with the same diff the same patch id' {
        $a = Get-FmTeardownCommitPatchId -Worktree $script:pfx.Worktree -Commit $script:localCommit
        $b = Get-FmTeardownCommitPatchId -Worktree $script:pfx.Worktree -Commit $script:prHead
        $a | Should -Not -BeNullOrEmpty
        $a | Should -Be $b
    }

    It 'accepts unpushed commits whose patches are all in the PR head' {
        Test-FmTeardownPatchesInPrHead -Worktree $script:pfx.Worktree -PrHead $script:prHead | Should -BeTrue
    }

    It 'REFUSES when an unpushed commit has no counterpart in the PR head' {
        $null = Add-TestCommit -Directory $script:pfx.Worktree -File 'extra.txt' -Content 'not in the pr' -Message 'extra'
        Test-FmTeardownPatchesInPrHead -Worktree $script:pfx.Worktree -PrHead $script:prHead | Should -BeFalse
    }
}

# =============================================================================
# Returning the worktree to the pool
# =============================================================================

Describe 'Invoke-FmTeardownWorktreeReturn' {
    BeforeEach {
        $script:rRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:rRoot -Force | Out-Null
        $script:wt = Join-Path $script:rRoot 'wt'
        $script:proj = Join-Path $script:rRoot 'proj'
        New-Item -ItemType Directory -Path $script:wt -Force | Out-Null
        New-Item -ItemType Directory -Path $script:proj -Force | Out-Null
        $env:FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS = '0'
        Mock Start-Sleep { }
        Mock Invoke-FmChildProcess {
            # A mock body sees only the parameters the CALLER bound, so each
            # optional one is forwarded only when it is actually there.
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmGit {
            $splat = @{ Directory = $Directory; Arguments = $Arguments }
            if ($null -ne $TimeoutSeconds) { $splat['TimeoutSeconds'] = $TimeoutSeconds }
            & $script:RealInvokeGit @splat
        }

        Mock Get-FmTeardownGitLockPath { Join-Path $script:wt 'index.lock' }
    }
    AfterEach { $env:FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS = $null }

    It 'returns on the first attempt when treehouse succeeds' {
        Mock Invoke-FmChildProcess { New-ChildProcessResult -StdOut 'returned' } -ParameterFilter { $FilePath -eq 'treehouse' }
        (Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -Confirm:$false).Outcome |
            Should -Be 'returned'
        Should -Invoke Invoke-FmChildProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'treehouse' }
    }

    It 'conditions the return on this task''s own lease, so it cannot recycle a re-issued one' {
        Mock Invoke-FmChildProcess { New-ChildProcessResult } -ParameterFilter { $FilePath -eq 'treehouse' }
        $null = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -LeaseId 'lease-77' -Confirm:$false
        Should -Invoke Invoke-FmChildProcess -Times 1 -ParameterFilter {
            $FilePath -eq 'treehouse' -and ($ArgumentList -join ' ') -match '--if-lease-id lease-77'
        }
    }

    It 'does NOT retry a failure that is not the index.lock signature' {
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr 'pool state is corrupt' } `
            -ParameterFilter { $FilePath -eq 'treehouse' }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -Confirm:$false
        $result.Outcome | Should -Be 'failed'
        $result.Detail | Should -Match 'pool state is corrupt'
        Should -Invoke Invoke-FmChildProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'treehouse' }
    }

    It 'waits out a transient lock and succeeds on a retry' {
        $script:calls = 0
        Mock Invoke-FmChildProcess {
            $script:calls++
            if ($script:calls -eq 1) {
                New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr "Unable to create '$script:wt/index.lock': File exists"
            } else {
                New-ChildProcessResult -StdOut 'returned'
            }
        } -ParameterFilter { $FilePath -eq 'treehouse' }
        (Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -Confirm:$false).Outcome |
            Should -Be 'returned'
        $script:calls | Should -Be 2
    }

    It 'REFUSES when the lock persists and is not provably stale' {
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr "Unable to create '$script:wt/index.lock': File exists" } `
            -ParameterFilter { $FilePath -eq 'treehouse' }
        Set-Content -LiteralPath (Join-Path $script:wt 'index.lock') -Value ''
        Mock Test-FmTeardownGitLockStale { $false }
        Mock Get-FmFileHolderProcess { @('git.exe (pid 4242)') }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -Confirm:$false
        $result.Outcome | Should -Be 'lock-refused'
        $result.Detail | Should -Match 'not provably stale'
        $result.Detail | Should -Match 'git\.exe \(pid 4242\)'
        Test-Path -LiteralPath (Join-Path $script:wt 'index.lock') | Should -BeTrue
    }

    It 'removes a PROVABLY stale lock, re-runs the safety checks, and returns' {
        $script:calls = 0
        Mock Invoke-FmChildProcess {
            $script:calls++
            if ($script:calls -le 4) {
                New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr "Unable to create '$script:wt/index.lock': File exists"
            } else {
                New-ChildProcessResult -StdOut 'returned'
            }
        } -ParameterFilter { $FilePath -eq 'treehouse' }
        Set-Content -LiteralPath (Join-Path $script:wt 'index.lock') -Value ''
        Mock Test-FmTeardownGitLockStale { $true }
        $script:rechecked = $false
        $check = { $script:rechecked = $true; $true }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -PostCleanupCheck $check -Confirm:$false
        $result.Outcome | Should -Be 'returned'
        $script:rechecked | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:wt 'index.lock') | Should -BeFalse
    }

    It 'ABORTS after a stale-lock cleanup when the re-run safety checks refuse' {
        # A lock is not a reason to skip the landed-work test: once the lock is
        # gone the checks that could not run now must, and they can still refuse.
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr "Unable to create '$script:wt/index.lock': File exists" } `
            -ParameterFilter { $FilePath -eq 'treehouse' }
        Set-Content -LiteralPath (Join-Path $script:wt 'index.lock') -Value ''
        Mock Test-FmTeardownGitLockStale { $true }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj `
            -PostCleanupCheck { $false } -Confirm:$false
        $result.Outcome | Should -Be 'refused'
        $result.Detail | Should -Match 'safety checks failed'
    }

    It 'reports the disappeared-lock case distinctly' {
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr "Unable to create '$script:wt/index.lock': File exists" } `
            -ParameterFilter { $FilePath -eq 'treehouse' }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $script:wt -Project $script:proj -Confirm:$false
        $result.Outcome | Should -Be 'failed'
        $result.Detail | Should -Match 'even after the lock file disappeared'
    }
}

Describe 'Get-FmTeardownSetting' {
    AfterEach {
        $env:FM_TREEHOUSE_RETURN_LOCK_RETRIES = $null
        $env:FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS = $null
        $env:FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS = $null
    }

    It 'defaults match the bash defaults' {
        Get-FmTeardownLockAgeSeconds | Should -Be 30
        Get-FmTeardownReturnRetryCount | Should -Be 3
        Get-FmTeardownReturnRetryWaitSeconds | Should -Be 1
    }

    It 'honours the older FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS alias' {
        $env:FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS = '2.5'
        Get-FmTeardownReturnRetryWaitSeconds | Should -Be 2.5
    }

    It 'prefers the newer name over the alias' {
        $env:FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS = '9'
        $env:FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS = '4'
        Get-FmTeardownReturnRetryWaitSeconds | Should -Be 4
    }

    It 'falls back to the default on an invalid value rather than failing' {
        $env:FM_TREEHOUSE_RETURN_LOCK_RETRIES = 'lots'
        Get-FmTeardownReturnRetryCount -WarningAction SilentlyContinue | Should -Be 3
    }
}

Describe 'Get-FmTeardownBacklogReminder' {
    It 'prints nothing for a secondmate, which is not a backlog item' {
        Get-FmTeardownBacklogReminder -TaskId 'sm' -Kind 'secondmate' | Should -Be ''
    }

    It 'points at the manual backlog when tasks-axi is unavailable' {
        Get-FmTeardownBacklogReminder -TaskId 'alpha' | Should -Match 'Update data/backlog\.md'
    }

    It 'names the scout report, the local-only note, and the PR' {
        Get-FmTeardownBacklogReminder -TaskId 'a' -Kind 'scout' -TasksAxiAvailable |
            Should -Match 'tasks-axi done a --report data/a/report\.md'
        Get-FmTeardownBacklogReminder -TaskId 'a' -Mode 'local-only' -TasksAxiAvailable |
            Should -Match 'tasks-axi done a --note "local main"'
        Get-FmTeardownBacklogReminder -TaskId 'a' -PrUrl 'https://p/1' -TasksAxiAvailable |
            Should -Match 'tasks-axi done a --pr https://p/1'
        Get-FmTeardownBacklogReminder -TaskId 'a' -TasksAxiAvailable | Should -Match '--pr PR_URL'
    }
}

# =============================================================================
# The whole command
# =============================================================================

Describe 'Invoke-FmTeardown' {
    BeforeEach {
        $script:iRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:ifx = New-TestFixture -Root $script:iRoot
        $script:fmHome = Join-Path $script:iRoot 'home'
        $script:stateDir = Join-Path $script:fmHome 'state'
        New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:fmHome 'data') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:fmHome 'config') -Force | Out-Null

        $script:metaPath = Join-Path $script:stateDir 'alpha.meta'
        $script:WriteMeta = {
            param([hashtable]$Extra = @{})
            $fields = [ordered]@{
                window             = 'default:pane-1'
                endpoint_task_id   = 'alpha'
                worktree           = $script:ifx.Worktree
                project            = $script:ifx.Project
                harness            = 'claude'
                kind               = 'ship'
                backend            = 'herdr'
                treehouse_lease_id = 'lease-alpha'
            }
            foreach ($key in $Extra.Keys) { $fields[$key] = $Extra[$key] }
            $text = ($fields.Keys | ForEach-Object { "$_=$($fields[$_])" }) -join "`n"
            Write-FmTextFileLf -Path $script:metaPath -Text ($text + "`n")
        }
        & $script:WriteMeta
        Set-Content -LiteralPath (Join-Path $script:stateDir 'alpha.status') -Value "working: x`n"
        Set-Content -LiteralPath (Join-Path $script:stateDir 'alpha.turn-ended') -Value ''

        Mock Invoke-FmChildProcess {
            # A mock body sees only the parameters the CALLER bound, so each
            # optional one is forwarded only when it is actually there.
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmGit {
            $splat = @{ Directory = $Directory; Arguments = $Arguments }
            if ($null -ne $TimeoutSeconds) { $splat['TimeoutSeconds'] = $TimeoutSeconds }
            & $script:RealInvokeGit @splat
        }
        Mock Test-FmTeardownTreehouseAvailable { $true }
        Mock Remove-FmHerdrPane { $true }
        Mock Test-FmHerdrEndpointGone { $true }
        Mock Stop-FmTaskJob { [pscustomobject]@{ Outcome = 'terminated'; Survivors = @(); Detail = 'clean' } }
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'returned'; Detail = '' } }
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 } -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }
    }

    It 'tears down a clean landed task and erases exactly the volatile records' {
        $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        Test-Path -LiteralPath $script:metaPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:stateDir 'alpha.status') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:stateDir 'alpha.turn-ended') | Should -BeFalse
        $result.Summary | Should -Match 'teardown alpha complete'
        $result.Reminder | Should -Match 'Backlog: alpha just finished'
    }

    It 'REFUSES uncommitted changes and keeps every record' {
        Set-Content -LiteralPath (Join-Path $script:ifx.Worktree 'README.md') -Value 'dirty'
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*has uncommitted changes*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 0
    }

    It 'REFUSES unpushed unlanded commits before touching the pane' {
        $null = Add-TestCommit -Directory $script:ifx.Worktree -File 'w.txt' -Content 'work'
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*not on any remote and not landed*'
        Should -Invoke Remove-FmHerdrPane -Times 0
    }

    It 'REFUSES a live process still in the worktree' {
        Mock Stop-FmTaskJob {
            [pscustomobject]@{ Outcome = 'survivors'; Survivors = @(4242, 4243); Detail = 'still alive' }
        }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*still has live processes in its worktree*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 0
    }

    It 'records custody it could not prove as a step that did NOT run, and continues' {
        Mock Stop-FmTaskJob {
            [pscustomobject]@{ Outcome = 'not-found'; Survivors = @(); Detail = 'no custody job' }
        }
        $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        $step = $result.Steps | Where-Object { $_.Step -eq 'process-custody' }
        $step.Outcome | Should -Be 'did-not-run'
        $step.Outcome | Should -Not -Be 'terminated'
    }

    It 'REFUSES a scout with no report' {
        & $script:WriteMeta @{ kind = 'scout' }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*has no report at*'
    }

    Context 'the unresolved-decision completion gate' {
        # This suite dot-sources the teardown area only, so the gate's own rules
        # are tested against real records in tests/FmDecisionHold.Tests.ps1.
        # What belongs HERE is teardown's half of the contract: it asks the
        # owner by name, it refuses when there is none, and it reports the
        # owner's verdict rather than a verdict of its own.
        BeforeEach {
            & $script:WriteMeta @{ kind = 'scout' }
            $reportDir = Join-Path (Join-Path $script:fmHome 'data') 'alpha'
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $reportDir 'report.md') -Value '# findings'
            # Staged at the seam, never by deleting the owner: the owner HAS
            # landed now, and CONTRIBUTING is explicit that a degradation test
            # which stops staging its absence stops testing the degradation.
            Mock Resolve-FmTeardownOwner { & $script:RealResolveOwner -Name $Name }
        }

        It 'REFUSES when the gate has no owner to run it' {
            Mock Resolve-FmTeardownOwner { $null } -ParameterFilter { $Name -eq 'Test-FmDecisionHoldComplete' }
            { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
                Should -Throw '*did NOT run*'
            Test-Path -LiteralPath $script:metaPath | Should -BeTrue
            Should -Invoke Remove-FmHerdrPane -Times 0
        }

        It 'REFUSES with the gate''s OWN message, so the refusal names the decision' {
            Mock Resolve-FmTeardownOwner {
                { param($TaskId, $FirstmateHome)
                    [pscustomobject]@{
                        Verdict = 'refuse'
                        Message = @("REFUSED: $TaskId has an unresolved decision hold in $FirstmateHome.", '  api-shape - pick a response shape')
                        Detail  = ''
                    } }
            } -ParameterFilter { $Name -eq 'Test-FmDecisionHoldComplete' }
            { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
                Should -Throw '*api-shape - pick a response shape*'
            Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        }

        It 'reads the VERDICT, not the truthiness of the record it gets back' {
            # The trap this pins: every object is truthy, so `if (-not $verdict)`
            # would pass a refusal straight through the one gate that exists to
            # stop it.
            Mock Resolve-FmTeardownOwner {
                { param($TaskId, $FirstmateHome)
                    [pscustomobject]@{
                        Verdict = 'refuse'
                        Message = @("REFUSED: $TaskId is still held, and $FirstmateHome is where that was read")
                        Detail  = ''
                    } }
            } -ParameterFilter { $Name -eq 'Test-FmDecisionHoldComplete' }
            { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
                Should -Throw '*alpha is still held*'
        }

        It 'passes, and records what the gate actually read' {
            # The stub echoes BOTH parameters teardown binds by name, so this
            # also pins that it passes the pair the owner actually declares -
            # the mismatch that makes a by-name caller degrade in silence.
            Mock Resolve-FmTeardownOwner {
                { param($TaskId, $FirstmateHome)
                    [pscustomobject]@{ Verdict = 'pass'; Message = @(); Detail = "nothing open for $TaskId in $FirstmateHome" } }
            } -ParameterFilter { $Name -eq 'Test-FmDecisionHoldComplete' }
            $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
            $result.Outcome | Should -Be 'complete'
            $step = $result.Steps | Where-Object { $_.Step -eq 'decision-hold-gate' }
            $step.Outcome | Should -Be 'passed'
            $step.Detail | Should -Be "nothing open for alpha in $script:fmHome"
        }

        It 'is skipped by -Force, which still requires an authority' {
            Mock Resolve-FmTeardownOwner { $null } -ParameterFilter { $Name -eq 'Test-FmDecisionHoldComplete' }
            { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Force -Confirm:$false } |
                Should -Throw '*requires -DiscardApprovedBy*'
            $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Force `
                -DiscardApprovedBy 'captain' -Confirm:$false
            $result.Outcome | Should -Be 'complete'
            ($result.Steps | Where-Object { $_.Step -eq 'scout-report' }).Outcome | Should -Be 'skipped'
            @($result.Steps | Where-Object { $_.Step -eq 'decision-hold-gate' }).Count | Should -Be 0
        }
    }

    It 'REFUSES a backend this port does not drive' {
        & $script:WriteMeta @{ backend = 'tmux' }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*drives the herdr session provider only*'
    }

    It 'KEEPS the state files when the pool return fails, so a held lease stays visible' {
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'lock-refused'; Detail = 'lock persisted' } }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*treehouse return failed*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
    }

    It 'KEEPS every durable record when the pane is not confirmed gone' {
        Mock Test-FmHerdrEndpointGone { $false }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*not confirmed gone*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
    }

    It 'REFUSES -Force without explicit authority, so force is never the easy path' {
        Set-Content -LiteralPath (Join-Path $script:ifx.Worktree 'README.md') -Value 'dirty'
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Force -Confirm:$false } |
            Should -Throw '*requires -DiscardApprovedBy*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
    }

    It 'discards dirty work only with -Force AND an authority, and records who' {
        Set-Content -LiteralPath (Join-Path $script:ifx.Worktree 'README.md') -Value 'dirty'
        $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Force `
            -DiscardApprovedBy 'captain' -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        $result.Forced | Should -BeTrue
        ($result.Steps | Where-Object { $_.Step -eq 'landed-work-test' }).Detail | Should -Match 'captain'
    }

    It 'returns the worktree conditionally on the recorded lease' {
        $null = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 1 -ParameterFilter { $LeaseId -eq 'lease-alpha' }
    }

    It 'deletes the task branch and its own hook files before returning the worktree' {
        New-Item -ItemType Directory -Path (Join-Path $script:ifx.Worktree '.claude') -Force | Out-Null
        $hook = Join-Path (Join-Path $script:ifx.Worktree '.claude') 'settings.local.json'
        Set-Content -LiteralPath $hook -Value '{}'
        $result = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        Test-Path -LiteralPath $hook | Should -BeFalse
        ($result.Steps | Where-Object { $_.Step -eq 'branch-delete' }).Detail | Should -Be $script:ifx.Branch
        Get-FmGitOutput -Directory $script:ifx.Project -Arguments @('branch', '--list', $script:ifx.Branch) |
            Should -Be ''
    }

    It 'refuses an unknown task and an invalid task id' {
        { Invoke-FmTeardown -TaskId 'ghost' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*no meta for task ghost*'
        { Invoke-FmTeardown -TaskId 'bad id' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*not a valid task id*'
    }

    It 'REFUSES a second concurrent lifecycle action for the same task' {
        # A live owner: this very process, which is certainly alive.
        $lock = Join-Path $script:stateDir '.control-alpha.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value "$PID"
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*another lifecycle action is already running*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        Should -Invoke Remove-FmHerdrPane -Times 0
    }

    It 'releases its control lock on success and on refusal alike' {
        $lock = Join-Path $script:stateDir '.control-alpha.lock'
        $null = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        Test-Path -LiteralPath $lock | Should -BeFalse

        & $script:WriteMeta
        Set-Content -LiteralPath (Join-Path $script:ifx.Worktree 'README.md') -Value 'dirty'
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } | Should -Throw
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'reclaims a lock whose owner is gone rather than deadlocking on it' {
        $lock = Join-Path $script:stateDir '.control-alpha.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value "$(Get-DeadProcessId)"
        (Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false).Outcome |
            Should -Be 'complete'
    }

    It 'REFUSES a remote-placed secondmate rather than reaching across the network' {
        & $script:WriteMeta @{ remote_host = 'builder.example.invalid' }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*remote-placed secondmate*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
    }

    It 'REFUSES before deleting the branch when treehouse is not installed' {
        Mock Test-FmTeardownTreehouseAvailable { $false }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*treehouse is not available*'
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        # The branch must survive: nothing destructive may run before that refusal.
        Get-FmGitOutput -Directory $script:ifx.Project -Arguments @('rev-parse', '--verify', "refs/heads/$($script:ifx.Branch)") |
            Should -Not -BeNullOrEmpty
    }

    It 'removes the task PR-check artifacts with the rest of the volatile state' {
        foreach ($leaf in @('alpha.check.sh', 'alpha.pr-poll', 'alpha.check-trust')) {
            Set-Content -LiteralPath (Join-Path $script:stateDir $leaf) -Value 'x'
        }
        $null = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        foreach ($leaf in @('alpha.check.sh', 'alpha.pr-poll', 'alpha.check-trust')) {
            Test-Path -LiteralPath (Join-Path $script:stateDir $leaf) | Should -BeFalse
        }
    }

    It 'REFUSES a PR-check artifact that is a symlink out of the state directory' {
        Set-FmTestSymlinkSkip
        $outside = Join-Path $script:iRoot 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'keep me'
        $link = Join-Path $script:stateDir 'alpha.check.sh'
        New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'symlinks are not available here' }
        { Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*PR-check artifacts did not pass validation*'
        Test-Path -LiteralPath $outside | Should -BeTrue
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
    }

    It 'changes nothing under -WhatIf' {
        $null = Invoke-FmTeardown -TaskId 'alpha' -FirstmateHome $script:fmHome -WhatIf
        Test-Path -LiteralPath $script:metaPath | Should -BeTrue
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 0
    }
}

# =============================================================================
# Retiring a secondmate through the whole command
#
# FmSecondmate.ps1's own suite covers each proof in isolation. These are about
# the COMMAND: that the gate runs before anything is touched, that the home comes
# off disk while this home's meta still names it, and - the ordering that matters
# most - that data/secondmates.md is edited LAST, after every step that can still
# refuse. While that row is present the home is findable, so removing it early
# would be how a failed retirement leaves an untracked home behind.
# =============================================================================

Describe 'Invoke-FmTeardown: secondmate retirement' {
    BeforeEach {
        $script:sRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:sfx = New-TestFixture -Root $script:sRoot
        $script:sHome = Join-Path $script:sRoot 'home'
        $script:sState = Join-Path $script:sHome 'state'
        $script:sData = Join-Path $script:sHome 'data'
        New-Item -ItemType Directory -Path $script:sState -Force | Out-Null
        New-Item -ItemType Directory -Path $script:sData -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:sHome 'config') -Force | Out-Null

        # The secondmate's own home, in the shape fm-setup.ps1 leaves behind.
        $script:subHome = Join-Path $script:sRoot 'sm-home'
        foreach ($leaf in @('state', 'data', 'config', 'projects')) {
            New-Item -ItemType Directory -Path (Join-Path $script:subHome $leaf) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $script:subHome 'data' 'backlog.md'),
            "# Backlog`n`n## In flight`n`n## Queued`n`n## Done`n")

        $script:sMeta = Join-Path $script:sState 'sm.meta'
        $script:WriteSecondmateMeta = {
            param([hashtable]$Extra = @{})
            $fields = [ordered]@{
                window             = 'default:pane-2'
                endpoint_task_id   = 'sm'
                worktree           = $script:sfx.Worktree
                project            = $script:sfx.Project
                harness            = 'claude'
                kind               = 'secondmate'
                backend            = 'herdr'
                home               = $script:subHome
                projects           = 'project'
                treehouse_lease_id = 'lease-sm'
            }
            foreach ($key in $Extra.Keys) { $fields[$key] = $Extra[$key] }
            Write-FmTextFileLf -Path $script:sMeta `
                -Text ((($fields.Keys | ForEach-Object { "$_=$($fields[$_])" }) -join "`n") + "`n")
        }
        & $script:WriteSecondmateMeta
        Set-Content -LiteralPath (Join-Path $script:sState 'sm.status') -Value "working: charter accepted`n"

        $script:sRegistry = Join-Path $script:sData 'secondmates.md'
        Write-FmTextFileLf -Path $script:sRegistry -Text (@(
                '# Secondmates'
                ''
                "- sm - home ``$script:subHome`` - scope: the demo lane"
                '- keeper - home `C:\homes\keeper` - scope: a lane that must survive'
                ''
            ) -join "`n")

        Mock Invoke-FmChildProcess {
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmGit {
            $splat = @{ Directory = $Directory; Arguments = $Arguments }
            if ($null -ne $TimeoutSeconds) { $splat['TimeoutSeconds'] = $TimeoutSeconds }
            & $script:RealInvokeGit @splat
        }
        Mock Test-FmTeardownTreehouseAvailable { $true }
        Mock Remove-FmHerdrPane { $true }
        Mock Test-FmHerdrEndpointGone { $true }
        Mock Stop-FmTaskJob { [pscustomobject]@{ Outcome = 'terminated'; Survivors = @(); Detail = 'clean' } }
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'returned'; Detail = '' } }
        Mock Invoke-FmChildProcess { New-ChildProcessResult -Ok $false -ExitCode 1 } -ParameterFilter { $FilePath -in @('gh', 'gh-axi') }

        # Every refusal test asserts this: a refusal changes NOTHING.
        $script:AssertNothingChanged = {
            Test-Path -LiteralPath $script:subHome | Should -BeTrue -Because 'the home is preserved'
            Test-Path -LiteralPath $script:sMeta | Should -BeTrue -Because 'the task record is preserved'
            [System.IO.File]::ReadAllText($script:sRegistry) |
                Should -BeLike '*- sm - home*' -Because 'the routing row is preserved'
        }
    }

    It 'retires an idle, clean secondmate: home gone, endpoint closed, routing row removed' {
        $result = Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        Test-Path -LiteralPath $script:subHome | Should -BeFalse
        Test-Path -LiteralPath $script:sMeta | Should -BeFalse
        Should -Invoke Remove-FmHerdrPane -Times 1

        $registry = [System.IO.File]::ReadAllText($script:sRegistry)
        $registry | Should -Not -BeLike '*- sm - home*'
        $registry | Should -BeLike '*- keeper - home*'
        ($result.Steps | Where-Object { $_.Step -eq 'secondmate-registry' }).Outcome | Should -Be 'removed'
    }

    It 'REFUSES work under way in the secondmate''s own home, naming it, and changes nothing' {
        Write-FmTextFileLf -Path (Join-Path $script:subHome 'state' 'child-1.meta') -Text "kind=ship`n"
        { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false } |
            Should -Throw '*task record child-1*'
        & $script:AssertNothingChanged
        Should -Invoke Remove-FmHerdrPane -Times 0
    }

    It 'REFUSES a live descendant lock even with -Force and an authority' {
        # The one refusal captain authority does not reach: force authorizes
        # discarding work, never removing a home a live process is using.
        $lock = Join-Path $script:subHome 'state' '.control-child.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value "$PID"
        { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Force `
                -DiscardApprovedBy 'captain' -Confirm:$false } | Should -Throw '*live descendant*'
        & $script:AssertNothingChanged
    }

    It 'REFUSES unlanded work in the home''s project clone without -Force' {
        $clone = Join-Path $script:subHome 'projects' 'proj'
        $null = New-TestClone -Origin $script:sfx.Origin -Path $clone
        Set-Content -LiteralPath (Join-Path $clone 'work.txt') -Value 'unlanded' -NoNewline
        { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false } |
            Should -Throw '*has not landed*'
        & $script:AssertNothingChanged
    }

    It 'discards it with -Force AND an authority, and records who approved' {
        $clone = Join-Path $script:subHome 'projects' 'proj'
        $null = New-TestClone -Origin $script:sfx.Origin -Path $clone
        Set-Content -LiteralPath (Join-Path $clone 'work.txt') -Value 'unlanded' -NoNewline
        $result = Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Force `
            -DiscardApprovedBy 'captain, 2026-08-14' -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        $result.Forced | Should -BeTrue
        ($result.Steps | Where-Object { $_.Step -eq 'secondmate-retirement-gate' }).Detail |
            Should -Match 'captain, 2026-08-14'
        Test-Path -LiteralPath $script:subHome | Should -BeFalse
    }

    It 'REFUSES a home= that is the launching home, the checkout, or a project clone' {
        foreach ($bad in @($script:sHome, (Get-FmRoot), $script:sfx.Project)) {
            & $script:WriteSecondmateMeta @{ home = $bad }
            { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Force `
                    -DiscardApprovedBy 'captain' -Confirm:$false } |
                Should -Throw '*is not a retirable secondmate home*'
            Test-Path -LiteralPath $bad | Should -BeTrue
        }
    }

    It 'KEEPS the routing row when the home cannot be removed' -Skip:(-not $IsWindows) {
        # THE ORDERING PROPERTY. Windows refuses a delete while a handle is open,
        # so this is the real failure an operator hits - and the row has to be
        # there afterwards, because it is the only thing that still names the home
        # that is still on disk.
        $held = Join-Path $script:subHome 'data' 'open.txt'
        [System.IO.File]::WriteAllText($held, 'x')
        $stream = [System.IO.File]::Open($held, 'Open', 'Read', [System.IO.FileShare]::None)
        try {
            { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false } |
                Should -Throw '*home could not be removed*'
            & $script:AssertNothingChanged
        } finally {
            $stream.Dispose()
        }
    }

    It 'KEEPS the routing row when a descendant''s worktree cannot be returned' {
        # Same rule one step earlier: the descendant's meta is the only record
        # that names its lease, and it goes with the home. A return that did not
        # happen therefore stops the removal rather than being noted and passed.
        $childWt = Join-Path $script:sRoot 'child-wt'
        New-Item -ItemType Directory -Path $childWt -Force | Out-Null
        Write-FmTextFileLf -Path (Join-Path $script:subHome 'state' 'child-1.meta') `
            -Text "kind=ship`nworktree=$childWt`nproject=$($script:sfx.Project)`ntreehouse_lease_id=lease-child`n"
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'lock-refused'; Detail = 'lock persisted' } } `
            -ParameterFilter { $Worktree -eq $childWt }
        { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Force `
                -DiscardApprovedBy 'captain' -Confirm:$false } |
            Should -Throw '*could not be returned to their pools*'
        & $script:AssertNothingChanged
    }

    It 'still retires a secondmate whose home is already gone, so a rerun finishes the job' {
        Remove-Item -LiteralPath $script:subHome -Recurse -Force
        $result = Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false
        ($result.Steps | Where-Object { $_.Step -eq 'secondmate-home' }).Outcome | Should -Be 'already-gone'
        [System.IO.File]::ReadAllText($script:sRegistry) | Should -Not -BeLike '*- sm - home*'
    }

    It 'completes without a registry when the home never had one' {
        Remove-Item -LiteralPath $script:sRegistry -Force
        $result = Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        ($result.Steps | Where-Object { $_.Step -eq 'secondmate-registry' }).Outcome | Should -Be 'no-registry'
    }

    It 'prints no backlog reminder: a secondmate is not a backlog item' {
        (Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false).Reminder | Should -Be ''
    }

    It 'REFUSES a remote-placed secondmate before the retirement gate is even reached' {
        & $script:WriteSecondmateMeta @{ remote_host = 'builder.example.invalid' }
        { Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -Confirm:$false } |
            Should -Throw '*remote-placed secondmate*'
        & $script:AssertNothingChanged
    }

    It 'changes nothing under -WhatIf' {
        $null = Invoke-FmTeardown -TaskId 'sm' -FirstmateHome $script:sHome -WhatIf
        & $script:AssertNothingChanged
    }
}

# =============================================================================
# Carried over from the lifecycle area's teardown, which this port replaces.
# Kept under the same names and signatures because other areas resolve them:
# tests/FmCrewState.Tests.ps1 calls Get-FmTaskParkedRunId directly.
# =============================================================================

Describe 'the per-task control lock' {
    BeforeEach {
        $script:lockRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:lockRoot -Force | Out-Null
        $script:lockPath = Join-Path $script:lockRoot '.control-t1.lock'
    }

    It 'is taken once and refuses a second acquirer' {
        Enter-FmTeardownLock -LockPath $script:lockPath | Should -BeTrue
        Enter-FmTeardownLock -LockPath $script:lockPath | Should -BeFalse
    }

    It 'writes the holder pid in the shape the bash lock library reads' {
        $null = Enter-FmTeardownLock -LockPath $script:lockPath
        (Get-Content -LiteralPath (Join-Path $script:lockPath 'pid') -Raw).Trim() | Should -Be "$PID"
    }

    It 'reclaims a lock whose recorded owner is gone' {
        New-Item -ItemType Directory -Path $script:lockPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:lockPath 'pid') -Value "$(Get-DeadProcessId)"
        Enter-FmTeardownLock -LockPath $script:lockPath | Should -BeTrue
    }

    It 'reclaims a lock whose acquirer died before writing its pid' {
        New-Item -ItemType Directory -Path $script:lockPath -Force | Out-Null
        Enter-FmTeardownLock -LockPath $script:lockPath | Should -BeTrue
    }

    It 'treats a pid file it cannot READ as a LIVE owner rather than stealing it' {
        # A malformed lock is not proof the owner is dead. Refusing costs an
        # operator one `rm`; stealing costs two teardowns in one worktree.
        New-Item -ItemType Directory -Path $script:lockPath -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:lockPath 'pid') -Force | Out-Null
        Test-FmTeardownLockOwnerAlive -LockPath $script:lockPath | Should -BeTrue
        Enter-FmTeardownLock -LockPath $script:lockPath | Should -BeFalse
    }

    It 'is released only by its holder' {
        $null = Enter-FmTeardownLock -LockPath $script:lockPath
        Set-Content -LiteralPath (Join-Path $script:lockPath 'pid') -Value '999999'
        Exit-FmTeardownLock -LockPath $script:lockPath
        Test-Path -LiteralPath $script:lockPath | Should -BeTrue

        Set-Content -LiteralPath (Join-Path $script:lockPath 'pid') -Value "$PID"
        Exit-FmTeardownLock -LockPath $script:lockPath
        Test-Path -LiteralPath $script:lockPath | Should -BeFalse
    }
}

Describe 'Get-FmTaskParkedRunId' {
    BeforeAll {
        $script:nmRoot = Join-Path $TestDrive 'nmrun'
        $script:nmfx = New-TestFixture -Root $script:nmRoot -Branch 'fm/t1'
        $script:nmHead = Get-FmGitOutput -Directory $script:nmfx.Worktree -Arguments @('rev-parse', 'HEAD')
    }

    It 'concludes only a parked run that belongs to THIS worktree' {
        $parked = "id: run-1`nbranch: fm/t1`nhead: $script:nmHead`nstatus: awaiting_approval`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $parked | Should -Be 'run-1'

        $otherBranch = "id: run-2`nbranch: fm/other`nhead: $script:nmHead`nstatus: awaiting_approval`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $otherBranch | Should -Be ''

        # An autonomous step is driven against no-mistakes' own clone, so
        # removing this worktree does not orphan it: leave it alone.
        $running = "id: run-3`nbranch: fm/t1`nhead: $script:nmHead`nstatus: running`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $running | Should -Be ''

        $terminal = "id: run-4`nbranch: fm/t1`nhead: $script:nmHead`nstatus: awaiting_approval`noutcome: passed`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $terminal | Should -Be ''

        $gated = "id: run-5`nbranch: fm/t1`nhead: $script:nmHead`nstatus: running`nawaiting_agent: crew`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $gated | Should -Be 'run-5'
    }

    It 'refuses to attribute a run whose head does not match this worktree' {
        $foreign = "id: run-6`nbranch: fm/t1`nhead: 0123456789abcdef0123456789abcdef01234567`nstatus: awaiting_approval`n"
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput $foreign | Should -Be ''
    }

    It 'says nothing for empty status output' {
        Get-FmTaskParkedRunId -WorktreePath $script:nmfx.Worktree -StatusOutput '' | Should -Be ''
    }
}

Describe 'Remove-FmTaskPrPollArtifact' {
    BeforeEach {
        $script:prState = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:prState -Force | Out-Null
    }

    It 'is a no-op when the task has no artifacts' {
        Remove-FmTaskPrPollArtifact -StatePath $script:prState -Id 't1' -Confirm:$false | Should -BeTrue
    }

    It 'removes every artifact and the emptied quarantine directory' {
        foreach ($leaf in @('t1.check.sh', 't1.pr-poll', 't1.pr-poll-registration', 't1.pr-poll-retirement', 't1.check-trust')) {
            Set-Content -LiteralPath (Join-Path $script:prState $leaf) -Value 'x'
        }
        $quarantine = Join-Path $script:prState '.pr-check-quarantine'
        New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $quarantine 't1.diagnostic') -Value 'x'

        Remove-FmTaskPrPollArtifact -StatePath $script:prState -Id 't1' -Confirm:$false | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:prState -Force).Count | Should -Be 0
    }

    It 'leaves another task''s quarantine entries alone' {
        $quarantine = Join-Path $script:prState '.pr-check-quarantine'
        New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $quarantine 't1.diagnostic') -Value 'x'
        Set-Content -LiteralPath (Join-Path $quarantine 'other.diagnostic') -Value 'x'
        Remove-FmTaskPrPollArtifact -StatePath $script:prState -Id 't1' -Confirm:$false | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $quarantine 'other.diagnostic') | Should -BeTrue
    }

    It 'REFUSES an artifact that is a symlink out of the state directory' {
        Set-FmTestSymlinkSkip
        $outside = Join-Path $TestDrive 'pr-outside.txt'
        Set-Content -LiteralPath $outside -Value 'keep me'
        $link = Join-Path $script:prState 't1.check.sh'
        New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'symlinks are not available here' }
        Remove-FmTaskPrPollArtifact -StatePath $script:prState -Id 't1' -WarningAction SilentlyContinue -Confirm:$false |
            Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeTrue
        Test-Path -LiteralPath $link | Should -BeTrue
    }

    It 'REFUSES a quarantine path that is not an ordinary directory' {
        Set-Content -LiteralPath (Join-Path $script:prState 't1.pr-poll') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:prState '.pr-check-quarantine') -Value 'not a directory'
        Remove-FmTaskPrPollArtifact -StatePath $script:prState -Id 't1' -WarningAction SilentlyContinue -Confirm:$false |
            Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:prState 't1.pr-poll') | Should -BeTrue
    }
}

Describe 'Test-FmTeardownTasksAxiBacklog' {
    It 'honours a configured manual backlog backend' {
        $config = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $config 'backlog-backend') -Value "manual`n"
        Test-FmTeardownTasksAxiBacklog -ConfigPath $config | Should -BeFalse
    }
}

Describe 'the stale-lock symlink refusal' {
    It 'never treats a SYMLINKED index.lock as stale' {
        Set-FmTestSymlinkSkip
        # Removing it would follow the link and delete something else entirely.
        $target = Join-Path $TestDrive 'lock-target.txt'
        Set-Content -LiteralPath $target -Value ''
        $link = Join-Path $TestDrive 'linked.lock'
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'symlinks are not available here' }
        [System.IO.File]::SetLastWriteTimeUtc($target, [DateTime]::UtcNow.AddMinutes(-10))
        Mock Test-FmTeardownGitLockHeld { 'free' }
        Mock Test-FmTeardownDirectoryHeld { 'none' }
        Test-FmTeardownGitLockStale -LockPath $link -TaskId 'alpha' -MinimumAgeSeconds 30 | Should -BeFalse
    }
}
