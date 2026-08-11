#requires -Version 7.0
# Classifier tests. The keyed open-and-resolved semantics carry the weight here:
# an open captain decision must survive every later unrelated event, and only a
# resolved line carrying its exact key may close it.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    function New-StatusFile {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        [System.IO.File]::WriteAllText($Path, (($Line -join "`n") + "`n"))
    }
    function Add-StatusLine {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        [System.IO.File]::AppendAllText($Path, (($Line -join "`n") + "`n"))
    }
}

Describe 'status line parsing' {
    It 'reads the leading verb' {
        Get-FmStatusLineVerb 'done: shipped it' | Should -Be 'done'
        Get-FmStatusLineVerb 'needs-decision [key=api-shape]: two options' | Should -Be 'needs-decision'
        Get-FmStatusLineVerb '  blocked : stuck' | Should -Be 'blocked'
        Get-FmStatusLineVerb '' | Should -Be ''
        Get-FmStatusLineVerb 'no colon here' | Should -Be 'no colon here'
    }

    It 'reads the note after the first colon only' {
        Get-FmStatusLineNote 'done: PR https://example.invalid/pr/1 checks green' | Should -Be 'PR https://example.invalid/pr/1 checks green'
        Get-FmStatusLineNote 'blocked [key=k]:   spaced' | Should -Be 'spaced'
        Get-FmStatusLineNote 'bare line' | Should -Be 'bare line'
    }

    It 'reads the decision key, defaulting when there is no token' {
        Get-FmStatusDecisionKey 'needs-decision [key=api-shape]: x' | Should -Be 'api-shape'
        Get-FmStatusDecisionKey 'needs-decision: x' | Should -Be 'default'
        Get-FmStatusDecisionKey 'resolved [key=a.b_c-1]: x' | Should -Be 'a.b_c-1'
    }

    It 'returns nothing for a malformed key, so the fold ignores the line' {
        Get-FmStatusDecisionKey 'needs-decision [key=bad key]: x' | Should -BeNullOrEmpty
        Get-FmStatusDecisionKey 'needs-decision [key=]: x' | Should -BeNullOrEmpty
    }
}

Describe 'captain-relevant classification' {
    It 'treats the terminal verbs as captain-relevant' {
        foreach ($line in @('done: shipped', 'needs-decision: pick one', 'blocked: stuck', 'failed: broke')) {
            Test-FmStatusIsCaptainRelevant $line | Should -BeTrue -Because $line
        }
    }

    It 'never surfaces a nonterminal line because of its prose' {
        # The regression this rule exists for: a working: line whose note happens
        # to contain a free-text token must stay absorbed.
        Test-FmStatusIsCaptainRelevant 'working: rebased onto merged #76' | Should -BeFalse
        Test-FmStatusIsCaptainRelevant 'working: PR ready soon' | Should -BeFalse
        Test-FmStatusIsCaptainRelevant 'resolved: answered' | Should -BeFalse
        Test-FmStatusIsCaptainRelevant 'captain-held: parked in the backlog' | Should -BeFalse
        Test-FmStatusIsCaptainRelevant 'paused: waiting on the upstream release' | Should -BeFalse
        Test-FmStatusIsCaptainRelevant '' | Should -BeFalse
    }

    It 'still matches a legacy bare line with no leading verb' {
        Test-FmStatusIsCaptainRelevant 'PR ready for review' | Should -BeTrue
        Test-FmStatusIsCaptainRelevant 'merged' | Should -BeTrue
    }

    It 'honours a home-specific verb vocabulary' {
        $env:FM_CAPTAIN_RE = 'urgent'
        try {
            Test-FmStatusIsCaptainRelevant 'note: urgent thing' | Should -BeTrue
            # With the override in force the built-in verb shortcut does not apply.
            Test-FmStatusIsCaptainRelevant 'failed: broke' | Should -BeFalse
        } finally {
            Remove-Item Env:FM_CAPTAIN_RE
        }
    }

    It 'matches the pause verb only in the verb position' {
        Test-FmStatusIsPaused 'paused: rate limit resets at 09:00' | Should -BeTrue
        Test-FmStatusIsPaused 'working: the build paused midway' | Should -BeFalse
        Test-FmStatusIsPausedOrCaptainHeld 'captain-held: filed as a backlog item' | Should -BeTrue
        Test-FmStatusIsPausedOrCaptainHeld 'done: finished' | Should -BeFalse
    }

    It 'reads a configured pause verb from the environment' {
        $env:FM_CLASSIFY_PAUSED_VERB = 'holding'
        try {
            Test-FmStatusIsPaused 'holding: waiting on the vendor' | Should -BeTrue
            Test-FmStatusIsCaptainRelevant 'holding: waiting on the vendor' | Should -BeFalse
        } finally {
            Remove-Item Env:FM_CLASSIFY_PAUSED_VERB
        }
    }

    It 'distinguishes a terminal verb from a free-text match' {
        Test-FmStatusIsTerminalVerb 'done: x' | Should -BeTrue
        Test-FmStatusIsTerminalVerb 'PR ready' | Should -BeFalse
    }
}

