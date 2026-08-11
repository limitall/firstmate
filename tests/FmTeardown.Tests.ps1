#requires -Version 7.0
# Teardown tests. The refusal path is tested harder than the success path on
# purpose: a false refusal costs a rerun, a false success destroys work that
# exists nowhere else.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }
}

Describe 'Test-FmTeardownSafety - the landed-work test' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach {
        Remove-FmTestHome -TestHome $script:TestHome
    }

    Context 'uncommitted work is never landed' {
        It 'refuses a worktree with modified tracked files' {
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'README.md'), "edited`n")
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'REFUSED: worktree .* has uncommitted changes\.'
            ($result.Messages -join "`n") | Should -Match 'Commit them'
        }

        It 'refuses a worktree with an untracked file' {
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'scratch.txt'), "notes`n")
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 1
        }

        It 'refuses a worktree with staged-but-uncommitted work' {
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'staged.txt'), "staged`n")
            Invoke-FmTestGit -RepoPath $script:Repo.Worktree add staged.txt | Out-Null
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 1
        }

        It 'ignores only the harness''s own droppings' {
            [void](New-Item -ItemType Directory -Path (Join-Path $script:Repo.Worktree '.claude') -Force)
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree '.claude/settings.local.json'), "{}`n")
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree '.fm-grok-turnend'), "x`n")
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree '.fm-kimi-turnend'), "x`n")
            # Nothing else is dirty and nothing is unpushed, so this proceeds.
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 0
        }

        It 'still refuses when a dropping-shaped name is a real tracked change' {
            # `.claude-notes` is NOT the ignored pattern: only `?? .claude/` and
            # the exact turn-end markers are.
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree '.claude-notes'), "real work`n")
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 1
        }
    }

    Context 'committed work that is on no remote' {
        It 'refuses when the commit is not in the default branch either' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'REFUSED: worktree .* has work not on any remote and not landed\.'
            ($result.Messages -join "`n") | Should -Match 'unpushed commits:'
            ($result.Messages -join "`n") | Should -Match 'Push the branch, land its PR'
        }

        It 'lists at most five unpushed commits in the refusal' {
            1..7 | ForEach-Object {
                New-FmTestCommit -RepoPath $script:Repo.Worktree -FileName "f$_.txt" -Content "$_`n" -Message "commit $_"
            }
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project
            $result.Code | Should -Be 1
            $listed = ($result.Messages | Where-Object { $_ -match 'unpushed commits:' })
            ([string]$listed).Split("`n").Count | Should -Be 6   # header plus five commits
        }

        It 'proceeds once the content is present in the default branch (squash-merge shape)' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            # Land the same content on main by a separate commit, exactly as a
            # squash merge would: the branch's own commit is on no remote and is
            # not an ancestor of main, but main already contains its change.
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Project 'feature.txt'), "feature`n")
            Invoke-FmTestGit -RepoPath $script:Repo.Project add feature.txt | Out-Null
            Invoke-FmTestGit -RepoPath $script:Repo.Project commit -m 'squashed feature' | Out-Null
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 0
        }

        It 'refuses when the default branch has only part of the work' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            New-FmTestCommit -RepoPath $script:Repo.Worktree -FileName 'second.txt' -Content "second`n" -Message 'second'
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Project 'feature.txt'), "feature`n")
            Invoke-FmTestGit -RepoPath $script:Repo.Project add feature.txt | Out-Null
            Invoke-FmTestGit -RepoPath $script:Repo.Project commit -m 'only the first change' | Out-Null
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 1
        }

        It 'proceeds when the commits are reachable from a remote-tracking branch' {
            $remote = Join-Path $script:TestHome.Path 'remote.git'
            Invoke-FmTestGit -RepoPath $script:TestHome.Path init --bare $remote | Out-Null
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            Invoke-FmTestGit -RepoPath $script:Repo.Worktree remote add origin $remote | Out-Null
            Invoke-FmTestGit -RepoPath $script:Repo.Worktree push origin HEAD | Out-Null
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project).Code | Should -Be 0
        }
    }

    Context 'local-only tasks' {
        It 'refuses commits not yet merged into the local default branch' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project -Mode 'local-only'
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'REFUSED: local-only worktree .* has work not yet merged into main and not on any remote\.'
            ($result.Messages -join "`n") | Should -Match 'Merge the branch into local main first'
        }

        It 'refuses uncommitted work even when every commit is merged' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            Invoke-FmTestGit -RepoPath $script:Repo.Project merge --ff-only $script:Repo.Branch | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'dirty.txt'), "dirty`n")
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project -Mode 'local-only'
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'uncommitted changes present'
        }

        It 'proceeds once the branch is merged into the local default branch' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            Invoke-FmTestGit -RepoPath $script:Repo.Project merge --ff-only $script:Repo.Branch | Out-Null
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project -Mode 'local-only').Code | Should -Be 0
        }

        It 'refuses when the default branch cannot be determined' {
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath (Join-Path $script:TestHome.Path 'no-such-project') -Mode 'local-only'
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'cannot determine default branch'
        }
    }

    Context 'an inspection that cannot run refuses like unlanded work' {
        It 'refuses when the worktree is not a git repository at all' {
            $plain = Join-Path $script:TestHome.Path 'plain'
            [void](New-Item -ItemType Directory -Path $plain -Force)
            $result = Test-FmTeardownSafety -WorktreePath $plain -ProjectPath $script:Repo.Project
            $result.Code | Should -Be 1
            ($result.Messages -join "`n") | Should -Match 'REFUSED: cannot inspect worktree .* for uncommitted changes\.'
        }

        It 'reports lock-blocked rather than a verdict when a git lock is present' {
            # A corrupt index makes `git status` fail exactly as a mid-operation
            # crash can, and the lock is what teardown must notice.
            $lock = Get-FmTeardownWorktreeLockPath -Path $script:Repo.Worktree
            $lock | Should -Not -BeNullOrEmpty
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree '.git'), (Get-Content -Raw -LiteralPath (Join-Path $script:Repo.Worktree '.git')))
            $indexPath = Get-FmGitFirstLine (Invoke-FmGit -Directory $script:Repo.Worktree -Arguments @('rev-parse', '--git-path', 'index'))
            [System.IO.File]::WriteAllText($indexPath, 'not an index')
            [System.IO.File]::WriteAllText($lock, '')
            $result = Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project
            $result.Code | Should -Be 3
        }

        It 'leaves a fresh lock in place because it may belong to a live process' {
            $lock = Get-FmTeardownWorktreeLockPath -Path $script:Repo.Worktree
            [System.IO.File]::WriteAllText($lock, '')
            Clear-FmTeardownStaleSafetyLock -WorktreePath $script:Repo.Worktree | Should -BeFalse
            Test-Path -LiteralPath $lock | Should -BeTrue
        }

        It 'clears a provably stale lock and allows the checks to be retried' {
            $lock = Get-FmTeardownWorktreeLockPath -Path $script:Repo.Worktree
            [System.IO.File]::WriteAllText($lock, '')
            [System.IO.File]::SetLastWriteTimeUtc($lock, (Get-Date).ToUniversalTime().AddMinutes(-10))
            Clear-FmTeardownStaleSafetyLock -WorktreePath $script:Repo.Worktree | Should -BeTrue
            Test-Path -LiteralPath $lock | Should -BeFalse
        }
    }

    Context 'documented carve-outs' {
        It 'skips the checks for a scout, whose worktree is declared scratch' {
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'dirty.txt'), "dirty`n")
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project -Kind 'scout').Code | Should -Be 0
        }

        It 'skips the checks under -Force, the explicit discard authority' {
            [System.IO.File]::WriteAllText((Join-Path $script:Repo.Worktree 'dirty.txt'), "dirty`n")
            New-FmTestCommit -RepoPath $script:Repo.Worktree
            (Test-FmTeardownSafety -WorktreePath $script:Repo.Worktree -ProjectPath $script:Repo.Project -Force).Code | Should -Be 0
        }

        It 'proceeds when the worktree is already gone' {
            (Test-FmTeardownSafety -WorktreePath (Join-Path $script:TestHome.Path 'gone') -ProjectPath $script:Repo.Project).Code | Should -Be 0
        }
    }
}

