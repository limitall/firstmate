#requires -Version 7.0
# Local-merge tests. This is the one sanctioned state-changing git action in a
# project, so its guards matter more than its happy path: wrong mode, missing
# branch, wrong or dirty checkout, and a diverged branch all refuse.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }
}

Describe 'Invoke-FmMergeLocal' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            mode     = 'local-only'
        } | Out-Null
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'fast-forwards the default branch onto the task branch' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        $head = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()

        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 0
        ($result.Messages -join "`n") | Should -Match 'merged fm/t1 into local main'
        (Invoke-FmTestGit -RepoPath $script:Repo.Project rev-parse main).Trim() | Should -Be $head
    }

    It 'refuses a diverged branch and asks for a rebase' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        # main advances independently, so the branch is no longer a fast-forward.
        New-FmTestCommit -RepoPath $script:Repo.Project -FileName 'main-side.txt' -Content "main`n" -Message 'main moved on'
        $before = (Invoke-FmTestGit -RepoPath $script:Repo.Project rev-parse main).Trim()

        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'REFUSED: fm/t1 is not a fast-forward of main \(it has diverged\)\.'
        ($result.Messages -join "`n") | Should -Match 'Have the crewmate rebase fm/t1 onto main'
        (Invoke-FmTestGit -RepoPath $script:Repo.Project rev-parse main).Trim() | Should -Be $before
    }

    It 'refuses a task that is not local-only' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            mode     = 'no-mistakes'
        } | Out-Null
        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'is mode=no-mistakes, not local-only'
    }

    It 'refuses when the task branch does not exist' {
        Invoke-FmTestGit -RepoPath $script:Repo.Project worktree remove --force $script:Repo.Worktree | Out-Null
        # -Arguments explicitly: a bare -D would bind to the common -Debug switch.
        Invoke-FmTestGit -RepoPath $script:Repo.Project -Arguments @('branch', '-D', 'fm/t1') | Out-Null
        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'branch fm/t1 does not exist'
    }

    It 'refuses when the project checkout is not on its default branch' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        Invoke-FmTestGit -RepoPath $script:Repo.Project checkout -b 'side' | Out-Null
        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match "is on 'side', expected default branch 'main'"
    }

    It 'refuses to merge into a dirty checkout' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        [System.IO.File]::WriteAllText((Join-Path $script:Repo.Project 'README.md'), "edited in the project`n")
        $result = Invoke-FmMergeLocal -Id 't1' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'has a dirty working tree; refusing to merge into it'
    }

    It 'fails when the task has no metadata' {
        $result = Invoke-FmMergeLocal -Id 'nosuch' -Confirm:$false
        $result.ExitCode | Should -Be 1
        ($result.Messages -join "`n") | Should -Match 'no meta for task nosuch'
    }

    It 'rejects a task id that is not a single path component' {
        (Invoke-FmMergeLocal -Id '../escape' -Confirm:$false).ExitCode | Should -Be 1
    }
}
