#requires -Version 7.0
# Pester 5+/6 tests for the four public verbs: Start-FmWorker, Send-FmText,
# Get-FmPane, Stop-FmWorker.
#
# Every herdr and treehouse call is mocked. Nothing here starts, stops, or
# otherwise drives a real herdr server or a real worktree pool.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    # Every Private file, not a hand-picked pair: Start-FmWorker composes the
    # dispatch area (the delivery contract, harness resolution, the record's
    # field order) as well as the backend and worktree ones.
    foreach ($private in (Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' | Sort-Object Name)) {
        . $private.FullName
    }
    foreach ($public in (Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' | Sort-Object Name)) {
        . $public.FullName
    }

    function New-TestHome {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path (Join-Path $Path 'state') -Force | Out-Null
        $Path
    }

    function New-TaskRecord {
        param(
            [Parameter(Mandatory)][string]$StateDir,
            [Parameter(Mandatory)][string]$TaskId,
            [string]$Harness = 'claude',
            [string]$Backend = 'herdr',
            [string]$LeaseId = 'L-1'
        )
        $lines = @(
            'window=default:w1:p2'
            "endpoint_task_id=$TaskId"
            'worktree=/wt/alpha'
            'project=/proj'
            "harness=$Harness"
            'kind=ship'
            "backend=$Backend"
            'herdr_session=default'
            'herdr_workspace_id=w1'
            'herdr_tab_id=t1'
            'herdr_pane_id=w1:p2'
            "treehouse_lease_id=$LeaseId"
        )
        [System.IO.File]::WriteAllText((Join-Path $StateDir "$TaskId.meta"), ($lines -join "`n") + "`n")
    }
}

Describe 'Start-FmWorker' {
    BeforeEach {
        $script:fmHome = New-TestHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $script:stateDir = Join-Path $script:fmHome 'state'
        $script:project = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path $script:project -Force | Out-Null
        $script:brief = Join-Path $TestDrive 'brief.md'
        Set-Content -LiteralPath $script:brief -Value '# brief'
        $script:worktree = Join-Path $TestDrive 'wt-alpha'
        New-Item -ItemType Directory -Path $script:worktree -Force | Out-Null

        Mock New-FmIsolatedWorktree {
            [pscustomobject]@{ Path = $script:worktree; LeaseId = 'L-7'; LeaseHolder = 'fm-alpha'; Name = 'pool-1'; Project = $script:project }
        }
        Mock New-FmHerdrContainer {
            [pscustomobject]@{ Session = 'default'; WorkspaceId = 'w1'; SeededTabId = ''; Container = 'default:w1' }
        }
        Mock New-FmHerdrTask {
            [pscustomobject]@{ Session = 'default'; TabId = 't5'; PaneId = 'w1:p5'; Target = 'default:w1:p5' }
        }
        Mock Confirm-FmWorkerWorktree { $true }
        Mock Send-FmHerdrTextLine { $true }
        Mock Remove-FmHerdrPane { $true }
        Mock Remove-FmWorktreeLease { $true }
    }

    It 'creates the pane inside the leased worktree, not in the project' {
        $null = Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
            -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke New-FmHerdrTask -Times 1 -ParameterFilter { $Cwd -eq $script:worktree -and $Label -eq 'fm-alpha' }
    }

    It 'publishes the durable record with the bash field set, order and LF bytes' {
        $null = Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
            -Harness 'claude' -LaunchCommand 'claude' -Mode 'direct-PR' -Yolo 'off' `
            -FirstmateHome $script:fmHome -Confirm:$false
        $metaPath = Join-Path $script:stateDir 'alpha.meta'
        $raw = [System.IO.File]::ReadAllText($metaPath)
        $raw | Should -Not -Match "`r"
        $keys = @(($raw -split "`n" | Where-Object { $_ }) | ForEach-Object { ($_ -split '=', 2)[0] })
        $keys[0..11] | Should -Be @(
            'window', 'endpoint_task_id', 'worktree', 'project', 'harness', 'kind',
            'mode', 'yolo', 'tasktmp', 'model', 'effort', 'backend'
        )
        Get-FmMetaValue -Path $metaPath -Key 'window' | Should -Be 'default:w1:p5'
        Get-FmMetaValue -Path $metaPath -Key 'herdr_pane_id' | Should -Be 'w1:p5'
        Get-FmMetaValue -Path $metaPath -Key 'model' | Should -Be 'default'
    }

    It 'writes a record the shared endpoint validation accepts' {
        $null = Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
            -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false
        $endpoint = Test-FmTaskEndpoint -MetaPath (Join-Path $script:stateDir 'alpha.meta') -TaskId 'alpha'
        $endpoint.Valid | Should -BeTrue
        $endpoint.Target | Should -Be 'default:w1:p5'
    }

    It 'omits mode and yolo for a kind that has no delivery contract, keeping the record byte-compatible' {
        $null = Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
            -Harness 'claude' -LaunchCommand 'claude' -Kind 'scout' -FirstmateHome $script:fmHome -Confirm:$false
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:stateDir 'alpha.meta'))
        $raw | Should -Not -Match '(?m)^mode='
        $raw | Should -Not -Match '(?m)^yolo='
    }

    It 'stops the task and rolls back when the endpoint is not in the isolated copy' {
        Mock Confirm-FmWorkerWorktree { throw 'error: refusing to launch an agent outside the copy holding its work' }
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*outside the copy holding its work*'
        Should -Invoke Remove-FmHerdrPane -Times 1
        Should -Invoke Remove-FmWorktreeLease -Times 1 -ParameterFilter { $IfLeaseId -eq 'L-7' }
        Test-Path -LiteralPath (Join-Path $script:stateDir 'alpha.meta') | Should -BeFalse
    }

    It 'releases the lease and leaves no record when the launch could not be delivered' {
        Mock Send-FmHerdrTextLine { $false }
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*launch command could not be delivered*'
        Should -Invoke Remove-FmWorktreeLease -Times 1
        Test-Path -LiteralPath (Join-Path $script:stateDir 'alpha.meta') | Should -BeFalse
    }

    It 'never creates a pane when the worktree could not be acquired' {
        Mock New-FmIsolatedWorktree { throw 'error: pool exhausted' }
        Mock New-FmHerdrContainer { throw 'container must not be ensured without a worktree' }
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*pool exhausted*'
    }

    It 'refuses a duplicate launch over an existing record' {
        New-TaskRecord -StateDir $script:stateDir -TaskId 'alpha'
        Mock New-FmIsolatedWorktree { throw 'must not acquire a worktree for a duplicate launch' }
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*refusing a duplicate launch*'
    }

    It 'labels the container with the secondmate home a secondmate launch names' {
        Mock New-FmHerdrContainer {
            [pscustomobject]@{ Session = 'default'; WorkspaceId = 'w1'; SeededTabId = ''; Container = 'default:w1'
                SeenHome = $env:FM_HOME }
        }
        $smHome = Join-Path $TestDrive 'sm-home'
        New-Item -ItemType Directory -Path $smHome -Force | Out-Null
        $before = $env:FM_HOME
        $null = Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
            -Harness 'claude' -LaunchCommand 'claude' -Kind 'secondmate' -LabelHome $smHome `
            -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke New-FmHerdrContainer -Times 1 -ParameterFilter { $Relationship -eq 'other-home' }
        $env:FM_HOME | Should -Be $before
    }

    It 'refuses a secondmate launch that does not name the secondmate home' {
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Kind 'secondmate' `
                -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*must name that secondmate*'
    }

    It 'refuses an invalid task id, a missing brief, and an adapter it cannot launch' {
        { Start-FmWorker -TaskId 'bad id' -Project $script:project -BriefPath $script:brief `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*not a valid task id*'
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath (Join-Path $TestDrive 'ghost.md') `
                -Harness 'claude' -LaunchCommand 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*never launched without its instructions*'
        { Start-FmWorker -TaskId 'alpha' -Project $script:project -BriefPath $script:brief `
                -Harness 'not-an-adapter' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*unknown harness*'
    }
}

Describe 'Confirm-FmWorkerWorktree' {
    BeforeEach { Mock Start-Sleep { } }

    It 'accepts an endpoint reporting the leased path' {
        $wt = Join-Path $TestDrive 'confirm-wt'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Mock Get-FmHerdrCurrentPath { $wt }.GetNewClosure()
        Confirm-FmWorkerWorktree -Target 'default:w1:p5' -Worktree $wt -Project '/proj' | Should -BeTrue
    }

    It 'refuses an endpoint sitting anywhere else, naming what it saw' {
        Mock Get-FmHerdrCurrentPath { '/somewhere/else' }
        Mock Get-FmHerdrPaneCreationPath { '/wt/alpha' }
        { Confirm-FmWorkerWorktree -Target 'default:w1:p5' -Worktree '/wt/alpha' -Project '/proj' -Polls 2 } |
            Should -Throw "*reports '/somewhere/else'*"
    }

    It 'falls back to the creation path when no live path is reported, and says the live check did not run' {
        # WINDOWS: a live foreground_cwd is MEASURED empty on the Windows herdr
        # preview, so an empty reading must not stop every spawn - but it must
        # not silently pass either.
        $wt = Join-Path $TestDrive 'confirm-created'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Mock Get-FmHerdrCurrentPath { '' }
        Mock Get-FmHerdrPaneCreationPath { $wt }.GetNewClosure()
        $warnings = @()
        Confirm-FmWorkerWorktree -Target 'default:w1:p5' -Worktree $wt -Project '/proj' -Polls 2 `
            -WarningVariable warnings -WarningAction SilentlyContinue | Should -BeTrue
        [string]$warnings[0] | Should -BeLike '*live-cwd confirmation did NOT run*'
    }

    It 'refuses when the creation path itself names somewhere else' {
        Mock Get-FmHerdrCurrentPath { '' }
        Mock Get-FmHerdrPaneCreationPath { '/proj' }
        { Confirm-FmWorkerWorktree -Target 'default:w1:p5' -Worktree '/wt/alpha' -Project '/proj' -Polls 2 } |
            Should -Throw "*reports '/proj' as its creation path*"
    }

    It 'reports that the check did not run when the endpoint answers nothing at all' {
        Mock Get-FmHerdrCurrentPath { '' }
        Mock Get-FmHerdrPaneCreationPath { '' }
        $warnings = @()
        Confirm-FmWorkerWorktree -Target 'default:w1:p5' -Worktree '/wt/alpha' -Project '/proj' -Polls 2 `
            -WarningVariable warnings -WarningAction SilentlyContinue | Should -BeFalse
        [string]$warnings[0] | Should -BeLike '*confirmation did NOT run*'
    }
}

Describe 'Send-FmText' {
    BeforeEach {
        $script:fmHome = New-TestHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $script:stateDir = Join-Path $script:fmHome 'state'
        New-TaskRecord -StateDir $script:stateDir -TaskId 'alpha'
        Mock Start-Sleep { }
    }

    It 'delivers text only on an exact empty verdict' {
        Mock Send-FmHerdrTextSubmit { 'empty' }
        $result = Send-FmText -Target 'alpha' -Text 'push the branch' -FirstmateHome $script:fmHome -Confirm:$false
        $result.Delivered | Should -BeTrue
        $result.Target | Should -Be 'default:w1:p2'
    }

    It 'reports loudly when the steer did not land' {
        foreach ($verdict in @('pending', 'unknown')) {
            Mock Send-FmHerdrTextSubmit { $verdict }.GetNewClosure()
            { Send-FmText -Target 'alpha' -Text 'push the branch' -FirstmateHome $script:fmHome -Confirm:$false } |
                Should -Throw '*delivery unconfirmed*'
        }
    }

    It 'reports a hard send failure distinctly from an unconfirmed submit' {
        Mock Send-FmHerdrTextSubmit { 'send-failed' }
        { Send-FmText -Target 'alpha' -Text 'push the branch' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*send failed*'
    }

    It 'gives a slash command a longer pre-Enter settle' {
        Mock Send-FmHerdrTextSubmit { 'empty' }
        $null = Send-FmText -Target 'alpha' -Text '/exit' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke Send-FmHerdrTextSubmit -Times 1 -ParameterFilter { $SettleSeconds -eq 1.2 }
    }

    It 'gives a codex $skill invocation the same settle, and plain text the short one' {
        Mock Send-FmHerdrTextSubmit { 'empty' }
        New-TaskRecord -StateDir $script:stateDir -TaskId 'cx' -Harness 'codex'
        $null = Send-FmText -Target 'cx' -Text '$review' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke Send-FmHerdrTextSubmit -Times 1 -ParameterFilter { $SettleSeconds -eq 1.2 }
        $null = Send-FmText -Target 'alpha' -Text '$5 a month' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke Send-FmHerdrTextSubmit -Times 1 -ParameterFilter { $SettleSeconds -eq 0.3 }
    }

    It 'sends a named key and, for muse, clears the restored prompt after Escape' {
        Mock Send-FmHerdrKey { $true }
        New-TaskRecord -StateDir $script:stateDir -TaskId 'ms' -Harness 'muse'
        $null = Send-FmText -Target 'ms' -Key 'Escape' -FirstmateHome $script:fmHome -Confirm:$false
        Should -Invoke Send-FmHerdrKey -Times 1 -ParameterFilter { $Key -eq 'Escape' }
        Should -Invoke Send-FmHerdrKey -Times 1 -ParameterFilter { $Key -eq 'C-u' }
    }

    It 'reports loudly when a key could not be delivered' {
        Mock Send-FmHerdrKey { $false }
        { Send-FmText -Target 'alpha' -Key 'Escape' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw "*key 'Escape' not sent*"
    }

    It 'refuses a key the backend cannot deliver' {
        { Send-FmText -Target 'alpha' -Key 'F5' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*cannot deliver key*'
    }

    It 'fails closed without an explicit firstmate home' {
        $saved = $env:FM_HOME
        try {
            $env:FM_HOME = ''
            { Send-FmText -Target 'alpha' -Text 'hi' -Confirm:$false } | Should -Throw '*FM_HOME is not set*'
        } finally { $env:FM_HOME = $saved }
    }

    It 'refuses an unresolvable target instead of guessing an endpoint' {
        Mock Send-FmHerdrTextSubmit { throw 'must not send to a guessed endpoint' }
        { Send-FmText -Target 'ghost' -Text 'hi' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*not resolvable*'
    }

    It 'refuses a task recorded on a backend this port cannot drive' {
        New-TaskRecord -StateDir $script:stateDir -TaskId 'tm' -Backend 'tmux'
        { Send-FmText -Target 'tm' -Text 'hi' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*herdr session provider only*'
    }
}

Describe 'Get-FmPane' {
    BeforeEach {
        $script:fmHome = New-TestHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        New-TaskRecord -StateDir (Join-Path $script:fmHome 'state') -TaskId 'alpha'
    }

    It 'returns the capture alongside both native state readings' {
        Mock Get-FmHerdrCapture { "line1`nline2" }
        Mock Get-FmHerdrBusyState { 'busy' }
        Mock Get-FmHerdrAgentState { 'alive' }
        $pane = Get-FmPane -Target 'alpha' -Lines 40 -FirstmateHome $script:fmHome
        $pane.Capture | Should -Be "line1`nline2"
        $pane.BusyState | Should -Be 'busy'
        $pane.AgentState | Should -Be 'alive'
        $pane.Target | Should -Be 'default:w1:p2'
        Should -Invoke Get-FmHerdrCapture -Times 1 -ParameterFilter { $Lines -eq 40 }
    }

    It 'returns just the text with -TextOnly, and reads nothing else' {
        Mock Get-FmHerdrCapture { 'just text' }
        Mock Get-FmHerdrBusyState { throw 'a text-only read must not probe agent state' }
        Get-FmPane -Target 'alpha' -FirstmateHome $script:fmHome -TextOnly | Should -Be 'just text'
    }

    It 'refuses an unresolvable target' {
        { Get-FmPane -Target 'ghost' -FirstmateHome $script:fmHome } | Should -Throw '*not resolvable*'
    }
}

Describe 'Stop-FmWorker' {
    BeforeEach {
        $script:fmHome = New-TestHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $script:stateDir = Join-Path $script:fmHome 'state'
        New-TaskRecord -StateDir $script:stateDir -TaskId 'alpha'
        Mock Start-Sleep { }
    }

    It 'treats an already-stopped agent as success, idempotently' {
        Mock Get-FmHerdrAgentState { 'dead' }
        Mock Send-FmHerdrTextSubmit { throw 'must not send an exit command to a stopped agent' }
        (Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false).Outcome | Should -Be 'already-stopped'
    }

    It 'interrupts a busy agent before submitting the exit command' {
        $script:states = @('alive', 'alive', 'dead')
        $script:i = 0
        Mock Get-FmHerdrAgentState { $s = $script:states[[math]::Min($script:i, $script:states.Count - 1)]; $script:i++; $s }
        Mock Get-FmHerdrBusyState { 'busy' }
        Mock Send-FmControlInterrupt { 'unconfirmed' }
        Mock Send-FmHerdrTextSubmit { 'empty' }
        $result = Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        $result.Outcome | Should -Be 'stopped'
        $result.Interrupt | Should -Match 'delivered verified=agent-alive'
        Should -Invoke Send-FmControlInterrupt -Times 1
        Should -Invoke Send-FmHerdrTextSubmit -Times 1 -ParameterFilter { $Text -eq '/exit' }
    }

    It 'does not interrupt an idle agent' {
        $script:i = 0
        Mock Get-FmHerdrAgentState { $script:i++; if ($script:i -eq 1) { 'alive' } else { 'dead' } }
        Mock Get-FmHerdrBusyState { 'idle' }
        Mock Send-FmControlInterrupt { throw 'an idle agent must not be interrupted' }
        Mock Send-FmHerdrTextSubmit { 'empty' }
        (Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false).Interrupt | Should -Be 'not-needed'
    }

    It 'proves the stop from agent state, not from the submit verdict' {
        # A successful exit destroys the composer the verdict is read from, so
        # an inconclusive verdict must not abort a stop that really happened.
        $script:i = 0
        Mock Get-FmHerdrAgentState { $script:i++; if ($script:i -eq 1) { 'alive' } else { 'dead' } }
        Mock Get-FmHerdrBusyState { 'idle' }
        Mock Send-FmHerdrTextSubmit { 'unknown' }
        (Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false).Outcome | Should -Be 'stopped'
    }

    It 'reports exit=unconfirmed when the agent never stopped' {
        Mock Get-FmHerdrAgentState { 'alive' }
        Mock Get-FmHerdrBusyState { 'idle' }
        Mock Send-FmHerdrTextSubmit { 'empty' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -ExitWaitSeconds 1 -PollSeconds 0.1 -Confirm:$false } |
            Should -Throw '*exit=unconfirmed*'
    }

    It 'aborts on a hard transport failure for the exit command' {
        $script:i = 0
        Mock Get-FmHerdrAgentState { 'alive' }
        Mock Get-FmHerdrBusyState { 'idle' }
        Mock Send-FmHerdrTextSubmit { 'send-failed' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*exit command could not be sent*'
    }

    It 'refuses an endpoint whose state is not positively classified' {
        Mock Get-FmHerdrAgentState { 'unreadable' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*rather than a positively classified state*'
    }

    It 'refuses a missing endpoint rather than pretending it stopped' {
        Mock Get-FmHerdrAgentState { 'missing' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*there is no agent to stop*'
    }

    It 'refuses a task with no record in this home' {
        { Stop-FmWorker -TaskId 'ghost' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*targets an exact task id in this home only*'
    }

    It 'refuses a harness with no verified control mechanics' {
        New-TaskRecord -StateDir $script:stateDir -TaskId 'weird' -Harness 'homebrew-cli'
        { Stop-FmWorker -TaskId 'weird' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*refuses to guess an interrupt key or exit command*'
    }

    It 'refuses a backend this port does not implement, preserving task state' {
        # The endpoint validation refuses an unimplemented backend before any
        # lifecycle command is composed; the state-classifier gate behind it
        # (Test-FmControlBackendStateVerified, unit-tested separately) is what
        # would refuse a future backend that IS implemented but unprovable.
        $lines = @(
            'window=zj:1:2', 'endpoint_task_id=zj', 'worktree=/wt/zj', 'project=/proj',
            'harness=claude', 'kind=ship', 'backend=zellij'
        )
        [System.IO.File]::WriteAllText((Join-Path $script:stateDir 'zj.meta'), ($lines -join "`n") + "`n")
        { Stop-FmWorker -TaskId 'zj' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*does not implement*'
    }

    It 'refuses a tmux record, which it can validate but not drive' {
        $lines = @(
            'window=fmsession:fm-tm', 'endpoint_task_id=tm', 'worktree=/wt/tm', 'project=/proj',
            'harness=claude', 'kind=ship'
        )
        [System.IO.File]::WriteAllText((Join-Path $script:stateDir 'tm.meta'), ($lines -join "`n") + "`n")
        { Stop-FmWorker -TaskId 'tm' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*herdr session provider only*'
    }

    It 'refuses a remotely placed secondmate by name' {
        Add-Content -LiteralPath (Join-Path $script:stateDir 'alpha.meta') -Value 'remote_host=elsewhere'
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false } |
            Should -Throw '*runs outside this home*'
    }

    It 'closes the pane and releases the lease only when asked' {
        Mock Get-FmHerdrAgentState { 'dead' }
        Mock Remove-FmHerdrPane { $true }
        Mock Remove-FmWorktreeLease { $true }
        $plain = Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Confirm:$false
        $plain.PaneClosed | Should -BeFalse
        $plain.WorktreeRelease | Should -Be 'not-requested'
        Should -Invoke Remove-FmHerdrPane -Times 0

        $full = Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -ClosePane -ReleaseWorktree -Confirm:$false
        $full.PaneClosed | Should -BeTrue
        $full.WorktreeRelease | Should -Be 'released'
        Should -Invoke Remove-FmWorktreeLease -Times 1 -ParameterFilter { $IfLeaseId -eq 'L-1' }
    }

    It 'refuses to return a worktree this port did not lease' {
        Mock Get-FmHerdrAgentState { 'dead' }
        New-TaskRecord -StateDir $script:stateDir -TaskId 'noLease' -LeaseId ''
        Mock Remove-FmWorktreeLease { throw 'must not return an unleased worktree' }
        (Stop-FmWorker -TaskId 'noLease' -FirstmateHome $script:fmHome -ReleaseWorktree -Confirm:$false).WorktreeRelease |
            Should -Be 'refused-no-lease-id'
    }
}

Describe 'Stop-FmWorker -Interrupt' {
    BeforeEach {
        $script:fmHome = New-TestHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        New-TaskRecord -StateDir (Join-Path $script:fmHome 'state') -TaskId 'alpha'
    }

    It 'delivers the interrupt and proves the agent is STILL running' {
        Mock Send-FmControlInterrupt { 'unconfirmed' }
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrAgentState { 'alive' }
        $result = Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Interrupt -Confirm:$false
        $result.Outcome | Should -Be 'interrupted'
        $result.Proof | Should -Be 'agent-alive'
        $result.Cancel | Should -Be 'unconfirmed'
    }

    It 'refuses when the interrupt appears to have stopped the agent' {
        Mock Send-FmControlInterrupt { 'unconfirmed' }
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrAgentState { 'dead' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Interrupt -Confirm:$false } |
            Should -Throw '*an interrupt must leave the agent running*'
    }

    It 'refuses when the endpoint disappeared during the interrupt' {
        Mock Send-FmControlInterrupt { 'unconfirmed' }
        Mock Get-FmHerdrAgentState { 'alive' }
        Mock Test-FmHerdrTargetExists { $false }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Interrupt -Confirm:$false } |
            Should -Throw '*no further control action is safe*'
    }

    It 'cannot be combined with the release switches, which would stop the agent' {
        Mock Get-FmHerdrAgentState { 'alive' }
        { Stop-FmWorker -TaskId 'alpha' -FirstmateHome $script:fmHome -Interrupt -ClosePane -Confirm:$false } |
            Should -Throw '*leaves the agent running*'
    }
}
