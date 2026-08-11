#requires -Version 7.0
# Crew-state tests. The invariant under test is that the status log is never
# treated as current state on its own, and that anything unproven reads
# `unknown` rather than a state a supervisor would act on.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    # Stand-in for the backend area's endpoint reader. Its absence is itself a
    # tested behaviour, so each test opts in by setting the script-scoped verdict.
    function Get-FmBackendBusyVerdict {
        param($Backend, $Target, $Id, $Harness, $StatePath)
        return $script:BusyVerdict
    }
}

Describe 'Get-FmCrewState' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:BusyVerdict = 'idle record'
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'reports unknown when the task has no metadata' {
        Get-FmCrewState -Id 'nosuch' | Should -Be 'state: unknown · source: none · no metadata for nosuch'
    }

    It 'reports unknown when the worktree is gone' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = (Join-Path $script:TestHome.Path 'torn-down')
            window   = 'fleet:fm-t1'
        } | Out-Null
        Get-FmCrewState -Id 't1' | Should -Be 'state: unknown · source: none · worktree gone (torn down?)'
    }

    It 'reports unknown when no endpoint was recorded' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{ worktree = $script:Repo.Worktree } | Out-Null
        Get-FmCrewState -Id 't1' | Should -Be 'state: unknown · source: none · no backend target recorded'
    }

    It 'reports a busy endpoint as working, sourced from the pane' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        $script:BusyVerdict = 'busy lifecycle-record'
        Get-FmCrewState -Id 't1' | Should -Be 'state: working · source: pane · harness busy (busy lifecycle-record)'
    }

    It 'reports unknown for an unverified endpoint verdict rather than guessing' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        $script:BusyVerdict = 'unknown no-record'
        Get-FmCrewState -Id 't1' | Should -Match '^state: unknown · source: pane'
    }

    It 'falls back to the status log only for an idle endpoint' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "working: mid-flight`nblocked: no credentials`n")
        Get-FmCrewState -Id 't1' | Should -Be 'state: blocked · source: status-log · no credentials'
    }

    It 'reports a declared pause distinctly from a wedge-suspect idle' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "paused: upstream release lands Tuesday`n")
        Get-FmCrewState -Id 't1' | Should -Be 'state: paused · source: status-log · upstream release lands Tuesday'
    }

    It 'never turns a decision-closing resolved line into a state' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "needs-decision: which shape?`nresolved: two endpoints`n")
        Get-FmCrewState -Id 't1' | Should -Be 'state: unknown · source: none · no current-state source available'
    }

    It 'reads a secondmate from its status log, because an idle endpoint is healthy for one' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
            kind     = 'secondmate'
        } | Out-Null
        $script:BusyVerdict = 'unknown no-record'
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "done: routed work finished`n")
        Get-FmCrewState -Id 't1' | Should -Be 'state: done · source: status-log · routed work finished'
    }
}

Describe 'no-mistakes run attribution' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'binds a run whose head is the worktree head' {
        $head = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead $head | Should -BeTrue
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead $head.Substring(0, 8) | Should -BeTrue
    }

    It 'binds a run whose head advanced past local HEAD on the same history' {
        # Pipeline fix commits advance the run tip along this line of history.
        New-FmTestCommit -RepoPath $script:Repo.Worktree -FileName 'fix.txt' -Content "fix`n" -Message 'pipeline fix'
        $runHead = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        Invoke-FmTestGit -RepoPath $script:Repo.Worktree reset --hard HEAD~1 | Out-Null
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead $runHead | Should -BeTrue
    }

    It 'refuses a run head that local work has advanced past' {
        $runHead = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead $runHead | Should -BeFalse
    }

    It 'refuses a missing or unknown run head' {
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead '' | Should -BeFalse
        Test-FmNmHeadMatchesWorktree -WorktreePath $script:Repo.Worktree -RunHead '0123456789abcdef0123456789abcdef01234567' | Should -BeFalse
    }

    It 'concludes only a parked run that belongs to this worktree' {
        $head = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        $parked = "id: run-1`nbranch: fm/t1`nhead: $head`nstatus: awaiting_approval`n"
        Get-FmTaskParkedRunId -WorktreePath $script:Repo.Worktree -StatusOutput $parked | Should -Be 'run-1'

        $otherBranch = "id: run-2`nbranch: fm/other`nhead: $head`nstatus: awaiting_approval`n"
        Get-FmTaskParkedRunId -WorktreePath $script:Repo.Worktree -StatusOutput $otherBranch | Should -Be ''

        $running = "id: run-3`nbranch: fm/t1`nhead: $head`nstatus: running`n"
        Get-FmTaskParkedRunId -WorktreePath $script:Repo.Worktree -StatusOutput $running | Should -Be ''

        $terminal = "id: run-4`nbranch: fm/t1`nhead: $head`nstatus: awaiting_approval`noutcome: passed`n"
        Get-FmTaskParkedRunId -WorktreePath $script:Repo.Worktree -StatusOutput $terminal | Should -Be ''

        $gated = "id: run-5`nbranch: fm/t1`nhead: $head`nstatus: running`nawaiting_agent: crew`n"
        Get-FmTaskParkedRunId -WorktreePath $script:Repo.Worktree -StatusOutput $gated | Should -Be 'run-5'
    }
}

Describe 'TOON field reads' {
    It 'reads a scalar field and strips quotes' {
        $out = "id: `"run-9`"`nstatus: awaiting_approval`nbranch: fm/t1`n"
        Get-FmNmField -Output $out -Key 'id' | Should -Be 'run-9'
        Get-FmNmField -Output $out -Key 'status' | Should -Be 'awaiting_approval'
        Get-FmNmField -Output $out -Key 'missing' | Should -Be ''
    }

    It 'reads the gate name, findings count, and effective ci step status' {
        $out = "status: awaiting_approval`ngate:`n  step: review`nfindings[3]{id,title}:`n"
        Get-FmNmGateStatus -Output $out | Should -Be 'awaiting_approval'
        Get-FmNmGateName -Output $out | Should -Be 'review'
        Get-FmNmGateFindingsCount -Output $out | Should -Be '3'
        Get-FmNmEffectiveCiStepStatus -Output "steps:`n  ci, running, 0`n" -RunStatus 'ci' | Should -Be 'running'
        Get-FmNmEffectiveCiStepStatus -Output '' -RunStatus 'fixing' | Should -Be 'fixing'
    }
}