Describe 'the keyed decision fold' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Status = Join-Path $script:TestHome.State 't1.status'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'keeps an open decision after a later unrelated terminal line' {
        # The whole reason the fold exists: reading last-event-wins would let
        # this done: line silently mask a still-open captain decision.
        New-StatusFile -Path $script:Status -Line @(
            'needs-decision [key=api-shape]: one or two endpoints?',
            'working: continuing on the other half',
            'done: the other half shipped'
        )
        $open = Get-FmOpenDecision -Path $script:Status
        $open.Count | Should -Be 1
        $open[0].Key | Should -Be 'api-shape'
        $open[0].Verb | Should -Be 'needs-decision'
        $open[0].Note | Should -Be 'one or two endpoints?'
    }

    It 'closes a decision only on its exact key' {
        New-StatusFile -Path $script:Status -Line @(
            'needs-decision [key=api-shape]: one or two endpoints?',
            'resolved [key=other-thing]: unrelated',
            'resolved: bare resolution closes only the default key'
        )
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 1
        Add-StatusLine -Path $script:Status -Line @('resolved [key=api-shape]: two endpoints')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'treats a bare line as the default key, preserving one-decision-per-task behaviour' {
        New-StatusFile -Path $script:Status -Line @('blocked: no credentials', 'resolved: credentials issued')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'closes a decision on a verified captain-held transfer' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=k]: x', 'captain-held [key=k]: filed as a backlog item')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'tracks several keys independently, most recently opened last' {
        New-StatusFile -Path $script:Status -Line @(
            'needs-decision [key=a]: first',
            'blocked [key=b]: second',
            'resolved [key=a]: answered'
        )
        $open = Get-FmOpenDecision -Path $script:Status
        $open.Count | Should -Be 1
        $open[0].Key | Should -Be 'b'
        Add-StatusLine -Path $script:Status -Line @('needs-decision [key=c]: third')
        $reopened = Get-FmOpenDecision -Path $script:Status
        $reopened[-1].Key | Should -Be 'c'
    }

    It 'ignores a line whose key is malformed' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=not ok]: x')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'refuses a reserved-namespace transition from a line that does not speak its vocabulary' {
        # Any writer reaches this same stream, so an unrelated note must not be
        # able to claim, block, or clear a reserved key.
        New-StatusFile -Path $script:Status -Line @(
            'needs-decision [key=pending-reply-7]: unrelated note'
        )
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0

        New-StatusFile -Path $script:Status -Line @(
            'needs-decision [key=pending-reply-7]: pending-reply-7 delivery: awaiting the routed answer',
            'resolved [key=pending-reply-7]: some other subsystem says it is fine'
        )
        $open = Get-FmOpenDecision -Path $script:Status
        $open.Count | Should -Be 1
        Add-StatusLine -Path $script:Status -Line @('resolved [key=pending-reply-7]: pending-reply-7 reply: answered')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'reports nothing for a missing or blank status file' {
        (Get-FmOpenDecision -Path (Join-Path $script:TestHome.State 'nope.status')).Count | Should -Be 0
        New-StatusFile -Path $script:Status -Line @('', '   ')
        (Get-FmOpenDecision -Path $script:Status).Count | Should -Be 0
    }

    It 'scans a whole fleet and tags each decision with its task' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=k]: task one')
        New-StatusFile -Path (Join-Path $script:TestHome.State 't2.status') -Line @('done: nothing open')
        New-StatusFile -Path (Join-Path $script:TestHome.State 't3.status') -Line @('blocked: task three')
        $scan = Get-FmOpenDecisionScan -StatePath $script:TestHome.State
        $scan.Count | Should -Be 2
        $scan[0].Task | Should -Be 't1'
        $scan[1].Task | Should -Be 't3'
        $scan[1].Line | Should -Be "t3`tdefault`tblocked`ttask three"
    }
}

