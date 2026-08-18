#requires -Version 7.0
# Crew-state tests. The invariant under test is that the status log is never
# treated as current state on its own, and that anything unproven reads
# `unknown` rather than a state a supervisor would act on.

# The seam stubs below declare their owner's full published parameter list and
# then ignore it, which is the point of the stub: a stub that dropped a name
# would make the caller's by-name invocation throw and its catch would read that
# as "no owner", and a stub declaring no parameters at all would swallow the
# arguments into $args unnoticed. PSReviewUnusedParameter is inverted here.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Test seam stubs must declare their owner''s full published parameter list without using it; see the comment above.')]
param()
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

Describe 'the run-liveness clause on the status-log fallback' {
    # The status-log fallback is the one path with no authority of its own: it
    # reports the crew's last EVENT because nothing better is available. That is
    # exactly where a crew waiting on a finished run and a crew waiting on a
    # running one used to read identically, and a supervisor acting on the
    # difference had to derive it by hand - wrongly, in every recorded instance
    # (docs/finished-run-stall.md).
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:BusyVerdict = 'idle record'
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
        } | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "working: mid-flight`n")
    }
    AfterEach {
        Remove-Item -Path 'function:Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue
        Remove-FmTestHome -TestHome $script:TestHome
    }

    It 'says nothing of this task is running when the reading is none' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'none'; ProcessId = @(); AgentProcessId = @(7); Detail = 'd' }
        }
        $line = Get-FmCrewState -Id 't1'
        $line | Should -Match '^state: working · source: status-log · mid-flight'
        $line | Should -Match 'run-liveness: none'
    }

    It 'says work IS in flight when the reading finds processes' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'processes'; ProcessId = @(11, 12); AgentProcessId = @(7); Detail = 'd' }
        }
        Get-FmCrewState -Id 't1' | Should -Match 'run-liveness: 2 live process\(es\) - work IS in flight'
    }

    It 'adds nothing when the reading is inconclusive' {
        # `source:` already says where the answer came from, so an unknown
        # clause on every line would be noise rather than information.
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'unknown'; ProcessId = @(); AgentProcessId = @(); Detail = 'd' }
        }
        Get-FmCrewState -Id 't1' | Should -Be 'state: working · source: status-log · mid-flight'
    }

    It 'says the reading did NOT run when it throws' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            throw 'no process table'
        }
        Get-FmCrewState -Id 't1' | Should -Match 'run-liveness: unknown \(the reading did NOT run\)'
    }

    It 'carries the clause onto the no-source line too' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'none'; ProcessId = @(); AgentProcessId = @(7); Detail = 'd' }
        }
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "resolved: closed`n")
        $line = Get-FmCrewState -Id 't1'
        $line | Should -Match '^state: unknown · source: none · no current-state source available'
        $line | Should -Match 'run-liveness: none'
    }

    It 'never pays for the reading when the endpoint is busy' {
        # A busy pane already answers the question, and this read costs a whole
        # process table.
        $script:LivenessCalls = 0
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            $script:LivenessCalls++
            return [pscustomobject]@{ TaskId = $TaskId; State = 'none'; ProcessId = @(); AgentProcessId = @(); Detail = 'd' }
        }
        $script:BusyVerdict = 'busy lifecycle-record'
        Get-FmCrewState -Id 't1' | Should -Be 'state: working · source: pane · harness busy (busy lifecycle-record)'
        $script:LivenessCalls | Should -Be 0
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

