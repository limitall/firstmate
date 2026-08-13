#requires -Version 7.0
# Pester tests for the unresolved-decision completion gate.
#
# WHAT THIS SUITE IS FOR. The gate decides whether a finished investigation may
# be discarded, and teardown is destructive, so the interesting assertions are
# the ones about REFUSING: an unresolved decision in either durable record, and
# every case where the gate could not read a record at all. A gate that answered
# "pass" on a file it failed to open would be worse than the refusal it replaced,
# so those live here as first-class tests rather than as error handling.
#
# The backlog fixtures are built through the backlog area's own verbs wherever
# one exists, so the file under test is byte-for-byte what firstmate writes
# rather than markdown this suite invented. The two shapes with no verb -
# `discovered-from:` and a report link in the title - are hand-written, which is
# exactly the hand-edited case the manual backend exists to read.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes and backlogs. -WhatIf on a fixture would leave the suite asserting against a home that was never created.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    # TASKS_AXI_FILE would redirect every backlog lookup out of the test home,
    # and Pester containers share one process, so it is cleared here and put
    # back afterwards rather than trusted to be unset.
    $script:SavedEnv = @{}
    foreach ($name in @('TASKS_AXI_FILE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE')) {
        $script:SavedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    # A home carrying a finished scout: its report, its status stream, and
    # optionally a backlog. Nothing here is a decision unless a test adds one.
    function New-GateHome {
        param(
            [string]$TaskId = 'demo-1',
            [switch]$NoReport,
            [switch]$NoStatus,
            [string[]]$Status = @('working: reading the lock code', 'done: report written')
        )
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'config', 'projects')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force
        }
        if (-not $NoReport) {
            $dir = Join-Path $root 'data' $TaskId
            $null = New-Item -ItemType Directory -Path $dir -Force
            [System.IO.File]::WriteAllText((Join-Path $dir 'report.md'), "# findings`n")
        }
        if (-not $NoStatus) {
            [System.IO.File]::WriteAllText((Join-Path $root 'state' "$TaskId.status"), (($Status -join "`n") + "`n"))
        }
        [pscustomobject]@{
            Path    = $root
            TaskId  = $TaskId
            Backlog = (Join-Path $root 'data' 'backlog.md')
            Status  = (Join-Path $root 'state' "$TaskId.status")
            Report  = (Join-Path $root 'data' $TaskId 'report.md')
        }
    }

    function Set-GateBacklog {
        # AllowEmptyString, because the binder rejects an empty ELEMENT of a
        # [string[]] without it, and a backlog fixture has blank lines in it.
        param([Parameter(Mandatory)]$Home_, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        [System.IO.File]::WriteAllText($Home_.Backlog, (($Line -join "`n") + "`n"))
    }

    # The scout's own item plus one captain-held decision, written by the verbs
    # firstmate itself uses. -Link attributes the hold by naming the report.
    function New-GateBacklogItem {
        param(
            [Parameter(Mandatory)]$Home_,
            [string]$HoldId = 'api-shape',
            [string]$HoldKind = 'captain',
            [string]$Until = '',
            [string[]]$ScoutBlockedBy = @(),
            [switch]$Link
        )
        $title = if ($Link) { "decide what data/$($Home_.TaskId)/report.md recommends" } else { 'flat or nested response shape' }
        $null = Add-FmBacklogTask -Id $HoldId -Title $title -Repo 'firstmate-win' `
            -Path $Home_.Backlog -Date '2026-08-12' -Confirm:$false
        $null = Add-FmBacklogTask -Id $Home_.TaskId -Title 'SCOUT investigate the lock' -Repo 'firstmate-win' `
            -BlockedBy $ScoutBlockedBy -Path $Home_.Backlog -Date '2026-08-10' -Start -Confirm:$false
        $null = Set-FmBacklogHold -Id $HoldId -Reason 'captain must choose the response shape' `
            -Kind $HoldKind -Until $Until -Path $Home_.Backlog -Confirm:$false
    }

    function Test-GateVerdict {
        param([Parameter(Mandatory)]$Home_, [string]$Today = '')
        Test-FmDecisionHoldComplete -TaskId $Home_.TaskId -FirstmateHome $Home_.Path -Today $Today
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        if ($null -eq $script:SavedEnv[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$name" -Value $script:SavedEnv[$name]
        }
    }
}

Describe 'the gate passes an investigation whose records carry no unresolved decision' {
    It 'passes a completed scout, and says what it read' {
        $fixture = New-GateHome
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'pass'
        $verdict.Message | Should -BeNullOrEmpty
        $verdict.Detail | Should -Match 'report'
        $verdict.Detail | Should -Match 'no open decision'
    }

    It 'passes a home with no backlog file, and reports that it read none' {
        # A home whose queue has never been created has no filed hold, which is
        # an answer rather than an unknown - but the pass has to SAY so, or a
        # reader cannot tell it from a backlog that was read and was clean.
        $fixture = New-GateHome
        Test-Path -LiteralPath $fixture.Backlog | Should -BeFalse
        (Test-GateVerdict -Home_ $fixture).Detail | Should -Match 'no backlog file at'
    }

    It 'passes a decision that was opened and then closed by its own key' {
        $fixture = New-GateHome -Status @(
            'needs-decision [key=api-shape]: flat or nested response shape',
            'captain-held [key=api-shape]: filed as a backlog item',
            'done: report written')
        (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'pass'
    }

    It 'passes a captain hold that belongs to other work' {
        $fixture = New-GateHome
        $null = Add-FmBacklogTask -Id 'other-thread' -Title 'unrelated captain call' `
            -Path $fixture.Backlog -Date '2026-08-12' -Confirm:$false
        $null = Set-FmBacklogHold -Id 'other-thread' -Reason 'captain must decide' -Kind captain `
            -Path $fixture.Backlog -Confirm:$false
        (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'pass'
    }

    It 'passes a declared dispatch hold, which is not a decision' {
        foreach ($kind in @('external', 'load', 'parked', 'future')) {
            $fixture = New-GateHome
            New-GateBacklogItem -Home_ $fixture -HoldId 'api-shape' -HoldKind $kind -ScoutBlockedBy @('api-shape')
            (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'pass' -Because "hold-kind $kind is a dispatch hold"
        }
    }

    It 'passes a hold whose until date has arrived, and names the date while it has not' {
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -Until '2026-09-01' -ScoutBlockedBy @('api-shape')
        (Test-GateVerdict -Home_ $fixture -Today '2026-09-01').Verdict | Should -Be 'pass'
        $held = Test-GateVerdict -Home_ $fixture -Today '2026-08-31'
        $held.Verdict | Should -Be 'refuse'
        ($held.Message -join "`n") | Should -Match 'in force until 2026-09-01'
    }
}