Describe 'the incremental (cursor-backed) fold' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Status = Join-Path $script:TestHome.State 't1.status'
        $script:Probe = Join-Path $script:TestHome.Path 'read-probe.tsv'
        $env:FM_OPEN_DECISIONS_READ_PROBE = $script:Probe
    }
    AfterEach {
        Remove-Item Env:FM_OPEN_DECISIONS_READ_PROBE -ErrorAction SilentlyContinue
        Remove-FmTestHome -TestHome $script:TestHome
    }

    It 'agrees with the whole-file fold at every step' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first')
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'a'
        Add-StatusLine -Path $script:Status -Line @('working: still going', 'blocked [key=b]: second')
        $incremental = Get-FmOpenDecisionIncremental -Path $script:Status
        $whole = Get-FmOpenDecision -Path $script:Status
        ($incremental.Line -join '|') | Should -Be ($whole.Line -join '|')
        Add-StatusLine -Path $script:Status -Line @('resolved [key=a]: answered')
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'b'
    }

    It 'carries an open decision forward across many later appends' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        1..50 | ForEach-Object { Add-StatusLine -Path $script:Status -Line @("working: step $_") }
        $open = Get-FmOpenDecisionIncremental -Path $script:Status
        $open.Count | Should -Be 1
        $open[0].Key | Should -Be 'a'
    }

    It 'folds only the newly appended bytes' {
        New-StatusFile -Path $script:Status -Line @('working: one', 'working: filler', 'working: more filler')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        $firstRead = [int](([System.IO.File]::ReadAllText($script:Probe)).Trim().Split("`t")[-1])
        Add-StatusLine -Path $script:Status -Line @('working: two')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        $reads = @(([System.IO.File]::ReadAllText($script:Probe)).Trim().Split("`n"))
        $secondRead = [int]($reads[-1].Split("`t")[-1])
        $secondRead | Should -BeLessThan $firstRead
        $secondRead | Should -Be "working: two`n".Length
    }

    It 'reads nothing at all when the file has not changed' {
        New-StatusFile -Path $script:Status -Line @('working: one')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        Remove-Item -LiteralPath $script:Probe -Force
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        Test-Path -LiteralPath $script:Probe | Should -BeFalse
    }

    It 'rebuilds from byte 0 when the file was replaced' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first', 'working: filler to make it long')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        Remove-Item -LiteralPath $script:Status -Force
        New-StatusFile -Path $script:Status -Line @('blocked [key=b]: a different task history entirely')
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'b'
    }

    It 'rebuilds from byte 0 when the cursor is beyond the end of a truncated file' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first', 'working: more', 'working: and more')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        New-StatusFile -Path $script:Status -Line @('blocked [key=b]: shorter')
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'b'
    }

    It 'rebuilds when a cursor from an older fold version is present' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first')
        $cursor = Get-FmClassifyCursorPath -StatusFile $script:Status
        [System.IO.File]::WriteAllText($cursor, "version=1`noffset=999`nident=stale`n")
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'a'
    }

    It 'writes the cursor next to the status file, safe to delete' {
        New-StatusFile -Path $script:Status -Line @('needs-decision [key=a]: first')
        [void](Get-FmOpenDecisionIncremental -Path $script:Status)
        $cursor = Get-FmClassifyCursorPath -StatusFile $script:Status
        $cursor | Should -Be (Join-Path $script:TestHome.State '.t1.open-decisions-cursor')
        Remove-Item -LiteralPath $cursor -Force
        (Get-FmOpenDecisionIncremental -Path $script:Status).Key | Should -Be 'a'
    }
}

Describe 'the activity fold' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Status = Join-Path $script:TestHome.State 't1.status'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'supersedes an earlier working phase with a later keyed event' {
        New-StatusFile -Path $script:Status -Line @(
            'working [key=migration]: moving the schema',
            'done [key=migration]: schema moved'
        )
        (Get-FmOpenActivity -Path $script:Status).Count | Should -Be 0
    }

    It 'keeps a working phase open until an event carrying its key arrives' {
        New-StatusFile -Path $script:Status -Line @(
            'working [key=migration]: moving the schema',
            'done: an unrelated default-key phase finished'
        )
        $open = Get-FmOpenActivity -Path $script:Status
        $open.Count | Should -Be 1
        $open[0].Key | Should -Be 'migration'
    }

    It 'treats a declared pause as an open phase' {
        New-StatusFile -Path $script:Status -Line @('paused: waiting on the upstream release')
        (Get-FmOpenActivity -Path $script:Status)[0].Verb | Should -Be 'paused'
    }
}