Describe 'Invoke-FmTeardown' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach {
        Remove-FmTestHome -TestHome $script:TestHome
    }

    It 'rejects a task id that is not a single path component' {
        (Invoke-FmTeardown -Id '../escape' -Confirm:$false).ExitCode | Should -Be 2
    }

    It 'fails when the task has no metadata' {
        $result = Invoke-FmTeardown -Id 'nosuch' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'no meta for task nosuch'
    }

    It 'refuses unlanded work and preserves every durable record' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            kind     = 'ship'
            mode     = 'direct-PR'
            window   = 'fleet:fm-t1'
        } | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "working: building`n")

        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'not on any remote and not landed'
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.status') | Should -BeTrue
        Test-Path -LiteralPath $script:Repo.Worktree | Should -BeTrue
        # The branch survives too: nothing destructive runs before the refusal.
        Invoke-FmTestGit -RepoPath $script:Repo.Project 'rev-parse' '--verify' 'refs/heads/fm/t1' | Should -Not -BeNullOrEmpty
    }

    It 'refuses a scout with no report' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            kind     = 'scout'
        } | Out-Null
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'REFUSED: scout task t1 has no report'
    }

    It 'refuses a scout whose completion gate cannot be checked' {
        [void](New-Item -ItemType Directory -Path (Join-Path $script:TestHome.Data 't1') -Force)
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.Data 't1/report.md'), "# findings`n")
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            kind     = 'scout'
        } | Out-Null
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'unresolved-decision completion gate'
    }

    It 'refuses a secondmate home rather than half-retiring it' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            kind     = 'secondmate'
            home     = $script:Repo.Worktree
        } | Out-Null
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'REFUSED: task t1 is a secondmate home'
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
    }

    It 'refuses a remote-placed secondmate' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree    = $script:Repo.Worktree
            project     = $script:Repo.Project
            kind        = 'secondmate'
            remote_host = 'builder.example.invalid'
        } | Out-Null
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'remote-placed secondmate'
    }

    It 'refuses a backend whose worktree and pane lifecycle is not ported' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            backend  = 'orca'
        } | Out-Null
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'runs on the orca backend'
    }

    It 'refuses a second concurrent lifecycle action for the same task' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{ worktree = $script:Repo.Worktree } | Out-Null
        $lock = Join-Path $script:TestHome.State '.control-t1.lock'
        [void](New-Item -ItemType Directory -Path $lock -Force)
        # A live owner: this very process, which is certainly alive.
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), "$PID`n")
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'another lifecycle action is already running'
    }

    It 'aborts without destroying anything when the worktree cannot be returned' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        Invoke-FmTestGit -RepoPath $script:Repo.Project merge --ff-only $script:Repo.Branch | Out-Null
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            mode     = 'local-only'
        } | Out-Null
        # The worktree is a plain linked worktree, not a treehouse pool slot, so
        # the return fails - as it also would with no treehouse installed at all.
        # Either way teardown aborts and every durable record survives.
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'treehouse (is not available|return failed)'
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
        Test-Path -LiteralPath $script:Repo.Worktree | Should -BeTrue
    }

    It 'completes and clears volatile state once the worktree is already gone' {
        $gone = Join-Path $script:TestHome.Path 'already-returned'
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $gone
            project  = $script:Repo.Project
            mode     = 'direct-PR'
            window   = 'fleet:fm-t1'
            pr       = 'https://example.invalid/pr/7'
        } | Out-Null
        foreach ($leaf in @('t1.status', 't1.turn-ended', 't1.check.sh', 't1.pr-poll', '.t1.open-decisions-cursor')) {
            [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State $leaf), "x`n")
        }
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 0
        ($result.Messages -join "`n") | Should -Match 'teardown t1 complete'
        ($result.Messages -join "`n") | Should -Match 'Backlog: t1 just finished'
        foreach ($leaf in @('t1.meta', 't1.status', 't1.turn-ended', 't1.check.sh', 't1.pr-poll', '.t1.open-decisions-cursor')) {
            Test-Path -LiteralPath (Join-Path $script:TestHome.State $leaf) | Should -BeFalse
        }
        Test-Path -LiteralPath (Join-Path $script:TestHome.State '.control-t1.lock') | Should -BeFalse
    }

    It 'refuses to remove a PR-check artifact that is a symlink out of the state directory' {
        $gone = Join-Path $script:TestHome.Path 'already-returned'
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{ worktree = $gone; project = $script:Repo.Project } | Out-Null
        $outside = Join-Path $script:TestHome.Path 'outside.txt'
        [System.IO.File]::WriteAllText($outside, "keep me`n")
        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $script:TestHome.State 't1.check.sh') -Target $outside -Force)
        $result = Invoke-FmTeardown -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        Test-Path -LiteralPath $outside | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
    }

    It 'discards unlanded work only under -Force' {
        $gone = Join-Path $script:TestHome.Path 'already-returned'
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $gone
            project  = $script:Repo.Project
        } | Out-Null
        (Invoke-FmTeardown -Id 't1' -Force -Confirm:$false).ExitCode | Should -Be 0
    }
}