Describe 'the gate refuses an unresolved decision, and names it' {
    It 'refuses a decision the task opened in its own status stream' {
        $fixture = New-GateHome -Status @(
            'working: reading the lock code',
            'needs-decision [key=api-shape]: flat or nested response shape',
            'done: report written')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'key=api-shape'
        ($verdict.Message -join "`n") | Should -Match 'flat or nested response shape'
    }

    It 'refuses a blocker no resolved line ever closed' {
        # blocked: opens a keyed decision exactly as needs-decision does, and a
        # later unrelated done: never closes one. Same rule, same refusal.
        $fixture = New-GateHome -Status @('blocked [key=lease]: cannot get a lease', 'done: report written')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'key=lease'
    }

    It 'refuses a hold the backlog attributes by discovered-from' {
        $fixture = New-GateHome
        Set-GateBacklog -Home_ $fixture -Line @(
            '# Backlog',
            '',
            '## In flight',
            "- [ ] $($fixture.TaskId) - SCOUT investigate the lock (repo: firstmate-win) (since 2026-08-10)",
            '## Queued',
            ('- [ ] api-shape - flat or nested response shape (repo: firstmate-win) (since 2026-08-12) ' +
                "(hold: captain must choose the response shape) (hold-kind: captain) discovered-from: $($fixture.TaskId)"),
            '## Done')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'api-shape'
        ($verdict.Message -join "`n") | Should -Match "discovered-from: $($fixture.TaskId)"
    }

    It 'refuses a hold that names this task''s report' {
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -Link
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match "names data/$($fixture.TaskId)/report.md"
    }

    It 'refuses a hold this task declares itself blocked by' {
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -ScoutBlockedBy @('api-shape')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match "$($fixture.TaskId) is blocked-by api-shape"
    }

    It 'refuses the task''s OWN item held for the captain' {
        $fixture = New-GateHome
        $null = Add-FmBacklogTask -Id $fixture.TaskId -Title 'SCOUT investigate the lock' `
            -Path $fixture.Backlog -Date '2026-08-10' -Start -Confirm:$false
        $null = Set-FmBacklogHold -Id $fixture.TaskId -Reason 'captain must choose whether to implement' `
            -Kind captain -Path $fixture.Backlog -Confirm:$false
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match "it IS $($fixture.TaskId)'s own backlog item"
    }

    It 'refuses an untyped hold rather than assuming it is not a decision' {
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -HoldKind '' -ScoutBlockedBy @('api-shape')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'no hold-kind recorded'
    }

    It 'says how to clear it, on every refusal' {
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -ScoutBlockedBy @('api-shape')
        ($($(Test-GateVerdict -Home_ $fixture).Message) -join "`n") | Should -Match '--force after explicit discard approval'
    }
}