Describe 'the run-step mapping' {
    BeforeAll {
        $script:NoCi = { param($runId) 'unknown' }
        function Resolve { param([string]$Output, [string]$Source = 'full', [string]$Coarse = '', [scriptblock]$Ci = $script:NoCi)
            Resolve-FmCrewRunState -Output $Output -RunSource $Source -CoarseStatus $Coarse -CiChecksStateProvider $Ci
        }
    }

    It 'maps a terminal outcome' {
        (Resolve -Output "outcome: passed`n").State | Should -Be 'done'
        (Resolve -Output "outcome: checks-passed`n").Detail | Should -Be 'checks green: PR ready for review'
        (Resolve -Output "outcome: failed`n").State | Should -Be 'failed'
        (Resolve -Output "outcome: cancelled`n").State | Should -Be 'failed'
        (Resolve -Output "outcome: something-new`n").State | Should -Be 'unknown'
    }

    It 'maps an active step to working' {
        (Resolve -Output "status: running`n").State | Should -Be 'working'
        (Resolve -Output "status: fixing`n").Detail | Should -Be 'validating (fixing)'
        (Resolve -Output "status: `n").Detail | Should -Be 'run active'
    }

    It 'maps a gate to parked, with its findings count and ask-user marker' {
        $out = "status: awaiting_approval`ngate:`n  step: review`nfindings[2]{id,title}:`n  1,ask-user thing`n"
        $run = Resolve -Output $out
        $run.State | Should -Be 'parked'
        $run.Detail | Should -Be 'parked at review: 2 finding(s) (ask-user: authority decision)'
    }

    It 'parks on an awaiting_agent field even when the status word says otherwise' {
        (Resolve -Output "status: running`nawaiting_agent: crew`n").State | Should -Be 'parked'
    }

    It 'promotes a green ci log to done, so a green PR never reads as still validating' {
        $green = { param($runId) 'green' }
        $run = Resolve -Output "id: run-1`nstatus: ci`n" -Ci $green
        $run.State | Should -Be 'done'
        $run.Detail | Should -Be 'checks green: PR ready for review (still monitoring for merge/close)'
    }

    It 'keeps a not-ready ci log as working' {
        $notReady = { param($runId) 'not-ready' }
        (Resolve -Output "id: run-1`nstatus: ci`n" -Ci $notReady).State | Should -Be 'working'
    }

    It 'maps the coarse runs-list statuses without step detail' {
        (Resolve -Output '' -Source 'coarse' -Coarse 'running').Detail | Should -Be 'validating (background run)'
        (Resolve -Output '' -Source 'coarse' -Coarse 'completed').State | Should -Be 'done'
        (Resolve -Output '' -Source 'coarse' -Coarse 'cancelled').State | Should -Be 'failed'
        (Resolve -Output '' -Source 'coarse' -Coarse 'weird').State | Should -Be 'unknown'
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

Describe 'reconciling a stale status log against an attributed run' {
    # These drive Get-FmCrewState end to end with the run lookup live, which is
    # where the log reconciliation and the ci-monitor override actually happen -
    # Resolve-FmCrewRunState above covers the pure mapping only. The lookup is
    # gated on a real no-mistakes being installed, so these skip where it is not;
    # the bounded CLI call itself is mocked and no run is ever started.
    BeforeDiscovery {
        $script:HasNoMistakes = $null -ne (Get-Command -Name 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue)
    }
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
        $script:Head = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            window   = 'fleet:fm-t1'
            kind     = 'ship'
        } | Out-Null
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'flags a needs-decision line the run has moved past as superseded' -Skip:(-not $script:HasNoMistakes) {
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "needs-decision: which shape?`n")
        Mock Invoke-FmNoMistakes { "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: running`n" }
        Get-FmCrewState -Id 't1' |
            Should -Be 'state: working · source: run-step · validating (running) · status-log superseded by active run'
    }

    It 'leaves a needs-decision line alone when the run really is parked' -Skip:(-not $script:HasNoMistakes) {
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "needs-decision: which shape?`n")
        Mock Invoke-FmNoMistakes { "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: awaiting_approval`n" }
        $line = Get-FmCrewState -Id 't1'
        $line | Should -Match '^state: parked'
        $line | Should -Not -Match 'superseded'
    }

    It 'names a finished run as the source even after the endpoint has closed' -Skip:(-not $script:HasNoMistakes) {
        # The run step is authoritative regardless of endpoint liveness, so a
        # crew whose pane is gone still reports what its run says.
        Mock Invoke-FmNoMistakes { "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: completed`noutcome: passed`n" }
        Mock Get-FmCrewEndpointVerdict { throw 'the endpoint must not be probed while a run is attributed' }
        Get-FmCrewState -Id 't1' | Should -Be 'state: done · source: run-step · run passed: PR merged/closed'
    }

    It 'falls back to the coarse runs list when axi status answers for another branch' -Skip:(-not $script:HasNoMistakes) {
        Mock Invoke-FmNoMistakes {
            param($WorktreePath, $TimeoutSeconds, $Arguments)
            if ($Arguments -contains 'runs') { return "running fm/t1 $($script:Head) 2026-08-12`n" }
            return "id: run-9`nbranch: fm/other`nhead: $($script:Head)`nstatus: running`n"
        }
        Get-FmCrewState -Id 't1' | Should -Be 'state: working · source: run-step · validating (background run)'
    }

    It 'skips a coarse row whose sha does not belong to this worktree' -Skip:(-not $script:HasNoMistakes) {
        $stale = (Invoke-FmTestGit -RepoPath $script:Repo.Worktree rev-parse HEAD).Trim()
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        Mock Invoke-FmNoMistakes {
            param($WorktreePath, $TimeoutSeconds, $Arguments)
            if ($Arguments -contains 'runs') { return "completed fm/t1 $stale 2026-08-12`n" }
            return "id: run-9`nbranch: fm/other`nhead: $stale`nstatus: running`n"
        }
        Get-FmCrewState -Id 't1' | Should -Not -Match 'run-step'
    }

    It 'promotes a green ci log to done through the whole reader, not just the mapper' -Skip:(-not $script:HasNoMistakes) {
        # End to end, because the wiring is what breaks: the ci-checks provider is
        # handed to the mapper as a scriptblock, and a mis-scoped one throws here
        # while every pure mapper test still passes.
        Mock Invoke-FmNoMistakes {
            param($WorktreePath, $TimeoutSeconds, $Arguments)
            if ($Arguments -contains 'logs') { return "all CI checks passed - still monitoring until merged or closed`n" }
            return "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: ci`nsteps[1]{step,status,findings}:`n  ci, running, 0`n"
        }
        Get-FmCrewState -Id 't1' |
            Should -Be 'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'
    }

    It 'accepts a done log reporting a green PR while the run keeps monitoring' -Skip:(-not $script:HasNoMistakes) {
        # No ci step to read, so the run alone still says working; the worker's own
        # "PR ... checks green" line is what closes it out.
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "done: PR ready, checks green`n")
        Mock Invoke-FmNoMistakes {
            param($WorktreePath, $TimeoutSeconds, $Arguments)
            if ($Arguments -contains 'logs') { return '' }
            return "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: running`n"
        }
        Get-FmCrewState -Id 't1' |
            Should -Be 'state: done · source: status-log · PR ready, checks green · run still monitoring PR'
    }

    It 'never lets a fixing run read as done from that same log line' -Skip:(-not $script:HasNoMistakes) {
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State 't1.status'), "done: PR ready, checks green`n")
        Mock Invoke-FmNoMistakes {
            param($WorktreePath, $TimeoutSeconds, $Arguments)
            if ($Arguments -contains 'logs') { return '' }
            return "id: run-1`nbranch: fm/t1`nhead: $($script:Head)`nstatus: fixing`n"
        }
        Get-FmCrewState -Id 't1' | Should -Match '^state: working'
    }
}