Describe 'git invocation' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'passes a short flag through as an explicit argument array' {
        # A bare -D in a remaining-arguments call binds to the -Debug common
        # parameter and never reaches git, which would silently leave the task
        # branch behind at teardown.
        Invoke-FmTestGit -RepoPath $script:Repo.Project branch 'side' | Out-Null
        (Invoke-FmGit -Directory $script:Repo.Project -Arguments @('branch', '-D', 'side')).ExitCode | Should -Be 0
        (Invoke-FmGit -Directory $script:Repo.Project -Arguments @('rev-parse', '--verify', '--quiet', 'refs/heads/side')).ExitCode | Should -Not -Be 0
    }

    It 'confirms a commit object that is already present, and rejects one that is not' {
        $head = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        Confirm-FmTeardownCommitObject -WorktreePath $script:Repo.Worktree -Target '' -Commit $head | Should -BeTrue
        Confirm-FmTeardownCommitObject -WorktreePath $script:Repo.Worktree -Target '' -Commit '0123456789abcdef0123456789abcdef01234567' | Should -BeFalse
    }
}

Describe 'Get-FmBacklogRefreshReminder' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'points at the manual backlog when the backend is configured manual' {
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.Config 'backlog-backend'), "manual`n")
        $line = Get-FmBacklogRefreshReminder -Id 't1' -Kind 'ship' -Mode 'direct-PR' -PrUrl '' -DataPath $script:TestHome.Data -ConfigPath $script:TestHome.Config
        $line | Should -Match 'Update data/backlog\.md'
    }

    It 'says nothing for a secondmate, which is not a backlog item' {
        Get-FmBacklogRefreshReminder -Id 't1' -Kind 'secondmate' -Mode '' -PrUrl '' -DataPath $script:TestHome.Data -ConfigPath $script:TestHome.Config | Should -Be ''
    }
}