Describe 'the gate refuses what it cannot determine, rather than passing it' {
    It 'refuses a home it cannot read' {
        $verdict = Test-FmDecisionHoldComplete -TaskId 'demo-1' -FirstmateHome (Join-Path $TestDrive 'no-such-home')
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'did NOT run'
    }

    It 'refuses with no task id to answer about' {
        (Test-FmDecisionHoldComplete -TaskId '' -FirstmateHome $TestDrive).Verdict | Should -Be 'refuse'
    }

    It 'refuses when there is no report to have inventoried' {
        $fixture = New-GateHome -NoReport
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'has no report at'
    }

    It 'refuses a status file that is not an ordinary file' {
        $fixture = New-GateHome -NoStatus
        $null = New-Item -ItemType Directory -Path $fixture.Status -Force
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'not an ordinary file'
    }

    It 'refuses a backlog that is not an ordinary file' {
        $fixture = New-GateHome
        $null = New-Item -ItemType Directory -Path $fixture.Backlog -Force
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'not an ordinary file'
    }

    It 'refuses a backlog it cannot parse' {
        $fixture = New-GateHome
        Set-GateBacklog -Home_ $fixture -Line @(
            '# Backlog',
            '## Queued',
            '- [ ] api-shape - a public obligation with no metadata (kind: public-followup)',
            '## Done')
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join "`n") | Should -Match 'could not be parsed'
    }

    It 'never claims to have read a status file that is not there' {
        # An absent status file is not a refusal: the backlog is the durable
        # owner of a filed hold, and the report gate already proved the work
        # happened. What it must not do is report the stream as clean, which
        # would claim a read that never happened.
        $fixture = New-GateHome -NoStatus
        $verdict = Test-GateVerdict -Home_ $fixture
        $verdict.Verdict | Should -Be 'pass'
        $verdict.Detail | Should -Match ('no status file at ' + [regex]::Escape($fixture.Status))
        $verdict.Detail | Should -Not -Match 'carries no open decision'
    }
}