Describe 'fleet scans and endpoint mapping' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'finds the tasks whose last line is captain-relevant' {
        New-StatusFile -Path (Join-Path $script:TestHome.State 't1.status') -Line @('done: shipped')
        New-StatusFile -Path (Join-Path $script:TestHome.State 't2.status') -Line @('needs-decision: x', 'working: resumed')
        $scan = Get-FmCaptainRelevantStatus -StatePath $script:TestHome.State
        $scan.Count | Should -Be 1
        $scan[0].Task | Should -Be 't1'
    }

    It 'reports a signal actionable only when a listed status file carries a captain verb' {
        $status = Join-Path $script:TestHome.State 't1.status'
        New-StatusFile -Path $status -Line @('working: mid-flight')
        Test-FmSignalReasonIsActionable -Path @($status) | Should -BeFalse
        Add-StatusLine -Path $status -Line @('needs-decision: which shape?')
        Test-FmSignalReasonIsActionable -Path @($status, (Join-Path $script:TestHome.State 't1.turn-ended')) | Should -BeTrue
    }

    It 'maps an endpoint target to its task through the recorded metadata' {
        New-FmTestMeta -TestHome $script:TestHome -Id 'lifecycle' -Fields @{ window = 'fleet:fm-lifecycle' } | Out-Null
        Convert-FmWindowToTask -Window 'fleet:fm-lifecycle' -StatePath $script:TestHome.State | Should -Be 'lifecycle'
        Convert-FmWindowToTask -Window 'other:fm-unknown' -StatePath $script:TestHome.State | Should -Be 'unknown'
    }

    It 'reports a stale endpoint terminal only on a captain-relevant last line' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{ window = 'fleet:fm-t1' } | Out-Null
        New-StatusFile -Path (Join-Path $script:TestHome.State 't1.status') -Line @('working: mid-flight')
        Test-FmStaleIsTerminal -Window 'fleet:fm-t1' -StatePath $script:TestHome.State | Should -BeFalse
        Add-StatusLine -Path (Join-Path $script:TestHome.State 't1.status') -Line @('blocked: stuck')
        Test-FmStaleIsTerminal -Window 'fleet:fm-t1' -StatePath $script:TestHome.State | Should -BeTrue
    }
}

Describe 'absorb classification' {
    It 'absorbs only on positive evidence that the crew is working' {
        $working = { param($id) 'state: working · source: run-step · validating (running)' }
        $panebusy = { param($id) 'state: working · source: pane · harness busy (record)' }
        $paused = { param($id) 'state: paused · source: status-log · waiting on the vendor' }
        $parked = { param($id) 'state: parked · source: run-step · parked at review' }
        $unknown = { param($id) 'state: unknown · source: none · worktree gone (torn down?)' }
        $garbage = { param($id) 'not a state line at all' }

        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $working | Should -Be 'working'
        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $panebusy | Should -Be 'working'
        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $paused | Should -Be 'paused'
        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $parked | Should -Be 'none'
        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $unknown | Should -Be 'none'
        Get-FmCrewAbsorbClass -Id 't1' -StateLineProvider $garbage | Should -Be 'none'
        Get-FmCrewAbsorbClass -Id '' | Should -Be 'none'
    }

    It 'never absorbs a working state whose source is only the status log' {
        # The status log is an event history, so it can never be the evidence
        # that a crew is working right now.
        $logOnly = { param($id) 'state: working · source: status-log · building' }
        Test-FmCrewProvablyWorking -Id 't1' -StateLineProvider $logOnly | Should -BeFalse
    }

    It 'requires every task in a no-verb signal to be provably working' {
        $mixed = {
            param($id)
            if ($id -eq 't1') { 'state: working · source: run-step · validating (running)' }
            else { 'state: unknown · source: none · worktree gone (torn down?)' }
        }
        Test-FmSignalCrewProvablyWorking -Path @('/s/t1.status') -StateLineProvider $mixed | Should -BeTrue
        Test-FmSignalCrewProvablyWorking -Path @('/s/t1.status', '/s/t2.turn-ended') -StateLineProvider $mixed | Should -BeFalse
    }

    It 'does not absorb a wake that names no resolvable task' {
        $working = { param($id) 'state: working · source: run-step · validating (running)' }
        Test-FmSignalCrewProvablyWorking -Path @() -StateLineProvider $working | Should -BeFalse
        Test-FmSignalCrewProvablyWorking -Path @('/s/notes.txt') -StateLineProvider $working | Should -BeFalse
    }
}