Describe 'the gate reads, and only reads' {
    It 'leaves the backlog and the status stream byte-identical on a pass and on a refusal' {
        # The skill is explicit that a hold outlives the investigation that
        # filed it, so the gate must never close one - and it must not rewrite
        # the backlog it parses either.
        $fixture = New-GateHome
        New-GateBacklogItem -Home_ $fixture -ScoutBlockedBy @('api-shape')
        $backlogBefore = [System.IO.File]::ReadAllBytes($fixture.Backlog)
        $statusBefore = [System.IO.File]::ReadAllBytes($fixture.Status)

        (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'refuse'
        [System.IO.File]::ReadAllBytes($fixture.Backlog) | Should -Be $backlogBefore
        [System.IO.File]::ReadAllBytes($fixture.Status) | Should -Be $statusBefore

        $null = Complete-FmBacklogTask -Id 'api-shape' -Note 'captain chose flat' -Path $fixture.Backlog -Confirm:$false
        (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'pass'
        [System.IO.File]::ReadAllBytes($fixture.Status) | Should -Be $statusBefore
    }

    It 'writes no open-decisions cursor while folding the status stream' {
        # The cursor-backed fold persists state as a documented exception. A
        # destructive gate has no business leaving one behind, and teardown
        # deletes that file moments later anyway.
        $fixture = New-GateHome
        (Test-GateVerdict -Home_ $fixture).Verdict | Should -Be 'pass'
        Test-Path -LiteralPath (Join-Path $fixture.Path 'state' ".$($fixture.TaskId).open-decisions-cursor") |
            Should -BeFalse
    }
}

Describe 'teardown through the gate' {
    BeforeEach {
        $script:fixture = New-GateHome
        # A worktree that is not on disk: a scout's worktree is scratch and the
        # pool return is not what this suite is about.
        $meta = @(
            'window=default:pane-1',
            "endpoint_task_id=$($script:fixture.TaskId)",
            "worktree=$(Join-Path $script:fixture.Path 'gone')",
            'project=none',
            'harness=claude',
            'kind=scout',
            'backend=herdr') -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.Path 'state' "$($script:fixture.TaskId).meta"), "$meta`n")

        Mock Remove-FmHerdrPane { $true }
        Mock Test-FmHerdrEndpointGone { $true }
        Mock Stop-FmTaskJob { [pscustomobject]@{ Outcome = 'terminated'; Survivors = @(); Detail = 'clean' } }
    }

    It 'tears a completed scout down with no --force at all' {
        # The whole point of this change: a finished investigation with nothing
        # unresolved must not need the flag that exists for discarding work.
        $result = Invoke-FmTeardown -TaskId $script:fixture.TaskId -FirstmateHome $script:fixture.Path -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        $result.Forced | Should -BeFalse
        ($result.Steps | Where-Object { $_.Step -eq 'decision-hold-gate' }).Outcome | Should -Be 'passed'
        Test-Path -LiteralPath (Join-Path $script:fixture.Path 'state' "$($script:fixture.TaskId).meta") | Should -BeFalse
        # The report is the work product and survives the worktree.
        Test-Path -LiteralPath $script:fixture.Report | Should -BeTrue
    }

    It 'REFUSES a scout whose decision is still unresolved, naming the decision' {
        New-GateBacklogItem -Home_ $script:fixture -ScoutBlockedBy @('api-shape')
        { Invoke-FmTeardown -TaskId $script:fixture.TaskId -FirstmateHome $script:fixture.Path -Confirm:$false } |
            Should -Throw '*api-shape*'
        Test-Path -LiteralPath (Join-Path $script:fixture.Path 'state' "$($script:fixture.TaskId).meta") | Should -BeTrue
        Should -Invoke Remove-FmHerdrPane -Times 0
    }

    It 'still REFUSES a scout with no report, with the report gate''s own message' {
        Remove-Item -LiteralPath $script:fixture.Report -Force
        { Invoke-FmTeardown -TaskId $script:fixture.TaskId -FirstmateHome $script:fixture.Path -Confirm:$false } |
            Should -Throw '*has no report at*'
    }

    It '--force still discards, and still requires an authority' {
        New-GateBacklogItem -Home_ $script:fixture -ScoutBlockedBy @('api-shape')
        { Invoke-FmTeardown -TaskId $script:fixture.TaskId -FirstmateHome $script:fixture.Path -Force -Confirm:$false } |
            Should -Throw '*requires -DiscardApprovedBy*'
        $result = Invoke-FmTeardown -TaskId $script:fixture.TaskId -FirstmateHome $script:fixture.Path -Force `
            -DiscardApprovedBy 'captain, 2026-08-14' -Confirm:$false
        $result.Outcome | Should -Be 'complete'
        # The hold is still the captain's to answer: teardown never closes one.
        (Get-FmBacklogTask -Id 'api-shape' -Path $script:fixture.Backlog).Hold.Reason |
            Should -Be 'captain must choose the response shape'
    }
}
